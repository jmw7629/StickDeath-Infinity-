"""Control evidence map generation/verification on small fixtures and the real tree; no iOS run."""
import contextlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("sdi_control_index", ROOT / "scripts/verify_control_index.py")
subject = importlib.util.module_from_spec(spec)
spec.loader.exec_module(subject)

VIEW_MODEL = """
final class StudioViewModel: ObservableObject {
    private func command(_ operation: (inout StudioDocumentEditor) throws -> Void) {}
    func addFrame() { stopPlayback(); command { try $0.addFrame() } }
    func deleteLayer(_ capture: LayerDeleteCapture) -> Bool { return removeLayer(capture) }
    private func removeLayer(_ capture: LayerDeleteCapture) -> Bool { command { try $0.deleteLayer(capture) }; return true }
    func toggleGrid() { showGrid.toggle() }
    func stopPlayback() {}
}
"""
STUDIO_VIEW = """
struct FixturePanel: View {
    @ObservedObject var vm: StudioViewModel
    var body: some View {
        VStack {
            Button("Add frame") { vm.addFrame() }
                .accessibilityIdentifier("studio.fixture.add-frame")
            Button("Delete layer") { _ = vm.deleteLayer(capture) }
                .accessibilityIdentifier("studio.fixture.delete-layer")
            Toggle("Grid", isOn: $vm.showGrid)
                .accessibilityIdentifier("studio.fixture.grid")
            Text("Status").accessibilityIdentifier("studio.fixture.status")
            ForEach(frames) { frame in
                Text(frame.id).accessibilityIdentifier("studio.fixture.frame." + frame.id)
            }
            Slider(value: $vm.wandTolerance, in: 0...128).accessibilityIdentifier("studio.wand.tolerance")
        }
    }
}
"""
WELCOME_VIEW = """
struct WelcomeView: View {
    var body: some View {
        Button("Continue as guest") { guest() }.accessibilityIdentifier("welcome.guest")
    }
}
"""
RETIRED_VIEW = """
struct WatchPartyView: View {
    var body: some View { Text("Chat unavailable").accessibilityIdentifier("watch-party-chat-error") }
}
"""
UI_TESTS = """
final class StudioSmokeUITests: XCTestCase {
    func testAddFrameUndo() throws {
        app.buttons["studio.fixture.add-frame"].tap()
        openGrid(app)
    }
    func testWelcomeGuest() throws { app.buttons["welcome.guest"].tap() }
    private func openGrid(_ app: XCUIApplication) { app.switches["studio.fixture.grid"].tap() }
}
"""
INDEX_DOC = """# Studio control implementation index

| Control | Production operation | State, history and scope | Issue |
| --- | --- | --- | --- |
| Wand tolerance / connected matching | `StudioImageRegionService` | persisted settings | #153 |
| Lasso New / Add / Subtract | `finishAreaSelection` | transient | #152 |
"""


def quiet_main(arguments):
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        return subject.main(arguments)


def build_fixture(root: Path, ui_tests: str = UI_TESTS, include_delete: bool = True) -> None:
    files = {
        "StickDeathInfinity/ViewModels/StudioViewModel.swift": VIEW_MODEL,
        "StickDeathInfinity/Views/Studio/Panels/FixturePanel.swift": STUDIO_VIEW if include_delete else STUDIO_VIEW.replace(
            '            Button("Delete layer") { _ = vm.deleteLayer(capture) }\n                .accessibilityIdentifier("studio.fixture.delete-layer")\n', ""),
        "StickDeathInfinity/Views/Auth/WelcomeView.swift": WELCOME_VIEW,
        "StickDeathInfinity/Views/Messages/WatchParty/WatchPartyView.swift": RETIRED_VIEW,
        "Tests/NativeUI/StudioSmokeUITests.swift": ui_tests,
        "docs/STUDIO_CONTROL_IMPLEMENTATION_INDEX.md": INDEX_DOC,
    }
    for name, text in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)


