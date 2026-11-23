// Witchspire Co-op Mod Setup / WSDS Setup.
// One code base, two builds: `--features client` (players) and `--features server` (WSDS + dedicated server).
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use serde_json::{json, Value};
use std::fs;
use std::io::{Cursor, Read, Write};
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;
use tauri::{AppHandle, Emitter, State};

const CREATE_NO_WINDOW: u32 = 0x0800_0000;
const APP_ID: &str = "2679100";

#[cfg(feature = "server")]
const FLAVOR: &str = "server";
#[cfg(not(feature = "server"))]
const FLAVOR: &str = "client";

#[cfg(feature = "server")]
static PAYLOAD: &[u8] = include_bytes!("../payload/server.zip");
#[cfg(not(feature = "server"))]
static PAYLOAD: &[u8] = include_bytes!("../payload/client.zip");

#[derive(Default)]
struct Steam {
    child: Option<Child>,
    stdin: Option<ChildStdin>,
}
type SteamState = Arc<Mutex<Steam>>;

// ------------------------------------------------------------------ helpers

fn run_hidden(program: &str, args: &[&str]) -> std::io::Result<std::process::Output> {
    // PSModulePath from a PowerShell 7 parent breaks built-in cmdlets in Windows PowerShell children.
    Command::new(program).args(args).env_remove("PSModulePath").creation_flags(CREATE_NO_WINDOW).output()
}

