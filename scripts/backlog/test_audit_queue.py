"""Offline backlog audit on the checked-in fixture; no GitHub calls."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("sdi_audit_queue", HERE / "audit_queue.py")
subject = importlib.util.module_from_spec(spec)
spec.loader.exec_module(subject)
FIXTURE = HERE / "fixtures/issues-sample.json"


class AuditQueue(unittest.TestCase):
    def report(self):
        return subject.audit(subject.load_issues(json.loads(FIXTURE.read_text())))

    def test_counts_open_next_items_only(self):
        report = self.report()
        self.assertEqual(report["nextOpen"], [124, 125, 126, 300])
        self.assertEqual(report["nextOpenCount"], 4)
        self.assertEqual(report["nextClosedStillLabelled"], [123])
        self.assertFalse(report["queueWithinTarget"])

    def test_dependency_patterns(self):
        blocking, parents = subject.parse_dependencies(
            "Part of #3 and the authoritative delivery tracker #116.\n\n**Dependencies:** #127, #164, #177\nExecute after #123 passes; depends on #9.")
        self.assertEqual(blocking, {127, 164, 177, 123, 9})
        self.assertEqual(parents, {3})
        self.assertEqual(subject.parse_dependencies("**Dependencies:** No child-task dependency; inspect current state first."), (set(), set()))

    def test_cycles_duplicates_ready_and_missing(self):
        report = self.report()
        self.assertEqual(report["blockingCycles"], [[200, 201]])
        self.assertEqual(report["parentCycles"], [])
        self.assertEqual(report["duplicateTitles"], {"verify accessibility and adaptive layouts across the native app": [264, 300]})
        self.assertEqual(report["readyOpenItemsWithAllDependenciesClosed"], [124, 125])
        self.assertEqual(report["blockedOpenItems"], {"126": [124], "200": [201], "201": [200]})
        self.assertEqual(report["closedDependencies"], [123])
        self.assertEqual(report["missingReferences"], {"264": [127, 164, 177]})
        self.assertEqual(report["missingParents"], {"124": [4], "126": [13], "264": [12], "300": [12]})

    def test_rest_shape_and_pull_requests(self):
        issues = subject.load_issues([
            {"number": 1, "title": "A", "state": "open", "labels": [{"name": "sdi:next"}], "body": "", "html_url": "u"},
            {"number": 2, "title": "PR", "state": "open", "labels": [], "body": "", "pull_request": {}},
            {"number": 3, "title": "B", "state": "closed", "labels": ["sdi:next"], "body": "after #1"}])
        self.assertEqual([i["number"] for i in issues], [1, 3])
        self.assertEqual(issues[0]["url"], "u")
        report = subject.audit(issues)
        self.assertEqual(report["nextOpen"], [1])
        self.assertEqual(report["readyOpenItemsWithAllDependenciesClosed"], [])

    def test_invalid_exports_are_rejected(self):
        for payload in ({"number": 1}, [{"title": "no number"}], [{"number": 1, "state": "weird", "title": "x"}],
                        [{"number": 1, "state": "open", "title": "x"}, {"number": 1, "state": "open", "title": "y"}]):
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                subject.load_issues(payload)

    def test_cli_text_and_json_and_exit_code(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = subject.main([str(FIXTURE)])
        self.assertEqual(code, 1)  # the fixture contains a cycle
        text = out.getvalue()
        self.assertIn("Open sdi:next items: 4", text)
        self.assertIn("#200 -> #201 -> #200", text)
        self.assertIn("#264, #300", text)
        self.assertIn("all closed: #124, #125", text)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            subject.main([str(FIXTURE), "--json"])
        self.assertEqual(json.loads(out.getvalue())["nextOpenCount"], 4)
        with tempfile.TemporaryDirectory() as directory:
            clean = Path(directory) / "clean.json"
            clean.write_text(json.dumps([{"number": 1, "title": "x", "state": "OPEN", "labels": [], "body": ""}]))
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(subject.main([str(clean)]), 0)
            broken = Path(directory) / "broken.json"
            broken.write_text("{")
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(subject.main([str(broken)]), 2)


if __name__ == "__main__":
    unittest.main()
