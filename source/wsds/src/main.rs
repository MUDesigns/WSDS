// WSDS - Witchspire Dedicated Server control panel.
//
// Modes
//   WSDS.exe                          window (manage the local server, or control remote servers)
//   WSDS.exe --headless               background service: runs the server + the remote-control API
//   WSDS.exe --set-remote-password P [--port N]   configure remote control (used by the installer)
//
// The game server is driven through files in <ServerData>/Saved/WSDS (see WSAdmin.as):
//   commands.txt + commands.ready (admin commands), save.request, shutdown.request.
//
// Remote control: HTTP/JSON on TCP (default 7780). Every request is signed:
//   X-WSDS-Auth: <unix ts>.<nonce>.<hex HMAC-SHA256(key, "<ts>\n<nonce>\n<body>")>
//   key = SHA256("<salt>:<password>")  (only the derived key is stored, never the password)
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use hmac::{Hmac, Mac};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, VecDeque};
use std::fs;
use std::io::{BufReader, Read, Seek, SeekFrom, Write};
use std::net::{TcpListener, TcpStream, ToSocketAddrs};
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, Manager, State};

const CREATE_NO_WINDOW: u32 = 0x0800_0000;
const VERSION: &str = "0.0.44";
const WITCHSPIRE_APP_ID: &str = "2679100";

// ================================================================ paths & config

fn find_mod_root() -> PathBuf {
    if let Ok(over) = std::env::var("WSDS_ROOT") {
        return PathBuf::from(over);
    }
    let exe = std::env::current_exe().unwrap_or_default();
    let mut dir = exe.parent().map(Path::to_path_buf).unwrap_or_default();
    for _ in 0..8 {
        if dir.join("ServerInstall.ps1").exists() {
            return dir;
        }
        match dir.parent() {
            Some(p) => dir = p.to_path_buf(),
            None => break,
        }
    }
    exe.parent().map(Path::to_path_buf).unwrap_or_default()
}

fn default_config() -> Value {
    json!({
        "SetupComplete": false,
        "WorldSlot": "DedicatedWorld",
        "WorldName": "Witchspire Dedicated Server",
        "Level": "L_StarterIsland",
        "Difficulty": 1,
        "AutoSaveSeconds": 300,
        "HeartbeatSeconds": 60,
        "Port": 7777,
        "MaxPlayers": 8,
        "Password": "",
        "ServerTickRate": 30,
        "AutoRestartOnCrash": true,
        "StartServerOnLaunch": false,
        "ConsoleVerbosity": "important",
        "ServerDataDir": "ServerData",
        "ExtraArgs": "",
        "RemoteControl": { "Enabled": false, "Port": 7780, "Salt": "", "Key": "" },
        "SteamCmd": { "Path": "", "User": "" },
        "AutoUpdate": { "Enabled": true, "CheckHours": 6, "OnlyWhenEmpty": true, "Repo": "MUDesigns/WSDS", "LastApplied": "" },
        "Gameplay": {
            "ExperienceMultiplier": 1.0,
            "FamiliarExperienceMultiplier": 0.8,
            "SkillXPRate": 1.0,
            "ShareExperience": true,
            "DayNightTimescale": 1.0
        },
        "Coop": {
            "InstancedLoot": true,
            "InstancedLootRange": 6000,
            "InstancedHarvest": true,
            "SharedObjectives": true,
            "RetroactiveMilestones": true,
            "CatchUpXP": true,
            "CatchUpMaxMultiplier": 2.5,
            "CatchUpPerLevel": 0.15,
            "CoOwnerPermissions": "AllPlayers",
            "Admins": "",
            "CovenSynergy": true,
            "CovenRange": 5000,
            "CovenBonusPerMember": 0.1,
            "CovenSkillShare": 0.25
        }
    })
}

fn merge_defaults(target: &mut Value, defaults: &Value) {
    if let (Some(t), Some(d)) = (target.as_object_mut(), defaults.as_object()) {
        for (k, dv) in d {
            match t.get_mut(k) {
                Some(tv) if tv.is_object() && dv.is_object() => merge_defaults(tv, dv),
                Some(_) => {}
                None => {
                    t.insert(k.clone(), dv.clone());
                }
            }
        }
    }
}

struct Paths {
    root: PathBuf,
}

impl Paths {
    fn config_file(&self) -> PathBuf {
        self.root.join("ServerConfig.json")
    }
    fn game_root(&self, cfg: &Value) -> PathBuf {
        if let Some(g) = cfg.get("GameRoot").and_then(Value::as_str).filter(|s| !s.is_empty()) {
            return PathBuf::from(g);
        }
        self.root.parent().map(Path::to_path_buf).unwrap_or_default()
    }
    fn data_dir(&self, cfg: &Value) -> PathBuf {
        let d = cfg.get("ServerDataDir").and_then(Value::as_str).unwrap_or("ServerData");
        let p = PathBuf::from(d);
        if p.is_absolute() {
            p
        } else {
            self.root.join(p)
        }
    }
    fn control_dir(&self, cfg: &Value) -> PathBuf {
        self.data_dir(cfg).join("Saved").join("WSDS")
    }
    fn bans_file(&self, cfg: &Value) -> PathBuf {
        self.data_dir(cfg).join("bans.json")
    }
}

fn load_config(paths: &Paths) -> Value {
    let mut cfg = fs::read_to_string(paths.config_file())
        .ok()
        .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        .unwrap_or_else(|| json!({}));
    let existed = cfg.as_object().map(|o| !o.is_empty()).unwrap_or(false);
    if existed && cfg.get("SetupComplete").is_none() {
        cfg["SetupComplete"] = json!(true);
    }
    merge_defaults(&mut cfg, &default_config());
    cfg
}

fn write_config(paths: &Paths, cfg: &Value) -> Result<(), String> {
    let mut cfg = cfg.clone();
    if let Some(o) = cfg.as_object_mut() {
        o.retain(|k, _| !k.starts_with('_'));
    }
    merge_defaults(&mut cfg, &default_config());
    fs::write(paths.config_file(), serde_json::to_string_pretty(&cfg).map_err(|e| e.to_string())?).map_err(|e| e.to_string())
}

fn now_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

// ================================================================ crypto helpers

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn unhex(s: &str) -> Option<Vec<u8>> {
    if s.len() % 2 != 0 {
        return None;
    }
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).ok()).collect()
}

fn random_hex(n: usize) -> String {
    let mut b = vec![0u8; n];
    let _ = getrandom::getrandom(&mut b);
    hex(&b)
}

fn derive_key(salt: &str, password: &str) -> String {
    hex(&Sha256::digest(format!("{salt}:{password}").as_bytes()))
}

fn sign(key_hex: &str, ts: u64, nonce: &str, body: &str) -> String {
    let key = unhex(key_hex).unwrap_or_default();
    let mut mac = Hmac::<Sha256>::new_from_slice(&key).expect("hmac key");
    mac.update(format!("{ts}\n{nonce}\n{body}").as_bytes());
    hex(&mac.finalize().into_bytes())
}

fn verify(key_hex: &str, ts: u64, nonce: &str, body: &str, sig_hex: &str) -> bool {
    let (Some(key), Some(sig)) = (unhex(key_hex), unhex(sig_hex)) else { return false };
    let Ok(mut mac) = Hmac::<Sha256>::new_from_slice(&key) else { return false };
    mac.update(format!("{ts}\n{nonce}\n{body}").as_bytes());
    mac.verify_slice(&sig).is_ok()
}

