"""Allowlist-only DNS responder for the ingest taps.

Each tap's host address listens on UDP/53. A query is answered only when its
qname is in that source's allowlist and its qtype is A or AAAA; every other
name gets REFUSED and every other port-53 destination is dropped by the per-tap
INPUT chain. Private, loopback and link-local answers are refused so a
compromised allowlisted name cannot point a guest at the LAN.

The choice over dnsmasq: one small stdlib responder keyed by the listener's
source is simpler than per-interface dnsmasq instances, and the policy file is
already the single allowlist source.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import select
import socket
import sys
import time
from datetime import datetime, timezone

import policy

TTL_REQUEST_TIMEOUT = 2.0


def log(event: str, **fields: object) -> None:
    record = {"ts": datetime.now(timezone.utc).isoformat(timespec="seconds"), "unit": "ingest-resolver", "event": event}
    record.update(fields)
    print(json.dumps(record, sort_keys=True), flush=True)


def load_policy(path: str) -> dict:
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


class Resolver:
    def __init__(self, policy_data: dict, port: int, bind: tuple[str, int] | None, force_source: str | None):
        self.sources = policy_data["sources"]
        self.port = port
        self.bind = bind
        self.force_source = force_source
        self.by_gateway = {entry["gateway"]: name for name, entry in self.sources.items()}

    def allowlist(self, source: str) -> set[str]:
        return {policy.normalize_host(h) for h in self.sources[source].get("allow", [])}

    def source_for(self, local: str) -> str | None:
        if self.force_source:
            return self.force_source if self.force_source in self.sources else None
        return self.by_gateway.get(local)

    def handle(self, sock: socket.socket, source: str, data: bytes, peer: tuple[str, int]) -> None:
        entry = self.sources[source]
        if not self.force_source and peer[0] != entry["client"]:
            log("drop", reason="unknown_peer", peer=peer[0], source=source)
            return
        try:
            ident, qname, qtype, qclass, question = policy.parse_dns_question(data)
        except policy.PolicyError as exc:
            log("drop", reason=str(exc), peer=peer[0], source=source)
            return
        if qclass != 1 or qtype not in (1, 28):
            log("refuse", source=source, qname=qname, qtype=qtype, reason="unsupported_type")
            sock.sendto(policy.build_dns_response(ident, question, qtype, [], rcode=5), peer)
            return
        if qname not in self.allowlist(source):
            log("refuse", source=source, qname=qname, qtype=qtype, reason="not_allowlisted")
            sock.sendto(policy.build_dns_response(ident, question, qtype, [], rcode=5), peer)
            return
        addresses = self.resolve(qname)
        if not addresses:
            log("answer", source=source, qname=qname, qtype=qtype, addresses=0)
        else:
            log("answer", source=source, qname=qname, qtype=qtype, addresses=len(addresses))
        sock.sendto(policy.build_dns_response(ident, question, qtype, addresses), peer)

    @staticmethod
    def resolve(qname: str) -> list[str]:
        try:
            infos = socket.getaddrinfo(qname, None, type=socket.SOCK_STREAM)
        except OSError as exc:
            log("resolve-failed", qname=qname, reason=str(exc))
            return []
        addresses: list[str] = []
        for info in infos:
            address = info[4][0]
            if address in addresses:
                continue
            ip = ipaddress.ip_address(address)
            if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved:
                log("refuse", qname=qname, address=address, reason="non_public_answer")
                continue
            addresses.append(address)
        return addresses[:8]

    def listeners(self) -> list[tuple[socket.socket, str]]:
        if self.bind is not None:
            source = self.source_for(self.bind[0])
            if source is None:
                raise SystemExit(f"ingest-resolver: no source bound to {self.bind[0]}")
            return [(self._bind(self.bind), source)]
        out: list[tuple[socket.socket, str]] = []
        for gateway, source in self.by_gateway.items():
            try:
                out.append((self._bind((gateway, self.port)), source))
            except OSError as exc:
                log("bind-wait", source=source, gateway=gateway, reason=str(exc))
        return out

    def _bind(self, address: tuple[str, int]) -> socket.socket:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(address)
        log("listen", address=f"{address[0]}:{address[1]}")
        return sock

    def serve(self) -> None:
        listeners = self.listeners()
        if not listeners:
            raise SystemExit(1)
        by_sock = {sock: source for sock, source in listeners}
        while True:
            readable, _, _ = select.select(list(by_sock), [], [], 30)
            if not readable:
                if self.bind is None and len(by_sock) < len(self.by_gateway):
                    for gateway, source in self.by_gateway.items():
                        if any(sock.getsockname()[0] == gateway for sock in by_sock):
                            continue
                        try:
                            sock = self._bind((gateway, self.port))
                            by_sock[sock] = source
                        except OSError:
                            pass
                continue
            for sock in readable:
                try:
                    data, peer = sock.recvfrom(4096)
                except OSError as exc:
                    log("drop", reason=str(exc))
                    continue
                self.handle(sock, by_sock[sock], data, peer)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="ingest-resolver")
    parser.add_argument("--policy", required=True)
    parser.add_argument("--port", type=int)
    parser.add_argument("--bind", help="verification only: single ADDR:PORT listener")
    parser.add_argument("--force-source", help="verification only: treat the listener as this source")
    args = parser.parse_args(argv)

    data = load_policy(args.policy)
    port = args.port or int(data.get("constants", {}).get("dnsPort", 53))
    bind = None
    if args.bind:
        host, bind_port = args.bind.rsplit(":", 1)
        bind = (host, int(bind_port))
        if args.force_source:
            if host not in {"127.0.0.1", "::1", "localhost"}:
                parser.error("--force-source is only valid on a loopback bind")
            if args.force_source not in data["sources"]:
                parser.error(f"unknown source {args.force_source}")
    elif args.force_source:
        parser.error("--force-source requires --bind")
    Resolver(data, port, bind, args.force_source).serve()
    return 0


if __name__ == "__main__":
    sys.exit(main())
