// Witchspire Co-op Mod Setup / WSDS Setup / WSCoopUpdater.
// One code base, three builds: `--features client` (players), `--features server` (WSDS + dedicated server)
// and `--features updater` (WSCoopUpdater.exe, the players' auto-updater, see updater.rs).
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
// The updater reuses a few helpers; the setup-only code is unused (and dropped by the linker) there.
#![cfg_attr(feature = "updater", allow(dead_code))]

#[cfg(feature = "updater")]
mod updater;

use serde_json::{json, Value};
use std::fs;
use std::io::{Cursor, Read};
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;
use tauri::{AppHandle, Emitter, State};

const CREATE_NO_WINDOW: u32 = 0x0800_0000;
const APP_ID: &str = "2679100";

#[cfg(feature = "server")]
const FLAVOR: &str = "server";
#[cfg(all(feature = "updater", not(feature = "server")))]
const FLAVOR: &str = "updater";
#[cfg(not(any(feature = "server", feature = "updater")))]
const FLAVOR: &str = "client";

#[cfg(feature = "server")]
static PAYLOAD: &[u8] = include_bytes!("../payload/server.zip");
#[cfg(all(feature = "updater", not(feature = "server")))]
static PAYLOAD: &[u8] = &[];
#[cfg(not(any(feature = "server", feature = "updater")))]
static PAYLOAD: &[u8] = include_bytes!("../payload/client.zip");

/// The player setup installs the updater next to the mod (built first, see build.rs / BuildInstallers.ps1).
#[cfg(not(any(feature = "server", feature = "updater")))]
static UPDATER_EXE: &[u8] = include_bytes!("../payload/WSCoopUpdater.exe");
#[cfg(any(feature = "server", feature = "updater"))]
static UPDATER_EXE: &[u8] = &[];

const UPDATE_PROTOCOL_KEY: &str = "HKCU\\Software\\Classes\\wscoop-update";

#[derive(Default)]
struct Steam {
    child: Option<Child>,
    /// Bumped by every new attempt; an older attempt stops reporting once it changes.
    gen: u64,
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

/// Witchspire processes (game or dedicated server) started from this game folder. Copies of the game
/// elsewhere on the PC do not count.
fn running_pids(game: &Path) -> Vec<u32> {
    let mut root = game.display().to_string().replace('/', "\\");
    if !root.ends_with('\\') {
        root.push('\\');
    }
    let script = format!(
        "Get-Process Hercules-Win64-Shipping -ErrorAction SilentlyContinue | Where-Object {{ -not $_.Path -or $_.Path.StartsWith('{}', [StringComparison]::OrdinalIgnoreCase) }} | ForEach-Object {{ $_.Id }}",
        root.replace('\'', "''")
    );
    ps(&script).map(|o| o.lines().filter_map(|l| l.trim().parse().ok()).collect()).unwrap_or_default()
}

fn game_running(game: &Path) -> bool {
    !running_pids(game).is_empty()
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

fn now_secs() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

/// Writes an exe that may be running right now: a running exe cannot be overwritten or deleted but can be
/// renamed, so it is moved aside as <name>.old-<time>.exe (the updater deletes those at its next start).
/// Returns false when the file already had exactly these bytes.
fn replace_exe(target: &Path, bytes: &[u8]) -> Result<bool, String> {
    if fs::read(target).map(|b| b == bytes).unwrap_or(false) {
        return Ok(false);
    }
    if fs::write(target, bytes).is_ok() {
        return Ok(true);
    }
    let stem = target.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
    let aside = target.with_file_name(format!("{stem}.old-{}.exe", now_secs()));
    fs::rename(target, &aside).map_err(|e| format!("{} is in use and could not be moved aside: {e}", target.display()))?;
    if let Err(e) = fs::write(target, bytes) {
        let _ = fs::rename(&aside, target);
        return Err(format!("{}: {e}", target.display()));
    }
    Ok(true)
}

/// Per-user URL protocol wscoop-update:// -> WSCoopUpdater.exe (the game's main menu opens it).
fn register_update_protocol(updater: &Path) -> Result<(), String> {
    let command = format!("\"{}\" \"%1\"", updater.display());
    let key = UPDATE_PROTOCOL_KEY;
    let cmd_key = format!("{key}\\shell\\open\\command");
    let runs: [Vec<&str>; 3] = [
        vec!["add", key, "/ve", "/d", "URL:Witchspire Co-op Mod Update", "/f"],
        vec!["add", key, "/v", "URL Protocol", "/t", "REG_SZ", "/f"],
        vec!["add", &cmd_key, "/ve", "/d", &command, "/f"],
    ];
    for args in runs {
        let out = run_hidden("reg", &args).map_err(|e| e.to_string())?;
        if !out.status.success() {
            return Err(format!("reg {}: {}", args.join(" "), String::from_utf8_lossy(&out.stderr).trim()));
        }
    }
    Ok(())
}

/// Removes the protocol when it points into this mod folder (or at an updater that no longer exists).
fn unregister_update_protocol(mod_root: &Path) {
    let Some(cmd) = reg_default(&format!("{UPDATE_PROTOCOL_KEY}\\shell\\open\\command")) else { return };
    let exe = cmd.trim().trim_start_matches('"').split('"').next().unwrap_or("").to_string();
    let ours = exe.to_lowercase().starts_with(&mod_root.display().to_string().to_lowercase());
    if ours || !Path::new(&exe).exists() {
        let _ = run_hidden("reg", &["delete", UPDATE_PROTOCOL_KEY, "/f"]);
    }
}

fn reg_default(key: &str) -> Option<String> {
    let out = run_hidden("reg", &["query", key, "/ve"]).ok()?;
    let text = String::from_utf8_lossy(&out.stdout).to_string();
    text.lines().find(|l| l.contains("REG_SZ")).and_then(|l| l.split("REG_SZ").nth(1)).map(|s| s.trim().to_string())
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
        "running": game_running(&p),
        "installed": p.join("WitchspireCoopMod").join("Install.ps1").exists(),
    })
}

