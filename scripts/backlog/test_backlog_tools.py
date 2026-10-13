"""Offline tests for the issue-cache adapter, the queue renderer and the ledger merger; no GitHub calls."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
FIXTURE = HERE / "fixtures/issues-sample.json"


def load(name):
    spec = importlib.util.spec_from_file_location("sdi_" + name, HERE / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


adapter = load("issue_cache_adapter")
renderer = load("render_queue")
ledger = load("issue_ledger")


class IssueCacheAdapter(unittest.TestCase):
    def test_parses_heading_labels_state_and_body(self):
        issue = adapter.parse_issue("# #264 [SDI QA01] Verify accessibility\nlabels: sdi:later,P1\n\nPart of #12.\n\n**Dependencies:** #127\n", 264)
        self.assertEqual((issue["number"], issue["title"], issue["state"]), (264, "[SDI QA01] Verify accessibility", "OPEN"))
        self.assertEqual(issue["labels"], [{"name": "sdi:later"}, {"name": "P1"}])
        self.assertTrue(issue["stateAssumed"])
        self.assertEqual(issue["body"], "Part of #12.\n\n**Dependencies:** #127")
        closed = adapter.parse_issue("# #123 Done\nlabels: \nstate: closed\n\nbody", 123)
        self.assertEqual((closed["state"], closed["stateAssumed"], closed["labels"]), ("CLOSED", False, []))

    def test_rejects_bad_heading_number_mismatch_and_unknown_state(self):
        for text, hint in (("no heading", None), ("# #5 Title\n", 6), ("# #5 Title\nstate: weird\n", 5), ("", None)):
            with self.subTest(text=text), self.assertRaises(ValueError):
                adapter.parse_issue(text, hint)

    def test_directory_round_trips_through_audit_queue_and_warns_about_index_gaps(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "3.md").write_text("# #3 [SDI epic] Delivery\nlabels: sdi:epic,P1\n\nEpic.\n")
            (root / "125.md").write_text("# #125 [SDI F03] Map controls\nlabels: sdi:next,P0\n\nPart of #3.\n\n**Dependencies:** #123\n")
            (root / "notes.md").write_text("not an issue")
            (root / "INDEX.tsv").write_text("3\ttitle\tsdi:epic\n125\ttitle\tsdi:next\n999\tmissing\t\n")
            issues, warnings = adapter.load_cache(root)
            self.assertEqual([i["number"] for i in issues], [3, 125])
            self.assertEqual(warnings, ["INDEX.tsv lists #999 but 999.md is missing from the cache"])
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                self.assertEqual(adapter.main([str(root)]), 0)
            payload = json.loads(out.getvalue())
            report = renderer.audit_queue.audit(renderer.audit_queue.load_issues(payload))
            self.assertEqual(report["nextOpen"], [125])
            self.assertEqual(report["missingReferences"], {"125": [123]})
            self.assertIn("2 with state assumed open", err.getvalue())
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(adapter.main([str(root / "absent")]), 2)


class RenderQueue(unittest.TestCase):
    def issues(self):
        return renderer.audit_queue.load_issues(json.loads(FIXTURE.read_text()))

    def test_dependency_order_priority_tiebreak_and_cycle_marking(self):
        result = renderer.plan(self.issues())
        order = [row["number"] for row in result["queue"]]
        self.assertLess(order.index(124), order.index(126), "#126 depends on open #124")
        self.assertEqual(order[:2], [124, 125], "both ready P0 items lead, lowest number first")
        cyclic = {row["number"] for row in result["queue"] if row["cyclic"]}
        self.assertEqual(cyclic, {200, 201})
        self.assertNotIn(3, order, "epics are tracking-only")
        self.assertEqual([e["number"] for e in result["epics"]], [3])
        row264 = next(row for row in result["queue"] if row["number"] == 264)
        self.assertEqual(row264["missingDependencies"], [127, 164, 177])
        self.assertEqual(row264["openBlockers"], [])

    def test_markdown_and_limit(self):
        result = renderer.plan(self.issues())
        text = renderer.render(result, "Source: fixture", 2)
        self.assertIn("# Backlog next queue", text)
        self.assertIn("Source: fixture", text)
        self.assertIn("| 1 | #124 ", text)
        self.assertIn("| 2 | #125 ", text)
        self.assertIn("further open items follow", text)
        self.assertIn("#200 -> #201 -> #200", text)
        self.assertIn("## Epics (tracking only, 1)", text)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(renderer.main([str(FIXTURE), "--limit", "50"]), 0)
        self.assertIn("in a dependency cycle", out.getvalue())
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(renderer.main([str(FIXTURE.with_name("missing.json"))]), 2)


class IssueLedger(unittest.TestCase):
    REPORT_A = """# Agent A report
## Ledger
#264 | DONE-in-source | Font+SD.swift:30, test X
- #125 | PARTIAL | verifier PASS rows=518
| #128 | DEFERRED-native-verification | nothing runs here |
## Files
#999 | NOT-STARTED | must be ignored outside the ledger
"""
    REPORT_B = """## Ledger
#264 | PARTIAL | a different rating
* #266 | OWNER-GATED ⭐ | signing
## Checks
"""

    def write(self, directory, name, text):
        path = Path(directory) / name
        path.write_text(text)
        return path

    def test_parses_three_row_shapes_and_counts(self):
        entries = ledger.parse_ledger(self.REPORT_A, "a.md")
        self.assertEqual([(e["issue"], e["state"], e["evidence"]) for e in entries],
                         [(264, "DONE-in-source", "Font+SD.swift:30, test X"), (125, "PARTIAL", "verifier PASS rows=518"),
                          (128, "DEFERRED-native-verification", "nothing runs here")])

    def test_merge_reports_conflicts_counts_and_missing_sections(self):
        with tempfile.TemporaryDirectory() as directory:
            a = self.write(directory, "a.md", self.REPORT_A)
            b = self.write(directory, "b.md", self.REPORT_B)
            c = self.write(directory, "c.md", "# no ledger here\n")
            result = ledger.merge([a, b, c])
            self.assertEqual(result["entryCount"], 5)
            self.assertEqual(result["issueCount"], 4)
            self.assertEqual(result["counts"], {"DEFERRED-native-verification": 1, "DONE-in-source": 1, "OWNER-GATED ⭐": 1, "PARTIAL": 2})
            self.assertEqual(result["conflicts"], {264: ["DONE-in-source", "PARTIAL"]})
            self.assertEqual(result["reportsWithoutLedger"], [c.as_posix()])
            text = ledger.render(result)
            self.assertIn("| #125 | PARTIAL | verifier PASS rows=518 |", text)
            self.assertIn("| PARTIAL | 2 |", text)
            self.assertIn("- #264: DONE-in-source, PARTIAL", text)
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(ledger.main([str(a), str(b)]), 1)
            self.assertIn("#264", out.getvalue())
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(ledger.main([str(a)]), 0)
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(ledger.main([str(Path(directory) / "missing.md")]), 2)


if __name__ == "__main__":
    unittest.main()