fn b64(data: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(data.len() * 4 / 3 + 4);
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

// ================================================================ shared state & event sink

#[derive(Clone)]
struct Sink(Option<AppHandle>);

impl Sink {
    fn emit(&self, event: &str, payload: Value) {
        if let Some(app) = &self.0 {
            let _ = app.emit(event, payload);
        }
    }
}

#[derive(Default)]
struct Inner {
    child: Option<Child>,
    status: String, // stopped | preparing | starting | running | stopping | updating
    started_at: Option<Instant>,
    stop_requested: bool,
    quick_crashes: u32,
    queue: VecDeque<String>,
    console: VecDeque<String>,
    console_total: u64,
    items: Vec<(String, String)>,
    pending_items: Vec<(String, String)>,
    items_ver: u64,
    bans_ver: u64,
    results: VecDeque<(u64, Value)>,
    results_total: u64,
    last_state: Option<Value>,
    generation: u64,
    nonces: HashMap<String, u64>,
    update_info: Option<Value>,
    update_busy: bool,
}

struct App {
    paths: Paths,
    inner: Mutex<Inner>,
    headless: bool,
}

type Shared = Arc<App>;

fn push_console(inner: &mut Inner, line: String) {
    inner.console.push_back(line);
    inner.console_total += 1;
    while inner.console.len() > 4000 {
        inner.console.pop_front();
    }
}

fn status_value(inner: &Inner) -> Value {
    json!({
        "status": inner.status,
        "uptime": inner.started_at.map(|t| t.elapsed().as_secs()).unwrap_or(0),
        "pid": inner.child.as_ref().map(|c| c.id()).unwrap_or(0),
    })
}

fn emit_status(sink: &Sink, s: &Shared) {
    let v = status_value(&s.inner.lock().unwrap());
    sink.emit("status", v);
}

fn set_status(sink: &Sink, s: &Shared, status: &str) {
    s.inner.lock().unwrap().status = status.to_string();
    emit_status(sink, s);
}

fn info(sink: &Sink, s: &Shared, msg: &str) {
    let line = format!("[WSDS] {msg}");
    push_console(&mut s.inner.lock().unwrap(), line.clone());
    sink.emit("log", json!([line]));
}

// ================================================================ server process

fn build_args(cfg: &Value, data_dir: &Path, log_file: &Path) -> Vec<String> {
    let get = |k: &str| cfg.get(k).cloned().unwrap_or(Value::Null);
    let s = |v: Value| match v {
        Value::String(x) => x,
        Value::Null => String::new(),
        other => other.to_string(),
    };
    let mut a = vec![
        "-nullrhi".into(),
        "-nosound".into(),
        "-unattended".into(),
        "-log".into(),
        format!("-abslog={}", log_file.display()),
        format!("-UserDir={}", data_dir.display()),
        "-LogCmds=global Log, LogWSDS Verbose, LogNet Log, LogOnline Log, LogEasyMultiSave Verbose, LogGameMode Verbose".into(),
        "-WSDedicated".into(),
        format!("-WSSlot={}", s(get("WorldSlot"))),
        format!("-WSWorldName={}", s(get("WorldName"))),
        format!("-WSLevel={}", s(get("Level"))),
        format!("-WSDifficulty={}", s(get("Difficulty"))),
        format!("-WSAutoSave={}", s(get("AutoSaveSeconds"))),
        format!("-WSHeartbeat={}", s(get("HeartbeatSeconds"))),
        format!("-Port={}", s(get("Port"))),
        format!("-WSTickRate={}", s(get("ServerTickRate"))),
        format!("-WSMaxPlayers={}", s(get("MaxPlayers"))),
    ];
    let pw = s(get("Password"));
    if !pw.is_empty() {
        a.push(format!("-WSPassword={pw}"));
    }
    if let Some(coop) = cfg.get("Coop").and_then(Value::as_object) {
        for (k, v) in coop {
            a.push(format!("-WSCoop_{k}={}", s(v.clone())));
        }
    }
    for part in s(get("ExtraArgs")).split_whitespace() {
        a.push(part.to_string());
    }
    a
}

fn gameplay_cvars(cfg: &Value) -> Vec<String> {
    let g = cfg.get("Gameplay").cloned().unwrap_or(json!({}));
    let num = |k: &str, d: f64| g.get(k).and_then(Value::as_f64).unwrap_or(d);
    let flag = |k: &str, d: bool| g.get(k).and_then(Value::as_bool).unwrap_or(d);
    vec![
        format!("Herc.Combat.ExperienceMultiplier {}", num("ExperienceMultiplier", 1.0)),
        format!("Herc.Combat.FamiliarExperienceMultiplier {}", num("FamiliarExperienceMultiplier", 0.8)),
        format!("Herc.Player.Skills.PlayerSkillsXPRate {}", num("SkillXPRate", 1.0)),
        format!("Herc.Combat.ShareExperience {}", if flag("ShareExperience", true) { 1 } else { 0 }),
        format!("Herc.Time.DayNightTimescale {}", num("DayNightTimescale", 1.0)),
    ]
}

fn powershell(script: &str) -> std::io::Result<std::process::Output> {
    Command::new("powershell").env_remove("PSModulePath")
        .args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script])
        .creation_flags(CREATE_NO_WINDOW)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
}

fn start_server(sink: Sink, s: Shared) -> Result<(), String> {
    {
        let mut inner = s.inner.lock().unwrap();
        if inner.child.is_some() || matches!(inner.status.as_str(), "preparing" | "updating") {
            return Err("The server is already running.".into());
        }
        inner.status = "preparing".into();
        inner.stop_requested = false;
        inner.generation += 1;
    }
    emit_status(&sink, &s);
    thread::spawn(move || {
        if let Err(e) = launch(&sink, &s) {
            info(&sink, &s, &format!("Could not start the server: {e}"));
            set_status(&sink, &s, "stopped");
        }
    });
    Ok(())
}

fn launch(sink: &Sink, s: &Shared) -> Result<(), String> {
    let cfg = load_config(&s.paths);
    let game = s.paths.game_root(&cfg);
    let root = &s.paths.root;
    if !game.join("Hercules/Binaries/Win64/Hercules-Win64-Shipping.exe").exists() {
        return Err(format!("Witchspire was not found at {}", game.display()));
    }

    info(sink, s, "Preparing server files (server mirror, config pak)...");
    let script = format!(
        ". '{}'; $exe = Update-ServerInstall -GameRoot '{}' -ModRoot '{}'; Write-Output \"EXE=$exe\"",
        root.join("ServerInstall.ps1").display(),
        game.display(),
        root.display()
    );
    let out = powershell(&script).map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(format!("server preparation failed: {}", String::from_utf8_lossy(&out.stderr).trim()));
    }
    let exe = String::from_utf8_lossy(&out.stdout)
        .lines()
        .find_map(|l| l.strip_prefix("EXE=").map(|p| PathBuf::from(p.trim())))
        .ok_or("server preparation did not report the server executable")?;

    let data = s.paths.data_dir(&cfg);
    let logs = data.join("Logs");
    let control = s.paths.control_dir(&cfg);
    fs::create_dir_all(&logs).ok();
    fs::create_dir_all(&control).ok();
    for f in ["save.request", "shutdown.request", "commands.ready"] {
        let _ = fs::remove_file(control.join(f));
    }
    cleanup_old_logs(&logs, 30);

    let log_file = logs.join(format!("server_{}.log", now_secs()));
    let args = build_args(&cfg, &data, &log_file);
    info(sink, s, &format!("Starting '{}' on UDP port {}", cfg["WorldName"].as_str().unwrap_or("server"), cfg["Port"]));
    let child = Command::new(&exe)
        .args(&args)
        .creation_flags(CREATE_NO_WINDOW)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("could not start {}: {e}", exe.display()))?;

    let gen;
    {
        let mut inner = s.inner.lock().unwrap();
        push_console(&mut inner, format!("[WSDS] Server process {} started; log {}", child.id(), log_file.display()));
        inner.child = Some(child);
        inner.status = "starting".into();
        inner.started_at = Some(Instant::now());
        inner.last_state = None;
        gen = inner.generation;
    }
    emit_status(sink, s);
    {
        let (sink, s) = (sink.clone(), s.clone());
        thread::spawn(move || tail_log(sink, s, log_file, gen));
    }
    {
        let (sink, s) = (sink.clone(), s.clone());
        thread::spawn(move || watch_exit(sink, s, gen));
    }
    Ok(())
}

fn cleanup_old_logs(dir: &Path, keep: usize) {
    if let Ok(rd) = fs::read_dir(dir) {
        let mut logs: Vec<_> = rd
            .flatten()
            .filter(|e| e.path().extension().map(|x| x == "log").unwrap_or(false))
            .filter(|e| e.file_name().to_string_lossy().starts_with("server_"))
            .filter_map(|e| e.metadata().ok().and_then(|m| m.modified().ok()).map(|t| (t, e.path())))
            .collect();
        logs.sort();
        while logs.len() > keep {
            let (_, p) = logs.remove(0);
            let _ = fs::remove_file(p);
        }
    }
}