/// Fonts from the player's own game files (Griezly, Lato); empty when the game is not available yet.
#[tauri::command]
async fn fonts(path: String) -> Result<Value, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let repak = if FLAVOR == "updater" {
            // The updater has no payload: use the tools the setup installed next to the mod.
            PathBuf::from(&path).join("WitchspireCoopMod\\tools\\repak.exe")
        } else {
            let tmp = std::env::temp_dir().join("wscoop-setup-tools");
            if extract_payload(&tmp, Some("WitchspireCoopMod/tools/")).is_err() {
                return json!({});
            }
            tmp.join("WitchspireCoopMod\\tools\\repak.exe")
        };
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
fn steamcmd_start(app: AppHandle, steam: State<SteamState>, dir: String, user: String, password: String, guard: Option<String>) -> Result<(), String> {
    let steam = steam.inner().clone();
    let gen = {
        let mut st = steam.lock().unwrap();
        st.gen += 1;
        if let Some(c) = st.child.as_mut() {
            let _ = c.kill();
        }
        st.child = None;
        st.gen
    };
    thread::spawn(move || {
        let r = steamcmd_run(&app, &steam, &dir, &user, &password, guard.as_deref().unwrap_or(""), gen);
        if let Err(e) = r {
            if steam.lock().unwrap().gen == gen {
                let _ = app.emit("steam", json!({ "event": "error", "message": e }));
            }
        }
    });
    Ok(())
}

fn steamcmd_count() -> usize {
    run_hidden("tasklist", &["/FI", "IMAGENAME eq steamcmd.exe", "/NH"])
        .map(|o| String::from_utf8_lossy(&o.stdout).matches("steamcmd.exe").count())
        .unwrap_or(0)
}

/// Waits until no SteamCMD process is left (it relaunches itself after updating).
fn wait_steamcmd_gone(max_secs: u64) {
    for _ in 0..max_secs {
        if steamcmd_count() == 0 {
            return;
        }
        thread::sleep(Duration::from_secs(1));
    }
}

