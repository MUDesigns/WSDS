// WSCoopUpdater.exe - keeps a player's Co-op Mod at the version of the latest GitHub release.
//
// It lives at <Witchspire>\WitchspireCoopMod\WSCoopUpdater.exe and is registered (per user) for the
// wscoop-update:// URL protocol by the player setup. The game's main menu opens:
//   wscoop-update://check   once per session: no window unless an update is available (and not put off)
//   wscoop-update://update  "Update now" after a server rejected the player for a version mismatch
// Started without arguments it shows its window, checks and offers the update.
//
// The release carries WSCoop-Client-Update-<version>.zip (entries under WitchspireCoopMod/) and
// SHA256SUMS.txt. Same approach as WSDS's self-updater: PowerShell downloads, SHA-256 verification, and a
// running exe is renamed (not deleted) to swap in a newer one.
//
// Test hooks: WSCOOP_UPDATE_FEED (local JSON file instead of the GitHub API answer; asset URLs may be
// file:// or plain paths), WSCOOP_UPDATER_AUTOTEST ("update" / "later": presses that button),
// WSCOOP_UPDATER_MARK (file the updater appends its states to), WSCOOP_UPDATER_CLOSE_WAIT (seconds),
// WSCOOP_UPDATER_TEST_IGNORE_HIDDEN (ignore Witchspire processes whose path is hidden, e.g. elevated servers).

use crate::{ensure_webview2, now_secs, ps, replace_exe, run_hidden, APP_ID};
use serde_json::{json, Value};
use std::ffi::c_void;
use std::fs;
use std::io::{Cursor, ErrorKind, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::Duration;
use tauri::{AppHandle, Emitter, WebviewUrl, WebviewWindowBuilder};

const VERSION: &str = env!("CARGO_PKG_VERSION");
const TITLE: &str = "Witchspire Co-op Mod Update";
const RELEASES: &str = "https://api.github.com/repos/MUDesigns/WSDS/releases/latest";
const ASSET_PREFIX: &str = "WSCoop-Client-Update-";
const PACKAGE_DIR: &str = "WitchspireCoopMod";
const LATER_SECS: u64 = 12 * 3600;

#[derive(Clone, Copy, PartialEq)]
enum Mode {
    Window,
    Check,
    Update,
}

struct Ctx {
    mode: Mode,
    game: PathBuf,
    mod_root: PathBuf,
    /// Restarted as administrator to finish an update.
    elevated_restart: bool,
}

static CTX: OnceLock<Ctx> = OnceLock::new();
static RELEASE: Mutex<Option<Value>> = Mutex::new(None);
static BUSY: AtomicBool = AtomicBool::new(false);

fn ctx() -> &'static Ctx {
    CTX.get().expect("updater context")
}

// ------------------------------------------------------------------ Win32

#[link(name = "kernel32")]
extern "system" {
    fn CreateMutexW(attrs: *const c_void, initial_owner: i32, name: *const u16) -> isize;
    fn GetLastError() -> u32;
    fn CloseHandle(h: isize) -> i32;
}

#[link(name = "user32")]
extern "system" {
    fn FindWindowW(class: *const u16, name: *const u16) -> isize;
    fn SetForegroundWindow(hwnd: isize) -> i32;
    fn ShowWindow(hwnd: isize, cmd: i32) -> i32;
    fn IsIconic(hwnd: isize) -> i32;
}

