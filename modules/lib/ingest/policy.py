"""Pure policy shared by the ingest writer, proxy, resolver and their unit tests.

Nothing here touches the network or the filesystem: framing, batch schema, hostname
allowlists, age recipients and TLS SNI parsing are the whole contract, so the host
services stay thin and the tests can exercise every rejection path.
"""

from __future__ import annotations

import ipaddress
import json
import re
import struct

# 1 MiB. The decoder rejects a frame before allocating past this bound.
MAX_BATCH_BYTES = 1 << 20
PROTOCOL_VERSION = 1
# Every collector identifies itself: Cloudflare in front of Immich answers 403 to
# urllib's default `Python-urllib/x.y` agent, and a normal agent also lets a WAF
# rule allow this plane deliberately instead of by accident.
USER_AGENT = "kanbei-ingest/1 (+https://kanbei.sammohr.dev)"

# An age X25519 recipient is `age1` plus 58 bech32 characters (52 data + 6 checksum).
AGE_RECIPIENT_RE = re.compile(r"^age1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{58}$")

# Exact, lowercase DNS names only: no wildcard, no port, no scheme, no trailing dot.
HOST_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$")

BATCH_KEYS = {"v", "source", "kind", "seq", "sent_at", "items"}
# `batch` is ordinary source data; `alert` is the same envelope the host writer
# turns into the existing cloudflare-email@ page (a new Sent item, a Tuta client
# rejection). Both carry the same schema so one validator guards the wire.
BATCH_KINDS = {"batch", "alert"}


class PolicyError(ValueError):
    """A frame, name or key that the plane refuses."""


class NeedMoreData(PolicyError):
    """A TLS ClientHello (or frame header) that is not complete yet."""


def _is_ip_literal(name: str) -> bool:
    try:
        ipaddress.ip_address(name)
        return True
    except ValueError:
        return False


def normalize_host(host: object) -> str:
    if not isinstance(host, str):
        raise PolicyError("host is not a string")
    h = host.strip().rstrip(".").lower()
    if not h:
        raise PolicyError("empty host")
    if any(c in h for c in "/:@[] \\"):
        raise PolicyError(f"host contains a scheme, port, userinfo or brackets: {host!r}")
    if _is_ip_literal(h):
        raise PolicyError(f"IP literal refused: {host}")
    if not HOST_RE.match(h):
        raise PolicyError(f"not a DNS hostname: {host!r}")
    return h


def host_allowed(host: object, allow: list[str]) -> bool:
    try:
        h = normalize_host(host)
    except PolicyError:
        return False
    return h in {normalize_host(a) for a in allow}


def parse_authority(authority: str, default_port: int = 443) -> tuple[str, int]:
    """Parse an HTTP CONNECT authority (`host:port`) and refuse IP literals."""
    if not isinstance(authority, str) or not authority:
        raise PolicyError("empty authority")
    if "@" in authority:
        raise PolicyError("userinfo refused")
    host, _, port_text = authority.rpartition(":")
    if not host:
        host, port_text = authority, ""
    if port_text:
        if not port_text.isdigit():
            raise PolicyError(f"non-numeric port: {authority!r}")
        port = int(port_text)
        if not 1 <= port <= 65535:
            raise PolicyError(f"port out of range: {authority!r}")
    else:
        port = default_port
    return normalize_host(host), port


def parse_absolute_form(target: str) -> tuple[str, int, str]:
    """Parse `http://host[:port]/path` into (host, port, origin-form path)."""
    if not isinstance(target, str) or "://" not in target:
        raise PolicyError("not an absolute-form request target")
    scheme, _, rest = target.partition("://")
    if scheme.lower() != "http":
        raise PolicyError(f"absolute-form scheme {scheme!r} refused")
    authority, slash, path = rest.partition("/")
    host, port = parse_authority(authority, default_port=80)
    # The proxy forwards absolute-form requests to the web ports only; anything else would
    # make it a generic forwarder around the CONNECT port policy.
    if port not in (80, 443):
        raise PolicyError("absolute-form requests are limited to ports 80 and 443")
    return host, port, "/" + path if slash else "/"


def parse_host_header(value: str) -> tuple[str, int]:
    if not isinstance(value, str) or not value.strip():
        raise PolicyError("empty Host header")
    return parse_authority(value.strip(), default_port=80)


