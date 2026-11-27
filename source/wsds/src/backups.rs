// World backups.
//
// The game itself copies the world slot (world + every player's save) into <slot>\Backups\<yyyy-mm-dd_HH.mm.ss>
// every Herc.SaveGame.AutoSaveBackupFrequency autosaves, but never deletes old copies and cannot restore them.
// WSDS sets that interval (Backups.IntervalMinutes), keeps the newest Backups.Keep automatic copies, adds
// "Back up now", makes a copy before every restore and update, and restores a copy in one click (the server is
// saved and stopped, the current world is backed up, the copy is put in place and the server starts again).

use crate::{info, load_config, request_stop, start_server, wait_stopped, Shared, Sink, CREATE_NO_WINDOW};
use serde_json::{json, Value};
use std::fs;
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const KEEP_SPECIAL: usize = 10; // "before restore" / "before update" copies kept

pub fn slot_dir(s: &Shared, cfg: &Value) -> PathBuf {
    let slot = cfg["WorldSlot"].as_str().filter(|x| !x.is_empty()).unwrap_or("DedicatedWorld");
    s.paths.data_dir(cfg).join("Saved").join("SaveGames").join(slot)
}

pub fn backups_dir(s: &Shared, cfg: &Value) -> PathBuf {
    slot_dir(s, cfg).join("Backups")
}

/// Autosaves between the game's own backups for the configured interval.
pub fn backup_frequency(cfg: &Value) -> u64 {
    let minutes = cfg["Backups"]["IntervalMinutes"].as_f64().unwrap_or(60.0).clamp(5.0, 1440.0);
    let autosave = cfg["AutoSaveSeconds"].as_f64().unwrap_or(300.0).max(30.0);
    ((minutes * 60.0 / autosave).round() as u64).max(1)
}

fn keep(cfg: &Value) -> usize {
    cfg["Backups"]["Keep"].as_u64().unwrap_or(48).clamp(1, 1000) as usize
}

/// "auto" (made by the game), "manual", "before-restore", "before-update".
fn kind_of(name: &str) -> &'static str {
    if name.ends_with(" manual") {
        "manual"
    } else if name.ends_with(" before-restore") {
        "before-restore"
    } else if name.ends_with(" before-update") {
        "before-update"
    } else {
        "auto"
    }
}

fn valid_name(name: &str) -> bool {
    !name.is_empty() && name.len() < 100 && !name.contains(['/', '\\', ':']) && !name.contains("..")
}

fn save_files(dir: &Path) -> Vec<PathBuf> {
    fs::read_dir(dir)
        .map(|rd| rd.flatten().map(|e| e.path()).filter(|p| p.is_file() && p.extension().map(|x| x.eq_ignore_ascii_case("sav")).unwrap_or(false)).collect())
        .unwrap_or_default()
}

fn mtime(p: &Path) -> u64 {
    fs::metadata(p).and_then(|m| m.modified()).ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_secs()).unwrap_or(0)
}

fn local_stamp() -> String {
    let out = Command::new("powershell")
        .env_remove("PSModulePath")
        .args(["-NoProfile", "-Command", "Get-Date -Format 'yyyy-MM-dd_HH.mm.ss'"])
        .creation_flags(CREATE_NO_WINDOW)
        .output();
    match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).trim().to_string(),
        _ => format!("{}", SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)),
    }
}

pub fn list(s: &Shared) -> Value {
    let cfg = load_config(&s.paths);
    let dir = backups_dir(s, &cfg);
    let mut out: Vec<Value> = fs::read_dir(&dir)
        .map(|rd| {
            rd.flatten()
                .filter(|e| e.path().is_dir())
                .filter_map(|e| {
                    let name = e.file_name().to_string_lossy().to_string();
                    let files = save_files(&e.path());
                    if files.is_empty() {
                        return None;
                    }
                    let size: u64 = files.iter().map(|f| fs::metadata(f).map(|m| m.len()).unwrap_or(0)).sum();
                    let time = files.iter().map(|f| mtime(f)).max().unwrap_or(0);
                    Some(json!({ "name": name, "kind": kind_of(&name), "time": time, "size": size, "files": files.len() }))
                })
                .collect()
        })
        .unwrap_or_default();
    out.sort_by(|a, b| b["time"].as_u64().cmp(&a["time"].as_u64()).then(b["name"].as_str().cmp(&a["name"].as_str())));
    json!({
        "slot": cfg["WorldSlot"],
        "dir": dir.display().to_string(),
        "keep": keep(&cfg),
        "intervalMinutes": cfg["Backups"]["IntervalMinutes"].as_f64().unwrap_or(60.0),
        "backups": out,
    })
}

/// Copies the world slot's save files into a new backup folder. Returns its name.
fn copy_slot(s: &Shared, cfg: &Value, suffix: &str) -> Result<String, String> {
    let slot = slot_dir(s, cfg);
    let files = save_files(&slot);
    if files.is_empty() {
        return Err(format!("there is no saved world in {}", slot.display()));
    }
    let mut name = format!("{} {suffix}", local_stamp());
    let mut dest = backups_dir(s, cfg).join(&name);
    let mut n = 2;
    while dest.exists() {
        name = format!("{} {suffix} {n}", local_stamp());
        dest = backups_dir(s, cfg).join(&name);
        n += 1;
    }
    fs::create_dir_all(&dest).map_err(|e| e.to_string())?;
    for f in &files {
        let target = dest.join(f.file_name().unwrap_or_default());
        fs::copy(f, &target).map_err(|e| format!("copying {}: {e}", f.display()))?;
    }
    Ok(name)
}

