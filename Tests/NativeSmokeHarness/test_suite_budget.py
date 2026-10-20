"""Exercise actual budget validation without launching or claiming an iOS run."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("sdi_test_budget", ROOT / "scripts/native-smoke/test_budget.py")
budget = importlib.util.module_from_spec(spec)
spec.loader.exec_module(budget)
COMMAND = ["xcodebuild", "test-without-building", "-test-timeouts-enabled", "YES",
           "-default-test-execution-time-allowance", "300", "-maximum-test-execution-time-allowance", "360",
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
        self.assertIn("testProjectLibraryLastRowWithExpandedCreation", value["testNames"])
        self.assertIn("testAccessibilityAuditLibraryAndStudioAtAccessibilityTextSize", value["testNames"])
        self.assertIn("testCompleteProjectJourneyCreateDrawLayerAudioExportPNGAndColdReopen", value["testNames"])
        self.assertEqual(value["testCount"], 110)
        self.assertEqual(value["suiteSeconds"], value["testCount"] * 300 + 15 * 60 + 300)
        self.assertEqual((value["retries"], value["parallelSimulators"]), (0, 1))
        self.assertIn("testImageDrawingOrderUndoAndColdReopen", value["testNames"])
        workflow = (ROOT / ".github/workflows/spatter-client-verify.yml").read_text()
        native_job = workflow.split("  native-ios-shards:", 1)[1].split("  native-ios-build:", 1)[0]
        self.assertIn("    timeout-minutes: ${{ matrix.timeout }}", native_job)
        # Shard ceilings derive from the exact inventory: assigned suite seconds
        # plus 25 min build/preservation, plus the 22 min auth step on shard zero.
        self.assertIn("            timeout: 334", native_job)
        self.assertIn("            timeout: 313", native_job)
        # Twenty isolated native auth cases (account export added, #262) share the existing runner in a
        # separately bounded 22-minute step (60 s maximum allowance each).
        self.assertIn("        timeout-minutes: 22", native_job)
        auth_source = (ROOT / "Tests/AuthState/AuthStateTests.swift").read_text()
        self.assertEqual(auth_source.count("    func test"), 20)
        for index, minutes in ((0, 334), (1, 313)):
            shard, _ = budget.build_shard_budget(source, COMMAND, index)
            overhead = (25 + (22 if index == 0 else 0)) * 60
            self.assertLessEqual(shard["suiteSeconds"] + overhead, minutes * 60)
            # No hidden slack: the matrix minute value is the exact ceiling.
            self.assertEqual(minutes, -(-(shard["suiteSeconds"] + overhead) // 60))
        for name in ("testDodgePixelsUndoAndColdReopen", "testBurnPixelsUndoAndColdReopen",
                     "testDodgeSettingsPersistAndReset", "testBurnSettingsPersistAndReset"):
            self.assertIn(name, value["testNames"])

    def test_per_case_capacity_is_available_and_global_bound_stays_finite(self):
        for count in (1, 49, 50, *range(60, budget.MAXIMUM_CASES + 1)):
            value = budget.build_test_budget(fixture(count), COMMAND)
            self.assertEqual(value["suiteSeconds"], count * 300 + 300)
            # CI runs the inventory as two shards; each half, plus build and
            # the shard-zero auth step, must fit a 360-minute hosted job.
            self.assertLessEqual(-(-count // 2) * 300 + 300 + (25 + 22) * 60, 360 * 60)
        self.assertEqual(budget.MAXIMUM_CASES, 110)
        self.assertEqual(budget.build_test_budget(fixture(50), COMMAND)["suiteSeconds"], 15300)

    def test_empty_excess_duplicate_or_additional_suites_reject(self):
        for source in (fixture(0), fixture(budget.MAXIMUM_CASES + 1), fixture(2).replace("testCase1", "testCase0"),
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
        self.assertEqual(value["extendedCases"]["testImageTweenLinearPixelsUndoAndColdReopen"], 360)
        self.assertEqual(value["extendedCases"]["testImageQuarterTweenPixelsUndoAndColdReopen"], 360)
        self.assertEqual(value["extendedCases"]["testActiveLayerImageMarqueeDeleteUndoAndColdReopen"], 360)
        self.assertEqual(value["extendedCases"]["testSpatterSelectedAudioPlacementUndoAndColdReopen"], 360)
        self.assertEqual(value["extendedCases"]["testSelectedImageAlphaFillUndoAndColdReopen"], 360)
        self.assertEqual(value["extendedCases"]["testImageDrawingOrderUndoAndColdReopen"], 360)
        self.assertEqual(sum(value["extendedCases"].values()), 15 * 360)
        self.assertEqual(value["extendedCases"]["testCompleteProjectJourneyCreateDrawLayerAudioExportPNGAndColdReopen"], 360)
        self.assertNotIn("testAccessibilityAuditLibraryAndStudioAtAccessibilityTextSize", value["extendedCases"])
        self.assertEqual(value["extendedCases"]["testSharpenPixelsUndoAndColdReopen"], 360)
        self.assertEqual(value["extendedCases"]["testMixedDrawingImageMoveDeleteUndoAndColdReopen"], 360)
        self.assertEqual(value["extendedCases"]["testMixedArtworkCopyCutPasteUndoAndColdReopen"], 360)
        self.assertEqual(value["extendedCases"]["testImageWandRegionCopyDeletePasteUndoAndColdReopen"], 360)
        for changed in (source.replace("executionTimeAllowance = 360", "executionTimeAllowance = 420", 1),
                        source.replace("executionTimeAllowance = 360", "", 1),
                        source + "\nexecutionTimeAllowance = 360"):
            with self.assertRaises(ValueError):
                budget.build_test_budget(changed, COMMAND)

    def test_inventory_digest_changes_with_source(self):
        before = budget.build_test_budget(fixture(2), COMMAND)
        after = budget.build_test_budget(fixture(2) + "\n// a source change", COMMAND)
        self.assertEqual(before["testNames"], after["testNames"])
        self.assertNotEqual(before["sourceSHA256"], after["sourceSHA256"])


if __name__ == "__main__":
    unittest.main()
