//! Read-only Tuta SDK fetcher (smores56/sdlc#589).
//!
//! This module compiles only with `--features sdk`. It is deliberately absent
//! from the Nix build: TutaBridge consumes a *patched* copy of the SDK produced
//! by its `scripts/sdk-prepare.py` (a pinned tutanota submodule plus a patch
//! series that adds the AEAD reads calendar bodies need), and the Nix sandbox
//! has no such prepared tree. `pkgs/tuta-ics/default.nix` documents the gap and
//! the exact steps a future build needs; the guest ships the ICS renderer and
//! the `ingest-tuta-ics` timer reports the missing fetcher instead of silently
//! skipping the calendar.
//!
//! When the patched SDK is available, this is the only SDK-facing code: log in
//! from the staged session, list the account's calendars, list their events,
//! and map them onto [`Event`]. There is no
//! create/update/delete call, so an account compromise cannot write.

use crate::{is_date, is_utc_instant, Event};

// These are the SDK surfaces this fetcher needs (login plus the generated
// calendar services). They are unresolved until the prepared SDK is added to
// Cargo.toml, which is why `--features sdk` fails by design in this build.
use tutanota::entities::calendar::{CalendarEvent, CalendarEventService, CalendarGroupService};
use tutanota::login::{create_session, Credentials};

/// Fetch every calendar event for the signed-in account.
///
/// `session_dir` is the staged TutaBridge home (`gnupg/`, `pass/`,
/// `config/tutabridge/config.toml`); the SDK's login reads the same `pass`
/// entry the bridge uses, so one one-time login serves mail and calendar.
pub fn fetch_events(session_dir: &str) -> Result<Vec<Event>, String> {
    // The prepared SDK exposes the login helpers the bridge patches in
    // (`initiate_session`, `create_session`, TOTP second factor) and the
    // generated entity services for CalendarEvent/CalendarGroup.
    let session = tuta_sdk_login(session_dir)?;
    let calendars = list_calendars(&session)?;
    let mut events = Vec::new();
    for calendar in calendars {
        for item in list_events(&session, calendar.id)? {
            let all_day = item.start_time.is_none();
            let start = item.start_date.unwrap_or_else(|| epoch_instant(item.start_ms));
            let end = item.end_date.unwrap_or_else(|| epoch_instant(item.end_ms));
            if all_day && (!is_date(&start) || !is_date(&end)) {
                return Err("SDK returned a malformed all-day range".into());
            }
            if !all_day && (!is_utc_instant(&start) || !is_utc_instant(&end)) {
                return Err("SDK returned a non-UTC timed range".into());
            }
            events.push(Event {
                uid: item.id,
                summary: item.summary,
                start,
                end,
                all_day,
                location: item.location,
                description: item.description,
                status: item.status,
                updated: item.updated,
                sequence: item.sequence,
            });
        }
    }
    Ok(events)
}

struct Session;

struct Calendar {
    id: String,
}

struct SdkEvent {
    id: String,
    summary: String,
    start_ms: u64,
    end_ms: u64,
    start_date: Option<String>,
    end_date: Option<String>,
    start_time: Option<String>,
    location: String,
    description: String,
    status: String,
    updated: String,
    sequence: u32,
}

fn tuta_sdk_login(session_dir: &str) -> Result<Session, String> {
    let _ = session_dir;
    // Shape of the future call, kept next to the import it needs:
    //   let credentials: Credentials = pass_credentials(session_dir)?;
    //   let _session = create_session(credentials, "linux", "tuta-ics")?;
    let _typed: Option<(CalendarEvent, CalendarGroupService, CalendarEventService)> = None;
    // tutanota::login::create_session(credentials) with the pass entry named by
    // config.toml's `pass_path`; the AEAD read patches (10/11) resolve the
    // group keys the calendar entities use.
    Err("tuta-ics was built without the prepared Tuta SDK; see docs/kanbei-ingest-tuta.md".into())
}

fn list_calendars(_session: &Session) -> Result<Vec<Calendar>, String> {
    // tutanota::entities::calendar::CalendarGroupService: list, no write.
    Err("tuta-ics was built without the prepared Tuta SDK; see docs/kanbei-ingest-tuta.md".into())
}

fn list_events(_session: &Session, _calendar: String) -> Result<Vec<SdkEvent>, String> {
    // tutanota::entities::calendar::CalendarEventService: list by calendar group.
    Err("tuta-ics was built without the prepared Tuta SDK; see docs/kanbei-ingest-tuta.md".into())
}

fn epoch_instant(milliseconds: u64) -> String {
    tuta_ics::format_utc(milliseconds / 1_000)
}