class ControlIndexGeneration(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="sdi-control-index-")
        self.root = Path(self.temporary.name)
        build_fixture(self.root)
        self.addCleanup(self.temporary.cleanup)

    def rows(self):
        rows, summary = subject.generate(self.root)
        return {r["identifier"]: r for r in rows}, summary

    def test_static_identifiers_become_rows_and_dynamic_ones_are_counted(self):
        rows, summary = self.rows()
        self.assertEqual(set(rows), {"studio.fixture.add-frame", "studio.fixture.delete-layer", "studio.fixture.grid",
                                     "studio.fixture.status", "studio.wand.tolerance", "welcome.guest", "watch-party-chat-error"})
        self.assertEqual(summary["dynamic"], 1)
        self.assertEqual(summary["rows"], 7)
        self.assertEqual(rows["studio.fixture.add-frame"]["file"], "StickDeathInfinity/Views/Studio/Panels/FixturePanel.swift")
        self.assertEqual(rows["studio.fixture.add-frame"]["screen"], "FixturePanel")

    def test_history_follows_the_view_model_command_path_transitively(self):
        rows, _ = self.rows()
        self.assertEqual(rows["studio.fixture.add-frame"]["history"], "yes")
        self.assertEqual(rows["studio.fixture.delete-layer"]["history"], "yes")  # via private removeLayer
        self.assertEqual(rows["studio.fixture.grid"]["history"], "no")
        self.assertEqual(rows["studio.fixture.status"]["history"], "no")
        self.assertEqual(rows["welcome.guest"]["history"], "n-a")

    def test_operation_summarises_control_label_and_action(self):
        rows, _ = self.rows()
        self.assertEqual(rows["studio.fixture.add-frame"]["operation"], "button 'Add frame' -> vm.addFrame")
        self.assertIn("binds vm.showGrid", rows["studio.fixture.grid"]["operation"])
        self.assertTrue(rows["studio.fixture.grid"]["operation"].startswith("toggle 'Grid'"))

    def test_issue_mapping_uses_index_table_then_prefix_map_then_unmapped(self):
        rows, _ = self.rows()
        self.assertEqual(rows["studio.wand.tolerance"]["issue"], "#153")
        self.assertEqual(rows["welcome.guest"]["issue"], "#134 #136 #137")
        self.assertEqual(rows["studio.fixture.status"]["issue"], "unmapped")

    def test_ui_test_column_lists_tests_then_helpers_and_defers_otherwise(self):
        rows, _ = self.rows()
        self.assertEqual(rows["studio.fixture.add-frame"]["uiTest"], "testAddFrameUndo")
        self.assertEqual(rows["studio.fixture.grid"]["uiTest"], "helper:openGrid")
        self.assertEqual(rows["welcome.guest"]["uiTest"], "testWelcomeGuest")
        self.assertEqual(rows["studio.fixture.status"]["uiTest"], "deferred")

    def test_retired_files_are_labelled(self):
        rows, _ = self.rows()
        self.assertEqual(rows["watch-party-chat-error"]["screen"], "WatchPartyView (retired; excluded from native target)")
        self.assertEqual(rows["watch-party-chat-error"]["history"], "n-a")