def validate_age_recipient(text: object) -> str:
    """Accept exactly one `age1...` recipient line; refuse keys and junk."""
    if not isinstance(text, str):
        raise PolicyError("age recipient is not text")
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if len(lines) != 1:
        raise PolicyError("age recipient file must contain exactly one line")
    recipient = lines[0]
    if not AGE_RECIPIENT_RE.match(recipient):
        raise PolicyError("not an age X25519 recipient")
    if len(recipient) != 62:
        raise PolicyError("age recipient has the wrong length")
    return recipient


def parse_client_hello_sni(data: bytes) -> str:
    """Return the SNI from a TLS ClientHello, raising NeedMoreData while truncated."""
    if len(data) < 5:
        raise NeedMoreData("tls record header")
    content_type, version, record_len = struct.unpack(">BHH", data[:5])
    if content_type != 22:
        raise PolicyError("not a TLS handshake record")
    if version >> 8 != 3:
        raise PolicyError("not a TLS record")
    end = 5 + record_len
    if len(data) < end:
        raise NeedMoreData("tls record body")
    body = data[5:end]
    if len(body) < 4:
        raise NeedMoreData("handshake header")
    handshake_type = body[0]
    if handshake_type != 1:
        raise PolicyError("not a ClientHello")
    hs_len = int.from_bytes(body[1:4], "big")
    if len(body) < 4 + hs_len:
        raise NeedMoreData("client hello body")
    hs = body[4 : 4 + hs_len]
    if len(hs) < 34:
        raise NeedMoreData("client hello prefix")
    off = 2 + 32  # legacy_version + random

    if len(hs) < off + 1:
        raise NeedMoreData("session id length")
    session_len = hs[off]
    off += 1 + session_len
    if len(hs) < off + 2:
        raise NeedMoreData("cipher suites length")
    cipher_len = int.from_bytes(hs[off : off + 2], "big")
    off += 2 + cipher_len
    if len(hs) < off + 1:
        raise NeedMoreData("compression length")
    comp_len = hs[off]
    off += 1 + comp_len
    if len(hs) < off + 2:
        raise NeedMoreData("extensions length")
    ext_len = int.from_bytes(hs[off : off + 2], "big")
    off += 2
    ext_end = off + ext_len
    if len(hs) < ext_end:
        raise NeedMoreData("extensions body")
    while off + 4 <= ext_end:
        ext_type = int.from_bytes(hs[off : off + 2], "big")
        length = int.from_bytes(hs[off + 2 : off + 4], "big")
        off += 4
        if off + length > ext_end:
            raise NeedMoreData("extension body")
        if ext_type == 0:  # server_name
            ext = hs[off : off + length]
            if len(ext) < 2:
                raise PolicyError("malformed server_name extension")
            list_len = int.from_bytes(ext[:2], "big")
            if len(ext) < 2 + list_len:
                raise PolicyError("malformed server_name list")
            pos = 2
            list_end = 2 + list_len
            while pos + 3 <= list_end:
                name_type = ext[pos]
                name_len = int.from_bytes(ext[pos + 1 : pos + 3], "big")
                pos += 3
                if pos + name_len > list_end:
                    raise PolicyError("malformed server_name entry")
                if name_type == 0:
                    try:
                        name = ext[pos : pos + name_len].decode("ascii")
                    except UnicodeDecodeError as exc:
                        raise PolicyError("non-ASCII SNI") from exc
                    return normalize_host(name)
                pos += name_len
            raise PolicyError("no host_name entry")
        off += length
    raise PolicyError("ClientHello has no SNI")


def encode_frame(payload: bytes) -> bytes:
    if not payload:
        raise PolicyError("empty frame")
    if len(payload) > MAX_BATCH_BYTES:
        raise PolicyError("frame exceeds the batch cap")
    return struct.pack(">I", len(payload)) + payload


class FrameDecoder:
    """Incremental 4-byte big-endian length-prefixed framing."""

    def __init__(self, max_bytes: int = MAX_BATCH_BYTES):
        self.max_bytes = max_bytes
        self._buf = bytearray()

    def feed(self, chunk: bytes) -> list[bytes]:
        self._buf += chunk
        frames: list[bytes] = []
        while len(self._buf) >= 4:
            length = struct.unpack(">I", self._buf[:4])[0]
            if length == 0 or length > self.max_bytes:
                raise PolicyError(f"frame length {length} outside 1..{self.max_bytes}")
            if len(self._buf) < 4 + length:
                break
            frames.append(bytes(self._buf[4 : 4 + length]))
            del self._buf[: 4 + length]
        return frames

    @property
    def pending(self) -> int:
        return len(self._buf)


