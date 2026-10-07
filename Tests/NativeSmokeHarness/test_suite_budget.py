"""Exercise actual budget validation without launching or claiming an iOS run."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("sdi_test_budget", ROOT / "scripts/native-smoke/test_budget.py")
budget = importlib.util.module_from_spec(spec)
spec.loader.exec_module(budget)
COMMAND = ["xcodebuild", "test-without-building", "-test-timeouts-enabled", "YES",
           "-default-test-execution-time-allowance", "180", "-maximum-test-execution-time-allowance", "240",
           "-parallel-testing-enabled", "NO", "-maximum-concurrent-test-simulator-destinations", "1"]


def fixture(count):
    return "final class StudioSmokeUITests: XCTestCase {\n" + "\n".join(
        "    func testCase%d() throws {}" % i for i in range(count)) + "\n}"


class NativeSuiteBudget(unittest.TestCase):
    def test_all_checked_in_native_cases_are_preserved(self):
        source = (ROOT / "Tests/NativeUI/StudioSmokeUITests.swift").read_text()
        value = budget.build_test_budget(source, COMMAND)
        self.assertIn("testFrameContextDuplicateUndoRedo", value["testNames"])
        self.assertIn("testFrameContextReorderDeleteUndoAndColdReopen", value["testNames"])
        self.assertIn("testEditableTextUndoRedo", value["testNames"])
        self.assertIn("testEditableTextCancelAndEdit", value["testNames"])
        self.assertIn("testImageCanvasDragUndoAndColdReopen", value["testNames"])
        self.assertIn("testGradientBrushPixelsUndoAndColdReopen", value["testNames"])
        self.assertIn("testGradientBrushRealPNGExport", value["testNames"])
        self.assertIn("testGradientCustomEndpointValidationRenderAndColdReopen", value["testNames"])
        self.assertIn("testRotoscopeFilesPickerCancelPreservesProject", value["testNames"])
        self.assertIn("testRotoscopePhotosActualPlayheadUndoAndColdReopen", value["testNames"])
        self.assertIn("testImageCropCancelApplyUndoAndColdReopen", value["testNames"])
        self.assertIn("testProjectLibraryDuplicateRecoveryAndColdReopen", value["testNames"])
        self.assertIn("testTweenEasingEditableFramesUndoAndColdReopen", value["testNames"])
        self.assertIn("testSoundLibraryTagsCountsPreviewStopAndColdReopen", value["testNames"])
        self.assertIn("testObsoleteRevisionCleanupCancelConfirmAndColdReopen", value["testNames"])
        self.assertIn("testMP4FilesSaveSurvivesReexportAndColdSourceDisposal", value["testNames"])
        self.assertIn("testSpatterSelectedAudioPlacementUndoAndColdReopen", value["testNames"])
        self.assertIn("testLinkedImageLayerDuplicateIndependentFlipUndoAndColdReopen", value["testNames"])
        self.assertIn("testEraserSettingsPersistAndResetAfterColdLaunch", value["testNames"])
        self.assertIn("testNativeLayerDragReordersPixelsUndoRedoAndColdReopen", value["testNames"])
        self.assertIn("testBottomCopyPasteUsesExplicitLinkedImageWithoutDrawingsOrFrameCopies", value["testNames"])
        self.assertIn("testFramesViewerStableSelectionAfterReorderAndColdReopen", value["testNames"])
        self.assertIn("testLayerGlowColorRadiusStrengthUndoAndColdReopen", value["testNames"])
        self.assertIn("testFrameExposureRepeatUndoAndColdReopen", value["testNames"])
        self.assertIn("testAlphaLockPaintUndoColdReopenAndRealPNG", value["testNames"])
        self.assertIn("testLayerFullLockAndHiddenPaintingRejectWithoutHistory", value["testNames"])
        self.assertIn("testSpatterSelectedErasureUndoAndColdReopen", value["testNames"])
        self.assertIn("testBlurSettingsPersistAndReset", value["testNames"])
        self.assertIn("testBlurPixelsUndoAndColdReopen", value["testNames"])
        self.assertIn("testSelectedCoverageFillUndoAndColdReopen", value["testNames"])
        self.assertIn("testImageAdditionalAngleUndoAndColdReopen", value["testNames"])
        self.assertIn("testImageRotationHandleUndoAndColdReopen", value["testNames"])
        self.assertIn("testActiveLayerImageMarqueeDeleteUndoAndColdReopen", value["testNames"])
        self.assertIn("testStickerShelfLockedRejectionThenInsertUndo", value["testNames"])
        self.assertIn("testExplicitImageCutUndoPasteAndColdReopen", value["testNames"])
        self.assertIn("testOptionalMicroPackImportRemovalAndColdReopen", value["testNames"])
        self.assertIn("testFillPreferencesSwitchDrawResetAndColdReopen", value["testNames"])
        self.assertIn("testMixedDrawingImageMoveDeleteUndoAndColdReopen", value["testNames"])
        self.assertIn("testTwoIndependentImagesUndoAndColdReopen", value["testNames"])
        self.assertIn("testMixedArtworkCopyCutPasteUndoAndColdReopen", value["testNames"])
        self.assertIn("testImageWandRegionCopyDeletePasteUndoAndColdReopen", value["testNames"])
        self.assertIn("testSelectedImageAlphaFillUndoAndColdReopen", value["testNames"])
        self.assertIn("testSpatterLayerDuplicateRenameUndoAndColdReopen", value["testNames"])
        self.assertEqual(value["testCount"], 101)
        self.assertEqual(value["suiteSeconds"], value["testCount"] * 180 + 540 + 300)
        self.assertEqual((value["retries"], value["parallelSimulators"]), (0, 1))
        self.assertLessEqual(value["suiteSeconds"] + 25 * 60, 342 * 60)
        workflow = (ROOT / ".github/workflows/spatter-client-verify.yml").read_text()
        native_job = workflow.split("  native-ios-build:", 1)[1]
        self.assertIn("    timeout-minutes: 359", native_job)
        # Nine isolated native auth cases share
        # the existing runner in a separately bounded 17-minute step.
        self.assertIn("        timeout-minutes: 17", native_job)
        auth_source = (ROOT / "Tests/AuthState/AuthStateTests.swift").read_text()
        self.assertEqual(auth_source.count("    func test"), 9)
        self.assertLessEqual(value["suiteSeconds"] + (25 + 17) * 60, 359 * 60)
        for name in ("testDodgePixelsUndoAndColdReopen", "testBurnPixelsUndoAndColdReopen",
                     "testDodgeSettingsPersistAndReset", "testBurnSettingsPersistAndReset"):
            self.assertIn(name, value["testNames"])

    def test_per_case_capacity_is_available_and_global_bound_stays_finite(self):
        for count in (1, 49, 50, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99, 100, 101):
            value = budget.build_test_budget(fixture(count), COMMAND)
            self.assertEqual(value["suiteSeconds"], count * 180 + 300)
            self.assertLessEqual(value["suiteSeconds"] + 25 * 60, 342 * 60)
        self.assertEqual(budget.build_test_budget(fixture(50), COMMAND)["suiteSeconds"], 9300)

    def test_empty_excess_duplicate_or_additional_suites_reject(self):
        for source in (fixture(0), fixture(102), fixture(2).replace("testCase1", "testCase0"),
                       fixture(1) + "\nclass AnotherSuite: XCTestCase {}"):
            with self.subTest(source=source[:60]), self.assertRaises(ValueError):
                budget.build_test_budget(source, COMMAND)

    def test_retries_and_filtered_cases_reject(self):
        for extra in ("-only-testing:Suite/testA", "-skip-testing:Suite/testA", "-test-iterations",
                      "-retry-tests-on-failure", "-run-tests-until-failure", "-maximum-test-iterations=2"):
            with self.subTest(extra=extra), self.assertRaises(ValueError):
                budget.build_test_budget(fixture(2), COMMAND + [extra])

    def test_timeouts_and_single_simulator_cannot_be_disabled_or_duplicated(self):
        for flag in ("-test-timeouts-enabled", "-default-test-execution-time-allowance",
                     "-maximum-test-execution-time-allowance", "-parallel-testing-enabled",
                     "-maximum-concurrent-test-simulator-destinations"):
            index = COMMAND.index(flag)
            variants = [COMMAND[:index] + COMMAND[index + 2:], COMMAND + [flag, COMMAND[index + 1]],
                        COMMAND[:index + 1] + ["invalid"] + COMMAND[index + 2:]]
            for command in variants:
                with self.subTest(flag=flag, command=command), self.assertRaises(ValueError):
                    budget.build_test_budget(fixture(2), command)

    def test_only_named_long_journeys_receive_extra_time(self):
        source = (ROOT / "Tests/NativeUI/StudioSmokeUITests.swift").read_text()
        value = budget.build_test_budget(source, COMMAND)
        self.assertEqual(value["extendedCases"], budget.EXTENDED_CASE_SECONDS)
        self.assertEqual(value["extendedCases"]["testActiveLayerImageMarqueeDeleteUndoAndColdReopen"], 240)
        self.assertEqual(value["extendedCases"]["testSpatterSelectedAudioPlacementUndoAndColdReopen"], 240)
        self.assertEqual(value["extendedCases"]["testSelectedImageAlphaFillUndoAndColdReopen"], 240)
        self.assertEqual(sum(value["extendedCases"].values()), 2160)
        self.assertEqual(value["extendedCases"]["testMixedDrawingImageMoveDeleteUndoAndColdReopen"], 240)
        self.assertEqual(value["extendedCases"]["testMixedArtworkCopyCutPasteUndoAndColdReopen"], 240)
        self.assertEqual(value["extendedCases"]["testImageWandRegionCopyDeletePasteUndoAndColdReopen"], 240)
        for changed in (source.replace("executionTimeAllowance = 240", "executionTimeAllowance = 300", 1),
                        source.replace("executionTimeAllowance = 240", "", 1),
                        source + "\nexecutionTimeAllowance = 240"):
            with self.assertRaises(ValueError):
                budget.build_test_budget(changed, COMMAND)

    def test_inventory_digest_changes_with_source(self):
        before = budget.build_test_budget(fixture(2), COMMAND)
        after = budget.build_test_budget(fixture(2) + "\n// a source change", COMMAND)
        self.assertEqual(before["testNames"], after["testNames"])
        self.assertNotEqual(before["sourceSHA256"], after["sourceSHA256"])


if __name__ == "__main__":
    unittest.main()
