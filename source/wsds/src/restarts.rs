// Scheduled restarts.
//
// Restarts.Times are daily restarts in the server's local time (HH:MM, 24 h); Restarts.EveryHours > 0 also
// restarts after every N hours the server has been up. The earliest of those is the next restart. Players get
// a notice Restarts.WarnMinutes before it, then the world is saved and the server restarts (like the Restart
// button). With Restarts.SkipWhenEmpty the restart waits for an empty server: from the planned time WSDS
// restarts as soon as nobody is online, and after WAIT_EMPTY_MAX it restarts anyway, with the usual warnings.
// "Restart in N minutes" starts a countdown by hand (same warnings) and can be cancelled.
//
// Only the process that owns the game server runs the scheduler (the window attached to the background
// service calls these operations remotely).

use crate::{info, load_config, now_secs, restart_server, Shared, Sink};
use serde_json::{json, Value};
use std::thread;
use std::time::{Duration, Instant};

pub const TITLE: &str = "Server Restart";
const WAIT_EMPTY_MAX: u64 = 2 * 3600;
const RETRY: u64 = 60;
const COOLDOWN: u64 = 300;
const DAY: i64 = 86_400;

// ---------------------------------------------------------------- pure scheduling math

/// "05:00" -> 300 (minutes after midnight). Accepts "5:00"; rejects anything outside 00:00-23:59.
pub fn parse_time(t: &str) -> Option<u32> {
    let (h, m) = t.trim().split_once(':')?;
    let (h, m): (u32, u32) = (h.trim().parse().ok()?, m.trim().parse().ok()?);
    (h < 24 && m < 60 && !t.trim().ends_with(':')).then_some(h * 60 + m)
}

/// The next daily restart strictly after `from` (unix seconds), given the local UTC offset in seconds.
pub fn next_daily(from: u64, offset: i64, times: &[u32]) -> Option<u64> {
    let local = from as i64 + offset;
    let midnight = local - local.rem_euclid(DAY);
    times
        .iter()
        .map(|&t| {
            let mut c = midnight + t as i64 * 60;
            if c <= local {
                c += DAY;
            }
            (c - offset) as u64
        })
        .min()
}

/// The next "every N hours of uptime" restart strictly after `from`: start + k * N hours.
pub fn next_uptime(from: u64, start: u64, every_hours: f64) -> Option<u64> {
    if !(every_hours > 0.0) {
        return None;
    }
    let period = ((every_hours * 3600.0) as u64).max(600);
    let k = if from < start { 1 } else { (from - start) / period + 1 };
    Some(start + k * period)
}

#[derive(Debug, Clone, PartialEq)]
pub struct Next {
    pub at: u64,
    pub daily: bool, // false: uptime
}

/// The earliest upcoming restart. `lead` (seconds) keeps an uptime restart that is already overdue (the setting
/// was just turned on) far enough away for the warnings.
pub fn next_restart(now: u64, from: u64, offset: i64, times: &[u32], every_hours: f64, start: Option<u64>, lead: u64) -> Option<Next> {
    let daily = next_daily(from.max(now), offset, times).map(|at| Next { at, daily: true });
    let uptime = start
        .and_then(|st| next_uptime(from.max(now), st, every_hours))
        .map(|at| Next { at: at.max(now + lead), daily: false });
    match (daily, uptime) {
        (Some(d), Some(u)) => Some(if u.at < d.at { u } else { d }),
        (d, u) => d.or(u),
    }
}

/// Which warning to send now, if any: the warnings whose time has come and that were not sent yet. When several
/// are due at once (WSDS started late, or a short countdown) only one notice goes out, with the real time left.
/// Returns (minutes to announce, warnings now counted as sent).
pub fn due_warning(secs_left: i64, warn: &[u32], sent: &[u32]) -> Option<(u32, Vec<u32>)> {
    if secs_left <= 0 {
        return None;
    }
    let due: Vec<u32> = warn.iter().copied().filter(|m| *m as i64 * 60 >= secs_left && !sent.contains(m)).collect();
    if due.is_empty() {
        return None;
    }
    let minutes = ((secs_left + 59) / 60) as u32;
    Some((minutes.max(1), due))
}

pub fn minutes_text(m: u32) -> String {
    if m == 1 {
        "1 minute".into()
    } else {
        format!("{m} minutes")
    }
}