#[link(name = "shell32")]
extern "system" {
    fn ShellExecuteW(hwnd: isize, op: *const u16, file: *const u16, params: *const u16, dir: *const u16, show: i32) -> isize;
    fn IsUserAnAdmin() -> i32;
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

/// Holds a named mutex for the life of the process. `wait_secs` > 0 waits for an instance that is exiting.
fn single_instance(wait_secs: u64) -> bool {
    const ERROR_ALREADY_EXISTS: u32 = 183;
    let name = wide("Local\\WSCoopUpdater");
    let tries = wait_secs * 4;
    for i in 0..=tries {
        let h = unsafe { CreateMutexW(std::ptr::null(), 0, name.as_ptr()) };
        let err = unsafe { GetLastError() };
        if h != 0 && err != ERROR_ALREADY_EXISTS {
            return true; // the handle stays open until the process exits
        }
        if h != 0 {
            unsafe { CloseHandle(h) };
        }
        if i < tries {
            thread::sleep(Duration::from_millis(250));
        }
    }
    false
}

fn focus_existing() {
    let title = wide(TITLE);
    let h = unsafe { FindWindowW(std::ptr::null(), title.as_ptr()) };
    if h != 0 {
        unsafe {
            if IsIconic(h) != 0 {
                ShowWindow(h, 9); // SW_RESTORE
            }
            SetForegroundWindow(h);
        }
    }
}

fn is_elevated() -> bool {
    unsafe { IsUserAnAdmin() != 0 }
}

// ------------------------------------------------------------------ small helpers

fn ps_quote(s: &str) -> String {
    s.replace('\'', "''")
}

fn version_parts(v: &str) -> Vec<u64> {
    v.trim().trim_start_matches(['v', 'V']).split(['.', '-', '+']).take(3).map(|p| p.parse().unwrap_or(0)).collect()
}

fn is_newer(candidate: &str, current: &str) -> bool {
    version_parts(candidate) > version_parts(current)
}

/// Test hook: appends a state line to WSCOOP_UPDATER_MARK.
fn mark(label: &str) {
    if let Ok(f) = std::env::var("WSCOOP_UPDATER_MARK") {
        if let Ok(mut file) = fs::OpenOptions::new().create(true).append(true).open(f) {
            let _ = writeln!(file, "{label}");
        }
    }
}

fn installed_version(mod_root: &Path) -> String {
    fs::read_to_string(mod_root.join("client-version.txt"))
        .ok()
        .map(|t| t.trim().trim_start_matches('\u{feff}').to_string())
        .filter(|t| !t.is_empty())
        .unwrap_or_else(|| "0.0.0".into())
}

/// A server PC: WSDS updates the mod itself.
fn hosts_wsds(mod_root: &Path) -> bool {
    mod_root.join("WSDS.exe").exists()
}

fn state_dir() -> PathBuf {
    let base = std::env::var_os("LOCALAPPDATA").map(PathBuf::from).unwrap_or_else(std::env::temp_dir);
    base.join("WSCoopUpdater")
}

/// "Later": the silent check stays quiet about this version (for this game folder) for 12 hours.
fn set_later(version: &str) {
    let dir = state_dir();
    let _ = fs::create_dir_all(&dir);
    let rec = json!({ "game": ctx().game.display().to_string(), "version": version, "at": now_secs() });
    let _ = fs::write(dir.join("later.json"), rec.to_string());
}

fn put_off(version: &str) -> bool {
    let Some(rec) = fs::read_to_string(state_dir().join("later.json")).ok().and_then(|t| serde_json::from_str::<Value>(&t).ok()) else {
        return false;
    };
    let same_game = rec["game"].as_str().map(|g| g.eq_ignore_ascii_case(&ctx().game.display().to_string())).unwrap_or(false);
    let at = rec["at"].as_u64().unwrap_or(0);
    same_game && rec["version"].as_str() == Some(version) && now_secs().saturating_sub(at) < LATER_SECS
}

fn clear_later() {
    let _ = fs::remove_file(state_dir().join("later.json"));
}

fn cleanup_old_exes(dir: &Path) {
    if let Ok(rd) = fs::read_dir(dir) {
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().to_lowercase();
            if name.starts_with("wscoopupdater.old-") && name.ends_with(".exe") {
                let _ = fs::remove_file(e.path());
            }
        }
    }
}

/// False when Windows denies writing in `dir` (a game folder under Program Files, for example).
fn writable(dir: &Path) -> bool {
    if !dir.is_dir() {
        return true;
    }
    let probe = dir.join(format!(".wscoop-write-test-{}", std::process::id()));
    match fs::write(&probe, b"x") {
        Ok(()) => {
            let _ = fs::remove_file(&probe);
            true
        }
        Err(e) => e.kind() != ErrorKind::PermissionDenied,
    }
}

