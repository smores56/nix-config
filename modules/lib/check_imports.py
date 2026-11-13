"""Import every module in a flat directory, so a missing sibling fails the build.

The ingest and search tool directories are assembled by `cp` in a Nix
derivation, which is exactly where a shared module can be missed (a single-file
store path keeps its hash prefix, so `relay_auth.py` lands as
`<hash>-relay_auth.py` and only fails at run time on the host). Importing each
file here turns that class of mistake into a build failure.

Exit codes: 0 every module imported; 1 at least one did not.
"""

from __future__ import annotations

import importlib
import pathlib
import sys


def main(argv: list[str]) -> int:
    root = pathlib.Path(argv[1])
    sys.path.insert(0, str(root))
    failed: list[str] = []
    for path in sorted(root.glob("*.py")):
        try:
            importlib.import_module(path.stem)
        except Exception as exc:  # noqa: BLE001 - any failure is a build failure
            failed.append(f"{path.name}: {type(exc).__name__}: {exc}")
    for line in failed:
        print(line, file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
