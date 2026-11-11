"""Unit tests for the Kanbei vsock wire format and certificate policy.

The CSR/certificate fixtures are static OpenSSL outputs under ``tests/fixtures/kanbei`` so
the suite stays stdlib-only (the unit-tests check carries Python and git, not OpenSSL).
"""

from __future__ import annotations

import importlib.util
import json
import socket
import struct
import unittest
from pathlib import Path

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "kanbei"


def load_module():
    path = Path(__file__).parents[1] / "modules/lib/kanbei/vsock.py"
    spec = importlib.util.spec_from_file_location("kanbei_vsock", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def fixture(name: str) -> str:
    return (FIXTURES / name).read_text()


class FramingTests(unittest.TestCase):
    def setUp(self):
        self.v = load_module()

    def test_round_trip_one_object(self):
        frame = self.v.encode_frame({"v": 1, "hello": "world"})
        obj, rest = self.v.decode_frame(frame + b"tail")
        self.assertEqual(obj, {"v": 1, "hello": "world"})
        self.assertEqual(rest, b"tail")

    def test_length_is_big_endian(self):
        frame = self.v.encode_frame({"a": 1})
        self.assertEqual(struct.unpack("!I", frame[:4])[0], len(frame) - 4)

    def test_rejects_empty_and_oversize(self):
        with self.assertRaises(self.v.FrameError):
            self.v.encode_frame("not an object")
        with self.assertRaises(self.v.FrameError):
            self.v.encode_frame({"x": "a" * (self.v.MAX_FRAME + 1)})
        for length in (0, self.v.MAX_FRAME + 1):
            with self.assertRaises(self.v.FrameError):
                self.v.decode_frame(struct.pack("!I", length) + b"{}")

    def test_rejects_short_and_invalid_bodies(self):
        with self.assertRaises(self.v.FrameError):
            self.v.decode_frame(b"\x00\x00\x01")
        with self.assertRaises(self.v.FrameError):
            self.v.decode_frame(struct.pack("!I", 5) + b"\xff\xfe\xfd\xfc\xfb")
        with self.assertRaises(self.v.FrameError):
            self.v.decode_frame(self.v.encode_frame({"x": 1})[:-1])
        with self.assertRaises(self.v.FrameError):
            self.v.decode_frame(struct.pack("!I", 2) + b"[]")

    def test_socket_read_write(self):
        left, right = socket.socketpair()
        self.addCleanup(left.close)
        self.addCleanup(right.close)
        self.v.write_frame(left, {"v": 1, "cn": self.v.FIXED_CN, "csr": "x"})
        self.assertEqual(self.v.read_frame(right)["csr"], "x")


class RequestSchemaTests(unittest.TestCase):
    def setUp(self):
        self.v = load_module()

    def good(self):
        return {"v": 1, "cn": self.v.FIXED_CN, "csr": fixture("good.csr")}

    def test_accepts_the_exact_shape(self):
        self.assertIn("BEGIN CERTIFICATE REQUEST", self.v.parse_request(self.good()))

    def test_rejects_extra_or_missing_keys(self):
        request = self.good()
        request["san"] = "evil.example.com"
        with self.assertRaises(self.v.SchemaError):
            self.v.parse_request(request)
        with self.assertRaises(self.v.SchemaError):
            self.v.parse_request({"v": 1, "csr": fixture("good.csr")})

    def test_rejects_other_versions_cns_and_types(self):
        for mutate in (
            lambda r: r.update(v=2),
            lambda r: r.update(v=True),
            lambda r: r.update(v="1"),
            lambda r: r.update(cn="evil.example.com"),
            lambda r: r.update(csr=123),
            lambda r: r.update(csr="a" * (self.v.MAX_CSR_BYTES + 1)),
        ):
            request = self.good()
            mutate(request)
            with self.assertRaises(self.v.SchemaError):
                self.v.parse_request(request)

    def test_error_response_is_an_exception_for_the_guest(self):
        with self.assertRaises(self.v.SchemaError):
            self.v.parse_response({"v": 1, "error": "nope"})
        with self.assertRaises(self.v.SchemaError):
            self.v.parse_response({"v": 1, "error": ""})

    def test_success_response_needs_every_field(self):
        response = self.v.success("-----BEGIN CERTIFICATE-----\nx\n", "2027-01-01T00:00:00Z")
        self.assertEqual(self.v.parse_response(response), response)
        for key in ("cn", "chain", "not_after"):
            broken = dict(response)
            del broken[key]
            with self.assertRaises(self.v.SchemaError):
                self.v.parse_response(broken)


class CsrPolicyTests(unittest.TestCase):
    def setUp(self):
        self.v = load_module()

    def test_ec_p256_with_matching_san(self):
        info = self.v.validate_csr(fixture("good.csr"))
        self.assertEqual(info, {"cn": "kanbei.sammohr.dev", "key_type": "ec", "key_bits": 256})

    def test_ec_p256_without_san(self):
        self.assertEqual(self.v.validate_csr(fixture("nosan.csr"))["key_type"], "ec")

    def test_rsa_2048_or_larger(self):
        path = FIXTURES / "rsa2048.csr"
        if not path.exists():
            self.skipTest("rsa2048 fixture is not present")
        self.assertEqual(self.v.validate_csr(path.read_text())["key_type"], "rsa")

    def test_rejects_wrong_cn(self):
        with self.assertRaisesRegex(self.v.CsrError, "subject CN"):
            self.v.validate_csr(fixture("wrongcn.csr"))

    def test_rejects_extra_san(self):
        with self.assertRaisesRegex(self.v.CsrError, "subjectAltName"):
            self.v.validate_csr(fixture("extrasan.csr"))

    def test_rejects_other_subject_attributes(self):
        with self.assertRaisesRegex(self.v.CsrError, "CN attribute"):
            self.v.validate_csr(fixture("ou.csr"))

    def test_rejects_small_rsa_and_other_algorithms(self):
        with self.assertRaisesRegex(self.v.CsrError, "at least 2048"):
            self.v.validate_csr(fixture("rsa1024.csr"))
        with self.assertRaisesRegex(self.v.CsrError, "not allowed"):
            self.v.validate_csr(fixture("ed25519.csr"))

    def test_rejects_malformed_pem(self):
        good = fixture("good.csr")
        for broken in (
            "",
            "not a pem",
            good + "trailing\n",
            good.replace("CERTIFICATE REQUEST", "CERTIFICATE"),
            good.replace("MII", "!!!"),
        ):
            with self.assertRaises(self.v.CsrError):
                self.v.validate_csr(broken)

    def test_csr_spki_is_the_public_key_only(self):
        spki = self.v.csr_spki(fixture("good.csr"))
        self.assertTrue(spki.startswith(b"\x30"))
        self.assertNotIn(b"PRIVATE", spki)


class CertificatePolicyTests(unittest.TestCase):
    def setUp(self):
        self.v = load_module()

    def test_accepts_fixed_cn_and_reports_expiry(self):
        info = self.v.validate_cert(fixture("cert.pem"))
        self.assertEqual(info["cn"], "kanbei.sammohr.dev")
        self.assertRegex(info["not_after"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")

    def test_rejects_a_certificate_for_another_name(self):
        with self.assertRaisesRegex(self.v.CertError, "subject CN"):
            self.v.validate_cert(fixture("certbad.pem"))

    def test_rejects_a_key_that_differs_from_the_csr(self):
        expected = self.v.csr_spki(fixture("good.csr"))
        with self.assertRaisesRegex(self.v.CertError, "public key"):
            self.v.validate_cert(fixture("cert.pem"), expected_spki=expected)

    def test_same_key_matches(self):
        expected = self.v.csr_spki(fixture("cert.csr"))
        self.v.validate_cert(fixture("cert.pem"), expected_spki=expected)

    def test_chain_split_keeps_order(self):
        chain = fixture("cert.pem") + fixture("certbad.pem")
        blocks = self.v.split_chain(chain)
        self.assertEqual(len(blocks), 2)
        self.assertIn("BEGIN CERTIFICATE", blocks[0])


if __name__ == "__main__":
    unittest.main()