/// `broadcasttitle "<title>" <message words...>` - the server's tokenizer only groups double quotes.
pub fn broadcast_command(title: &str, message: &str) -> String {
    let clean = |t: &str| t.replace('"', "'").replace(['\r', '\n'], " ");
    format!("broadcasttitle \"{}\" {}", clean(title), clean(message).trim())
}

pub fn warning_message(template: &str, minutes: u32) -> String {
    let t = if template.trim().is_empty() { "The server restarts in {minutes}. Find a safe spot!" } else { template };
    t.replace("{minutes}", &minutes_text(minutes))
}

/// "Today 05:00", "Tomorrow 05:00", "Sat 05:00" for a unix time, in the server's local time.
pub fn day_label(now: u64, at: u64, offset: i64) -> String {
    let (ln, la) = (now as i64 + offset, at as i64 + offset);
    let days = la.div_euclid(DAY) - ln.div_euclid(DAY);
    let mins = la.rem_euclid(DAY) / 60;
    let hhmm = format!("{:02}:{:02}", mins / 60, mins % 60);
    let day = match days {
        0 => "Today".to_string(),
        1 => "Tomorrow".to_string(),
        _ => ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"][la.div_euclid(DAY).rem_euclid(7) as usize].to_string(), // 1970-01-01 was a Thursday
    };
    format!("{day} {hhmm}")
}

// ---------------------------------------------------------------- settings

struct Settings {
    enabled: bool,
    times: Vec<u32>,
    every_hours: f64,
    warn: Vec<u32>,
    message: String,
    wait_empty: bool,
}

fn settings(cfg: &Value) -> Settings {
    let r = &cfg["Restarts"];
    let mut warn: Vec<u32> = r["WarnMinutes"].as_array().map(|a| a.iter().filter_map(Value::as_u64).filter(|m| (1..=120).contains(m)).map(|m| m as u32).collect()).unwrap_or_default();
    warn.sort_unstable_by(|a, b| b.cmp(a));
    warn.dedup();
    Settings {
        enabled: r["Enabled"].as_bool().unwrap_or(false),
        times: r["Times"].as_array().map(|a| a.iter().filter_map(|t| t.as_str().and_then(parse_time)).collect()).unwrap_or_default(),
        every_hours: r["EveryHours"].as_f64().unwrap_or(0.0).clamp(0.0, 24.0 * 30.0),
        warn,
        message: r["Message"].as_str().unwrap_or("").to_string(),
        wait_empty: r["SkipWhenEmpty"].as_bool().unwrap_or(false),
    }
}

// ---------------------------------------------------------------- scheduler state

#[derive(Default, Clone)]
pub struct Plan {
    pub at: u64,
    pub reason: String,
    pub manual: bool,
    pub minutes: u32,              // manual countdown length (announced first)
    pub wait_from: Option<u64>,    // SkipWhenEmpty: restart as soon as the server is empty from this time on
    pub sent: Vec<u32>,
}

#[derive(Default)]
pub struct Sched {
    plan: Option<Plan>,
    fingerprint: String,
    skip_before: u64,
    cooldown_until: u64,
}

fn local_offset() -> i64 {
    chrono::Local::now().offset().local_minus_utc() as i64
}

fn queue(s: &Shared, cmd: String) {
    let mut inner = s.inner.lock().unwrap();
    if inner.child.is_some() && inner.status == "running" {
        inner.queue.push_back(cmd);
    }
}

/// (running, generation, unix start time, players online)
fn server_facts(s: &Shared) -> (bool, u64, Option<u64>, usize) {
    let inner = s.inner.lock().unwrap();
    let running = inner.child.is_some() && inner.status == "running";
    let start = inner.child.as_ref().and(inner.started_at).map(|t| now_secs().saturating_sub(t.elapsed().as_secs()));
    let players = if running { inner.last_state.as_ref().and_then(|st| st["players"].as_array().map(|a| a.len())).unwrap_or(0) } else { 0 };
    (running, inner.generation, start, players)
}

fn plan_scheduled(st: &Settings, now: u64, from: u64, offset: i64, start: Option<u64>) -> Option<Plan> {
    let lead = if st.wait_empty { 0 } else { st.warn.first().copied().unwrap_or(0) as u64 * 60 };
    let n = next_restart(now, from, offset, &st.times, st.every_hours, start, lead)?;
    let reason = if n.daily {
        let mins = (n.at as i64 + offset).rem_euclid(DAY) / 60;
        format!("daily restart at {:02}:{:02}", mins / 60, mins % 60)
    } else {
        format!("restart after {} hours of uptime", st.every_hours)
    };
    Some(if st.wait_empty {
        Plan { at: n.at + WAIT_EMPTY_MAX, reason, wait_from: Some(n.at), ..Default::default() }
    } else {
        Plan { at: n.at, reason, ..Default::default() }
    })
}

