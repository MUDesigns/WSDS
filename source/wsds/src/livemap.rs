// Live map for wsdsmaps.com: viewer authentication and the data the game server writes to its log.
//
// Join-password proof (computed in the viewer's browser, so the password never leaves it):
//     key   = SHA256("<salt>:<password>")          (same derivation as remote control)
//     proof = hex(HMAC-SHA256(key, nonce))         (nonce: single use, 60 s)

use crate::{derive_key, hex, http_response, info, load_config, now_secs, random_hex, read_request, unhex, write_config, Shared, Sink, CREATE_NO_WINDOW, VERSION};
use hmac::{Hmac, Mac};
use serde_json::{json, Value};
use sha2::Sha256;
use std::collections::{BTreeMap, HashMap};
use std::io::Write;
use std::net::{TcpListener, TcpStream};
use std::os::windows::process::CommandExt;
use std::process::Command;
use std::sync::mpsc::{sync_channel, RecvTimeoutError, SyncSender, TrySendError};
use std::thread;
use std::time::Duration;

pub fn proof(key_hex: &str, nonce: &str) -> String {
    let key = unhex(key_hex).unwrap_or_default();
    let mut mac = Hmac::<Sha256>::new_from_slice(&key).expect("hmac key");
    mac.update(nonce.as_bytes());
    hex(&mac.finalize().into_bytes())
}

pub fn proof_ok(key_hex: &str, nonce: &str, proof_hex: &str) -> bool {
    let (Some(key), Some(sig)) = (unhex(key_hex), unhex(proof_hex)) else { return false };
    let Ok(mut mac) = Hmac::<Sha256>::new_from_slice(&key) else { return false };
    mac.update(nonce.as_bytes());
    mac.verify_slice(&sig).is_ok()
}

const NONCE_LIFE: u64 = 60;
const TOKEN_LIFE: u64 = 600;

#[derive(Debug, PartialEq)]
pub enum AuthError {
    BadNonce,
    WrongPassword,
}

#[derive(Default)]
pub struct Auth {
    nonces: HashMap<String, u64>,
    tokens: HashMap<String, u64>,
}

impl Auth {
    pub fn new_nonce(&mut self, now: u64) -> String {
        self.nonces.retain(|_, exp| *exp >= now);
        let n = random_hex(16);
        self.nonces.insert(n.clone(), now + NONCE_LIFE);
        n
    }

    /// Spends the nonce (even on a wrong password) and returns a session token.
    /// `key` is None when the server has no join password.
    pub fn redeem(&mut self, nonce: &str, proof: &str, key: Option<&str>, now: u64) -> Result<String, AuthError> {
        match self.nonces.remove(nonce) {
            Some(exp) if exp >= now => {}
            _ => return Err(AuthError::BadNonce),
        }
        if let Some(k) = key {
            if !proof_ok(k, nonce, proof) {
                return Err(AuthError::WrongPassword);
            }
        }
        self.tokens.retain(|_, exp| *exp >= now);
        let t = random_hex(24);
        self.tokens.insert(t.clone(), now + TOKEN_LIFE);
        Ok(t)
    }

    /// True while the token is in use; every use extends it by TOKEN_LIFE.
    pub fn token_valid(&mut self, token: &str, now: u64) -> bool {
        match self.tokens.get_mut(token) {
            Some(exp) if *exp >= now => {
                *exp = now + TOKEN_LIFE;
                true
            }
            _ => false,
        }
    }
}

/// `[WSDS-POS] <unixMs>|<key>,<x>,<y>,<z>,<yaw>;...` -> `{"type":"pos","t":ms,"p":[[key,x,y,z,yaw],...]}`
pub fn parse_pos_line(line: &str) -> Option<Value> {
    let rest = &line[line.find("[WSDS-POS] ")? + 11..];
    let (t, entries) = rest.trim_end().split_once('|')?;
    let t: u64 = t.parse().ok()?;
    let mut p = Vec::new();
    for e in entries.split(';').filter(|e| !e.is_empty()) {
        let f: Vec<&str> = e.split(',').collect();
        if f.len() != 5 || f[0].is_empty() {
            return None;
        }
        let n: Vec<i64> = f[1..].iter().map(|x| x.parse::<i64>().ok()).collect::<Option<Vec<_>>>()?;
        p.push(json!([f[0], n[0], n[1], n[2], n[3]]));
    }
    Some(json!({ "type": "pos", "t": t, "p": p }))
}

