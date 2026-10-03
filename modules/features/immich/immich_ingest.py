# immich-ingest: pre-import timestamp normalisation + upload for Google Takeout
# dumps. Immich's storage template files assets by *capture* date, but Takeout
# sets mtime to upload time, so a raw import scatters a decade of photos across
# a few upload dates. `plan` is a read-only coverage report; `normalize` writes
# the resolved capture time into EXIF and the file mtime on staging copies;
# `upload` pushes assets to a live Immich with the same resolved capture time.
# Originals are never deleted or moved.
#
# Capture-time priority: Takeout sidecar > filename > EXIF > mtime. Timezones
# are deliberately NOT converted here: sidecar epochs are UTC and become naive
# UTC, while filename/EXIF values stay local-naive. Immich re-derives its own
# display timezone later; T1 only needs the date/time preserved consistently.
import argparse
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from collections import Counter, namedtuple
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone

Row = namedtuple("Row", ["path", "when", "source"])
Action = namedtuple("Action", ["path", "when", "write_exif", "write_mtime"])

SOURCE_ORDER = ("sidecar", "filename", "exif", "mtime")
EXIF_FORMAT = "%Y:%m:%d %H:%M:%S"
COLLISION_PREVIEW = 20


def _load_photobucket():
    # The Nix wrapper ships photobucket.py as a separate store path; the env var
    # bridges that, while tests fall back to the in-repo sibling layout.
    path = os.environ.get("IMMICH_INGEST_PHOTOBUCKET") or os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        "..",
        "photobucket",
        "photobucket.py",
    )
    spec = importlib.util.spec_from_file_location("photobucket", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_pb = _load_photobucket()
media_files = _pb.media_files
is_media = _pb.is_media
read_exif_batch = _pb.read_exif_batch
exiftool_path = _pb.exiftool_path
parse_filename_date = _pb.parse_filename_date
_as_datetime = _pb._as_datetime

_OFFICE_LENS = re.compile(
    r"(?<!\d)(\d{2})_(\d{2})_(\d{2})[ _]+(\d{1,2})_(\d{2})\s*([AaPp][Mm])"
)


def parse_office_lens(stem):
    """`10_23_17 2_05 AM Office Lens` -> MM_DD_YY H_MM AM. Pure.

    photobucket's parser predates this Takeout/Office Lens shape, so it is
    covered here rather than by editing that tool's tested logic.
    """
    match = _OFFICE_LENS.search(stem)
    if not match:
        return None
    month, day, year, hour, minute, meridiem = match.groups()
    hour = int(hour) % 12 + (12 if meridiem.lower() == "pm" else 0)
    try:
        return datetime(int(year) + 2000, int(month), int(day), hour, int(minute))
    except ValueError:
        return None


def resolve_filename_date(path):
    """Filename-encoded capture time: photobucket's patterns plus Office Lens."""
    parsed = parse_filename_date(path)
    if parsed is not None:
        return parsed
    stem = os.path.splitext(os.path.basename(path))[0]
    return parse_office_lens(stem)


def sidecar_candidates(path):
    """Plausible Takeout sidecar names for `path`, most-specific first."""
    base = os.path.basename(path)
    stem = os.path.splitext(base)[0]
    suffixes = (
        ".supplemental-metadata.json",
        ".metadata.json",
        "-metadata.json",
        ".json",
    )
    names = [prefix + suffix for prefix in (base, stem) for suffix in suffixes]
    # Takeout truncates sidecar stems to 46 chars for long original names.
    if len(base) > 46:
        names.extend(base[:46] + suffix for suffix in suffixes)
    seen = set()
    unique = []
    for name in names:
        if name not in seen:
            seen.add(name)
            unique.append(name)
    return unique


def parse_sidecar(path):
    """Naive datetime from a Takeout sidecar's photoTakenTime, or None."""
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return None
    info = data.get("photoTakenTime") if isinstance(data, dict) else None
    if not isinstance(info, dict):
        return None
    timestamp = info.get("timestamp")
    if timestamp not in (None, "", "-"):
        try:
            return datetime.fromtimestamp(int(timestamp), tz=timezone.utc).replace(
                tzinfo=None
            )
        except (OverflowError, OSError, ValueError):
            pass
    formatted = info.get("formatted")
    if formatted:
        for fmt in (
            "%b %d, %Y, %I:%M:%S %p UTC",
            "%B %d, %Y, %I:%M:%S %p UTC",
            "%d %b %Y, %H:%M:%S UTC",
            "%b %d, %Y, %H:%M:%S UTC",
            "%Y-%m-%d %H:%M:%S",
        ):
            try:
                return datetime.strptime(formatted, fmt)
            except ValueError:
                continue
    return None


def resolve_sidecar(path):
    directory = os.path.dirname(path)
    for name in sidecar_candidates(path):
        candidate = os.path.join(directory, name)
        if os.path.isfile(candidate):
            parsed = parse_sidecar(candidate)
            if parsed is not None:
                return parsed
    return None


def _truncate(value):
    # EXIF stores whole seconds, so resolving at second precision keeps
    # normalize idempotent even for sub-second mtimes / epoch-ms filenames.
    return None if value is None else value.replace(microsecond=0)


def resolve_capture(path, exif=None, mtime=None):
    """(datetime, source) by priority sidecar > filename > exif > mtime."""
    sidecar = resolve_sidecar(path)
    if sidecar is not None:
        return _truncate(sidecar), "sidecar"
    filename_date = resolve_filename_date(path)
    if filename_date is not None:
        return _truncate(filename_date), "filename"
    exif_date = _as_datetime(exif)
    if exif_date is not None:
        return _truncate(exif_date), "exif"
    mtime_date = _as_datetime(mtime)
    if mtime_date is not None:
        return _truncate(mtime_date), "mtime"
    return None, None


def collect_media(sources):
    """Media paths under each source (file or directory), deduped and sorted."""
    found = set()
    for source in sources:
        if os.path.isdir(source):
            found.update(media_files(source))
        elif is_media(source):
            found.add(os.path.realpath(source))
    return sorted(found)


def collect_plan(paths):
    """Resolve every path to a Row; EXIF is read in one chunked batch."""
    exif = read_exif_batch(paths)
    rows = []
    for path in paths:
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            mtime = None
        when, source = resolve_capture(path, exif=exif.get(path), mtime=mtime)
        rows.append(Row(path=path, when=when, source=source))
    return rows


def collisions(rows):
    """Group resolved rows by (day, basename) where more than one file lands."""
    groups = {}
    for row in rows:
        if row.when is None:
            continue
        groups.setdefault((row.when.date(), os.path.basename(row.path)), []).append(row)
    return {key: members for key, members in groups.items() if len(members) > 1}


def report_plan(rows):
    """(exit_code, text) coverage report; nonzero if anything is unresolved."""
    counts = Counter(row.source for row in rows)
    unresolved = [row for row in rows if row.source is None]
    lines = [f"Total media files: {len(rows)}", "Resolved by source (priority order):"]
    for source in SOURCE_ORDER:
        label = f"{source} (unreliable: upload time, not capture)" if source == "mtime" else source
        lines.append(f"  {label}: {counts.get(source, 0)}")
    lines.append(f"Unresolved: {len(unresolved)}")
    for row in unresolved:
        lines.append(f"  {row.path}")
    groups = collisions(rows)
    members = sum(len(group) for group in groups.values())
    lines.append(f"Collisions (same day + basename): {len(groups)} groups / {members} files")
    for (day, name), group in sorted(groups.items())[:COLLISION_PREVIEW]:
        lines.append(f"  {day} {name} (x{len(group)})")
    if len(groups) > COLLISION_PREVIEW:
        lines.append(f"  ... {len(groups) - COLLISION_PREVIEW} more groups")
    return (1 if unresolved else 0), "\n".join(lines)


def plan_normalize(rows, current_exif, current_mtime=None):
    """Actions needed to write each row's capture time; no writes happen here."""
    actions = []
    for row in rows:
        if row.when is None:
            continue
        want_exif = row.when.strftime("%Y-%m-%d %H:%M:%S")
        if current_mtime is not None and row.path in current_mtime:
            have_mtime = current_mtime[row.path]
        else:
            try:
                have_mtime = int(os.path.getmtime(row.path))
            except OSError:
                have_mtime = None
        write_exif = current_exif.get(row.path) != want_exif
        actions.append(
            Action(
                path=row.path,
                when=row.when,
                write_exif=write_exif,
                # exiftool bumps mtime to "now" on write, so any EXIF write must
                # be followed by an mtime restore even if it already matched.
                write_mtime=have_mtime != int(row.when.timestamp()) or write_exif,
            )
        )
    return actions


def apply_action(action, tool):
    if action.write_exif and tool:
        value = action.when.strftime(EXIF_FORMAT)
        subprocess.run(
            [
                tool,
                "-overwrite_original",
                "-q",
                "-q",
                "-m",
                f"-DateTimeOriginal={value}",
                f"-CreateDate={value}",
                action.path,
            ],
            capture_output=True,
            text=True,
            check=False,
        )
    if action.write_mtime:
        stamp = action.when.timestamp()
        os.utime(action.path, (stamp, stamp))


def cmd_plan(args):
    rows = collect_plan(collect_media(args.src))
    code, text = report_plan(rows)
    print(text)
    return code


def cmd_normalize(args):
    paths = collect_media(args.src)
    rows = collect_plan(paths)
    actions = plan_normalize(rows, read_exif_batch(paths))
    changed = [a for a in actions if a.write_exif or a.write_mtime]
    if args.dry_run:
        for action in changed:
            print(f"[dry-run] {action.path} -> {action.when}")
        print(f"[dry-run] would change {len(changed)} files")
        return 0
    tool = exiftool_path()
    if tool is None:
        print("warning: exiftool not found; only file mtimes will be written")
    for action in changed:
        apply_action(action, tool)
    print(f"{len(changed)} files changed")
    return 0


# --- upload ---------------------------------------------------------------
# Immich 3.0.3 quirks baked in here: the API key rides in the x-api-key header,
# the upload check takes hex SHA1, and the per-asset form has no device* fields
# (older clients sent deviceAssetId/deviceId; 3.0.3 rejects unknown form parts).

DEFAULT_URL = "http://smortress:2283"
DEFAULT_API_KEY_FILE = "~/.config/immich-ingest/api-key"
API_KEY_ENV = "IMMICH_API_KEY"
URL_ENV = "IMMICH_URL"
BULK_CHUNK = 500
DEFAULT_WORKERS = 4
MAX_ATTEMPTS = 4
BACKOFF_BASE = 0.5
# Large videos are ~1-2 GB; at observed throughput a 2 GB upload needs ~8 min,
# far beyond the short JSON timeout. Uploads get their own generous budget.
UPLOAD_TIMEOUT = 1800

HttpResponse = namedtuple("HttpResponse", ["status", "body", "headers"])
UploadItem = namedtuple("UploadItem", ["path", "sha1", "when"])


class ImmichError(Exception):
    """A transport or protocol failure that is fatal for the whole run."""


class ConfigError(Exception):
    """Missing or unusable configuration (auth, URL); surfaced to the user."""


_sleep = time.sleep


def http_transport(method, url, headers, body, timeout):
    """Default transport over urllib; the seam tests inject a fake into.

    HTTPError is returned (not raised) so the client can apply its own
    retry policy uniformly to 429/5xx responses.
    """
    request = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return HttpResponse(response.status, response.read(), dict(response.headers))
    except urllib.error.HTTPError as error:
        return HttpResponse(error.code, error.read(), dict(error.headers))


class MultipartStream:
    """Streams one multipart file part from disk instead of holding it in RAM.

    Buffering a 2 GB video into bytes cost ~2 GB per worker; exposing
    read()/readinto()/__len__ lets urllib derive Content-Length and http.client
    send in fixed-size blocks.
    """

    def __init__(self, head, path, tail, file_size):
        self._head = head
        self._tail = tail
        self._path = path
        self._file_size = file_size
        self._stage = 0  # 0=head, 1=file, 2=tail, 3=done
        self._offset = 0
        self._remaining = file_size
        self._handle = None

    def __len__(self):
        return len(self._head) + self._file_size + len(self._tail)

    def read(self, size=-1):
        if size is None or size < 0:
            size = len(self)
        out = bytearray()
        while len(out) < size:
            chunk = self._next(size - len(out))
            if not chunk:
                break
            out += chunk
        return bytes(out)

    def readinto(self, buffer):
        chunk = self.read(len(buffer))
        buffer[: len(chunk)] = chunk
        return len(chunk)

    def close(self):
        self._close_handle()

    def __del__(self):
        self._close_handle()

    def _close_handle(self):
        if self._handle is not None:
            self._handle.close()
            self._handle = None

    def _next(self, want):
        while self._stage < 3:
            if self._stage == 0:
                chunk = _take(self._head, self._offset, want)
                self._offset += len(chunk)
                if chunk:
                    return chunk
                self._stage, self._offset = 1, 0
                self._handle = open(self._path, "rb")
                continue
            if self._stage == 1:
                if self._remaining <= 0:
                    self._close_handle()
                    self._stage, self._offset = 2, 0
                    continue
                chunk = self._handle.read(want if want > 0 else self._remaining)
                if not chunk:
                    self._close_handle()
                    self._stage, self._offset = 2, 0
                    continue
                self._remaining -= len(chunk)
                return chunk
            chunk = _take(self._tail, self._offset, want)
            self._offset += len(chunk)
            if chunk:
                return chunk
            self._stage = 3
        return b""


def _take(buffer, offset, want):
    end = len(buffer) if want <= 0 else min(len(buffer), offset + want)
    return buffer[offset:end]


def encode_multipart_streaming(fields, name, filename, content_type, path, boundary=None):
    """Return (content_type, body) for a single streamed file part.

    `fields` are the plain text parts, `name` the form field carrying the file.
    """
    boundary = boundary or uuid.uuid4().hex
    head = bytearray()
    for field, value in fields:
        head += f"--{boundary}\r\n".encode()
        head += f'Content-Disposition: form-data; name="{field}"\r\n\r\n'.encode()
        head += str(value).encode() + b"\r\n"
    head += f"--{boundary}\r\n".encode()
    head += (
        f'Content-Disposition: form-data; name="{name}"; filename="{filename}"\r\n'
    ).encode()
    head += f"Content-Type: {content_type}\r\n\r\n".encode()
    tail = b"\r\n" + f"--{boundary}--\r\n".encode()
    return (
        f"multipart/form-data; boundary={boundary}",
        MultipartStream(bytes(head), path, tail, os.path.getsize(path)),
    )


def guess_extension(head):
    """Best-effort extension from magic bytes, or None if unrecognised."""
    if head.startswith(b"\xff\xd8\xff"):
        return ".jpg"
    if head.startswith(b"\x89PNG\r\n\x1a\n"):
        return ".png"
    if head.startswith(b"GIF8"):
        return ".gif"
    if head.startswith(b"BM"):
        return ".bmp"
    if head.startswith((b"II*\x00", b"MM\x00*")):
        return ".tiff"
    if head.startswith(b"\x1aE\xdf\xa3"):
        return ".mkv"
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return ".webp"
    if head[:4] == b"RIFF" and head[8:12] == b"AVI ":
        return ".avi"
    if head[4:8] == b"ftyp":
        brand = head[8:12]
        if brand == b"qt  ":
            return ".mov"
        if brand.startswith(b"3g"):
            return ".3gp"
        if brand in (b"heic", b"heix", b"hevc", b"mif1", b"msf1"):
            return ".heic"
        return ".mp4"
    return None


def upload_filename(path):
    """Immich infers MIME from the filename extension and 400s a file with
    none ("Unsupported file type"); Takeout names some captures by date alone,
    so recover an extension from the magic bytes."""
    name = os.path.basename(path)
    if os.path.splitext(name)[1]:
        return name
    with open(path, "rb") as handle:
        head = handle.read(16)
    return name + (guess_extension(head) or "")


def format_iso8601(when):
    """Resolved capture time as Immich's ISO8601 UTC (millisecond) string.

    Naive values are the resolver's local/UTC-naive mix, and normalize writes
    mtime via `datetime.timestamp()` (local-interpretation); interpreting naive
    as local here keeps the uploaded date identical to what normalize produced.
    """
    if when.tzinfo is None:
        when = when.astimezone()
    when = when.astimezone(timezone.utc)
    return when.strftime("%Y-%m-%dT%H:%M:%S.") + f"{when.microsecond // 1000:03d}Z"


def compute_sha1(path, chunk=1 << 20):
    digest = hashlib.sha1()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(chunk), b""):
            digest.update(block)
    return digest.hexdigest()


