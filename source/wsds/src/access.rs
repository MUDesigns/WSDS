// Message of the day and the whitelist.
//
// Motd (top level) is shown to every player when they join. With Whitelist.Enabled only players on the list
// may join. The list lives in <ServerData>/whitelist.json like bans.json: [{key, name, time}], where key is a
// player key (Steam id / save key) and may be empty when someone was added by name only; the game script
// matches either (names case-insensitively). Both reach the game as admin commands when it is up and again
// whenever they change, so no restart is needed.

use crate::{load_config, now_secs, Paths, Shared, Sink};
use serde_json::{json, Value};
use std::fs;
use std::path::PathBuf;

pub const MOTD_MAX: usize = 500;
const NAME_MAX: usize = 64;

fn file(paths: &Paths, cfg: &Value) -> PathBuf {
    paths.data_dir(cfg).join("whitelist.json")
}

pub fn load(paths: &Paths, cfg: &Value) -> Vec<Value> {
    fs::read_to_string(file(paths, cfg)).ok().and_then(|t| serde_json::from_str::<Vec<Value>>(&t).ok()).unwrap_or_default()
}

fn save(s: &Shared, cfg: &Value, list: &[Value]) -> Result<(), String> {
    let _ = fs::create_dir_all(s.paths.data_dir(cfg));
    fs::write(file(&s.paths, cfg), serde_json::to_string_pretty(list).unwrap_or_default()).map_err(|e| e.to_string())?;
    s.inner.lock().unwrap().whitelist_ver += 1;
    Ok(())
}

pub fn enabled(cfg: &Value) -> bool {
    cfg["Whitelist"]["Enabled"].as_bool().unwrap_or(false)
}

/// `motd <text>`: line breaks become the two characters \n, double quotes become single quotes.
/// An empty message gives `motd`, which clears it.
pub fn motd_command(text: &str) -> String {
    let t = text.replace("\r\n", "\n").replace('\r', "\n").replace('"', "'");
    let t = t.trim().replace('\n', "\\n");
    if t.is_empty() {
        "motd".into()
    } else {
        format!("motd {t}")
    }
}

/// The list first, then on/off, so the whitelist is never switched on with an empty list.
pub fn whitelist_commands(on: bool, list: &[Value]) -> Vec<String> {
    let mut out = vec!["whitelistclear".to_string()];
    for e in list {
        let key = e["key"].as_str().unwrap_or("").trim();
        let who = if key.is_empty() { e["name"].as_str().unwrap_or("").trim() } else { key };
        if !who.is_empty() {
            out.push(format!("whitelistadd \"{}\"", who.replace('"', "'")));
        }
    }
    out.push(format!("whitelist {}", if on { "on" } else { "off" }));
    out
}

/// Everything the game needs when it comes up (the message only when there is one).
pub fn ready_commands(s: &Shared, cfg: &Value) -> Vec<String> {
    let mut out = Vec::new();
    let motd = cfg["Motd"].as_str().unwrap_or("");
    if !motd.trim().is_empty() {
        out.push(motd_command(motd));
    }
    out.extend(whitelist_commands(enabled(cfg), &load(&s.paths, cfg)));
    out
}

fn push_if_running(s: &Shared, cmds: Vec<String>) {
    let mut inner = s.inner.lock().unwrap();
    if inner.child.is_some() && inner.status == "running" {
        inner.queue.extend(cmds);
    }
}

/// After the settings were saved: pass a changed message or whitelist switch to the running game.
pub fn config_saved(s: &Shared, old: &Value, new: &Value) {
    let mut cmds = Vec::new();
    if old["Motd"].as_str().unwrap_or("") != new["Motd"].as_str().unwrap_or("") {
        cmds.push(motd_command(new["Motd"].as_str().unwrap_or("")));
    }
    if enabled(old) != enabled(new) {
        cmds.push(format!("whitelist {}", if enabled(new) { "on" } else { "off" }));
    }
    push_if_running(s, cmds);
}