fn file_writable(f: &Path) -> bool {
    !f.exists() || fs::OpenOptions::new().write(true).open(f).map(|_| true).unwrap_or_else(|e| e.kind() != ErrorKind::PermissionDenied)
}

// ------------------------------------------------------------------ release check

fn fetch_release() -> Result<Value, String> {
    let text = match std::env::var("WSCOOP_UPDATE_FEED") {
        Ok(feed) => fs::read_to_string(&feed).map_err(|e| format!("{feed}: {e}"))?,
        Err(_) => {
            let script = format!(
                "$ProgressPreference='SilentlyContinue'; [Console]::OutputEncoding=[Text.Encoding]::UTF8; [Net.ServicePointManager]::SecurityProtocol='Tls12'; \
                 (Invoke-WebRequest -UseBasicParsing -TimeoutSec 20 -Headers @{{'User-Agent'='WSCoopUpdater/{VERSION}'; 'Accept'='application/vnd.github+json'}} '{RELEASES}').Content"
            );
            let out = run_hidden("powershell", &["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", &script]).map_err(|e| e.to_string())?;
            if !out.status.success() {
                let err = String::from_utf8_lossy(&out.stderr).lines().find(|l| !l.trim().is_empty()).unwrap_or("").trim().to_string();
                return Err(format!("could not reach GitHub ({err})"));
            }
            String::from_utf8_lossy(&out.stdout).to_string()
        }
    };
    serde_json::from_str(text.trim_start_matches('\u{feff}').trim()).map_err(|e| format!("unexpected answer from GitHub: {e}"))
}

fn check() -> Result<Value, String> {
    let installed = installed_version(&ctx().mod_root);
    let rel = fetch_release()?;
    let (mut zip, mut zip_name, mut sums, mut version) = (String::new(), String::new(), String::new(), String::new());
    for a in rel["assets"].as_array().cloned().unwrap_or_default() {
        let name = a["name"].as_str().unwrap_or("");
        let url = a["browser_download_url"].as_str().unwrap_or("").to_string();
        if name.starts_with(ASSET_PREFIX) && name.to_lowercase().ends_with(".zip") {
            version = name[ASSET_PREFIX.len()..name.len() - 4].to_string();
            zip = url;
            zip_name = name.to_string();
        } else if name == "SHA256SUMS.txt" {
            sums = url;
        }
    }
    if version.is_empty() {
        version = rel["tag_name"].as_str().unwrap_or("").trim_start_matches(['v', 'V']).to_string();
    }
    let available = !zip.is_empty() && !sums.is_empty() && is_newer(&version, &installed);
    let info = json!({
        "installed": installed, "version": version, "available": available,
        "zip": zip, "zipName": zip_name, "sums": sums,
        "notes": rel["body"].as_str().unwrap_or(""), "url": rel["html_url"].as_str().unwrap_or(""),
    });
    *RELEASE.lock().unwrap() = Some(info.clone());
    Ok(info)
}

// ------------------------------------------------------------------ update

enum Stop {
    NeedClose,
    NeedAdmin,
    Failed(String),
}

impl From<String> for Stop {
    fn from(e: String) -> Self {
        Stop::Failed(e)
    }
}

fn emit(app: &AppHandle, v: Value) {
    let _ = app.emit("upd", v);
}

fn step(app: &AppHandle, s: &str) {
    emit(app, json!({ "step": s }));
}

fn line(app: &AppHandle, s: &str) {
    emit(app, json!({ "line": s }));
}

/// file:///C:/x.zip, file://server/share/x.zip or a plain path -> local path.
fn local_path(url: &str) -> PathBuf {
    let decode = |s: &str| -> String {
        let b = s.as_bytes();
        let mut out = Vec::with_capacity(b.len());
        let mut i = 0;
        while i < b.len() {
            if b[i] == b'%' && i + 2 < b.len() {
                if let Some(v) = std::str::from_utf8(&b[i + 1..i + 3]).ok().and_then(|h| u8::from_str_radix(h, 16).ok()) {
                    out.push(v);
                    i += 3;
                    continue;
                }
            }
            out.push(b[i]);
            i += 1;
        }
        String::from_utf8_lossy(&out).to_string()
    };
    let lower = url.to_lowercase();
    if lower.starts_with("file:///") {
        PathBuf::from(decode(&url[8..]).replace('/', "\\"))
    } else if lower.starts_with("file://") {
        PathBuf::from(format!("\\\\{}", decode(&url[7..]).replace('/', "\\")))
    } else {
        PathBuf::from(url)
    }
}