def chunks(sequence, size):
    for start in range(0, len(sequence), size):
        yield sequence[start : start + size]


def get_api_key(api_key_file):
    """API key from the key file if present, else the environment; never logged."""
    path = os.path.expanduser(api_key_file) if api_key_file else None
    if path and os.path.isfile(path):
        with open(path, "r", encoding="utf-8") as handle:
            key = handle.read().strip()
        if key:
            return key
    env_key = os.environ.get(API_KEY_ENV, "").strip()
    if env_key:
        return env_key
    raise ConfigError(
        f"no Immich API key: write one to {api_key_file} or set {API_KEY_ENV}"
    )


def resolve_url(url):
    return url or os.environ.get(URL_ENV) or DEFAULT_URL


class ImmichClient:
    """Thin Immich 3.0.3 client; `transport`/`sleep` are injectable for tests."""

    def __init__(
        self, url, api_key, transport=None, sleep=None, timeout=60,
        upload_timeout=UPLOAD_TIMEOUT,
    ):
        self.base = url.rstrip("/")
        self.api_key = api_key
        self.transport = transport if transport is not None else http_transport
        self.sleep = sleep if sleep is not None else _sleep
        self.timeout = timeout
        self.upload_timeout = upload_timeout

    def _request(
        self, method, path, headers=None, body=None, json_body=None, timeout=None,
        body_factory=None,
    ):
        url = self.base + path
        request_headers = {"Accept": "application/json"}
        if self.api_key:
            request_headers["x-api-key"] = self.api_key
        if headers:
            request_headers.update(headers)
        payload = body
        if json_body is not None:
            payload = json.dumps(json_body).encode()
            request_headers["Content-Type"] = "application/json"
        for attempt in range(MAX_ATTEMPTS):
            # A streamed body is single-use; rebuild it so retries resend bytes.
            attempt_body = body_factory() if body_factory is not None else payload
            try:
                response = self.transport(
                    method, url, request_headers, attempt_body, timeout or self.timeout
                )
            except Exception:
                # Network-level failures (DNS, reset) are as retryable as 5xx.
                if attempt == MAX_ATTEMPTS - 1:
                    raise
                self.sleep(BACKOFF_BASE * (2**attempt))
                continue
            if response.status == 429 or response.status >= 500:
                if attempt == MAX_ATTEMPTS - 1:
                    return response
                self.sleep(BACKOFF_BASE * (2**attempt))
                continue
            return response
        raise ImmichError(f"unreachable retry state for {method} {path}")

    def bulk_upload_check(self, checks):
        """checks: [(client_id, sha1hex)] -> {client_id: result dict}."""
        results = {}
        for chunk in chunks(list(checks), BULK_CHUNK):
            payload = {
                "assets": [{"id": cid, "checksum": cs} for cid, cs in chunk]
            }
            response = self._request(
                "POST", "/api/assets/bulk-upload-check", json_body=payload
            )
            data = json.loads(response.body.decode() or "{}")
            for item in data.get("results", []):
                results[item["id"]] = item
        return results

    def upload_asset(self, path, when, filename=None):
        iso = format_iso8601(when)
        fields = [("fileCreatedAt", iso), ("fileModifiedAt", iso)]
        name = filename or upload_filename(path)
        boundary = uuid.uuid4().hex

        def body_factory():
            return encode_multipart_streaming(
                fields,
                "assetData",
                name,
                "application/octet-stream",
                path,
                boundary=boundary,
            )[1]

        # Pin Content-Length: urllib otherwise falls back to chunked for a
        # file-like body, and a sized POST is what Immich/Node expects.
        probe = body_factory()
        content_length = len(probe)
        probe.close()
        return self._request(
            "POST",
            "/api/assets",
            headers={
                "Content-Type": f"multipart/form-data; boundary={boundary}",
                "Content-Length": str(content_length),
            },
            timeout=self.upload_timeout,
            body_factory=body_factory,
        )

    def admin_sign_up(self, email, password, name):
        return self._request(
            "POST",
            "/api/auth/admin-sign-up",
            json_body={"email": email, "password": password, "name": name},
        )

    def create_api_key(self, name, permissions):
        return self._request(
            "POST", "/api/api-keys", json_body={"name": name, "permissions": permissions}
        )


