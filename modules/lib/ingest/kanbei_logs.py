"""Touch-gated log viewer for the Kanbei-side units.

Not a daemon: an operator runs it through the absolute sudo wrapper, so the
YubiKey touch (or the host's sudo policy) is the gate:

    /run/wrappers/bin/sudo /run/current-system/sw/bin/kanbei-logs [unit]

It refuses to run without root or outside sudo, then tails the root-only file
logs under /var/log/kanbei-ingest and the journal for the ingest and Kanbei
units (console output included).
"""

from __future__ import annotations

import glob
import os
import subprocess
import sys

LOG_DIR = "/var/log/kanbei-ingest"
# The guest's journal is volatile and never reaches the host; the serial console is
# the only place `inbox poll` and a boot refusal are visible. microvm@kanbei appends
# it here, root-only, so this viewer is the sanctioned reader.
CONSOLE_FILE = "/var/lib/kanbei-vm/console/console.log"
JOURNAL_UNITS = [
    "microvm@kanbei.service",
    "microvm@ingest-tuta.service",
    "microvm@ingest-finance.service",
    "microvm@ingest-brave.service",
    "microvm@ingest-immich.service",
    "microvm@search.service",
    "ingest-age-key.service",
    "ingest-proxy.service",
    "ingest-resolver.service",
    "ingest-heartbeat.service",
    "ingest-writer-cluster-digest.service",
    "search-vm-model.service",
    "search-vm-state.service",
    "search-relay.service",
    "kanbei.service",
    "kanbei-swtpm.service",
]
TAIL = 80


def journal(unit: str) -> None:
    print(f"===== journal: {unit} =====")
    subprocess.run(
        ["journalctl", "-u", unit, "-n", str(TAIL), "--no-pager", "-o", "short-iso"],
        check=False,
    )


def file_tail(path: str) -> None:
    print(f"===== log: {path} =====")
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            lines = handle.readlines()
    except OSError as exc:
        print(f"cannot read {path}: {exc}")
        return
    sys.stdout.writelines(lines[-TAIL:])


def select_logs(wanted: set[str]) -> list[str]:
    """File logs to tail: the ingest plane's, plus the guest console.

    The filter matches the whole path, so `kanbei` also selects the console while
    a source name such as `finance` does not.
    """
    paths = sorted(glob.glob(os.path.join(LOG_DIR, "*.log")))
    paths.append(CONSOLE_FILE)
    return [path for path in paths if not wanted or any(token in path for token in wanted)]


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if os.geteuid() != 0:
        print("kanbei-logs: root required; run /run/wrappers/bin/sudo /run/current-system/sw/bin/kanbei-logs", file=sys.stderr)
        return 2
    if not os.environ.get("SUDO_USER"):
        print("kanbei-logs: run through /run/wrappers/bin/sudo so the touch-gated sudo policy applies", file=sys.stderr)
        return 2

    wanted = set(args)
    logs = select_logs(wanted)
    if wanted:
        units = [unit for unit in JOURNAL_UNITS if any(token in unit for token in wanted)]
    else:
        units = JOURNAL_UNITS
    for path in logs:
        file_tail(path)
    for unit in units:
        journal(unit)
    print(f"kanbei-logs: {len(logs)} file logs, {len(units)} journal units")
    return 0


if __name__ == "__main__":
    sys.exit(main())