fn watch_exit(sink: Sink, s: Shared, gen: u64) {
    loop {
        thread::sleep(Duration::from_millis(500));
        let mut inner = s.inner.lock().unwrap();
        if inner.generation != gen {
            return;
        }
        let exited = match inner.child.as_mut() {
            Some(c) => c.try_wait().ok().flatten().map(|st| st.code().unwrap_or(-1)),
            None => return,
        };
        let Some(code) = exited else { continue };
        inner.child = None;
        let ran = inner.started_at.map(|t| t.elapsed().as_secs()).unwrap_or(0);
        let stop_requested = inner.stop_requested;
        inner.status = "stopped".into();
        inner.last_state = Some(json!({ "players": [] }));
        drop(inner);
        info(&sink, &s, &format!("Server process exited (code {code}) after {ran}s"));
        emit_status(&sink, &s);
        sink.emit("state", json!({ "players": [] }));

        let cfg = load_config(&s.paths);
        let auto = cfg.get("AutoRestartOnCrash").and_then(Value::as_bool).unwrap_or(true);
        if stop_requested || !(auto || s.headless) {
            return;
        }
        let crashes = {
            let mut inner = s.inner.lock().unwrap();
            inner.quick_crashes = if ran < 90 { inner.quick_crashes + 1 } else { 0 };
            inner.quick_crashes
        };
        if crashes >= 3 {
            info(&sink, &s, "The server crashed 3 times in a row shortly after starting - not restarting. Check the console for errors.");
            return;
        }
        info(&sink, &s, "Unexpected exit - restarting in 10 seconds...");
        thread::sleep(Duration::from_secs(10));
        if s.inner.lock().unwrap().generation == gen {
            let _ = start_server(sink.clone(), s.clone());
        }
        return;
    }
}

fn request_stop(sink: &Sink, s: &Shared) -> Result<(), String> {
    let cfg = load_config(&s.paths);
    let control = s.paths.control_dir(&cfg);
    {
        let mut inner = s.inner.lock().unwrap();
        if inner.child.is_none() {
            return Err("The server is not running.".into());
        }
        inner.stop_requested = true;
        inner.status = "stopping".into();
    }
    emit_status(sink, s);
    fs::create_dir_all(&control).ok();
    fs::write(control.join("shutdown.request"), b"").map_err(|e| e.to_string())?;
    info(sink, s, "Graceful shutdown requested (saving world and players)...");
    let (sink2, s2) = (sink.clone(), s.clone());
    thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(90);
        while Instant::now() < deadline {
            thread::sleep(Duration::from_millis(500));
            if s2.inner.lock().unwrap().child.is_none() {
                let _ = fs::remove_file(control.join("shutdown.request"));
                return;
            }
        }
        info(&sink2, &s2, "The server did not exit within 90 seconds - forcing it to stop.");
        if let Some(c) = s2.inner.lock().unwrap().child.as_mut() {
            let _ = c.kill();
        }
        let _ = fs::remove_file(control.join("shutdown.request"));
    });
    Ok(())
}

fn wait_stopped(s: &Shared, secs: u64) -> bool {
    let deadline = Instant::now() + Duration::from_secs(secs);
    while Instant::now() < deadline {
        if s.inner.lock().unwrap().child.is_none() {
            return true;
        }
        thread::sleep(Duration::from_millis(500));
    }
    false
}

/// SteamCMD game update followed by re-applying the mod (game updates revert edited scripts).
fn update_game(sink: Sink, s: Shared) -> Result<(), String> {
    let cfg = load_config(&s.paths);
    let steamcmd = cfg["SteamCmd"]["Path"].as_str().unwrap_or("").to_string();
    let user = cfg["SteamCmd"]["User"].as_str().unwrap_or("").to_string();
    if steamcmd.is_empty() || !Path::new(&steamcmd).exists() || user.is_empty() {
        return Err("SteamCMD is not configured on this server (it is set up by WSDS Setup).".into());
    }
    let was_running = s.inner.lock().unwrap().child.is_some();
    thread::spawn(move || {
        if was_running {
            let _ = request_stop(&sink, &s);
            wait_stopped(&s, 120);
        }
        set_status(&sink, &s, "updating");
        let game = s.paths.game_root(&cfg);
        info(&sink, &s, "Updating Witchspire with SteamCMD (cached login)...");
        match Command::new(&steamcmd)
            .args(["+force_install_dir", &game.to_string_lossy(), "+login", &user, "+app_update", WITCHSPIRE_APP_ID, "+quit"])
            .creation_flags(CREATE_NO_WINDOW)
            .output()
        {
            Ok(o) => {
                let text = String::from_utf8_lossy(&o.stdout).to_string();
                let tail: Vec<&str> = text.lines().filter(|l| !l.trim().is_empty()).collect();
                for line in tail.iter().skip(tail.len().saturating_sub(8)) {
                    info(&sink, &s, &format!("steamcmd: {line}"));
                }
            }
            Err(e) => info(&sink, &s, &format!("SteamCMD failed to run: {e}")),
        }
        info(&sink, &s, "Re-applying the Co-op Overhaul mod...");
        let install = s.paths.root.join("Install.ps1");
        let ok = match Command::new("powershell").env_remove("PSModulePath")
            .args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", &install.to_string_lossy()])
            .creation_flags(CREATE_NO_WINDOW)
            .output()
        {
            Ok(o) => {
                for line in String::from_utf8_lossy(&o.stdout).lines().chain(String::from_utf8_lossy(&o.stderr).lines()) {
                    if !line.trim().is_empty() {
                        info(&sink, &s, line.trim());
                    }
                }
                o.status.success()
            }
            Err(e) => {
                info(&sink, &s, &format!("Install.ps1 failed to run: {e}"));
                false
            }
        };
        set_status(&sink, &s, "stopped");
        if !ok {
            info(&sink, &s, "The mod could not be fully re-applied - the server will not be started until the mod is updated.");
            return;
        }
        if was_running || s.headless {
            let _ = start_server(sink.clone(), s.clone());
        }
    });
    Ok(())
}

// ================================================================ self-update (GitHub releases)
//
// The latest GitHub release of AutoUpdate.Repo carries "WSDS-Server-Update-<version>.zip" (WSDS.exe, the
// scripts and the mod payload - no game files) and "SHA256SUMS.txt". The background service checks every
// AutoUpdate.CheckHours; when a newer version exists (and, with OnlyWhenEmpty, nobody is online) it
// downloads and verifies the package, saves and stops the server, installs it, swaps its own exe and
// restarts itself. The window only reports updates; "Update now" works from the window or remotely.

fn version_parts(v: &str) -> Vec<u64> {
    v.trim().trim_start_matches(['v', 'V']).split(['.', '-', '+']).take(3).map(|p| p.parse().unwrap_or(0)).collect()
}

fn is_newer(candidate: &str, current: &str) -> bool {
    version_parts(candidate) > version_parts(current)
}

fn ps_quote(s: &str) -> String {
    s.replace('\'', "''")
}

/// Asks GitHub (or the WSDS_UPDATE_FEED test file) for the latest release.
fn check_update(s: &Shared) -> Result<Value, String> {
    let cfg = load_config(&s.paths);
    let repo = cfg["AutoUpdate"]["Repo"].as_str().unwrap_or("MUDesigns/WSDS").to_string();
    let script = match std::env::var("WSDS_UPDATE_FEED") {
        Ok(feed) => format!("Get-Content -Raw '{}'", ps_quote(&feed)),
        Err(_) => format!(
            "$ProgressPreference='SilentlyContinue'; [Net.ServicePointManager]::SecurityProtocol='Tls12'; (Invoke-WebRequest -UseBasicParsing -TimeoutSec 30 -Headers @{{'User-Agent'='WSDS/{VERSION}'; 'Accept'='application/vnd.github+json'}} 'https://api.github.com/repos/{}/releases/latest').Content",
            ps_quote(&repo)
        ),
    };
    let out = powershell(&script).map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(format!("could not reach GitHub: {}", String::from_utf8_lossy(&out.stderr).lines().next().unwrap_or("").trim()));
    }
    let release: Value = serde_json::from_slice(&out.stdout).map_err(|e| format!("unexpected answer from GitHub: {e}"))?;
    let version = release["tag_name"].as_str().unwrap_or("").trim_start_matches(['v', 'V']).to_string();
    let mut zip = String::new();
    let mut sums = String::new();
    for a in release["assets"].as_array().cloned().unwrap_or_default() {
        let name = a["name"].as_str().unwrap_or("");
        let url = a["browser_download_url"].as_str().unwrap_or("").to_string();
        if name.starts_with("WSDS-Server-Update-") && name.ends_with(".zip") {
            zip = url;
        } else if name == "SHA256SUMS.txt" {
            sums = url;
        }
    }
    let last = cfg["AutoUpdate"]["LastApplied"].as_str().unwrap_or("").to_string();
    let available = !version.is_empty() && !zip.is_empty() && !sums.is_empty() && is_newer(&version, VERSION) && version != last;
    let info = json!({
        "current": VERSION, "version": version, "available": available, "zip": zip, "sums": sums,
        "notes": release["body"].as_str().unwrap_or(""), "url": release["html_url"].as_str().unwrap_or(""),
        "checked": now_secs(),
    });
    s.inner.lock().unwrap().update_info = Some(info.clone());
    Ok(info)
}