/// SteamCMD runs hidden; the sign-in goes on its command line (SteamCMD does not read piped input
/// reliably on Windows) and status is read from its console log, which it writes line by line.
/// A Steam Guard code is supplied on a retry with +set_steam_guard_code.
fn steamcmd_run(app: &AppHandle, steam: &SteamState, dir: &str, user: &str, password: &str, guard: &str, gen: u64) -> Result<(), String> {
    let current = || steam.lock().unwrap().gen == gen;
    let emit = |v: Value| {
        if current() {
            let _ = app.emit("steam", v);
        }
    };
    let line = |l: &str| emit(json!({ "event": "line", "line": l }));
    let game = PathBuf::from(dir);
    // Outside the game folder: SteamCMD refuses to treat its own folder tree as an install dir.
    let tools = PathBuf::from(std::env::var("ProgramData").unwrap_or_else(|_| r"C:\ProgramData".into())).join("WSDS").join("steamcmd");
    let exe = tools.join("steamcmd.exe");
    fs::create_dir_all(&tools).map_err(|e| e.to_string())?;
    let _ = run_hidden("taskkill", &["/F", "/IM", "steamcmd.exe"]);
    if !exe.exists() {
        line("Downloading SteamCMD from Valve...");
        ps(&format!(
            "$ProgressPreference='SilentlyContinue'; [Net.ServicePointManager]::SecurityProtocol='Tls12'; Invoke-WebRequest 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip' -OutFile '{0}\\steamcmd.zip'; Expand-Archive -Force '{0}\\steamcmd.zip' '{0}'",
            tools.display()
        ))?;
    }
    if guard.trim().is_empty() {
        line("Updating SteamCMD (takes a minute the first time)...");
        let _ = Command::new(&exe).arg("+quit").current_dir(&tools).creation_flags(CREATE_NO_WINDOW).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).status();
        wait_steamcmd_gone(240);
    }

    let log = tools.join("logs").join("console_log.txt");
    let mut pos = fs::metadata(&log).map(|m| m.len()).unwrap_or(0);
    // Steam's two-factor requests only appear in the connection log.
    let clog = tools.join("logs").join("connection_log.txt");
    let mut cpos = fs::metadata(&clog).map(|m| m.len()).unwrap_or(0);
    let mut told_confirm = false;
    line(&format!("Signing in to Steam as {user}..."));
    let mut args: Vec<String> = Vec::new();
    if !guard.trim().is_empty() {
        args.extend(["+set_steam_guard_code".into(), guard.trim().to_string()]);
    }
    args.extend([
        "+force_install_dir".into(), game.to_string_lossy().to_string(),
        "+login".into(), user.to_string(), password.to_string(),
        "+app_update".into(), APP_ID.into(), "validate".into(), "+quit".into(),
    ]);
    let child = Command::new(&exe)
        .args(&args)
        .current_dir(&tools)
        .creation_flags(CREATE_NO_WINDOW)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("could not start SteamCMD: {e}"))?;
    {
        let mut st = steam.lock().unwrap();
        if st.gen != gen {
            drop(st);
            let mut child = child;
            let _ = child.kill();
            return Ok(());
        }
        st.child = Some(child);
    }

    let mut need_code = false;
    let mut failure: Option<String> = None;
    let mut last_pct = String::new();
    let mut quiet_since_exit = 0;
    loop {
        thread::sleep(Duration::from_millis(700));
        if !current() {
            return Ok(()); // superseded by a newer attempt
        }
        if let Ok(mut f) = fs::File::open(&log) {
            use std::io::{Seek, SeekFrom};
            let len = f.metadata().map(|m| m.len()).unwrap_or(0);
            if len < pos {
                pos = 0;
            }
            if len > pos {
                let _ = f.seek(SeekFrom::Start(pos));
                let mut raw = Vec::new();
                let _ = f.read_to_end(&mut raw);
                pos = len;
                for l in String::from_utf8_lossy(&raw).lines() {
                    let text = l.split_once("] ").map(|(_, r)| r).unwrap_or(l).trim();
                    if text.is_empty() || (!password.is_empty() && text.contains(password)) {
                        continue;
                    }
                    let low = text.to_lowercase();
                    if low.contains("progress:") {
                        if let Some(p) = low.split("progress:").nth(1).and_then(|r| r.split_whitespace().next()) {
                            emit(json!({ "event": "percent", "value": p }));
                            let whole = p.split('.').next().unwrap_or("").to_string();
                            if whole != last_pct {
                                last_pct = whole;
                                line(text);
                            }
                        }
                        continue;
                    }
                    line(text);
                    if low.contains("steam mobile app") || low.contains("confirm the login") {
                        emit(json!({ "event": "confirm_mobile" }));
                    }
                    if low.contains("logged in ok") || low.contains("waiting for user info...ok") {
                        emit(json!({ "event": "logged_in" }));
                    }
                    if low.contains("steam guard") || low.contains("two-factor") || low.contains("two factor") || low.contains("auth code") || low.contains("account logon denied") {
                        need_code = true;
                    }
                    if low.contains("invalid password") {
                        failure = Some("Steam rejected the account name or password.".into());
                    } else if low.contains("rate limit") {
                        failure = Some("Steam is rate-limiting sign-ins from this machine. Wait 30-60 minutes and try again.".into());
                    } else if low.contains("no subscription") {
                        failure = Some("This Steam account does not own Witchspire.".into());
                    } else if low.starts_with("error! app") {
                        failure = Some(text.to_string());
                    }
                }
            }
        }
        if let Ok(mut f) = fs::File::open(&clog) {
            use std::io::{Seek, SeekFrom};
            let len = f.metadata().map(|m| m.len()).unwrap_or(0);
            if len < cpos {
                cpos = 0;
            }
            if len > cpos {
                let _ = f.seek(SeekFrom::Start(cpos));
                let mut raw = Vec::new();
                let _ = f.read_to_end(&mut raw);
                cpos = len;
                let text = String::from_utf8_lossy(&raw).to_lowercase();
                if text.contains("need two-factor code") || text.contains("need steam guard") || text.contains("invalid login auth code") || text.contains("two-factor code mismatch") {
                    need_code = true;
                }
                if text.contains("waiting for confirmation") && !told_confirm {
                    told_confirm = true;
                    need_code = true;
                    emit(json!({ "event": "confirm_mobile" }));
                    line("Steam is waiting for this sign-in to be approved in the Steam mobile app.");
                }
            }
        }
        let running = {
            let mut st = steam.lock().unwrap();
            let alive = matches!(st.child.as_mut().map(|c| c.try_wait()), Some(Ok(None)));
            if !alive {
                st.child = None;
            }
            alive
        };
        if !running && steamcmd_count() == 0 {
            // One more pass over the log after the last process is gone.
            quiet_since_exit += 1;
            if quiet_since_exit >= 2 {
                break;
            }
        }
    }
    if is_game_dir(&game) {
        emit(json!({ "event": "done", "path": game.display().to_string(), "steamcmd": exe.display().to_string() }));
        return Ok(());
    }
    if need_code && failure.is_none() {
        emit(json!({ "event": "need_code", "retry": !guard.trim().is_empty() }));
        return Ok(());
    }
    Err(failure.unwrap_or_else(|| "SteamCMD finished without installing Witchspire (see the log above).".into()))
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
    let mod_root = game.join("WitchspireCoopMod");

    if FLAVOR == "server" {
        // Updating a running server: stop the service, then let the game server save and exit.
        stop_running_server(app, &mod_root);
    }
    if game_running(&game) {
        return Err("Witchspire (or a Witchspire server) is running. Close it and try again.".into());
    }

    step(app, "Copying files");
    // A new version brings its complete payload: drop the old one so removed patches do not linger.
    let _ = fs::remove_dir_all(mod_root.join("payload"));
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
        step(app, "Setting up automatic updates");
        let updater = mod_root.join("WSCoopUpdater.exe");
        replace_exe(&updater, UPDATER_EXE)?;
        fs::write(mod_root.join("client-version.txt"), env!("CARGO_PKG_VERSION")).map_err(|e| e.to_string())?;
        // Not fatal: the mod works without it, only the update offer in the main menu is missing.
        match register_update_protocol(&updater) {
            Ok(()) => progress(app, "The game will offer new mod versions at the main menu."),
            Err(e) => progress(app, &format!("Could not register the updater ({e}).")),
        }
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
        let _ = run_hidden("netsh", &["advfirewall", "firewall", "delete", "rule", "name=WSDS Live Map"]);
        run_hidden("netsh", &["advfirewall", "firewall", "add", "rule", "name=WSDS Live Map", "dir=in", "action=allow", "protocol=TCP", &format!("localport={game_port}")]).map_err(|e| e.to_string())?;
        progress(app, &format!("Allowed TCP {game_port} (live map on wsdsmaps.com)."));
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
             $s = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -Priority 4;\
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
                let _ = run_hidden("netsh", &["advfirewall", "firewall", "delete", "rule", "name=WSDS Live Map"]);
                let _ = ps("foreach ($d in @([Environment]::GetFolderPath('CommonDesktopDirectory'), [Environment]::GetFolderPath('CommonPrograms'))) { Remove-Item (Join-Path $d 'WSDS.lnk') -ErrorAction SilentlyContinue }");
                thread::sleep(Duration::from_secs(3));
            }
            if FLAVOR == "server" {
                stop_running_server(&app, &mod_root);
            }
            if game_running(&game) {
                return Err("Witchspire is running. Close it and try again.".into());
            }
            step(&app, "Restoring the original game files");
            let out = run_hidden("powershell", &["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", &mod_root.join("Uninstall.ps1").to_string_lossy()]).map_err(|e| e.to_string())?;
            for line in String::from_utf8_lossy(&out.stdout).lines() {
                if !line.trim().is_empty() {
                    progress(&app, line.trim());
                }
            }
            if FLAVOR == "client" {
                unregister_update_protocol(&mod_root);
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

/// Stops the WSDS background service and asks a running game server to save and exit (as WSDS does),
/// forcing it only if it has not exited after two minutes.
fn stop_running_server(app: &AppHandle, mod_root: &Path) {
    let game = mod_root.parent().map(Path::to_path_buf).unwrap_or_default();
    let _ = ps("Stop-ScheduledTask -TaskName 'WSDS' -ErrorAction SilentlyContinue; Get-Process WSDS -ErrorAction SilentlyContinue | Stop-Process -Force");
    thread::sleep(Duration::from_secs(2));
    if !game_running(&game) {
        return;
    }
    let cfg: Value = fs::read_to_string(mod_root.join("ServerConfig.json")).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or(json!({}));
    let data_dir = cfg["ServerDataDir"].as_str().unwrap_or("ServerData");
    let data = if Path::new(data_dir).is_absolute() { PathBuf::from(data_dir) } else { mod_root.join(data_dir) };
    let control = data.join("Saved").join("WSDS");
    let _ = fs::create_dir_all(&control);
    let _ = fs::write(control.join("shutdown.request"), b"");
    step(app, "Saving the world and stopping the running server");
    for _ in 0..120 {
        if !game_running(&game) {
            break;
        }
        thread::sleep(Duration::from_secs(1));
    }
    if game_running(&game) {
        progress(app, "The server did not stop within 2 minutes - forcing it to close.");
        for pid in running_pids(&game) {
            let _ = run_hidden("taskkill", &["/F", "/PID", &pid.to_string()]);
        }
        thread::sleep(Duration::from_secs(2));
    } else {
        progress(app, "Server saved and stopped.");
    }
    let _ = fs::remove_file(control.join("shutdown.request"));
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
    #[cfg(feature = "updater")]
    updater::main(tauri::generate_context!());
    #[cfg(not(feature = "updater"))]
    {
        ensure_webview2();
        tauri::Builder::default()
            .manage(SteamState::default())
            .invoke_handler(tauri::generate_handler![info, auto_mark, auto_done, detect_game, check_game, fonts, steamcmd_start, steamcmd_cancel, install, uninstall, launch, open_path])
            .run(tauri::generate_context!())
            .expect("error while running setup");
    }
}
