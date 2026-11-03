"""Offline CLI tests: real worker, private preview and fake native renderer/RPC."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from backend.spatter import daily_draft_cli as cli, draft_preview as dp, draft_rpc_transport as transport
from backend.spatter import renderer_cli as rc
from backend.spatter.test_draft_worker import JOB, KEY, ORIGIN, OWNER, REVIEW, RUN
from backend.spatter.test_renderer_cli import FAKE


class DailyDraftCLITests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.output, self.intake = self.root / "render", self.root / "intake"
        self.output.mkdir(mode=0o700)
        self.intake.mkdir(mode=0o700)
        self.service = self.root / "service.key"
        self.service.write_text(KEY + "\n")
        self.service.chmod(0o600)
        self.signing = self.root / "preview.key"
        self.signing.write_bytes(b"s" * 32)
        self.signing.chmod(0o600)
        self.executable = self.root / "fake-renderer"
        fake = FAKE.format(python=sys.executable, mode="ok")
        fake = fake.replace("MODE = 'ok'", "assert not any(name.startswith('SDI_') for name in os.environ)\n"
                            "assert 'offline_fixture' not in ' '.join(sys.argv)\nMODE = 'ok'")
        self.executable.write_text(fake)
        self.executable.chmod(0o700)
        self.env = {cli.ENV_BACKEND: ORIGIN, cli.ENV_SERVICE_KEY_FILE: str(self.service),
                    rc.ENV_CLI: str(self.executable), rc.ENV_OUTPUT: str(self.output),
                    dp.ENV_DIRECTORY: str(self.intake), dp.ENV_KEY_FILE: str(self.signing),
                    dp.ENV_OWNER: OWNER, dp.ENV_ORIGIN: "https://private-preview.invalid",
                    dp.ENV_QUOTA: str(2**20)}

    def invoke(self, *, args=("--run-once",), settings=None):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = cli.main(args, self.env if settings is None else settings)
        self.assertEqual(stderr.getvalue(), "")
        raw = stdout.getvalue()
        for private in (KEY, str(self.root), ORIGIN, OWNER, JOB, REVIEW, "private-preview.invalid"):
            self.assertNotIn(private, raw)
        return code, json.loads(raw)

    def assert_refused_before_rpc(self, settings):
        with patch.object(transport.BoundedRPCOpener, "open", side_effect=AssertionError("unexpected network call")) as rpc:
            self.assertEqual(self.invoke(settings=settings), (2, {"state": "invalid_configuration"}))
            rpc.assert_not_called()

    def test_explicit_invocation_never_echoes_unknown_arguments(self):
        with patch.object(cli, "_configured") as configure:
            self.assertEqual(self.invoke(args=(KEY,)), (2, {"state": "invalid_invocation"}))
            configure.assert_not_called()

    def test_missing_invalid_and_legacy_configuration_has_no_rpc(self):
        cases = ({}, {**self.env, cli.ENV_BACKEND: "http://example.invalid"},
                 {**self.env, cli.ENV_BACKEND: "https://user:password@example.invalid"},
                 {**self.env, cli.ENV_BACKEND: "https://bad name.invalid"},
                 {**self.env, dp.ENV_OWNER: ""}, {**self.env, dp.ENV_QUOTA: "-1"},
                 {**self.env, rc.ENV_OUTPUT: str(self.root / "missing")},
                 {**self.env, rc.ENV_CLI: str(self.root / "missing-cli")},
                 {**self.env, rc.ENV_TIMEOUT: str(transport.RPC_WALL_SECONDS)})
        for settings in cases:
            self.assert_refused_before_rpc(settings)
        for value in ("sb_publishable_" + "fixture", "legacy.jwt.fixture", KEY + "\n\n", "X" * 513):
            self.service.write_text(value)
            self.assert_refused_before_rpc(self.env)

    def test_private_file_permissions_symlinks_and_fifos_refused(self):
        self.service.chmod(0o644)
        self.assert_refused_before_rpc(self.env)
        self.service.chmod(0o600)
        alias, fifo = self.root / "alias", self.root / "fifo"
        alias.symlink_to(self.service)
        os.mkfifo(fifo, mode=0o600)
        self.assert_refused_before_rpc({**self.env, cli.ENV_SERVICE_KEY_FILE: str(alias)})
        self.assert_refused_before_rpc({**self.env, cli.ENV_SERVICE_KEY_FILE: str(fifo)})
        self.assert_refused_before_rpc({**self.env, dp.ENV_KEY_FILE: str(fifo)})

    def test_malformed_intake_origin_refused_before_preview_or_claim(self):
        cases = ("https://private preview.invalid", "https://private\tpreview.invalid",
                 "https://private\npreview.invalid", "https://private\x1fpreview.invalid",
                 "https://private-preview.invalid/#")
        with patch.object(cli, "renderer_from_env", wraps=rc.renderer_from_env) as configure:
            for origin in cases:
                with self.subTest(origin=origin):
                    self.assert_refused_before_rpc({**self.env, dp.ENV_ORIGIN: origin})
            configure.assert_not_called()

    def test_no_claim_uses_one_rpc_without_rendering_or_echoing_service_reason(self):
        response = io.BytesIO(json.dumps({"claimed": False, "reason": KEY, "job": JOB}).encode())
        with patch.object(transport.BoundedRPCOpener, "open", return_value=response) as rpc:
            self.assertEqual(self.invoke(), (3, {"state": "not_claimed"}))
        rpc.assert_called_once()
        request = rpc.call_args.args[0]
        self.assertEqual(request.full_url, ORIGIN + "/rest/v1/rpc/sdi_spatter_draft_claim")
        self.assertEqual(request.get_header("Apikey"), KEY)
        self.assertIsNone(request.get_header("Authorization"))
        self.assertEqual(list(self.output.iterdir()), [])

    def test_one_pass_retains_private_preview_with_no_release_route(self):
        calls = []

        def wire(request, timeout):
            self.assertGreater(timeout, 0)
            self.assertLessEqual(timeout, transport.RPC_WALL_SECONDS)
            self.assertEqual(request.get_header("Apikey"), KEY)
            name = request.full_url.rsplit("/", 1)[1]
            self.assertIn(name, transport.RPC_NAMES)
            payload = json.loads(request.data)
            calls.append((name, payload))
            if name == "sdi_spatter_draft_claim":
                response = dict(claimed=True, job=JOB, run=RUN, attempt=1, per_run_item_cap=1,
                                planner_seed=payload["p_seed"], brief=payload["p_brief"])
            elif name == "sdi_agent_run_heartbeat":
                response = True
            else:
                response = dict(status="confirmed", state=payload["p_state"], review=REVIEW)
            return io.BytesIO(json.dumps(response).encode())

        with patch.dict(os.environ, {"SDI_SERVICE_KEY": KEY}), patch.object(transport.BoundedRPCOpener, "open", side_effect=wire):
            self.assertEqual(self.invoke(), (0, {"state": "review_pending"}))
        self.assertEqual(sum(name == "sdi_spatter_draft_claim" for name, _ in calls), 1)
        self.assertEqual([payload["p_state"] for _, payload in calls if "p_state" in payload], ["rendering", "review_pending"])
        review = calls[-1][1]["p_review"]
        self.assertEqual(review["creator"], OWNER)
        self.assertTrue((self.intake / review["object_key"]).is_file())
        self.assertTrue({"approval", "destinations", "published"}.isdisjoint(review))

    def test_failure_and_interrupt_are_redacted_and_never_retried(self):
        for error, status in ((RuntimeError(KEY), (1, "unconfirmed")),
                              (KeyboardInterrupt(KEY), (130, "interrupted")),
                              (cli._PassDeadline(KEY), (1, "timed_out"))):
            with patch.object(cli, "run_daily_draft_once", side_effect=error) as worker:
                self.assertEqual(self.invoke(), (status[0], {"state": status[1]}))
                worker.assert_called_once()

    def test_unconfigured_module_command_returns_machine_readable_exit(self):
        run = subprocess.run([sys.executable, "-B", "-m", "backend.spatter.daily_draft_cli", "--run-once"],
                             env={}, capture_output=True, text=True, timeout=5)
        self.assertEqual((run.returncode, run.stdout, run.stderr), (2, '{"state":"invalid_configuration"}\n', ""))


if __name__ == "__main__":
    unittest.main()
