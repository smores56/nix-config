#!/usr/bin/env python3
"""Assert cloudflare_sync.py's protected sets match the Nix sources.

cloudflare_sync.py hard-codes PROTECTED_PORTS/PROTECTED_SUBDOMAINS as a second
line of defence, so a stale or hand-edited spec cannot publish sshd/the LLM/
SearXNG/ntfy over the tunnel. Those copies must stay in sync with
modules/ports.nix (plus sshd's 22) and modules/protected-services.nix; the flake's
`protected-services-sync` check passes the expected sets in, so this script needs
no Nix parsing.

Usage: protected_services_sync.py <cloudflare_sync.py> <ports-csv> <subdomains-csv>
"""

import importlib.util
import sys


def load_module(path):
    spec = importlib.util.spec_from_file_location("cloudflare_sync", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main(argv):
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    module = load_module(argv[1])
    expected_ports = {int(p) for p in argv[2].split(",") if p}
    expected_subs = {s for s in argv[3].split(",") if s}

    problems = []
    if module.PROTECTED_PORTS != expected_ports:
        problems.append(
            "PROTECTED_PORTS "
            f"{sorted(module.PROTECTED_PORTS)} != {sorted(expected_ports)} "
            "(modules/ports.nix + sshd's 22)"
        )
    if module.PROTECTED_SUBDOMAINS != expected_subs:
        problems.append(
            "PROTECTED_SUBDOMAINS "
            f"{sorted(module.PROTECTED_SUBDOMAINS)} != {sorted(expected_subs)} "
            "(modules/protected-services.nix)"
        )
    for problem in problems:
        print(f"protected-services-sync: {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