def state_dir():
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(
        os.path.expanduser("~"), ".local", "state"
    )
    return os.path.join(base, "immich-ingest")


def manifest_path(sources):
    """Manifest file keyed by the source set, so a rerun of the same job resumes."""
    digest = hashlib.sha1("\n".join(sorted(sources)).encode()).hexdigest()
    return os.path.join(state_dir(), f"upload-{digest}.jsonl")


def load_manifest(path):
    """{(source path, sha1): entry}; last write wins so reruns can supersede."""
    entries = {}
    if not os.path.isfile(path):
        return entries
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            entries[(entry.get("path"), entry.get("sha1"))] = entry
    return entries


def append_manifest(path, entry, lock=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    line = json.dumps(entry, sort_keys=True) + "\n"

    def write():
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(line)

    # Appending under a lock keeps concurrent workers from interleaving lines.
    if lock is not None:
        with lock:
            write()
    else:
        write()


def collect_upload_items(paths):
    rows = {row.path: row.when for row in collect_plan(paths)}
    items = []
    for path in paths:
        try:
            sha1 = compute_sha1(path)
        except OSError as error:
            print(f"skip unreadable: {path}: {error}")
            continue
        items.append(UploadItem(path=path, sha1=sha1, when=rows.get(path)))
    return items


def summary_line(checked, duplicate, uploaded, failed, skipped):
    return (
        f"Summary: checked={checked} duplicate={duplicate} uploaded={uploaded} "
        f"failed={failed} skipped={skipped}"
    )


def cmd_upload(args):
    paths = collect_media(args.src)
    if args.limit is not None:
        paths = paths[: args.limit]
    items = collect_upload_items(paths)

    manifest = manifest_path(args.src)
    entries = load_manifest(manifest)
    uploaded_keys = {
        key for key, entry in entries.items() if entry.get("outcome") == "uploaded"
    }
    skipped = [item for item in items if (item.path, item.sha1) in uploaded_keys]
    pending = [item for item in items if (item.path, item.sha1) not in uploaded_keys]

    if args.dry_run:
        print(
            f"[dry-run] {len(items)} files; {len(skipped)} already uploaded; "
            f"would check/upload {len(pending)}"
        )
        print(summary_line(0, 0, 0, 0, len(skipped)))
        return 0

    if not pending:
        print(summary_line(0, 0, 0, 0, len(skipped)))
        return 0

    try:
        client = ImmichClient(
            resolve_url(args.url),
            get_api_key(args.api_key_file),
            upload_timeout=args.upload_timeout,
        )
    except ConfigError as error:
        print(f"error: {error}")
        return 1

    results = client.bulk_upload_check([(item.path, item.sha1) for item in pending])
    lock = threading.Lock()
    accepted = []
    duplicate = 0
    for item in pending:
        result = results.get(item.path)
        # A missing result is treated as "accept" so an under-reporting server
        # never silently drops a file.
        if result is not None and result.get("action") == "reject":
            duplicate += 1
            append_manifest(
                manifest,
                {"path": item.path, "sha1": item.sha1, "outcome": "duplicate"},
                lock,
            )
        else:
            accepted.append(item)

    def upload_one(item):
        if item.when is None:
            return False, "no capture time resolved"
        try:
            response = client.upload_asset(item.path, item.when)
        except Exception as error:  # per-file isolation: keep the pool running
            return False, str(error)
        if response.status in (200, 201):
            return True, None
        return False, f"HTTP {response.status}"

    uploaded = 0
    failed = 0
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = {pool.submit(upload_one, item): item for item in accepted}
        for future in as_completed(futures):
            item = futures[future]
            ok, error = future.result()
            if ok:
                uploaded += 1
                outcome = {"path": item.path, "sha1": item.sha1, "outcome": "uploaded"}
            else:
                failed += 1
                outcome = {"path": item.path, "sha1": item.sha1, "outcome": "failed"}
                print(f"failed: {item.path}: {error}")
            append_manifest(manifest, outcome, lock)

    print(summary_line(len(pending), duplicate, uploaded, failed, len(skipped)))
    return 1 if failed else 0


def cmd_bootstrap_admin(args):
    # Password only ever arrives on stdin: argv leaks into process listings.
    password = sys.stdin.readline().rstrip("\n")
    if not password:
        print("error: empty password on stdin")
        return 1
    client = ImmichClient(resolve_url(args.url), api_key="")
    response = client.admin_sign_up(args.email, password, args.name)
    if response.status not in (200, 201):
        message = response.body.decode(errors="replace")[:200]
        print(f"error: admin sign-up failed (HTTP {response.status}): {message}")
        print("bootstrap only works on a server with no users")
        return 1
    response = client.create_api_key("immich-ingest", ["asset.upload", "asset.read"])
    if response.status not in (200, 201):
        print(f"error: api key creation failed (HTTP {response.status})")
        return 1
    secret = json.loads(response.body.decode() or "{}").get("secret")
    if not secret:
        print("error: server did not return a key secret")
        return 1
    path = os.path.expanduser(args.key_file)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(secret + "\n")
    os.chmod(path, 0o600)
    # Print the path only; the secret is never echoed.
    print(f"wrote API key to {path}")
    return 0


def main(argv):
    parser = argparse.ArgumentParser(prog="immich-ingest")
    subparsers = parser.add_subparsers(dest="command", required=True)

    plan = subparsers.add_parser("plan", help="read-only capture-time coverage report")
    plan.add_argument("src", nargs="+", help="source file or directory")
    plan.set_defaults(func=cmd_plan)

    normalize = subparsers.add_parser(
        "normalize", help="write capture time into EXIF and mtime"
    )
    normalize.add_argument("src", nargs="+", help="source file or directory")
    normalize.add_argument("--dry-run", action="store_true", help="report only")
    normalize.set_defaults(func=cmd_normalize)

    upload = subparsers.add_parser("upload", help="upload media to a live Immich")
    upload.add_argument("src", nargs="+", help="source file or directory")
    upload.add_argument("--dry-run", action="store_true", help="report only")
    upload.add_argument("--limit", type=int, help="cap the number of files")
    upload.add_argument("--workers", type=int, default=DEFAULT_WORKERS, help="upload workers")
    upload.add_argument(
        "--upload-timeout",
        type=int,
        default=UPLOAD_TIMEOUT,
        help=f"per-file upload timeout in seconds (default {UPLOAD_TIMEOUT})",
    )
    upload.add_argument("--url", help=f"Immich base URL (default {DEFAULT_URL})")
    upload.add_argument(
        "--api-key-file",
        default=DEFAULT_API_KEY_FILE,
        help=f"file holding the API key (default {DEFAULT_API_KEY_FILE})",
    )
    upload.set_defaults(func=cmd_upload)

    bootstrap = subparsers.add_parser(
        "bootstrap-admin", help="create the first admin and an API key"
    )
    bootstrap.add_argument("--email", required=True)
    bootstrap.add_argument("--name", required=True)
    bootstrap.add_argument("--url", help=f"Immich base URL (default {DEFAULT_URL})")
    bootstrap.add_argument(
        "--key-file",
        default=DEFAULT_API_KEY_FILE,
        help=f"where to write the API key (default {DEFAULT_API_KEY_FILE})",
    )
    bootstrap.set_defaults(func=cmd_bootstrap_admin)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
