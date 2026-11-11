//! Read-only Tuta calendar rendering (smores56/sdlc#589).
//!
//! The SDK fetcher lives behind the `sdk` feature; this half is pure and
//! testable anywhere: a strict event model, an RFC 5545 renderer and a
//! fingerprint the guest timer uses to emit only a changed calendar.
//!
//! Nothing here can write to Tuta. The fetcher only calls list/read APIs, and
//! the crate has no create/update/delete surface at all.

use std::fmt::Write as _;

/// The event fields the digest needs. Unknown JSON keys are refused so an SDK
/// change surfaces at parse time instead of being silently dropped.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Event {
    pub uid: String,
    pub summary: String,
    pub start: String,
    pub end: String,
    pub all_day: bool,
    pub location: String,
    pub description: String,
    pub status: String,
    pub updated: String,
    pub sequence: u32,
}

#[derive(Debug, PartialEq, Eq)]
pub enum ParseError {
    NotObject,
    MissingEvents,
    BadEvent(usize, &'static str),
    TooManyEvents(usize),
}

const MAX_EVENTS: usize = 5_000;
const EVENT_KEYS: [&str; 10] = [
    "uid",
    "summary",
    "start",
    "end",
    "all_day",
    "location",
    "description",
    "status",
    "updated",
    "sequence",
];
const MAX_UID: usize = 512;
const MAX_SUMMARY: usize = 1_024;
const MAX_DESCRIPTION: usize = 8_192;
const MAX_LOCATION: usize = 512;

fn field<'a>(
    object: &'a Json,
    key: &str,
    index: usize,
    max: usize,
) -> Result<&'a str, ParseError> {
    match object.get(key) {
        Some(Json::String(value)) if value.len() <= max => Ok(value.as_str()),
        Some(Json::String(_)) => Err(ParseError::BadEvent(index, "field over the length cap")),
        Some(_) => Err(ParseError::BadEvent(index, "field is not a string")),
        None => Ok(""),
    }
}

fn required<'a>(object: &'a Json, key: &str, index: usize) -> Result<&'a str, ParseError> {
    match object.get(key) {
        Some(Json::String(value)) => Ok(value.as_str()),
        Some(_) => Err(ParseError::BadEvent(index, "field is not a string")),
        None => Err(ParseError::BadEvent(index, "field is missing")),
    }
}

/// UTC instant, only `YYYY-MM-DDTHH:MM:SSZ`; the fetcher formats SDK epoch
/// milliseconds that way, and refusing offsets keeps the renderer obvious.
pub fn is_utc_instant(value: &str) -> bool {
    let bytes = value.as_bytes();
    if bytes.len() != 20 || bytes[19] != b'Z' {
        return false;
    }
    let digits = [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18];
    if !digits.iter().all(|i| bytes[*i].is_ascii_digit()) {
        return false;
    }
    if bytes[4] != b'-' || bytes[7] != b'-' || bytes[10] != b'T' || bytes[13] != b':' || bytes[16] != b':' {
        return false;
    }
    let month: u32 = value[5..7].parse().unwrap_or(0);
    let day: u32 = value[8..10].parse().unwrap_or(0);
    let hour: u32 = value[11..13].parse().unwrap_or(99);
    let minute: u32 = value[14..16].parse().unwrap_or(99);
    let second: u32 = value[17..19].parse().unwrap_or(99);
    (1..=12).contains(&month)
        && (1..=31).contains(&day)
        && hour < 24
        && minute < 60
        && second < 60
}

/// Calendar date, only `YYYY-MM-DD`.
pub fn is_date(value: &str) -> bool {
    let bytes = value.as_bytes();
    if bytes.len() != 10 || bytes[4] != b'-' || bytes[7] != b'-' {
        return false;
    }
    let digits = [0, 1, 2, 3, 5, 6, 8, 9];
    if !digits.iter().all(|i| bytes[*i].is_ascii_digit()) {
        return false;
    }
    let month: u32 = value[5..7].parse().unwrap_or(0);
    let day: u32 = value[8..10].parse().unwrap_or(0);
    (1..=12).contains(&month) && (1..=31).contains(&day)
}