class ControlIndexVerification(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="sdi-control-verify-")
        self.root = Path(self.temporary.name)
        build_fixture(self.root)
        self.csv = self.root / subject.CSV_PATH
        self.assertEqual(quiet_main(["--root", str(self.root), "--write"]), 0)
        self.addCleanup(self.temporary.cleanup)

    def test_fresh_csv_passes(self):
        problems, _ = subject.verify(self.root)
        self.assertEqual(problems, [])
        self.assertEqual(quiet_main(["--root", str(self.root)]), 0)

    def test_missing_csv_fails(self):
        self.csv.unlink()
        problems, _ = subject.verify(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("missing", problems[0])

    def test_new_source_identifier_missing_from_csv_fails(self):
        panel = self.root / "StickDeathInfinity/Views/Studio/Panels/FixturePanel.swift"
        panel.write_text(panel.read_text().replace('Text("Status")', 'Text("Status").accessibilityIdentifier("studio.fixture.new")\n            Text("Status")'))
        problems, _ = subject.verify(self.root)
        self.assertEqual(problems, ["identifier in source missing from CSV: studio.fixture.new (StickDeathInfinity/Views/Studio/Panels/FixturePanel.swift)"])

    def test_removed_source_identifier_still_in_csv_fails(self):
        build_fixture(self.root, include_delete=False)
        problems, _ = subject.verify(self.root)
        self.assertEqual(problems, ["CSV row references an identifier/file no longer in source: studio.fixture.delete-layer (StickDeathInfinity/Views/Studio/Panels/FixturePanel.swift)"])

    def test_stale_ui_test_column_fails_when_test_stops_referencing_identifier(self):
        build_fixture(self.root, ui_tests=UI_TESTS.replace('app.buttons["studio.fixture.add-frame"].tap()', ""))
        problems, _ = subject.verify(self.root)
        self.assertEqual(problems, ["stale uiTest for studio.fixture.add-frame (StickDeathInfinity/Views/Studio/Panels/FixturePanel.swift): CSV 'testAddFrameUndo' vs source 'deferred'"])

    def test_renamed_test_function_fails_as_stale_and_nonexistent(self):
        build_fixture(self.root, ui_tests=UI_TESTS.replace("testAddFrameUndo", "testAddFrameUndoRenamed"))
        problems, _ = subject.verify(self.root)
        self.assertIn("stale uiTest for studio.fixture.add-frame", problems[0])
        self.assertIn("uiTest 'testAddFrameUndo' for studio.fixture.add-frame does not exist", problems[1])

    def test_hand_edited_ui_test_column_is_rejected_even_when_function_exists(self):
        text = self.csv.read_text().replace("testAddFrameUndo", "testWelcomeGuest", 1)
        self.csv.write_text(text)
        problems, _ = subject.verify(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("stale uiTest", problems[0])

    def test_curated_issue_cell_survives_regeneration(self):
        text = self.csv.read_text().replace("studio.fixture.status,StickDeathInfinity/Views/Studio/Panels/FixturePanel.swift,FixturePanel,text 'Status',no,unmapped,",
                                            "studio.fixture.status,StickDeathInfinity/Views/Studio/Panels/FixturePanel.swift,FixturePanel,text 'Status',no,#999,")
        self.assertIn("#999", text)
        self.csv.write_text(text)
        self.assertEqual(quiet_main(["--root", str(self.root), "--write"]), 0)
        self.assertIn("studio.fixture.status,", self.csv.read_text())
        self.assertIn(",no,#999,deferred", self.csv.read_text())

    def test_empty_issue_or_operation_fails(self):
        text = self.csv.read_text().replace(",no,unmapped,deferred", ",no,,deferred", 1)
        self.csv.write_text(text)
        problems, _ = subject.verify(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("empty issue", problems[0])

    def test_wrong_columns_fail(self):
        self.csv.write_text("identifier,file\nstudio.fixture.add-frame,x\n")
        problems, _ = subject.verify(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("must have columns", problems[0])


class ControlIndexRealTree(unittest.TestCase):
    def test_checked_in_map_matches_current_source_and_ui_tests(self):
        problems, summary = subject.verify(ROOT)
        self.assertEqual(problems, [])
        self.assertGreaterEqual(summary["identifiers"], 400)
        self.assertIn("studio.undo", {r["identifier"] for r in subject.read_csv(ROOT / subject.CSV_PATH)})

    def test_real_undo_control_reaches_history(self):
        rows = {(r["identifier"], r["file"]): r for r in subject.read_csv(ROOT / subject.CSV_PATH)}
        undo = rows[("studio.undo", "StickDeathInfinity/Views/Studio/StudioView.swift")]
        self.assertEqual(undo["history"], "yes")
        self.assertNotEqual(undo["uiTest"], "deferred")


if __name__ == "__main__":
    unittest.main()