/// The scheduler: checks every 2 seconds.
pub fn run(sink: Sink, s: Shared) {
    thread::sleep(Duration::from_secs(5));
    loop {
        tick(&sink, &s);
        thread::sleep(Duration::from_secs(2));
    }
}

fn tick(sink: &Sink, s: &Shared) {
    let cfg = load_config(&s.paths);
    let st = settings(&cfg);
    let now = now_secs();
    let offset = local_offset();
    let (running, generation, start, players) = server_facts(s);
    let busy = {
        let inner = s.inner.lock().unwrap();
        inner.update_busy || inner.backup_busy
    };
    let fingerprint = format!("{}|{generation}|{}|{offset}", cfg["Restarts"], start.is_some());

    // Keep (or work out) the plan.
    let mut sched = s.restarts.lock().unwrap();
    let manual = sched.plan.as_ref().is_some_and(|p| p.manual);
    if !manual {
        if !st.enabled {
            sched.plan = None;
        } else if sched.plan.is_none() || sched.fingerprint != fingerprint {
            let from = sched.skip_before;
            let fresh = plan_scheduled(&st, now, from, offset, start);
            // Same restart as before (only an unrelated setting changed): keep the warnings already sent.
            sched.plan = match (sched.plan.take(), fresh) {
                (Some(old), Some(mut new)) if old.at == new.at => {
                    new.sent = old.sent;
                    Some(new)
                }
                (_, fresh) => fresh,
            };
        }
    }
    sched.fingerprint = fingerprint;
    let Some(mut plan) = sched.plan.clone() else { return };
    if now < sched.cooldown_until {
        return;
    }

    // Waiting for an empty server: restart as soon as nobody is online.
    let empty_now = plan.wait_from.is_some_and(|w| now >= w) && players == 0;
    let due = now >= plan.at || empty_now;
    if !due {
        if running {
            let mut warn = st.warn.clone();
            if plan.manual && !warn.contains(&plan.minutes) {
                warn.push(plan.minutes);
            }
            if let Some((minutes, mark)) = due_warning(plan.at as i64 - now as i64, &warn, &plan.sent) {
                plan.sent.extend(mark);
                sched.plan = Some(plan);
                drop(sched);
                queue(s, broadcast_command(TITLE, &warning_message(&st.message, minutes)));
                info(sink, s, &format!("Restart warning sent: {} left.", minutes_text(minutes)));
            }
        }
        return;
    }

    // Time to restart.
    if !running && !busy {
        // Nothing to restart: the server is off, or is stopping or starting right now. Plan the next one.
        sched.skip_before = now;
        sched.plan = if plan.manual { None } else { plan_scheduled(&st, now, now, offset, start) };
        return;
    }
    if busy {
        // An update, backup or restore is busy: try again in a minute.
        plan.at = now + RETRY;
        plan.wait_from = None;
        plan.sent = st.warn.clone();
        if plan.manual {
            plan.sent.push(plan.minutes);
        }
        sched.plan = Some(plan);
        return;
    }
    sched.plan = None;
    sched.skip_before = now;
    sched.cooldown_until = now + COOLDOWN;
    drop(sched);
    let (sink, s) = (sink.clone(), s.clone());
    thread::spawn(move || {
        let reason = if empty_now { format!("{} (nobody online)", plan.reason) } else { plan.reason.clone() };
        if players > 0 {
            let last = broadcast_command(TITLE, "Restarting now - see you in a minute!");
            queue(&s, last.clone());
            // Let the notice reach the players before the server shuts down.
            let t = Instant::now();
            while t.elapsed() < Duration::from_secs(10) && s.inner.lock().unwrap().queue.contains(&last) {
                thread::sleep(Duration::from_millis(250));
            }
            thread::sleep(Duration::from_secs(5));
        }
        info(&sink, &s, &format!("Restarting the server: {reason}."));
        if let Err(e) = restart_server(&sink, &s) {
            info(&sink, &s, &format!("The restart did not happen: {e}"));
        }
    });
}

// ---------------------------------------------------------------- operations