#[derive(Default)]
pub struct Chunks {
    pending: HashMap<String, (u64, usize, BTreeMap<usize, String>)>,
}

impl Chunks {
    /// Feeds one `[WSDS-MAP] <reqId> <part>/<total> <chunk>` line; returns (reqId, json) when complete.
    pub fn push(&mut self, line: &str, now: u64) -> Option<(String, String)> {
        self.pending.retain(|_, (first, _, _)| now.saturating_sub(*first) <= 30);
        let rest = &line[line.find("[WSDS-MAP] ")? + 11..];
        let (req, rest) = rest.split_once(' ')?;
        let (pt, chunk) = match rest.split_once(' ') {
            Some((a, b)) => (a, b),
            None => (rest, ""),
        };
        let (part, total) = pt.split_once('/')?;
        let (part, total): (usize, usize) = (part.parse().ok()?, total.parse().ok()?);
        if part == 0 || part > total {
            return None;
        }
        let entry = self.pending.entry(req.to_string()).or_insert_with(|| (now, total, BTreeMap::new()));
        entry.2.insert(part, chunk.trim_end_matches(&['\r', '\n'][..]).to_string());
        if entry.2.len() < entry.1 {
            return None;
        }
        let (_, _, parts) = self.pending.remove(req)?;
        Some((req.to_string(), parts.into_values().collect::<String>()))
    }
}

#[derive(Default)]
pub struct Lease {
    last: Option<u64>,
}

impl Lease {
    /// Called regularly with the number of open map streams; returns a command to queue when the
    /// game's watch lease (10 s) needs renewing (every 3 s while anyone watches).
    pub fn viewer_count_changed(&mut self, viewers: usize, now: u64) -> Option<String> {
        if viewers == 0 {
            self.last = None;
            return None;
        }
        if matches!(self.last, Some(t) if now < t + 3) {
            return None;
        }
        self.last = Some(now);
        Some("mapwatch 10".into())
    }
}

// ================================================================ live map server (TCP map port)

const MAX_STREAMS: usize = 20;
const QUERY_TIMEOUT: Duration = Duration::from_secs(12);

#[derive(Default)]
pub struct LiveState {
    pub auth: Auth,
    chunks: Chunks,
    lease: Lease,
    next_viewer: u64,
    viewers: Vec<(u64, SyncSender<String>)>,
    waiting: HashMap<String, SyncSender<String>>,
    info: Option<(u64, Value)>,
    players: Option<(u64, Value)>,
    online_keys: Vec<String>,
}

/// The TCP port the live map listens on: LiveMap.Port, or the game's port number when 0.
pub fn map_port(cfg: &Value) -> u16 {
    let p = cfg["LiveMap"]["Port"].as_u64().unwrap_or(0);
    (if p == 0 { cfg["Port"].as_u64().unwrap_or(7777) } else { p }) as u16
}

fn game_running(s: &Shared) -> bool {
    let inner = s.inner.lock().unwrap();
    inner.child.is_some() && inner.status == "running"
}

fn broadcast(s: &Shared, line: String) {
    let mut live = s.live.lock().unwrap();
    live.viewers.retain(|(_, tx)| !matches!(tx.try_send(line.clone()), Err(TrySendError::Disconnected(_))));
}

/// Game log lines for the live map. Returns true when the line was consumed (kept out of the console).
pub fn on_log_line(s: &Shared, line: &str) -> bool {
    if line.contains("[WSDS-POS] ") {
        if let Some(v) = parse_pos_line(line) {
            broadcast(s, v.to_string());
        }
        return true;
    }
    if line.contains("[WSDS-MAP] ") {
        let done = s.live.lock().unwrap().chunks.push(line, now_secs());
        if let Some((req, json)) = done {
            if let Some(tx) = s.live.lock().unwrap().waiting.remove(&req) {
                let _ = tx.try_send(json);
            }
        }
        return true;
    }
    // Developer survey output (WSMapSurvey.as) never belongs in the console.
    ["[WSDS-CATALOG] ", "[WSDS-SURVEYPT] ", "[WSDS-MAPINFO] ", "[WSDS-EXPORT] "].iter().any(|m| line.contains(*m))
}