fn start_update(sink: Sink, s: Shared) -> Result<(), String> {
    let info = s.inner.lock().unwrap().update_info.clone().ok_or("Check for updates first.")?;
    if info["available"].as_bool() != Some(true) {
        return Err(format!("WSDS {VERSION} is up to date."));
    }
    {
        let mut inner = s.inner.lock().unwrap();
        if inner.update_busy {
            return Err("An update is already running.".into());
        }
        inner.update_busy = true;
    }
    thread::spawn(move || {
        if let Err(e) = apply_update(&sink, &s, &info) {
            info_line(&sink, &s, &format!("Update failed: {e}"));
            s.inner.lock().unwrap().update_busy = false;
            // Do not leave the world offline because of a failed update.
            if s.inner.lock().unwrap().child.is_none() {
                set_status(&sink, &s, "stopped");
            }
            if s.inner.lock().unwrap().child.is_none() && s.headless {
                let _ = start_server(sink.clone(), s.clone());
            }
        }
    });
    Ok(())
}

fn info_line(sink: &Sink, s: &Shared, msg: &str) {
    info(sink, s, msg);
}

fn apply_update(sink: &Sink, s: &Shared, info_v: &Value) -> Result<(), String> {
    let version = info_v["version"].as_str().unwrap_or("").to_string();
    let zip_url = info_v["zip"].as_str().unwrap_or("").to_string();
    let sums_url = info_v["sums"].as_str().unwrap_or("").to_string();
    let work = std::env::temp_dir().join(format!("wsds-update-{version}"));
    let _ = fs::remove_dir_all(&work);
    fs::create_dir_all(&work).map_err(|e| e.to_string())?;
    let zip_name = zip_url.rsplit(['/', '\\']).next().unwrap_or("update.zip").to_string();

    info(sink, s, &format!("Downloading WSDS {version} ({zip_name})..."));
    let fetch = |url: &str, dest: &Path| -> String {
        if url.starts_with("http://") || url.starts_with("https://") {
            format!("Invoke-WebRequest -UseBasicParsing -TimeoutSec 300 -Headers @{{'User-Agent'='WSDS/{VERSION}'}} '{}' -OutFile '{}'", ps_quote(url), ps_quote(&dest.to_string_lossy()))
        } else {
            format!("Copy-Item -LiteralPath '{}' -Destination '{}' -Force", ps_quote(url), ps_quote(&dest.to_string_lossy()))
        }
    };
    let zip_path = work.join(&zip_name);
    let sums_path = work.join("SHA256SUMS.txt");
    let extract = work.join("files");
    let script = format!(
        "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; [Net.ServicePointManager]::SecurityProtocol='Tls12';\
         {}; {};\
         $sha = [Security.Cryptography.SHA256]::Create(); $fs = [IO.File]::OpenRead('{zip}'); $hash = ([BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-','').ToLower(); $fs.Dispose();\
         $line = Get-Content '{sums}' | Where-Object {{ $_ -match [regex]::Escape('{name}') }} | Select-Object -First 1;\
         if (-not $line) {{ throw 'the update is not listed in SHA256SUMS.txt' }};\
         $expected = ($line -split '\\s+')[0].ToLower();\
         if ($expected -ne $hash) {{ throw \"checksum mismatch (expected $expected, got $hash)\" }};\
         Expand-Archive -LiteralPath '{zip}' -DestinationPath '{ext}' -Force;\
         Write-Output \"VERIFIED $hash\"",
        fetch(&zip_url, &zip_path),
        fetch(&sums_url, &sums_path),
        zip = ps_quote(&zip_path.to_string_lossy()),
        sums = ps_quote(&sums_path.to_string_lossy()),
        name = ps_quote(&zip_name),
        ext = ps_quote(&extract.to_string_lossy()),
    );
    let out = powershell(&script).map_err(|e| e.to_string())?;
    let stdout = String::from_utf8_lossy(&out.stdout).to_string();
    if !out.status.success() || !stdout.contains("VERIFIED") {
        return Err(format!("download/verification failed: {}", String::from_utf8_lossy(&out.stderr).lines().find(|l| !l.trim().is_empty()).unwrap_or("").trim()));
    }
    info(sink, s, &format!("Package verified (SHA-256 {}).", stdout.trim().trim_start_matches("VERIFIED ").chars().take(16).collect::<String>()));
    let package = extract.join("WitchspireCoopMod");
    if !package.join("Install.ps1").exists() {
        return Err("the update package does not contain WitchspireCoopMod\\Install.ps1".into());
    }

    // Stop the server (saves the world and every player).
    let was_running = s.inner.lock().unwrap().child.is_some();
    if was_running {
        info(sink, s, "Saving the world and stopping the server for the update...");
        let _ = request_stop(sink, s);
        if !wait_stopped(s, 150) {
            return Err("the server did not stop".into());
        }
    }
    set_status(sink, s, "updating");

    // Copy everything except settings, world data and WSDS.exe (swapped below).
    let root = s.paths.root.clone();
    let copy = format!(
        "Remove-Item -Recurse -Force -LiteralPath (Join-Path '{1}' 'payload') -ErrorAction SilentlyContinue; robocopy '{0}' '{1}' /E /XF ServerConfig.json WSDS.exe /XD ServerData ServerInstall backup /NFL /NDL /NJH /NJS /NP | Out-Null; if ($LASTEXITCODE -ge 8) {{ throw \"robocopy failed ($LASTEXITCODE)\" }}; exit 0",
        ps_quote(&package.to_string_lossy()),
        ps_quote(&root.to_string_lossy())
    );
    let out = powershell(&copy).map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(format!("copying the update failed (exit {:?}): {}", out.status.code(), String::from_utf8_lossy(&out.stderr).trim()));
    }
    info(sink, s, "Files updated. Applying the Co-op Overhaul mod...");
    let out = Command::new("powershell")
        .env_remove("PSModulePath")
        .args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", &root.join("Install.ps1").to_string_lossy()])
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .map_err(|e| e.to_string())?;
    for line in String::from_utf8_lossy(&out.stdout).lines().chain(String::from_utf8_lossy(&out.stderr).lines()) {
        let l = line.trim();
        if !l.is_empty() && !l.starts_with("up to date") {
            info(sink, s, l);
        }
    }
    let mod_ok = out.status.success();

    // Never apply the same version twice, even if something below fails.
    let mut cfg = load_config(&s.paths);
    cfg["AutoUpdate"]["LastApplied"] = json!(version);
    let _ = write_config(&s.paths, &cfg);

    // Swap our own executable: a running exe can be renamed, then the new one takes its name.
    let new_exe = package.join("WSDS.exe");
    let current = std::env::current_exe().map_err(|e| e.to_string())?;
    let mut swapped = false;
    if new_exe.exists() {
        let old = current.with_file_name("WSDS.old.exe");
        let _ = fs::remove_file(&old);
        if fs::rename(&current, &old).is_ok() {
            if fs::copy(&new_exe, &current).is_ok() {
                swapped = true;
            } else {
                let _ = fs::rename(&old, &current);
            }
        }
    }
    if !mod_ok {
        info(sink, s, "The mod could not be applied to this game version - the server keeps running the previous mod files. A game update through SteamCMD may be needed.");
    }
    if swapped {
        info(sink, s, &format!("WSDS {version} installed - restarting WSDS..."));
        thread::sleep(Duration::from_secs(3)); // let the service log catch up
        let args: Vec<String> = std::env::args().skip(1).collect();
        let mut cmd = Command::new(&current);
        cmd.args(&args).current_dir(&root);
        if s.headless {
            cmd.creation_flags(CREATE_NO_WINDOW);
        }
        cmd.spawn().map_err(|e| format!("could not restart WSDS: {e}"))?;
        thread::sleep(Duration::from_millis(500));
        std::process::exit(0);
    }
    info(sink, s, "Update installed (WSDS itself was not replaced).");
    s.inner.lock().unwrap().update_busy = false;
    set_status(sink, s, "stopped");
    if was_running || s.headless {
        let _ = start_server(sink.clone(), s.clone());
    }
    Ok(())
}

fn players_online(s: &Shared) -> usize {
    let inner = s.inner.lock().unwrap();
    if inner.child.is_none() {
        return 0;
    }
    inner.last_state.as_ref().and_then(|st| st["players"].as_array().map(|a| a.len())).unwrap_or(0)
}