fn download(url: &str, dest: &Path) -> Result<(), String> {
    let lower = url.to_lowercase();
    if lower.starts_with("https://") || lower.starts_with("http://") {
        ps(&format!(
            "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; [Net.ServicePointManager]::SecurityProtocol='Tls12'; \
             Invoke-WebRequest -UseBasicParsing -TimeoutSec 600 -Headers @{{'User-Agent'='WSCoopUpdater/{VERSION}'}} '{}' -OutFile '{}'",
            ps_quote(url),
            ps_quote(&dest.to_string_lossy())
        ))
        .map(|_| ())
        .map_err(|e| format!("download failed: {}", e.lines().next().unwrap_or("").trim()))
    } else {
        let src = local_path(url);
        fs::copy(&src, dest).map(|_| ()).map_err(|e| format!("{}: {e}", src.display()))
    }
}

fn sha256_file(path: &Path) -> Result<String, String> {
    let out = ps(&format!(
        "$sha=[Security.Cryptography.SHA256]::Create(); $fs=[IO.File]::OpenRead('{}'); try {{ ([BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-','').ToLower() }} finally {{ $fs.Dispose() }}",
        ps_quote(&path.to_string_lossy())
    ))?;
    let h = out.trim().to_lowercase();
    if h.len() == 64 && h.chars().all(|c| c.is_ascii_hexdigit()) {
        Ok(h)
    } else {
        Err(format!("could not hash {}: {h}", path.display()))
    }
}

/// The expected hash of `name` from a SHA256SUMS.txt ("<hash> *<name>" or "<hash>  <name>").
fn expected_hash(sums: &str, name: &str) -> Option<String> {
    sums.lines().find_map(|l| {
        let mut it = l.split_whitespace();
        let hash = it.next()?;
        let file = it.next()?.trim_start_matches('*');
        file.eq_ignore_ascii_case(name).then(|| hash.to_lowercase())
    })
}

/// Reads the whole package into memory (CRC-checked) before anything is changed. Every entry must sit under
/// WitchspireCoopMod/; returned paths are relative to the mod folder.
fn read_package(data: &[u8]) -> Result<Vec<(PathBuf, Vec<u8>)>, String> {
    let mut zip = zip::ZipArchive::new(Cursor::new(data)).map_err(|e| format!("the update package is damaged: {e}"))?;
    let mut files = Vec::new();
    for i in 0..zip.len() {
        let mut f = zip.by_index(i).map_err(|e| e.to_string())?;
        if f.is_dir() {
            continue;
        }
        let rel = f
            .enclosed_name()
            .and_then(|p| p.strip_prefix(PACKAGE_DIR).ok().map(Path::to_path_buf))
            .filter(|p| !p.as_os_str().is_empty())
            .ok_or_else(|| format!("unexpected entry in the update package: {}", f.name()))?;
        let mut buf = Vec::with_capacity(f.size() as usize);
        f.read_to_end(&mut buf).map_err(|e| format!("the update package is damaged ({}): {e}", f.name()))?;
        files.push((rel, buf));
    }
    if !files.iter().any(|(p, _)| p == Path::new("Install.ps1")) {
        return Err("the update package does not contain WitchspireCoopMod\\Install.ps1".into());
    }
    Ok(files)
}

