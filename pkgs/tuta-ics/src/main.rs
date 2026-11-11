//! CLI for the read-only Tuta calendar fetcher.
//!
//! `--mode render` (the default, and the only mode the Nix build ships) renders
//! a neutral event export to ICS. `--mode fetch` needs the `sdk` feature and a
//! TutaBridge session; it only lists and reads calendar events. No write call
//! exists in this crate.

use std::fs;
use std::io::Read;
use std::process::ExitCode;

use tuta_ics::{fingerprint, parse_events, render_ics};

fn usage() -> ! {
    eprintln!(
        "usage: tuta-ics [--mode render|fetch] [--input <events.json>] [--out <calendar.ics>] \
         [--name <calendar name>] [--session <dir>] [--stamp <UTC instant>] [--print-fingerprint]"
    );
    std::process::exit(64)
}

fn read_input(path: Option<&str>) -> Result<String, String> {
    match path {
        Some(path) => fs::read_to_string(path).map_err(|error| format!("cannot read {path}: {error}")),
        None => {
            let mut buffer = String::new();
            std::io::stdin()
                .read_to_string(&mut buffer)
                .map_err(|error| format!("cannot read stdin: {error}"))?;
            Ok(buffer)
        }
    }
}

fn main() -> ExitCode {
    let mut mode = String::from("render");
    let mut input: Option<String> = None;
    let mut out: Option<String> = None;
    let mut name = String::from("Tuta");
    let mut session: Option<String> = None;
    let mut stamp: Option<String> = None;
    let mut print_fingerprint = false;

    let mut args = std::env::args().skip(1);
    while let Some(argument) = args.next() {
        match argument.as_str() {
            "--mode" => mode = args.next().unwrap_or_else(|| usage()),
            "--input" => input = Some(args.next().unwrap_or_else(|| usage())),
            "--out" => out = Some(args.next().unwrap_or_else(|| usage())),
            "--name" => name = args.next().unwrap_or_else(|| usage()),
            "--session" => session = Some(args.next().unwrap_or_else(|| usage())),
            "--stamp" => stamp = Some(args.next().unwrap_or_else(|| usage())),
            "--print-fingerprint" => print_fingerprint = true,
            "-h" | "--help" => usage(),
            other => {
                eprintln!("tuta-ics: unknown argument {other}");
                usage()
            }
        }
    }

    let source = if mode == "fetch" {
        #[cfg(feature = "sdk")]
        {
            match session.as_deref() {
                Some(dir) => match tuta_ics::sdk::fetch_events(dir) {
                    Ok(events) => tuta_ics::events_json(&events),
                    Err(error) => {
                        eprintln!("tuta-ics: {error}");
                        return ExitCode::from(69);
                    }
                },
                None => {
                    eprintln!("tuta-ics: --session is required with --mode fetch");
                    return ExitCode::from(64);
                }
            }
        }
        #[cfg(not(feature = "sdk"))]
        {
            let _ = session;
            eprintln!(
                "tuta-ics: built without the `sdk` feature; this binary renders exports only \
                 (see docs/kanbei-ingest-tuta.md)"
            );
            return ExitCode::from(78);
        }
    } else {
        match read_input(input.as_deref()) {
            Ok(text) => text,
            Err(error) => {
                eprintln!("tuta-ics: {error}");
                return ExitCode::from(66);
            }
        }
    };

    let events = match parse_events(&source) {
        Ok(events) => events,
        Err(error) => {
            eprintln!("tuta-ics: refused event export: {error:?}");
            return ExitCode::from(65);
        }
    };
    let stamp = stamp.unwrap_or_else(tuta_ics::now_utc);
    if !tuta_ics::is_utc_instant(&stamp) {
        eprintln!("tuta-ics: --stamp must be YYYY-MM-DDTHH:MM:SSZ");
        return ExitCode::from(64);
    }
    let ics = render_ics(&events, &name, &stamp);
    if print_fingerprint {
        println!("{}", fingerprint(&events));
    }
    match out {
        Some(path) => {
            if let Err(error) = fs::write(&path, ics.as_bytes()) {
                eprintln!("tuta-ics: cannot write {path}: {error}");
                return ExitCode::from(73);
            }
        }
        None => print!("{ics}"),
    }
    ExitCode::SUCCESS
}