/// Background checks. The service installs updates by itself; the window only reports them.
fn update_loop(sink: Sink, s: Shared) {
    // Clean up after a previous self-update.
    if let Ok(cur) = std::env::current_exe() {
        let old = cur.with_file_name("WSDS.old.exe");
        for _ in 0..10 {
            if !old.exists() || fs::remove_file(&old).is_ok() {
                break;
            }
            thread::sleep(Duration::from_secs(2));
        }
    }
    thread::sleep(Duration::from_secs(90));
    let mut announced = String::new();
    loop {
        let cfg = load_config(&s.paths);
        let au = &cfg["AutoUpdate"];
        let hours = au["CheckHours"].as_f64().unwrap_or(6.0).clamp(0.25, 168.0);
        if au["Enabled"].as_bool().unwrap_or(true) {
            match check_update(&s) {
                Ok(info_v) if info_v["available"].as_bool() == Some(true) => {
                    let v = info_v["version"].as_str().unwrap_or("").to_string();
                    if announced != v {
                        info(&sink, &s, &format!("WSDS {v} is available (this is {VERSION})."));
                        announced = v.clone();
                    }
                    if s.headless {
                        let only_empty = au["OnlyWhenEmpty"].as_bool().unwrap_or(true);
                        // Wait for an empty server (re-checking every minute), then update.
                        loop {
                            if !only_empty || players_online(&s) == 0 {
                                let _ = start_update(sink.clone(), s.clone());
                                break;
                            }
                            thread::sleep(Duration::from_secs(60));
                        }
                    }
                }
                Ok(_) => {}
                Err(e) => info(&sink, &s, &format!("Update check failed: {e}")),
            }
        }
        thread::sleep(Duration::from_secs((hours * 3600.0) as u64));
    }
}

// ================================================================ log tail & parsing

fn tail_log(sink: Sink, s: Shared, path: PathBuf, gen: u64) {
    let start = Instant::now();
    while !path.exists() {
        if start.elapsed() > Duration::from_secs(120) || s.inner.lock().unwrap().generation != gen {
            return;
        }
        thread::sleep(Duration::from_millis(300));
    }
    let Ok(file) = fs::File::open(&path) else { return };
    let mut reader = BufReader::new(file);
    let mut pos: u64 = 0;
    let mut partial = String::new();
    let mut ready_sent = false;
    loop {
        let running = {
            let inner = s.inner.lock().unwrap();
            inner.generation == gen && inner.child.is_some()
        };
        let mut batch: Vec<String> = Vec::new();
        let _ = reader.seek(SeekFrom::Start(pos));
        let mut buf = Vec::new();
        if reader.read_to_end(&mut buf).is_ok() && !buf.is_empty() {
            pos += buf.len() as u64;
            partial.push_str(&String::from_utf8_lossy(&buf));
            while let Some(nl) = partial.find('\n') {
                let line: String = partial[..nl].trim_end_matches('\r').to_string();
                partial.drain(..=nl);
                if handle_line(&sink, &s, &line, &mut ready_sent) {
                    batch.push(line);
                }
            }
        }
        if !batch.is_empty() {
            {
                let mut inner = s.inner.lock().unwrap();
                for l in &batch {
                    push_console(&mut inner, l.clone());
                }
            }
            sink.emit("log", json!(batch));
        }
        if !running {
            return;
        }
        thread::sleep(Duration::from_millis(250));
    }
}

fn handle_line(sink: &Sink, s: &Shared, line: &str, ready_sent: &mut bool) -> bool {
    if let Some(i) = line.find("[WSDS-STATE] ") {
        if let Ok(v) = serde_json::from_str::<Value>(&line[i + 13..]) {
            s.inner.lock().unwrap().last_state = Some(v.clone());
            sink.emit("state", v);
        }
        return false;
    }
    if let Some(i) = line.find("[WSDS-ITEM] ") {
        if let Some((tag, name)) = line[i + 12..].split_once('|') {
            s.inner.lock().unwrap().pending_items.push((tag.to_string(), name.to_string()));
        }
        return false;
    }
    if let Some(i) = line.find("[WSDS-RESULT] ") {
        if let Ok(v) = serde_json::from_str::<Value>(&line[i + 14..]) {
            if v["cmd"] == "items" {
                let items = {
                    let mut inner = s.inner.lock().unwrap();
                    let mut items = std::mem::take(&mut inner.pending_items);
                    items.sort_by(|a, b| a.1.to_lowercase().cmp(&b.1.to_lowercase()));
                    inner.items = items.clone();
                    inner.items_ver += 1;
                    items
                };
                sink.emit("items", json!(items.iter().map(|(t, n)| json!({ "tag": t, "name": n })).collect::<Vec<_>>()));
                return false;
            }
            {
                let mut inner = s.inner.lock().unwrap();
                inner.results_total += 1;
                let n = inner.results_total;
                inner.results.push_back((n, v.clone()));
                while inner.results.len() > 100 {
                    inner.results.pop_front();
                }
            }
            sink.emit("result", v);
        }
        return true;
    }
    if let Some(i) = line.find("[WSDS-EVENT] ") {
        if let Ok(v) = serde_json::from_str::<Value>(&line[i + 13..]) {
            handle_event(sink, s, &v);
        }
        return true;
    }
    if !*ready_sent && line.contains("[WSDS] Priming world replication") {
        *ready_sent = true;
        on_server_ready(sink, s);
    }
    true
}

fn on_server_ready(sink: &Sink, s: &Shared) {
    set_status(sink, s, "running");
    let cfg = load_config(&s.paths);
    {
        let mut inner = s.inner.lock().unwrap();
        inner.queue.push_front(format!("__cvars__ {}", gameplay_cvars(&cfg).join(";")));
        for b in load_bans(&s.paths, &cfg) {
            if let Some(k) = b["key"].as_str() {
                inner.queue.push_back(format!("bankey {k}"));
            }
        }
        inner.queue.push_back("items".into());
    }
    info(sink, s, "Server is up - applying bans, gameplay settings and loading the item catalogue.");
}

fn load_bans(paths: &Paths, cfg: &Value) -> Vec<Value> {
    fs::read_to_string(paths.bans_file(cfg))
        .ok()
        .and_then(|t| serde_json::from_str::<Vec<Value>>(&t).ok())
        .unwrap_or_default()
}

fn save_bans(s: &Shared, cfg: &Value, bans: &[Value]) {
    let _ = fs::create_dir_all(s.paths.data_dir(cfg));
    let _ = fs::write(s.paths.bans_file(cfg), serde_json::to_string_pretty(bans).unwrap_or_default());
    s.inner.lock().unwrap().bans_ver += 1;
}

fn handle_event(sink: &Sink, s: &Shared, v: &Value) {
    let cfg = load_config(&s.paths);
    let mut bans = load_bans(&s.paths, &cfg);
    match v["type"].as_str().unwrap_or("") {
        "ban" => {
            let key = v["key"].as_str().unwrap_or("").to_string();
            bans.retain(|b| b["key"].as_str() != Some(&key));
            bans.push(json!({ "key": key, "name": v["name"], "reason": v["detail"], "time": now_secs() }));
            save_bans(s, &cfg, &bans);
        }
        "unban" => {
            let key = v["key"].as_str().unwrap_or("");
            bans.retain(|b| b["key"].as_str() != Some(key));
            save_bans(s, &cfg, &bans);
        }
        _ => return,
    }
    sink.emit("bans", json!(load_bans(&s.paths, &cfg)));
}

// ================================================================ admin command channel

fn command_pump(sink: Sink, s: Shared) {
    loop {
        thread::sleep(Duration::from_millis(400));
        let batch = {
            let mut inner = s.inner.lock().unwrap();
            if inner.child.is_none() || inner.status != "running" || inner.queue.is_empty() {
                continue;
            }
            let mut b = Vec::new();
            while b.len() < 10 {
                match inner.queue.pop_front() {
                    Some(c) => b.push(c),
                    None => break,
                }
            }
            b
        };
        let cfg = load_config(&s.paths);
        let control = s.paths.control_dir(&cfg);
        let _ = fs::create_dir_all(&control);
        let mut text = String::new();
        let mut n = 0;
        for c in &batch {
            if let Some(cvars) = c.strip_prefix("__cvars__ ") {
                for cv in cvars.split(';').filter(|x| !x.trim().is_empty()) {
                    text.push_str(cv.trim());
                    text.push_str("\r\n");
                }
                continue;
            }
            text.push_str(&format!("wsds.c{n} \"{}\"\r\n", c.replace('"', "'")));
            n += 1;
        }
        text.push_str(&format!("wsds.count {n}\r\n"));
        if fs::write(control.join("commands.txt"), text).is_err() {
            continue;
        }
        let _ = fs::write(control.join("commands.ready"), b"");
        thread::sleep(Duration::from_millis(1700));
        let _ = fs::remove_file(control.join("commands.ready"));
        thread::sleep(Duration::from_millis(1200));
        let len = s.inner.lock().unwrap().queue.len();
        sink.emit("queue", json!(len));
    }
}

