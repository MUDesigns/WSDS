// Public server list on wsdsmaps.com (opt-in: PublicListing.Enabled, needs the live map).
//
// While enabled, WSDS announces the server every 5 minutes: POST <WSDS_LISTING_URL or
// https://wsdsmaps.com/api/announce> {"port": <live-map port>}. The site then reads /map/hello on that port,
// which carries a "listing" block (name, description, players, join port) only while the listing is on.
// It answers {"ok":true,"listed":true} or {"error":"<code>"}.

use crate::{info, livemap, load_config, now_secs, players_online, powershell, ps_quote, Shared, Sink, VERSION};
use serde_json::{json, Value};
use std::thread;
use std::time::Duration;

pub const DESCRIPTION_MAX: usize = 200;
const EVERY: u64 = 5 * 60;

pub fn enabled(cfg: &Value) -> bool {
    cfg["PublicListing"]["Enabled"].as_bool().unwrap_or(false) && cfg["LiveMap"]["Enabled"].as_bool().unwrap_or(true)
}

pub fn description(cfg: &Value) -> String {
    cfg["PublicListing"]["Description"].as_str().unwrap_or("").trim().chars().take(DESCRIPTION_MAX).collect()
}

pub fn clamp_config(cfg: &mut Value) {
    if cfg["PublicListing"].is_object() {
        cfg["PublicListing"]["Description"] = json!(description(cfg));
    }
}

/// The "listing" block of /map/hello (None while the listing is off).
pub fn hello_block(cfg: &Value, players: usize, online: bool) -> Option<Value> {
    enabled(cfg).then(|| {
        json!({
            "listed": true, "description": description(cfg), "players": players,
            "maxPlayers": cfg["MaxPlayers"].as_u64().unwrap_or(8), "gamePort": cfg["Port"].as_u64().unwrap_or(7777), "online": online,
        })
    })
}

/// The site's answer (or the transport error) as an outcome code: "listed", the site's error code,
/// "site-unreachable" or "bad-answer".
pub fn outcome(answer: Result<&str, &str>) -> String {
    let Ok(text) = answer else { return "site-unreachable".into() };
    match serde_json::from_str::<Value>(text.trim()) {
        Ok(v) if v["ok"].as_bool() == Some(true) && v["listed"].as_bool() != Some(false) => "listed".into(),
        Ok(v) => v["error"].as_str().filter(|e| !e.is_empty()).map(String::from).unwrap_or_else(|| "not-listed".into()),
        Err(_) => "bad-answer".into(),
    }
}

/// What an outcome means, in plain words.
pub fn outcome_message(code: &str, port: u16, game_port: u16) -> String {
    let same = if port == game_port { " (the same number as the game's UDP port, but TCP)" } else { "" };
    match code {
        "listed" => "Listed on wsdsmaps.com/servers".into(),
        "not-reachable" => format!(
            "Not listed on wsdsmaps.com/servers: the site could not reach this server's live map from the internet. Forward TCP port {port}{same} on your router to this PC and allow it in the firewall."
        ),
        "private-address" => "Not listed on wsdsmaps.com/servers: this server's address is a private (home network) address. Only servers that can be reached from the internet are listed.".into(),
        "rate-limited" => "Not listed yet: wsdsmaps.com asked WSDS to slow down. It tries again in a few minutes.".into(),
        "not-listed" => "Not listed on wsdsmaps.com/servers: the site did not accept this server. It tries again in a few minutes.".into(),
        "site-unreachable" => "Could not reach wsdsmaps.com to announce this server. Is this PC online? WSDS tries again in a few minutes.".into(),
        "bad-answer" => "wsdsmaps.com gave an answer WSDS does not understand. WSDS tries again in a few minutes.".into(),
        other => format!("Not listed on wsdsmaps.com/servers ({other}). WSDS tries again in a few minutes."),
    }
}

fn announce_url() -> String {
    std::env::var("WSDS_LISTING_URL").ok().filter(|u| !u.trim().is_empty()).unwrap_or_else(|| "https://wsdsmaps.com/api/announce".into())
}

/// POSTs the announcement. Error answers (HTTP 4xx/5xx) still carry the site's JSON, so their body is returned.
fn announce(url: &str, port: u16) -> Result<String, String> {
    let body = json!({ "port": port }).to_string();
    let script = format!(
        "$ProgressPreference='SilentlyContinue'; [Net.ServicePointManager]::SecurityProtocol='Tls12';\
         try {{ (Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Method Post -UserAgent 'WSDS/{VERSION}' -ContentType 'application/json' -Body '{}' '{}').Content }}\
         catch {{ if ($_.ErrorDetails -and $_.ErrorDetails.Message) {{ $_.ErrorDetails.Message }}\
           elseif ($_.Exception.Response) {{ (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() }}\
           else {{ [Console]::Error.WriteLine($_.Exception.Message); exit 1 }} }}",
        ps_quote(&body),
        ps_quote(url)
    );
    let out = powershell(&script).map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
    }
    Ok(String::from_utf8_lossy(&out.stdout).to_string())
}

