import io
import os
import socket
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "modules/lib/photo-triage/src"))

from photo_triage import __version__  # noqa: E402
from photo_triage.cli import build_parser, doctor, main  # noqa: E402


def _set_env(**values):
    old = {key: os.environ.get(key) for key in values}
    os.environ.update(values)
    return old


def _restore_env(old):
    for key, value in old.items():
        if value is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = value


class CliTests(unittest.TestCase):
    def test_version(self):
        with redirect_stdout(io.StringIO()) as out:
            with self.assertRaises(SystemExit) as raised:
                main(["--version"])
        self.assertEqual(raised.exception.code, 0)
        self.assertEqual(out.getvalue().strip(), __version__)

    def test_parser_requires_a_command(self):
        with self.assertRaises(SystemExit):
            build_parser().parse_args([])

    def test_doctor_passes_with_the_data_root_and_both_sockets(self):
        with tempfile.TemporaryDirectory() as tmp:
            data = Path(tmp, "data")
            data.mkdir()
            paths = [Path(tmp, "immich.sock"), Path(tmp, "llm.sock")]
            listeners = []
            for path in paths:
                listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                listener.bind(str(path))
                listener.listen(1)
                listeners.append(listener)
            old = _set_env(
                PHOTO_TRIAGE_DATA_DIR=str(data),
                PHOTO_TRIAGE_IMMICH_SOCKET=str(paths[0]),
                PHOTO_TRIAGE_LLM_SOCKET=str(paths[1]),
            )
            try:
                with redirect_stdout(io.StringIO()) as out:
                    self.assertEqual(doctor(), 0)
                self.assertIn("ok data=", out.getvalue())
            finally:
                _restore_env(old)
                for listener in listeners:
                    listener.close()

    def test_doctor_fails_on_missing_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            old = _set_env(
                PHOTO_TRIAGE_DATA_DIR=str(Path(tmp, "missing")),
                PHOTO_TRIAGE_IMMICH_SOCKET=str(Path(tmp, "missing.sock")),
                PHOTO_TRIAGE_LLM_SOCKET=str(Path(tmp, "missing-llm.sock")),
            )
            try:
                with redirect_stderr(io.StringIO()) as err:
                    self.assertEqual(doctor(), 1)
                self.assertIn("missing data dir", err.getvalue())
            finally:
                _restore_env(old)

    def test_doctor_fails_when_the_socket_is_stale(self):
        with tempfile.TemporaryDirectory() as tmp:
            data = Path(tmp, "data")
            data.mkdir()
            stale = Path(tmp, "stale.sock")
            stale.write_text("")
            old = _set_env(
                PHOTO_TRIAGE_DATA_DIR=str(data),
                PHOTO_TRIAGE_IMMICH_SOCKET=str(stale),
                PHOTO_TRIAGE_LLM_SOCKET=str(stale),
            )
            try:
                with redirect_stderr(io.StringIO()) as err:
                    self.assertEqual(doctor(), 1)
                self.assertIn("not a socket", err.getvalue())
            finally:
                _restore_env(old)

    def test_run_refuses_outside_the_unit(self):
        old = {key: os.environ.get(key) for key in ("PHOTO_TRIAGE_UNIT",)}
        os.environ.pop("PHOTO_TRIAGE_UNIT", None)
        try:
            with redirect_stderr(io.StringIO()) as err:
                self.assertEqual(main(["run"]), 2)
            self.assertIn("run through the service", err.getvalue())
        finally:
            _restore_env(old)

    def test_run_is_a_noop_inside_the_unit(self):
        old = _set_env(PHOTO_TRIAGE_UNIT="1")
        try:
            with redirect_stderr(io.StringIO()):
                self.assertEqual(main(["run"]), 0)
        finally:
            _restore_env(old)

    def test_dev_fixtures_runs_outside_the_unit(self):
        old = {key: os.environ.get(key) for key in ("PHOTO_TRIAGE_UNIT",)}
        os.environ.pop("PHOTO_TRIAGE_UNIT", None)
        try:
            with redirect_stderr(io.StringIO()):
                self.assertEqual(main(["run", "--dev-fixtures"]), 0)
        finally:
            _restore_env(old)


if __name__ == "__main__":
    unittest.main()