// ================================================================ operations (window and network API)

fn op(sink: &Sink, s: &Shared, name: &str, args: &Value) -> Result<Value, String> {
    match name {
        "get_config" => {
            let cfg = load_config(&s.paths);
            let mut v = cfg.clone();
            // Never hand out the remote-control key.
            v["RemoteControl"]["Key"] = json!(if cfg["RemoteControl"]["Key"].as_str().unwrap_or("").is_empty() { "" } else { "set" });
            v["RemoteControl"]["Salt"] = json!("");
            v["_modRoot"] = json!(s.paths.root.display().to_string());
            v["_gameRoot"] = json!(s.paths.game_root(&cfg).display().to_string());
            v["_gameFound"] = json!(s.paths.game_root(&cfg).join("Hercules").exists());
            v["_autotest"] = json!(std::env::var("WSDS_AUTOTEST").is_ok());
            v["_startPage"] = json!(std::env::var("WSDS_START_PAGE").unwrap_or_default());
            v["_steamcmd"] = json!(!cfg["SteamCmd"]["Path"].as_str().unwrap_or("").is_empty());
            v["_headless"] = json!(s.headless);
            Ok(v)
        }
        "save_config" => {
            let old = load_config(&s.paths);
            let mut cfg = args.get("config").cloned().ok_or("missing config")?;
            // Secrets the UI never sees are kept as they are.
            cfg["RemoteControl"]["Key"] = old["RemoteControl"]["Key"].clone();
            cfg["RemoteControl"]["Salt"] = old["RemoteControl"]["Salt"].clone();
            cfg["SteamCmd"] = old["SteamCmd"].clone();
            write_config(&s.paths, &cfg).map(|_| json!(true))
        }
        "set_remote_password" => {
            let pw = args["password"].as_str().unwrap_or("");
            if pw.len() < 4 {
                return Err("Use a password of at least 4 characters.".into());
            }
            let mut cfg = load_config(&s.paths);
            let salt = random_hex(16);
            cfg["RemoteControl"]["Salt"] = json!(salt);
            cfg["RemoteControl"]["Key"] = json!(derive_key(&salt, pw));
            write_config(&s.paths, &cfg).map(|_| json!(true))
        }
        "list_worlds" => {
            let cfg = load_config(&s.paths);
            let dir = s.paths.data_dir(&cfg).join("Saved").join("SaveGames");
            let mut out: Vec<String> = fs::read_dir(dir)
                .map(|rd| rd.flatten().filter(|e| e.path().is_dir()).map(|e| e.file_name().to_string_lossy().to_string()).collect())
                .unwrap_or_default();
            out.sort();
            Ok(json!(out))
        }
        "server_start" => {
            s.inner.lock().unwrap().quick_crashes = 0;
            start_server(sink.clone(), s.clone()).map(|_| json!(true))
        }
        "server_stop" => request_stop(sink, s).map(|_| json!(true)),
        "server_restart" => {
            if s.inner.lock().unwrap().child.is_none() {
                return start_server(sink.clone(), s.clone()).map(|_| json!(true));
            }
            request_stop(sink, s)?;
            let (sink, s) = (sink.clone(), s.clone());
            thread::spawn(move || {
                if wait_stopped(&s, 100) {
                    thread::sleep(Duration::from_secs(2));
                    let _ = start_server(sink, s);
                }
            });
            Ok(json!(true))
        }
        "server_save" => {
            if s.inner.lock().unwrap().child.is_none() {
                return Err("The server is not running.".into());
            }
            s.inner.lock().unwrap().queue.push_back("save".into());
            info(sink, s, "Save requested.");
            Ok(json!(true))
        }
        "update_game" => update_game(sink.clone(), s.clone()).map(|_| json!(true)),
        "update_status" => {
            let inner = s.inner.lock().unwrap();
            Ok(json!({ "current": VERSION, "info": inner.update_info.clone(), "busy": inner.update_busy, "service": s.headless }))
        }
        "update_check" => check_update(s),
        "update_apply" => {
            if s.inner.lock().unwrap().update_info.is_none() {
                check_update(s)?;
            }
            start_update(sink.clone(), s.clone()).map(|_| json!(true))
        }
        "admin" => {
            let c = args["command"].as_str().unwrap_or("").trim().to_string();
            if c.is_empty() {
                return Err("empty command".into());
            }
            let mut inner = s.inner.lock().unwrap();
            if inner.child.is_none() || inner.status != "running" {
                return Err("The server is not running yet.".into());
            }
            inner.queue.push_back(c);
            Ok(json!(true))
        }
        "unban" => {
            let key = args["key"].as_str().unwrap_or("").to_string();
            let cfg = load_config(&s.paths);
            let mut bans = load_bans(&s.paths, &cfg);
            bans.retain(|b| b["key"].as_str() != Some(key.as_str()));
            save_bans(s, &cfg, &bans);
            if s.inner.lock().unwrap().child.is_some() {
                s.inner.lock().unwrap().queue.push_back(format!("unban {key}"));
            }
            sink.emit("bans", json!(bans));
            Ok(json!(true))
        }
        "snapshot" => {
            let cfg = load_config(&s.paths);
            let inner = s.inner.lock().unwrap();
            Ok(json!({
                "status": inner.status,
                "uptime": inner.started_at.map(|t| t.elapsed().as_secs()).unwrap_or(0),
                "console": inner.console.iter().rev().take(1500).rev().collect::<Vec<_>>(),
                "consoleNext": inner.console_total,
                "resultsNext": inner.results_total,
                "state": inner.last_state.clone().unwrap_or(json!({ "players": [] })),
                "items": inner.items.iter().map(|(t, n)| json!({ "tag": t, "name": n })).collect::<Vec<_>>(),
                "itemsVer": inner.items_ver,
                "bans": load_bans(&s.paths, &cfg),
                "bansVer": inner.bans_ver,
            }))
        }
        "poll" => {
            let since = args["since"].as_u64().unwrap_or(0);
            let rsince = args["resultsSince"].as_u64().unwrap_or(0);
            let inner = s.inner.lock().unwrap();
            let base = inner.console_total - inner.console.len() as u64;
            let start = since.max(base).min(inner.console_total);
            let lines: Vec<&String> = inner.console.iter().skip((start - base) as usize).take(2000).collect();
            let next = start + lines.len() as u64;
            let results: Vec<&Value> = inner.results.iter().filter(|(n, _)| *n > rsince).map(|(_, v)| v).collect();
            Ok(json!({
                "status": status_value(&inner),
                "lines": lines,
                "next": next,
                "results": results,
                "resultsNext": inner.results_total,
                "state": inner.last_state.clone().unwrap_or(json!({ "players": [] })),
                "itemsVer": inner.items_ver,
                "bansVer": inner.bans_ver,
            }))
        }
        "items" => {
            let inner = s.inner.lock().unwrap();
            Ok(json!(inner.items.iter().map(|(t, n)| json!({ "tag": t, "name": n })).collect::<Vec<_>>()))
        }
        "bans" => {
            let cfg = load_config(&s.paths);
            Ok(json!(load_bans(&s.paths, &cfg)))
        }
        _ => Err(format!("unknown operation '{name}'")),
    }
}

// ================================================================ remote-control server

fn http_response(stream: &mut TcpStream, code: u16, body: &Value) {
    let text = body.to_string();
    let reason = match code {
        200 => "OK",
        401 => "Unauthorized",
        404 => "Not Found",
        _ => "Error",
    };
    let _ = write!(stream, "HTTP/1.1 {code} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{text}", text.len());
}

fn read_request(stream: &mut TcpStream) -> Option<(String, String, HashMap<String, String>, String)> {
    stream.set_read_timeout(Some(Duration::from_secs(10))).ok()?;
    let mut buf = Vec::new();
    let mut tmp = [0u8; 4096];
    let header_end;
    loop {
        let n = stream.read(&mut tmp).ok()?;
        if n == 0 {
            return None;
        }
        buf.extend_from_slice(&tmp[..n]);
        if let Some(p) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            header_end = p + 4;
            break;
        }
        if buf.len() > 16 * 1024 {
            return None;
        }
    }
    let head = String::from_utf8_lossy(&buf[..header_end]).to_string();
    let mut lines = head.split("\r\n");
    let mut first = lines.next()?.split_whitespace();
    let method = first.next()?.to_string();
    let path = first.next()?.to_string();
    let mut headers = HashMap::new();
    for l in lines {
        if let Some((k, v)) = l.split_once(':') {
            headers.insert(k.trim().to_ascii_lowercase(), v.trim().to_string());
        }
    }
    let len: usize = headers.get("content-length").and_then(|v| v.parse().ok()).unwrap_or(0);
    if len > 1024 * 1024 {
        return None;
    }
    let mut body = buf[header_end..].to_vec();
    while body.len() < len {
        let n = stream.read(&mut tmp).ok()?;
        if n == 0 {
            break;
        }
        body.extend_from_slice(&tmp[..n]);
    }
    body.truncate(len);
    Some((method, path, headers, String::from_utf8_lossy(&body).to_string()))
}