/// Parse the neutral event export the SDK fetcher writes.
pub fn parse_events(input: &str) -> Result<Vec<Event>, ParseError> {
    let root = parse_json(input)?;
    if let Json::Object(entries) = &root {
        for (key, _) in entries {
            if key != "events" && key != "calendar" {
                return Err(ParseError::NotObject);
            }
        }
    }
    let list = match root.get("events") {
        Some(Json::Array(items)) => items,
        Some(_) => return Err(ParseError::MissingEvents),
        None => return Err(ParseError::MissingEvents),
    };
    if list.len() > MAX_EVENTS {
        return Err(ParseError::TooManyEvents(list.len()));
    }
    let mut events = Vec::with_capacity(list.len());
    for (index, item) in list.iter().enumerate() {
        let Json::Object(entries) = item else {
            return Err(ParseError::BadEvent(index, "event is not an object"));
        };
        if entries.iter().any(|(key, _)| !EVENT_KEYS.contains(&key.as_str())) {
            return Err(ParseError::BadEvent(index, "event has an unknown key"));
        }
        let uid = required(item, "uid", index)?;
        if uid.is_empty() || uid.len() > MAX_UID {
            return Err(ParseError::BadEvent(index, "uid is empty or over the cap"));
        }
        let start = required(item, "start", index)?;
        let end = required(item, "end", index)?;
        let all_day = match item.get("all_day") {
            Some(Json::Bool(value)) => *value,
            Some(Json::Null) | None => false,
            Some(_) => return Err(ParseError::BadEvent(index, "all_day is not a boolean")),
        };
        if all_day {
            if !is_date(start) || !is_date(end) {
                return Err(ParseError::BadEvent(index, "all-day bounds are not dates"));
            }
        } else if !is_utc_instant(start) || !is_utc_instant(end) {
            return Err(ParseError::BadEvent(index, "timed bounds are not UTC instants"));
        }
        let status = field(item, "status", index, 32)?;
        let status = if status.is_empty() { "CONFIRMED" } else { status };
        if !matches!(status, "CONFIRMED" | "TENTATIVE" | "CANCELLED") {
            return Err(ParseError::BadEvent(index, "status is not a calendar status"));
        }
        let updated = field(item, "updated", index, 64)?;
        if !updated.is_empty() && !is_utc_instant(updated) {
            return Err(ParseError::BadEvent(index, "updated is not a UTC instant"));
        }
        let sequence = match item.get("sequence") {
            Some(Json::Number(value)) => *value as u32,
            Some(Json::Null) | None => 0,
            Some(_) => return Err(ParseError::BadEvent(index, "sequence is not a number")),
        };
        events.push(Event {
            uid: uid.to_string(),
            summary: field(item, "summary", index, MAX_SUMMARY)?.to_string(),
            start: start.to_string(),
            end: end.to_string(),
            all_day,
            location: field(item, "location", index, MAX_LOCATION)?.to_string(),
            description: field(item, "description", index, MAX_DESCRIPTION)?.to_string(),
            status: status.to_string(),
            updated: updated.to_string(),
            sequence,
        });
    }
    events.sort_by(|a, b| a.start.cmp(&b.start).then_with(|| a.uid.cmp(&b.uid)));
    Ok(events)
}

fn escape(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for character in value.chars() {
        match character {
            '\\' => out.push_str("\\\\"),
            ';' => out.push_str("\\;"),
            ',' => out.push_str("\\,"),
            '\n' | '\r' => out.push_str("\\n"),
            other => out.push(other),
        }
    }
    out
}

fn compact_date(value: &str) -> String {
    value.replace('-', "")
}

fn compact_instant(value: &str) -> String {
    value.replace(['-', ':'], "")
}