fn ps(script: &str) -> Result<String, String> {
    let out = run_hidden("powershell", &["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script]).map_err(|e| e.to_string())?;
    let text = String::from_utf8_lossy(&out.stdout).to_string() + &String::from_utf8_lossy(&out.stderr);
    if out.status.success() {
        Ok(text)
    } else {
        Err(text.trim().to_string())
    }
}

fn reg_value(key: &str, value: &str) -> Option<String> {
    let out = run_hidden("reg", &["query", key, "/v", value]).ok()?;
    let text = String::from_utf8_lossy(&out.stdout).to_string();
    text.lines().find(|l| l.contains(value)).and_then(|l| l.split("REG_SZ").nth(1)).map(|s| s.trim().to_string())
}

fn progress(app: &AppHandle, line: &str) {
    let _ = app.emit("progress", json!({ "line": line }));
}

fn step(app: &AppHandle, name: &str) {
    let _ = app.emit("progress", json!({ "step": name }));
}

fn is_game_dir(p: &Path) -> bool {
    p.join("Hercules").join("Binaries").join("Win64").join("Hercules-Win64-Shipping.exe").exists()
}

fn game_running() -> bool {
    run_hidden("tasklist", &["/FI", "IMAGENAME eq Hercules-Win64-Shipping.exe"])
        .map(|o| String::from_utf8_lossy(&o.stdout).contains("Hercules-Win64-Shipping"))
        .unwrap_or(false)
}

fn b64(data: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in data.chunks(3) {
        let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
        let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
        out.push(T[(n >> 18) as usize & 63] as char);
        out.push(T[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 { T[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if chunk.len() > 2 { T[n as usize & 63] as char } else { '=' });
    }
    out
}

fn extract_payload(dest_root: &Path, only_prefix: Option<&str>) -> Result<usize, String> {
    let mut zip = zip::ZipArchive::new(Cursor::new(PAYLOAD)).map_err(|e| e.to_string())?;
    let mut n = 0;
    for i in 0..zip.len() {
        let mut f = zip.by_index(i).map_err(|e| e.to_string())?;
        let Some(rel) = f.enclosed_name() else { continue };
        if let Some(prefix) = only_prefix {
            if !rel.to_string_lossy().replace('\\', "/").starts_with(prefix) {
                continue;
            }
        }
        let out = dest_root.join(&rel);
        // Never overwrite settings from an earlier install.
        let fname = rel.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
        if (fname == "ServerConfig.json" || fname == "ClientConfig.json") && out.exists() {
            continue;
        }
        if f.is_dir() {
            fs::create_dir_all(&out).ok();
            continue;
        }
        if let Some(parent) = out.parent() {
            fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        let mut buf = Vec::new();
        f.read_to_end(&mut buf).map_err(|e| e.to_string())?;
        fs::write(&out, buf).map_err(|e| format!("{}: {e}", out.display()))?;
        n += 1;
    }
    Ok(n)
}

// ------------------------------------------------------------------ game detection & fonts

#[tauri::command]
fn info() -> Value {
    let autotest = std::env::var("WSCOOP_SETUP_AUTOTEST").ok().and_then(|t| serde_json::from_str::<Value>(&t).ok());
    json!({ "flavor": FLAVOR, "version": env!("CARGO_PKG_VERSION"), "autotest": autotest })
}

/// Test hooks: report which page is showing (for screenshots) and finish the run.
#[tauri::command]
fn auto_mark(label: String) {
    if let Ok(f) = std::env::var("WSCOOP_SETUP_MARK") {
        let _ = fs::write(f, label);
    }
}

#[tauri::command]
fn auto_done(app: AppHandle, ok: bool) {
    auto_mark(if ok { "done-ok".into() } else { "done-fail".into() });
    thread::spawn(move || {
        thread::sleep(Duration::from_secs(4));
        app.exit(if ok { 0 } else { 1 });
    });
}

#[tauri::command]
fn detect_game() -> Option<String> {
    let mut candidates: Vec<PathBuf> = Vec::new();
    for key in ["HKCU\\Software\\Valve\\Steam", "HKLM\\SOFTWARE\\WOW6432Node\\Valve\\Steam"] {
        for value in ["SteamPath", "InstallPath"] {
            if let Some(steam) = reg_value(key, value) {
                let steam = PathBuf::from(steam.replace('/', "\\"));
                candidates.push(steam.join("steamapps\\common\\Witchspire"));
                if let Ok(vdf) = fs::read_to_string(steam.join("steamapps\\libraryfolders.vdf")) {
                    for line in vdf.lines() {
                        let t = line.trim();
                        if t.starts_with("\"path\"") {
                            if let Some(p) = t.split('"').nth(3) {
                                candidates.push(PathBuf::from(p.replace("\\\\", "\\")).join("steamapps\\common\\Witchspire"));
                            }
                        }
                    }
                }
            }
        }
    }
    candidates.push(PathBuf::from("C:\\WitchspireServer"));
    candidates.into_iter().find(|p| is_game_dir(p)).map(|p| p.display().to_string())
}

#[tauri::command]
fn check_game(path: String) -> Value {
    let p = PathBuf::from(&path);
    json!({
        "found": is_game_dir(&p),
        "running": game_running(),
        "installed": p.join("WitchspireCoopMod").join("Install.ps1").exists(),
    })
}

/// Fonts from the player's own game files (Griezly, Lato); empty when the game is not available yet.
#[tauri::command]
async fn fonts(path: String) -> Result<Value, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let tmp = std::env::temp_dir().join("wscoop-setup-tools");
        if extract_payload(&tmp, Some("WitchspireCoopMod/tools/")).is_err() {
            return json!({});
        }
        let repak = tmp.join("WitchspireCoopMod\\tools\\repak.exe");
        let pak = PathBuf::from(&path).join("Hercules\\Content\\Paks\\Hercules-Windows.pak");
        let mut out = json!({});
        if !repak.exists() || !pak.exists() {
            return out;
        }
        for name in ["Griezly-Regular", "Lato-Regular", "Lato-Bold"] {
            if let Ok(o) = Command::new(&repak)
                .args(["get", &pak.to_string_lossy(), &format!("Hercules/Content/UserInterface/Fonts/{name}.ufont")])
                .creation_flags(CREATE_NO_WINDOW)
                .output()
            {
                let raw = o.stdout;
                if raw.len() > 1000 {
                    let start = if &raw[4..8] == b"OTTO" || raw[4..8] == [0, 1, 0, 0] { 4 } else { 0 };
                    out[name] = json!(b64(&raw[start..]));
                }
            }
        }
        out
    })
    .await
    .map_err(|e| e.to_string())
}

// ------------------------------------------------------------------ SteamCMD (server)

#[tauri::command]
fn steamcmd_start(app: AppHandle, steam: State<SteamState>, dir: String, user: String, password: String) -> Result<(), String> {
    let steam = steam.inner().clone();
    thread::spawn(move || {
        if let Err(e) = steamcmd_run(&app, &steam, &dir, &user, &password) {
            let _ = app.emit("steam", json!({ "event": "error", "message": e }));
        }
    });
    Ok(())
}

fn steamcmd_run(app: &AppHandle, steam: &SteamState, dir: &str, user: &str, password: &str) -> Result<(), String> {
    let game = PathBuf::from(dir);
    let tools = game.join("steamcmd");
    let exe = tools.join("steamcmd.exe");
    fs::create_dir_all(&tools).map_err(|e| e.to_string())?;
    if !exe.exists() {
        let _ = app.emit("steam", json!({ "event": "line", "line": "Downloading SteamCMD from Valve..." }));
        ps(&format!(
            "$ProgressPreference='SilentlyContinue'; [Net.ServicePointManager]::SecurityProtocol='Tls12'; Invoke-WebRequest 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip' -OutFile '{0}\\steamcmd.zip'; Expand-Archive -Force '{0}\\steamcmd.zip' '{0}'",
            tools.display()
        ))?;
    }
    let _ = app.emit("steam", json!({ "event": "line", "line": "Starting SteamCMD (it updates itself the first time)..." }));
    let mut child = Command::new(&exe)
        .creation_flags(CREATE_NO_WINDOW)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| e.to_string())?;
    let mut stdout = child.stdout.take().unwrap();
    let mut stdin = child.stdin.take().unwrap();
    // Commands go through stdin so the Steam password never appears on a command line.
    writeln!(stdin, "force_install_dir \"{}\"", game.display()).ok();
    writeln!(stdin, "login {} {}", user, password).ok();
    stdin.flush().ok();
    {
        let mut st = steam.lock().unwrap();
        st.child = Some(child);
        st.stdin = Some(stdin);
    }

    let mut buf = [0u8; 4096];
    let mut pending = String::new();
    let mut logged_in = false;
    let mut done = false;
    loop {
        let n = match stdout.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        pending.push_str(&String::from_utf8_lossy(&buf[..n]));
        // Prompts end without a newline: check the partial buffer.
        let lower = pending.to_lowercase();
        if lower.contains("steam guard code:") || lower.contains("two-factor code:") || lower.contains("two factor code:") {
            let _ = app.emit("steam", json!({ "event": "need_code" }));
            pending.clear();
            continue;
        }
        while let Some(i) = pending.find('\n') {
            let line = pending[..i].trim_end_matches('\r').trim().to_string();
            pending.drain(..=i);
            if line.is_empty() {
                continue;
            }
            // Never echo anything that could contain the password.
            if line.to_lowercase().contains(&password.to_lowercase()) && !password.is_empty() {
                continue;
            }
            let _ = app.emit("steam", json!({ "event": "line", "line": line }));
            let l = line.to_lowercase();
            if !logged_in && (l.contains("waiting for user info...ok") || l.contains("logged in ok")) {
                logged_in = true;
                let _ = app.emit("steam", json!({ "event": "logged_in" }));
                if let Some(si) = steam.lock().unwrap().stdin.as_mut() {
                    writeln!(si, "app_update {APP_ID} validate").ok();
                    si.flush().ok();
                }
            }
            if l.contains("confirm the login in the steam mobile app") || l.contains("check your email") {
                let _ = app.emit("steam", json!({ "event": "confirm_mobile" }));
            }
            if l.contains("invalid password") || l.contains("failed (invalid") || l.contains("rate limit") || l.contains("account logon denied") && !l.contains("steam guard") {
                let _ = app.emit("steam", json!({ "event": "error", "message": line.clone() }));
            }
            if l.contains("no subscription") {
                let _ = app.emit("steam", json!({ "event": "error", "message": "This Steam account does not own Witchspire." }));
            }
            if l.contains("success! app") && l.contains("fully installed") {
                done = true;
                if let Some(si) = steam.lock().unwrap().stdin.as_mut() {
                    writeln!(si, "quit").ok();
                    si.flush().ok();
                }
            }
            if l.starts_with("error! app") {
                let _ = app.emit("steam", json!({ "event": "error", "message": line.clone() }));
            }
            if l.contains("update state") && l.contains("progress:") {
                if let Some(p) = l.split("progress:").nth(1).and_then(|r| r.split_whitespace().next()) {
                    let _ = app.emit("steam", json!({ "event": "percent", "value": p }));
                }
            }
        }
    }
    {
        let mut st = steam.lock().unwrap();
        if let Some(mut c) = st.child.take() {
            let _ = c.wait();
        }
        st.stdin = None;
    }
    if done && is_game_dir(&game) {
        let _ = app.emit("steam", json!({ "event": "done", "path": game.display().to_string(), "steamcmd": exe.display().to_string() }));
        Ok(())
    } else {
        Err("SteamCMD finished without installing Witchspire (see the log above).".into())
    }
}

#[tauri::command]
fn steamcmd_code(steam: State<SteamState>, code: String) -> Result<(), String> {
    let mut st = steam.lock().unwrap();
    let si = st.stdin.as_mut().ok_or("SteamCMD is not running")?;
    writeln!(si, "{}", code.trim()).map_err(|e| e.to_string())?;
    si.flush().map_err(|e| e.to_string())
}

#[tauri::command]
fn steamcmd_cancel(steam: State<SteamState>) {
    if let Some(c) = steam.lock().unwrap().child.as_mut() {
        let _ = c.kill();
    }
}

// ------------------------------------------------------------------ install / uninstall

#[tauri::command]
fn install(app: AppHandle, opts: Value) -> Result<(), String> {
    thread::spawn(move || {
        let r = do_install(&app, &opts);
        let _ = app.emit("progress", match r {
            Ok(summary) => json!({ "done": true, "summary": summary }),
            Err(e) => json!({ "error": e }),
        });
    });
    Ok(())
}

fn do_install(app: &AppHandle, opts: &Value) -> Result<Value, String> {
    let game = PathBuf::from(opts["gamePath"].as_str().unwrap_or(""));
    if !is_game_dir(&game) {
        return Err(format!("Witchspire was not found at {}", game.display()));
    }
    if game_running() {
        return Err("Witchspire (or a Witchspire server) is running. Close it and try again.".into());
    }
    let mod_root = game.join("WitchspireCoopMod");

    if FLAVOR == "server" {
        // Stop a previous background service so its files can be replaced.
        let _ = ps("Stop-ScheduledTask -TaskName 'WSDS' -ErrorAction SilentlyContinue; Get-Process WSDS -ErrorAction SilentlyContinue | Stop-Process -Force");
        thread::sleep(Duration::from_secs(2));
    }

    step(app, "Copying files");
    let n = extract_payload(&game, None)?;
    progress(app, &format!("{n} files copied to {}", mod_root.display()));

    step(app, "Installing the Co-op Overhaul mod");
    let out = run_hidden("powershell", &["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", &mod_root.join("Install.ps1").to_string_lossy()]).map_err(|e| e.to_string())?;
    for line in String::from_utf8_lossy(&out.stdout).lines().chain(String::from_utf8_lossy(&out.stderr).lines()) {
        if !line.trim().is_empty() {
            progress(app, line.trim());
        }
    }
    if !out.status.success() {
        return Err("The mod could not be installed (see the log above).".into());
    }

    if FLAVOR == "client" {
        return Ok(json!({ "modRoot": mod_root.display().to_string() }));
    }

    // ---------------- server-only steps
    step(app, "Checking the Visual C++ runtime");
    let sys = PathBuf::from(std::env::var("WINDIR").unwrap_or("C:\\Windows".into())).join("System32");
    if !(sys.join("vcruntime140.dll").exists() && sys.join("vcruntime140_1.dll").exists() && sys.join("msvcp140.dll").exists()) {
        progress(app, "Installing the Microsoft Visual C++ runtime...");
        ps("$ProgressPreference='SilentlyContinue'; [Net.ServicePointManager]::SecurityProtocol='Tls12'; $f=\"$env:TEMP\\vc_redist.x64.exe\"; Invoke-WebRequest 'https://aka.ms/vs/17/release/vc_redist.x64.exe' -OutFile $f; Start-Process $f -ArgumentList '/install','/quiet','/norestart' -Wait")?;
        progress(app, "Visual C++ runtime installed.");
    } else {
        progress(app, "Visual C++ runtime present.");
    }

    step(app, "Writing server settings");
    let cfg_path = mod_root.join("ServerConfig.json");
    let mut cfg: Value = fs::read_to_string(&cfg_path).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or(json!({}));
    let game_port = opts["gamePort"].as_u64().unwrap_or(7777);
    let remote_port = opts["remotePort"].as_u64().unwrap_or(7780);
    cfg["SetupComplete"] = json!(true);
    cfg["WorldName"] = json!(opts["worldName"].as_str().unwrap_or("Witchspire Dedicated Server"));
    if cfg.get("WorldSlot").is_none() {
        cfg["WorldSlot"] = json!("DedicatedWorld");
    }
    cfg["Port"] = json!(game_port);
    cfg["MaxPlayers"] = json!(opts["maxPlayers"].as_u64().unwrap_or(8));
    cfg["Password"] = json!(opts["joinPassword"].as_str().unwrap_or(""));
    cfg["AutoRestartOnCrash"] = json!(true);
    if cfg.get("SteamCmd").is_none() || !cfg["SteamCmd"].is_object() {
        cfg["SteamCmd"] = json!({});
    }
    if let Some(p) = opts["steamcmd"].as_str().filter(|s| !s.is_empty()) {
        cfg["SteamCmd"]["Path"] = json!(p);
        cfg["SteamCmd"]["User"] = json!(opts["steamUser"].as_str().unwrap_or(""));
    }
    fs::write(&cfg_path, serde_json::to_string_pretty(&cfg).unwrap()).map_err(|e| e.to_string())?;

    let wsds = mod_root.join("WSDS.exe");
    let remote_pw = opts["remotePassword"].as_str().unwrap_or("");
    if !remote_pw.is_empty() {
        step(app, "Enabling remote control");
        let st = Command::new(&wsds)
            .args(["--set-remote-password", remote_pw, "--port", &remote_port.to_string()])
            .creation_flags(CREATE_NO_WINDOW)
            .status()
            .map_err(|e| e.to_string())?;
        if !st.success() {
            return Err("Could not configure remote control.".into());
        }
        progress(app, &format!("Remote control enabled on TCP port {remote_port} (password stored as a salted hash)."));
    }

    if opts["firewall"].as_bool().unwrap_or(true) {
        step(app, "Opening Windows Firewall ports");
        let _ = run_hidden("netsh", &["advfirewall", "firewall", "delete", "rule", "name=WSDS Game"]);
        let _ = run_hidden("netsh", &["advfirewall", "firewall", "delete", "rule", "name=WSDS Remote Control"]);
        run_hidden("netsh", &["advfirewall", "firewall", "add", "rule", "name=WSDS Game", "dir=in", "action=allow", "protocol=UDP", &format!("localport={game_port}")]).map_err(|e| e.to_string())?;
        progress(app, &format!("Allowed UDP {game_port} (players)."));
        if !remote_pw.is_empty() {
            run_hidden("netsh", &["advfirewall", "firewall", "add", "rule", "name=WSDS Remote Control", "dir=in", "action=allow", "protocol=TCP", &format!("localport={remote_port}")]).map_err(|e| e.to_string())?;
            progress(app, &format!("Allowed TCP {remote_port} (remote control)."));
        }
    }

    if opts["service"].as_bool().unwrap_or(true) {
        step(app, "Installing the background service");
        ps(&format!(
            "$a = New-ScheduledTaskAction -Execute '{0}' -Argument '--headless' -WorkingDirectory '{1}';\
             $t = New-ScheduledTaskTrigger -AtStartup;\
             $s = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable;\
             $p = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest;\
             Register-ScheduledTask -TaskName 'WSDS' -Description 'Witchspire Dedicated Server (WSDS)' -Action $a -Trigger $t -Settings $s -Principal $p -Force | Out-Null;\
             Start-ScheduledTask -TaskName 'WSDS'",
            wsds.display(),
            mod_root.display()
        ))?;
        progress(app, "WSDS runs in the background at every boot and has been started now.");
    }

    step(app, "Creating shortcuts");
    let _ = ps(&format!(
        "$w = New-Object -ComObject WScript.Shell;\
         foreach ($dir in @([Environment]::GetFolderPath('CommonDesktopDirectory'), (Join-Path ([Environment]::GetFolderPath('CommonPrograms')) ''))) {{\
           $l = $w.CreateShortcut((Join-Path $dir 'WSDS.lnk')); $l.TargetPath = '{0}'; $l.WorkingDirectory = '{1}'; $l.IconLocation = '{0},0'; $l.Description = 'Witchspire Dedicated Server'; $l.Save() }}",
        wsds.display(),
        mod_root.display()
    ));
    let ip = ps("$ProgressPreference='SilentlyContinue'; try { (Invoke-RestMethod 'https://api.ipify.org' -TimeoutSec 5) } catch { '' }").unwrap_or_default().trim().to_string();
    Ok(json!({ "modRoot": mod_root.display().to_string(), "wsds": wsds.display().to_string(), "publicIp": ip, "gamePort": game_port, "remotePort": remote_port }))
}

#[tauri::command]
fn uninstall(app: AppHandle, path: String) -> Result<(), String> {
    thread::spawn(move || {
        let r = (|| -> Result<(), String> {
            let game = PathBuf::from(&path);
            let mod_root = game.join("WitchspireCoopMod");
            if FLAVOR == "server" {
                step(&app, "Removing the background service");
                let _ = ps("Stop-ScheduledTask -TaskName 'WSDS' -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName 'WSDS' -Confirm:$false -ErrorAction SilentlyContinue; Get-Process WSDS -ErrorAction SilentlyContinue | Stop-Process -Force");
                let _ = run_hidden("netsh", &["advfirewall", "firewall", "delete", "rule", "name=WSDS Game"]);
                let _ = run_hidden("netsh", &["advfirewall", "firewall", "delete", "rule", "name=WSDS Remote Control"]);
                let _ = ps("foreach ($d in @([Environment]::GetFolderPath('CommonDesktopDirectory'), [Environment]::GetFolderPath('CommonPrograms'))) { Remove-Item (Join-Path $d 'WSDS.lnk') -ErrorAction SilentlyContinue }");
                thread::sleep(Duration::from_secs(3));
            }
            if game_running() {
                return Err("Witchspire is running. Close it and try again.".into());
            }
            step(&app, "Restoring the original game files");
            let out = run_hidden("powershell", &["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", &mod_root.join("Uninstall.ps1").to_string_lossy()]).map_err(|e| e.to_string())?;
            for line in String::from_utf8_lossy(&out.stdout).lines() {
                if !line.trim().is_empty() {
                    progress(&app, line.trim());
                }
            }
            step(&app, "Removing mod files");
            // Keep server worlds (ServerData) - everything else goes.
            if let Ok(rd) = fs::read_dir(&mod_root) {
                for e in rd.flatten() {
                    if e.file_name() == "ServerData" {
                        continue;
                    }
                    let p = e.path();
                    let meta = fs::symlink_metadata(&p);
                    let r = if meta.map(|m| m.is_dir()).unwrap_or(false) { remove_dir_links_safe(&p) } else { fs::remove_file(&p) };
                    if let Err(err) = r {
                        progress(&app, &format!("could not remove {}: {err}", p.display()));
                    }
                }
            }
            Ok(())
        })();
        let _ = app.emit("progress", match r {
            Ok(()) => json!({ "done": true, "summary": { "uninstalled": true } }),
            Err(e) => json!({ "error": e }),
        });
    });
    Ok(())
}

/// Deletes a directory tree without following junctions (ServerInstall contains junctions into the game).
fn remove_dir_links_safe(p: &Path) -> std::io::Result<()> {
    let meta = fs::symlink_metadata(p)?;
    // Junctions/symlinks: remove only the link itself.
    if meta.file_type().is_symlink() || is_junction(p) {
        return fs::remove_dir(p);
    }
    for e in fs::read_dir(p)?.flatten() {
        let ep = e.path();
        let m = fs::symlink_metadata(&ep)?;
        if m.is_dir() {
            remove_dir_links_safe(&ep)?;
        } else {
            fs::remove_file(&ep)?;
        }
    }
    fs::remove_dir(p)
}

fn is_junction(p: &Path) -> bool {
    use std::os::windows::fs::MetadataExt;
    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
    fs::symlink_metadata(p).map(|m| m.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0).unwrap_or(false)
}

#[tauri::command]
fn launch(path: String, args: Vec<String>) -> Result<(), String> {
    Command::new(&path).args(&args).spawn().map(|_| ()).map_err(|e| e.to_string())
}

#[tauri::command]
fn open_path(path: String) {
    let _ = Command::new("explorer").arg(path).spawn();
}

// ------------------------------------------------------------------ WebView2 bootstrap (before any window)

#[link(name = "user32")]
extern "system" {
    fn MessageBoxW(hwnd: isize, text: *const u16, caption: *const u16, flags: u32) -> i32;
}

fn message_box(text: &str, caption: &str, flags: u32) -> i32 {
    let t: Vec<u16> = text.encode_utf16().chain(Some(0)).collect();
    let c: Vec<u16> = caption.encode_utf16().chain(Some(0)).collect();
    unsafe { MessageBoxW(0, t.as_ptr(), c.as_ptr(), flags) }
}

fn ensure_webview2() {
    let key = "{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}";
    let present = [
        format!("HKLM\\SOFTWARE\\WOW6432Node\\Microsoft\\EdgeUpdate\\Clients\\{key}"),
        format!("HKCU\\Software\\Microsoft\\EdgeUpdate\\Clients\\{key}"),
        format!("HKLM\\SOFTWARE\\Microsoft\\EdgeUpdate\\Clients\\{key}"),
    ]
    .iter()
    .any(|k| reg_value(k, "pv").map(|v| !v.is_empty() && v != "0.0.0.0").unwrap_or(false));
    if present {
        return;
    }
    // MB_OKCANCEL | MB_ICONINFORMATION
    if message_box("This setup needs the Microsoft Edge WebView2 runtime, which is not installed on this PC.\n\nPress OK to download and install it from Microsoft (about 2 MB, takes a minute).", "Setup", 0x1 | 0x40) != 1 {
        std::process::exit(1);
    }
    let r = ps("$ProgressPreference='SilentlyContinue'; [Net.ServicePointManager]::SecurityProtocol='Tls12'; $f=\"$env:TEMP\\MicrosoftEdgeWebview2Setup.exe\"; Invoke-WebRequest 'https://go.microsoft.com/fwlink/p/?LinkId=2124703' -OutFile $f; Start-Process $f -ArgumentList '/silent','/install' -Wait");
    if let Err(e) = r {
        message_box(&format!("Could not install WebView2:\n{e}"), "Setup", 0x10);
        std::process::exit(1);
    }
}

fn main() {
    ensure_webview2();
    tauri::Builder::default()
        .manage(SteamState::default())
        .invoke_handler(tauri::generate_handler![info, auto_mark, auto_done, detect_game, check_game, fonts, steamcmd_start, steamcmd_code, steamcmd_cancel, install, uninstall, launch, open_path])
        .run(tauri::generate_context!())
        .expect("error while running setup");
}