/// Witchspire processes started from this game folder, and how many Witchspire processes hide their path
/// from us (run as administrator or as a service). Install.ps1 refuses while either kind runs (running_pids).
fn game_processes(game: &Path) -> (Vec<u32>, usize) {
    let mut root = game.display().to_string().replace('/', "\\");
    if !root.ends_with('\\') {
        root.push('\\');
    }
    let script = format!(
        "Get-Process Hercules-Win64-Shipping -ErrorAction SilentlyContinue | ForEach-Object {{ if (-not $_.Path) {{ 'hidden' }} elseif ($_.Path.StartsWith('{}', [StringComparison]::OrdinalIgnoreCase)) {{ $_.Id }} }}",
        ps_quote(&root)
    );
    let out = ps(&script).unwrap_or_default();
    let mine = out.lines().filter_map(|l| l.trim().parse().ok()).collect();
    // Test hook: this development PC runs other people's elevated servers.
    let hidden = if std::env::var_os("WSCOOP_UPDATER_TEST_IGNORE_HIDDEN").is_some() { 0 } else { out.lines().filter(|l| l.trim() == "hidden").count() };
    (mine, hidden)
}

/// Asks Witchspire (started from this game folder) to close like the player would; never kills it.
/// Only processes known to belong to this folder get the request.
fn close_game(app: &AppHandle) -> bool {
    let game = &ctx().game;
    let (mine, hidden) = game_processes(game);
    if mine.is_empty() && hidden == 0 {
        return true;
    }
    if !mine.is_empty() {
        step(app, "Closing Witchspire...");
        let list = mine.iter().map(|p| p.to_string()).collect::<Vec<_>>().join(",");
        let _ = ps(&format!("Get-Process -Id {list} -ErrorAction SilentlyContinue | ForEach-Object {{ [void]$_.CloseMainWindow() }}"));
        let wait: u64 = std::env::var("WSCOOP_UPDATER_CLOSE_WAIT").ok().and_then(|v| v.parse().ok()).unwrap_or(60);
        let start = std::time::Instant::now();
        loop {
            thread::sleep(Duration::from_secs(1));
            if game_processes(game).0.is_empty() {
                thread::sleep(Duration::from_secs(1)); // let the game release its files
                line(app, "Witchspire closed.");
                break;
            }
            if start.elapsed().as_secs() >= wait {
                return false;
            }
        }
    }
    // Witchspire started as administrator: we cannot ask it to close; the player has to.
    game_processes(game).1 == 0
}