/// Fold a content line at 75 octets, continuing with a single space (RFC 5545 §3.1).
fn fold(line: &str) -> String {
    if line.len() <= 75 {
        return format!("{line}\r\n");
    }
    let mut out = String::with_capacity(line.len() + line.len() / 70);
    let mut first = true;
    let mut rest = line;
    while !rest.is_empty() {
        let limit = if first { 75 } else { 74 };
        let mut cut = rest.len().min(limit);
        // Never split a UTF-8 sequence.
        while cut > 0 && !rest.is_char_boundary(cut) {
            cut -= 1;
        }
        if cut == 0 {
            cut = rest.len().min(limit);
        }
        if !first {
            out.push(' ');
        }
        out.push_str(&rest[..cut]);
        out.push_str("\r\n");
        rest = &rest[cut..];
        first = false;
    }
    out
}

/// Render one deterministic VCALENDAR. `dtstamp` must be a UTC instant.
pub fn render_ics(events: &[Event], calendar_name: &str, dtstamp: &str) -> String {
    let mut out = String::with_capacity(256 + events.len() * 256);
    let mut line = |text: String| {
        out.push_str(&fold(&text));
    };
    line("BEGIN:VCALENDAR".into());
    line("VERSION:2.0".into());
    line("PRODID:-//smores56//tuta-ics//EN".into());
    line("CALSCALE:GREGORIAN".into());
    line("METHOD:PUBLISH".into());
    line(format!("X-WR-CALNAME:{}", escape(calendar_name)));
    for event in events {
        line("BEGIN:VEVENT".into());
        line(format!("UID:{}", escape(&event.uid)));
        line(format!("DTSTAMP:{}", compact_instant(dtstamp)));
        if event.all_day {
            line(format!("DTSTART;VALUE=DATE:{}", compact_date(&event.start)));
            line(format!("DTEND;VALUE=DATE:{}", compact_date(&event.end)));
        } else {
            line(format!("DTSTART:{}", compact_instant(&event.start)));
            line(format!("DTEND:{}", compact_instant(&event.end)));
        }
        if !event.summary.is_empty() {
            line(format!("SUMMARY:{}", escape(&event.summary)));
        }
        if !event.location.is_empty() {
            line(format!("LOCATION:{}", escape(&event.location)));
        }
        if !event.description.is_empty() {
            line(format!("DESCRIPTION:{}", escape(&event.description)));
        }
        line(format!("STATUS:{}", event.status));
        line(format!("SEQUENCE:{}", event.sequence));
        if !event.updated.is_empty() {
            line(format!("LAST-MODIFIED:{}", compact_instant(&event.updated)));
        }
        line("END:VEVENT".into());
    }
    line("END:VCALENDAR".into());
    out
}

/// FNV-1a over the canonical event set; the guest timer compares this instead of
/// re-emitting an unchanged ICS every run.
pub fn fingerprint(events: &[Event]) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    let mut eat = |bytes: &[u8]| {
        for byte in bytes {
            hash ^= u64::from(*byte);
            hash = hash.wrapping_mul(0x100_0000_01b3);
        }
    };
    for event in events {
        eat(event.uid.as_bytes());
        eat(b"\x1f");
        eat(event.start.as_bytes());
        eat(b"\x1f");
        eat(event.end.as_bytes());
        eat(b"\x1f");
        eat(event.summary.as_bytes());
        eat(b"\x1f");
        eat(event.location.as_bytes());
        eat(b"\x1f");
        eat(event.description.as_bytes());
        eat(b"\x1f");
        eat(event.status.as_bytes());
        eat(b"\x1f");
        eat(&event.sequence.to_be_bytes());
        eat(b"\x1e");
    }
    let mut text = String::with_capacity(16);
    let _ = write!(text, "{hash:016x}");
    text
}

/// Current UTC instant in the `YYYY-MM-DDTHH:MM:SSZ` form the renderer takes.
pub fn now_utc() -> String {
    let seconds = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0);
    format_utc(seconds)
}

/// Format epoch seconds as a UTC instant; `civil_from_days` is the standard
/// days-to-date transform so the crate needs no date library.
pub fn format_utc(seconds: u64) -> String {
    let days = (seconds / 86_400) as i64;
    let day_seconds = seconds % 86_400;
    let (year, month, day) = civil_from_days(days);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        day_seconds / 3600,
        (day_seconds % 3600) / 60,
        day_seconds % 60
    )
}

fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let day_of_era = z - era * 146_097;
    let year_of_era = (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let year = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_position = (5 * day_of_year + 2) / 153;
    let day = (day_of_year - (153 * month_position + 2) / 5 + 1) as u32;
    let month = if month_position < 10 {
        month_position + 3
    } else {
        month_position - 9
    } as u32;
    (if month <= 2 { year + 1 } else { year }, month, day)
}

/// The neutral export shape, so `--mode fetch` and `--mode render` share one parser.
pub fn events_json(events: &[Event]) -> String {
    let mut out = String::from("{\"events\":[");
    for (index, event) in events.iter().enumerate() {
        if index > 0 {
            out.push(',');
        }
        let _ = write!(
            out,
            "{{\"uid\":{},\"summary\":{},\"start\":{},\"end\":{},\"all_day\":{},\"location\":{},\"description\":{},\"status\":{},\"updated\":{},\"sequence\":{}}}",
            json_string(&event.uid),
            json_string(&event.summary),
            json_string(&event.start),
            json_string(&event.end),
            event.all_day,
            json_string(&event.location),
            json_string(&event.description),
            json_string(&event.status),
            json_string(&event.updated),
            event.sequence
        );
    }
    out.push_str("]}");
    out
}

fn json_string(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 2);
    out.push('"');
    for character in value.chars() {
        match character {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            control if (control as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", control as u32);
            }
            other => out.push(other),
        }
    }
    out.push('"');
    out
}

// --- a strict minimal JSON reader -------------------------------------------

#[derive(Debug, Clone, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    Number(i64),
    String(String),
    Array(Vec<Json>),
    Object(Vec<(String, Json)>),
}

impl Json {
    pub fn get(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Object(entries) => entries.iter().find(|(name, _)| name == key).map(|(_, value)| value),
            _ => None,
        }
    }
}

fn parse_json(text: &str) -> Result<Json, ParseError> {
    let bytes = text.trim().as_bytes();
    let mut position = 0usize;
    let value = parse_value(bytes, &mut position, 0)?;
    skip_space(bytes, &mut position);
    if position != bytes.len() {
        return Err(ParseError::NotObject);
    }
    Ok(value)
}

fn skip_space(bytes: &[u8], position: &mut usize) {
    while *position < bytes.len() && bytes[*position].is_ascii_whitespace() {
        *position += 1;
    }
}

fn parse_value(bytes: &[u8], position: &mut usize, depth: usize) -> Result<Json, ParseError> {
    if depth > 16 {
        return Err(ParseError::NotObject);
    }
    skip_space(bytes, position);
    match bytes.get(*position) {
        Some(b'{') => parse_object(bytes, position, depth),
        Some(b'[') => parse_array(bytes, position, depth),
        Some(b'"') => Ok(Json::String(parse_string(bytes, position)?)),
        Some(b't') if bytes[*position..].starts_with(b"true") => {
            *position += 4;
            Ok(Json::Bool(true))
        }
        Some(b'f') if bytes[*position..].starts_with(b"false") => {
            *position += 5;
            Ok(Json::Bool(false))
        }
        Some(b'n') if bytes[*position..].starts_with(b"null") => {
            *position += 4;
            Ok(Json::Null)
        }
        Some(byte) if byte.is_ascii_digit() || *byte == b'-' => parse_number(bytes, position),
        _ => Err(ParseError::NotObject),
    }
}

fn parse_number(bytes: &[u8], position: &mut usize) -> Result<Json, ParseError> {
    let start = *position;
    if bytes.get(*position) == Some(&b'-') {
        *position += 1;
    }
    while matches!(bytes.get(*position), Some(byte) if byte.is_ascii_digit()) {
        *position += 1;
    }
    let text = std::str::from_utf8(&bytes[start..*position]).map_err(|_| ParseError::NotObject)?;
    text.parse::<i64>().map(Json::Number).map_err(|_| ParseError::NotObject)
}