pub fn status(s: &Shared) -> Value {
    let cfg = load_config(&s.paths);
    let st = settings(&cfg);
    let now = now_secs();
    let offset = local_offset();
    let (running, _, _, _) = server_facts(s);
    let plan = s.restarts.lock().unwrap().plan.clone();
    let server_time = day_label(now, now, offset).trim_start_matches("Today ").to_string();
    let next = plan.as_ref().map(|p| {
        let first = p.wait_from.unwrap_or(p.at);
        json!({
            "at": first, "in": first.saturating_sub(now), "label": day_label(now, first, offset), "reason": p.reason,
            "waitEmpty": p.wait_from.is_some(), "latest": p.at, "latestLabel": day_label(now, p.at, offset),
            "latestIn": p.at.saturating_sub(now), "manual": p.manual,
        })
    });
    let pending = plan.as_ref().filter(|p| p.manual || !p.sent.is_empty() || p.wait_from.is_some_and(|w| now >= w)).map(|p| {
        json!({ "in": p.at.saturating_sub(now), "manual": p.manual, "reason": p.reason, "waiting": p.wait_from.is_some_and(|w| now >= w) })
    });
    json!({
        "enabled": st.enabled, "running": running, "serverTime": server_time,
        "times": st.times.len(), "everyHours": st.every_hours, "next": next, "pending": pending,
    })
}

pub fn countdown(sink: &Sink, s: &Shared, minutes: u64) -> Result<(), String> {
    if !(1..=1440).contains(&minutes) {
        return Err("Pick between 1 and 1440 minutes.".into());
    }
    if !server_facts(s).0 {
        return Err("The server is not running.".into());
    }
    let now = now_secs();
    let mut sched = s.restarts.lock().unwrap();
    sched.plan = Some(Plan { at: now + minutes * 60, reason: "restart started by an admin".into(), manual: true, minutes: minutes as u32, ..Default::default() });
    sched.cooldown_until = 0;
    drop(sched);
    info(sink, s, &format!("Restart in {} requested.", minutes_text(minutes as u32)));
    Ok(())
}