/// Saves first when the server runs (waits for the world file to be rewritten), then copies.
fn backup_now(sink: &Sink, s: &Shared, suffix: &str) -> Result<String, String> {
    let cfg = load_config(&s.paths);
    let running = s.inner.lock().unwrap().child.is_some();
    if running {
        let world_file = slot_dir(s, &cfg).join("Actors.sav");
        let before = mtime(&world_file);
        s.inner.lock().unwrap().queue.push_back("save".into());
        for _ in 0..40 {
            thread::sleep(Duration::from_millis(500));
            if mtime(&world_file) > before {
                break;
            }
        }
        thread::sleep(Duration::from_secs(3)); // let the save finish writing every file
    }
    let name = copy_slot(s, &cfg, suffix)?;
    info(sink, s, &format!("World backed up: {name}"));
    Ok(name)
}

pub fn create(sink: Sink, s: Shared) -> Result<(), String> {
    begin(&s)?;
    thread::spawn(move || {
        if let Err(e) = backup_now(&sink, &s, "manual") {
            info(&sink, &s, &format!("Backup failed: {e}"));
        }
        end(&s);
    });
    Ok(())
}

/// Used by the updater once the server has stopped.
pub fn before_update(sink: &Sink, s: &Shared) {
    let cfg = load_config(&s.paths);
    match copy_slot(s, &cfg, "before-update") {
        Ok(name) => info(sink, s, &format!("World backed up before the update: {name}")),
        Err(e) => info(sink, s, &format!("No backup before the update: {e}")),
    }
}

pub fn delete(sink: &Sink, s: &Shared, name: &str) -> Result<(), String> {
    if !valid_name(name) {
        return Err("invalid backup name".into());
    }
    let cfg = load_config(&s.paths);
    let dir = backups_dir(s, &cfg).join(name);
    if !dir.is_dir() {
        return Err("that backup does not exist".into());
    }
    fs::remove_dir_all(&dir).map_err(|e| e.to_string())?;
    info(sink, s, &format!("Backup deleted: {name}"));
    Ok(())
}

pub fn restore(sink: Sink, s: Shared, name: String) -> Result<(), String> {
    if !valid_name(&name) {
        return Err("invalid backup name".into());
    }
    let cfg = load_config(&s.paths);
    let src = backups_dir(&s, &cfg).join(&name);
    if save_files(&src).is_empty() {
        return Err("that backup does not exist or is empty".into());
    }
    begin(&s)?;
    thread::spawn(move || {
        if let Err(e) = do_restore(&sink, &s, &name, &src) {
            info(&sink, &s, &format!("Restore failed: {e}"));
        }
        end(&s);
    });
    Ok(())
}

fn do_restore(sink: &Sink, s: &Shared, name: &str, src: &Path) -> Result<(), String> {
    let cfg = load_config(&s.paths);
    let was_running = s.inner.lock().unwrap().child.is_some();
    info(sink, s, &format!("Restoring the world from backup {name}..."));
    if was_running {
        let _ = request_stop(sink, s);
        if !wait_stopped(s, 150) {
            return Err("the server did not stop".into());
        }
    }
    // Keep what is being replaced, so a restore can always be undone.
    match copy_slot(s, &cfg, "before-restore") {
        Ok(saved) => info(sink, s, &format!("The current world was backed up as {saved}")),
        Err(e) => info(sink, s, &format!("Could not back up the current world first ({e}) - continuing")),
    }
    let slot = slot_dir(s, &cfg);
    for f in save_files(&slot) {
        fs::remove_file(&f).map_err(|e| format!("removing {}: {e}", f.display()))?;
    }
    for f in save_files(src) {
        let target = slot.join(f.file_name().unwrap_or_default());
        fs::copy(&f, &target).map_err(|e| format!("copying {}: {e}", f.display()))?;
    }
    info(sink, s, &format!("World restored from {name}."));
    prune(sink, s);
    if was_running || s.headless {
        s.inner.lock().unwrap().quick_crashes = 0;
        let _ = start_server(sink.clone(), s.clone());
    }
    Ok(())
}

fn begin(s: &Shared) -> Result<(), String> {
    let mut inner = s.inner.lock().unwrap();
    if inner.backup_busy {
        return Err("A backup or restore is already running.".into());
    }
    if inner.update_busy {
        return Err("An update is running - try again in a minute.".into());
    }
    inner.backup_busy = true;
    Ok(())
}

fn end(s: &Shared) {
    s.inner.lock().unwrap().backup_busy = false;
}

/// Keeps the newest Backups.Keep automatic copies and the newest few "before ..." copies. Manual ones stay.
pub fn prune(sink: &Sink, s: &Shared) {
    let cfg = load_config(&s.paths);
    let dir = backups_dir(s, &cfg);
    let mut by_kind: std::collections::HashMap<&'static str, Vec<String>> = std::collections::HashMap::new();
    if let Ok(rd) = fs::read_dir(&dir) {
        for e in rd.flatten().filter(|e| e.path().is_dir()) {
            let name = e.file_name().to_string_lossy().to_string();
            by_kind.entry(kind_of(&name)).or_default().push(name);
        }
    }
    let mut removed = 0;
    for (kind, mut names) in by_kind {
        let limit = match kind {
            "auto" => keep(&cfg),
            "manual" => continue,
            _ => KEEP_SPECIAL,
        };
        names.sort();
        while names.len() > limit {
            let oldest = names.remove(0);
            if fs::remove_dir_all(dir.join(&oldest)).is_ok() {
                removed += 1;
            }
        }
    }
    if removed > 0 {
        info(sink, s, &format!("Removed {removed} old world backup(s)."));
    }
}

pub fn prune_loop(sink: Sink, s: Shared) {
    thread::sleep(Duration::from_secs(60));
    loop {
        if !s.inner.lock().unwrap().backup_busy {
            prune(&sink, &s);
        }
        thread::sleep(Duration::from_secs(15 * 60));
    }
}