fn parse_string(bytes: &[u8], position: &mut usize) -> Result<String, ParseError> {
    *position += 1; // opening quote
    let mut out = String::new();
    loop {
        match bytes.get(*position) {
            None => return Err(ParseError::NotObject),
            Some(b'"') => {
                *position += 1;
                return Ok(out);
            }
            Some(b'\\') => {
                *position += 1;
                match bytes.get(*position) {
                    Some(b'"') => out.push('"'),
                    Some(b'\\') => out.push('\\'),
                    Some(b'/') => out.push('/'),
                    Some(b'n') => out.push('\n'),
                    Some(b'r') => out.push('\r'),
                    Some(b't') => out.push('\t'),
                    Some(b'b') => out.push('\u{0008}'),
                    Some(b'f') => out.push('\u{000c}'),
                    Some(b'u') => {
                        let hex = bytes.get(*position + 1..*position + 5).ok_or(ParseError::NotObject)?;
                        let code = u32::from_str_radix(std::str::from_utf8(hex).unwrap_or(""), 16)
                            .map_err(|_| ParseError::NotObject)?;
                        out.push(char::from_u32(code).unwrap_or('\u{fffd}'));
                        *position += 4;
                    }
                    _ => return Err(ParseError::NotObject),
                }
                *position += 1;
            }
            Some(_byte) => {
                let start = *position;
                while matches!(bytes.get(*position), Some(b) if *b != b'"' && *b != b'\\') {
                    *position += 1;
                }
                let slice = std::str::from_utf8(&bytes[start..*position]).map_err(|_| ParseError::NotObject)?;
                out.push_str(slice);
            }
        }
    }
}

fn parse_array(bytes: &[u8], position: &mut usize, depth: usize) -> Result<Json, ParseError> {
    *position += 1;
    let mut items = Vec::new();
    skip_space(bytes, position);
    if bytes.get(*position) == Some(&b']') {
        *position += 1;
        return Ok(Json::Array(items));
    }
    loop {
        items.push(parse_value(bytes, position, depth + 1)?);
        skip_space(bytes, position);
        match bytes.get(*position) {
            Some(b',') => *position += 1,
            Some(b']') => {
                *position += 1;
                return Ok(Json::Array(items));
            }
            _ => return Err(ParseError::NotObject),
        }
    }
}

fn parse_object(bytes: &[u8], position: &mut usize, depth: usize) -> Result<Json, ParseError> {
    *position += 1;
    let mut entries: Vec<(String, Json)> = Vec::new();
    skip_space(bytes, position);
    if bytes.get(*position) == Some(&b'}') {
        *position += 1;
        return Ok(Json::Object(entries));
    }
    loop {
        skip_space(bytes, position);
        if bytes.get(*position) != Some(&b'"') {
            return Err(ParseError::NotObject);
        }
        let key = parse_string(bytes, position)?;
        skip_space(bytes, position);
        if bytes.get(*position) != Some(&b':') {
            return Err(ParseError::NotObject);
        }
        *position += 1;
        let value = parse_value(bytes, position, depth + 1)?;
        if entries.iter().any(|(name, _)| *name == key) {
            return Err(ParseError::NotObject);
        }
        entries.push((key, value));
        skip_space(bytes, position);
        match bytes.get(*position) {
            Some(b',') => *position += 1,
            Some(b'}') => {
                *position += 1;
                return Ok(Json::Object(entries));
            }
            _ => return Err(ParseError::NotObject),
        }
    }
}