fn apply(app: &AppHandle) -> Result<String, Stop> {
    let c = ctx();
    let info = RELEASE.lock().unwrap().clone().ok_or_else(|| "Check for updates first.".to_string())?;
    if hosts_wsds(&c.mod_root) {
        return Err(Stop::Failed("This PC hosts a WSDS server - WSDS updates the mod here.".into()));
    }
    if info["available"].as_bool() != Some(true) {
        return Err(Stop::Failed("The Co-op Mod is already up to date.".into()));
    }
    let version = info["version"].as_str().unwrap_or("").to_string();
    let zip_url = info["zip"].as_str().unwrap_or("");
    let sums_url = info["sums"].as_str().unwrap_or("");
    let zip_name = info["zipName"].as_str().unwrap_or("").to_string();

    // Rights first: a game folder under Program Files needs an administrator.
    let script_dir = c.game.join("Hercules").join("Script");
    if !writable(&c.mod_root) || !writable(&script_dir) || !file_writable(&c.mod_root.join("Install.ps1")) {
        if is_elevated() {
            return Err(Stop::Failed(format!("Windows does not allow changing files in {}.", c.game.display())));
        }
        return Err(Stop::NeedAdmin);
    }

    // 1. Download and verify while the game keeps running.
    step(app, &format!("Downloading version {version}..."));
    let work = std::env::temp_dir().join(format!("wscoop-update-{version}"));
    let _ = fs::remove_dir_all(&work);
    fs::create_dir_all(&work).map_err(|e| format!("{}: {e}", work.display()))?;
    let zip_path = work.join(&zip_name);
    let sums_path = work.join("SHA256SUMS.txt");
    download(zip_url, &zip_path)?;
    download(sums_url, &sums_path)?;
    step(app, "Verifying the download...");
    let sums = fs::read_to_string(&sums_path).map_err(|e| e.to_string())?;
    let expected = expected_hash(&sums, &zip_name).ok_or_else(|| format!("{zip_name} is not listed in SHA256SUMS.txt - nothing was changed."))?;
    let actual = sha256_file(&zip_path)?;
    if expected != actual {
        let _ = fs::remove_dir_all(&work);
        return Err(Stop::Failed(format!("The download is damaged or was tampered with (SHA-256 mismatch: expected {}..., got {}...). Nothing was changed.", &expected[..12], &actual[..12])));
    }
    line(app, &format!("SHA-256 verified ({}...).", &actual[..16]));
    let data = fs::read(&zip_path).map_err(|e| e.to_string())?;
    let files = read_package(&data)?;

    // 2. Witchspire must not run while its scripts change.
    if !close_game(app) {
        return Err(Stop::NeedClose);
    }

    // 3. Files. A new version brings its complete payload: drop the old one so removed patches do not linger.
    step(app, "Installing the new files...");
    let _ = fs::remove_dir_all(c.mod_root.join("payload"));
    let mut new_updater: Option<&[u8]> = None;
    let mut n = 0;
    for (rel, bytes) in &files {
        let name = rel.to_string_lossy().replace('/', "\\").to_lowercase();
        if name == "wscoopupdater.exe" {
            new_updater = Some(bytes);
            continue;
        }
        let out = c.mod_root.join(rel);
        // Never overwrite the player's settings; never touch a server's files.
        if (name == "clientconfig.json" && out.exists()) || name == "wsds.exe" || name == "serverconfig.json" {
            continue;
        }
        if let Some(parent) = out.parent() {
            fs::create_dir_all(parent).map_err(|e| format!("{}: {e}", parent.display()))?;
        }
        fs::write(&out, bytes).map_err(|e| format!("{}: {e}", out.display()))?;
        n += 1;
    }
    line(app, &format!("{n} files updated."));
    if let Some(bytes) = new_updater {
        match replace_exe(&c.mod_root.join("WSCoopUpdater.exe"), bytes) {
            Ok(true) => line(app, "The updater itself was updated."),
            Ok(false) => {}
            Err(e) => line(app, &format!("The updater could not replace itself ({e}).")),
        }
    }

    // 4. Apply the mod to the game scripts.
    step(app, "Applying the mod...");
    let out = run_hidden("powershell", &["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", &c.mod_root.join("Install.ps1").to_string_lossy()])
        .map_err(|e| format!("Install.ps1 could not start: {e}"))?;
    for l in String::from_utf8_lossy(&out.stdout).lines().chain(String::from_utf8_lossy(&out.stderr).lines()) {
        let l = l.trim();
        if !l.is_empty() {
            line(app, l);
        }
    }
    if !out.status.success() {
        return Err(Stop::Failed("The mod could not be applied to the game (see the log). Nothing in the game was changed.".into()));
    }
    fs::write(c.mod_root.join("client-version.txt"), &version).map_err(|e| e.to_string())?;
    clear_later();
    let _ = fs::remove_dir_all(&work);
    Ok(version)
}

// ------------------------------------------------------------------ commands

#[tauri::command]
fn upd_info() -> Value {
    let c = ctx();
    json!({
        "version": VERSION,
        "mode": match c.mode { Mode::Window => "window", Mode::Check => "check", Mode::Update => "update" },
        "installed": installed_version(&c.mod_root),
        "host": hosts_wsds(&c.mod_root),
        "game": c.game.display().to_string(),
        "prefetched": RELEASE.lock().unwrap().clone(),
        "elevatedRestart": c.elevated_restart,
        "autotest": std::env::var("WSCOOP_UPDATER_AUTOTEST").ok(),
    })
}

#[tauri::command]
async fn upd_check() -> Result<Value, String> {
    tauri::async_runtime::spawn_blocking(check).await.map_err(|e| e.to_string())?
}

#[tauri::command]
fn upd_update(app: AppHandle) -> Result<(), String> {
    if BUSY.swap(true, Ordering::SeqCst) {
        return Err("The update is already running.".into());
    }
    thread::spawn(move || {
        let r = apply(&app);
        BUSY.store(false, Ordering::SeqCst);
        emit(&app, match r {
            Ok(v) => json!({ "done": true, "version": v }),
            Err(Stop::NeedClose) => json!({ "needClose": true }),
            Err(Stop::NeedAdmin) => json!({ "needAdmin": true }),
            Err(Stop::Failed(e)) => json!({ "error": e }),
        });
    });
    Ok(())
}

