// Live map for wsdsmaps.com: viewer authentication and the data the game server writes to its log.
//
// Join-password proof (computed in the viewer's browser, so the password never leaves it):
//     key   = SHA256("<salt>:<password>")          (same derivation as remote control)
//     proof = hex(HMAC-SHA256(key, nonce))         (nonce: single use, 60 s)

use crate::{hex, random_hex, unhex};
use hmac::{Hmac, Mac};
use serde_json::{json, Value};
use sha2::Sha256;
use std::collections::{BTreeMap, HashMap};

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
    /// game's watch lease needs renewing (every 5 s while anyone watches).
    pub fn viewer_count_changed(&mut self, viewers: usize, now: u64) -> Option<String> {
        if viewers == 0 {
            self.last = None;
            return None;
        }
        if matches!(self.last, Some(t) if now < t + 5) {
            return None;
        }
        self.last = Some(now);
        Some("mapwatch 15".into())
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
    fn lease_renews_every_5s() {
        let mut l = Lease::default();
        assert_eq!(l.viewer_count_changed(0, 0), None);
        assert_eq!(l.viewer_count_changed(1, 10), Some("mapwatch 15".into()));
        assert_eq!(l.viewer_count_changed(2, 12), None);
        assert_eq!(l.viewer_count_changed(2, 15), Some("mapwatch 15".into()));
        assert_eq!(l.viewer_count_changed(0, 16), None);
        assert_eq!(l.viewer_count_changed(1, 17), Some("mapwatch 15".into()));
    }
}
