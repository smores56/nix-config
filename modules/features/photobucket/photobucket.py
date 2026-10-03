#!/usr/bin/env python3
"""Keyboard-driven photo triage reviewer built on feh, log-first.

Photos are shown one at a time in feh. Pressing 1-9 only *records* a decision
in `decisions.tsv`; nothing moves on keystroke. `apply` performs the moves
later, in bulk, so a miskey is undoable in-session.

WHY slideshow mode: in feh 3.12.2 normal mode an action triggers
`winwidget_destroy` (the window dies), but slideshow mode runs the action and
then always advances (`slideshow_change_image(..., SLIDE_NEXT, ...)`) whether
or not the file moved. So the viewer needs `--slideshow-delay` (a huge delay)
to keep number-key actions usable, and the actions themselves do not need to
move anything.

Pure stdlib. Logic is split into small pure functions so it can be tested
without a display; `main` is a thin argument dispatcher.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone

IMAGE_EXTENSIONS = frozenset(
    {
        "jpg",
        "jpeg",
        "png",
        "heic",
        "heif",
        "gif",
        "webp",
        "tif",
        "tiff",
        "bmp",
        "avif",
    }
)
VIDEO_EXTENSIONS = frozenset(
    {
        "mp4",
        "mov",
        "avi",
        "mkv",
        "webm",
        "m4v",
        "3gp",
        "3g2",
    }
)
MEDIA_EXTENSIONS = IMAGE_EXTENSIONS | VIDEO_EXTENSIONS
TIERS = range(1, 10)
SLIDESHOW_DELAY = "86400"
EXIFTOOL_CHUNK = 500
EXIFTOOL_FALLBACK = "/home/smores/.nix-profile/bin/exiftool"


def root_dir():
    """Root holding all sessions; overridable via PHOTOBUCKET_ROOT."""
    return os.environ.get("PHOTOBUCKET_ROOT") or os.path.join(
        os.path.expanduser("~"), "Pictures", "_triage"
    )


def sanitize(name):
    """Reduce an arbitrary string to a filesystem-safe session-name fragment."""
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "-", name).strip("-.")
    return cleaned or "session"


def session_name(source_dir):
    """Stable session name: sanitized basename + short hash of the abs path."""
    abs_source = os.path.abspath(source_dir)
    digest = hashlib.sha1(abs_source.encode()).hexdigest()[:8]
    return f"{sanitize(os.path.basename(abs_source))}-{digest}"


def session_dir(root, session):
    """Resolve a session argument (name or existing directory) to a path."""
    if os.path.isdir(session):
        return os.path.abspath(session)
    return os.path.join(root, session)


def bucket_dir(session_path, tier):
    return os.path.join(session_path, f"{int(tier):02d}")


# ---------------------------------------------------------------------------
# Media detection (magic bytes, so extensionless files are included)
# ---------------------------------------------------------------------------

def _media_kind_from_magic(head):
    """Classify a file from its leading bytes; returns 'image'/'video'/None."""
    if head.startswith(b"\xff\xd8\xff"):
        return "image"
    if head.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image"
    if head[:6] in (b"GIF87a", b"GIF89a"):
        return "image"
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "image"
    if head[:4] == b"RIFF" and head[8:12] == b"AVI ":
        return "video"
    if head[:4] == b"\x1a\x45\xdf\xa3":  # Matroska / WebM
        return "video"
    if head[4:8] == b"ftyp":
        brand = head[8:12]
        if brand in (b"heic", b"heix", b"heif", b"mif1", b"hevc", b"hevx"):
            return "image"
        return "video"
    return None


def media_kind(path):
    """Return 'image', 'video', or None. Magic bytes first, then extension."""
    try:
        with open(path, "rb") as handle:
            head = handle.read(32)
    except OSError:
        head = b""
    kind = _media_kind_from_magic(head)
    if kind is not None:
        return kind
    ext = os.path.splitext(path)[1].lstrip(".").lower()
    if ext in IMAGE_EXTENSIONS:
        return "image"
    if ext in VIDEO_EXTENSIONS:
        return "video"
    return None


def is_media(path):
    return media_kind(path) is not None


def media_files(source):
    """All media files under `source`, as absolute paths sorted by path."""
    found = []
    for dirpath, _dirnames, filenames in os.walk(source):
        for filename in filenames:
            path = os.path.join(dirpath, filename)
            if is_media(path):
                found.append(os.path.realpath(path))
    return sorted(found)


# ---------------------------------------------------------------------------
# Capture-key sorting (filename datetime > EXIF DateTimeOriginal > mtime)
# ---------------------------------------------------------------------------

def parse_filename_date(path):
    """Extract a datetime encoded in the basename, or None. Pure."""
    stem = os.path.splitext(os.path.basename(path))[0]
    if re.fullmatch(r"\d{13}", stem):
        millis = int(stem) / 1000
        return datetime.fromtimestamp(millis, tz=timezone.utc).replace(tzinfo=None)

    patterns = (
        (r"(\d{4})(\d{2})(\d{2})[_](\d{2})(\d{2})(\d{2})",
         (1, 2, 3, 4, 5, 6)),
        (r"(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})",
         (1, 2, 3, 4, 5, 6)),
        (r"IMG[-_](\d{4})(\d{2})(\d{2})[-_]WA", (1, 2, 3)),
        (r"(\d{4})-(\d{2})-(\d{2})", (1, 2, 3)),
        (r"(?<!\d)(\d{4})(\d{2})(\d{2})(?!\d)", (1, 2, 3)),
    )
    for pattern, groups in patterns:
        match = re.search(pattern, stem)
        if not match:
            continue
        parts = [int(match.group(g)) for g in groups]
        parts += [0] * (6 - len(parts))
        try:
            return datetime(*parts)
        except ValueError:
            continue
    return None


def _as_datetime(value):
    """Coerce a datetime, numeric epoch, or ISO-ish string into a naive datetime.

    `os.path.getmtime` yields a float epoch, so numerics must be handled here or
    the mtime fallback in `capture_key` silently resolves to nothing.
    """
    if value is None:
        return None
    if isinstance(value, datetime):
        return value.replace(tzinfo=None) if value.tzinfo else value
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        try:
            return datetime.fromtimestamp(value)
        except (OverflowError, OSError, ValueError):
            return None
    text = str(value).strip()
    if not text or text == "-":
        return None
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y:%m:%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S"):
        try:
            return datetime.strptime(text, fmt)
        except ValueError:
            continue
    return None


def capture_key(path, filename_date=None, exif=None, mtime=None):
    """Sortable capture key: filename datetime, else EXIF, else mtime.

    Pure: callers pass the pre-resolved components; the only in-function
    derivation is the (pure) filename parse. Missing components fall through
    in priority order; an unresolvable file yields "" and sorts first.
    """
    if filename_date is None:
        filename_date = parse_filename_date(path)
    resolved = _as_datetime(filename_date)
    if resolved is None:
        resolved = _as_datetime(exif)
    if resolved is None:
        resolved = _as_datetime(mtime)
    if resolved is None:
        return ""
    return resolved.isoformat()


def exiftool_path():
    return shutil.which("exiftool") or (
        EXIFTOOL_FALLBACK if os.path.exists(EXIFTOOL_FALLBACK) else None
    )


def read_exif_batch(paths, chunk_size=EXIFTOOL_CHUNK):
    """Map path -> DateTimeOriginal string via chunked exiftool calls.

    Thin I/O wrapper kept separate so pure tests never invoke exiftool.
    """
    tool = exiftool_path()
    if not tool or not paths:
        return {}
    result = {}
    for start in range(0, len(paths), chunk_size):
        chunk = list(paths[start:start + chunk_size])
        try:
            proc = subprocess.run(
                # -f forces a "-" line for files lacking the tag, so stdout maps
                # 1:1 onto `chunk`; without it one tagless file shifts every
                # subsequent line and the length guard below drops the chunk.
                [
                    tool,
                    "-q",
                    "-q",
                    "-f",
                    "-DateTimeOriginal",
                    "-s3",
                    "-d",
                    "%Y-%m-%d %H:%M:%S",
                    *chunk,
                ],
                capture_output=True,
                text=True,
                check=False,
            )
        except OSError:
            return result
        lines = proc.stdout.splitlines()
        if len(lines) != len(chunk):
            continue
        for path, line in zip(chunk, lines):
            value = line.strip()
            if value and value != "-":
                result[path] = value
    return result


def sort_by_capture(paths):
    """Sort paths ascending by capture key, resolving EXIF in one batch."""
    exif = read_exif_batch(paths)
    return sorted(
        paths,
        key=lambda p: capture_key(
            p, exif=exif.get(p), mtime=os.path.getmtime(p)
        ),
    )


# ---------------------------------------------------------------------------
# Decision log
# ---------------------------------------------------------------------------

def decisions_path(session_path):
    return os.path.join(session_path, "decisions.tsv")


def parse_decisions(path):
    """Parse decisions.tsv into a list of (timestamp, tier, source_path)."""
    if not os.path.exists(path):
        return []
    decisions = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            fields = line.rstrip("\n").split("\t")
            if len(fields) < 3:
                continue
            timestamp, tier, source_path = fields[:3]
            decisions.append((timestamp, tier, source_path))
    return decisions


def latest_by_path(decisions):
    """Map each source path to its most recent decision (last line wins)."""
    latest = {}
    for decision in decisions:
        latest[decision[2]] = decision
    return latest


def decided_paths(decisions):
    return {decision[2] for decision in decisions}


def _fsync_write(path, text):
    """Atomically replace `path` with `text`, fsyncing before the rename."""
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        handle.write(text)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, path)


def append_decision(session_path, tier, source_path):
    """Append-only decision line: timestamp, tier, absolute source path."""
    line = "\t".join(
        [datetime.now().isoformat(timespec="seconds"), str(tier), source_path]
    )
    with open(decisions_path(session_path), "a", encoding="utf-8") as handle:
        handle.write(line + "\n")


def append_applied(session_path, tier, source_path, dest_path):
    """Record an apply, fsynced before the move it describes."""
    line = "\t".join(
        [
            datetime.now().isoformat(timespec="seconds"),
            str(tier),
            source_path,
            dest_path,
        ]
    )
    path = os.path.join(session_path, "applied.tsv")
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(line + "\n")
        handle.flush()
        os.fsync(handle.fileno())


def applied_destinations(session_path):
    """Map canonical source_path -> current dest_path from `applied.tsv`.

    `apply` moves files out of their original location, so the decision log's
    source path stops existing on disk. Reading this back keeps one photo one
    identity across apply and any post-apply re-review.
    """
    path = os.path.join(session_path, "applied.tsv")
    result = {}
    if not os.path.exists(path):
        return result
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            fields = line.rstrip("\n").split("\t")
            if len(fields) == 4:
                result[fields[2]] = fields[3]
    return result


def unique_destination(dest_dir, filename, claimed=frozenset()):
    """Collision-safe path in `dest_dir`, suffixing -1, -2, ... before ext."""
    base, ext = os.path.splitext(filename)
    candidate = os.path.join(dest_dir, filename)
    counter = 1
    while candidate in claimed or os.path.exists(candidate):
        candidate = os.path.join(dest_dir, f"{base}-{counter}{ext}")
        counter += 1
    return candidate


def same_content(first, second):
    """True when both files exist with identical size and sha256."""
    try:
        if os.path.getsize(first) != os.path.getsize(second):
            return False
    except OSError:
        return False
    return _sha256(first) == _sha256(second)


def _sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(65536), b""):
            digest.update(block)
    return digest.hexdigest()


# ---------------------------------------------------------------------------
# Review file lists
# ---------------------------------------------------------------------------

def build_review_list(source, session_path):
    """(photos, videos) under source, undecided, photos sorted by capture key."""
    decisions = parse_decisions(decisions_path(session_path))
    excluded = decided_paths(decisions)
    pending = [p for p in media_files(source) if p not in excluded]
    photos = [p for p in pending if media_kind(p) == "image"]
    videos = [p for p in pending if media_kind(p) == "video"]
    return sort_by_capture(photos), videos


def tier_files(session_path, tier):
    """Files currently decided as `tier`, wherever they physically are."""
    latest = latest_by_path(parse_decisions(decisions_path(session_path)))
    applied = applied_destinations(session_path)
    files = []
    for _timestamp, line_tier, source in latest.values():
        if line_tier != str(tier):
            continue
        if os.path.exists(source):
            files.append(source)
            continue
        # Post-apply the file lives in its bucket; resolve it there so the
        # "iterate on maybes" pass still works after an apply.
        dest = applied.get(source)
        if dest and os.path.exists(dest):
            files.append(dest)
    return sort_by_capture(files)


# ---------------------------------------------------------------------------
# Session metadata
# ---------------------------------------------------------------------------

def write_session(session_path, source):
    os.makedirs(session_path, exist_ok=True)
    for tier in TIERS:
        os.makedirs(bucket_dir(session_path, tier), exist_ok=True)
    log = decisions_path(session_path)
    if not os.path.exists(log):
        open(log, "a", encoding="utf-8").close()
    metadata = os.path.join(session_path, "session.json")
    if not os.path.exists(metadata):
        with open(metadata, "w", encoding="utf-8") as handle:
            json.dump(
                {
                    "source": os.path.abspath(source),
                    "created": datetime.now().isoformat(timespec="seconds"),
                },
                handle,
                indent=2,
            )
            handle.write("\n")


def read_session_source(session_path):
    metadata = os.path.join(session_path, "session.json")
    if not os.path.exists(metadata):
        return None
    with open(metadata, encoding="utf-8") as handle:
        return json.load(handle).get("source")


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def cmd_decide(args):
    session_path = session_dir(root_dir(), args.session)
    if not os.path.isdir(session_path):
        print(f"photobucket: no such session: {session_path}", file=sys.stderr)
        return 1
    tier = int(args.tier)
    if tier not in TIERS:
        print(f"photobucket: tier out of range: {tier}", file=sys.stderr)
        return 1
    given = os.path.realpath(args.file)
    if not os.path.exists(given):
        print(f"photobucket: no such file: {args.file}", file=sys.stderr)
        return 1
    # A file already sitting in a bucket maps back to its canonical source, so
    # re-tagging it post-apply updates the decision instead of adding a second
    # identity for the same photo.
    by_dest = {
        dest: source for source, dest in applied_destinations(session_path).items()
    }
    source_path = by_dest.get(given, given)
    append_decision(session_path, tier, source_path)
    print(f"decided tier {tier}: {source_path}")
    return 0


def cmd_undo(args):
    session_path = session_dir(root_dir(), args.session)
    log = decisions_path(session_path)
    decisions = parse_decisions(log)
    if not decisions:
        print("photobucket: nothing to undo", file=sys.stderr)
        return 1
    timestamp, tier, source_path = decisions.pop()
    _fsync_write(log, "".join("\t".join(d) + "\n" for d in decisions))
    print(f"undid tier {tier}: {source_path}")
    return 0


def plan_apply(session_path, latest):
    """Resolve moves for latest decisions. Returns (moves, skips, conflicts).

    A move is (source, tier, dest). Conflicts (destination occupied by a
    different file) abort the whole apply; nothing is guessed.
    """
    moves, skips, conflicts = [], [], []
    claimed = set()
    applied = applied_destinations(session_path)
    for source in sorted(latest):
        _timestamp, tier_text, _source_path = latest[source]
        try:
            tier = int(tier_text)
        except ValueError:
            skips.append((source, "bad tier"))
            continue
        # The canonical source may already have been moved by a previous
        # apply; in that case the file currently sits at its recorded dest.
        current = source if os.path.exists(source) else applied.get(source)
        if not current or not os.path.exists(current):
            skips.append((source, "already moved or absent"))
            continue
        dest_dir = bucket_dir(session_path, tier)
        natural = os.path.join(dest_dir, os.path.basename(current))
        if natural in claimed:
            candidate = unique_destination(dest_dir, os.path.basename(current), claimed)
        elif os.path.exists(natural):
            if same_content(natural, current):
                skips.append((source, "already at destination"))
                continue
            conflicts.append((source, natural))
            continue
        else:
            candidate = natural
        claimed.add(candidate)
        moves.append((current, tier, candidate, source))
    return moves, skips, conflicts


def cmd_apply(args):
    session_path = session_dir(root_dir(), args.session)
    if not os.path.isdir(session_path):
        print(f"photobucket: no such session: {session_path}", file=sys.stderr)
        return 1
    latest = latest_by_path(parse_decisions(decisions_path(session_path)))
    moves, skips, conflicts = plan_apply(session_path, latest)

    if conflicts:
        print(
            "photobucket: refusing to apply; destination already exists with "
            "different content:",
            file=sys.stderr,
        )
        for source, dest in conflicts:
            print(f"  {source} -> {dest}", file=sys.stderr)
        return 1

    if args.dry_run:
        for current, tier, dest, _source in moves:
            print(f"would move tier {tier}: {current} -> {dest}")
        for source, reason in skips:
            print(f"skip ({reason}): {source}")
        print(f"dry-run: {len(moves)} move(s), {len(skips)} skip(s)")
        return 0

    for current, tier, dest, source in moves:
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        if os.path.exists(dest):
            dest = unique_destination(os.path.dirname(dest), os.path.basename(dest))
        # Record against the canonical source so identity survives re-applies.
        append_applied(session_path, tier, source, dest)
        shutil.move(current, dest)
        print(f"moved tier {tier}: {current} -> {dest}")
    for source, reason in skips:
        print(f"skip ({reason}): {source}")
    print(f"applied: {len(moves)} move(s), {len(skips)} skip(s)")
    return 0


def cmd_review(args):
    root = root_dir()
    if args.tier is not None:
        session = args.session or (session_name(args.src) if args.src else None)
        if session is None:
            print("photobucket: --tier requires a source or --session", file=sys.stderr)
            return 1
        session_path = session_dir(root, session)
        if not os.path.isdir(session_path):
            print(f"photobucket: no such session: {session_path}", file=sys.stderr)
            return 1
        decided = tier_files(session_path, args.tier)
        photos = [p for p in decided if media_kind(p) == "image"]
        videos = [p for p in decided if media_kind(p) == "video"]
    else:
        if not args.src:
            print("photobucket: review requires a source directory", file=sys.stderr)
            return 1
        session = args.session or session_name(args.src)
        session_path = session_dir(root, session)
        write_session(session_path, args.src)
        photos, videos = build_review_list(args.src, session_path)

    if videos:
        print(
            f"photobucket: excluding {len(videos)} video(s) feh cannot display"
        )
    if not photos:
        print(
            f"photobucket: no photos to review in session {session}", file=sys.stderr
        )
        return 1

    filelist = os.path.join(session_path, "filelist.txt")
    with open(filelist, "w", encoding="utf-8") as handle:
        handle.write("\n".join(photos) + "\n")

    argv = ["feh"]
    if args.grid:
        argv += ["-t"]
    else:
        argv += ["--slideshow-delay", SLIDESHOW_DELAY]
    # `--sort none` is required: feh applies --sort to the explicit --filelist
    # too, so `--sort mtime` would re-order by upload time and destroy the
    # capture-key ordering computed in build_review_list.
    argv += [
        "--sort",
        "none",
        "--scale-down",
        "--draw-filename",
        "--filelist",
        filelist,
        "--action",
        f"photobucket undo {session}",
    ]
    for tier in TIERS:
        argv += [f"--action{tier}", f"photobucket decide {session} {tier} %F"]
    os.execvp("feh", argv)


def cmd_report(args):
    session_path = session_dir(root_dir(), args.session)
    latest = latest_by_path(parse_decisions(decisions_path(session_path)))
    counts = {tier: 0 for tier in TIERS}
    for _timestamp, tier_text, _source in latest.values():
        try:
            tier = int(tier_text)
        except ValueError:
            continue
        if tier in counts:
            counts[tier] += 1
    for tier in TIERS:
        print(f"tier {tier}: {counts[tier]}")
    print(f"total decided: {len(latest)}")

    source = read_session_source(session_path)
    if source and os.path.isdir(source):
        remaining = [
            p
            for p in media_files(source)
            if p not in decided_paths(parse_decisions(decisions_path(session_path)))
        ]
        videos = [p for p in remaining if media_kind(p) == "video"]
        print(f"undecided remaining: {len(remaining)}")
        print(f"videos excluded: {len(videos)}")
    return 0


def cmd_sessions(_args):
    root = root_dir()
    if not os.path.isdir(root):
        return 0
    for name in sorted(os.listdir(root)):
        session_path = os.path.join(root, name)
        log = decisions_path(session_path)
        if not os.path.isfile(log):
            continue
        count = len(latest_by_path(parse_decisions(log)))
        source = read_session_source(session_path)
        print(f"{name}\t{count}\t{source or ''}")
    return 0


def main(argv):
    parser = argparse.ArgumentParser(prog="photobucket")
    subparsers = parser.add_subparsers(dest="command", required=True)

    review = subparsers.add_parser("review", help="open feh for a source or tier")
    review.add_argument("src", nargs="?", help="source directory")
    review.add_argument("--session", help="session name")
    review.add_argument("--tier", type=int, choices=list(TIERS), help="re-review tier 0N")
    review.add_argument("--grid", action="store_true", help="thumbnail grid mode")
    review.set_defaults(func=cmd_review)

    decide = subparsers.add_parser("decide", help="record a tier decision")
    decide.add_argument("session")
    decide.add_argument("tier", type=int)
    decide.add_argument("file")
    decide.set_defaults(func=cmd_decide)

    undo = subparsers.add_parser("undo", help="pop the most recent decision")
    undo.add_argument("session")
    undo.set_defaults(func=cmd_undo)

    apply_cmd = subparsers.add_parser("apply", help="move decided files to buckets")
    apply_cmd.add_argument("session")
    apply_cmd.add_argument("--dry-run", action="store_true", help="print only")
    apply_cmd.set_defaults(func=cmd_apply)

    report = subparsers.add_parser("report", help="print per-tier counts")
    report.add_argument("session")
    report.set_defaults(func=cmd_report)

    sessions = subparsers.add_parser("sessions", help="list sessions")
    sessions.set_defaults(func=cmd_sessions)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
