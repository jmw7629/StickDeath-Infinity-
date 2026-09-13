"""Actual shell/child cancellation probe with a blocked fake selector; no iOS runtime claim."""
import os
import pathlib
import signal
import subprocess
import tempfile
import time
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[2] / 'scripts/native-smoke/run_smoke_ci.sh'


class EvidencePath(unittest.TestCase):
    def test_cancellation_preserves_the_already_published_evidence_directory(self):
        with tempfile.TemporaryDirectory(prefix='sdi-evidence-path-test-') as temporary:
            root = pathlib.Path(temporary).resolve()
            checkout = root / 'checkout'
            checkout.mkdir()
            script = checkout / 'run_smoke_ci.sh'
            script.write_bytes(SCRIPT.read_bytes())
            tools = root / 'controlled-tools'
            tools.mkdir()
            selector = tools / 'python3'
            selector.write_text('#!/bin/bash\nexec /bin/sleep 30\n')
            selector.chmod(0o700)
            runner = root / 'runner'
            runner.mkdir()
            output = root / 'github-output'
            output.touch()
            empty_config = root / 'empty-git-config'
            empty_config.touch()
            environment = dict(os.environ, GIT_CONFIG_GLOBAL=str(empty_config),
                               GIT_CONFIG_NOSYSTEM='1')
            # Ignore outer candidate-index routing in this isolated fixture.
            for name in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE'):
                environment.pop(name, None)
            def git(*arguments):
                subprocess.run(['git', *arguments], cwd=checkout, env=environment,
                               check=True, capture_output=True, timeout=10)
            git('init', '-q')
            git('add', 'run_smoke_ci.sh')
            git('-c', 'user.name=SDI Harness Test', '-c', 'user.email=test@example.invalid',
                'commit', '-qm', 'Controlled cancellation fixture')
            environment.update(PATH=str(tools) + os.pathsep + os.defpath,
                               RUNNER_TEMP=str(runner), GITHUB_ACTIONS='true',
                               GITHUB_OUTPUT=str(output),
                               SDI_SMOKE_SIMULATOR_UDID='controlled-selector-never-completes')
            process = subprocess.Popen(['/bin/bash', str(script)], cwd=checkout,
                                       env=environment, start_new_session=True,
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 3
                while not output.read_text() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.02)
                published_before_cancellation = output.read_text()
                self.assertIsNone(process.poll(), 'The controlled child must still be running')
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                captured, _ = process.communicate(timeout=5)
            self.assertNotEqual(process.returncode, 0)
            self.assertTrue(published_before_cancellation.startswith('artifact_path='),
                            'Interrupted runner never published its evidence path: ' + captured.decode(errors='replace'))
            artifact = pathlib.Path(published_before_cancellation.strip().split('=', 1)[1])
            self.assertEqual(artifact.parent, runner)
            self.assertTrue(artifact.name.startswith('sdi-native-smoke.'))
            self.assertTrue(artifact.is_dir())
            marker = runner / 'sdi-native-smoke-artifact-path.txt'
            self.assertEqual(marker.read_text().strip(), str(artifact))
            self.assertEqual(output.read_text(), published_before_cancellation)


if __name__ == '__main__':
    unittest.main()
