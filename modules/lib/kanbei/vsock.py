"""Wire format and certificate policy for the Kanbei vsock channels.

Two channels cross the guest boundary:

- chat (guest listens, host relay pipes raw TCP in): TLS terminates in the guest.
- cert (host listens, guest asks for a certificate): the guest sends a CSR and receives
  the signed chain. The private key never leaves the guest.

Both use the same length-prefixed JSON frame: a 4-byte big-endian length followed by one
UTF-8 JSON object. Every message carries ``v: 1`` and the fixed CN ``kanbei.sammohr.dev``;
anything else is rejected before a certificate authority is asked to sign.

The CSR parser is deliberately a small DER reader instead of a third-party x509 library:
the guest image and the unit tests are Python stdlib only, and the accepted shapes are a
short allow-list (one CN, optional SAN with exactly that name, RSA >= 2048 or EC P-256).
"""

from __future__ import annotations

import base64
import binascii
import json
import re
import struct

FIXED_CN = "kanbei.sammohr.dev"
PROTOCOL_VERSION = 1
MAX_FRAME = 64 * 1024
MAX_CSR_BYTES = 16 * 1024
MAX_CERT_BYTES = 64 * 1024

REQUEST_KEYS = frozenset({"v", "cn", "csr"})
SUCCESS_KEYS = frozenset({"v", "cn", "chain", "not_after"})
ERROR_KEYS = frozenset({"v", "error"})

OID_CN = "2.5.4.3"
OID_EXTENSION_REQUEST = "1.2.840.113549.1.9.14"
OID_SUBJECT_ALT_NAME = "2.5.29.17"
OID_RSA = "1.2.840.113549.1.1.1"
OID_EC = "1.2.840.10045.2.1"
OID_P256 = "1.2.840.10045.3.1.7"

PEM_CSR = re.compile(
    r"\A-----BEGIN CERTIFICATE REQUEST-----\r?\n"
    r"([A-Za-z0-9+/=\r\n]+)"
    r"-----END CERTIFICATE REQUEST-----\r?\n?\Z"
)
PEM_CERT = re.compile(
    r"-----BEGIN CERTIFICATE-----\r?\n([A-Za-z0-9+/=\r\n]+)-----END CERTIFICATE-----"
)


class FrameError(ValueError):
    """A frame is oversize, truncated, or not one JSON object."""


class SchemaError(ValueError):
    """A well-formed frame carries the wrong fields for this channel."""


class CsrError(ValueError):
    """A CSR violates the fixed-name or key policy."""


class CertError(ValueError):
    """A returned certificate does not match the fixed name or the requesting key."""


# --- framing ---------------------------------------------------------------------------


