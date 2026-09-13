"""Path confinement for the read-only filesystem tool server.

Stdlib-only on purpose: this is the security-critical logic, so it is testable
without a web framework. `tests/test_path_guard.py` locks the behavior.
"""

from __future__ import annotations

import os
import pathlib
from typing import Iterable, List


class InvalidPath(ValueError):
    """The requested path is malformed."""


class AccessDenied(PermissionError):
    """The requested path resolves outside every allowlisted root."""

    def __init__(self, requested: pathlib.Path, allowed: Iterable[pathlib.Path]) -> None:
        self.requested = requested
        self.allowed = list(allowed)
        super().__init__(f"{requested} is outside the allowed directories")


def parse_allowed(raw: str) -> List[pathlib.Path]:
    """Parse a colon-separated list of roots into resolved absolute paths."""
    roots: List[pathlib.Path] = []
    for entry in raw.split(":"):
        entry = entry.strip()
        if entry:
            roots.append(pathlib.Path(os.path.expanduser(entry)).resolve())
    return roots


def normalize_path(requested_path: str, allowed: Iterable[pathlib.Path]) -> pathlib.Path:
    """Resolve a requested path and confine it to an allowlisted root.

    `resolve()` follows symlinks *before* the containment check, so a symlink
    inside a root that points outside it is rejected.

    Containment is an exact-match-or-ancestor test, never a bare string prefix.
    A prefix test would let `/srv/evil` match the root `/srv/e`; that is the
    class of bug behind CVE-2025-53110 in the MCP filesystem server.
    """
    if "\x00" in requested_path:
        raise InvalidPath("path contains a NUL byte")

    requested = pathlib.Path(os.path.expanduser(requested_path)).resolve()
    roots = list(allowed)

    for root in roots:
        if requested == root or root in requested.parents:
            return requested

    raise AccessDenied(requested, roots)
