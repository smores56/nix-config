#!/usr/bin/env python3
"""Validate an SMS Import / Export output set against the v2 schema.

Usage: validate-export.py <file-or-directory>

The app exports three file shapes and fixed names:

- ``messages-YYYY-MM-DD.zip``: a ZIP with ``messages.ndjson`` (v2). Each line is one SMS or
  MMS record; every cursor column is a string, app-added tags are ``__``-prefixed, MMS
  records carry ``msg_box`` and the ``__*`` address/parts fields.
- ``calls-YYYY-MM-DD.json``: a JSON array of call-log records.
- ``contacts-YYYY-MM-DD.json``: a JSON array of contacts with nested ``raw_contacts`` and
  ``contacts_data``.

This validates the schema, not the app: it is the check to run against a sample export
after an app update, before assuming the kanbei decrypt service will accept the files.
Exit status is 0 only when every file passes.
"""

from __future__ import annotations

import json
import re
import sys
import zipfile
from pathlib import Path

NAME_PATTERNS = {
    "messages": re.compile(r"^messages-\d{4}-\d{2}-\d{2}\.zip$"),
    "calls": re.compile(r"^calls-\d{4}-\d{2}-\d{2}\.json$"),
    "contacts": re.compile(r"^contacts-\d{4}-\d{2}-\d{2}\.json$"),
}

SMS_REQUIRED = ("_id", "address", "date", "type")
MMS_REQUIRED = ("_id", "date", "msg_box")
CALL_REQUIRED = ("number", "date", "duration", "type")
CONTACT_REQUIRED = ("_id",)


def scalar(value: object) -> bool:
    return isinstance(value, (str, int, float)) and not isinstance(value, bool)


def validate_messages_line(line: str, where: str) -> list[str]:
    errors: list[str] = []
    try:
        record = json.loads(line)
    except json.JSONDecodeError as exc:
        return [f"{where}: not JSON: {exc}"]
    if not isinstance(record, dict):
        return [f"{where}: record is not an object"]
    required = MMS_REQUIRED if "msg_box" in record else SMS_REQUIRED
    for key in required:
        if key not in record:
            errors.append(f"{where}: missing {key}")
        elif not scalar(record[key]):
            errors.append(f"{where}: {key} is not a scalar")
    for key in ("__parts", "__recipient_addresses"):
        if key in record and not isinstance(record[key], list):
            errors.append(f"{where}: {key} is not a list")
    for key in ("__display_name", "__subject"):
        if key in record and not isinstance(record[key], str):
            errors.append(f"{where}: {key} is not a string")
    return errors


def validate_messages(path: Path) -> list[str]:
    errors: list[str] = []
    if not zipfile.is_zipfile(path):
        return [f"{path.name}: not a ZIP"]
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if "messages.ndjson" not in names:
            return [f"{path.name}: messages.ndjson is missing"]
        with archive.open("messages.ndjson") as handle:
            for number, raw in enumerate(handle, start=1):
                line = raw.decode("utf-8", "replace").strip()
                if not line:
                    continue
                errors.extend(validate_messages_line(line, f"{path.name}:{number}"))
    return errors


def validate_calls(path: Path) -> list[str]:
    try:
        records = json.loads(path.read_text("utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return [f"{path.name}: not JSON: {exc}"]
    if not isinstance(records, list):
        return [f"{path.name}: top level is not an array"]
    errors: list[str] = []
    for index, record in enumerate(records):
        where = f"{path.name}[{index}]"
        if not isinstance(record, dict):
            errors.append(f"{where}: not an object")
            continue
        for key in CALL_REQUIRED:
            if key not in record:
                errors.append(f"{where}: missing {key}")
            elif not scalar(record[key]):
                errors.append(f"{where}: {key} is not a scalar")
    return errors


def validate_contacts(path: Path) -> list[str]:
    try:
        records = json.loads(path.read_text("utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return [f"{path.name}: not JSON: {exc}"]
    if not isinstance(records, list):
        return [f"{path.name}: top level is not an array"]
    errors: list[str] = []
    for index, record in enumerate(records):
        where = f"{path.name}[{index}]"
        if not isinstance(record, dict):
            errors.append(f"{where}: not an object")
            continue
        for key in CONTACT_REQUIRED:
            if key not in record or not scalar(record[key]):
                errors.append(f"{where}: missing or non-scalar {key}")
        raw_contacts = record.get("raw_contacts", [])
        if not isinstance(raw_contacts, list):
            errors.append(f"{where}: raw_contacts is not a list")
            continue
        for raw_index, raw in enumerate(raw_contacts):
            if not isinstance(raw, dict):
                errors.append(f"{where}.raw_contacts[{raw_index}]: not an object")
                continue
            data = raw.get("contacts_data", [])
            if not isinstance(data, list):
                errors.append(f"{where}.raw_contacts[{raw_index}]: contacts_data is not a list")
    return errors


def classify(path: Path) -> str | None:
    for kind, pattern in NAME_PATTERNS.items():
        if pattern.match(path.name):
            return kind
    return None


def validate_file(path: Path) -> list[str]:
    kind = classify(path)
    if kind is None:
        return [f"{path.name}: unknown export filename"]
    if kind == "messages":
        return validate_messages(path)
    if kind == "calls":
        return validate_calls(path)
    return validate_contacts(path)


def validate(path: Path) -> dict[str, object]:
    if path.is_dir():
        files = sorted(p for p in path.iterdir() if p.is_file() and not p.name.startswith("."))
        if not files:
            return {"ok": False, "files": [], "errors": [f"{path}: no export files"]}
    else:
        files = [path]
    errors: list[str] = []
    checked: list[str] = []
    for candidate in files:
        checked.append(candidate.name)
        errors.extend(validate_file(candidate))
    return {"ok": not errors, "files": checked, "errors": errors}


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: validate-export.py <file-or-directory>", file=sys.stderr)
        return 2
    result = validate(Path(argv[1]))
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