#[cfg(feature = "sdk")]
pub mod sdk;

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Vec<Event> {
        parse_events(
            r#"{"events":[
              {"uid":"b@tuta","summary":"Standup; daily","start":"2026-01-02T09:00:00Z","end":"2026-01-02T09:15:00Z","all_day":false},
              {"uid":"a@tuta","summary":"Holiday","start":"2026-01-01","end":"2026-01-02","all_day":true,"location":"Home"}
            ]}"#,
        )
        .expect("valid export")
    }

    #[test]
    fn parses_and_sorts_events() {
        let events = sample();
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].uid, "a@tuta");
        assert!(events[0].all_day);
        assert_eq!(events[1].summary, "Standup; daily");
    }

    #[test]
    fn refuses_bad_bounds_and_shapes() {
        for input in [
            r#"{"events":[{"uid":"a","start":"2026-13-01","end":"2026-01-02","all_day":true}]}"#,
            r#"{"events":[{"uid":"a","start":"2026-01-01T09:00:00Z","end":"2026-01-02T09:00:00+01:00"}]}"#,
            r#"{"events":[{"uid":"","start":"2026-01-01","end":"2026-01-02","all_day":true}]}"#,
            r#"{"events":[{"uid":"a","start":"2026-01-01","end":"2026-01-02","all_day":"yes"}]}"#,
            r#"{"events":[{"uid":"a","start":"2026-01-01","end":"2026-01-02","all_day":true,"status":"MAYBE"}]}"#,
            r#"{"events":{}}"#,
            r#"{"events":[{"uid":"a","start":"2026-01-01","end":"2026-01-02","all_day":true,"extra":1}]}"#,
            r#"{"events":[]} trailing"#,
        ] {
            assert!(parse_events(input).is_err(), "accepted {input}");
        }
    }

    #[test]
    fn renders_deterministic_ics() {
        let events = sample();
        let first = render_ics(&events, "Personal", "2026-01-01T00:00:00Z");
        let second = render_ics(&events, "Personal", "2026-01-01T00:00:00Z");
        assert_eq!(first, second);
        assert!(first.starts_with("BEGIN:VCALENDAR\r\nVERSION:2.0\r\n"));
        assert!(first.ends_with("END:VCALENDAR\r\n"));
        assert!(first.contains("DTSTART;VALUE=DATE:20260101\r\n"));
        assert!(first.contains("DTEND;VALUE=DATE:20260102\r\n"));
        assert!(first.contains("DTSTART:20260102T090000Z\r\n"));
        assert!(first.contains("SUMMARY:Standup\\; daily\r\n"));
        assert!(first.contains("X-WR-CALNAME:Personal\r\n"));
    }

    #[test]
    fn escapes_and_folds_long_lines() {
        let mut events = sample();
        events[1].description = "x".repeat(400);
        let ics = render_ics(&events, "Personal", "2026-01-01T00:00:00Z");
        for line in ics.split("\r\n") {
            assert!(line.len() <= 75, "line over 75 bytes: {line}");
        }
        assert!(ics.contains("\r\n x"));
        let escaped = render_ics(
            &[Event {
                description: "a,b\\c".into(),
                ..events[0].clone()
            }],
            "Personal",
            "2026-01-01T00:00:00Z",
        );
        assert!(escaped.contains("DESCRIPTION:a\\,b\\\\c\r\n"));
    }

    #[test]
    fn fingerprint_tracks_changes() {
        let events = sample();
        let base = fingerprint(&events);
        assert_eq!(base, fingerprint(&events.clone()));
        let mut changed = events.clone();
        changed[0].summary = "Holiday (moved)".into();
        assert_ne!(base, fingerprint(&changed));
        // Order of input does not matter: parse_events sorts.
        let reordered = parse_events(
            r#"{"events":[
              {"uid":"a@tuta","summary":"Holiday","start":"2026-01-01","end":"2026-01-02","all_day":true,"location":"Home"},
              {"uid":"b@tuta","summary":"Standup; daily","start":"2026-01-02T09:00:00Z","end":"2026-01-02T09:15:00Z","all_day":false}
            ]}"#,
        )
        .unwrap();
        assert_eq!(base, fingerprint(&reordered));
    }

    #[test]
    fn json_reader_is_strict() {
        assert_eq!(parse_json(r#"{"a":1}"#), Ok(Json::Object(vec![("a".into(), Json::Number(1))])));
        for bad in [r#"{"a":1,}"#, r#"{"a":1,"a":2}"#, r#"[1,]"#, r#"{"a":"\q"}"#, r#""#] {
            assert!(parse_json(bad).is_err(), "accepted {bad}");
        }
    }
}