/// Periodic server state: when the set of online players changes, viewers get a fresh player list.
pub fn on_state(s: &Shared, state: &Value) {
    let mut keys: Vec<String> = state["players"]
        .as_array()
        .map(|a| a.iter().filter(|p| p["spawned"].as_bool() == Some(true)).filter_map(|p| p["key"].as_str().map(String::from)).collect())
        .unwrap_or_default();
    keys.sort();
    let changed = {
        let mut live = s.live.lock().unwrap();
        if live.online_keys == keys {
            false
        } else {
            live.online_keys = keys;
            !live.viewers.is_empty()
        }
    };
    if changed {
        let s = s.clone();
        thread::spawn(move || {
            if let Ok(p) = query(&s, "mapplayers", "") {
                s.live.lock().unwrap().players = Some((now_secs(), p.clone()));
                let mut msg = p;
                msg["type"] = json!("players");
                broadcast(&s, msg.to_string());
            }
        });
    }
}

/// Asks the game (through the admin command queue) and waits for its [WSDS-MAP] answer.
fn query(s: &Shared, cmd: &str, arg: &str) -> Result<Value, String> {
    if !game_running(s) {
        return Err("server-offline".into());
    }
    let req = random_hex(4);
    let (tx, rx) = sync_channel(1);
    s.live.lock().unwrap().waiting.insert(req.clone(), tx);
    s.inner.lock().unwrap().queue.push_back(format!("{cmd} {req} {arg}").trim_end().to_string());
    let out = rx.recv_timeout(QUERY_TIMEOUT);
    s.live.lock().unwrap().waiting.remove(&req);
    let text = out.map_err(|_| "timeout".to_string())?;
    let v: Value = serde_json::from_str(&text).map_err(|_| "bad answer".to_string())?;
    if let Some(e) = v["error"].as_str() {
        return Err(e.to_string());
    }
    Ok(v)
}

fn cached(s: &Shared, which: &str, max_age: u64) -> Option<Value> {
    let live = s.live.lock().unwrap();
    let slot = if which == "info" { &live.info } else { &live.players };
    slot.as_ref().filter(|(t, _)| now_secs().saturating_sub(*t) <= max_age).map(|(_, v)| v.clone())
}

fn info_and_players(s: &Shared) -> (Option<Value>, Option<Value>) {
    // Both questions go out together so they share one trip through the command queue.
    let players = {
        let s = s.clone();
        thread::spawn(move || {
            cached(&s, "players", 30).or_else(|| {
                let v = query(&s, "mapplayers", "").ok()?;
                s.live.lock().unwrap().players = Some((now_secs(), v.clone()));
                Some(v)
            })
        })
    };
    let info = cached(s, "info", 60).or_else(|| {
        let v = query(s, "mapinfo", "").ok()?;
        s.live.lock().unwrap().info = Some((now_secs(), v.clone()));
        Some(v)
    });
    (info, players.join().ok().flatten())
}