#[tauri::command]
fn upd_later(version: String) {
    set_later(&version);
}

#[tauri::command]
fn upd_start_game() -> Result<(), String> {
    std::process::Command::new("explorer.exe").arg(format!("steam://rungameid/{APP_ID}")).spawn().map(|_| ()).map_err(|e| e.to_string())
}

/// Restarts the updater as administrator (UAC prompt) and lets it finish the update.
#[tauri::command]
async fn upd_elevate(app: AppHandle) -> Result<(), String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let (op, file, params, dir) = (wide("runas"), wide(&exe.to_string_lossy()), wide("wscoop-update://update --elevated"), wide(&ctx().mod_root.to_string_lossy()));
    let r = unsafe { ShellExecuteW(0, op.as_ptr(), file.as_ptr(), params.as_ptr(), dir.as_ptr(), 1) };
    if r <= 32 {
        return Err("The update was not started as administrator.".into());
    }
    app.exit(0);
    Ok(())
}

#[tauri::command]
fn upd_mark(label: String) {
    mark(&label);
}

#[tauri::command]
fn upd_exit(app: AppHandle, code: i32) {
    app.exit(code);
}

// ------------------------------------------------------------------ entry

pub fn main(mut context: tauri::Context<tauri::Wry>) {
    let mut mode = Mode::Window;
    let mut elevated_restart = false;
    for a in std::env::args().skip(1) {
        let l = a.trim().to_lowercase();
        if l == "--elevated" {
            elevated_restart = true;
        } else if let Some(rest) = l.strip_prefix("wscoop-update:") {
            // wscoop-update://check, wscoop-update:check/, wscoop-update://update/whatever?x=1 ...
            let action = rest.trim_start_matches('/').split(['/', '?', '#']).next().unwrap_or("");
            mode = match action {
                "check" => Mode::Check,
                "update" => Mode::Update,
                _ => Mode::Window,
            };
        }
    }
    let exe = std::env::current_exe().unwrap_or_default();
    let mod_root = exe.parent().map(Path::to_path_buf).unwrap_or_default();
    let game = mod_root.parent().map(Path::to_path_buf).unwrap_or_default();
    cleanup_old_exes(&mod_root);

    if !single_instance(if elevated_restart { 15 } else { 0 }) {
        if mode != Mode::Check {
            focus_existing();
        }
        mark("second-instance");
        return;
    }
    let _ = CTX.set(Ctx { mode, game, mod_root, elevated_restart });
    let c = ctx();

    if mode == Mode::Check {
        if hosts_wsds(&c.mod_root) {
            mark("silent-host");
            return;
        }
        match check() {
            Err(e) => {
                mark(&format!("silent-offline: {e}"));
                return;
            }
            Ok(info) if info["available"].as_bool() != Some(true) => {
                mark("silent-uptodate");
                return;
            }
            Ok(info) if put_off(info["version"].as_str().unwrap_or("")) => {
                mark("silent-later");
                return;
            }
            Ok(_) => mark("silent-offer"),
        }
    }

    ensure_webview2();
    // The setup's 900x640 window comes from tauri.conf.json; the updater builds its own compact one.
    context.config_mut().app.windows.clear();
    let data_dir = state_dir().join("WebView");
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![upd_info, upd_check, upd_update, upd_later, upd_start_game, upd_elevate, upd_mark, upd_exit, crate::fonts])
        .setup(move |app| {
            WebviewWindowBuilder::new(app, "main", WebviewUrl::App("updater.html".into()))
                .title(TITLE)
                .inner_size(460.0, 300.0)
                .resizable(false)
                .maximizable(false)
                .decorations(false)
                .always_on_top(true)
                .center()
                .focused(true)
                .background_color(tauri::window::Color(18, 12, 26, 255))
                .additional_browser_args("--disable-features=msWebOOUI,msPdfOOUI,msSmartScreenProtection --disable-gpu --renderer-process-limit=1")
                .data_directory(data_dir.clone())
                .build()?;
            Ok(())
        })
        .run(context)
        .expect("error while running the updater");
}
