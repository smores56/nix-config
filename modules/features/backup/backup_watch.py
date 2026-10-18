#!/usr/bin/env python3
"""Queue one backup request per debounced batch of source changes.

`inotifywait -m -r` streams every `close_write`, `moved_to`, and `create` under
the source; this helper drops noise (hidden entries, build/sync scratch files,
and dataset-specific derived trees), waits for `--debounce-seconds` of quiet,
then writes one request file into the queue directory.

The queue directory is watched by a systemd `DirectoryNotEmpty=` path unit that
starts the dataset's existing backup service. That predicate is re-checked when
the service exits, so changes arriving during a run cause exactly one follow-up
run; the scheduled timer remains the fallback for anything missed (watcher
restart, inotify queue overflow, events before the watches were installed).

The systemd unit, not this helper, owns the backup: this process never runs the
driver, so the unit's timeout, failure marker, notification, and sandboxing
stay in one place.
"""

import argparse
import fnmatch
import os
import queue
import subprocess
import sys
import threading
import time

# Hidden entries and these scratch names are never media a backup should react
# to. The list is deliberately about writers' conventions, not dataset content;
# per-dataset derived trees (e.g. Immich's thumbs/) come in via --ignore.
IGNORED_NAMES = frozenset({"Thumbs.db", "desktop.ini"})
IGNORED_SUFFIXES = (
    ".part",
    ".partial",
    ".tmp",
    ".temp",
    ".swp",
    ".swo",
    ".crdownload",
    ".download",
    ".aria2",
    ".!qB",
)


class WatcherExit(RuntimeError):
    """The inotify stream ended; the unit restarts the watcher."""


def is_ignored(path, source, ignores=()):
    """Whether a changed path should not count as a change.

    Paths outside the source are ignored (a synthetic/renamed path can resolve
    elsewhere). A path component is matched against the user globs, so
    `--ignore thumbs` drops any `thumbs/` anywhere in the tree.
    """
    relative = os.path.relpath(path, source)
    if relative == os.pardir or relative.startswith(os.pardir + os.sep):
        return True
    if relative == os.curdir:
        return False
    parts = relative.split(os.sep)
    if any(part.startswith(".") for part in parts):
        return True
    if any(part in IGNORED_NAMES for part in parts):
        return True
    if any(fnmatch.fnmatch(part, pattern) for part in parts for pattern in ignores):
        return True
    return parts[-1].endswith(IGNORED_SUFFIXES)


class Debouncer:
    """Collapse a burst into one batch, emitted after a quiet period."""

    def __init__(self, seconds, clock=time.monotonic):
        self.seconds = seconds
        self.clock = clock
        self.dirty = False
        self.last = 0.0

    def note(self, now=None):
        self.dirty = True
        self.last = self.clock() if now is None else now

    def take(self, now=None):
        """True once no event has arrived for `seconds`; clears the batch."""
        now = self.clock() if now is None else now
        if not self.dirty or now - self.last < self.seconds:
            return False
        self.dirty = False
        return True


def write_request(queue_dir):
    """Create a private, uniquely named request file and return its path."""
    os.makedirs(queue_dir, mode=0o700, exist_ok=True)
    path = os.path.join(queue_dir, f"{time.time_ns()}-{os.getpid()}")
    fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.close(fd)
    return path


def pump(stream, events):
    """Forward lines from the inotify stream; "" marks end of stream.

    A reader thread is used instead of selecting on the text stream: Python
    buffers decoded lines, so a later select can report "not ready" while more
    complete lines are already buffered, which would delay a debounce window.
    """
    for line in stream:
        events.put(line)
    events.put("")


def event_reader(events, timeout=1.0):
    """Return the next event line, None on timeout, or "" at end of stream."""
    try:
        return events.get(timeout=timeout)
    except queue.Empty:
        return None


def run_loop(
    source,
    queue_dir,
    debounce_seconds,
    ignores=(),
    read_line=None,
    clock=time.monotonic,
    write=write_request,
):
    """Consume event lines until the stream ends, queueing one file per batch."""
    debouncer = Debouncer(debounce_seconds, clock)
    while True:
        line = read_line(1.0)
        if line == "":
            raise WatcherExit("inotifywait exited")
        if line:
            path = line.rstrip("\n")
            if not is_ignored(path, source, ignores):
                debouncer.note()
        if debouncer.take():
            write(queue_dir)


def watch(source, queue_dir, debounce_seconds, ignores=(), inotify="inotifywait"):
    process = subprocess.Popen(
        [
            inotify,
            "-m",
            "-r",
            "-e",
            "close_write",
            "-e",
            "moved_to",
            "-e",
            "create",
            "--format",
            "%w%f",
            source,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
    )
    events = queue.SimpleQueue()
    threading.Thread(target=pump, args=(process.stdout, events), daemon=True).start()
    try:
        run_loop(
            source,
            queue_dir,
            debounce_seconds,
            ignores,
            read_line=lambda timeout: event_reader(events, timeout),
        )
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, help="directory to watch recursively")
    parser.add_argument("--queue-dir", required=True, help="directory to write request files into")
    parser.add_argument(
        "--debounce-seconds",
        type=int,
        required=True,
        help="quiet period after the last accepted change before queueing a run",
    )
    parser.add_argument(
        "--ignore",
        action="append",
        default=[],
        help="path component or glob whose changes are ignored (repeatable)",
    )
    parser.add_argument("--inotify", default="inotifywait", help="inotifywait binary")
    args = parser.parse_args(argv)
    watch(
        args.source,
        args.queue_dir,
        args.debounce_seconds,
        args.ignore,
        args.inotify,
    )


if __name__ == "__main__":
    main()