fn authenticate(s: &Shared, key: &str, auth: &str, body: &str) -> bool {
    let parts: Vec<&str> = auth.split('.').collect();
    if key.is_empty() || parts.len() != 3 {
        return false;
    }
    let Ok(ts) = parts[0].parse::<u64>() else { return false };
    let now = now_secs();
    if ts + 120 < now || ts > now + 120 {
        return false;
    }
    if !verify(key, ts, parts[1], body, parts[2]) {
        return false;
    }
    let mut inner = s.inner.lock().unwrap();
    inner.nonces.retain(|_, t| *t + 300 > now);
    if inner.nonces.contains_key(parts[1]) {
        return false; // replay
    }
    inner.nonces.insert(parts[1].to_string(), now);
    true
}

fn handle_client(mut stream: TcpStream, sink: Sink, s: Shared) {
    let Some((method, path, headers, body)) = read_request(&mut stream) else { return };
    let cfg = load_config(&s.paths);
    if method == "GET" && path == "/api/hello" {
        http_response(&mut stream, 200, &json!({
            "app": "WSDS", "version": VERSION,
            "name": cfg["WorldName"], "salt": cfg["RemoteControl"]["Salt"],
        }));
        return;
    }
    if method != "POST" || path != "/api/op" {
        http_response(&mut stream, 404, &json!({ "error": "not found" }));
        return;
    }
    let key = cfg["RemoteControl"]["Key"].as_str().unwrap_or("").to_string();
    let auth = headers.get("x-wsds-auth").cloned().unwrap_or_default();
    if !authenticate(&s, &key, &auth, &body) {
        thread::sleep(Duration::from_millis(400)); // slow down guessing
        http_response(&mut stream, 401, &json!({ "error": "authentication failed" }));
        return;
    }
    let req: Value = serde_json::from_str(&body).unwrap_or(json!({}));
    let name = req["name"].as_str().unwrap_or("");
    let args = req.get("args").cloned().unwrap_or(json!({}));
    match op(&sink, &s, name, &args) {
        Ok(v) => http_response(&mut stream, 200, &json!({ "ok": true, "value": v })),
        Err(e) => http_response(&mut stream, 200, &json!({ "ok": false, "error": e })),
    }
}

fn start_control_server(sink: Sink, s: Shared) {
    let cfg = load_config(&s.paths);
    if !cfg["RemoteControl"]["Enabled"].as_bool().unwrap_or(false) {
        return;
    }
    let port = cfg["RemoteControl"]["Port"].as_u64().unwrap_or(7780);
    thread::spawn(move || {
        // Retry for a while: right after a self-update the previous WSDS may still hold the port.
        let mut bound = TcpListener::bind(("0.0.0.0", port as u16));
        for _ in 0..30 {
            if bound.is_ok() {
                break;
            }
            thread::sleep(Duration::from_secs(2));
            bound = TcpListener::bind(("0.0.0.0", port as u16));
        }
        match bound {
        Ok(listener) => {
            info(&sink, &s, &format!("Remote control listening on TCP port {port}"));
            for stream in listener.incoming().flatten() {
                let (sink, s) = (sink.clone(), s.clone());
                thread::spawn(move || handle_client(stream, sink, s));
            }
        }
        Err(e) => info(&sink, &s, &format!("Remote control could not listen on port {port}: {e}")),
        }
    });
}

// ================================================================ remote-control client

fn remotes_file() -> PathBuf {
    let base = std::env::var("APPDATA").map(PathBuf::from).unwrap_or_else(|_| std::env::temp_dir());
    base.join("WSDS").join("remotes.json")
}

fn load_remotes() -> Vec<Value> {
    fs::read_to_string(remotes_file()).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default()
}

fn save_remotes(r: &[Value]) {
    let f = remotes_file();
    if let Some(dir) = f.parent() {
        let _ = fs::create_dir_all(dir);
    }
    let _ = fs::write(f, serde_json::to_string_pretty(r).unwrap_or_default());
}

fn http_call(host: &str, port: u16, method: &str, path: &str, headers: &[(String, String)], body: &str) -> Result<(u16, String), String> {
    let addr = (host, port).to_socket_addrs().map_err(|e| format!("cannot resolve {host}: {e}"))?.next().ok_or("no address")?;
    let mut stream = TcpStream::connect_timeout(&addr, Duration::from_secs(5)).map_err(|e| format!("cannot reach {host}:{port} ({e})"))?;
    stream.set_read_timeout(Some(Duration::from_secs(20))).ok();
    let mut req = format!("{method} {path} HTTP/1.1\r\nHost: {host}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n", body.len());
    for (k, v) in headers {
        req.push_str(&format!("{k}: {v}\r\n"));
    }
    req.push_str("\r\n");
    req.push_str(body);
    stream.write_all(req.as_bytes()).map_err(|e| e.to_string())?;
    let mut resp = Vec::new();
    stream.read_to_end(&mut resp).map_err(|e| e.to_string())?;
    let text = String::from_utf8_lossy(&resp).to_string();
    let (head, body) = text.split_once("\r\n\r\n").ok_or("bad response")?;
    let code: u16 = head.split_whitespace().nth(1).and_then(|c| c.parse().ok()).unwrap_or(0);
    Ok((code, body.to_string()))
}

fn remote_target(s: &Shared, id: &str) -> Result<(String, u16, String), String> {
    if id == "local-service" {
        let cfg = load_config(&s.paths);
        let port = cfg["RemoteControl"]["Port"].as_u64().unwrap_or(7780) as u16;
        return Ok(("127.0.0.1".into(), port, cfg["RemoteControl"]["Key"].as_str().unwrap_or("").to_string()));
    }
    let r = load_remotes().into_iter().find(|r| r["id"] == id).ok_or("unknown remote server")?;
    Ok((r["host"].as_str().unwrap_or("").to_string(), r["port"].as_u64().unwrap_or(7780) as u16, r["key"].as_str().unwrap_or("").to_string()))
}

fn remote_op_raw(host: &str, port: u16, key: &str, name: &str, args: &Value) -> Result<Value, String> {
    let body = json!({ "name": name, "args": args }).to_string();
    let ts = now_secs();
    let nonce = random_hex(12);
    let sig = sign(key, ts, &nonce, &body);
    let (code, text) = http_call(host, port, "POST", "/api/op", &[("X-WSDS-Auth".into(), format!("{ts}.{nonce}.{sig}"))], &body)?;
    if code == 401 {
        return Err("Wrong remote-control password (or the server's clock is more than 2 minutes off).".into());
    }
    let v: Value = serde_json::from_str(&text).map_err(|_| format!("unexpected answer from the server (HTTP {code})"))?;
    if v["ok"].as_bool() == Some(true) {
        Ok(v["value"].clone())
    } else {
        Err(v["error"].as_str().unwrap_or("remote error").to_string())
    }
}

// ================================================================ tauri commands

#[tauri::command]
fn op_local(app: AppHandle, s: State<Shared>, name: String, args: Value) -> Result<Value, String> {
    op(&Sink(Some(app)), s.inner(), &name, &args)
}

#[tauri::command]
async fn op_remote(s: State<'_, Shared>, id: String, name: String, args: Value) -> Result<Value, String> {
    let (host, port, key) = remote_target(s.inner(), &id)?;
    tauri::async_runtime::spawn_blocking(move || remote_op_raw(&host, port, &key, &name, &args)).await.map_err(|e| e.to_string())?
}

#[tauri::command]
fn list_remotes() -> Vec<Value> {
    load_remotes()
        .into_iter()
        .map(|mut r| {
            if let Some(o) = r.as_object_mut() {
                o.remove("key");
            }
            r
        })
        .collect()
}