pub fn cancel(sink: &Sink, s: &Shared) -> Result<(), String> {
    let now = now_secs();
    let mut sched = s.restarts.lock().unwrap();
    let Some(plan) = sched.plan.clone() else { return Err("No restart is planned.".into()) };
    let started = plan.manual || !plan.sent.is_empty() || plan.wait_from.is_some_and(|w| now >= w);
    if !started {
        return Err("No restart is counting down.".into());
    }
    // A cancelled scheduled restart is skipped: the next one is planned from after it.
    if !plan.manual {
        sched.skip_before = plan.at.max(now);
    }
    sched.plan = None;
    sched.fingerprint.clear();
    drop(sched);
    if plan.manual || !plan.sent.is_empty() {
        queue(s, broadcast_command(TITLE, "The restart was cancelled."));
    }
    info(sink, s, &format!("Restart cancelled ({}).", plan.reason));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    // 2026-11-27 21:48:00 UTC
    const NOW: u64 = 1_795_816_080;

    #[test]
    fn times_parse() {
        assert_eq!(parse_time("05:00"), Some(300));
        assert_eq!(parse_time(" 5:07 "), Some(307));
        assert_eq!(parse_time("23:59"), Some(1439));
        assert_eq!(parse_time("24:00"), None);
        assert_eq!(parse_time("12:60"), None);
        assert_eq!(parse_time("noon"), None);
        assert_eq!(parse_time("12:"), None);
    }

    #[test]
    fn daily_restart_is_the_next_one_in_local_time() {
        // UTC: 21:48 -> 05:00 tomorrow is 7 h 12 min away.
        assert_eq!(next_daily(NOW, 0, &[300]), Some(NOW + 7 * 3600 + 12 * 60));
        // UTC+1 (local 22:48): 05:00 local = 04:00 UTC, 6 h 12 min away.
        assert_eq!(next_daily(NOW, 3600, &[300]), Some(NOW + 6 * 3600 + 12 * 60));
        // UTC-5 (local 16:48): 18:00 local today is 1 h 12 min away; the earliest time wins.
        assert_eq!(next_daily(NOW, -5 * 3600, &[300, 1080]), Some(NOW + 3600 + 12 * 60));
        // A time that is exactly now is tomorrow's.
        assert_eq!(next_daily(NOW, 0, &[21 * 60 + 48]), Some(NOW + 86_400));
        assert_eq!(next_daily(NOW, 0, &[]), None);
    }

    #[test]
    fn uptime_restarts_come_every_n_hours_after_the_start() {
        let start = NOW - 3600;
        assert_eq!(next_uptime(NOW, start, 6.0), Some(start + 6 * 3600));
        assert_eq!(next_uptime(start + 6 * 3600, start, 6.0), Some(start + 12 * 3600)); // strictly after
        assert_eq!(next_uptime(NOW, start, 0.0), None);
    }

    #[test]
    fn the_earliest_restart_wins_and_overdue_uptime_restarts_leave_time_for_warnings() {
        let start = NOW - 3600;
        // Daily 05:00 UTC is 7 h 12 min away; 6 h of uptime comes first (5 h away).
        let n = next_restart(NOW, 0, 0, &[300], 6.0, Some(start), 900).unwrap();
        assert_eq!(n, Next { at: start + 6 * 3600, daily: false });
        // Not running: only the daily time counts.
        assert_eq!(next_restart(NOW, 0, 0, &[300], 6.0, None, 900).unwrap(), Next { at: NOW + 7 * 3600 + 720, daily: true });
        // Up for 10 h and "every 6 h" just turned on: the 12 h mark is 2 h away.
        let n = next_restart(NOW, 0, 0, &[], 6.0, Some(NOW - 10 * 3600), 900).unwrap();
        assert_eq!(n.at, NOW + 2 * 3600);
        // Due within the warning time: pushed back so every warning can go out.
        let n = next_restart(NOW, 0, 0, &[], 6.0, Some(NOW - 6 * 3600 + 60), 900).unwrap();
        assert_eq!(n.at, NOW + 900);
        // A skipped restart: plan from after it.
        let n = next_restart(NOW, NOW + 7 * 3600 + 720, 0, &[300], 0.0, None, 0).unwrap();
        assert_eq!(n.at, NOW + 7 * 3600 + 720 + 86_400);
        assert_eq!(next_restart(NOW, 0, 0, &[], 0.0, Some(NOW), 0), None);
    }

    #[test]
    fn warnings_go_out_once_each() {
        let warn = [15, 5, 1];
        assert_eq!(due_warning(16 * 60, &warn, &[]), None);
        assert_eq!(due_warning(15 * 60, &warn, &[]), Some((15, vec![15])));
        assert_eq!(due_warning(14 * 60 + 58, &warn, &[15]), None);
        assert_eq!(due_warning(299, &warn, &[15]), Some((5, vec![5])));
        assert_eq!(due_warning(59, &warn, &[15, 5]), Some((1, vec![1])));
        assert_eq!(due_warning(30, &warn, &[15, 5, 1]), None);
        assert_eq!(due_warning(0, &warn, &[]), None);
        // Started 3 minutes before: one notice with the real time left, the passed warnings count as sent.
        assert_eq!(due_warning(180, &warn, &[]), Some((3, vec![15, 5])));
    }

    #[test]
    fn notices_read_naturally() {
        assert_eq!(minutes_text(1), "1 minute");
        assert_eq!(minutes_text(15), "15 minutes");
        assert_eq!(warning_message("The server restarts in {minutes}. Find a safe spot!", 1), "The server restarts in 1 minute. Find a safe spot!");
        assert_eq!(warning_message("", 5), "The server restarts in 5 minutes. Find a safe spot!");
        assert_eq!(broadcast_command(TITLE, "Say \"bye\"\nnow"), "broadcasttitle \"Server Restart\" Say 'bye' now");
    }

    #[test]
    fn labels_use_the_server_day() {
        assert_eq!(day_label(NOW, NOW + 7 * 3600 + 720, 0), "Tomorrow 05:00");
        assert_eq!(day_label(NOW, NOW + 600, 0), "Today 21:58");
        assert_eq!(day_label(NOW, NOW + 600, 3 * 3600), "Today 00:58"); // local 00:48 is already the next day
        assert_eq!(day_label(NOW, NOW + 2 * 3600, 3600), "Tomorrow 00:48");
        assert_eq!(day_label(NOW, NOW + 2 * 86_400, 0), "Sun 21:48"); // 2026-11-27 is a Friday
    }

    #[test]
    fn settings_are_cleaned() {
        let st = settings(&json!({ "Restarts": { "Enabled": true, "Times": ["05:00", "bad", "17:30"], "WarnMinutes": [1, 15, 5, 0, 500, 5] } }));
        assert_eq!(st.times, vec![300, 1050]);
        assert_eq!(st.warn, vec![15, 5, 1]);
        assert!(st.enabled && !st.wait_empty);
    }
}