def validate_batch(payload: bytes, source: str) -> dict:
    """Return the decoded batch or raise; the caller turns this into a refusal."""
    if not isinstance(payload, (bytes, bytearray)) or not payload:
        raise PolicyError("empty batch")
    if len(payload) > MAX_BATCH_BYTES:
        raise PolicyError("batch exceeds the size cap")
    try:
        text = bytes(payload).decode("utf-8")
    except UnicodeDecodeError as exc:
        raise PolicyError("batch is not UTF-8") from exc
    try:
        batch = json.loads(text)
    except json.JSONDecodeError as exc:
        raise PolicyError("batch is not JSON") from exc
    if not isinstance(batch, dict):
        raise PolicyError("batch is not an object")
    unknown = set(batch) - BATCH_KEYS
    if unknown:
        raise PolicyError(f"batch has unknown keys: {sorted(unknown)}")
    missing = {"v", "source", "kind", "items"} - set(batch)
    if missing:
        raise PolicyError(f"batch is missing keys: {sorted(missing)}")
    if batch["v"] != PROTOCOL_VERSION:
        raise PolicyError(f"unsupported batch version {batch['v']!r}")
    if batch["kind"] not in BATCH_KINDS:
        raise PolicyError(f"unsupported batch kind {batch['kind']!r}")
    if batch["source"] != source:
        raise PolicyError(f"batch source {batch['source']!r} is not {source!r}")
    if not isinstance(batch["items"], list):
        raise PolicyError("batch items is not a list")
    if "seq" in batch and (not isinstance(batch["seq"], int) or batch["seq"] < 0):
        raise PolicyError("batch seq is not a non-negative integer")
    if "sent_at" in batch and not isinstance(batch["sent_at"], str):
        raise PolicyError("batch sent_at is not a string")
    return batch


def validate_heartbeat(envelope: dict) -> dict:
    if not isinstance(envelope, dict):
        raise PolicyError("heartbeat is not an object")
    if envelope.get("v") != PROTOCOL_VERSION:
        raise PolicyError("unsupported heartbeat version")
    if envelope.get("kind") != "heartbeat":
        raise PolicyError("not a heartbeat envelope")
    if not isinstance(envelope.get("sources"), dict):
        raise PolicyError("heartbeat has no sources map")
    for name, status in envelope["sources"].items():
        if not isinstance(status, dict) or "stale" not in status or "window_s" not in status:
            raise PolicyError(f"heartbeat source {name} is malformed")
    return envelope


def parse_dns_question(data: bytes) -> tuple[int, str, int, int, bytes]:
    """Parse one standard query; returns (id, qname, qtype, qclass, question_bytes)."""
    if len(data) < 12:
        raise PolicyError("short DNS message")
    ident, flags, qdcount, _an, _ns, _ar = struct.unpack(">HHHHHH", data[:12])
    if flags & 0x8000:
        raise PolicyError("DNS response, not a query")
    if qdcount != 1:
        raise PolicyError("exactly one question is supported")
    off = 12
    labels: list[str] = []
    while True:
        if off >= len(data):
            raise PolicyError("truncated qname")
        length = data[off]
        off += 1
        if length == 0:
            break
        if length & 0xC0:
            raise PolicyError("compression in the question is refused")
        if length > 63 or off + length > len(data):
            raise PolicyError("bad label")
        try:
            labels.append(data[off : off + length].decode("ascii").lower())
        except UnicodeDecodeError as exc:
            raise PolicyError("non-ASCII qname") from exc
        off += length
        if len(labels) > 127:
            raise PolicyError("qname too long")
    if off + 4 > len(data):
        raise PolicyError("truncated question")
    qtype, qclass = struct.unpack(">HH", data[off : off + 4])
    off += 4
    qname = ".".join(labels)
    if not qname:
        raise PolicyError("empty qname")
    normalize_host(qname)
    return ident, qname, qtype, qclass, data[12:off]


def build_dns_response(
    ident: int, question: bytes, qtype: int, addresses: list[str], rcode: int = 0
) -> bytes:
    flags = 0x8180 | (rcode & 0xF)  # QR, RD, RA
    answers: list[bytes] = []
    if rcode == 0 and addresses:
        for address in addresses:
            ip = ipaddress.ip_address(address)
            if qtype == 1 and ip.version == 4:
                rdata = ip.packed
                rtype = 1
            elif qtype == 28 and ip.version == 6:
                rdata = ip.packed
                rtype = 28
            else:
                continue
            answers.append(
                b"\xc0\x0c"  # pointer to the question name
                + struct.pack(">HHIH", rtype, 1, 60, len(rdata))
                + rdata
            )
    header = struct.pack(">HHHHHH", ident, flags, 1, len(answers), 0, 0)
    return header + question + b"".join(answers)