pub fn status(s: &Shared) -> Value {
    let cfg = load_config(&s.paths);
    let last = s.inner.lock().unwrap().listing.clone();
    json!({
        "enabled": cfg["PublicListing"]["Enabled"].as_bool().unwrap_or(false),
        "liveMap": cfg["LiveMap"]["Enabled"].as_bool().unwrap_or(true),
        "port": livemap::map_port(&cfg),
        "last": last,
    })
}

/// Announces every 5 minutes while the listing is on (first ~30 s after start, and right after it is turned on).
pub fn run(sink: Sink, s: Shared) {
    thread::sleep(Duration::from_secs(30));
    let mut was_on = false;
    let mut next = 0u64;
    let mut last_code = String::new();
    loop {
        let cfg = load_config(&s.paths);
        let on = enabled(&cfg);
        let now = now_secs();
        if !on {
            if was_on {
                info(&sink, &s, "Public server list turned off: this server is no longer announced on wsdsmaps.com/servers.");
                s.inner.lock().unwrap().listing = None;
            }
            last_code.clear();
        } else if !was_on || now >= next {
            let port = livemap::map_port(&cfg);
            let answer = announce(&announce_url(), port);
            let code = outcome(answer.as_deref().map_err(|e| e.as_str()));
            let message = outcome_message(&code, port, cfg["Port"].as_u64().unwrap_or(7777) as u16);
            if code != last_code {
                info(&sink, &s, &message);
                if let Err(e) = &answer {
                    if !e.is_empty() {
                        info(&sink, &s, &format!("(wsdsmaps.com: {})", e.lines().next().unwrap_or("").trim()));
                    }
                }
                last_code = code.clone();
            }
            s.inner.lock().unwrap().listing = Some(json!({ "code": code, "message": message, "time": now, "players": players_online(&s) }));
            next = now + EVERY;
        }
        was_on = on;
        thread::sleep(Duration::from_secs(5));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn answers_become_outcomes() {
        assert_eq!(outcome(Ok("{\"ok\":true,\"listed\":true}")), "listed");
        assert_eq!(outcome(Ok("{\"error\":\"not-reachable\"}\r\n")), "not-reachable");
        assert_eq!(outcome(Ok("{\"error\":\"rate-limited\"}")), "rate-limited");
        assert_eq!(outcome(Ok("{\"ok\":true,\"listed\":false}")), "not-listed");
        assert_eq!(outcome(Ok("<html>")), "bad-answer");
        assert_eq!(outcome(Err("timeout")), "site-unreachable");
        assert!(outcome_message("not-reachable", 7777, 7777).contains("Forward TCP port 7777 (the same number as the game's UDP port, but TCP)"));
        assert!(outcome_message("not-reachable", 7790, 7777).contains("Forward TCP port 7790 on your router"));
    }

    /// The real PowerShell request against a local stand-in for the site, which answers 400 with its JSON.
    #[test]
    fn announce_posts_the_port_and_reads_error_answers() {
        use std::io::{Read, Write};
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://127.0.0.1:{}/api/announce", l.local_addr().unwrap().port());
        let site = thread::spawn(move || {
            let (mut c, _) = l.accept().unwrap();
            c.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
            let mut req = Vec::new();
            let mut buf = [0u8; 4096];
            while !String::from_utf8_lossy(&req).contains("{\"port\":7790}") {
                let n = c.read(&mut buf).unwrap();
                if n == 0 {
                    break;
                }
                req.extend_from_slice(&buf[..n]);
            }
            let body = "{\"error\":\"not-reachable\"}";
            write!(c, "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
            String::from_utf8_lossy(&req).to_string()
        });
        let answer = announce(&url, 7790);
        let req = site.join().unwrap().to_lowercase();
        assert!(req.starts_with("post /api/announce"), "{req}");
        assert!(req.contains("content-type: application/json"), "{req}");
        assert!(req.contains(&format!("user-agent: wsds/{VERSION}")), "{req}");
        assert_eq!(outcome(answer.as_deref().map_err(|e| e.as_str())), "not-reachable", "{answer:?}");
    }

    #[test]
    fn hello_carries_the_listing_only_when_both_are_on() {
        let mut cfg = json!({ "Port": 7777, "MaxPlayers": 6, "LiveMap": { "Enabled": true }, "PublicListing": { "Enabled": true, "Description": "x".repeat(300) } });
        let b = hello_block(&cfg, 2, true).unwrap();
        assert_eq!(b["players"], 2);
        assert_eq!(b["maxPlayers"], 6);
        assert_eq!(b["gamePort"], 7777);
        assert_eq!(b["online"], true);
        assert_eq!(b["listed"], true);
        assert_eq!(b["description"].as_str().unwrap().len(), DESCRIPTION_MAX);
        cfg["LiveMap"]["Enabled"] = json!(false);
        assert!(hello_block(&cfg, 2, true).is_none());
        cfg["LiveMap"]["Enabled"] = json!(true);
        cfg["PublicListing"]["Enabled"] = json!(false);
        assert!(hello_block(&cfg, 2, true).is_none());
    }
}
