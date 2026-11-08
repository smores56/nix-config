"""Entry point; the proxy is implemented in sdlc #459 T2."""

import sys


def main() -> int:
    print("agent-broker: not implemented", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