def encode_frame(obj: dict) -> bytes:
    if not isinstance(obj, dict):
        raise FrameError("frame body must be a JSON object")
    payload = json.dumps(obj, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    if not payload or len(payload) > MAX_FRAME:
        raise FrameError(f"frame body must be 1..{MAX_FRAME} bytes")
    return struct.pack("!I", len(payload)) + payload


def decode_frame(buf: bytes) -> tuple[dict, bytes]:
    """Return ``(object, remaining_bytes)`` or raise :class:`FrameError`."""
    if len(buf) < 4:
        raise FrameError("short frame header")
    (length,) = struct.unpack("!I", buf[:4])
    if length == 0 or length > MAX_FRAME:
        raise FrameError("frame length out of range")
    if len(buf) < 4 + length:
        raise FrameError("short frame body")
    body = buf[4 : 4 + length]
    try:
        obj = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise FrameError("frame body is not UTF-8 JSON") from exc
    if not isinstance(obj, dict):
        raise FrameError("frame body must be a JSON object")
    return obj, buf[4 + length :]


def recv_exact(sock, count: int) -> bytes:
    chunks = []
    remaining = count
    while remaining:
        chunk = sock.recv(remaining)
        if not chunk:
            raise FrameError("peer closed the channel")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def read_frame(sock) -> dict:
    header = recv_exact(sock, 4)
    (length,) = struct.unpack("!I", header)
    if length == 0 or length > MAX_FRAME:
        raise FrameError("frame length out of range")
    return decode_frame(header + recv_exact(sock, length))[0]


def write_frame(sock, obj: dict) -> None:
    sock.sendall(encode_frame(obj))


# --- request/response schema -----------------------------------------------------------


def parse_request(obj: dict) -> str:
    """Validate the cert-request message and return its CSR PEM."""
    if not isinstance(obj, dict):
        raise SchemaError("request must be an object")
    if frozenset(obj) != REQUEST_KEYS:
        raise SchemaError("request keys must be exactly v, cn, csr")
    version = obj["v"]
    if type(version) is not int or version != PROTOCOL_VERSION:
        raise SchemaError("unsupported protocol version")
    cn = obj["cn"]
    if not isinstance(cn, str) or cn != FIXED_CN:
        raise SchemaError(f"cn must be {FIXED_CN}")
    csr = obj["csr"]
    if not isinstance(csr, str):
        raise SchemaError("csr must be a PEM string")
    if len(csr.encode("utf-8")) > MAX_CSR_BYTES:
        raise SchemaError("csr is larger than the channel allows")
    return csr


def success(chain: str, not_after: str) -> dict:
    return {"v": PROTOCOL_VERSION, "cn": FIXED_CN, "chain": chain, "not_after": not_after}


def error(message: str) -> dict:
    return {"v": PROTOCOL_VERSION, "error": message}


def parse_response(obj: dict) -> dict:
    """Validate a host response; return it unchanged or raise :class:`SchemaError`."""
    if not isinstance(obj, dict):
        raise SchemaError("response must be an object")
    version = obj.get("v")
    if type(version) is not int or version != PROTOCOL_VERSION:
        raise SchemaError("unsupported protocol version")
    if frozenset(obj) == ERROR_KEYS:
        if not isinstance(obj["error"], str) or not obj["error"]:
            raise SchemaError("error must be a non-empty string")
        raise SchemaError(obj["error"])
    if frozenset(obj) != SUCCESS_KEYS:
        raise SchemaError("response must be a success or error object")
    if obj["cn"] != FIXED_CN:
        raise SchemaError(f"response cn must be {FIXED_CN}")
    if not isinstance(obj["chain"], str) or not obj["chain"]:
        raise SchemaError("chain must be a PEM string")
    if not isinstance(obj["not_after"], str) or not obj["not_after"]:
        raise SchemaError("not_after must be a timestamp string")
    return obj


# --- minimal DER reader ----------------------------------------------------------------


def _tlv(data: bytes, offset: int) -> tuple[int, bytes, int]:
    if offset + 2 > len(data):
        raise CsrError("truncated DER tag")
    tag = data[offset]
    first = data[offset + 1]
    offset += 2
    if first < 0x80:
        length = first
    else:
        count = first & 0x7F
        if count == 0 or count > 4 or offset + count > len(data):
            raise CsrError("unsupported DER length")
        if data[offset] == 0:
            raise CsrError("non-minimal DER length")
        length = int.from_bytes(data[offset : offset + count], "big")
        offset += count
        if length < 0x80:
            raise CsrError("non-minimal DER length")
    end = offset + length
    if end > len(data):
        raise CsrError("truncated DER value")
    return tag, data[offset:end], end


def _children(data: bytes, what: str) -> list[tuple[int, bytes]]:
    out = []
    offset = 0
    while offset < len(data):
        tag, value, offset = _tlv(data, offset)
        out.append((tag, value))
    if not out:
        raise CsrError(f"empty {what}")
    return out


def _single(data: bytes, tag: int, what: str) -> bytes:
    got_tag, value, end = _tlv(data, 0)
    if got_tag != tag or end != len(data):
        raise CsrError(f"{what} must be one tag 0x{tag:02x} value")
    return value


def _oid(value: bytes) -> str:
    if not value:
        raise CsrError("empty OID")
    first = value[0]
    parts = [str(first // 40), str(first % 40)]
    number = 0
    started = False
    for byte in value[1:]:
        number = (number << 7) | (byte & 0x7F)
        started = True
        if not byte & 0x80:
            parts.append(str(number))
            number = 0
            started = False
    if started:
        raise CsrError("truncated OID")
    return ".".join(parts)


def _pem_der(pem: str, pattern: re.Pattern[str], what: str, limit: int) -> bytes:
    if not isinstance(pem, str) or len(pem.encode("utf-8")) > limit:
        raise CsrError(f"{what} is empty or too large")
    match = pattern.fullmatch(pem) if what == "csr" else pattern.search(pem)
    if match is None:
        raise CsrError(f"{what} is not a single PEM block")
    if what != "csr" and len(pattern.findall(pem)) != 1:
        raise CsrError(f"{what} must contain exactly one certificate")
    body = re.sub(r"\s+", "", match.group(1))
    try:
        der = base64.b64decode(body, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise CsrError(f"{what} base64 is invalid") from exc
    if not der:
        raise CsrError(f"{what} is empty")
    return der


# --- subject / key / extension policy --------------------------------------------------


def _parse_name(value: bytes) -> list[tuple[str, str]]:
    fields = []
    for tag, rdn in _children(value, "Name"):
        if tag != 0x31:
            raise CsrError("Name must contain SET values")
        entries = _children(rdn, "RelativeDistinguishedName")
        if len(entries) != 1:
            raise CsrError("multi-valued RDNs are not allowed")
        atv_tag, atv = entries[0]
        if atv_tag != 0x30:
            raise CsrError("AttributeTypeAndValue must be a SEQUENCE")
        parts = _children(atv, "AttributeTypeAndValue")
        if len(parts) != 2:
            raise CsrError("AttributeTypeAndValue must hold an OID and one value")
        (oid_tag, oid_value), (value_tag, raw) = parts
        if oid_tag != 0x06:
            raise CsrError("attribute type must be an OID")
        if value_tag not in (0x0C, 0x13):
            raise CsrError("attribute value must be UTF8String or PrintableString")
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise CsrError("attribute value is not UTF-8") from exc
        fields.append((_oid(oid_value), text))
    return fields


def _check_subject(subject: bytes) -> None:
    fields = _parse_name(subject)
    if len(fields) != 1 or fields[0][0] != OID_CN:
        raise CsrError("subject must contain only the CN attribute")
    if fields[0][1] != FIXED_CN:
        raise CsrError(f"subject CN must be {FIXED_CN}")


def _parse_spki(body: bytes) -> tuple[str, int]:
    parts = _children(body, "SubjectPublicKeyInfo")
    if len(parts) != 2:
        raise CsrError("SubjectPublicKeyInfo must hold an algorithm and a key")
    (alg_tag, alg), (key_tag, key_bits) = parts
    if alg_tag != 0x30 or key_tag != 0x03:
        raise CsrError("SubjectPublicKeyInfo is malformed")
    alg_parts = _children(alg, "AlgorithmIdentifier")
    if len(alg_parts) < 1 or alg_parts[0][0] != 0x06:
        raise CsrError("algorithm identifier has no OID")
    algorithm = _oid(alg_parts[0][1])
    if not key_bits or key_bits[0] != 0:
        raise CsrError("public key bit string is malformed")
    key = key_bits[1:]
    if algorithm == OID_RSA:
        modulus, _exponent = _children(_single(key, 0x30, "RSAPublicKey"), "RSAPublicKey")
        if modulus[0] != 0x02:
            raise CsrError("RSA modulus must be an INTEGER")
        bits = len(modulus[1].lstrip(b"\x00")) * 8
        if bits < 2048:
            raise CsrError(f"RSA keys must be at least 2048 bits, got {bits}")
        return "rsa", bits
    if algorithm == OID_EC:
        if len(alg_parts) != 2 or alg_parts[1][0] != 0x06:
            raise CsrError("EC keys must name a curve")
        if _oid(alg_parts[1][1]) != OID_P256:
            raise CsrError("EC keys must use prime256v1 (P-256)")
        if len(key) != 65 or key[0] != 0x04:
            raise CsrError("P-256 public key must be one uncompressed point")
        return "ec", 256
    raise CsrError(f"public key algorithm {algorithm} is not allowed")


def _check_extensions(body: bytes) -> None:
    seen_san = False
    for tag, extension in _children(body, "Extensions"):
        if tag != 0x30:
            raise CsrError("each extension must be a SEQUENCE")
        parts = _children(extension, "Extension")
        if len(parts) not in (2, 3) or parts[0][0] != 0x06 or parts[-1][0] != 0x04:
            raise CsrError("extension must hold an OID and an OCTET STRING")
        oid = _oid(parts[0][1])
        if oid != OID_SUBJECT_ALT_NAME:
            raise CsrError(f"extension {oid} is not allowed")
        if seen_san:
            raise CsrError("duplicate subjectAltName")
        seen_san = True
        names = _children(_single(parts[-1][1], 0x30, "GeneralNames"), "GeneralNames")
        if len(names) != 1 or names[0][0] != 0x82:
            raise CsrError("subjectAltName must hold only one dNSName")
        try:
            dns = names[0][1].decode("ascii")
        except UnicodeDecodeError as exc:
            raise CsrError("subjectAltName is not ASCII") from exc
        if dns != FIXED_CN:
            raise CsrError(f"subjectAltName must be {FIXED_CN}")


def _check_attributes(attributes: bytes) -> None:
    if not attributes:
        return
    seen = False
    for tag, attribute in _children(attributes, "attributes"):
        if tag != 0x30:
            raise CsrError("attribute must be a SEQUENCE")
        parts = _children(attribute, "Attribute")
        if len(parts) != 2 or parts[0][0] != 0x06 or parts[1][0] != 0x31:
            raise CsrError("attribute must hold an OID and a SET")
        oid = _oid(parts[0][1])
        if oid != OID_EXTENSION_REQUEST:
            raise CsrError(f"attribute {oid} is not allowed")
        if seen:
            raise CsrError("duplicate extensionRequest")
        seen = True
        values = _children(parts[1][1], "attribute values")
        if len(values) != 1 or values[0][0] != 0x30:
            raise CsrError("extensionRequest must hold one Extensions value")
        _check_extensions(values[0][1])


# --- CSR and certificate validation ----------------------------------------------------


def _csr_parts(pem: str) -> tuple[bytes, bytes]:
    der = _pem_der(pem, PEM_CSR, "csr", MAX_CSR_BYTES)
    body = _single(der, 0x30, "CertificationRequest")
    parts = _children(body, "CertificationRequest")
    if len(parts) != 3:
        raise CsrError("CertificationRequest must hold three values")
    cri, sig_alg, signature = parts
    if cri[0] != 0x30 or sig_alg[0] != 0x30 or signature[0] != 0x03:
        raise CsrError("CertificationRequest is malformed")
    cri_parts = _children(cri[1], "CertificationRequestInfo")
    if len(cri_parts) != 4:
        raise CsrError("CertificationRequestInfo must hold four values")
    (version_tag, version), (subject_tag, subject), (spki_tag, spki), (attrs_tag, attrs) = cri_parts
    if version_tag != 0x02 or version != b"\x00":
        raise CsrError("only CSR version 0 is allowed")
    if subject_tag != 0x30 or spki_tag != 0x30 or attrs_tag != 0xA0:
        raise CsrError("CertificationRequestInfo is malformed")
    _check_subject(subject)
    _parse_spki(spki)
    _check_attributes(attrs)
    return _encode_tlv(0x30, spki), der


def validate_csr(pem: str) -> dict:
    """Enforce the fixed CN/SAN and key policy; return the accepted key description."""
    spki_der, _der = _csr_parts(pem)
    kind, bits = _parse_spki(_single(spki_der, 0x30, "SubjectPublicKeyInfo"))
    return {"cn": FIXED_CN, "key_type": kind, "key_bits": bits}


def csr_spki(pem: str) -> bytes:
    """The SubjectPublicKeyInfo DER of a CSR (never includes private key material)."""
    return _csr_parts(pem)[0]


def _der_time(value: bytes, tag: int) -> str:
    try:
        text = value.decode("ascii")
    except UnicodeDecodeError as exc:
        raise CertError("certificate time is not ASCII") from exc
    if tag == 0x17:
        if len(text) != 13 or not text.endswith("Z"):
            raise CertError("UTCTime is malformed")
        year = int(text[:2])
        year += 2000 if year < 50 else 1900
        rest = text[2:]
    elif tag == 0x18:
        if len(text) != 15 or not text.endswith("Z"):
            raise CertError("GeneralizedTime is malformed")
        year = int(text[:4])
        rest = text[4:]
    else:
        raise CertError("certificate time has an unknown tag")
    month, day, hour, minute, second = (
        int(rest[0:2]),
        int(rest[2:4]),
        int(rest[4:6]),
        int(rest[6:8]),
        int(rest[8:10]),
    )
    return f"{year:04d}-{month:02d}-{day:02d}T{hour:02d}:{minute:02d}:{second:02d}Z"


def _cert_parts(pem: str) -> tuple[bytes, bytes, str]:
    der = _pem_der(pem, PEM_CERT, "certificate", MAX_CERT_BYTES)
    body = _single(der, 0x30, "Certificate")
    parts = _children(body, "Certificate")
    if len(parts) != 3 or parts[0][0] != 0x30:
        raise CertError("Certificate must hold three values")
    tbs = _children(parts[0][1], "TBSCertificate")
    index = 1 if tbs and tbs[0][0] == 0xA0 else 0
    if len(tbs) < index + 6:
        raise CertError("TBSCertificate is malformed")
    # serial, signature, issuer, validity, subject, spki, [extensions]
    validity = tbs[index + 3]
    subject = tbs[index + 4]
    spki = tbs[index + 5]
    if validity[0] != 0x30 or subject[0] != 0x30 or spki[0] != 0x30:
        raise CertError("TBSCertificate fields are malformed")
    try:
        _check_subject(subject[1])
    except CsrError as exc:
        raise CertError(str(exc)) from exc
    spki_der = _encode_tlv(0x30, spki[1])
    if len(tbs) > index + 6:
        ext_tag, ext_value = tbs[index + 6]
        if ext_tag == 0xA3:
            try:
                body_ext = _single(ext_value, 0x30, "Extensions")
                for tag, extension in _children(body_ext, "Extensions"):
                    parts_ext = _children(extension, "Extension") if tag == 0x30 else []
                    if len(parts_ext) >= 2 and parts_ext[0][0] == 0x06:
                        oid = _oid(parts_ext[0][1])
                        if oid == OID_SUBJECT_ALT_NAME:
                            names = _children(
                                _single(parts_ext[-1][1], 0x30, "GeneralNames"), "GeneralNames"
                            )
                            for name_tag, name in names:
                                if name_tag != 0x82 or name.decode("ascii", "replace") != FIXED_CN:
                                    raise CertError("certificate SAN must be only the fixed CN")
            except CsrError as exc:
                raise CertError(str(exc)) from exc
    times = _children(validity[1], "Validity")
    if len(times) != 2:
        raise CertError("Validity must hold two times")
    return spki_der, der, _der_time(times[1][1], times[1][0])


def _encode_tlv(tag: int, value: bytes) -> bytes:
    length = len(value)
    if length < 0x80:
        header = bytes([tag, length])
    else:
        encoded = length.to_bytes((length.bit_length() + 7) // 8, "big")
        header = bytes([tag, 0x80 | len(encoded)]) + encoded
    return header + value


def validate_cert(pem: str, expected_spki: bytes | None = None) -> dict:
    """Check the leaf name/SAN (and optionally that it carries the CSR's public key)."""
    spki, _der, not_after = _cert_parts(pem)
    if expected_spki is not None and spki != expected_spki:
        raise CertError("certificate public key does not match the CSR")
    return {"cn": FIXED_CN, "not_after": not_after, "spki": spki}


def split_chain(pem: str) -> list[str]:
    """Return the certificate PEM blocks in a chain, in order."""
    blocks = [m.group(0).strip() + "\n" for m in re.finditer(
        r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", pem, re.DOTALL
    )]
    if not blocks:
        raise CertError("chain holds no certificates")
    for block in blocks:
        _pem_der(block, PEM_CERT, "certificate", MAX_CERT_BYTES)
    return blocks