fn percent_decode(x: &str) -> String {
    let b = x.replace('+', " ").into_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let Some(n) = std::str::from_utf8(&b[i + 1..i + 3]).ok().and_then(|h| u8::from_str_radix(h, 16).ok()) {
                out.push(n);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

pub fn parse_query(path: &str) -> (String, HashMap<String, String>) {
    let (p, q) = path.split_once('?').unwrap_or((path, ""));
    let map = q
        .split('&')
        .filter(|kv| !kv.is_empty())
        .map(|kv| {
            let (k, v) = kv.split_once('=').unwrap_or((kv, ""));
            (percent_decode(k), percent_decode(v))
        })
        .collect();
    (p.to_string(), map)
}

/// Player keys are save identities (Steam ids, ws_<hash>, ...): keep them to a safe alphabet.
pub fn clean_key(k: &str) -> String {
    k.chars().filter(|c| c.is_ascii_alphanumeric() || "_-:.".contains(*c)).take(128).collect()
}

fn handle(mut stream: TcpStream, s: Shared) {
    let Some((method, path, _headers, _body)) = read_request(&mut stream) else { return };
    if method != "GET" {
        return http_response(&mut stream, 404, &json!({ "error": "not found" }));
    }
    let cfg = load_config(&s.paths);
    if !cfg["LiveMap"]["Enabled"].as_bool().unwrap_or(true) {
        return http_response(&mut stream, 404, &json!({ "error": "live map is turned off" }));
    }
    let (route, q) = parse_query(&path);
    let arg = |k: &str| q.get(k).cloned().unwrap_or_default();
    let password = cfg["Password"].as_str().unwrap_or("").to_string();
    let salt = cfg["LiveMap"]["Salt"].as_str().unwrap_or("").to_string();
    let now = now_secs();
    match route.as_str() {
        "/map/hello" => {
            let nonce = s.live.lock().unwrap().auth.new_nonce(now);
            http_response(&mut stream, 200, &json!({
                "app": "WSDS", "version": VERSION, "name": cfg["WorldName"],
                "passwordRequired": !password.is_empty(), "salt": salt, "nonce": nonce,
            }));
        }
        "/map/auth" => {
            let key = (!password.is_empty()).then(|| derive_key(&salt, &password));
            let r = s.live.lock().unwrap().auth.redeem(&arg("nonce"), &arg("proof"), key.as_deref(), now);
            match r {
                Ok(token) => http_response(&mut stream, 200, &json!({ "ok": true, "token": token })),
                Err(e) => {
                    thread::sleep(Duration::from_millis(400)); // slow down guessing
                    let msg = if e == AuthError::WrongPassword { "wrong password" } else { "bad nonce" };
                    http_response(&mut stream, 401, &json!({ "error": msg }));
                }
            }
        }
        "/map/stream" | "/map/players" | "/map/progress" => {
            if !s.live.lock().unwrap().auth.token_valid(&arg("token"), now) {
                return http_response(&mut stream, 401, &json!({ "error": "bad token" }));
            }
            if !game_running(&s) {
                return http_response(&mut stream, 503, &json!({ "error": "server-offline" }));
            }
            let answer = match route.as_str() {
                "/map/players" => query(&s, "mapplayers", ""),
                "/map/progress" => query(&s, "mapprogress", &clean_key(&arg("key"))),
                _ => return serve_stream(stream, s),
            };
            match answer {
                Ok(v) => http_response(&mut stream, 200, &v),
                Err(e) => http_response(&mut stream, 503, &json!({ "error": e })),
            }
        }
        _ => http_response(&mut stream, 404, &json!({ "error": "not found" })),
    }
}

fn serve_stream(mut stream: TcpStream, s: Shared) {
    let (tx, rx) = sync_channel::<String>(64);
    let id = {
        let mut live = s.live.lock().unwrap();
        if live.viewers.len() >= MAX_STREAMS {
            drop(live);
            return http_response(&mut stream, 503, &json!({ "error": "busy" }));
        }
        live.next_viewer += 1;
        let id = live.next_viewer;
        live.viewers.push((id, tx.clone()));
        id
    };
    let _ = stream.set_write_timeout(Some(Duration::from_secs(10)));
    let mut ok = write!(stream, "HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n").is_ok();
    // Map info and the player list come from the game (a few seconds through the command queue):
    // positions start flowing right away and these follow when ready.
    {
        let s = s.clone();
        thread::spawn(move || {
            let (info, players) = info_and_players(&s);
            for (kind, v) in [("info", info), ("players", players)] {
                if let Some(mut v) = v {
                    v["type"] = json!(kind);
                    let _ = tx.send(v.to_string());
                }
            }
        });
    }
    while ok {
        match rx.recv_timeout(Duration::from_secs(15)) {
            Ok(line) => ok = writeln!(stream, "{line}").is_ok(),
            Err(RecvTimeoutError::Timeout) => ok = game_running(&s) && writeln!(stream, "{{\"type\":\"ping\"}}").is_ok(),
            Err(RecvTimeoutError::Disconnected) => break,
        }
    }
    s.live.lock().unwrap().viewers.retain(|(v, _)| *v != id);
}

fn ensure_firewall(sink: &Sink, s: &Shared, port: u16) {
    let netsh = |args: &[&str]| Command::new("netsh").args(args).creation_flags(CREATE_NO_WINDOW).output().map(|o| o.status.success()).unwrap_or(false);
    let _ = netsh(&["advfirewall", "firewall", "delete", "rule", "name=WSDS Live Map"]);
    let port_arg = format!("localport={port}");
    if netsh(&["advfirewall", "firewall", "add", "rule", "name=WSDS Live Map", "dir=in", "action=allow", "protocol=TCP", &port_arg]) {
        info(sink, s, &format!("Live map: Windows Firewall allows TCP {port}"));
    } else {
        info(sink, s, &format!("Live map: could not add a Windows Firewall rule (needs administrator rights) - allow TCP {port} yourself"));
    }
}

/// Starts the live-map listener (if enabled) and the watch-lease keeper.
pub fn start(sink: Sink, s: Shared) {
    let mut cfg = load_config(&s.paths);
    if cfg["LiveMap"]["Salt"].as_str().unwrap_or("").is_empty() {
        cfg["LiveMap"]["Salt"] = json!(random_hex(16));
        let _ = write_config(&s.paths, &cfg);
    }
    if !cfg["LiveMap"]["Enabled"].as_bool().unwrap_or(true) {
        info(&sink, &s, "Live map is turned off (Settings > Live map)");
        return;
    }
    let port = map_port(&cfg);
    {
        let (sink, s) = (sink.clone(), s.clone());
        thread::spawn(move || ensure_firewall(&sink, &s, port));
    }
    {
        let s = s.clone();
        thread::spawn(move || loop {
            thread::sleep(Duration::from_secs(1));
            let renew = {
                let mut live = s.live.lock().unwrap();
                let viewers = live.viewers.len();
                live.lease.viewer_count_changed(viewers, now_secs())
            };
            if let Some(cmd) = renew {
                if game_running(&s) {
                    s.inner.lock().unwrap().queue.push_back(cmd);
                }
            }
        });
    }
    for addr in ["0.0.0.0", "::"] {
        let (sink, s) = (sink.clone(), s.clone());
        thread::spawn(move || {
            let mut bound = TcpListener::bind((addr, port));
            for _ in 0..30 {
                if bound.is_ok() {
                    break;
                }
                thread::sleep(Duration::from_secs(2));
                bound = TcpListener::bind((addr, port));
            }
            match bound {
                Ok(listener) => {
                    if addr == "0.0.0.0" {
                        info(&sink, &s, &format!("Live map listening on TCP port {port} (wsdsmaps.com)"));
                    }
                    for stream in listener.incoming().flatten() {
                        let s = s.clone();
                        thread::spawn(move || handle(stream, s));
                    }
                }
                Err(e) => {
                    if addr == "0.0.0.0" {
                        info(&sink, &s, &format!("Live map could not listen on TCP port {port}: {e}"));
                    }
                }
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::derive_key;

    #[test]
    fn proof_roundtrip() {
        let key = derive_key("s", "pw");
        let p = proof(&key, "n1");
        assert_eq!(p.len(), 64);
        assert!(proof_ok(&key, "n1", &p));
        assert!(!proof_ok(&derive_key("s", "wrong"), "n1", &p));
        assert!(!proof_ok(&key, "n2", &p));
        // Fixed vector (computed independently with Python's hmac), shared with the site's proof.js test.
        assert_eq!(p, "961b19b498d944ab88770ebd2088337283fe706e98043675a84f128593af1f9c");
    }

    #[test]
    fn nonce_single_use() {
        let mut a = Auth::default();
        let key = derive_key("s", "pw");
        let n = a.new_nonce(100);
        let p = proof(&key, &n);
        assert!(a.redeem(&n, &p, Some(&key), 101).is_ok());
        assert_eq!(a.redeem(&n, &p, Some(&key), 102), Err(AuthError::BadNonce));
    }

    #[test]
    fn nonce_expires() {
        let mut a = Auth::default();
        let key = derive_key("s", "pw");
        let n = a.new_nonce(100);
        assert_eq!(a.redeem(&n, &proof(&key, &n), Some(&key), 161), Err(AuthError::BadNonce));
    }

    #[test]
    fn wrong_password_is_refused_and_burns_the_nonce() {
        let mut a = Auth::default();
        let key = derive_key("s", "pw");
        let n = a.new_nonce(100);
        assert_eq!(a.redeem(&n, &proof(&derive_key("s", "nope"), &n), Some(&key), 101), Err(AuthError::WrongPassword));
        assert_eq!(a.redeem(&n, &proof(&key, &n), Some(&key), 102), Err(AuthError::BadNonce));
    }

    #[test]
    fn no_password_needs_no_proof() {
        let mut a = Auth::default();
        let n = a.new_nonce(100);
        let t = a.redeem(&n, "", None, 101).unwrap();
        assert!(a.token_valid(&t, 102));
    }

    #[test]
    fn token_slides_then_expires() {
        let mut a = Auth::default();
        let n = a.new_nonce(0);
        let t = a.redeem(&n, "", None, 0).unwrap();
        assert!(a.token_valid(&t, 500)); // renews to 1100
        assert!(a.token_valid(&t, 1000));
        assert!(!a.token_valid(&t, 1601));
        assert!(!a.token_valid("nope", 1));
    }

    #[test]
    fn pos_line_parses() {
        let v = parse_pos_line("[2026.11.25-16.40.23:089][675]WSDS: [WSDS-POS] 1764081000123|765,1,-2,3,90;k2,4,5,6,359").unwrap();
        assert_eq!(v["type"], "pos");
        assert_eq!(v["t"], 1764081000123u64);
        assert_eq!(v["p"], json!([["765", 1, -2, 3, 90], ["k2", 4, 5, 6, 359]]));
        let empty = parse_pos_line("[WSDS-POS] 1764081000123|").unwrap();
        assert_eq!(empty["p"], json!([]));
    }

    #[test]
    fn pos_line_rejects_garbage() {
        assert!(parse_pos_line("[WSDS-POS] abc|k,1,2,3,4").is_none());
        assert!(parse_pos_line("[WSDS-POS] 1764081000123|k,1,2").is_none());
        assert!(parse_pos_line("[WSDS-POS] 1764081000123|k,1,x,3,4").is_none());
        assert!(parse_pos_line("no marker here").is_none());
    }

    #[test]
    fn chunks_reassemble_out_of_order() {
        let mut c = Chunks::default();
        assert_eq!(c.push("x [WSDS-MAP] r1 2/3 \":", 10), None);
        assert_eq!(c.push("x [WSDS-MAP] r1 1/3 {\"a", 10), None);
        assert_eq!(c.push("x [WSDS-MAP] r1 3/3 1}", 11), Some(("r1".into(), "{\"a\":1}".into())));
        assert_eq!(c.push("x [WSDS-MAP] r2 1/1 {}", 12), Some(("r2".into(), "{}".into())));
    }

    #[test]
    fn chunks_keep_emoji() {
        let mut c = Chunks::default();
        c.push("[WSDS-MAP] q 1/2 {\"s\":\"aa", 1);
        let (_, json) = c.push("[WSDS-MAP] q 2/2 \u{1F600}bb\"}", 1).unwrap();
        let v: Value = serde_json::from_str(&json).unwrap();
        assert_eq!(v["s"], "aa\u{1F600}bb");
    }

    #[test]
    fn chunks_drop_stale_partials() {
        let mut c = Chunks::default();
        c.push("[WSDS-MAP] r 1/2 {\"a\"", 0);
        assert_eq!(c.push("[WSDS-MAP] r 2/2 :1}", 31), None);
    }

    #[test]
    fn lease_renews_every_3s() {
        // 10 s leases renewed every 3 s: positions stop within ~13 s of the last viewer leaving,
        // and two renewals may be delayed by the command queue (~3 s each) without a gap.
        let mut l = Lease::default();
        assert_eq!(l.viewer_count_changed(0, 0), None);
        assert_eq!(l.viewer_count_changed(1, 10), Some("mapwatch 10".into()));
        assert_eq!(l.viewer_count_changed(2, 12), None);
        assert_eq!(l.viewer_count_changed(2, 13), Some("mapwatch 10".into()));
        assert_eq!(l.viewer_count_changed(0, 14), None);
        assert_eq!(l.viewer_count_changed(1, 15), Some("mapwatch 10".into()));
    }

    #[test]
    fn query_strings_are_decoded() {
        let (p, q) = parse_query("/map/progress?token=abc&key=ws_123%3A4&x=a+b&empty=");
        assert_eq!(p, "/map/progress");
        assert_eq!(q["token"], "abc");
        assert_eq!(q["key"], "ws_123:4");
        assert_eq!(q["x"], "a b");
        assert_eq!(q["empty"], "");
        assert_eq!(parse_query("/map/hello").0, "/map/hello");
        assert_eq!(parse_query("/x?bad=%zz%4").1["bad"], "%zz%4");
    }

    #[test]
    fn player_keys_are_cleaned() {
        assert_eq!(clean_key("76561198000000000"), "76561198000000000");
        assert_eq!(clean_key("ws_1369144312"), "ws_1369144312");
        assert_eq!(clean_key("a b\"c;mapwatch 60"), "abcmapwatch60");
    }

    #[test]
    fn map_port_defaults_to_the_game_port() {
        assert_eq!(map_port(&json!({ "Port": 7787, "LiveMap": { "Port": 0 } })), 7787);
        assert_eq!(map_port(&json!({ "Port": 7787, "LiveMap": { "Port": 7790 } })), 7790);
        assert_eq!(map_port(&json!({ "Port": 7787 })), 7787);
    }
}