pub fn clamp_config(cfg: &mut Value) {
    if let Some(m) = cfg["Motd"].as_str() {
        cfg["Motd"] = json!(m.chars().take(MOTD_MAX).collect::<String>());
    }
}

fn changed(sink: &Sink, s: &Shared, cfg: &Value, list: &[Value]) {
    push_if_running(s, whitelist_commands(enabled(cfg), list));
    sink.emit("whitelist", json!({ "enabled": enabled(cfg), "entries": list }));
}

pub fn list(s: &Shared) -> Value {
    let cfg = load_config(&s.paths);
    json!({ "enabled": enabled(&cfg), "entries": load(&s.paths, &cfg) })
}

fn clean_name(n: &str) -> String {
    n.trim().replace('"', "'").chars().filter(|c| !c.is_control()).take(NAME_MAX).collect()
}

/// Adds (or completes) an entry. Returns a short description for the activity log.
pub fn add(sink: &Sink, s: &Shared, key: &str, name: &str) -> Result<String, String> {
    let key = crate::livemap::clean_key(key);
    let name = clean_name(name);
    if key.is_empty() && name.is_empty() {
        return Err("Enter a player name.".into());
    }
    let cfg = load_config(&s.paths);
    let mut list = load(&s.paths, &cfg);
    let same_key = |e: &Value| !key.is_empty() && e["key"].as_str() == Some(key.as_str());
    let same_name = |e: &Value| !name.is_empty() && e["name"].as_str().is_some_and(|n| n.eq_ignore_ascii_case(&name));
    if let Some(e) = list.iter_mut().find(|e| same_key(e) || (same_name(e) && e["key"].as_str().unwrap_or("").is_empty())) {
        if !key.is_empty() {
            e["key"] = json!(key);
        }
        if !name.is_empty() {
            e["name"] = json!(name);
        }
    } else {
        list.push(json!({ "key": key, "name": name, "time": now_secs() }));
    }
    save(s, &cfg, &list)?;
    changed(sink, s, &cfg, &list);
    Ok(if name.is_empty() { key } else { name })
}

pub fn remove(sink: &Sink, s: &Shared, key: &str, name: &str) -> Result<(), String> {
    let (key, name) = (key.trim(), name.trim());
    if key.is_empty() && name.is_empty() {
        return Err("Nothing to remove.".into());
    }
    let cfg = load_config(&s.paths);
    let mut list = load(&s.paths, &cfg);
    let before = list.len();
    if key.is_empty() {
        list.retain(|e| !e["name"].as_str().is_some_and(|n| n.eq_ignore_ascii_case(name)));
    } else {
        list.retain(|e| e["key"].as_str() != Some(key));
    }
    if list.len() == before {
        return Err("That player is not on the whitelist.".into());
    }
    save(s, &cfg, &list)?;
    changed(sink, s, &cfg, &list);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn motd_keeps_line_breaks_as_backslash_n() {
        assert_eq!(motd_command("Welcome!\r\nBe \"nice\".\nHave fun"), "motd Welcome!\\nBe 'nice'.\\nHave fun");
        assert_eq!(motd_command("  \n "), "motd");
        assert_eq!(motd_command(""), "motd");
    }

    #[test]
    fn whitelist_sends_keys_or_names_then_the_switch() {
        let list = vec![
            json!({ "key": "76561198000000000", "name": "Morgana Fey" }),
            json!({ "key": "", "name": "Haze \"the\" Witch" }),
            json!({ "key": "", "name": "" }),
        ];
        assert_eq!(
            whitelist_commands(true, &list),
            vec!["whitelistclear", "whitelistadd \"76561198000000000\"", "whitelistadd \"Haze 'the' Witch\"", "whitelist on"]
        );
        assert_eq!(whitelist_commands(false, &[]), vec!["whitelistclear", "whitelist off"]);
    }
}