#[tauri::command]
async fn add_remote(name: String, host: String, port: u16, password: String) -> Result<Value, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let (code, text) = http_call(&host, port, "GET", "/api/hello", &[], "")?;
        let hello: Value = serde_json::from_str(&text).map_err(|_| format!("{host}:{port} is not a WSDS server (HTTP {code})"))?;
        if hello["app"] != "WSDS" {
            return Err(format!("{host}:{port} is not a WSDS server"));
        }
        let salt = hello["salt"].as_str().unwrap_or("");
        if salt.is_empty() {
            return Err("Remote control is not set up on that server (no password configured).".into());
        }
        let key = derive_key(salt, &password);
        remote_op_raw(&host, port, &key, "poll", &json!({ "since": 0 }))?; // verifies the password
        let display = if name.trim().is_empty() { hello["name"].as_str().unwrap_or(&host).to_string() } else { name };
        let id = random_hex(6);
        let mut remotes = load_remotes();
        remotes.retain(|r| !(r["host"] == host.as_str() && r["port"] == port));
        remotes.push(json!({ "id": id, "name": display, "host": host, "port": port, "key": key }));
        save_remotes(&remotes);
        Ok(json!({ "id": id, "name": display }))
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
fn remove_remote(id: String) {
    let mut remotes = load_remotes();
    remotes.retain(|r| r["id"] != id.as_str());
    save_remotes(&remotes);
}

/// True when a headless WSDS service runs on this machine (the window then attaches to it).
#[tauri::command]
async fn local_service(s: State<'_, Shared>) -> Result<bool, String> {
    let cfg = load_config(&s.paths);
    if !cfg["RemoteControl"]["Enabled"].as_bool().unwrap_or(false) || cfg["RemoteControl"]["Key"].as_str().unwrap_or("").is_empty() {
        return Ok(false);
    }
    let port = cfg["RemoteControl"]["Port"].as_u64().unwrap_or(7780) as u16;
    Ok(tauri::async_runtime::spawn_blocking(move || http_call("127.0.0.1", port, "GET", "/api/hello", &[], "").map(|(c, _)| c == 200).unwrap_or(false))
        .await
        .unwrap_or(false))
}

fn game_font(paths: &Paths, cfg: &Value, name: &str) -> Option<Vec<u8>> {
    let cache = paths.data_dir(cfg).join("ui-fonts");
    let cached = cache.join(format!("{name}.font"));
    if let Ok(b) = fs::read(&cached) {
        return Some(b);
    }
    let pak = paths.game_root(cfg).join("Hercules/Content/Paks/Hercules-Windows.pak");
    let out = Command::new(paths.root.join("tools/repak.exe"))
        .args(["get", &pak.to_string_lossy(), &format!("Hercules/Content/UserInterface/Fonts/{name}.ufont")])
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .ok()?;
    let raw = out.stdout;
    let start = if raw.len() > 8 && (&raw[4..8] == b"OTTO" || raw[4..8] == [0, 1, 0, 0]) { 4 } else { 0 };
    let bytes = raw[start..].to_vec();
    if bytes.len() < 1000 {
        return None;
    }
    let _ = fs::create_dir_all(&cache);
    let _ = fs::write(&cached, &bytes);
    Some(bytes)
}

#[tauri::command]
async fn fonts(s: State<'_, Shared>) -> Result<Value, String> {
    let shared = s.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        let cfg = load_config(&shared.paths);
        let mut out = json!({});
        for name in ["Griezly-Regular", "Lato-Regular", "Lato-Bold"] {
            if let Some(b) = game_font(&shared.paths, &cfg, name) {
                out[name] = json!(b64(&b));
            }
        }
        out
    })
    .await
    .map_err(|e| e.to_string())
}

#[tauri::command]
fn open_folder(s: State<Shared>, which: String) -> Result<(), String> {
    let cfg = load_config(&s.paths);
    let p = match which.as_str() {
        "data" => s.paths.data_dir(&cfg),
        "logs" => s.paths.data_dir(&cfg).join("Logs"),
        "saves" => s.paths.data_dir(&cfg).join("Saved").join("SaveGames"),
        _ => s.paths.root.clone(),
    };
    let _ = fs::create_dir_all(&p);
    Command::new("explorer").arg(p).spawn().map(|_| ()).map_err(|e| e.to_string())
}

// ================================================================ entry points

fn run_headless(shared: Shared) {
    let sink = Sink(None);
    {
        let (sink, s) = (sink.clone(), shared.clone());
        thread::spawn(move || command_pump(sink, s));
    }
    start_control_server(sink.clone(), shared.clone());
    {
        let (sink, s) = (sink.clone(), shared.clone());
        thread::spawn(move || update_loop(sink, s));
    }
    let _ = start_server(sink.clone(), shared.clone());
    // Mirror WSDS messages to a file so problems are visible without a window.
    let cfg = load_config(&shared.paths);
    let service_log = shared.paths.data_dir(&cfg).join("Logs").join("wsds-service.log");
    let _ = fs::create_dir_all(shared.paths.data_dir(&cfg).join("Logs"));
    let mut written: u64 = 0;
    loop {
        thread::sleep(Duration::from_secs(2));
        let lines: Vec<String> = {
            let inner = shared.inner.lock().unwrap();
            let base = inner.console_total - inner.console.len() as u64;
            let start = written.max(base);
            written = inner.console_total;
            inner.console.iter().skip((start - base) as usize).filter(|l| l.starts_with("[WSDS]")).cloned().collect()
        };
        if !lines.is_empty() {
            if let Ok(mut f) = fs::OpenOptions::new().create(true).append(true).open(&service_log) {
                for l in lines {
                    let _ = writeln!(f, "{} {l}", now_secs());
                }
            }
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let shared: Shared = Arc::new(App {
        paths: Paths { root: find_mod_root() },
        inner: Mutex::new(Inner { status: "stopped".into(), ..Default::default() }),
        headless: args.iter().any(|a| a == "--headless"),
    });

    // Installer helper: WSDS.exe --set-remote-password <pw> [--port N]
    if let Some(i) = args.iter().position(|a| a == "--set-remote-password") {
        let pw = args.get(i + 1).cloned().unwrap_or_default();
        let mut cfg = load_config(&shared.paths);
        let salt = random_hex(16);
        cfg["RemoteControl"]["Salt"] = json!(salt);
        cfg["RemoteControl"]["Key"] = json!(derive_key(&salt, &pw));
        cfg["RemoteControl"]["Enabled"] = json!(true);
        if let Some(p) = args.iter().position(|a| a == "--port").and_then(|j| args.get(j + 1)).and_then(|p| p.parse::<u64>().ok()) {
            cfg["RemoteControl"]["Port"] = json!(p);
        }
        std::process::exit(if write_config(&shared.paths, &cfg).is_ok() { 0 } else { 1 });
    }

    if shared.headless {
        run_headless(shared);
        return;
    }

    tauri::Builder::default()
        .manage(shared.clone())
        .invoke_handler(tauri::generate_handler![op_local, op_remote, list_remotes, add_remote, remove_remote, local_service, fonts, open_folder])
        .setup(move |app| {
            let sink = Sink(Some(app.handle().clone()));
            {
                let (sink, s) = (sink.clone(), shared.clone());
                thread::spawn(move || command_pump(sink, s));
            }
            {
                let (sink, s) = (sink.clone(), shared.clone());
                thread::spawn(move || loop {
                    thread::sleep(Duration::from_secs(1));
                    emit_status(&sink, &s);
                });
            }
            let cfg = load_config(&shared.paths);
            // When a background service owns this machine's server, the window only attaches to it.
            let service_owns_port = cfg["RemoteControl"]["Enabled"].as_bool().unwrap_or(false)
                && TcpStream::connect_timeout(&format!("127.0.0.1:{}", cfg["RemoteControl"]["Port"].as_u64().unwrap_or(7780)).parse().unwrap(), Duration::from_millis(300)).is_ok();
            if !service_owns_port {
                start_control_server(sink.clone(), shared.clone());
                {
                    let (sink, s) = (sink.clone(), shared.clone());
                    thread::spawn(move || update_loop(sink, s));
                }
                if cfg["SetupComplete"].as_bool().unwrap_or(false) && cfg["StartServerOnLaunch"].as_bool().unwrap_or(false) {
                    let _ = start_server(sink, shared.clone());
                }
            }
            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                let state: State<Shared> = window.state();
                let shared = state.inner().clone();
                if shared.inner.lock().unwrap().child.is_some() {
                    api.prevent_close();
                    let app = window.app_handle().clone();
                    let _ = app.emit("closing", true);
                    let sink = Sink(Some(app.clone()));
                    let _ = request_stop(&sink, &shared);
                    thread::spawn(move || {
                        wait_stopped(&shared, 100);
                        app.exit(0);
                    });
                }
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running WSDS");
}
