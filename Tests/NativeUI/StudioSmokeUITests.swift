import XCTest
import UIKit

/// Runs against the real app and an isolated simulator. The build preflight must
/// verify empty backend settings; setting app.launchEnvironment cannot do that.
final class StudioSmokeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testSelectedImageAlphaFillUndoAndColdReopen() throws {
        // The measured real import, image selection, Fill and history path reaches cold reopen at 184s.
        executionTimeAllowance = 240
        let app = try launchGuestStudio(); defer { app.terminate() }
        let name = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let frame = canvas.frame
        try importLicensedImageForExport(app, canvas: canvas)
        let original = try pixels(canvas.screenshot().image)
        // Use a real dark interior of the licensed source, not a guessed canvas
        // coordinate. White screenshot pixels provide a surrounding-background oracle.
        var seed: CGPoint?
        var darkest = Int.max
        for y in (original.height / 10)..<(original.height * 9 / 10) {
            for x in (original.width / 10)..<(original.width * 9 / 10) {
                var score = 0, dark = 0
                for dy in -2...2 { for dx in -2...2 {
                    let i = ((y + dy) * original.width + x + dx) * 4
                    let value = max(Int(original.bytes[i]), max(Int(original.bytes[i + 1]), Int(original.bytes[i + 2])))
                    score += value
                    if value < 90 { dark += 1 }
                } }
                let i = (y * original.width + x) * 4
                if dark >= 9 && max(original.bytes[i], max(original.bytes[i + 1], original.bytes[i + 2])) < 70 && score < darkest {
                    darkest = score; seed = CGPoint(x: CGFloat(x), y: CGFloat(y))
                }
            }
        }
        let selectedPixel = try XCTUnwrap(seed, "Licensed image has no stable dark interior seed")
        capture(app, name: "fill-selected-image-original")
        app.buttons["studio.layers.open"].tap()
        let imageLayer = app.staticTexts["Image: Dungeon Dragon"].firstMatch
        XCTAssertTrue(imageLayer.waitForExistence(timeout: 5) && imageLayer.isHittable); imageLayer.tap()
        app.buttons["studio.layers.close"].tap()
        try selectToolbarTool("move", app: app)
        let target = try fillPreferenceControl("studio.image-move.target", app: app)
        XCTAssertEqual(target.value as? String, "Drawings")
        target.tap(); XCTAssertEqual(target.value as? String, "Image")
        app.buttons["studio.tool-settings.close"].tap()
        try pickerRailControl("studio.tool.fill", app: app, forward: false).tap()
        let guidance = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Fill stays within the explicitly selected image")).firstMatch
        XCTAssertTrue(guidance.waitForExistence(timeout: 5), "Explicit image target was lost on Fill handoff")
        XCTAssertTrue(guidance.label.contains("alpha, crop and region mask"))
        try fillPreferenceControl("studio.tool-settings.reset", app: app).tap()
        app.buttons["studio.tool-settings.close"].tap()
        try choosePickerTestColor("#0000FF", app: app)
        try waitForStableCanvas(canvas, expected: frame)
        canvas.coordinate(withNormalizedOffset: .init(dx: (selectedPixel.x + 0.5) / CGFloat(original.width),
                                                       dy: (selectedPixel.y + 0.5) / CGFloat(original.height))).tap()
        let receipt = app.staticTexts["Added paint within the selected image alpha. Original image bytes remain unchanged."]
        XCTAssertTrue(receipt.waitForExistence(timeout: 8), "Selected image Fill did not commit through the real worker")
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        // Leave the transient image target before checking actual canvas pixels.
        try selectToolbarTool("move", app: app); app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(canvas, expected: frame)
        let painted = try pixels(canvas.screenshot().image)
        XCTAssertEqual(original.width, painted.width); XCTAssertEqual(original.height, painted.height)
        var blue = 0, escaped = 0
        for i in stride(from: 0, to: painted.bytes.count, by: 4) {
            if painted.bytes[i + 2] > 180 && painted.bytes[i] < 90 && painted.bytes[i + 1] < 90 {
                blue += 1
                if original.bytes[i] >= 250 && original.bytes[i + 1] >= 250 && original.bytes[i + 2] >= 250 { escaped += 1 }
            }
        }
        XCTAssertGreaterThan(blue, 20, "No selected image pixels acquired the actual blue fill")
        XCTAssertLessThan(blue, painted.width * painted.height / 3, "Selected image Fill flooded the canvas")
        XCTAssertEqual(escaped, 0, "Blue paint reached the surrounding white canvas")
        let sample = (Int(selectedPixel.y) * painted.width + Int(selectedPixel.x)) * 4
        XCTAssertGreaterThan(painted.bytes[sample + 2], 180)
        XCTAssertLessThan(painted.bytes[sample], 90); XCTAssertLessThan(painted.bytes[sample + 1], 90)
        capture(app, name: "fill-selected-image-painted")
        app.buttons["studio.undo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4,
                                "One Undo failed to restore the untouched imported source")
        app.buttons["studio.redo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(painted, pixels(canvas.screenshot().image)), 4)
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(painted, pixels(restored.screenshot().image)), 4,
                                "Cold reopen lost selected image Fill paint or its source")
        capture(reopened, name: "fill-selected-image-cold-reopened")
    }

    @MainActor
    func testSelectedCoverageFillUndoAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let name = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let frame = canvas.frame
        try pickerRailControl("studio.tool.pencil", app: app, forward: false).tap()
        app.sliders["studio.setting.size"].adjust(toNormalizedSliderPosition: 0.85)
        app.sliders["studio.setting.opacity"].adjust(toNormalizedSliderPosition: 1)
        app.buttons["studio.tool-settings.close"].tap()
        // The shared ink oracle measures red coverage; use an explicit red
        // source so this assertion verifies the stroke before exercising Fill.
        try choosePickerTestColor("#FF0000", app: app)
        try waitForStableCanvas(canvas, expected: frame)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).press(forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let original = try pixels(canvas.screenshot().image)
        capture(app, name: "fill-selected-original-red-source")
        XCTAssertGreaterThan(exportInkMask(original).count, 60)
        try pickerRailControl("studio.tool.lasso", app: app, forward: true).tap()
        let selectAll = app.buttons["studio.selection.all"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5)); selectAll.tap()
        XCTAssertEqual(app.staticTexts["studio.selection.count"].label, "1 drawings selected")
        app.buttons["studio.tool-settings.close"].tap()
        try pickerRailControl("studio.tool.fill", app: app, forward: false).tap()
        XCTAssertTrue(app.staticTexts["studio.fill.selection-coverage"].waitForExistence(timeout: 5))
        try fillPreferenceControl("studio.tool-settings.reset", app: app).tap()
        app.buttons["studio.tool-settings.close"].tap()
        try choosePickerTestColor("#0000FF", app: app)
        try waitForStableCanvas(canvas, expected: frame)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        // Remove only the editor's red selection outline before pixel checks.
        try pickerRailControl("studio.tool.eraser", app: app, forward: false).tap()
        let deselect = app.buttons["studio.eraser.deselect"]
        XCTAssertTrue(deselect.waitForExistence(timeout: 5)); deselect.tap()
        app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(canvas, expected: frame)
        let painted = try pixels(canvas.screenshot().image)
        let blue = imageFixtureColors(painted)[1]
        XCTAssertGreaterThan(blue, 20, "Selected Fill painted no real artwork")
        XCTAssertLessThan(blue, painted.width * painted.height / 3, "Fill escaped onto the surrounding canvas")
        XCTAssertEqual(original.width, painted.width); XCTAssertEqual(original.height, painted.height)
        var escaped = 0
        for i in stride(from: 0, to: min(original.bytes.count, painted.bytes.count), by: 4) {
            if original.bytes[i] >= 250 && original.bytes[i + 1] >= 250 && original.bytes[i + 2] >= 250,
               painted.bytes[i + 2] > 180 && painted.bytes[i] < 90 && painted.bytes[i + 1] < 90 { escaped += 1 }
        }
        XCTAssertEqual(escaped, 0, "Paint reached pixels outside the actual selected stroke")
        capture(app, name: "fill-selected-coverage-real-pixels")
        app.buttons["studio.undo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4)
        app.buttons["studio.redo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(painted, pixels(canvas.screenshot().image)), 4)
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(painted, pixels(restored.screenshot().image)), 4,
            "Cold reopen lost selected Fill coverage")
        capture(reopened, name: "fill-selected-coverage-cold-reopened")
    }

    @MainActor
    func testSpatterLayerDuplicateRenameUndoAndColdReopen() throws {
        let app = try launchGuestStudio(); defer { app.terminate() }
        let name = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching:.any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let frame = canvas.frame, blank = try pixels(canvas.screenshot().image)
        canvas.coordinate(withNormalizedOffset:.init(dx:0.25,dy:0.4)).press(forDuration:0.1,thenDragTo:canvas.coordinate(withNormalizedOffset:.init(dx:0.7,dy:0.6)))
        try settlePickerCanvasAfterSave(app,canvas:canvas)
        let original = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(blank,original),20,"Layer command source drawing is missing")
        app.buttons["studio.menu.open"].tap()
        let open = app.buttons["studio.spatter.open"]
        XCTAssertTrue(open.waitForExistence(timeout:8)); open.tap()
        let local = app.buttons["spatter.studio.local-motion"]
        XCTAssertTrue(local.waitForExistence(timeout:8)); local.tap()
        try localMotionControl("spatter.layer.duplicate-example",app:app).tap()
        XCTAssertTrue(app.staticTexts["Duplicate active layer"].exists)
        let duplicateInput = try localMotionControl("spatter.motion.input",app:app)
        XCTAssertEqual(duplicateInput.value as? String,"Duplicate active layer.")
        try localMotionControl("spatter.motion.apply",app:app).tap()
        let receipt = try localMotionControl("spatter.motion.result",app:app)
        XCTAssertTrue(expectation(for:NSPredicate(format:"label == %@","Duplicated the active layer across its frames in one undoable local edit. Original artwork remains editable."),evaluatedWith:receipt).waitUntilFulfilled(timeout:8))
        capture(app,name:"spatter-layer-duplicate-receipt")
        try localMotionControl("spatter.layer.rename-example",app:app,scrollUp:false).tap()
        let unfocusedInput = try localMotionControl("spatter.motion.input",app:app)
        unfocusedInput.tap()
        let done = app.buttons["spatter.motion.keyboard.done"]
        XCTAssertTrue(done.waitForExistence(timeout:5))
        // Focusing opens the keyboard and shrinks the scroll viewport. Reacquire
        // the fully visible editor before asking its focused text for Select All.
        let input = try localMotionControl("spatter.motion.input",app:app)
        input.press(forDuration:1)
        let selectAll = app.descendants(matching:.any).matching(NSPredicate(format:"label == %@","Select All")).firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout:5) && selectAll.isHittable); selectAll.tap()
        let instruction = "Rename active layer to \"Frame exposure\"."
        input.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertEqual(input.value as? String,"", "Select All did not clear the instruction")
        input.typeText(instruction)
        XCTAssertTrue(done.waitForExistence(timeout:5)); done.tap()
        XCTAssertEqual(input.value as? String,instruction)
        XCTAssertTrue(app.staticTexts["Edit active layer"].exists)
        XCTAssertFalse(app.staticTexts["Rename current project"].exists)
        try localMotionControl("spatter.motion.apply",app:app).tap()
        let renamed = try localMotionControl("spatter.motion.result",app:app)
        XCTAssertTrue(expectation(for:NSPredicate(format:"label == %@","Updated the active layer settings in one undoable local edit."),evaluatedWith:renamed).waitUntilFulfilled(timeout:8))
        app.buttons["spatter.motion.back"].tap()
        let close = app.buttons["spatter.studio.close"]
        XCTAssertTrue(close.waitForExistence(timeout:5)); close.tap()
        try settlePickerCanvasAfterSave(app,canvas:canvas)
        app.buttons["studio.layers.open"].tap()
        XCTAssertTrue(app.staticTexts["Frame exposure"].waitForExistence(timeout:5))
        XCTAssertTrue(app.staticTexts["Layer 1"].exists)
        app.buttons["studio.layers.close"].tap()
        app.buttons["studio.undo"].tap() // Undo rename only.
        app.buttons["studio.layers.open"].tap()
        XCTAssertTrue(app.staticTexts["Layer 1 Copy"].waitForExistence(timeout:5))
        XCTAssertFalse(app.staticTexts["Frame exposure"].exists)
        app.buttons["studio.layers.close"].tap()
        app.buttons["studio.undo"].tap() // One more Undo removes duplication only.
        try settlePickerCanvasAfterSave(app,canvas:canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(original,pixels(canvas.screenshot().image)),4,"Layer Undo damaged source drawing")
        app.buttons["studio.layers.open"].tap()
        XCTAssertFalse(app.staticTexts["Layer 1 Copy"].exists)
        XCTAssertTrue(app.staticTexts["Layer 1"].exists)
        app.buttons["studio.layers.close"].tap()
        app.buttons["studio.redo"].tap(); app.buttons["studio.redo"].tap()
        try settlePickerCanvasAfterSave(app,canvas:canvas)
        let duplicated = try pixels(canvas.screenshot().image)
        capture(app,name:"spatter-layer-redo-artwork")
        app.buttons["studio.back"].tap(); app.terminate()
        let cold = try launchGuestStudio(); defer { cold.terminate() }
        let project = cold.buttons.matching(NSPredicate(format:"label == %@",name)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout:8)); project.tap()
        let reopened = cold.descendants(matching:.any)["studio.canvas"].firstMatch
        try waitForStableCanvas(reopened,expected:frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(duplicated,pixels(reopened.screenshot().image)),4,"Cold layer duplicate pixels changed")
        cold.buttons["studio.layers.open"].tap()
        XCTAssertTrue(cold.staticTexts["Frame exposure"].waitForExistence(timeout:5))
        XCTAssertTrue(cold.staticTexts["Layer 1"].exists)
        capture(cold,name:"spatter-layer-cold-inspector")
    }

    @MainActor
    func testSpatterSelectedErasureUndoAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let name = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let frame = canvas.frame
        try pickerRailControl("studio.tool.pencil", app: app, forward: false).tap()
        app.sliders["studio.setting.size"].adjust(toNormalizedSliderPosition: 0.85)
        app.sliders["studio.setting.opacity"].adjust(toNormalizedSliderPosition: 1)
        app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(canvas, expected: frame)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).press(forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let original = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(exportInkMask(original).count, 60)
        try pickerRailControl("studio.tool.lasso", app: app, forward: true).tap()
        let selectAll = app.buttons["studio.selection.all"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5)); selectAll.tap()
        XCTAssertEqual(app.staticTexts["studio.selection.count"].label, "1 drawings selected")
        app.buttons["studio.tool-settings.close"].tap()
        app.buttons["studio.menu.open"].tap()
        let open = app.buttons["studio.spatter.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 8)); open.tap()
        let local = app.buttons["spatter.studio.local-motion"]
        XCTAssertTrue(local.waitForExistence(timeout: 8) && local.isHittable); local.tap()
        try localMotionControl("spatter.selection.erase-example", app: app).tap()
        let input = try localMotionControl("spatter.motion.input", app: app)
        XCTAssertEqual(input.value as? String, "Erase selected drawings from (25%, 50%) to (75%, 50%) with hard eraser size 24 px and strength 100%.")
        let guidance = try localMotionControl("spatter.local-edit.guidance", app: app, scrollUp: false)
        XCTAssertTrue(guidance.label.lowercased().contains("selected"))
        XCTAssertFalse(guidance.label.contains("Append"), "Selected eraser guidance must not promise generated frames")
        try localMotionControl("spatter.motion.apply", app: app).tap()
        let receipt = try localMotionControl("spatter.motion.result", app: app)
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@",
            "Added 1 erasure mask to selected drawings in one undoable local edit. Original artwork remains editable."),
            evaluatedWith: receipt).waitUntilFulfilled(timeout: 8))
        capture(app, name: "spatter-selected-erasure-factual-receipt")
        app.buttons["spatter.motion.back"].tap()
        let close = app.buttons["spatter.studio.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5) && close.isHittable); close.tap()
        try pickerRailControl("studio.tool.eraser", app: app, forward: false).tap()
        let deselect = app.buttons["studio.eraser.deselect"]
        XCTAssertTrue(deselect.waitForExistence(timeout: 5)); deselect.tap()
        app.buttons["studio.tool-settings.close"].tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        try waitForStableCanvas(canvas, expected: frame)
        let erased = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(original, erased), 20)
        XCTAssertLessThan(exportInkMask(erased).count, exportInkMask(original).count, "Spatter erased no real ink")
        capture(app, name: "spatter-selected-erasure-real-pixels")
        app.buttons["studio.undo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4, "One Undo failed to restore source pixels")
        app.buttons["studio.redo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(erased, pixels(canvas.screenshot().image)), 4, "Redo changed selected erasure")
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(erased, pixels(restored.screenshot().image)), 4, "Cold reopen lost the retained selected mask")
        capture(reopened, name: "spatter-selected-erasure-cold-reopened")
    }

    /// Real drawing/save revisions -> explicit Storage consent -> actual deletion
    /// receipt -> cold reopen. No sandbox seeding, test-only cleanup shortcut,
    /// current-pointer substitution, or success-label injection.
    @MainActor
    func testObsoleteRevisionCleanupCancelConfirmAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let projectName = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let blank = try pixels(canvas.screenshot().image)
        // Each changed drawing is committed by the real production save path.
        // Autosave may win first; it still creates a selected real revision.
        for index in 0..<5 {
            let y = 0.23 + Double(index) * 0.10
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.23, dy: y)).press(forDuration: 0.05,
                thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.71, dy: y + 0.065)))
            try settlePickerCanvasAfterSave(app, canvas: canvas)
        }
        var savedPixels = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(blank, savedPixels), 20, "Actual drawing changes are required")
        XCTAssertGreaterThan(exportInkMask(savedPixels).count, 20)
        let savedFrame = canvas.frame
        capture(app, name: "storage-cleanup-five-saved-drawing-changes")
        app.buttons["studio.back"].tap()
        let project = app.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8))
        let projectID = project.identifier
        XCTAssertTrue(projectID.hasPrefix("studio.project."))
        let projectUUID = String(projectID.dropFirst("studio.project.".count))
        let storage = app.buttons["studio.library.storage"]
        XCTAssertTrue(storage.waitForExistence(timeout: 5)); storage.tap()
        XCTAssertTrue(app.navigationBars["Device Storage"].waitForExistence(timeout: 8))
        let list = app.descendants(matching: .any)["studio.storage.list"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        @MainActor func reveal(_ element: XCUIElement) throws {
            for _ in 0..<5 {
                var viewport = list.frame.intersection(app.frame).insetBy(dx: 4, dy: 8)
                let top = max(viewport.minY, app.navigationBars["Device Storage"].frame.maxY + 4)
                viewport = CGRect(x: viewport.minX, y: top, width: viewport.width, height: max(0, viewport.maxY - top))
                if element.exists && element.isHittable && viewport.contains(element.frame) { return }
                if element.exists && element.frame.minY < viewport.minY {
                    list.swipeDown(velocity: .slow)
                } else {
                    list.swipeUp(velocity: .slow)
                }
            }
            captureHierarchy(app, name: "storage-cleanup-unreachable-control")
            XCTFail("Storage control is not reachable: " + element.identifier)
            throw NSError(domain: "NativeRevisionCleanup", code: 1)
        }
        @MainActor func selectReviewedProject() throws {
            let picker = app.descendants(matching: .any)["studio.storage.project-picker"].firstMatch
            try reveal(picker); picker.tap()
            let exactOption = app.descendants(matching: .any)["studio.storage.project-option." + projectUUID].firstMatch
            if exactOption.exists && exactOption.isHittable {
                exactOption.tap()
            } else {
                // Native Picker may expose the row as a button rather than its Text.
                // Resolve only the unique newly created project, never a remembered
                // first row or another user's existing project.
                let candidates = app.buttons.matching(NSPredicate(format: "label == %@", projectName))
                let choice = try XCTUnwrap(candidates.allElementsBoundByIndex.first { $0.exists && $0.isHittable },
                    "The dedicated project was not available in the actual native picker")
                choice.tap()
            }
        }
        try selectReviewedProject()
        let review = app.buttons["studio.storage.review-revisions"]
        try reveal(review)
        XCTAssertTrue(review.isEnabled); review.tap()
        let preview = app.staticTexts["studio.storage.revision-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        // Cancelling a review releases its scan lease; it is distinct from
        // cancelling the later removal confirmation (which retains the batch).
        let cancelReview = app.buttons["studio.storage.cancel-review"]
        try reveal(cancelReview); XCTAssertTrue(cancelReview.isEnabled); cancelReview.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: preview).waitUntilFulfilled(timeout: 5))
        XCTAssertEqual(app.staticTexts["studio.storage.revision-result"].label,
            "Review cancelled. No saved versions were removed.")
        app.navigationBars["Device Storage"].buttons["Done"].tap()
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        try waitForStableCanvas(canvas, expected: savedFrame)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.23, dy: 0.77)).press(forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.71, dy: 0.82)))
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let afterCancelledReview = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(savedPixels, afterCancelledReview), 20,
            "The post-cancellation save must contain a real new drawing")
        savedPixels = afterCancelledReview
        capture(app, name: "storage-cancel-review-releases-real-project-save")
        app.buttons["studio.back"].tap()
        XCTAssertTrue(storage.waitForExistence(timeout: 5)); storage.tap()
        XCTAssertTrue(app.navigationBars["Device Storage"].waitForExistence(timeout: 8))
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        try selectReviewedProject()
        try reveal(review); XCTAssertTrue(review.isEnabled); review.tap()
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        let reviewedText = preview.label
        let reviewedCount = try XCTUnwrap(Int(reviewedText.split(separator: " ").first.map(String.init) ?? ""))
        XCTAssertGreaterThanOrEqual(reviewedCount, 3, "Real successive saves must yield eligible old versions")
        XCTAssertLessThanOrEqual(reviewedCount, 8, "Review must obey production batch bound")
        let remove = app.buttons["studio.storage.remove-revisions"]
        try reveal(remove); remove.tap()
        let confirm = app.buttons["studio.storage.confirm-remove-revisions"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        let cancel = app.buttons["studio.storage.cancel-confirmation"]
        XCTAssertTrue(cancel.isHittable); cancel.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: confirm).waitUntilFulfilled(timeout: 5))
        XCTAssertEqual(preview.label, reviewedText, "Cancelling must preserve the exact reviewed batch")
        XCTAssertFalse(app.staticTexts["studio.storage.revision-result"].exists, "Cancel must not claim or perform a completed removal")
        capture(app, name: "storage-cleanup-cancel-retains-reviewed-batch")
        try reveal(remove); remove.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        let result = app.staticTexts["studio.storage.revision-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 15))
        XCTAssertTrue(result.label.hasPrefix("Removed \(reviewedCount) obsolete versions ("),
            "Actual removal receipt must match exactly the confirmed batch: " + result.label)
        XCTAssertTrue(result.label.contains("Current, previous, original and unverified recovery files remain."))
        XCTAssertFalse(result.label.contains("Stopped"), "This normal run must not hide a partial cleanup")
        XCTAssertFalse(result.label.contains("Nothing further"), "This normal run must not hide an error")
        capture(app, name: "storage-cleanup-confirmed-actual-removal-receipt")
        app.navigationBars["Device Storage"].buttons["Done"].tap()
        XCTAssertTrue(project.waitForExistence(timeout: 8))
        app.terminate()

        let reopened = try launchGuestStudio()
        defer { reopened.terminate() }
        let search = reopened.textFields["studio.library.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 8)); search.tap(); search.typeText(projectName + "\n")
        let sameProject = reopened.buttons[projectID]
        XCTAssertTrue(sameProject.waitForExistence(timeout: 8)); sameProject.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored)
        XCTAssertEqual(restored.frame, savedFrame, "Compare the same settled native canvas dimensions")
        XCTAssertLessThanOrEqual(try changedPixelCount(savedPixels, pixels(restored.screenshot().image)), 4,
            "Cleanup changed the actual latest saved artwork on cold reopen")
        capture(reopened, name: "storage-cleanup-latest-drawing-cold-reopened")
    }


    /// Actual FileDocument -> local Files provider -> bounded import -> fresh
    /// editable project. No sandbox seeding or successful-export substitute.
    @MainActor
    func testPortableProjectFilesBackupImportCancelAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let name = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let canvasFrame = canvas.frame
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.35)).press(forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.60)))
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let originalPixels = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(exportInkMask(originalPixels).count, 12)
        app.buttons["studio.back"].tap()
        let original = app.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 8))
        let originalID = original.identifier
        XCTAssertTrue(originalID.hasPrefix("studio.project."))
        let projectUUID = String(originalID.dropFirst("studio.project.".count))
        let projectSearch = app.textFields["studio.library.search"]
        projectSearch.tap(); projectSearch.typeText(name + "\n")
        XCTAssertTrue(expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch).waitUntilFulfilled(timeout: 5))
        let beforeIDs = Set(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "studio.project."))
            .allElementsBoundByIndex.map(\.identifier))

        func hittableElement(in query: XCUIElementQuery, timeout: TimeInterval) throws -> XCUIElement {
            var resolved: XCUIElement?
            let ready = expectation(for: NSPredicate { _, _ in
                resolved = query.allElementsBoundByIndex.first { $0.exists && $0.isHittable }
                return resolved != nil
            }, evaluatedWith: app)
            XCTAssertTrue(ready.waitUntilFulfilled(timeout: timeout), "Actual Files provider control did not become hittable")
            return try XCTUnwrap(resolved)
        }
        func providerCancel(importer: Bool) throws {
            let navigation = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"].buttons
            // The system picker remembers its last directory. A prior MP4 export
            // leaves On My iPhone as a back button; Browse is one level above it.
            // Only tap the actual navigation Cancel, never the covered overlay.
            for _ in 0..<5 {
                // Files presents asynchronously after SwiftUI becomes idle.
                // Wait for a real actionable navigation control at each level.
                _ = try hittableElement(in: navigation.matching(NSPredicate(format: "label IN %@",
                    ["Cancel", "On My iPhone", "Browse", "Locations"])), timeout: 10)
                if let cancel = navigation.matching(NSPredicate(format: "label == %@", "Cancel"))
                    .allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) {
                    cancel.tap()
                    XCTAssertTrue(expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: cancel).waitUntilFulfilled(timeout: 8))
                    XCTAssertTrue(app.buttons["studio.library.import-backup"].isHittable)
                    return
                }
                let back = navigation.matching(NSPredicate(format: "label IN %@", ["On My iPhone", "Browse", "Locations"]))
                    .allElementsBoundByIndex.first { $0.exists && $0.isHittable }
                guard let back else { break }
                back.tap()
            }
            captureHierarchy(app, name: importer ? "portable-import-cancel-unavailable" : "portable-export-cancel-unavailable")
            XCTFail("Actual Files Cancel is not reachable from the remembered local location")
            throw NSError(domain: "SDIPortableFilesUI", code: 2)
        }
        func libraryIDs() -> Set<String> {
            Set(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "studio.project."))
                .allElementsBoundByIndex.map(\.identifier))
        }
        func openBackup() throws {
            app.buttons["studio.project-actions." + projectUUID].tap()
            try waitForButton("Save Project Backup to Files", in: app).tap()
            XCTAssertTrue(app.navigationBars["FullDocumentManagerViewControllerNavigationBar"].waitForExistence(timeout: 10))
        }
        // Cancel each actual system picker before any destination is accepted.
        app.buttons["studio.library.import-backup"].tap()
        captureHierarchy(app, name: "portable-import-provider-before-cancel")
        try providerCancel(importer: true)
        XCTAssertEqual(libraryIDs(), beforeIDs, "Cancelled import changed the library")
        try openBackup()
        captureHierarchy(app, name: "portable-backup-provider-before-cancel")
        try providerCancel(importer: false)
        XCTAssertEqual(libraryIDs(), beforeIDs, "Cancelled backup changed the library")

        @MainActor func chooseLocalFilesLocation() throws {
            // A retained local browsingRoot can wrap the frontmost Browse
            // sidebar. Require the real local title/content, not root.exists.
            let navigation = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"]
            for _ in 0..<5 {
                let localRoot = app.otherElements["DOC.browsingRoot Source: com.apple.FileProvider.LocalStorage, Title: On My iPhone"]
                let localTitle = navigation.staticTexts["On My iPhone"]
                let fileView = app.collectionViews["File View"].firstMatch
                if localRoot.exists && localTitle.exists && localTitle.isHittable
                    && fileView.exists && fileView.isHittable { return }
                let localBack = navigation.buttons["On My iPhone"]
                if localBack.exists && localBack.isHittable { localBack.tap(); continue }
                let sidebar = app.cells["DOC.sidebar.item.On My iPhone"]
                if sidebar.exists && sidebar.isHittable { sidebar.tap(); continue }
                let local = app.staticTexts.matching(NSPredicate(format: "label == %@", "On My iPhone"))
                    .allElementsBoundByIndex.first { $0.exists && $0.isHittable }
                if let local { local.tap(); continue }
                let localButton = app.buttons.matching(NSPredicate(format: "label == %@", "On My iPhone"))
                    .allElementsBoundByIndex.first { $0.exists && $0.isHittable }
                if let localButton { localButton.tap(); continue }
                let browse = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Browse", "Locations"))
                    .allElementsBoundByIndex.first { $0.exists && $0.isHittable }
                if let browse { browse.tap() } else { break }
            }
            capture(app, name: "portable-local-files-location-unavailable")
            captureHierarchy(app, name: "portable-local-files-location-unavailable-hierarchy")
            XCTFail("This simulator has no reachable On My iPhone Files location; no backup was saved or cloud destination selected")
            throw NSError(domain: "SDIPortableFilesUI", code: 1)
        }
        try openBackup()
        try chooseLocalFilesLocation()
        captureHierarchy(app, name: "portable-backup-local-destination")
        // iOS 18's actual FileDocument exporter labels this action Move.
        // Both labels invoke the system export; the completion and imported
        // bytes below remain mandatory, never inferred from the button tap.
        let save = try hittableElement(in: app.navigationBars.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Save", "Move")), timeout: 8)
        XCTAssertTrue(save.isEnabled); save.tap()
        let saved = app.staticTexts["Project backup saved to Files."]
        XCTAssertTrue(saved.waitForExistence(timeout: 15), "Actual FileDocument export did not complete")
        XCTAssertEqual(libraryIDs(), beforeIDs)
        capture(app, name: "portable-backup-actual-files-completion")

        app.buttons["studio.library.import-backup"].tap()
        try chooseLocalFilesLocation()
        let file = app.collectionViews["File View"].cells.matching(NSPredicate(format: "label CONTAINS %@", projectUUID)).firstMatch
        let fileAppeared = file.waitForExistence(timeout: 15)
        if !fileAppeared {
            capture(app, name: "portable-saved-file-not-listed")
            captureHierarchy(app, name: "portable-saved-file-not-listed-hierarchy")
        }
        XCTAssertTrue(fileAppeared, "The actual saved .sdiproject file is missing from local Files")
        XCTAssertTrue(file.isHittable); file.tap()
        let imported = app.staticTexts["Imported " + name + " as a new project."]
        XCTAssertTrue(imported.waitForExistence(timeout: 20), "Real bounded reader/asset validation did not complete")
        let afterIDs = libraryIDs(), newIDs = afterIDs.subtracting(beforeIDs)
        XCTAssertEqual(newIDs.count, 1); XCTAssertTrue(afterIDs.isSuperset(of: beforeIDs))
        let importedID = try XCTUnwrap(newIDs.first)
        XCTAssertNotEqual(importedID, originalID)
        app.buttons[importedID].tap()
        try waitForStableCanvas(canvas, expected: canvasFrame)
        XCTAssertLessThanOrEqual(try changedPixelCount(originalPixels, pixels(canvas.screenshot().image)), 4,
                                 "Imported source does not render the actual backed-up drawing")
        XCTAssertFalse(app.buttons["studio.undo"].isEnabled, "Imported project invented prior-process undo history")
        // A distinct edit proves this is a usable native document, not a preview.
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.75)).press(forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.80)))
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let editedCopy = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(originalPixels, editedCopy), 20)
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let reopenedSearch = reopened.textFields["studio.library.search"]
        XCTAssertTrue(reopenedSearch.waitForExistence(timeout: 8))
        reopenedSearch.tap(); reopenedSearch.typeText(name + "\n")
        XCTAssertTrue(expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: reopened.keyboards.firstMatch).waitUntilFulfilled(timeout: 5))
        XCTAssertTrue(reopened.buttons[originalID].waitForExistence(timeout: 8)); reopened.buttons[originalID].tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: canvasFrame)
        XCTAssertLessThanOrEqual(try changedPixelCount(originalPixels, pixels(restored.screenshot().image)), 4,
                                 "Editing the imported identity changed the original project")
        reopened.buttons["studio.back"].tap(); reopened.buttons[importedID].tap()
        try waitForStableCanvas(restored, expected: canvasFrame)
        XCTAssertLessThanOrEqual(try changedPixelCount(editedCopy, pixels(restored.screenshot().image)), 4,
                                 "Imported editable project did not survive a cold reopen")
        capture(reopened, name: "portable-files-import-editable-cold-reopened")
    }

    @MainActor
    func testSpatterDirectMP4PreviewRetainsEditableProject() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let name = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let frame = canvas.frame, before = try pixels(canvas.screenshot().image)
        app.buttons["studio.menu.open"].tap()
        let openSpatter = app.buttons["studio.spatter.open"]
        XCTAssertTrue(openSpatter.waitForExistence(timeout: 8)); XCTAssertTrue(openSpatter.isHittable); openSpatter.tap()
        let motion = app.buttons["spatter.studio.local-motion"]
        XCTAssertTrue(motion.waitForExistence(timeout: 8)); XCTAssertTrue(motion.isHittable); motion.tap()
        let input = try localMotionControl("spatter.motion.input", app: app)
        input.tap(); input.typeText("Two stick figures: red walks left to right; blue waves right to left; 2 seconds.")
        let done = app.buttons["spatter.motion.keyboard.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 8)); XCTAssertTrue(done.isHittable); done.tap()
        try localMotionControl("spatter.motion.apply", app: app).tap()
        let edit = try localMotionControl("spatter.motion.result", app: app)
        XCTAssertTrue(expectation(for: NSPredicate(format: "label CONTAINS %@", "Added 24 editable frames"),
            evaluatedWith: edit).waitUntilFulfilled(timeout: 8))
        try localMotionControl("spatter.motion.save", app: app).tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "Saved"),
            evaluatedWith: app.staticTexts["spatter.motion.save-state"]).waitUntilFulfilled(timeout: 8))
        try localMotionControl("spatter.motion.export-mp4", app: app).tap()
        // No manual Export tap: this action must start the actual movie service.
        let provenance = app.staticTexts["studio.export.movie.spatter-receipt"]
        XCTAssertTrue(provenance.waitForExistence(timeout: 30))
        XCTAssertTrue(provenance.label.contains("verified MP4 from revision"))
        XCTAssertTrue(try exportControl("studio.export.movie.receipt", app: app).label.contains("25 frames · 12 fps"))
        let picture = try exportControl("studio.export.movie.preview", app: app)
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "Preview ready"),
            evaluatedWith: app.staticTexts["studio.export.movie.preview.status"]).waitUntilFulfilled(timeout: 8))
        // Frame zero is the original blank frame; seek into a generated pose.
        let seek = try exportControl("studio.export.movie.preview.seek", app: app)
        seek.adjust(toNormalizedSliderPosition: 0.65)
        _ = try exportControl("studio.export.movie.preview", app: app)
        let actualActors = NSPredicate { _, _ in
            guard let raster = try? self.moviePreviewPixels(picture, app: app) else { return false }
            var blue = 0, red = 0
            for i in stride(from: 0, to: raster.bytes.count, by: 4) {
                if raster.bytes[i + 2] > 130 && raster.bytes[i] < 100 && raster.bytes[i + 1] < 100 { blue += 1 }
                if raster.bytes[i] > 130 && raster.bytes[i + 1] < 100 && raster.bytes[i + 2] < 100 { red += 1 }
            }
            return blue > 12 && red > 12
        }
        XCTAssertTrue(expectation(for: actualActors, evaluatedWith: nil).waitUntilFulfilled(timeout: 8),
                      "Direct MP4 did not decode both independently colored actors")
        capture(app, name: "spatter-direct-mp4-actual-decoded-pose")
        try closeExportPanel(app)
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let edited = try pixels(canvas.screenshot().image)
        let frames = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "studio.frame."))
        let ids = Set(frames.allElementsBoundByIndex.map(\.identifier))
        XCTAssertEqual(ids.count, 25)
        XCTAssertGreaterThan(try changedPixelCount(before, edited), 12)
        app.buttons["studio.undo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertEqual(frames.count, 1)
        XCTAssertLessThanOrEqual(try changedPixelCount(before, pixels(canvas.screenshot().image)), 4)
        app.buttons["studio.redo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertEqual(Set(frames.allElementsBoundByIndex.map(\.identifier)), ids)
        XCTAssertLessThanOrEqual(try changedPixelCount(edited, pixels(canvas.screenshot().image)), 4)
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: frame)
        XCTAssertEqual(Set(reopened.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "studio.frame."))
            .allElementsBoundByIndex.map(\.identifier)), ids)
        XCTAssertLessThanOrEqual(try changedPixelCount(edited, pixels(restored.screenshot().image)), 4)
        capture(reopened, name: "spatter-direct-mp4-editable-cold-reopened")
    }

    @MainActor
    func testBackgroundLibraryFiltersPixelsUndoAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let name = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let frame = canvas.frame, before = try pixels(canvas.screenshot().image)
        func openLibrary() throws {
            app.buttons["studio.menu.open"].tap()
            let button = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Background Library")).firstMatch
            for _ in 0..<5 {
                if button.exists && button.isHittable { break }
                app.scrollViews["studio.menu.scroll"].swipeUp(velocity: .slow)
            }
            XCTAssertTrue(button.isHittable); button.tap()
            XCTAssertTrue(app.buttons["studio.background.category.gradients"].waitForExistence(timeout: 8))
        }
        try openLibrary()
        XCTAssertEqual(app.buttons["studio.background.category.gradients"].label, "Gradients (8)")
        XCTAssertTrue(app.buttons["studio.background.preset.gradient-sunset"].exists)
        app.buttons["studio.background.category.solid"].tap()
        XCTAssertEqual(app.buttons["studio.background.category.solid"].label, "Solid (8)")
        XCTAssertTrue(app.buttons["studio.background.preset.solid-sunset"].exists)
        XCTAssertFalse(app.buttons["studio.background.preset.gradient-sunset"].exists)
        try waitForButton("Close Background Library", in: app).tap()
        try waitForStableCanvas(canvas, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(before, pixels(canvas.screenshot().image)), 4,
                                "Cancelling background browsing changed the project")
        XCTAssertFalse(app.buttons["studio.undo"].isEnabled)
        try openLibrary()
        app.buttons["studio.background.category.solid"].tap()
        let solid = app.buttons["studio.background.preset.solid-sunset"]
        XCTAssertTrue(solid.waitForExistence(timeout: 8)); XCTAssertTrue(solid.isHittable); solid.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "exists == false"),
            evaluatedWith: app.buttons["Close Background Library"]).waitUntilFulfilled(timeout: 8))
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let added = try pixels(canvas.screenshot().image)
        var orange = 0
        for i in stride(from: 0, to: added.bytes.count, by: 4) {
            if abs(Int(added.bytes[i]) - 255) <= 3 && abs(Int(added.bytes[i + 1]) - 107) <= 3 &&
                abs(Int(added.bytes[i + 2]) - 53) <= 3 { orange += 1 }
        }
        XCTAssertGreaterThan(orange, added.width * added.height * 9 / 10,
                             "Background card did not fill the real canvas with its selected color")
        app.buttons["studio.layers.open"].tap()
        XCTAssertTrue(app.staticTexts["Image: Sunset solid background"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Layer 1"].exists)
        app.buttons["studio.layers.close"].tap()
        capture(app, name: "background-solid-real-pixels-layer")
        app.buttons["studio.undo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(before, pixels(canvas.screenshot().image)), 4)
        XCTAssertFalse(app.buttons["studio.undo"].isEnabled)
        app.buttons["studio.redo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(added, pixels(canvas.screenshot().image)), 4)
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(added, pixels(restored.screenshot().image)), 4)
        capture(reopened, name: "background-solid-cold-reopened")
    }

    @MainActor
    func testTweenEasingEditableFramesUndoAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let projectName = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try choosePickerTestColor("#FF0000", app: app)
        try pickerRailControl("studio.tool.rectangle", app: app, forward: true).tap()
        try resetToolPreferencesInPopup(app)
        let fill = app.buttons["studio.shape.fill"]
        XCTAssertEqual(fill.value as? String, "None"); fill.tap()
        XCTAssertEqual(fill.value as? String, "Solid")
        app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(canvas)
        func frames(_ target: XCUIApplication) -> XCUIElementQuery {
            target.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "studio.frame."))
        }
        func redCenter(_ raster: Raster) throws -> Double {
            var sum = 0.0, count = 0
            for y in 0..<raster.height { for x in 0..<raster.width {
                let i = (y * raster.width + x) * 4
                if raster.bytes[i] > 180 && raster.bytes[i + 1] < 90 && raster.bytes[i + 2] < 90 {
                    sum += Double(x); count += 1
                }
            } }
            XCTAssertGreaterThan(count, 40, "Real red rectangle pixels are required")
            return sum / Double(max(1, count)) / Double(raster.width)
        }
        let firstID = frames(app).firstMatch.identifier
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.4)).press(forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.6)))
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let first = try pixels(canvas.screenshot().image), frame = canvas.frame
        app.buttons["studio.add-frame"].tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let lastID = frames(app).allElementsBoundByIndex.first { $0.identifier != firstID }!.identifier
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.4)).press(forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.6)))
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let last = try pixels(canvas.screenshot().image)
        let startX = try redCenter(first), endX = try redCenter(last)
        XCTAssertGreaterThan(endX - startX, 0.25)
        app.buttons[firstID].press(forDuration: 0.7)
        try waitForButton("Tween to next frame…", in: app).tap()
        try waitForButton("Cancel", in: app).tap()
        XCTAssertEqual(app.buttons[lastID].value as? String, "Selected", "Cancelled tween must retain the previous frame")
        XCTAssertEqual(frames(app).count, 2)
        app.buttons[firstID].press(forDuration: 0.7)
        try waitForButton("Tween to next frame…", in: app).tap()
        let count = app.steppers["studio.tween.count"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        // Original CI hierarchy exposes identifier studio.tween.count-Decrement;
        // the child label includes its current numeric value.
        let decrement = count.buttons["studio.tween.count-Decrement"]
        XCTAssertTrue(decrement.exists); XCTAssertTrue(decrement.isHittable)
        for _ in 0..<4 { decrement.tap() }
        XCTAssertTrue(count.label.contains("2 new frames"))
        app.buttons["studio.tween.easing"].tap()
        try waitForButton("Ease in", in: app).tap()
        try waitForButton("Insert in-betweens", in: app).tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertEqual(frames(app).count, 4)
        let inserted = frames(app).matching(NSPredicate(format: "label == %@", "Frame 2")).firstMatch
        let insertedID = inserted.identifier
        inserted.tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        let middle = try pixels(canvas.screenshot().image)
        XCTAssertEqual((try redCenter(middle) - startX) / (endX - startX), 1.0 / 9.0, accuracy: 0.06,
                       "Ease-in must change the actual intermediate artwork")
        app.buttons[firstID].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(first, pixels(canvas.screenshot().image)), 4)
        app.buttons[lastID].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(last, pixels(canvas.screenshot().image)), 4)
        app.buttons["studio.undo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertEqual(frames(app).count, 2)
        XCTAssertEqual(app.buttons[lastID].value as? String, "Selected")
        app.buttons["studio.redo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertEqual(frames(app).count, 4)
        app.buttons[insertedID].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: frame)
        XCTAssertEqual(frames(reopened).count, 4)
        XCTAssertEqual(reopened.buttons[insertedID].value as? String, "Selected")
        XCTAssertLessThanOrEqual(try changedPixelCount(middle, pixels(restored.screenshot().image)), 4)
        capture(reopened, name: "tween-ease-in-editable-cold-reopened")
    }

    @MainActor
    func testProjectLibraryDuplicateRecoveryAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate() }
        let name = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        app.buttons["studio.back"].tap()
        let original = app.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 8))
        try waitForButton("Actions for " + name, in: app).tap()
        try waitForButton("Duplicate Project", in: app).tap()
        let copiedName = name + " Copy"
        let copied = app.buttons.matching(NSPredicate(format: "label == %@", copiedName)).firstMatch
        XCTAssertTrue(copied.waitForExistence(timeout: 8))
        XCTAssertTrue(original.exists, "Duplicating removed the original")
        let search = app.textFields["studio.library.search"]
        search.tap(); search.typeText(copiedName)
        XCTAssertTrue(copied.exists)
        XCTAssertFalse(original.exists, "Project search did not filter by the entered name")
        try waitForButton("Clear project search", in: app).tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch).waitUntilFulfilled(timeout: 5), "Clearing project search must dismiss the keyboard before project actions")
        try waitForButton("Actions for " + copiedName, in: app).tap()
        // Exercise the menu directly; screenshot collection during the native
        // menu transition can block XCTest before the recovery assertions run.
        // The restored library and cold-open canvas are captured below.
        try waitForButton("Move to Recently Deleted", in: app).tap()
        try waitForButton("Move " + copiedName + " to Recently Deleted", in: app).tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: copied).waitUntilFulfilled(timeout: 8))
        XCTAssertTrue(original.exists, "Deleting the copy removed the original")
        app.buttons["studio.library.recently-deleted"].tap()
        let recoveredRow = app.cells.containing(.staticText, identifier: copiedName).firstMatch
        XCTAssertTrue(recoveredRow.waitForExistence(timeout: 8))
        recoveredRow.buttons["Restore"].tap()
        try waitForButton("Done", in: app).tap()
        XCTAssertTrue(copied.waitForExistence(timeout: 8))
        // Finish the persistence journey before collecting diagnostic imagery.
        // A screenshot-service timeout must not prevent cold-reopen assertions.
        app.terminate()
        let reopened = try launchGuestStudio()
        defer { reopened.terminate() }
        let restored = reopened.buttons.matching(NSPredicate(format: "label == %@", copiedName)).firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 8), "Restored copy was lost after relaunch")
        restored.tap()
        XCTAssertTrue(reopened.descendants(matching: .any)["studio.canvas"].firstMatch.waitForExistence(timeout: 8))
        capture(reopened, name: "project-library-restored-cold-open")
    }

    @MainActor
    func testRotoscopePhotosActualPlayheadUndoAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let projectName = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let addFrame = app.buttons["studio.add-frame"]
        XCTAssertTrue(addFrame.isHittable)
        for _ in 0..<6 { addFrame.tap() }
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let before = try pixels(canvas.screenshot().image), canvasFrame = canvas.frame
        app.buttons["studio.menu.open"].tap()
        try waitForButton("Rotoscope / Video", in: app).tap()
        app.buttons["studio.image.photos"].tap()
        XCTAssertTrue(app.navigationBars.buttons["Cancel"].firstMatch.waitForExistence(timeout: 10))
        let deadline = Date().addingTimeInterval(30)
        var selected = false
        repeat {
            let videos = app.navigationBars["Videos"].firstMatch
            let viewports = app.scrollViews.matching(NSPredicate(format: "identifier IN %@",
                ["photosView_content_scroll_view", "content_scroll_view"]))
                .allElementsBoundByIndex.prefix(3).filter {
                    $0.exists && !$0.frame.intersection(app.frame).isEmpty &&
                    $0.images.matching(identifier: "PXGGridLayout-Info").count > 0
                }
            if videos.exists, viewports.count == 1, let viewport = viewports.first {
                let bounds = viewport.frame.intersection(app.frame)
                for candidate in viewport.images.matching(identifier: "PXGGridLayout-Info").allElementsBoundByIndex.prefix(12) {
                    guard Date() < deadline, candidate.exists else { break }
                    let frame = candidate.frame
                    guard frame.width > 24, frame.height > 24, bounds.contains(frame) else { continue }
                    let raster = try pixels(candidate.screenshot().image)
                    if videoPrimaryFraction(raster, channel: 0) > 0.45 {
                        guard candidate.exists, candidate.frame == frame, viewport.exists,
                              viewport.frame.intersection(app.frame).contains(frame), videos.exists else { continue }
                        capture(app, name: "rotoscope-photos-real-video-selection")
                        candidate.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                        selected = true; break
                    }
                }
            }
            if !selected { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        } while !selected && Date() < deadline
        if !selected { captureHierarchy(app, name: "rotoscope-video-grid-missing-fixture") }
        XCTAssertTrue(selected, "Original generated red video thumbnail was absent from the real Photos picker")
        let preview = try imageControl("studio.image.preview", app: app)
        XCTAssertGreaterThan(videoPrimaryFraction(try pixels(preview.screenshot().image), channel: 1), 0.3,
                             "Project time 0.5s must decode the green frame, not the red Photos thumbnail")
        XCTAssertTrue(app.staticTexts["studio.image.dimensions"].label.hasPrefix("64 × 96 pixels"), "Video orientation was lost")
        XCTAssertTrue(try imageControl("studio.image.result", app: app).label.contains("Studio 0.500s"))
        capture(app, name: "rotoscope-photos-decoded-green-playhead")
        try imageControl("studio.image.apply", app: app).tap()
        XCTAssertTrue(try imageControl("studio.image.result", app: app).label.hasPrefix("Added "))
        app.buttons["studio.panel.close.Rotoscope / Video"].tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let edited = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(videoPrimaryFraction(edited, channel: 1), 0.5)
        app.buttons["studio.undo"].tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(before, pixels(canvas.screenshot().image)), 4)
        XCTAssertTrue(app.buttons["studio.redo"].isEnabled); app.buttons["studio.redo"].tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(edited, pixels(canvas.screenshot().image)), 4)
        let save = app.buttons["studio.save"]; save.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "Saved"), evaluatedWith: save).waitUntilFulfilled(timeout: 8))
        capture(app, name: "rotoscope-video-reference-saved-after-redo")
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: canvasFrame)
        XCTAssertLessThanOrEqual(try changedPixelCount(edited, pixels(restored.screenshot().image)), 4)
        let frameTimeline = reopened.scrollViews["studio.frame-timeline"]
        let selectedFrame = reopened.buttons.matching(NSPredicate(format: "label == %@ AND value == %@", "Frame 7", "Selected")).firstMatch
        XCTAssertTrue(frameTimeline.waitForExistence(timeout: 5))
        XCTAssertTrue(selectedFrame.exists)
        let visibleSelection = expectation(for: NSPredicate { _, _ in
            selectedFrame.exists && frameTimeline.frame.contains(selectedFrame.frame) && selectedFrame.isHittable
        }, evaluatedWith: selectedFrame)
        XCTAssertTrue(visibleSelection.waitUntilFulfilled(timeout: 5), "Cold reopen must reveal the complete active frame thumbnail without manual scrolling")
        capture(reopened, name: "rotoscope-video-reference-cold-reopened")
    }

    private func videoPrimaryFraction(_ raster: Raster, channel: Int) -> Double {
        var count = 0
        for offset in stride(from: 0, to: raster.bytes.count, by: 4) {
            let primary = Int(raster.bytes[offset + channel])
            let others = (0..<3).filter { $0 != channel }.map { Int(raster.bytes[offset + $0]) }
            if primary > 180 && others.allSatisfy({ primary - $0 > 120 }) { count += 1 }
        }
        return Double(count) / Double(raster.width * raster.height)
    }

    @MainActor
    func testRotoscopeFilesPickerCancelPreservesProject() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        _ = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let before = try pixels(canvas.screenshot().image)
        app.buttons["studio.menu.open"].tap()
        try waitForButton("Rotoscope / Video", in: app).tap()
        let files = app.buttons["studio.image.files"]
        XCTAssertTrue(files.waitForExistence(timeout: 8))
        let photos = app.buttons["studio.image.photos"]
        XCTAssertTrue(photos.exists && photos.isEnabled)
        XCTAssertFalse(app.buttons["Record Video"].exists, "Do not expose a recording button with no operation")
        XCTAssertFalse(app.buttons["studio.image.apply"].exists, "No decoded frame exists yet")
        capture(app, name: "rotoscope-real-files-import-panel")
        photos.tap()
        // Photos can retain an offscreen Cancel node with an infinite frame.
        // Address the visible video picker navigation bar, not the first duplicate.
        let cancelPhotos = app.navigationBars["Videos"].buttons["Cancel"]
        try waitForHittable(cancelPhotos, app: app, name: "rotoscope-photos-cancel-ready")
        capture(app, name: "rotoscope-native-photos-video-picker")
        captureHierarchy(app, name: "rotoscope-native-photos-video-hierarchy")
        cancelPhotos.tap()
        XCTAssertTrue(files.waitForExistence(timeout: 8)); XCTAssertTrue(files.isEnabled)
        files.tap()
        let navigation = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"]
        let cancel = navigation.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        XCTAssertTrue(app.collectionViews["File View"].exists)
        capture(app, name: "rotoscope-native-files-picker")
        XCTAssertTrue(cancel.isHittable); cancel.tap()
        let result = app.staticTexts["studio.image.result"]
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@",
            "Image import cancelled. No image was added by this pending selection."),
            evaluatedWith: result).waitUntilFulfilled(timeout: 8))
        XCTAssertFalse(app.buttons["studio.image.apply"].exists)
        app.buttons["studio.panel.close.Rotoscope / Video"].tap()
        try waitForStableCanvas(canvas)
        XCTAssertFalse(app.buttons["studio.undo"].isEnabled)
        XCTAssertLessThanOrEqual(try changedPixelCount(before, pixels(canvas.screenshot().image)), 4)
        capture(app, name: "rotoscope-picker-cancelled-unchanged-studio")
    }

    @MainActor
    func testGradientCustomEndpointValidationRenderAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let name = try createProjectIfLibraryIsShown(app)
        let original = try drawNativeGradient(app)
        let frame = original.canvas.frame
        try selectToolbarTool("brush", app: app)
        try gradientPopupControl("studio.brush.gradient-end", app: app, scrollUp: true).tap()
        let input = app.textFields["studio.color.hex"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); XCTAssertTrue(input.isHittable)
        let apply = app.buttons["studio.color.hex.apply"]
        XCTAssertFalse(apply.isEnabled)
        input.tap(); input.typeText("ZZZZZZ")
        XCTAssertFalse(apply.isEnabled, "Malformed custom colors must not mutate preferences")
        XCTAssertEqual(app.staticTexts["studio.color.current"].label, "#0000FF")
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6))
        input.typeText("00FF00")
        XCTAssertTrue(apply.isEnabled); apply.tap()
        XCTAssertEqual(app.staticTexts["studio.color.current"].label, "#00FF00")
        capture(app, name: "gradient-custom-green-endpoint")
        app.buttons["studio.panel.close.Gradient end color"].tap()
        XCTAssertEqual(app.buttons["studio.brush.gradient-end"].value as? String, "#00FF00")
        app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(original.canvas, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(original.drawn, pixels(original.canvas.screenshot().image)), 4,
                                "Changing brush preferences recolored the existing editable stroke")
        XCTAssertEqual(app.buttons["studio.color.open"].value as? String, "#FF0000",
                       "Editing the gradient endpoint changed the primary drawing color")
        app.buttons["studio.undo"].tap()
        try settlePickerCanvasAfterSave(app, canvas: original.canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(original.blank, pixels(original.canvas.screenshot().image)), 4)
        original.canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).press(forDuration: 0.05,
            thenDragTo: original.canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        try settlePickerCanvasAfterSave(app, canvas: original.canvas)
        let green = try pixels(original.canvas.screenshot().image)
        var redPixels = 0, greenPixels = 0, bluePixels = 0
        for y in 0..<green.height {
            for x in 0..<green.width {
                let i = (y * green.width + x) * 4
                let red = Int(green.bytes[i]), g = Int(green.bytes[i+1]), blue = Int(green.bytes[i+2])
                let fraction = Double(x) / Double(green.width)
                if (0.18...0.40).contains(fraction), red > g + 60, blue < 120 { redPixels += 1 }
                if (0.60...0.82).contains(fraction), g > red + 60, blue < 120 { greenPixels += 1 }
                if (0.60...0.82).contains(fraction), blue > g + 60 { bluePixels += 1 }
            }
        }
        XCTAssertGreaterThan(redPixels, 4); XCTAssertGreaterThan(greenPixels, 4)
        XCTAssertEqual(bluePixels, 0, "New stroke ignored the custom endpoint and kept the old blue")
        capture(app, name: "gradient-custom-green-real-stroke")
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(green, pixels(restored.screenshot().image)), 4)
        capture(reopened, name: "gradient-custom-green-cold-reopened")
        try selectToolbarTool("brush", app: reopened)
        let endpoint = try gradientPopupControl("studio.brush.gradient-end", app: reopened, scrollUp: true)
        XCTAssertEqual(endpoint.value as? String, "#00FF00", "Endpoint preference did not survive app termination")
        reopened.buttons["studio.tool-settings.close"].tap()
    }


    @MainActor
    private func gradientPopupControl(_ id: String, app: XCUIApplication, scrollUp: Bool) throws -> XCUIElement {
        let control = app.descendants(matching: .any)[id].firstMatch
        for attempt in 0...4 {
            if control.exists && control.isHittable { return control }
            guard attempt < 4 else { break }
            let scroll = app.scrollViews.containing(.button, identifier: "studio.tool-settings.reset").firstMatch
            XCTAssertTrue(scroll.exists, "Gradient controls must stay inside the one scrollable popup")
            if scrollUp { scroll.swipeUp() } else { scroll.swipeDown() }
        }
        captureHierarchy(app, name: "gradient-control-unreachable-" + id)
        XCTFail("Gradient control is unreachable: " + id)
        throw NSError(domain: "GradientNative", code: 1)
    }

    @MainActor
    private func drawNativeGradient(_ app: XCUIApplication) throws -> (canvas: XCUIElement, blank: Raster, drawn: Raster) {
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let frame = canvas.frame
        try choosePickerTestColor("#FF0000", app: app)
        try selectToolbarTool("brush", app: app)
        try resetToolPreferencesInPopup(app)
        try gradientPopupControl("studio.brush-library", app: app, scrollUp: false).tap()
        try gradientPopupControl("studio.brush-family.gradient", app: app, scrollUp: true).tap()
        XCTAssertTrue(app.buttons["studio.brush-library"].label.contains("Gradient"))
        let size = try gradientPopupControl("studio.setting.size", app: app, scrollUp: false)
        size.adjust(toNormalizedSliderPosition: 0.85)
        let opacity = app.sliders["studio.setting.opacity"]
        XCTAssertTrue(opacity.isHittable); opacity.adjust(toNormalizedSliderPosition: 1)
        let endpoint = try gradientPopupControl("studio.brush.gradient-end", app: app, scrollUp: true)
        XCTAssertTrue(endpoint.exists && endpoint.isHittable, "Gradient must expose its own end-color control")
        capture(app, name: "gradient-family-sole-popup")
        app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(canvas, expected: frame)
        let blank = try pixels(canvas.screenshot().image)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).press(forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let drawn = try pixels(canvas.screenshot().image)
        assertNativeGradientColors(drawn)
        capture(app, name: "gradient-red-to-blue-actual-canvas")
        return (canvas, blank, drawn)
    }

    private func assertNativeGradientColors(_ raster: Raster, file: StaticString = #filePath, line: UInt = #line) {
        var redStart = 0, blueEnd = 0, mixedMiddle = 0
        for y in 0..<raster.height {
            for x in 0..<raster.width {
                let offset = (y * raster.width + x) * 4
                let red = Int(raster.bytes[offset]), green = Int(raster.bytes[offset + 1]), blue = Int(raster.bytes[offset + 2])
                let fraction = Double(x) / Double(raster.width)
                guard green < 120 else { continue }
                if (0.18...0.40).contains(fraction), red > blue + 60 { redStart += 1 }
                if (0.60...0.82).contains(fraction), blue > red + 60 { blueEnd += 1 }
                if (0.45...0.55).contains(fraction), red > 60, blue > 60, abs(red-blue) < 80 { mixedMiddle += 1 }
            }
        }
        XCTAssertGreaterThan(redStart, 4, "Actual gradient does not start with the chosen red", file: file, line: line)
        XCTAssertGreaterThan(blueEnd, 4, "Actual gradient does not reach its reset blue endpoint", file: file, line: line)
        XCTAssertGreaterThan(mixedMiddle, 4, "Gradient is not interpolating between its endpoint colors", file: file, line: line)
    }

    @MainActor
    func testGradientBrushPixelsUndoAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let name = try createProjectIfLibraryIsShown(app)
        let result = try drawNativeGradient(app), frame = result.canvas.frame
        app.buttons["studio.undo"].tap()
        try settlePickerCanvasAfterSave(app, canvas: result.canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(result.blank, pixels(result.canvas.screenshot().image)), 4)
        app.buttons["studio.redo"].tap()
        try settlePickerCanvasAfterSave(app, canvas: result.canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(result.drawn, pixels(result.canvas.screenshot().image)), 4)
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: frame)
        let raster = try pixels(restored.screenshot().image)
        XCTAssertLessThanOrEqual(try changedPixelCount(result.drawn, raster), 4)
        assertNativeGradientColors(raster)
        capture(reopened, name: "gradient-actual-cold-reopened")
    }

    @MainActor
    func testGradientBrushRealPNGExport() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        _ = try createProjectIfLibraryIsShown(app)
        _ = try drawNativeGradient(app)
        try openExportPanel(app)
        try exportControl("studio.export.format.png", app: app, scrollUp: false).tap()
        try exportControl("studio.export.start", app: app).tap()
        let preview = try waitForPNGPreview(app)
        let output = try exportPreviewPixels(preview, app: app, name: "gradient-red-blue")
        assertNativeGradientColors(output)
        capture(app, name: "gradient-real-decoded-png")
    }


    @MainActor
    func testNonActiveFrameCopyPasteUndoAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let projectName = try createProjectIfLibraryIsShown(app)
        let prepared = try preparePickerSourceStroke(app), canvas = prepared.canvas
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let canvasFrame = canvas.frame, drawn = try pixels(canvas.screenshot().image)
        func frames(_ target: XCUIApplication) -> XCUIElementQuery {
            target.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "studio.frame."))
        }
        let originalID = frames(app).firstMatch.identifier
        app.buttons["studio.add-frame"].tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let blankID = frames(app).allElementsBoundByIndex.first { $0.identifier != originalID }!.identifier
        let blank = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(drawn, blank), 50)
        app.buttons[originalID].press(forDuration: 0.7)
        let copy = app.buttons["studio.frame-menu.copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5) && copy.isHittable && copy.isEnabled)
        copy.tap()
        XCTAssertEqual(app.buttons[blankID].value as? String, "Selected", "Copy must leave the current frame selected")
        XCTAssertEqual(frames(app).count, 2)
        XCTAssertEqual(app.buttons["studio.save"].label, "Saved", "Copy must not dirty the project")
        XCTAssertLessThanOrEqual(try changedPixelCount(blank, pixels(canvas.screenshot().image)), 4)
        let paste = app.buttons["studio.paste"]
        XCTAssertTrue(paste.isEnabled && paste.isHittable)
        XCTAssertEqual(paste.label, "Paste frame")
        paste.tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertEqual(frames(app).count, 3)
        let copyID = frames(app).allElementsBoundByIndex.first { $0.identifier != originalID && $0.identifier != blankID }!.identifier
        XCTAssertEqual(app.buttons[copyID].label, "Frame 3")
        XCTAssertEqual(app.buttons[copyID].value as? String, "Selected")
        XCTAssertLessThanOrEqual(try changedPixelCount(drawn, pixels(canvas.screenshot().image)), 4)
        capture(app, name: "frame-explicit-copy-pasted")
        app.buttons["studio.undo"].tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertEqual(frames(app).count, 2)
        XCTAssertEqual(app.buttons[blankID].value as? String, "Selected")
        XCTAssertLessThanOrEqual(try changedPixelCount(blank, pixels(canvas.screenshot().image)), 4)
        app.buttons["studio.redo"].tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertEqual(app.buttons[copyID].value as? String, "Selected")
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: canvasFrame)
        XCTAssertEqual(frames(reopened).count, 3)
        XCTAssertEqual(reopened.buttons[copyID].value as? String, "Selected")
        XCTAssertEqual(reopened.buttons[copyID].label, "Frame 3")
        XCTAssertLessThanOrEqual(try changedPixelCount(drawn, pixels(restored.screenshot().image)), 4)
        XCTAssertFalse(reopened.buttons["studio.paste"].isEnabled, "Clipboard must not persist across app launches")
        capture(reopened, name: "frame-copy-paste-cold-reopened")
    }

    @MainActor
    func testFrameContextDuplicateUndoRedo() throws {
        try verifyFrameContext(duplicateHistoryOnly: true)
    }

    @MainActor
    func testFramesViewerStableSelectionAfterReorderAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let projectName = try createProjectIfLibraryIsShown(app)
        let prepared = try preparePickerSourceStroke(app), canvas = prepared.canvas
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let canvasFrame = canvas.frame, drawn = try pixels(canvas.screenshot().image)
        let timelineFrames = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "studio.frame."))
        XCTAssertEqual(timelineFrames.count, 1)
        let originalID = timelineFrames.firstMatch.identifier
        app.buttons["studio.add-frame"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertEqual(timelineFrames.count, 2)
        let blankID = try XCTUnwrap(timelineFrames.allElementsBoundByIndex.first { $0.identifier != originalID }).identifier
        let blank = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(drawn, blank), 50)
        @MainActor func selectInViewer(_ identifier: String, ordinal: Int, expected: Raster) throws {
            app.buttons["studio.menu.open"].tap()
            try waitForButton("Frames Viewer", in: app).tap()
            let stableID = String(identifier.dropFirst("studio.frame.".count))
            let row = app.buttons["studio.frames-viewer.frame." + stableID]
            XCTAssertTrue(row.waitForExistence(timeout: 5)); XCTAssertTrue(row.isHittable)
            XCTAssertEqual(row.label, "Frame \(ordinal)")
            row.tap()
            try waitForStableCanvas(canvas, expected: canvasFrame)
            XCTAssertEqual(app.buttons[identifier].value as? String, "Selected")
            XCTAssertEqual(app.buttons[identifier].label, "Frame \(ordinal)")
            XCTAssertLessThanOrEqual(try changedPixelCount(expected, pixels(canvas.screenshot().image)), 4,
                "Frames Viewer selected another cel's pixels")
        }
        try selectInViewer(originalID, ordinal: 1, expected: drawn)
        app.buttons[originalID].press(forDuration: 0.7)
        let later = app.buttons["studio.frame-menu.later"]
        XCTAssertTrue(later.waitForExistence(timeout: 5)); XCTAssertTrue(later.isEnabled && later.isHittable); later.tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertEqual(app.buttons[originalID].label, "Frame 2")
        XCTAssertEqual(app.buttons[blankID].label, "Frame 1")
        try selectInViewer(blankID, ordinal: 1, expected: blank)
        try selectInViewer(originalID, ordinal: 2, expected: drawn)
        capture(app, name: "frames-viewer-reordered-stable-selection")
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: canvasFrame)
        XCTAssertEqual(reopened.buttons[originalID].label, "Frame 2")
        XCTAssertEqual(reopened.buttons[originalID].value as? String, "Selected")
        XCTAssertLessThanOrEqual(try changedPixelCount(drawn, pixels(restored.screenshot().image)), 4,
            "Cold reopen lost Frames Viewer target artwork")
        capture(reopened, name: "frames-viewer-selection-cold-reopened")
    }

    @MainActor
    func testFrameExposureRepeatUndoAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let projectName = try createProjectIfLibraryIsShown(app)
        let prepared = try preparePickerSourceStroke(app), canvas = prepared.canvas
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let canvasFrame = canvas.frame, drawn = try pixels(canvas.screenshot().image)
        @MainActor func thumbnails(_ target: XCUIApplication) -> XCUIElementQuery {
            target.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "studio.frame."))
        }
        @MainActor func repeatOption(_ target: XCUIApplication, frameID: String) throws -> XCUIElement {
            let frame = target.buttons[frameID]
            XCTAssertTrue(frame.waitForExistence(timeout: 5) && frame.isHittable)
            frame.press(forDuration: 0.7)
            let menu = target.buttons["studio.frame-menu.repeat"]
            XCTAssertTrue(menu.waitForExistence(timeout: 5) && menu.isHittable); menu.tap()
            let option = target.buttons["studio.frame-menu.repeat.2"]
            XCTAssertTrue(option.waitForExistence(timeout: 5) && option.isEnabled && option.isHittable)
            // This label is computed from this cel's stored durationTicks and the
            // project's actual FPS, rather than the exposure menu's fixed presets.
            XCTAssertEqual(option.label, "Add 2 copies (0.50s)")
            return option
        }
        XCTAssertEqual(thumbnails(app).count, 1)
        let originalID = thumbnails(app).firstMatch.identifier
        app.buttons[originalID].press(forDuration: 0.7)
        try waitForButton("Frame exposure", in: app).tap()
        let hold = app.buttons["studio.frame-menu.hold.3"]
        XCTAssertTrue(hold.waitForExistence(timeout: 5) && hold.isEnabled && hold.isHittable)
        XCTAssertEqual(hold.label, "3 ticks (0.25s)"); hold.tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertEqual(thumbnails(app).count, 1, "Exposure must hold the actual cel, not create copies")
        XCTAssertEqual(app.buttons[originalID].value as? String, "Selected")
        XCTAssertLessThanOrEqual(try changedPixelCount(drawn, pixels(canvas.screenshot().image)), 4)
        try repeatOption(app, frameID: originalID).tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let repeatedIDs = Set(thumbnails(app).allElementsBoundByIndex.map(\.identifier))
        XCTAssertEqual(repeatedIDs.count, 3); XCTAssertTrue(repeatedIDs.contains(originalID))
        let selected = thumbnails(app).matching(NSPredicate(format: "value == %@", "Selected"))
        XCTAssertEqual(selected.count, 1)
        let copyID = selected.firstMatch.identifier
        XCTAssertNotEqual(copyID, originalID)
        XCTAssertLessThanOrEqual(try changedPixelCount(drawn, pixels(canvas.screenshot().image)), 4,
            "Repeat must copy the original cel's real artwork")
        app.buttons["studio.undo"].tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertEqual(thumbnails(app).count, 1, "One Undo must remove both repeated cels")
        XCTAssertEqual(app.buttons[originalID].value as? String, "Selected")
        XCTAssertLessThanOrEqual(try changedPixelCount(drawn, pixels(canvas.screenshot().image)), 4)
        app.buttons["studio.redo"].tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertEqual(Set(thumbnails(app).allElementsBoundByIndex.map(\.identifier)), repeatedIDs)
        XCTAssertEqual(app.buttons[copyID].value as? String, "Selected")
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: canvasFrame)
        XCTAssertEqual(Set(thumbnails(reopened).allElementsBoundByIndex.map(\.identifier)), repeatedIDs)
        XCTAssertEqual(reopened.buttons[copyID].value as? String, "Selected")
        XCTAssertLessThanOrEqual(try changedPixelCount(drawn, pixels(restored.screenshot().image)), 4)
        _ = try repeatOption(reopened, frameID: copyID)
        capture(reopened, name: "frame-exposure-repeat-duration-cold-reopened")
    }

    @MainActor
    func testFrameContextReorderDeleteUndoAndColdReopen() throws {
        try verifyFrameContext(duplicateHistoryOnly: false)
    }

    @MainActor
    private func verifyFrameContext(duplicateHistoryOnly: Bool) throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let projectName = try createProjectIfLibraryIsShown(app)
        let prepared = try preparePickerSourceStroke(app), canvas = prepared.canvas
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let canvasFrame = canvas.frame, drawn = try pixels(canvas.screenshot().image)
        func thumbnails(_ target: XCUIApplication) -> XCUIElementQuery {
            target.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "studio.frame."))
        }
        func contextAction(_ frameID: String, _ action: String) throws {
            let frame = app.buttons[frameID]
            XCTAssertTrue(frame.waitForExistence(timeout: 5) && frame.isHittable)
            frame.press(forDuration: 0.7)
            let control = app.buttons["studio.frame-menu." + action]
            XCTAssertTrue(control.waitForExistence(timeout: 5) && control.isHittable && control.isEnabled)
            control.tap()
            try settlePickerCanvasAfterSave(app, canvas: canvas)
        }
        XCTAssertEqual(thumbnails(app).count, 1)
        let originalID = thumbnails(app).firstMatch.identifier
        XCTAssertEqual(app.buttons[originalID].value as? String, "Selected")
        app.buttons["studio.add-frame"].tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertEqual(thumbnails(app).count, 2)
        let blankID = thumbnails(app).allElementsBoundByIndex.first { $0.identifier != originalID }!.identifier
        XCTAssertEqual(app.buttons[blankID].value as? String, "Selected")
        let blank = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(drawn, blank), 50)
        try contextAction(originalID, "duplicate")
        XCTAssertEqual(thumbnails(app).count, 3)
        let copyID = thumbnails(app).allElementsBoundByIndex.first {
            $0.identifier != originalID && $0.identifier != blankID
        }!.identifier
        XCTAssertEqual(app.buttons[copyID].label, "Frame 2")
        XCTAssertEqual(app.buttons[copyID].value as? String, "Selected")
        XCTAssertLessThanOrEqual(try changedPixelCount(drawn, pixels(canvas.screenshot().image)), 4)
        if duplicateHistoryOnly {
            app.buttons["studio.undo"].tap()
            try settlePickerCanvasAfterSave(app, canvas: canvas)
            XCTAssertEqual(thumbnails(app).count, 2)
            XCTAssertFalse(app.buttons[copyID].exists)
            XCTAssertEqual(app.buttons[blankID].value as? String, "Selected", "Undo must restore selection from before the context menu")
            XCTAssertLessThanOrEqual(try changedPixelCount(blank, pixels(canvas.screenshot().image)), 4)
            app.buttons["studio.redo"].tap()
            try settlePickerCanvasAfterSave(app, canvas: canvas)
            XCTAssertEqual(app.buttons[copyID].value as? String, "Selected")
            return
        }
        try contextAction(copyID, "earlier")
        XCTAssertEqual(app.buttons[copyID].label, "Frame 1")
        XCTAssertEqual(app.buttons[originalID].label, "Frame 2")
        XCTAssertEqual(app.buttons[copyID].value as? String, "Selected")
        capture(app, name: "frame-stable-identity-reordered")
        app.buttons["studio.undo"].tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertEqual(app.buttons[copyID].label, "Frame 2")
        try contextAction(originalID, "delete")
        XCTAssertFalse(app.buttons[originalID].exists)
        XCTAssertEqual(app.buttons[copyID].value as? String, "Selected")
        XCTAssertLessThanOrEqual(try changedPixelCount(drawn, pixels(canvas.screenshot().image)), 4)
        app.buttons["studio.undo"].tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertTrue(app.buttons[originalID].exists)
        let retainedIDs = Set(thumbnails(app).allElementsBoundByIndex.map(\.identifier))
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: canvasFrame)
        XCTAssertEqual(Set(thumbnails(reopened).allElementsBoundByIndex.map(\.identifier)), retainedIDs)
        XCTAssertEqual(reopened.buttons[copyID].value as? String, "Selected")
        XCTAssertEqual(reopened.buttons[copyID].label, "Frame 2")
        XCTAssertLessThanOrEqual(try changedPixelCount(drawn, pixels(restored.screenshot().image)), 4)
        capture(reopened, name: "frame-identities-order-selection-cold-reopened")
    }

    @MainActor
    func testWelcomeGuideNavigationAndLocalCompletion() throws {
        let app = try launchAtWelcome()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.staticTexts["welcome.account-unavailable"].exists,
                      "Unconfigured account services must be disclosed")
        capture(app, name: "welcome-reference-layout")
        try tapWelcomeAction("welcome.sign-in", in: app)
        XCTAssertTrue(app.staticTexts["Welcome Back"].waitForExistence(timeout: 5))
        let loginBack = app.buttons["auth.back"]
        XCTAssertTrue(loginBack.waitForExistence(timeout: 5))
        capture(app, name: "login-back-hit-target")
        XCTAssertTrue(loginBack.isHittable, "Account Back must expose a tappable hit target")
        loginBack.tap()
        try tapWelcomeAction("welcome.create-account", in: app)
        XCTAssertTrue(app.staticTexts["Join the Carnage"].waitForExistence(timeout: 5))
        let signupBack = app.buttons["auth.back"]
        XCTAssertTrue(signupBack.waitForExistence(timeout: 5))
        capture(app, name: "signup-back-hit-target")
        XCTAssertTrue(signupBack.isHittable, "Account Back must expose a tappable hit target")
        signupBack.tap()
        try tapWelcomeAction("welcome.guide", in: app)
        XCTAssertTrue(app.staticTexts["onboarding.position"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["onboarding.position"].label, "1 of 5")
        XCTAssertFalse(app.staticTexts["Join a community of 100,000+ artists"].exists)
        capture(app, name: "onboarding-welcome")
        app.buttons["onboarding.next"].tap()
        XCTAssertEqual(app.staticTexts["onboarding.position"].label, "2 of 5")
        app.buttons["onboarding.back"].tap()
        XCTAssertEqual(app.staticTexts["onboarding.position"].label, "1 of 5")
        app.buttons["onboarding.back"].tap()
        XCTAssertTrue(app.buttons["welcome.guide"].waitForExistence(timeout: 5))
        try tapWelcomeAction("welcome.guide", in: app)
        app.buttons["onboarding.dot.2"].tap()
        XCTAssertEqual(app.staticTexts["onboarding.position"].label, "3 of 5")
        XCTAssertTrue(app.staticTexts["Planned next · not connected in this build"].exists)
        capture(app, name: "onboarding-collaboration-status")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["onboarding.next"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["onboarding.next"].isHittable)
        XCTAssertTrue(app.buttons["onboarding.skip"].isHittable)
        capture(app, name: "onboarding-landscape-controls")
        XCUIDevice.shared.orientation = .portrait
        app.buttons["onboarding.dot.4"].tap()
        XCTAssertEqual(app.staticTexts["onboarding.position"].label, "5 of 5")
        app.buttons["onboarding.next"].tap()
        try waitForButton("Skip Tutorial", in: app).tap()
        XCTAssertTrue(app.descendants(matching: .any)["studio.library"].firstMatch.waitForExistence(timeout: 5),
                      "Open Studio routed to a different tab")
        let name = try createProjectIfLibraryIsShown(app)
        XCTAssertTrue(app.buttons["studio.back"].waitForExistence(timeout: 8))
        app.buttons["studio.back"].tap()
        app.terminate()
        let reopened = try launchAtWelcome()
        defer { reopened.terminate() }
        let guide = reopened.buttons["welcome.guide"]
        XCTAssertTrue(guide.waitForExistence(timeout: 5))
        XCTAssertEqual(guide.label, "Review Studio Guide", "Guide completion did not survive relaunch")
        try tapWelcomeAction("welcome.guide", in: reopened)
        reopened.buttons["onboarding.skip"].tap()
        try waitForButton("Skip Tutorial", in: reopened).tap()
        try waitForButton("Studio", in: reopened).tap()
        XCTAssertTrue(reopened.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch.waitForExistence(timeout: 8), "Guide navigation lost the local project")
        capture(reopened, name: "guide-completed-local-project-preserved")
    }

    @MainActor
    func testAlphaLockPaintUndoColdReopenAndRealPNG() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let projectName = try createProjectIfLibraryIsShown(app)
        let prepared = try preparePickerSourceStroke(app), canvas = prepared.canvas
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let frame = canvas.frame, original = try pixels(canvas.screenshot().image)
        func coloredMask(_ raster: Raster) -> Set<Int> {
            Set((0..<(raster.width * raster.height)).filter { pixel in
                let i = pixel * 4, r = Int(raster.bytes[i]), g = Int(raster.bytes[i + 1]), b = Int(raster.bytes[i + 2])
                return (r > g + 24 && r > b + 24) || (b > r + 24 && b > g + 24)
            })
        }
        app.buttons["studio.layers.open"].tap()
        let row = app.staticTexts["Layer 1"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5) && row.isHittable); row.tap()
        try waitForButton("Alpha", in: app).tap()
        app.buttons["studio.layers.close"].tap()
        try choosePickerTestColor("#FF0000", app: app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).press(forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let painted = try pixels(canvas.screenshot().image)
        let originalCoverage = coloredMask(original), paintedCoverage = coloredMask(painted)
        let red = exportInkMask(painted)
        XCTAssertGreaterThan(red.count, 12, "Alpha lock rejected all paint instead of repainting existing coverage")
        XCTAssertGreaterThan(try changedPixelCount(original, painted), 12)
        XCTAssertLessThanOrEqual(paintedCoverage.subtracting(originalCoverage).count, max(8, originalCoverage.count / 100),
            "Alpha paint escaped the existing blue stroke into empty canvas")
        XCTAssertLessThanOrEqual(originalCoverage.subtracting(paintedCoverage).count, max(8, originalCoverage.count / 100),
            "Alpha paint removed prior visible coverage")
        app.buttons["studio.undo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4)
        app.buttons["studio.redo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(painted, pixels(canvas.screenshot().image)), 4)
        capture(app, name: "alpha-lock-real-constrained-paint")
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(painted, pixels(restored.screenshot().image)), 4)
        try openExportPanel(reopened)
        try exportControl("studio.export.format.png", app: reopened, scrollUp: false).tap()
        try exportControl("studio.export.start", app: reopened).tap()
        let preview = try waitForPNGPreview(reopened)
        let output = try exportPreviewPixels(preview, app: reopened, name: "alpha-lock-cold-real-png")
        let outputCoverage = coloredMask(output), outputRed = exportInkMask(output)
        XCTAssertGreaterThan(outputRed.count, 4); XCTAssertGreaterThan(outputCoverage.subtracting(outputRed).count, 4)
        XCTAssertEqual(Double(outputRed.count) / Double(max(1, outputCoverage.count)),
            Double(red.count) / Double(max(1, paintedCoverage.count)), accuracy: 0.08,
            "Decoded PNG changed the constrained red/blue coverage proportions")
        XCTAssertEqual(Double(outputCoverage.count) / Double(output.width * output.height),
            Double(paintedCoverage.count) / Double(painted.width * painted.height), accuracy: 0.015,
            "Decoded PNG expanded alpha paint outside the stored stroke")
        capture(reopened, name: "alpha-lock-cold-export-ready")
    }

    @MainActor
    func testStickerShelfLockedRejectionThenInsertUndo() throws {
        let app = try launchGuestStudio(); defer { app.terminate() }
        _ = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas); let frame = canvas.frame
        let blank = try pixels(canvas.screenshot().image)
        @MainActor func lock(_ name: String) throws {
            app.buttons["studio.layers.open"].tap()
            let row = app.staticTexts["Layer 1"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5) && row.isHittable); row.tap()
            try waitForButton(name, in: app).tap()
            app.buttons["studio.layers.close"].tap()
            try settlePickerCanvasAfterSave(app, canvas: canvas)
        }
        @MainActor func openShelf() throws {
            app.buttons["studio.menu.open"].tap()
            let settings = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Project Settings")).firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 5) && settings.isHittable); settings.tap()
            let field = app.textFields["studio.settings.name"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            let scroll = app.scrollViews.containing(.textField, identifier: "studio.settings.name").firstMatch
            let shelf = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Stickers & Emoji")).firstMatch
            XCTAssertTrue(shelf.waitForExistence(timeout: 5) && scroll.exists)
            for _ in 0..<4 where !shelf.isHittable { scroll.swipeUp(velocity: .slow) }
            XCTAssertTrue(shelf.isHittable); shelf.tap()
            XCTAssertTrue(app.buttons["studio.sticker.item.f1"].waitForExistence(timeout: 5))
        }
        try lock("Full"); try openShelf()
        let search = app.textFields["studio.sticker.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Swordsman\n")
        let sword = app.buttons["studio.sticker.item.f1"]
        XCTAssertTrue(sword.isHittable); sword.tap()
        let result = app.staticTexts["studio.sticker.result"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertEqual(result.label, "Choose a visible, unlocked layer before editing.")
        XCTAssertTrue(sword.exists && sword.isHittable, "Rejected insertion dismissed the chooser")
        XCTAssertEqual(search.value as? String, "Swordsman", "Rejection discarded the user's shelf search")
        capture(app, name: "sticker-locked-chooser-retained")
        app.buttons["studio.panel.close.Stickers & Emoji"].tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(blank, pixels(canvas.screenshot().image)), 4,
                                "Rejected shelf action changed canvas pixels")
        try lock("Free"); try openShelf()
        let available = app.buttons["studio.sticker.item.f1"]
        XCTAssertTrue(available.isHittable); available.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: available).waitUntilFulfilled(timeout: 5),
                      "Successful insertion did not dismiss chooser")
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertGreaterThan(try changedPixelCount(blank, pixels(canvas.screenshot().image)), 20,
                             "Successful shelf action added no actual glyph pixels")
        capture(app, name: "sticker-inserted-real-glyph")
        app.buttons["studio.undo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        try waitForStableCanvas(canvas, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(blank, pixels(canvas.screenshot().image)), 4,
                                "One Undo did not remove the newly inserted glyph")
    }

    @MainActor
    func testLayerFullLockAndHiddenPaintingRejectWithoutHistory() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        _ = try createProjectIfLibraryIsShown(app)
        let prepared = try preparePickerSourceStroke(app), canvas = prepared.canvas
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let frame = canvas.frame, original = try pixels(canvas.screenshot().image)
        @MainActor func crossStroke() {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).press(forDuration: 0.05,
                thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
        }
        app.buttons["studio.layers.open"].tap()
        let row = app.staticTexts["Layer 1"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5) && row.isHittable); row.tap()
        try waitForButton("Full", in: app).tap()
        app.buttons["studio.layers.close"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        crossStroke()
        let rejection = app.staticTexts["studio.status"]
        XCTAssertTrue(rejection.waitForExistence(timeout: 5))
        XCTAssertEqual(rejection.label, "This tool or layer cannot edit here yet. Choose an unlocked Brush, Pen, Pencil, Eraser or shape tool.")
        // Rejection is deliberately visible and changes available canvas height.
        // The real Save action clears this notice without adding an Undo entry.
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        try waitForStableCanvas(canvas, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4,
            "Full-locked layer accepted painting")
        app.buttons["studio.undo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        // The denied stroke must not consume Undo: one Undo restores the Free
        // lock, demonstrated by this same gesture now creating real pixels.
        crossStroke(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertGreaterThan(try changedPixelCount(original, pixels(canvas.screenshot().image)), 30,
            "One Undo after denied paint failed to unlock the layer")
        app.buttons["studio.undo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4)
        app.buttons["studio.layers.open"].tap()
        // Actual preserved layer AX exposes the SF Symbol as the Button ID;
        // scope to the sole project layer, not an arbitrary screen coordinate.
        let list = app.scrollViews["studio.layers.list"], visibility = list.buttons["eye.fill"]
        XCTAssertTrue(visibility.waitForExistence(timeout: 5) && visibility.isHittable)
        XCTAssertEqual(list.buttons.matching(identifier: "eye.fill").count, 1); visibility.tap()
        app.buttons["studio.layers.close"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        let hidden = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(original, hidden), 30, "Visibility toggle did not remove actual artwork")
        crossStroke()
        let hiddenRejection = app.staticTexts["studio.status"]
        XCTAssertTrue(hiddenRejection.waitForExistence(timeout: 5))
        XCTAssertEqual(hiddenRejection.label, "This tool or layer cannot edit here yet. Choose an unlocked Brush, Pen, Pencil, Eraser or shape tool.")
        // Rejection is deliberately visible and changes available canvas height.
        // The real Save action clears this notice without adding an Undo entry.
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        try waitForStableCanvas(canvas, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(hidden, pixels(canvas.screenshot().image)), 4)
        app.buttons["studio.undo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4,
            "Hidden-layer denied paint altered artwork or consumed the visibility Undo")
        capture(app, name: "full-lock-and-hidden-paint-atomic-denial")
    }

    @MainActor
    func testLayerGlowColorRadiusStrengthUndoAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let projectName = try createProjectIfLibraryIsShown(app)
        let prepared = try preparePickerSourceStroke(app), canvas = prepared.canvas
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let frame = canvas.frame, original = try pixels(canvas.screenshot().image)
        @MainActor func openLayer(_ target: XCUIApplication) throws {
            target.buttons["studio.layers.open"].tap()
            let row = target.staticTexts["Layer 1"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5)); XCTAssertTrue(row.isHittable); row.tap()
        }
        @MainActor func reveal(_ control: XCUIElement, in target: XCUIApplication) throws -> XCUIElement {
            XCTAssertTrue(control.waitForExistence(timeout: 5))
            let list = target.scrollViews["studio.layers.list"]
            for _ in 0..<4 where !control.isHittable { list.swipeUp(velocity: .slow) }
            XCTAssertTrue(control.isHittable && control.isEnabled)
            return control
        }
        try openLayer(app)
        let glow = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH %@", "studio.layer.glow.")).firstMatch
        try reveal(glow, in: app).tap()
        XCTAssertEqual(glow.value as? String, "1")
        try reveal(app.buttons["studio.layer.glow-color.#00FF00"], in: app).tap()
        let radius = app.sliders.matching(NSPredicate(format: "identifier BEGINSWITH %@", "studio.layer.glow-radius.")).firstMatch
        try reveal(radius, in: app).adjust(toNormalizedSliderPosition: 0.25)
        let radiusID = radius.identifier, savedRadius = try XCTUnwrap(radius.value as? String)
        let strength = app.sliders.matching(NSPredicate(format: "identifier BEGINSWITH %@", "studio.layer.glow-strength.")).firstMatch
        // Radius sits below strength; reveal from the top again when needed.
        if !strength.isHittable { app.scrollViews["studio.layers.list"].swipeDown(velocity: .slow) }
        try reveal(strength, in: app).adjust(toNormalizedSliderPosition: 0)
        let strengthID = strength.identifier, glowID = glow.identifier
        app.buttons["studio.layers.close"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        let zeroStrength = try pixels(canvas.screenshot().image)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, zeroStrength), 4, "Zero strength still changed actual layer pixels")
        try openLayer(app)
        try reveal(app.sliders[strengthID], in: app).adjust(toNormalizedSliderPosition: 1)
        let savedStrength = try XCTUnwrap(app.sliders[strengthID].value as? String)
        capture(app, name: "layer-glow-real-controls")
        app.buttons["studio.layers.close"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        let glowing = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(zeroStrength, glowing), 30, "Glow controls changed no real pixels")
        var greenHalo = 0
        for offset in stride(from: 0, to: glowing.bytes.count, by: 4) {
            let red = Int(glowing.bytes[offset]), green = Int(glowing.bytes[offset + 1]), blue = Int(glowing.bytes[offset + 2])
            if green > red + 12 && green > blue + 12 { greenHalo += 1 }
        }
        XCTAssertGreaterThan(greenHalo, 10, "Chosen green glow did not appear around the actual blue stroke")
        app.buttons["studio.undo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(zeroStrength, pixels(canvas.screenshot().image)), 4, "One Undo did not restore zero-strength pixels")
        app.buttons["studio.redo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(glowing, pixels(canvas.screenshot().image)), 4, "One Redo did not restore glow pixels")
        capture(app, name: "layer-glow-actual-pixels")
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(glowing, pixels(restored.screenshot().image)), 4, "Cold reopen changed glow color/geometry/pixels")
        capture(reopened, name: "layer-glow-cold-reopened")
        try openLayer(reopened)
        XCTAssertEqual(try reveal(reopened.switches[glowID], in: reopened).value as? String, "1")
        XCTAssertEqual(try reveal(reopened.sliders[strengthID], in: reopened).value as? String, savedStrength)
        XCTAssertEqual(try reveal(reopened.sliders[radiusID], in: reopened).value as? String, savedRadius)
        reopened.buttons["studio.layers.close"].tap()
    }

    @MainActor
    func testLayerRenameCancelUndoAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let projectName = try createProjectIfLibraryIsShown(app)
        let prepared = try preparePickerSourceStroke(app), canvas = prepared.canvas
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let frame = canvas.frame, original = try pixels(canvas.screenshot().image)
        func showLayers() { app.buttons["studio.layers.open"].tap() }
        func renameInput() throws -> XCUIElement {
            let rename = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "studio.layer.rename.")).firstMatch
            XCTAssertTrue(rename.waitForExistence(timeout: 5))
            XCTAssertTrue(expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: rename).waitUntilFulfilled(timeout: 8))
            rename.tap()
            // The original iOS18.5 AX snapshot exposes the UIKit alert field
            // by its placeholder, without SwiftUI's accessibility identifier.
            let dialog = app.alerts.firstMatch
            XCTAssertTrue(dialog.staticTexts["Rename layer"].waitForExistence(timeout: 5))
            XCTAssertEqual(dialog.textFields.count, 1)
            let input = dialog.textFields.firstMatch
            XCTAssertEqual(input.placeholderValue, "Layer name")
            XCTAssertTrue(input.isHittable); input.tap()
            return input
        }
        showLayers();app.staticTexts["Layer 1"].tap()
        let cancelled = try renameInput();cancelled.typeText(" cancelled")
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Layer 1"].exists)
        let input = try renameInput()
        XCTAssertEqual(input.value as? String, "Layer 1")
        // The preserved iOS 18.5 failure recording shows the caret at the
        // beginning: backspacing seven times left "Layer 1" untouched. Select
        // the actual text first, then prove the field is empty before checking
        // validation. Keep the original invalid-name assertion.
        input.press(forDuration: 1.1)
        let selectAll = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Select All")).firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5), "Layer name selection menu is unavailable")
        // XCTest treated the expected rename alert as an interruption when
        // tapping its text-selection menu and automatically pressed Cancel.
        // Anchor the tap to that alert, using the observed menu frame.
        let dialog = app.alerts.firstMatch
        let menuFrame = selectAll.frame, dialogFrame = dialog.frame
        XCTAssertGreaterThan(menuFrame.width, 0)
        XCTAssertGreaterThan(menuFrame.height, 0)
        dialog.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: menuFrame.midX - dialogFrame.minX,
                                 dy: menuFrame.midY - dialogFrame.minY)).tap()
        XCTAssertTrue(dialog.exists, "Selecting layer-name text dismissed its editor")
        input.typeText(XCUIKeyboardKey.delete.rawValue)
        let clearedValue = input.value as? String
        XCTAssertTrue(clearedValue == "" || clearedValue == input.placeholderValue,
                      "Layer name was not cleared before invalid-name validation")
        XCTAssertFalse(app.alerts.buttons["Save name"].isEnabled, "Empty name can be saved")
        input.typeText("Hero ink")
        capture(app, name: "layer-rename-draft")
        app.alerts.buttons["Save name"].tap()
        XCTAssertTrue(app.staticTexts["Hero ink"].waitForExistence(timeout: 5))
        app.buttons["studio.layers.close"].tap()
        try waitForStableCanvas(canvas, expected: frame)
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4, "Rename changed canvas pixels")
        app.buttons["studio.undo"].tap();try settlePickerCanvasAfterSave(app, canvas: canvas)
        showLayers();XCTAssertTrue(app.staticTexts["Layer 1"].waitForExistence(timeout: 5));app.buttons["studio.layers.close"].tap()
        app.buttons["studio.redo"].tap();try settlePickerCanvasAfterSave(app, canvas: canvas)
        showLayers();XCTAssertTrue(app.staticTexts["Hero ink"].waitForExistence(timeout: 5));capture(app, name: "layer-renamed-after-redo");app.buttons["studio.layers.close"].tap()
        app.buttons["studio.back"].tap();app.terminate()
        let reopened = try launchGuestStudio();defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8));project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(restored.screenshot().image)), 4, "Renamed layer pixels changed after cold reopen")
        reopened.buttons["studio.layers.open"].tap()
        XCTAssertTrue(reopened.staticTexts["Hero ink"].waitForExistence(timeout: 5))
        capture(reopened, name: "layer-name-cold-reopened")
    }

    @MainActor
    func testNativeLayerDragReordersPixelsUndoRedoAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let projectName = try createProjectIfLibraryIsShown(app)
        let prepared = try preparePickerSourceStroke(app), canvas = prepared.canvas
        try waitForStableCanvas(canvas)
        let canvasFrame = canvas.frame
        let blueOnly = try pixels(canvas.screenshot().image)
        func assertCenter(_ raster: Raster, blue: Bool, file: StaticString = #filePath, line: UInt = #line) {
            let offset = ((raster.height / 2) * raster.width + raster.width / 2) * 4
            XCTAssertGreaterThan(raster.bytes[offset + (blue ? 2 : 0)], 180, "Top layer did not color the real crossing", file: file, line: line)
            XCTAssertLessThan(raster.bytes[offset + (blue ? 0 : 2)], 90, "Lower layer incorrectly covered the crossing", file: file, line: line)
            XCTAssertLessThan(raster.bytes[offset + 1], 90, file: file, line: line)
        }
        assertCenter(blueOnly, blue: true)
        app.buttons["studio.layers.open"].tap()
        let addLayer = app.buttons["studio.add-layer"]
        XCTAssertTrue(addLayer.waitForExistence(timeout: 5) && addLayer.isHittable)
        addLayer.tap()
        XCTAssertTrue(app.staticTexts["Layer 2"].waitForExistence(timeout: 5))
        app.buttons["studio.layers.close"].tap()
        try choosePickerTestColor("#FF0000", app: app)
        try waitForStableCanvas(canvas, expected: canvasFrame)
        // Cross the existing blue horizontal stroke with a red vertical one.
        // Both colors remain visible, while their intersection proves z-order.
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)))
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let redOnTop = try pixels(canvas.screenshot().image)
        assertCenter(redOnTop, blue: false)
        XCTAssertGreaterThan(imageFixtureColors(redOnTop)[0], 12)
        XCTAssertGreaterThan(imageFixtureColors(redOnTop)[1], 12)
        XCTAssertGreaterThan(try changedPixelCount(blueOnly, redOnTop), 100, "Second layer did not acquire its actual red stroke")

        app.buttons["studio.layers.open"].tap()
        let first = app.staticTexts["Layer 1"].firstMatch
        let second = app.staticTexts["Layer 2"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5) && second.exists)
        XCTAssertTrue(first.isHittable && second.isHittable)
        XCTAssertGreaterThan(first.frame.midY, second.frame.midY, "New front layer was not above the original")
        let list = app.scrollViews["studio.layers.list"]
        let start = first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        // LayerRow is 36pt thumbnail + 8pt padding at each edge (52pt).
        // Its name is vertically centered. Drop 16pt above the target center,
        // inside its upper half: actual DropDelegate.info.location.y < 26.
        // This uses the production row onDrag/onDrop; no context action/model hook.
        let targetPoint = CGPoint(x: second.frame.midX, y: second.frame.midY - 16)
        XCTAssertTrue(list.frame.contains(targetPoint), "Reorder destination is outside the actual layer list")
        let target = second.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: 0, dy: -16))
        start.press(forDuration: 1.0, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.3)
        let reordered = NSPredicate { _, _ in
            first.exists && second.exists && first.frame.midY < second.frame.midY
        }
        let didReorder = expectation(for: reordered, evaluatedWith: nil).waitUntilFulfilled(timeout: 8)
        if !didReorder {
            capture(app, name: "layer-row-drag-failed")
            captureHierarchy(app, name: "layer-row-drag-failed-hierarchy")
        }
        XCTAssertTrue(didReorder, "Real row drop did not reorder the layer panel")
        guard didReorder else { throw NSError(domain: "NativeLayerReorder", code: 1) }
        capture(app, name: "layer-row-drag-real-order")
        app.buttons["studio.layers.close"].tap()
        try waitForStableCanvas(canvas, expected: canvasFrame)
        let blueOnTop = try pixels(canvas.screenshot().image)
        assertCenter(blueOnTop, blue: true)
        XCTAssertGreaterThan(try changedPixelCount(redOnTop, blueOnTop), 100, "Layer row moved without changing the actual composite")
        XCTAssertGreaterThan(imageFixtureColors(blueOnTop)[0], 12, "Reorder erased the red layer")
        capture(app, name: "layer-row-drag-blue-over-red")

        app.buttons["studio.undo"].tap()
        try waitForStableCanvas(canvas, expected: canvasFrame)
        XCTAssertLessThanOrEqual(try changedPixelCount(redOnTop, pixels(canvas.screenshot().image)), 4, "One Undo did not restore the exact original composite")
        XCTAssertTrue(app.buttons["studio.redo"].isEnabled)
        app.buttons["studio.redo"].tap()
        try waitForStableCanvas(canvas, expected: canvasFrame)
        XCTAssertLessThanOrEqual(try changedPixelCount(blueOnTop, pixels(canvas.screenshot().image)), 4, "Redo did not restore the exact reordered composite")
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio()
        defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: canvasFrame)
        let reopenedPixels = try pixels(restored.screenshot().image)
        assertCenter(reopenedPixels, blue: true)
        XCTAssertLessThanOrEqual(try changedPixelCount(blueOnTop, reopenedPixels), 4, "Reordered layers changed after actual save and cold reopen")
        capture(reopened, name: "layer-row-drag-cold-reopened")
        reopened.buttons["studio.layers.open"].tap()
        let restoredFirst = reopened.staticTexts["Layer 1"].firstMatch
        let restoredSecond = reopened.staticTexts["Layer 2"].firstMatch
        XCTAssertTrue(restoredFirst.waitForExistence(timeout: 5) && restoredSecond.exists)
        XCTAssertLessThan(restoredFirst.frame.midY, restoredSecond.frame.midY, "Persisted layer order was lost")
    }

    @MainActor
    func testLayerDeleteConfirmationUndoAndColdReopen() throws {
        let app=try launchGuestStudio()
        defer { app.terminate();XCUIDevice.shared.orientation = .portrait }
        let projectName=try createProjectIfLibraryIsShown(app)
        let canvas=app.descendants(matching:.any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let frame=canvas.frame,blank=try pixels(canvas.screenshot().image)
        func openLayer(_ name:String) throws -> XCUIElement {
            app.buttons["studio.layers.open"].tap()
            let row=app.staticTexts[name].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout:5));row.tap()
            let deletion=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","studio.layer.delete.")).firstMatch
            XCTAssertTrue(deletion.waitForExistence(timeout:5))
            let list=app.scrollViews["studio.layers.list"]
            for _ in 0..<3 where !deletion.isHittable { list.swipeUp() }
            return deletion
        }
        let last=try openLayer("Layer 1")
        XCTAssertFalse(last.isEnabled,"Last layer exposed an enabled delete action")
        app.buttons["studio.layers.close"].tap()
        app.buttons["studio.layers.open"].tap()
        app.buttons["studio.add-layer"].tap()
        app.buttons["studio.layers.close"].tap()
        let prepared=try preparePickerSourceStroke(app)
        try settlePickerCanvasAfterSave(app,canvas:canvas)
        let drawn=try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(blank,drawn),100)
        let deletion=try openLayer("Layer 2")
        XCTAssertTrue(expectation(for:NSPredicate(format:"enabled == true"),evaluatedWith:deletion).waitUntilFulfilled(timeout:8))
        deletion.tap()
        XCTAssertTrue(app.buttons["Delete layer"].waitForExistence(timeout:5))
        capture(app,name:"layer-delete-confirmation")
        app.buttons["Cancel"].tap()
        app.buttons["studio.layers.close"].tap()
        try waitForStableCanvas(canvas,expected:frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(drawn,pixels(canvas.screenshot().image)),4,"Cancel changed actual layer pixels")
        try openLayer("Layer 2").tap()
        app.buttons["Delete layer"].tap()
        XCTAssertFalse(app.staticTexts["Layer 2"].exists)
        app.buttons["studio.layers.close"].tap()
        try waitForStableCanvas(canvas,expected:frame)
        try settlePickerCanvasAfterSave(app,canvas:canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(blank,pixels(canvas.screenshot().image)),4,"Confirmed layer delete left drawn pixels")
        app.buttons["studio.undo"].tap();try settlePickerCanvasAfterSave(app,canvas:canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(drawn,pixels(canvas.screenshot().image)),4,"One Undo did not restore deleted layer pixels")
        capture(app,name:"layer-delete-undone")
        app.buttons["studio.redo"].tap();try settlePickerCanvasAfterSave(app,canvas:canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(blank,pixels(canvas.screenshot().image)),4)
        app.buttons["studio.back"].tap();app.terminate()
        let reopened=try launchGuestStudio();defer { reopened.terminate() }
        let project=reopened.buttons.matching(NSPredicate(format:"label == %@",projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout:8));project.tap()
        let restored=reopened.descendants(matching:.any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored,expected:frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(blank,pixels(restored.screenshot().image)),4,"Deleted layer returned after cold reopen")
        capture(reopened,name:"layer-delete-cold-reopened")
        _ = prepared
    }

    @MainActor
    func testRoomsReplaceMessagingWithoutClaimingConnectedServices() throws {
        let app = try launchGuestStudio()
        defer { app.terminate() }
        XCTAssertFalse(button("Messages", in: app).exists)
        try waitForButton("Rooms", in: app).tap()
        XCTAssertTrue(app.descendants(matching: .any)["rooms.unavailable"].firstMatch.waitForExistence(timeout: 5))
        let warRoom = app.descendants(matching: .any)["rooms.warRoom"].firstMatch
        XCTAssertTrue(warRoom.isHittable)
        warRoom.tap()
        XCTAssertTrue(app.descendants(matching: .any)["warRoom.unavailable"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(button("Find Match", in: app).exists)
        try waitForButton("Back to Rooms", in: app).tap()
        XCTAssertTrue(app.descendants(matching: .any)["rooms.unavailable"].firstMatch.exists)
        try waitForButton("Studio", in: app).tap()
        XCTAssertTrue(app.buttons["studio.new-project"].waitForExistence(timeout: 5))
        capture(app, name: "rooms-back-to-studio")
    }

    @MainActor
    func testFloatingToolbarDockingAndPopupDismissal() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        _ = try createProjectIfLibraryIsShown(app)
        let stage = app.descendants(matching: .any)["studio.toolbar.stage"].firstMatch
        let rail = app.descendants(matching: .any)["studio.toolbar"].firstMatch
        let grip = app.descendants(matching: .any)["studio.toolbar.grip"].firstMatch
        XCTAssertTrue(stage.waitForExistence(timeout: 8) && rail.exists && grip.isHittable)
        let undo = app.buttons["studio.undo"]
        XCTAssertFalse(undo.isEnabled, "Chrome gestures must not edit the blank document")
        for (x, side) in [(0.025, "left"), (0.975, "right")] {
            grip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.2, thenDragTo: stage.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.35)))
            let docked = NSPredicate { _, _ in
                guard rail.value as? String == "Vertical", grip.isHittable,
                      stage.frame.contains(rail.frame), rail.frame.height > rail.frame.width else { return false }
                return side == "left" ? rail.frame.minX < stage.frame.minX + 20 : rail.frame.maxX > stage.frame.maxX - 20
            }
            XCTAssertTrue(expectation(for: docked, evaluatedWith: nil).waitUntilFulfilled(timeout: 5), "Toolbar did not dock at \(side) stage edge")
            capture(app, name: "toolbar-docked-" + side)
        }
        try selectToolbarTool("hand", app: app)
        let close = app.buttons["studio.tool-settings.close"]
        if !close.isHittable { captureHierarchy(app, name: "toolbar-popup-close-unreachable") }
        XCTAssertTrue(close.isHittable && app.buttons["studio.tool-settings.fit"].isHittable)
        XCTAssertGreaterThanOrEqual(close.frame.width.rounded(), 44)
        XCTAssertGreaterThanOrEqual(close.frame.height.rounded(), 44)
        close.tap()
        XCTAssertFalse(close.exists, "X did not dismiss tool-specific controls")
        try selectToolbarTool("hand", app: app)
        XCTAssertTrue(close.waitForExistence(timeout: 3), "Retapping Hand did not restore its context")
        try selectToolbarTool("eyedropper", app: app)
        XCTAssertFalse(close.exists, "An inapplicable tool kept the settings popup")
        XCTAssertFalse(app.buttons["studio.context.close"].exists, "The removed secondary toolbar returned")
        grip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.2, thenDragTo: stage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
        XCTAssertTrue(expectation(for: NSPredicate(format: "value == %@", "Horizontal"), evaluatedWith: rail).waitUntilFulfilled(timeout: 5))
        XCTAssertTrue(stage.frame.contains(rail.frame))
        XCTAssertFalse(undo.isEnabled, "Toolbar movement altered undo history")
        try selectToolbarTool("hand", app: app)
        app.buttons["studio.tool-settings.zoom-in"].tap()
        app.buttons["studio.tool-settings.fit"].tap()
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        XCTAssertGreaterThan(canvas.frame.width, 80)
        XCTAssertGreaterThan(canvas.frame.height, 80)
        let popup = app.descendants(matching: .any)["studio.tool-settings"].firstMatch
        let fitted = NSPredicate { _, _ in
            popup.exists && popup.frame.height > 80 && popup.frame.height <= 220
                && stage.frame.contains(popup.frame) && !popup.frame.intersects(rail.frame)
        }
        XCTAssertTrue(expectation(for: fitted, evaluatedWith: nil).waitUntilFulfilled(timeout: 5),
                      "Short Hand controls should fit the popup without a large empty viewport")
        if popup.frame.maxY <= rail.frame.minY {
            XCTAssertLessThanOrEqual(rail.frame.minY - popup.frame.maxY, 14,
                                     "A popup above the rail must remain adjacent to it")
        } else {
            XCTAssertLessThanOrEqual(popup.frame.minY - rail.frame.maxY, 14,
                                     "A popup below the rail must remain adjacent to it")
        }
        capture(app, name: "toolbar-floating-popup")
    }

    @MainActor
    private func waitForStableCanvas(_ canvas: XCUIElement, expected: CGRect? = nil) throws {
        var last = CGRect.null
        var since = Date()
        let settled = NSPredicate { _, _ in
            let frame = canvas.frame
            // Sample geometry once per poll. Existence and hittability each
            // initiate another accessibility query; on a cold simulator those
            // queries can consume the whole wait after the frame is stable.
            guard frame.width > 80, frame.height > 80,
                  expected == nil || frame == expected else { since = Date(); return false }
            if last != frame { last = frame; since = Date(); return false }
            return Date().timeIntervalSince(since) >= 1
        }
        let geometrySettled = expectation(for: settled, evaluatedWith: nil).waitUntilFulfilled(timeout: 8)
        if !geometrySettled {
            let evidence = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            evidence.name = "canvas-geometry-wait-failed"
            evidence.lifetime = .keepAlways
            add(evidence)
        }
        XCTAssertTrue(geometrySettled, "The real canvas did not settle at its expected geometry")
        // Keep both interaction assertions, once, after observing unchanged
        // geometry for a full second. No retry, sleep or larger test timeout.
        XCTAssertTrue(canvas.exists, "The settled canvas disappeared")
        XCTAssertTrue(canvas.isHittable, "The settled canvas is not reachable")
    }

    @MainActor
    private func selectToolbarTool(_ name: String, app: XCUIApplication) throws {
        // Run 37261534983 tapped Text after two fast flicks but never opened
        // its popup. Use the same bounded, fully-contained slow drag/hold
        // path as the drawing tests so the tap does not land during inertia.
        try pickerRailControl("studio.tool." + name, app: app, forward: true).tap()
    }

    @MainActor
    func testGuestStudioPortraitLandscapeAndPersistedGuideControls() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let projectName = try createProjectIfLibraryIsShown(app)
        // FIT now belongs to the selected Hand/Zoom tool, as requested.
        try selectToolbarTool("hand", app: app)
        try waitForButton("FIT", in: app)
        capture(app, name: "studio-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = NSPredicate { _, _ in app.frame.width > app.frame.height }
        XCTAssertTrue(expectation(for: landscape, evaluatedWith: nil).waitUntilFulfilled(timeout: 8))
        XCTAssertTrue(button("FIT", in: app).isHittable, "Landscape fit control is inaccessible")
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5), "The actual rendered canvas needs its accessibility identifier")
        XCTAssertGreaterThan(canvas.frame.width, 80, "Landscape canvas collapsed")
        XCTAssertGreaterThan(canvas.frame.height, 80, "Landscape canvas collapsed")
        // The window reports landscape before the display rotation completes.
        // Require settled, visible geometry before recording full-screen proof.
        var previousFrame = CGRect.null
        var stableSince = Date()
        let settled = NSPredicate { _, _ in
            let frame = canvas.frame
            guard app.frame.width > app.frame.height, app.frame.contains(frame),
                  canvas.isHittable, frame.width > 80, frame.height > 80 else {
                previousFrame = .null; stableSince = Date(); return false
            }
            if frame != previousFrame { previousFrame = frame; stableSince = Date(); return false }
            return Date().timeIntervalSince(stableSince) >= 1
        }
        XCTAssertTrue(expectation(for: settled, evaluatedWith: nil).waitUntilFulfilled(timeout: 8),
                      "Landscape canvas geometry did not settle within the visible app")
        let popup = app.descendants(matching: .any)["studio.tool-settings"].firstMatch
        XCTAssertTrue(popup.exists && app.buttons["studio.tool-settings.close"].isHittable)
        XCTAssertFalse(popup.frame.intersects(canvas.frame), "Docked Hand popup covers the fitted portrait canvas in landscape")
        let landscapeCapture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        landscapeCapture.name = "studio-landscape"
        landscapeCapture.lifetime = .keepAlways
        add(landscapeCapture)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(expectation(for: NSPredicate { _, _ in app.frame.height > app.frame.width }, evaluatedWith: nil).waitUntilFulfilled(timeout: 8))
        app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(canvas)
        func menuControl(_ id: String, in target: XCUIApplication) throws -> XCUIElement {
            let control = target.descendants(matching: .any)[id].firstMatch
            for _ in 0..<5 {
                if control.exists && control.isHittable { return control }
                target.scrollViews["studio.menu.scroll"].swipeUp(velocity: .slow)
            }
            XCTFail("Guide control inaccessible: \(id)"); throw NSError(domain: "GuideControls", code: 1)
        }
        func closeMenu(_ target: XCUIApplication) throws {
            let close = target.buttons["studio.menu.close"]
            for _ in 0..<5 { if close.isHittable { break }; target.scrollViews["studio.menu.scroll"].swipeDown(velocity: .slow) }
            XCTAssertTrue(close.isHittable); close.tap()
        }
        app.buttons["studio.menu.open"].tap()
        try menuControl("studio.menu.edit.onion", in: app).tap()
        let previous = app.steppers["studio.onion.previous"]
        XCTAssertTrue(previous.waitForExistence(timeout: 5))
        previous.buttons["studio.onion.previous-Increment"].tap()
        app.steppers["studio.onion.next"].buttons["studio.onion.next-Increment"].tap()
        let tint = app.switches["studio.onion.tint"]
        try menuControl("studio.onion.tint", in: app).tap()
        XCTAssertEqual(tint.value as? String, "1")
        XCTAssertTrue(previous.label.contains("2") || app.staticTexts["Previous: 2"].exists)
        capture(app, name: "onion-range-tint-controls")
        try menuControl("studio.menu.edit.onion", in: app).tap()
        try menuControl("studio.menu.edit.grid", in: app).tap()
        let spacing = app.sliders["studio.grid.spacing"]
        XCTAssertTrue(spacing.waitForExistence(timeout: 5)); spacing.adjust(toNormalizedSliderPosition: 0.65)
        let opacity = app.sliders["studio.grid.opacity"]
        opacity.adjust(toNormalizedSliderPosition: 0.5)
        app.segmentedControls["studio.grid.tint"].buttons["Red"].tap()
        let savedSpacing = spacing.value as? String, savedOpacity = opacity.value as? String
        XCTAssertNotNil(savedSpacing); XCTAssertNotNil(savedOpacity)
        capture(app, name: "grid-spacing-opacity-tint-controls")
        try closeMenu(app)
        let save = app.buttons["studio.save"]; save.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "Saved"), evaluatedWith: save).waitUntilFulfilled(timeout: 8))
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        try waitForStableCanvas(reopened.descendants(matching: .any)["studio.canvas"].firstMatch)
        reopened.buttons["studio.menu.open"].tap()
        try menuControl("studio.menu.edit.onion", in: reopened).tap()
        XCTAssertEqual(reopened.switches["studio.onion.tint"].value as? String, "1")
        XCTAssertTrue(reopened.steppers["studio.onion.previous"].label.contains("2") || reopened.staticTexts["Previous: 2"].exists)
        try menuControl("studio.menu.edit.onion", in: reopened).tap()
        try menuControl("studio.menu.edit.grid", in: reopened).tap()
        XCTAssertEqual(reopened.sliders["studio.grid.spacing"].value as? String, savedSpacing)
        XCTAssertEqual(reopened.sliders["studio.grid.opacity"].value as? String, savedOpacity)
        XCTAssertTrue(reopened.segmentedControls["studio.grid.tint"].buttons["Red"].isSelected)
        capture(reopened, name: "guide-settings-cold-reopened")
        try closeMenu(reopened)
    }

    @MainActor
    func testMoveArtworkUndoAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let name = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let frame = canvas.frame
        canvas.coordinate(withNormalizedOffset: CGVector(dx:0.20,dy:0.4)).press(forDuration:0.05,
            thenDragTo:canvas.coordinate(withNormalizedOffset:CGVector(dx:0.45,dy:0.4)))
        let original = try pixels(canvas.screenshot().image), originalInk = exportInkMask(original)
        XCTAssertGreaterThan(originalInk.count,12)
        try selectToolbarTool("move",app:app)
        let close = app.buttons["studio.tool-settings.close"]
        XCTAssertTrue(close.waitForExistence(timeout:3));close.tap()
        try waitForStableCanvas(canvas,expected:frame)
        canvas.coordinate(withNormalizedOffset:CGVector(dx:0.30,dy:0.4)).press(forDuration:0.1,
            thenDragTo:canvas.coordinate(withNormalizedOffset:CGVector(dx:0.30,dy:0.6)))
        // Empty canvas tap clears the transient selection outline without editing.
        canvas.coordinate(withNormalizedOffset:CGVector(dx:0.85,dy:0.8)).tap()
        try waitForStableCanvas(canvas,expected:frame)
        XCTAssertFalse(app.staticTexts["studio.status"].exists,"Empty deselection inserted a resizing status banner")
        let moved = try pixels(canvas.screenshot().image), movedInk = exportInkMask(moved)
        XCTAssertGreaterThan(movedInk.count,12)
        XCTAssertLessThan(originalInk.intersection(movedInk).count,max(4,originalInk.count/10),"Move retained artwork at its old position")
        XCTAssertGreaterThan(Double(movedInk.count)/Double(originalInk.count),0.75)
        XCTAssertLessThan(Double(movedInk.count)/Double(originalInk.count),1.25)
        capture(app,name:"move-artwork-committed")
        let undo = identifiedButton("studio.undo",fallback:"UNDO",app:app)
        let redo = identifiedButton("studio.redo",fallback:"REDO",app:app)
        undo.tap()
        XCTAssertLessThanOrEqual(try changedPixelCount(original,pixels(canvas.screenshot().image)),4,"Move Undo did not restore original artwork")
        redo.tap()
        XCTAssertLessThanOrEqual(try changedPixelCount(moved,pixels(canvas.screenshot().image)),4,"Move Redo changed artwork")
        let save=app.buttons["studio.save"];save.tap()
        XCTAssertTrue(expectation(for:NSPredicate(format:"label == %@","Saved"),evaluatedWith:save).waitUntilFulfilled(timeout:8))
        app.buttons["studio.back"].tap();app.terminate()
        let reopened=try launchGuestStudio();defer { reopened.terminate() }
        let project=reopened.buttons.matching(NSPredicate(format:"label == %@",name)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout:8));project.tap()
        let reopenedCanvas=reopened.descendants(matching:.any)["studio.canvas"].firstMatch
        try waitForStableCanvas(reopenedCanvas,expected:frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(moved,pixels(reopenedCanvas.screenshot().image)),4,"Moved artwork did not survive cold reopen")
        capture(reopened,name:"move-artwork-cold-reopened")
    }

    @MainActor
    func testSelectedArtworkCopyPasteUndoAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let name = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching:.any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let frame = canvas.frame
        try pickerRailControl("studio.tool.pencil", app:app, forward:false).tap()
        app.buttons["studio.tool-settings.close"].tap()
        canvas.coordinate(withNormalizedOffset:CGVector(dx:0.25,dy:0.25)).press(forDuration:0.05,
            thenDragTo:canvas.coordinate(withNormalizedOffset:CGVector(dx:0.25,dy:0.6)))
        try settlePickerCanvasAfterSave(app,canvas:canvas)
        let original = try pixels(canvas.screenshot().image), originalInk = exportInkMask(original)
        XCTAssertGreaterThan(originalInk.count,12)
        try selectToolbarTool("move",app:app)
        XCTAssertTrue(app.buttons["studio.selection.copy"].waitForExistence(timeout:5))
        XCTAssertFalse(app.buttons["studio.selection.copy"].isEnabled,"Copy requires explicit selection")
        XCTAssertFalse(app.buttons["studio.selection.cut"].isEnabled, "Cut requires explicit selection")
        app.buttons["studio.tool-settings.close"].tap()
        canvas.coordinate(withNormalizedOffset:CGVector(dx:0.25,dy:0.4)).tap()
        try selectToolbarTool("move",app:app)
        let copy = app.buttons["studio.selection.copy"]
        let selectionLock = app.buttons["studio.selection.lock-layers"]
        XCTAssertTrue(selectionLock.waitForExistence(timeout: 5))
        XCTAssertTrue(selectionLock.isEnabled, "Explicit selection must enable the implemented whole-layer lock action")
        XCTAssertTrue(app.staticTexts["studio.selection.lock-scope"].exists, "Whole-layer scope must be disclosed")
        XCTAssertTrue(copy.isHittable && copy.isEnabled); copy.tap()
        app.buttons["studio.tool-settings.close"].tap()
        XCTAssertEqual(app.buttons["studio.save"].label,"Saved","Copy must not dirty the saved document")
        let paste = app.buttons["studio.paste"]
        XCTAssertTrue(paste.isEnabled && paste.isHittable)
        XCTAssertEqual(paste.label,"Paste drawing")
        paste.tap()
        canvas.coordinate(withNormalizedOffset:CGVector(dx:0.25,dy:0.4)).press(forDuration:0.05,
            thenDragTo:canvas.coordinate(withNormalizedOffset:CGVector(dx:0.65,dy:0.4)))
        canvas.coordinate(withNormalizedOffset:CGVector(dx:0.9,dy:0.85)).tap()
        try waitForStableCanvas(canvas,expected:frame)
        XCTAssertFalse(app.descendants(matching:.any)["studio.status"].firstMatch.exists,"Copy or Paste inserted a resizing success banner")
        let duplicated = try pixels(canvas.screenshot().image), duplicatedInk = exportInkMask(duplicated)
        XCTAssertGreaterThan(Double(duplicatedInk.count)/Double(originalInk.count),1.75,"Paste failed to retain both original and copied artwork in one frame")
        XCTAssertLessThan(Double(duplicatedInk.count)/Double(originalInk.count),2.25)
        XCTAssertGreaterThanOrEqual(originalInk.intersection(duplicatedInk).count,originalInk.count-4,"Moving the pasted selection moved or removed the original")
        capture(app,name:"selected-artwork-copy-paste-moved")
        app.buttons["studio.undo"].tap();app.buttons["studio.undo"].tap()
        XCTAssertLessThanOrEqual(try changedPixelCount(original,pixels(canvas.screenshot().image)),4,"Undo Move and Paste did not restore the exact original")
        app.buttons["studio.redo"].tap();app.buttons["studio.redo"].tap()
        XCTAssertLessThanOrEqual(try changedPixelCount(duplicated,pixels(canvas.screenshot().image)),4,"Redo changed the actual copied artwork")
        try settlePickerCanvasAfterSave(app,canvas:canvas)
        // Cut the visibly moved copy, leaving its original untouched. The same
        // project-local drawing clipboard must restore it without adding a frame.
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.4)).tap()
        try selectToolbarTool("move", app: app)
        let cut = app.buttons["studio.selection.cut"]
        XCTAssertTrue(cut.waitForExistence(timeout: 5) && cut.isHittable && cut.isEnabled)
        cut.tap()
        app.buttons["studio.tool-settings.close"].tap()
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4,
            "Cut removed the wrong drawing or left selected artwork behind")
        XCTAssertTrue(paste.isEnabled)
        XCTAssertEqual(paste.label, "Paste drawing", "Cut replaced drawing clipboard with frame scope")
        app.buttons["studio.undo"].tap()
        XCTAssertLessThanOrEqual(try changedPixelCount(duplicated, pixels(canvas.screenshot().image)), 4,
            "One Undo did not restore both original and cut drawing")
        app.buttons["studio.redo"].tap()
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4,
            "Cut Redo removed the original or changed retained pixels")
        paste.tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.85)).tap()
        try waitForStableCanvas(canvas, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(duplicated, pixels(canvas.screenshot().image)), 4,
            "Pasting the cut drawing did not restore the actual moved artwork")
        capture(app, name: "selected-artwork-cut-undo-redo-paste-restored")
        try settlePickerCanvasAfterSave(app,canvas:canvas)
        app.buttons["studio.back"].tap();app.terminate()
        let reopened = try launchGuestStudio();defer {reopened.terminate()}
        let project = reopened.buttons.matching(NSPredicate(format:"label == %@",name)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout:8));project.tap()
        let restoredCanvas = reopened.descendants(matching:.any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restoredCanvas,expected:frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(duplicated,pixels(restoredCanvas.screenshot().image)),4,"Saved original and copied artwork did not survive cold reopen")
        XCTAssertFalse(reopened.buttons["studio.paste"].isEnabled,"Transient clipboard was incorrectly persisted")
        capture(reopened,name:"selected-artwork-cold-reopened")
    }

    @MainActor
    func testToolPreferencesSwitchDrawAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let name = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let frame = canvas.frame
        try pickerRailControl("studio.tool.pencil", app: app, forward: false).tap()
        let size = app.sliders["studio.setting.size"]
        let opacity = app.sliders["studio.setting.opacity"]
        XCTAssertTrue(size.waitForExistence(timeout: 5) && size.isHittable && opacity.isHittable)
        size.adjust(toNormalizedSliderPosition: 0.28)
        opacity.adjust(toNormalizedSliderPosition: 0.8)
        let pencilSize = try XCTUnwrap(size.value as? String)
        let pencilOpacity = try XCTUnwrap(opacity.value as? String)
        app.buttons["studio.tool-settings.close"].tap()
        XCTAssertFalse(app.buttons["studio.undo"].isEnabled, "Tool preferences changed document history")

        try pickerRailControl("studio.tool.pen", app: app, forward: true).tap()
        XCTAssertTrue(size.waitForExistence(timeout: 5) && size.isHittable)
        size.adjust(toNormalizedSliderPosition: 0.75)
        opacity.adjust(toNormalizedSliderPosition: 0.35)
        let penSize = try XCTUnwrap(size.value as? String)
        XCTAssertNotEqual(penSize, pencilSize)
        app.buttons["studio.tool-settings.close"].tap()
        try pickerRailControl("studio.tool.pencil", app: app, forward: false).tap()
        XCTAssertEqual(size.value as? String, pencilSize, "Switching tools lost pencil size")
        XCTAssertEqual(opacity.value as? String, pencilOpacity, "Switching tools lost pencil opacity")
        capture(app, name: "independent-pencil-settings-restored")
        app.buttons["studio.tool-settings.close"].tap()

        try waitForStableCanvas(canvas, expected: frame)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.55)).press(forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.55)))
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let artwork = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(exportInkMask(artwork).count, 30, "Restored settings did not draw real artwork")
        app.buttons["studio.back"].tap(); app.terminate()

        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(artwork, pixels(restored.screenshot().image)), 4,
                                "Preference cold reopen changed actual artwork")
        try pickerRailControl("studio.tool.pencil", app: reopened, forward: false).tap()
        XCTAssertEqual(reopened.sliders["studio.setting.size"].value as? String, pencilSize,
                       "Pencil preferences did not survive actual app termination")
        XCTAssertEqual(reopened.sliders["studio.setting.opacity"].value as? String, pencilOpacity)
        capture(reopened, name: "independent-tool-settings-cold-reopened")
        try resetToolPreferencesInPopup(reopened)
        XCTAssertNotEqual(try XCTUnwrap(reopened.sliders["studio.setting.size"].value as? String), pencilSize)
        reopened.buttons["studio.tool-settings.close"].tap()
        try pickerRailControl("studio.tool.pen", app: reopened, forward: true).tap()
        XCTAssertEqual(reopened.sliders["studio.setting.size"].value as? String, penSize,
                       "Resetting pencil also reset pen")
        try resetToolPreferencesInPopup(reopened)
        reopened.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(restored, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(artwork, pixels(restored.screenshot().image)), 4,
                                "Resetting tool preferences rewrote existing artwork")
        XCTAssertFalse(reopened.buttons["studio.undo"].isEnabled, "Preference reset inserted document history")

    }

    @MainActor
    func testFillPreferencesSwitchDrawResetAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let name = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let frame = canvas.frame
        try pickerRailControl("studio.tool.pencil", app: app, forward: false).tap()
        let size = app.sliders["studio.setting.size"]
        let opacity = app.sliders["studio.setting.opacity"]
        XCTAssertTrue(size.waitForExistence(timeout: 5) && size.isHittable && opacity.isHittable)
        size.adjust(toNormalizedSliderPosition: 0.28)
        opacity.adjust(toNormalizedSliderPosition: 0.8)
        let pencilSize = try XCTUnwrap(app.sliders["studio.setting.size"].value as? String)
        let pencilOpacity = try XCTUnwrap(app.sliders["studio.setting.opacity"].value as? String)
        app.buttons["studio.tool-settings.close"].tap()
        // Configure real Fill controls independently from remembered Pencil settings.
        try pickerRailControl("studio.tool.fill", app: app, forward: true).tap()
        try resetToolPreferencesInPopup(app)
        let fillSliderIDs = ["studio.setting.tolerance", "studio.setting.expand", "studio.setting.gap-close"]
        let fillPositions: [CGFloat] = [0.72, 0.85, 0.65]
        var fillDefaults: [String] = [], fillRemembered: [String] = []
        for (index, id) in fillSliderIDs.enumerated() {
            let slider = try fillPreferenceControl(id, app: app)
            fillDefaults.append(try XCTUnwrap(slider.value as? String))
            slider.adjust(toNormalizedSliderPosition: fillPositions[index])
            fillRemembered.append(try XCTUnwrap(slider.value as? String))
            XCTAssertNotEqual(fillRemembered[index], fillDefaults[index])
        }
        let fillToggleIDs = ["studio.fill.contiguous", "studio.fill.antialias", "studio.fill.sample-all"]
        var fillDefaultLabels: [String] = [], fillRememberedLabels: [String] = []
        for id in fillToggleIDs {
            let toggle = try fillPreferenceControl(id, app: app)
            fillDefaultLabels.append(toggle.label)
            toggle.tap()
            fillRememberedLabels.append(toggle.label)
            XCTAssertNotEqual(fillRememberedLabels.last, fillDefaultLabels.last)
        }
        XCTAssertFalse(app.sliders["studio.setting.gap-close"].isEnabled,
                       "All Similar must retain but disable the gap setting")
        capture(app, name: "fill-independent-settings-configured")
        app.buttons["studio.tool-settings.close"].tap()
        XCTAssertFalse(app.buttons["studio.undo"].isEnabled, "Fill preferences changed history")
        try pickerRailControl("studio.tool.pencil", app: app, forward: false).tap()
        XCTAssertEqual(app.sliders["studio.setting.size"].value as? String, pencilSize)
        XCTAssertEqual(app.sliders["studio.setting.opacity"].value as? String, pencilOpacity)
        app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(canvas, expected: frame)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.55)).press(forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.55)))
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let artwork = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(exportInkMask(artwork).count, 30, "Restored settings did not draw real artwork")
        app.buttons["studio.back"].tap(); app.terminate()

        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(artwork, pixels(restored.screenshot().image)), 4,
                                "Preference cold reopen changed actual artwork")
        // Reset another tool before reading remembered Fill values: a
        // mistakenly global Reset must not pass the separated journeys.
        try pickerRailControl("studio.tool.pencil", app: reopened, forward: false).tap()
        try resetToolPreferencesInPopup(reopened)
        XCTAssertNotEqual(reopened.sliders["studio.setting.size"].value as? String, pencilSize,
                          "The independent Pencil Reset did not actually run")
        reopened.buttons["studio.tool-settings.close"].tap()
        try pickerRailControl("studio.tool.fill", app: reopened, forward: false).tap()
        for (index, id) in fillSliderIDs.enumerated() {
            let slider = reopened.sliders[id]
            XCTAssertTrue(slider.exists)
            XCTAssertEqual(slider.value as? String, fillRemembered[index], "Cold launch lost Fill setting: " + id)
        }
        for (index, id) in fillToggleIDs.enumerated() {
            let toggle = try fillPreferenceControl(id, app: reopened)
            XCTAssertEqual(toggle.label, fillRememberedLabels[index], "Cold launch lost Fill toggle: " + id)
        }
        XCTAssertFalse(reopened.sliders["studio.setting.gap-close"].isEnabled)
        capture(reopened, name: "fill-independent-settings-cold-reopened")
        try resetToolPreferencesInPopup(reopened)
        for (index, id) in fillSliderIDs.enumerated() {
            XCTAssertEqual(reopened.sliders[id].value as? String, fillDefaults[index], "Fill Reset lost default: " + id)
        }
        for (index, id) in fillToggleIDs.enumerated() {
            XCTAssertEqual(reopened.buttons[id].label, fillDefaultLabels[index], "Fill Reset lost toggle default: " + id)
        }
        XCTAssertTrue(reopened.sliders["studio.setting.gap-close"].isEnabled)
        capture(reopened, name: "fill-independent-settings-reset")
        reopened.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(restored, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(artwork, pixels(restored.screenshot().image)), 4,
                                "Fill Reset rewrote existing artwork")
        XCTAssertFalse(reopened.buttons["studio.undo"].isEnabled, "Fill Reset inserted document history")
    }

    @MainActor
    func testSmudgePixelsUndoAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let name = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let frame = canvas.frame
        try pickerRailControl("studio.tool.pencil", app: app, forward: false).tap()
        app.sliders["studio.setting.size"].adjust(toNormalizedSliderPosition: 0.85)
        app.sliders["studio.setting.opacity"].adjust(toNormalizedSliderPosition: 1)
        app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(canvas, expected: frame)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.15,dy: 0.5)).press(forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.85,dy: 0.5)))
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let original = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(exportInkMask(original).count, 60)
        try pickerRailControl("studio.tool.pencil", app: app, forward: false).tap()
        try resetToolPreferencesInPopup(app)
        app.buttons["studio.tool-settings.close"].tap()
        try pickerRailControl("studio.tool.smudge", app: app, forward: true).tap()
        XCTAssertTrue(app.staticTexts["studio.smudge.instructions"].waitForExistence(timeout: 5))
        app.sliders["studio.setting.size"].adjust(toNormalizedSliderPosition: 0.45)
        app.sliders["studio.setting.opacity"].adjust(toNormalizedSliderPosition: 1)
        let savedSize = try XCTUnwrap(app.sliders["studio.setting.size"].value as? String)
        capture(app, name: "smudge-size-opacity-popup")
        app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(canvas, expected: frame)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5,dy: 0.5)).press(forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5,dy: 0.7)))
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let smudged = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(original, smudged), 30, "Smudge did not move actual artwork pixels")
        capture(app, name: "smudge-real-canvas-pixels")
        app.buttons["studio.undo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4)
        app.buttons["studio.redo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(smudged, pixels(canvas.screenshot().image)), 4)
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(smudged, pixels(restored.screenshot().image)), 4,
            "Cold reopen changed smudged artwork")
        capture(reopened, name: "smudge-cold-reopened")
        try pickerRailControl("studio.tool.smudge", app: reopened, forward: true).tap()
        XCTAssertEqual(reopened.sliders["studio.setting.size"].value as? String, savedSize)
        try resetToolPreferencesInPopup(reopened)
        reopened.buttons["studio.tool-settings.close"].tap()
    }

    @MainActor
    func testBlurPixelsUndoAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let name = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let frame = canvas.frame
        try pickerRailControl("studio.tool.pencil", app: app, forward: false).tap()
        app.sliders["studio.setting.size"].adjust(toNormalizedSliderPosition: 0.85)
        app.sliders["studio.setting.opacity"].adjust(toNormalizedSliderPosition: 1)
        app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(canvas, expected: frame)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.15,dy: 0.5)).press(forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.85,dy: 0.5)))
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let original = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(exportInkMask(original).count, 60)
        try pickerRailControl("studio.tool.pencil", app: app, forward: false).tap()
        try resetToolPreferencesInPopup(app)
        app.buttons["studio.tool-settings.close"].tap()
        try pickerRailControl("studio.tool.blur", app: app, forward: true).tap()
        XCTAssertTrue(app.staticTexts["studio.blur.instructions"].waitForExistence(timeout: 5))
        app.sliders["studio.setting.size"].adjust(toNormalizedSliderPosition: 0.45)
        app.sliders["studio.setting.strength"].adjust(toNormalizedSliderPosition: 1)
        app.sliders["studio.setting.hardness"].adjust(toNormalizedSliderPosition: 0.8)
        app.sliders["studio.setting.radius"].adjust(toNormalizedSliderPosition: 0.35)
        capture(app, name: "blur-size-opacity-popup")
        app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(canvas, expected: frame)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5,dy: 0.5)).press(forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5,dy: 0.7)))
        // The CI trace tapped Save while the real detached blur still showed
        // Cancel/Drawing. Await operation completion before saving its result.
        let blurProgress = app.descendants(matching: .any).matching(identifier: "studio.blur.progress")
        let blurFinished = NSPredicate { _, _ in
            blurProgress.count == 0 && app.buttons["studio.undo"].isEnabled
        }
        let completed = expectation(for: blurFinished, evaluatedWith: nil).waitUntilFulfilled(timeout: 30)
        if !completed { captureHierarchy(app, name: "blur-operation-completion-timeout") }
        XCTAssertTrue(completed, "Actual Blur did not complete before save")
        guard completed else { throw NSError(domain: "NativeBlurCompletion", code: 1) }
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let blurd = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(original, blurd), 30, "Blur did not soften actual artwork pixels")
        capture(app, name: "blur-real-canvas-pixels")
        app.buttons["studio.undo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4)
        app.buttons["studio.redo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(blurd, pixels(canvas.screenshot().image)), 4)
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(blurd, pixels(restored.screenshot().image)), 4,
            "Cold reopen changed blurd artwork")
        capture(reopened, name: "blur-cold-reopened")
    }

    @MainActor
    func testBlurSettingsPersistAndReset() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let name = try createProjectIfLibraryIsShown(app)
        try pickerRailControl("studio.tool.blur", app: app, forward: true).tap()
        XCTAssertTrue(app.staticTexts["studio.blur.instructions"].waitForExistence(timeout: 5))
        try resetToolPreferencesInPopup(app)
        let adjustments: [(String, CGFloat)] = [("size", 0.45), ("strength", 1), ("hardness", 0.8), ("radius", 0.35)]
        var defaults: [String: String] = [:]
        var saved: [String: String] = [:]
        for (key, value) in adjustments {
            let slider = try sharpenSetting(key, in: app)
            defaults[key] = try XCTUnwrap(slider.value as? String)
            slider.adjust(toNormalizedSliderPosition: value)
            saved[key] = try XCTUnwrap(slider.value as? String)
        }
        app.buttons["studio.tool-settings.close"].tap()
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        try pickerRailControl("studio.tool.blur", app: reopened, forward: true).tap()
        for (key, _) in adjustments {
            XCTAssertEqual(try sharpenSetting(key, in: reopened).value as? String, saved[key], "Cold reopen changed Blur " + key)
        }
        capture(reopened, name: "blur-four-settings-cold-reopened")
        try resetToolPreferencesInPopup(reopened)
        for (key, _) in adjustments {
            XCTAssertEqual(try sharpenSetting(key, in: reopened).value as? String, defaults[key], "Reset did not restore Blur " + key)
        }
        reopened.buttons["studio.tool-settings.close"].tap()
    }

    @MainActor
    private func sharpenSetting(_ name: String, in target: XCUIApplication) throws -> XCUIElement {
        let slider = target.sliders["studio.setting." + name]
        let scroll = target.scrollViews.containing(.button, identifier: "studio.tool-settings.reset").firstMatch
        for attempt in 0...5 {
            XCTAssertTrue(scroll.exists, "Sharpen popup must scroll to every real setting")
            guard scroll.exists else { break }
            let viewport = scroll.frame
            let sliderFrame = slider.exists ? slider.frame : CGRect.null
            // A partially clipped slider can report hittable while its adjustment
            // coordinates reach the canvas underneath. Require its whole track.
            if !sliderFrame.isNull && viewport.contains(sliderFrame) && slider.isHittable { return slider }
            guard attempt < 5 else { break }
            // Reset leaves this popup at its bottom. Revisit Size by scrolling
            // down; reveal settings below the viewport by scrolling up.
            if !sliderFrame.isNull && sliderFrame.minY < viewport.minY {
                scroll.swipeDown()
            } else {
                scroll.swipeUp()
            }
        }
        capture(target, name: "tool-setting-unreachable-" + name)
        captureHierarchy(target, name: "sharpen-setting-unreachable-" + name)
        XCTFail("Sharpen setting is unreachable: " + name)
        throw NSError(domain: "SharpenNative", code: 1)
    }
    @MainActor
    func testSharpenPixelsUndoAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let name = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let frame = canvas.frame
        try choosePickerTestColor("#999999", app: app)
        try pickerRailControl("studio.tool.rectangle", app: app, forward: true).tap()
        try resetToolPreferencesInPopup(app)
        let solid = app.buttons["studio.shape.fill"]
        XCTAssertEqual(solid.value as? String, "None"); solid.tap()
        XCTAssertEqual(solid.value as? String, "Solid")
        app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(canvas, expected: frame)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.1,dy: 0.2)).press(forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.9,dy: 0.8)))
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let background = try pixels(canvas.screenshot().image)
        try pickerRailControl("studio.tool.rectangle", app: app, forward: false).tap()
        try resetToolPreferencesInPopup(app)
        app.buttons["studio.tool-settings.close"].tap()
        try choosePickerTestColor("#666666", app: app)
        try pickerRailControl("studio.tool.pencil", app: app, forward: false).tap()
        app.sliders["studio.setting.size"].adjust(toNormalizedSliderPosition: 0.85)
        app.sliders["studio.setting.opacity"].adjust(toNormalizedSliderPosition: 1)
        app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(canvas, expected: frame)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.15,dy: 0.5)).press(forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.85,dy: 0.5)))
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let original = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(background, original), 60)
        try pickerRailControl("studio.tool.pencil", app: app, forward: false).tap()
        try resetToolPreferencesInPopup(app)
        app.buttons["studio.tool-settings.close"].tap()
        try pickerRailControl("studio.tool.sharpen", app: app, forward: true).tap()
        XCTAssertTrue(app.staticTexts["studio.sharpen.instructions"].waitForExistence(timeout: 5))
        let adjustments: [(String, CGFloat)] = [("size",0.45),("opacity",1),("hardness",0.8),("radius",0.2),("amount",0.75),("threshold",0)]
        for (key, value) in adjustments {
            let slider = try sharpenSetting(key, in: app)
            slider.adjust(toNormalizedSliderPosition: value)
        }
        capture(app, name: "sharpen-size-opacity-popup")
        app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(canvas, expected: frame)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5,dy: 0.5)).press(forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5,dy: 0.7)))
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let sharpened = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(original, sharpened), 30, "Sharpen did not change actual edge contrast")
        capture(app, name: "sharpen-real-canvas-pixels")
        app.buttons["studio.undo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4)
        app.buttons["studio.redo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(sharpened, pixels(canvas.screenshot().image)), 4)
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(sharpened, pixels(restored.screenshot().image)), 4,
            "Cold reopen changed sharpened artwork")
        capture(reopened, name: "sharpen-cold-reopened")
    }

    @MainActor
    func testDodgePixelsUndoAndColdReopen() throws { try exerciseDodgeBurnPixelsAndReopen("dodge") }

    @MainActor
    func testBurnPixelsUndoAndColdReopen() throws { try exerciseDodgeBurnPixelsAndReopen("burn") }

    @MainActor
    private func exerciseDodgeBurnPixelsAndReopen(_ tool: String) throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let name = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let frame = canvas.frame
        try choosePickerTestColor("#999999", app: app)
        try pickerRailControl("studio.tool.rectangle", app: app, forward: true).tap()
        try resetToolPreferencesInPopup(app)
        let solid = app.buttons["studio.shape.fill"]
        XCTAssertEqual(solid.value as? String, "None"); solid.tap()
        XCTAssertEqual(solid.value as? String, "Solid")
        app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(canvas, expected: frame)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.1,dy: 0.2)).press(forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.9,dy: 0.8)))
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let original = try pixels(canvas.screenshot().image)
        try pickerRailControl("studio.tool." + tool, app: app, forward: true).tap()
        XCTAssertTrue(app.staticTexts["studio.dodge-burn.instructions"].waitForExistence(timeout: 5))
        let adjustments: [(String, CGFloat)] = [("size",0.65),("opacity",1),("hardness",0.8),("exposure",0.75)]
        for (key, value) in adjustments {
            let slider = try sharpenSetting(key, in: app)
            slider.adjust(toNormalizedSliderPosition: value)
        }
        capture(app, name: tool + "-exposure-popup")
        app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(canvas, expected: frame)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5,dy: 0.5)).press(forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5,dy: 0.7)))
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let sharpened = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(original, sharpened), 30, tool + " did not change existing artwork exposure")
        capture(app, name: tool + "-real-canvas-pixels")
        app.buttons["studio.undo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4)
        app.buttons["studio.redo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(sharpened, pixels(canvas.screenshot().image)), 4)
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(sharpened, pixels(restored.screenshot().image)), 4,
            "Cold reopen changed " + tool + " artwork")
        capture(reopened, name: tool + "-cold-reopened")
    }

    @MainActor
    func testDodgeSettingsPersistAndReset() throws { try exerciseDodgeBurnSettings("dodge") }

    @MainActor
    func testBurnSettingsPersistAndReset() throws { try exerciseDodgeBurnSettings("burn") }

    @MainActor
    private func exerciseDodgeBurnSettings(_ tool: String) throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let name = try createProjectIfLibraryIsShown(app)
        try pickerRailControl("studio.tool." + tool, app: app, forward: true).tap()
        try resetToolPreferencesInPopup(app)
        let adjustments: [(String, CGFloat)] = [("size",0.6),("opacity",0.7),("hardness",0.8),("exposure",0.65)]
        var defaults: [String:String] = [:]
        var saved: [String:String] = [:]
        for (key, value) in adjustments {
            let slider = try sharpenSetting(key, in: app)
            defaults[key] = try XCTUnwrap(slider.value as? String)
            slider.adjust(toNormalizedSliderPosition: value)
            saved[key] = try XCTUnwrap(slider.value as? String)
            XCTAssertNotEqual(saved[key], defaults[key], "Setting did not change: " + key)
        }
        let range = app.buttons["studio.dodge-burn.range"]
        XCTAssertTrue(range.isHittable)
        XCTAssertEqual(range.value as? String, "Midtones")
        range.tap()
        let highlights = app.buttons["Highlights"]
        XCTAssertTrue(highlights.waitForExistence(timeout: 5)); highlights.tap()
        XCTAssertEqual(range.value as? String, "Highlights")
        let protection = app.switches["studio.dodge-burn.protect-tones"]
        XCTAssertEqual(protection.value as? String, "1"); protection.tap()
        XCTAssertEqual(protection.value as? String, "0")
        capture(app, name: tool + "-all-settings-changed")
        app.buttons["studio.tool-settings.close"].tap()
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        try pickerRailControl("studio.tool." + tool, app: reopened, forward: true).tap()
        for (key, _) in adjustments {
            XCTAssertEqual(try sharpenSetting(key, in: reopened).value as? String, saved[key])
        }
        XCTAssertEqual(reopened.buttons["studio.dodge-burn.range"].value as? String, "Highlights")
        XCTAssertEqual(reopened.switches["studio.dodge-burn.protect-tones"].value as? String, "0")
        capture(reopened, name: tool + "-six-settings-cold-reopened")
        try resetToolPreferencesInPopup(reopened)
        for (key, _) in adjustments {
            XCTAssertEqual(try sharpenSetting(key, in: reopened).value as? String, defaults[key])
        }
        XCTAssertEqual(reopened.buttons["studio.dodge-burn.range"].value as? String, "Midtones")
        XCTAssertEqual(reopened.switches["studio.dodge-burn.protect-tones"].value as? String, "1")
        reopened.buttons["studio.tool-settings.close"].tap()
    }

    // Keep all six persisted preference and reset checks independent of the
    // drawing/reopen journey, which reached these checks at its 180s deadline.
    @MainActor
    func testSharpenSettingsPersistAndReset() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let name = try createProjectIfLibraryIsShown(app)
        try pickerRailControl("studio.tool.sharpen", app: app, forward: true).tap()
        try resetToolPreferencesInPopup(app)
        let adjustments: [(String, CGFloat)] = [("size",0.45),("opacity",1),("hardness",0.8),("radius",0.2),("amount",0.75),("threshold",0)]
        var defaults: [String:String] = [:]
        var saved: [String:String] = [:]
        for (key, value) in adjustments {
            let slider = try sharpenSetting(key, in: app)
            defaults[key] = try XCTUnwrap(slider.value as? String)
            slider.adjust(toNormalizedSliderPosition: value)
            saved[key] = try XCTUnwrap(slider.value as? String)
        }
        app.buttons["studio.tool-settings.close"].tap()
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        try pickerRailControl("studio.tool.sharpen", app: reopened, forward: true).tap()
        for (key, _) in adjustments {
            XCTAssertEqual(try sharpenSetting(key, in: reopened).value as? String, saved[key])
        }
        capture(reopened, name: "sharpen-six-settings-cold-reopened")
        try resetToolPreferencesInPopup(reopened)
        for (key, _) in adjustments {
            XCTAssertEqual(try sharpenSetting(key, in: reopened).value as? String, defaults[key])
        }
        reopened.buttons["studio.tool-settings.close"].tap()
    }

    @MainActor
    func testEraserModesStrengthUndoAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let name = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let frame = canvas.frame
        try pickerRailControl("studio.tool.pencil", app: app, forward: false).tap()
        app.sliders["studio.setting.size"].adjust(toNormalizedSliderPosition: 0.85)
        app.sliders["studio.setting.opacity"].adjust(toNormalizedSliderPosition: 1)
        app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(canvas, expected: frame)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.15,dy: 0.5)).press(forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.85,dy: 0.5)))
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let original = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(exportInkMask(original).count, 60)

        try pickerRailControl("studio.tool.lasso", app: app, forward: true).tap()
        let selectAll = app.buttons["studio.selection.all"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5)); selectAll.tap()
        XCTAssertEqual(app.staticTexts["studio.selection.count"].label, "1 drawings selected")
        app.buttons["studio.tool-settings.close"].tap()
        try pickerRailControl("studio.tool.eraser", app: app, forward: false).tap()
        let hard = app.buttons["studio.eraser.mode.hard"], soft = app.buttons["studio.eraser.mode.soft"]
        XCTAssertTrue(hard.waitForExistence(timeout: 5) && hard.isHittable && soft.isHittable)
        hard.tap()
        app.sliders["studio.setting.size"].adjust(toNormalizedSliderPosition: 0.7)
        app.sliders["studio.setting.strength"].adjust(toNormalizedSliderPosition: 1)
        app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(canvas, expected: frame)
        func eraseAcrossStroke() {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5,dy: 0.35)).press(forDuration: 0.05,
                thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5,dy: 0.65)))
        }
        eraseAcrossStroke(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        // Remove only the selection overlay before comparing actual artwork.
        try pickerRailControl("studio.tool.eraser", app: app, forward: true).tap()
        let deselect = app.buttons["studio.eraser.deselect"]
        XCTAssertTrue(deselect.waitForExistence(timeout: 5)); deselect.tap()
        app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(canvas, expected: frame)
        let hardPixels = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(original, hardPixels), 30, "Hard eraser did not change actual artwork")
        XCTAssertLessThan(exportInkMask(hardPixels).count, exportInkMask(original).count, "Hard eraser failed to remove ink")
        capture(app, name: "hard-eraser-real-pixels")
        app.buttons["studio.undo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4, "Undo lost original artwork")

        try pickerRailControl("studio.tool.eraser", app: app, forward: true).tap()
        soft.tap(); XCTAssertEqual(soft.value as? String, "Selected")
        let strength = app.sliders["studio.setting.strength"]
        strength.adjust(toNormalizedSliderPosition: 0.5)
        app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(canvas, expected: frame)
        eraseAcrossStroke(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        let softPixels = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(original, softPixels), 30, "Soft eraser did not change actual pixels")
        XCTAssertGreaterThan(try changedPixelCount(hardPixels, softPixels), 30, "Mode and strength changed labels only")
        app.buttons["studio.undo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4)
        app.buttons["studio.redo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(softPixels, pixels(canvas.screenshot().image)), 4)
        app.buttons["studio.back"].tap(); app.terminate()

        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(softPixels, pixels(restored.screenshot().image)), 4,
                                "Cold reopen changed erased artwork")
        capture(reopened, name: "soft-eraser-cold-reopened")
    }

    @MainActor
    func testEraserSettingsPersistAndResetAfterColdLaunch() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let name = try createProjectIfLibraryIsShown(app)
        // Preference cleanup belongs to this independent settings journey,
        // keeping every real canvas/history/cold-render check in the modes case.
        try pickerRailControl("studio.tool.pencil", app: app, forward: false).tap()
        try resetToolPreferencesInPopup(app)
        app.buttons["studio.tool-settings.close"].tap()
        try pickerRailControl("studio.tool.eraser", app: app, forward: true).tap()
        let soft = app.buttons["studio.eraser.mode.soft"]
        XCTAssertTrue(soft.waitForExistence(timeout: 5)); XCTAssertTrue(soft.isHittable)
        soft.tap(); XCTAssertEqual(soft.value as? String, "Selected")
        let strength = app.sliders["studio.setting.strength"]
        strength.adjust(toNormalizedSliderPosition: 0.5)
        let capturedStrength = try XCTUnwrap(strength.value as? String)
        capture(app, name: "soft-eraser-strength-popup")
        app.buttons["studio.tool-settings.close"].tap()
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        try pickerRailControl("studio.tool.eraser", app: reopened, forward: true).tap()
        XCTAssertEqual(reopened.buttons["studio.eraser.mode.soft"].value as? String, "Selected")
        XCTAssertEqual(reopened.sliders["studio.setting.strength"].value as? String, capturedStrength)
        try resetToolPreferencesInPopup(reopened)
        XCTAssertEqual(reopened.buttons["studio.eraser.mode.hard"].value as? String, "Selected")
        reopened.buttons["studio.tool-settings.close"].tap()
    }

    @MainActor
    private func createEditableTextFixture(_ content: String, app: XCUIApplication, chooseRed: Bool = true, keepTextSelected: Bool = false, exerciseNativeTextAlpha: Bool = false) throws -> (name: String, canvas: XCUIElement, frame: CGRect, pixels: Raster) {
        let name = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let frame = canvas.frame
        if chooseRed { try choosePickerTestColor("#FF0000", app: app) }
        try selectToolbarTool("text", app: app)
        XCTAssertTrue(app.buttons["studio.text.new"].waitForExistence(timeout: 5))
        app.buttons["studio.text.new"].tap()
        let input = app.descendants(matching: .any)["studio.text.content"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap(); input.typeText(content)
        app.buttons["studio.text.keyboard-dismiss"].tap()
        if exerciseNativeTextAlpha {
            let picker = app.descendants(matching: .any)["studio.text.color"].firstMatch
            let popup = app.descendants(matching: .any)["studio.tool-settings"].firstMatch
            let scroll = popup.scrollViews.firstMatch
            XCTAssertTrue(picker.waitForExistence(timeout: 5) && scroll.exists)
            for _ in 0..<5 {
                let viewport = scroll.frame.intersection(app.frame)
                if viewport.contains(picker.frame) && picker.isHittable { break }
                if picker.frame.minY < viewport.minY { scroll.swipeDown(velocity: .slow) }
                else { scroll.swipeUp(velocity: .slow) }
            }
            XCTAssertTrue(scroll.frame.intersection(app.frame).contains(picker.frame) && picker.isHittable)
            // Observed ColorWell includes its label; only the right circular
            // swatch opens UIKit's picker. Derive its center from actual bounds.
            let well = picker.frame
            XCTAssertGreaterThan(well.width, well.height)
            picker.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: well.width - well.height / 2, dy: well.height / 2)).tap()
            // iOS exposes this native picker track as Other, with a separate
            // percentage TextField; the Studio opacity Slider is underneath.
            let systemPicker = app.otherElements["UIColorPickerView"].firstMatch
            XCTAssertTrue(systemPicker.waitForExistence(timeout: 8))
            let alpha = systemPicker.otherElements.matching(NSPredicate(format: "label == %@", "Opacity")).firstMatch
            let alphaValue = systemPicker.textFields.matching(NSPredicate(format: "label == %@", "Opacity")).firstMatch
            XCTAssertTrue(alpha.waitForExistence(timeout: 5) && alpha.isHittable && alpha.isEnabled)
            XCTAssertTrue(alphaValue.exists && alphaValue.isEnabled)
            let priorAlpha = try XCTUnwrap(alphaValue.value as? String)
            // Actual captured UIKit hierarchy identifies the track and its
            // bounds. Tap its midpoint, then verify the native percentage.
            alpha.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let halfOpacity = expectation(for: NSPredicate { _, _ in
                guard let value = alphaValue.value as? String,
                      let percent = Double(value.replacingOccurrences(of: "%", with: "")) else { return false }
                return (45...55).contains(percent)
            }, evaluatedWith: alphaValue).waitUntilFulfilled(timeout: 5)
            if !halfOpacity { captureHierarchy(app, name: "native-text-picker-percentage-unexpected") }
            XCTAssertTrue(halfOpacity, "Native Text color picker did not set approximately half opacity")
            XCTAssertNotEqual(alphaValue.value as? String, priorAlpha, "System opacity did not change")
            capture(app, name: "native-text-picker-half-opacity")
            let close = app.buttons.matching(NSPredicate(format: "label ==[c] %@", "Close"))
                .allElementsBoundByIndex.first { $0.exists && $0.isEnabled && $0.isHittable }
            if close == nil {
                capture(app, name: "native-text-picker-close-unavailable")
                print("SDI_TEXT_PICKER_AX_BEGIN\n" + String(app.debugDescription.prefix(60000)) + "\nSDI_TEXT_PICKER_AX_END")
            }
            try XCTUnwrap(close, "Actual UIKit picker Close control is unavailable").tap()
            XCTAssertTrue(expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: systemPicker)
                .waitUntilFulfilled(timeout: 5), "System picker remained open")
        }
        let fontSize: XCUIElement
        if exerciseNativeTextAlpha { fontSize = try sharpenSetting("font-size", in: app) }
        else { fontSize = app.sliders["studio.setting.font-size"] }
        // All four glyphs must fit the 240 px box. At 100 px the final !
        // correctly wraps below its 120 px height, hiding the expected edit.
        XCTAssertTrue(fontSize.isHittable); fontSize.adjust(toNormalizedSliderPosition: 0.18)
        app.buttons["studio.text.apply"].tap()
        XCTAssertTrue(app.buttons["studio.text.new"].waitForExistence(timeout: 5))
        app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(canvas, expected: frame)
        if !keepTextSelected {
            // Ordinary drawing fixtures use an undecorated canvas. The cold
            // text-edit journey keeps the same text selection before/after
            // each pixel comparison and on reopen, avoiding redundant trips
            // across the toolbar before editing that already selected text.
            try selectToolbarTool("move", app: app)
            app.buttons["studio.tool-settings.close"].tap()
            try waitForStableCanvas(canvas, expected: frame)
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.05)).tap()
            try settlePickerCanvasAfterSave(app, canvas: canvas)
        }
        let original = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(exportInkMask(original).count, 25, "Text did not draw actual glyphs")
        return (name, canvas, frame, original)
    }

    @MainActor
    func testEditableTextUndoRedo() throws {
        try verifyEditableText(historyOnly: true)
    }

    @MainActor
    func testEditableTextCancelAndEdit() throws {
        try verifyEditableText(historyOnly: false)
    }

    @MainActor
    private func verifyEditableText(historyOnly: Bool) throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let fixture = try createEditableTextFixture("SDI", app: app, chooseRed: historyOnly, keepTextSelected: !historyOnly, exerciseNativeTextAlpha: historyOnly)
        let canvas = fixture.canvas, frame = fixture.frame, original = fixture.pixels
        let input = app.descendants(matching: .any)["studio.text.content"].firstMatch
        capture(app, name: "editable-text-original-glyphs")
        // Keep each real journey within the unchanged native time budget.
        // The former combined case completed its pixel checks at 179.75 s
        // but timed out during termination. Preserve both sets of assertions.
        if historyOnly {
            let ink = exportInkMask(original)
            let greens = ink.map { Int(original.bytes[$0 * 4 + 1]) }.sorted()
            XCTAssertGreaterThan(greens.count, 25)
            let interiorGreen = try XCTUnwrap(greens.dropFirst(greens.count / 4).first, "No rendered text pixels")
            XCTAssertGreaterThan(interiorGreen, 80, "Picker opacity left glyphs opaque or compounded alpha")
            XCTAssertLessThan(interiorGreen, 180, "Picker opacity made glyphs too faint or compounded alpha")
            capture(app, name: "native-text-picker-translucent-glyphs")
            app.buttons["studio.undo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
            let blank = try pixels(canvas.screenshot().image)
            XCTAssertLessThan(exportInkMask(blank).count, exportInkMask(original).count, "Undo left text pixels behind")
            app.buttons["studio.redo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
            XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4)
            return
        }
        // The fixture keeps this exact text box selected. Both pixel captures
        // include the same fixed selection outline, as in the cold-reopen test.
        // Avoid deselecting and selecting it again before editing its source.
        try selectToolbarTool("text", app: app)
        app.buttons["studio.text.edit"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5)); XCTAssertEqual(input.value as? String, "SDI")
        input.tap(); input.typeText(" CANCEL")
        app.buttons["studio.text.cancel"].tap()
        app.buttons["studio.text.edit"].tap()
        XCTAssertEqual(input.value as? String, "SDI", "Cancel changed editable source")
        input.tap(); input.typeText("!")
        XCTAssertEqual(input.value as? String, "SDI!", "Text entry did not update the editable draft")
        app.buttons["studio.text.keyboard-dismiss"].tap()
        capture(app, name: "editable-text-typography-popup")
        app.buttons["studio.text.apply"].tap()
        // Reset while the Text popup is already open. A later trip back across
        // the rail consumed the original 180-second allowance after all edit
        // assertions had passed. Reset changes tool defaults, not saved text.
        try resetToolPreferencesInPopup(app)
        app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(canvas, expected: frame)
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let edited = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(original, edited), 4, "Editing text did not change glyphs")
        capture(app, name: "editable-text-edited-glyphs")
    }

    @MainActor
    func testEditableTextColdReopenAndEditableSource() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let fixture = try createEditableTextFixture("SDI", app: app, chooseRed: false, keepTextSelected: true)
        let name = fixture.name, frame = fixture.frame, canvas = fixture.canvas
        // Persist an actual edit to existing text, not only a newly created box.
        // Apply selected the new text. Edit that real selection directly.
        try selectToolbarTool("text", app: app)
        app.buttons["studio.text.edit"].tap()
        let input = app.descendants(matching: .any)["studio.text.content"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5)); XCTAssertEqual(input.value as? String, "SDI")
        input.tap(); input.typeText("!")
        XCTAssertEqual(input.value as? String, "SDI!")
        app.buttons["studio.text.keyboard-dismiss"].tap()
        app.buttons["studio.text.apply"].tap(); app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(canvas, expected: frame)
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let edited = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(fixture.pixels, edited), 4, "Text edit did not change saved glyphs")
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: frame)
        try selectToolbarTool("move", app: reopened)
        reopened.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(restored, expected: frame)
        restored.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        try selectToolbarTool("text", app: reopened)
        reopened.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(restored, expected: frame)
        // Match the same Text-tool selection decoration as both earlier
        // captures; fixed text-box geometry keeps the outline unchanged.
        XCTAssertLessThanOrEqual(try changedPixelCount(edited, pixels(restored.screenshot().image)), 4,
                                "Cold reopen changed text glyphs")
        capture(reopened, name: "editable-text-cold-reopened")
        try selectToolbarTool("text", app: reopened)
        reopened.buttons["studio.text.edit"].tap()
        let restoredInput = reopened.descendants(matching: .any)["studio.text.content"].firstMatch
        XCTAssertTrue(restoredInput.waitForExistence(timeout: 5)); XCTAssertEqual(restoredInput.value as? String, "SDI!")
        reopened.buttons["studio.text.cancel"].tap()
        try resetToolPreferencesInPopup(reopened)
        reopened.buttons["studio.tool-settings.close"].tap()
    }

    @MainActor
    private func fillPreferenceControl(_ identifier: String, app: XCUIApplication) throws -> XCUIElement {
        let popup = app.descendants(matching: .any)["studio.tool-settings"].firstMatch
        let scroll = popup.scrollViews.firstMatch
        let control = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 5), "Fill controls need the existing popup scroll viewport")
        for _ in 0..<6 {
            let bounds = scroll.frame.intersection(app.frame)
            let viewport = bounds.insetBy(dx: 0, dy: min(12, bounds.height * 0.05))
            guard viewport.width > 0, viewport.height > 0, control.exists else { break }
            let target = control.frame
            // XCTest can report a clipped slider as hittable. Its entire thumb
            // and track must lie inside the actual scroll viewport before adjustment.
            if target.width > 0, target.height > 0, viewport.contains(target),
               control.isEnabled, control.isHittable { return control }
            guard target.width > 0, target.height > 0, target.height <= viewport.height else { break }
            if viewport.contains(target) { break } // Disabled controls are not scroll failures.
            let inset = bounds.height * 0.15
            let maximumTravel = bounds.height - 2 * inset
            let movement = min(maximumTravel, max(-maximumTravel, viewport.midY - target.midY))
            guard abs(movement) > 0 else { break }
            let startY = movement < 0 ? bounds.maxY - inset : bounds.minY + inset
            let origin = scroll.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: bounds.midX - scroll.frame.minX, dy: startY - scroll.frame.minY))
            let end = origin.withOffset(CGVector(dx: bounds.midX - scroll.frame.minX, dy: startY + movement - scroll.frame.minY))
            // Hold at the measured destination to avoid an inertial swipe
            // skipping the next short row in this compact popup.
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.25)
        }
        captureHierarchy(app, name: "fill-preference-control-clipped-" + identifier)
        XCTFail("Fill control is not fully visible and actionable: " + identifier)
        throw NSError(domain: "NativeFillPreferences", code: 1)
    }

    @MainActor private func resetToolPreferencesInPopup(_ app: XCUIApplication) throws {
        let reset = app.buttons["studio.tool-settings.reset"]
        for attempt in 0...4 {
            if reset.exists && reset.isHittable { reset.tap(); return }
            guard attempt < 4 else { break }
            let scroll = app.scrollViews.containing(.button, identifier: "studio.tool-settings.reset").firstMatch
            XCTAssertTrue(scroll.exists, "Reset this tool has no reachable popup scroll container")
            scroll.swipeUp()
        }
        captureHierarchy(app, name: "tool-preference-reset-unreachable")
        XCTFail("Reset this tool is unreachable")
        throw NSError(domain: "NativeToolPreferences", code: 1)
    }

    @MainActor
    func testRectangleAndPolygonSelectionDeleteUndoAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let name = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching:.any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let frame = canvas.frame
        try pickerRailControl("studio.tool.pencil", app:app, forward:false).tap()
        app.buttons["studio.tool-settings.close"].tap()
        canvas.coordinate(withNormalizedOffset:CGVector(dx:0.65,dy:0.60)).press(forDuration:0.05,
            thenDragTo:canvas.coordinate(withNormalizedOffset:CGVector(dx:0.82,dy:0.60)))
        try settlePickerCanvasAfterSave(app,canvas:canvas)
        let rightOnly = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(exportInkMask(rightOnly).count,12)
        canvas.coordinate(withNormalizedOffset:CGVector(dx:0.20,dy:0.42)).press(forDuration:0.05,
            thenDragTo:canvas.coordinate(withNormalizedOffset:CGVector(dx:0.43,dy:0.42)))
        try settlePickerCanvasAfterSave(app,canvas:canvas)
        let both = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(exportInkMask(both).count,exportInkMask(rightOnly).count+12)
        try selectToolbarTool("lasso",app:app)
        let rectangle = app.buttons["studio.selection.kind.rectangle"]
        XCTAssertTrue(rectangle.waitForExistence(timeout:5) && rectangle.isHittable); rectangle.tap()
        XCTAssertFalse(app.buttons["studio.lasso.delete"].isEnabled,"Area Delete requires explicit selection")
        app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(canvas,expected:frame)
        canvas.coordinate(withNormalizedOffset:CGVector(dx:0.13,dy:0.34)).press(forDuration:0.1,
            thenDragTo:canvas.coordinate(withNormalizedOffset:CGVector(dx:0.51,dy:0.50)))
        try selectToolbarTool("lasso",app:app)
        XCTAssertEqual(app.staticTexts["studio.selection.count"].label,"1 drawings selected","Rectangle must select only the enclosed drawing")
        XCTAssertEqual(app.buttons["studio.save"].label,"Saved","Selection must not edit the document")
        app.buttons["studio.lasso.deselect"].tap()
        let polygon = app.buttons["studio.selection.kind.polygon"]
        XCTAssertTrue(polygon.isHittable); polygon.tap()
        app.buttons["studio.tool-settings.close"].tap()
        for point in [CGVector(dx:0.13,dy:0.34), CGVector(dx:0.51,dy:0.34)] {
            canvas.coordinate(withNormalizedOffset:point).tap()
        }
        try selectToolbarTool("lasso",app:app)
        XCTAssertFalse(app.buttons["studio.selection.polygon.finish"].isEnabled,"Two corners must not finish a polygon")
        XCTAssertTrue(app.buttons["studio.selection.polygon.cancel"].isEnabled)
        app.buttons["studio.selection.polygon.cancel"].tap()
        XCTAssertEqual(app.staticTexts["studio.selection.count"].label,"0 drawings selected")
        app.buttons["studio.tool-settings.close"].tap()
        for point in [CGVector(dx:0.13,dy:0.34), CGVector(dx:0.51,dy:0.34),
                      CGVector(dx:0.51,dy:0.50), CGVector(dx:0.13,dy:0.50)] {
            canvas.coordinate(withNormalizedOffset:point).tap()
        }
        try selectToolbarTool("lasso",app:app)
        let finishPolygon = app.buttons["studio.selection.polygon.finish"]
        XCTAssertTrue(finishPolygon.isEnabled && finishPolygon.isHittable); finishPolygon.tap()
        XCTAssertEqual(app.staticTexts["studio.selection.count"].label,"1 drawings selected","Polygon must enclose the same single drawing")
        XCTAssertEqual(app.buttons["studio.save"].label,"Saved","Polygon selection must remain transient")
        capture(app,name:"polygon-selection-finished-with-canonical-drawing")
        let delete = app.buttons["studio.lasso.delete"]
        XCTAssertTrue(delete.isEnabled && delete.isHittable); delete.tap()
        app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(canvas,expected:frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(rightOnly,pixels(canvas.screenshot().image)),4,"Selection Delete removed the wrong artwork or kept the enclosed drawing")
        capture(app,name:"rectangle-selection-deleted-only-enclosed-artwork")
        app.buttons["studio.undo"].tap()
        XCTAssertLessThanOrEqual(try changedPixelCount(both,pixels(canvas.screenshot().image)),4,"Delete Undo failed to restore exact artwork")
        app.buttons["studio.redo"].tap()
        XCTAssertLessThanOrEqual(try changedPixelCount(rightOnly,pixels(canvas.screenshot().image)),4,"Delete Redo changed surviving artwork")
        try settlePickerCanvasAfterSave(app,canvas:canvas)
        app.buttons["studio.back"].tap();app.terminate()
        let reopened = try launchGuestStudio(); defer {reopened.terminate()}
        let project = reopened.buttons.matching(NSPredicate(format:"label == %@",name)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout:8));project.tap()
        let restored = reopened.descendants(matching:.any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored,expected:frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(rightOnly,pixels(restored.screenshot().image)),4,"Selection edit did not survive cold reopen")
        capture(reopened,name:"rectangle-selection-cold-reopened")
    }

    @MainActor
    func testSelectionForwardBackUndoAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let name = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let stableSelectionCanvasFrame = canvas.frame
        try pickerRailControl("studio.tool.brush", app: app, forward: false).tap()
        let library = app.buttons["studio.brush-library"]
        XCTAssertTrue(library.waitForExistence(timeout: 5)); library.tap()
        let round = app.buttons["studio.brush-family.round"]
        XCTAssertTrue(round.waitForExistence(timeout: 5)); round.tap()
        app.sliders["studio.setting.size"].adjust(toNormalizedSliderPosition: 0.7)
        app.sliders["studio.setting.opacity"].adjust(toNormalizedSliderPosition: 1)
        app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(canvas)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.22,dy: 0.5)).press(forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.78,dy: 0.5)))
        try choosePickerTestColor("#0000FF", app: app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5,dy: 0.36)).press(forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5,dy: 0.7)))
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let original = try pixels(canvas.screenshot().image), originalColors = imageFixtureColors(original)
        XCTAssertGreaterThan(originalColors[0], 20); XCTAssertGreaterThan(originalColors[1], 20)
        try selectToolbarTool("move", app: app)
        app.buttons["studio.tool-settings.close"].tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3,dy: 0.5)).tap()
        try selectToolbarTool("move", app: app)
        let forward = app.buttons["studio.selection.fwd"]
        XCTAssertTrue(forward.waitForExistence(timeout: 5) && forward.isHittable); forward.tap()
        app.buttons["studio.selection.deselect"].tap()
        app.buttons["studio.tool-settings.close"].tap()
        XCTAssertEqual(canvas.frame, stableSelectionCanvasFrame, "Selection action resized the canvas")
        XCTAssertFalse(app.descendants(matching: .any)["studio.status"].firstMatch.exists, "Selection action added a resizing status banner")
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let front = try pixels(canvas.screenshot().image), frontColors = imageFixtureColors(front)
        XCTAssertGreaterThan(frontColors[0], originalColors[0] + 12, "Forward did not expose the actual red crossing")
        XCTAssertLessThan(frontColors[1], originalColors[1] - 12, "Forward did not occlude the actual blue crossing")
        capture(app, name: "selection-forward-actual-overlap")
        app.buttons["studio.undo"].tap()
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4)
        app.buttons["studio.redo"].tap()
        XCTAssertLessThanOrEqual(try changedPixelCount(front, pixels(canvas.screenshot().image)), 4)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3,dy: 0.5)).tap()
        try selectToolbarTool("move", app: app)
        let back = app.buttons["studio.selection.back"]
        XCTAssertTrue(back.isHittable); back.tap()
        app.buttons["studio.selection.deselect"].tap()
        app.buttons["studio.tool-settings.close"].tap()
        XCTAssertEqual(canvas.frame, stableSelectionCanvasFrame, "Selection action resized the canvas")
        XCTAssertFalse(app.descendants(matching: .any)["studio.status"].firstMatch.exists, "Selection action added a resizing status banner")
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4, "Back did not restore original overlap")
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let reopenedCanvas = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(reopenedCanvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(reopenedCanvas.screenshot().image)), 4, "Saved stacking did not survive cold reopen")
        capture(reopened, name: "selection-stacking-cold-reopened")
    }

    @MainActor
    func testSelectionCanvasHandlesUndoAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let name = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let frame = canvas.frame
        canvas.coordinate(withNormalizedOffset: CGVector(dx:0.35,dy:0.48)).press(forDuration:0.05,
            thenDragTo:canvas.coordinate(withNormalizedOffset:CGVector(dx:0.65,dy:0.52)))
        try settlePickerCanvasAfterSave(app,canvas:canvas)
        let original = try pixels(canvas.screenshot().image)
        func inkBounds(_ image: Raster) throws -> CGRect {
            let ink = exportInkMask(image)
            XCTAssertGreaterThan(ink.count,12)
            let xs=ink.map{$0 % image.width}, ys=ink.map{$0 / image.width}
            let minX=try XCTUnwrap(xs.min()),maxX=try XCTUnwrap(xs.max())
            let minY=try XCTUnwrap(ys.min()),maxY=try XCTUnwrap(ys.max())
            return CGRect(x:Double(minX)/Double(image.width)*frame.width,
                          y:Double(minY)/Double(image.height)*frame.height,
                          width:Double(maxX-minX+1)/Double(image.width)*frame.width,
                          height:Double(maxY-minY+1)/Double(image.height)*frame.height)
        }
        func coordinate(_ p: CGPoint) -> XCUICoordinate {
            canvas.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:p.x,dy:p.y))
        }
        try selectToolbarTool("move",app:app);app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(canvas,expected:frame)
        let beforeBounds=try inkBounds(original), center=CGPoint(x:beforeBounds.midX,y:beforeBounds.midY)
        coordinate(center).tap()
        let corner=CGPoint(x:center.x+max(beforeBounds.width/2,22),y:center.y+max(beforeBounds.height/2,22))
        let cornerEnd=CGPoint(x:center.x+1.7*(corner.x-center.x),y:center.y+1.7*(corner.y-center.y))
        capture(app,name:"selection-canvas-resize-handles")
        coordinate(corner).press(forDuration:0.05,thenDragTo:coordinate(cornerEnd))
        canvas.coordinate(withNormalizedOffset:CGVector(dx:0.03,dy:0.03)).tap()
        try settlePickerCanvasAfterSave(app,canvas:canvas)
        let resized=try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(exportInkMask(resized).count,exportInkMask(original).count*3/2,"Corner handle did not resize actual ink")
        app.buttons["studio.undo"].tap();try settlePickerCanvasAfterSave(app,canvas:canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(original,pixels(canvas.screenshot().image)),4,"One Undo did not reverse handle resize")
        app.buttons["studio.redo"].tap();try settlePickerCanvasAfterSave(app,canvas:canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(resized,pixels(canvas.screenshot().image)),4)
        let resizedBounds=try inkBounds(resized),pivot=CGPoint(x:resizedBounds.midX,y:resizedBounds.midY)
        coordinate(pivot).tap()
        let knob=CGPoint(x:pivot.x,y:pivot.y-max(resizedBounds.height/2,22)-30)
        let quarterTurn=CGPoint(x:pivot.x+(pivot.y-knob.y),y:pivot.y)
        coordinate(knob).press(forDuration:0.05,thenDragTo:coordinate(quarterTurn))
        canvas.coordinate(withNormalizedOffset:CGVector(dx:0.03,dy:0.03)).tap()
        try settlePickerCanvasAfterSave(app,canvas:canvas)
        let rotated=try pixels(canvas.screenshot().image),rotatedBounds=try inkBounds(rotated)
        XCTAssertGreaterThan(rotatedBounds.height,resizedBounds.height*1.3,"Rotation handle did not rotate real ink")
        XCTAssertGreaterThan(try changedPixelCount(resized,rotated),20)
        capture(app,name:"selection-canvas-handles-committed")
        app.buttons["studio.undo"].tap();try settlePickerCanvasAfterSave(app,canvas:canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(resized,pixels(canvas.screenshot().image)),4)
        app.buttons["studio.redo"].tap();try settlePickerCanvasAfterSave(app,canvas:canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(rotated,pixels(canvas.screenshot().image)),4)
        app.buttons["studio.back"].tap();app.terminate()
        let reopened=try launchGuestStudio();defer { reopened.terminate() }
        let project=reopened.buttons.matching(NSPredicate(format:"label == %@",name)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout:8));project.tap()
        let restored=reopened.descendants(matching:.any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored,expected:frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(rotated,pixels(restored.screenshot().image)),4,"Cold reopen changed handle-edited artwork")
        capture(reopened,name:"selection-canvas-handles-cold-reopened")
    }

    @MainActor
    func testSelectionScaleRotateUndoAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let name = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let stableFrame = canvas.frame
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.46)).press(forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.54)))
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let original = try pixels(canvas.screenshot().image), originalInk = exportInkMask(original)
        capture(app, name: "selection-transform-original-artwork")
        XCTAssertGreaterThan(originalInk.count, 12)
        try selectToolbarTool("move", app: app)
        app.buttons["studio.tool-settings.close"].tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        try selectToolbarTool("move", app: app)
        let scale = app.sliders["studio.setting.scale"], angle = app.sliders["studio.setting.angle"]
        let apply = app.buttons["studio.selection.transform-apply"]
        let popup = app.descendants(matching: .any)["studio.tool-settings"].firstMatch
        let scroll = popup.scrollViews.firstMatch
        func revealTransformControl(_ control: XCUIElement) throws {
            for _ in 0..<4 {
                XCTAssertTrue(scroll.exists, "Transform controls have no reachable popup scroll container")
                let viewport = scroll.frame.insetBy(dx: 0, dy: 12)
                // A partially clipped slider can report hittable while its
                // thumb is behind the popup footer. Require its entire track.
                if control.isHittable && viewport.contains(control.frame) { return }
                if control.frame.midY < viewport.midY { scroll.swipeDown(velocity: .slow) }
                else { scroll.swipeUp(velocity: .slow) }
            }
            XCTAssertTrue(control.isHittable && scroll.frame.insetBy(dx: 0, dy: 12).contains(control.frame),
                          "Transform control is not fully visible inside its sole popup")
        }
        try revealTransformControl(scale)
        scale.adjust(toNormalizedSliderPosition: 0.4667) // roughly 200% in 25...400
        let actualScale = try XCTUnwrap(Double((scale.value as? String ?? "").filter { "0123456789.-".contains($0) }))
        XCTAssertTrue((180...220).contains(actualScale), "Scale gesture did not reach the actual control; value=\(actualScale)")
        try revealTransformControl(angle)
        angle.adjust(toNormalizedSliderPosition: 0.75) // roughly 90 degrees
        let actualAngle = try XCTUnwrap(Double((angle.value as? String ?? "").filter { "0123456789.-".contains($0) }))
        XCTAssertTrue((75...105).contains(actualAngle), "Angle gesture did not reach the actual control; value=\(actualAngle)")
        try revealTransformControl(apply)
        capture(app, name: "selection-scale-rotate-popup")
        apply.tap()
        app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(canvas, expected: stableFrame)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.04)).tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let changed = try pixels(canvas.screenshot().image), changedInk = exportInkMask(changed)
        capture(app, name: "selection-transform-before-pixel-verification")
        XCTAssertGreaterThan(changedInk.count, originalInk.count * 3 / 2,
                             "Scale changed controls without increasing actual ink")
        let originalRows = originalInk.map { $0 / original.width }, changedRows = changedInk.map { $0 / changed.width }
        let oldHeight = try XCTUnwrap(originalRows.max()) - XCTUnwrap(originalRows.min()) + 1
        let newHeight = try XCTUnwrap(changedRows.max()) - XCTUnwrap(changedRows.min()) + 1
        XCTAssertGreaterThan(newHeight, oldHeight * 2, "Rotation did not turn the near-horizontal drawing vertically")
        XCTAssertGreaterThan(try changedPixelCount(original, changed), 20)
        XCTAssertFalse(app.descendants(matching: .any)["studio.status"].firstMatch.exists,
                       "Applying the transform resized the canvas with a status banner")
        capture(app, name: "selection-scaled-rotated-artwork")
        app.buttons["studio.undo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4,
                                 "One Undo did not restore exact pre-transform artwork")
        app.buttons["studio.redo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(changed, pixels(canvas.screenshot().image)), 4)
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: stableFrame)
        XCTAssertLessThanOrEqual(try changedPixelCount(changed, pixels(restored.screenshot().image)), 4,
                                 "Cold reopen changed transformed drawing pixels")
        capture(reopened, name: "selection-transform-cold-reopened")
    }

    @MainActor
    func testSelectionFlipUndoAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let name = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let stableSelectionCanvasFrame = canvas.frame
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.22,dy: 0.35)).press(forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.48,dy: 0.60)))
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let original = try pixels(canvas.screenshot().image), originalInk = exportInkMask(original)
        XCTAssertGreaterThan(originalInk.count, 12)
        try selectToolbarTool("move", app: app)
        app.buttons["studio.tool-settings.close"].tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.35,dy: 0.475)).tap()
        try selectToolbarTool("move", app: app)
        let flipH = app.buttons["studio.selection.flip-h"]
        XCTAssertTrue(flipH.waitForExistence(timeout: 5) && flipH.isHittable); flipH.tap()
        app.buttons["studio.selection.deselect"].tap()
        app.buttons["studio.tool-settings.close"].tap()
        XCTAssertEqual(canvas.frame, stableSelectionCanvasFrame, "Selection action resized the canvas")
        XCTAssertFalse(app.descendants(matching: .any)["studio.status"].firstMatch.exists, "Selection action added a resizing status banner")
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let horizontal = try pixels(canvas.screenshot().image), horizontalInk = exportInkMask(horizontal)
        XCTAssertGreaterThan(horizontalInk.count, 12)
        XCTAssertLessThan(originalInk.intersection(horizontalInk).count, max(8, originalInk.count/3), "Flip H retained the original slope")
        XCTAssertGreaterThan(Double(horizontalInk.count)/Double(originalInk.count), 0.75)
        XCTAssertLessThan(Double(horizontalInk.count)/Double(originalInk.count), 1.25)
        capture(app, name: "selection-flip-horizontal")
        app.buttons["studio.undo"].tap()
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4)
        app.buttons["studio.redo"].tap()
        XCTAssertLessThanOrEqual(try changedPixelCount(horizontal, pixels(canvas.screenshot().image)), 4)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.35,dy: 0.475)).tap()
        try selectToolbarTool("move", app: app)
        let flipV = app.buttons["studio.selection.flip-v"]
        XCTAssertTrue(flipV.isHittable); flipV.tap()
        app.buttons["studio.selection.deselect"].tap()
        app.buttons["studio.tool-settings.close"].tap()
        XCTAssertEqual(canvas.frame, stableSelectionCanvasFrame, "Selection action resized the canvas")
        XCTAssertFalse(app.descendants(matching: .any)["studio.status"].firstMatch.exists, "Selection action added a resizing status banner")
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let vertical = try pixels(canvas.screenshot().image), verticalInk = exportInkMask(vertical)
        XCTAssertLessThan(horizontalInk.intersection(verticalInk).count, max(8, horizontalInk.count/3), "Flip V retained the horizontal reflection")
        XCTAssertGreaterThan(originalInk.intersection(verticalInk).count, originalInk.count*7/10, "Two-axis reflection moved the diagonal outside its original bounds")
        app.buttons["studio.undo"].tap()
        XCTAssertLessThanOrEqual(try changedPixelCount(horizontal, pixels(canvas.screenshot().image)), 4)
        app.buttons["studio.redo"].tap()
        XCTAssertLessThanOrEqual(try changedPixelCount(vertical, pixels(canvas.screenshot().image)), 4)
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let reopenedCanvas = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(reopenedCanvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(vertical, pixels(reopenedCanvas.screenshot().image)), 4, "Reflected pixels did not survive cold reopen")
        capture(reopened, name: "selection-flip-cold-reopened")
    }

    @MainActor
    func testRealCanvasStrokeUndoRedo() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let projectName = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 8), "Missing accessible rendered canvas; do not substitute a shell coordinate")
        XCTAssertTrue(canvas.isHittable)
        XCTAssertGreaterThan(canvas.frame.width, 80)
        XCTAssertGreaterThan(canvas.frame.height, 80)
        let undo = identifiedButton("studio.undo", fallback: "UNDO", app: app)
        let redo = identifiedButton("studio.redo", fallback: "REDO", app: app)
        XCTAssertFalse(undo.isEnabled, "The fixture must be a new blank project")
        let before = try pixels(canvas.screenshot().image)
        capture(app, name: "stroke-before")

        // Drag inside the actual accessibility frame, not a guessed window area.
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.4))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: undo).waitUntilFulfilled(timeout: 5))
        let drawn = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(before, drawn), 12, "Drag changed no visible canvas pixels")
        capture(app, name: "stroke-drawn")

        undo.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: redo).waitUntilFulfilled(timeout: 5))
        let undone = try pixels(canvas.screenshot().image)
        XCTAssertLessThanOrEqual(try changedPixelCount(before, undone), 4, "Undo did not restore the actual blank raster")
        capture(app, name: "stroke-undone")

        redo.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: undo).waitUntilFulfilled(timeout: 5))
        let redone = try pixels(canvas.screenshot().image)
        XCTAssertLessThanOrEqual(try changedPixelCount(drawn, redone), 4, "Redo did not restore the drawn raster")
        capture(app, name: "stroke-redone")

        let save = app.buttons["studio.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5)); save.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "Saved"), evaluatedWith: save).waitUntilFulfilled(timeout: 8))
        let back = app.buttons["studio.back"]
        XCTAssertTrue(back.isHittable); back.tap()
        let library = app.descendants(matching: .any)["studio.library"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 8))
        let savedProject = app.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(savedProject.waitForExistence(timeout: 5), "Saved project is missing from the actual device library")
        capture(app, name: "saved-project-library")

        // A new app process must load persisted document bytes, not reuse the
        // in-memory shared view model or replay fixture drawing commands.
        app.terminate()
        let reopenedApp = try launchGuestStudio()
        defer { reopenedApp.terminate() }
        let reopenedProject = reopenedApp.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(reopenedProject.waitForExistence(timeout: 8)); reopenedProject.tap()
        let reopenedCanvas = reopenedApp.descendants(matching: .any)["studio.canvas"].firstMatch
        XCTAssertTrue(reopenedCanvas.waitForExistence(timeout: 8))
        let reopened = try pixels(reopenedCanvas.screenshot().image)
        XCTAssertLessThanOrEqual(try changedPixelCount(redone, reopened), 4, "Save/relaunch/reopen did not restore the drawn raster")
        XCTAssertGreaterThan(try changedPixelCount(before, reopened), 12, "Reopened project contains no visible stroke")
        capture(reopenedApp, name: "persisted-stroke-reopened")
    }

    /// A screenshot comparison of the actual decoded export preview proves the
    /// user-visible PNG changes with the document. It does not read app-sandbox
    /// bytes from the UI runner or claim an external destination received them.
    @MainActor
    func testPNGExportPreviewAndNativeShareCancellation() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        _ = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 8))

        try openExportPanel(app)
        try exportControl("studio.export.format.png", app: app, scrollUp: false).tap()
        try exportControl("studio.export.start", app: app).tap()
        let blankPreview = try waitForPNGPreview(app)
        let blankPixels = try exportPreviewPixels(blankPreview, app: app, name: "blank")
        XCTAssertEqual(exportInkMask(blankPixels).count, 0, "The fresh export must contain no red drawing")
        capture(app, name: "png-export-blank-preview")
        try closeExportPanel(app)

        // Draw on the actual canvas and create a second export from the changed
        // document. The preview is loaded from the returned PNG URL by the app.
        XCTAssertTrue(canvas.isHittable)
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.4))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6))
        start.press(forDuration: 0.05, thenDragTo: end)
        let undo = app.buttons["studio.undo"]
        XCTAssertTrue(expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: undo).waitUntilFulfilled(timeout: 5))
        try openExportPanel(app)
        try exportControl("studio.export.start", app: app).tap()
        let drawnPreview = try waitForPNGPreview(app)
        let drawnPixels = try exportPreviewPixels(drawnPreview, app: app, name: "drawn")
        XCTAssertGreaterThan(exportInkMask(drawnPixels).count, 12, "The actual PNG preview contains no red stroke")
        XCTAssertGreaterThan(try changedPixelCount(blankPixels, drawnPixels), 12,
                             "Drawing did not change the preview decoded from the actual exported PNG")
        XCTAssertTrue(app.staticTexts["frame_000000.png"].exists)
        capture(app, name: "png-export-drawn-preview")
        let share = try exportControl("studio.export.share", app: app)
        XCTAssertTrue(share.isEnabled); share.tap()

        // Save to Files is a native share action, not a button in our panel.
        // Assert its presentation but do not invoke a destination or upload.
        // The recorded iOS share hierarchy exposes file actions as cells in
        // its remote container, rather than buttons in the application panel.
        let nativeShare = app.otherElements["ShareSheet.RemoteContainerView"].firstMatch
        let saveToFiles = nativeShare.cells.matching(NSPredicate(format: "label == %@", "Save to Files")).firstMatch
        let sheetPresented = saveToFiles.waitForExistence(timeout: 10)
        capture(app, name: "png-native-share-sheet")
        captureHierarchy(app, name: "png-native-share-sheet-hierarchy")
        XCTAssertTrue(sheetPresented, "The native share sheet did not expose its file action")
        XCTAssertTrue(saveToFiles.isHittable, "The real file action is not reachable")
        let dismiss = nativeShare.buttons["header.closeButton"]
        XCTAssertTrue(dismiss.isHittable, "The recorded native share dismissal control is not reachable")
        dismiss.tap()
        // The completion callback can update our status before UIKit finishes
        // dismissing. Require the actual native presentation to disappear.
        let shareDismissed = expectation(for: NSPredicate(format: "exists == false"),
                                         evaluatedWith: dismiss).waitUntilFulfilled(timeout: 8)
        if !shareDismissed {
            capture(app, name: "png-share-dismissal-failed")
            captureHierarchy(app, name: "png-share-dismissal-failed-hierarchy")
        }
        XCTAssertTrue(shareDismissed, "The native share sheet did not finish dismissing")
        let status = app.staticTexts["studio.export.status"]
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "Sharing cancelled. Your export is still available."),
                                  evaluatedWith: status).waitUntilFulfilled(timeout: 8))
        let retainedPreview = try exportControl("studio.export.preview", app: app)
        var previousPreviewFrame = CGRect.null
        var stableSince = Date()
        let previewSettled = NSPredicate { _, _ in
            let frame = retainedPreview.frame
            guard !frame.isEmpty, app.frame.contains(frame), retainedPreview.isHittable else {
                previousPreviewFrame = .null; stableSince = Date(); return false
            }
            if frame != previousPreviewFrame {
                previousPreviewFrame = frame; stableSince = Date(); return false
            }
            return Date().timeIntervalSince(stableSince) >= 1
        }
        let settled = expectation(for: previewSettled, evaluatedWith: nil).waitUntilFulfilled(timeout: 8)
        if !settled {
            capture(app, name: "png-retained-preview-unsettled")
            captureHierarchy(app, name: "png-retained-preview-unsettled-hierarchy")
        }
        XCTAssertTrue(settled, "Retained PNG preview did not settle visibly after native sharing")
        let retainedPixels = try exportPreviewPixels(retainedPreview, app: app, name: "retained-after-share")
        XCTAssertGreaterThan(exportInkMask(retainedPixels).count, 12, "Cancelling sharing lost the exported stroke")
        XCTAssertEqual(unmatchedExportInk(drawnPixels, retainedPixels), 0,
                       "Cancelling sharing changed the exported content beyond one normalized pixel")
        XCTAssertTrue(try exportControl("studio.export.share", app: app).isEnabled,
                      "Cancelled sharing must leave real files available for retry")
        capture(app, name: "png-share-cancelled-files-retained")
    }

    @MainActor
    func testSpritesheetSizeErrorThenPNGExportRecovery() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        _ = try createProjectIfLibraryIsShown(app)
        let addFrame = app.buttons["studio.add-frame"]
        XCTAssertTrue(addFrame.waitForExistence(timeout: 8)); XCTAssertTrue(addFrame.isHittable)
        // Seven default portrait frames form a 3x3 sheet (18,662,400 pixels),
        // above the declared 16,777,216 limit. The PNG sequence stays in bounds.
        for _ in 0..<6 { addFrame.tap() }
        try openExportPanel(app)
        // Export initially selects MP4. Select the image format before checking
        // its PNG/timing description; the movie panel has its own description.
        try exportControl("studio.export.format.spritesheet", app: app, scrollUp: false).tap()
        // SwiftUI localizes numeric interpolation; the verified en_US UI uses
        // grouping separators while retaining the exact1080×1920 canvas.
        XCTAssertTrue(app.staticTexts["Original canvas · 1,080 × 1,920"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Lossless PNG · 7 frames")).firstMatch.exists)
        try exportControl("studio.export.start", app: app).tap()
        let status = app.staticTexts["studio.export.status"]
        XCTAssertTrue(expectation(for: NSPredicate(format: "label CONTAINS %@", "exceeds the current safe"),
                                  evaluatedWith: status).waitUntilFulfilled(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["studio.export.preview"].firstMatch.exists)
        XCTAssertFalse(app.buttons["studio.export.share"].exists,
                       "An export size error must not expose a fake ready file or share action")
        capture(app, name: "spritesheet-real-size-error")
        captureHierarchy(app, name: "spritesheet-size-error-hierarchy")

        try exportControl("studio.export.format.png", app: app, scrollUp: false).tap()
        try exportControl("studio.export.start", app: app).tap()
        _ = try waitForPNGPreview(app)
        XCTAssertTrue(app.staticTexts["7 PNG files + timing manifest"].exists)
        XCTAssertTrue(try exportControl("studio.export.share", app: app).isEnabled)
        capture(app, name: "png-export-after-size-error")
    }

    /// Real category/tag filtering, audition, explicit stop, add and saved playback.
    /// No audio fixture injection or enlarged execution allowance.
    @MainActor
    func testSoundLibraryTagsCountsPreviewStopAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let projectName = try createProjectIfLibraryIsShown(app)
        let open = app.buttons["studio.audio.open"]
        XCTAssertTrue(expectation(for: NSPredicate(format: "exists == true AND hittable == true"), evaluatedWith: open).waitUntilFulfilled(timeout: 8))
        open.tap()
        app.buttons["studio.audio.library.open"].tap()
        let catalogueCount = app.staticTexts["studio.audio.catalogue.count"]
        XCTAssertTrue(catalogueCount.waitForExistence(timeout: 8))
        XCTAssertEqual(catalogueCount.label, "2,127 offline sounds · CC0")
        let clipCount = app.staticTexts["studio.audio.clip-count"]
        XCTAssertEqual(clipCount.label, "0 clips")
        try audioLibraryButton("studio.audio.category.Impacts & Crashes", app: app).tap()
        let resultCount = app.staticTexts["studio.audio.search.count"]
        XCTAssertTrue(resultCount.waitForExistence(timeout: 5))
        XCTAssertEqual(resultCount.label, "128 matching sounds")
        // This alias is absent from every original title/category/author. The
        // result therefore requires the actual catalogue tags search path.
        let search = app.textFields["studio.audio.search"]
        search.tap(); search.typeText("collision\n")
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "128 matching sounds"), evaluatedWith: resultCount).waitUntilFulfilled(timeout: 5))
        search.tap(); search.typeText(" zzzz-no-sound\n")
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "0 matching sounds"), evaluatedWith: resultCount).waitUntilFulfilled(timeout: 5))
        XCTAssertTrue(app.staticTexts["studio.audio.search.empty"].exists)
        try audioLibraryButton("studio.audio.search.clear", app: app).tap()
        XCTAssertTrue(["", "Search sounds, tags, categories…"].contains(search.value as? String ?? "<missing>"), "Clear filters retained the query")
        XCTAssertFalse(resultCount.exists)
        _ = try audioLibraryButton("studio.audio.category.Impacts & Crashes", app: app)
        search.tap(); search.typeText("collision\n")
        XCTAssertTrue(resultCount.waitForExistence(timeout: 5))
        XCTAssertEqual(resultCount.label, "128 matching sounds", "Global tag search differs from its actual category")
        try audioLibraryButton("studio.audio.search.clear", app: app).tap()
        search.tap(); search.typeText("Key Lock Door 46\n")
        XCTAssertTrue(resultCount.waitForExistence(timeout: 5))
        XCTAssertEqual(resultCount.label, "1 matching sounds")
        let soundID = "fb438f90e074a2090b3e355222ec6ab54d10f559ae1ad137ddf825e9f2059f42"
        let preview = try audioLibraryButton("studio.audio.catalogue.preview." + soundID, app: app)
        XCTAssertEqual(preview.label, "Preview Key Lock Door 46")
        preview.tap()
        // The label follows playingClipID, assigned only after the real player
        // successfully starts. This 9.215-second asset leaves time to stop it.
        // Actual immutable AAC analysis must finish before AVAudioPlayer starts.
        // The recorded simulator attempt was still analyzing at the former 5s
        // deadline. Fail promptly on a real error; busy is never playback proof.
        let previewNotice = app.staticTexts["studio.audio.notice"]
        XCTAssertTrue(expectation(for: NSPredicate { _, _ in
            previewNotice.exists || (preview.exists && preview.isEnabled && preview.label == "Stop preview Key Lock Door 46")
        }, evaluatedWith: nil).waitUntilFulfilled(timeout: 15))
        XCTAssertFalse(previewNotice.exists, "Actual sound preview reported an error")
        XCTAssertEqual(preview.label, "Stop preview Key Lock Door 46")
        XCTAssertEqual(clipCount.label, "0 clips", "Audition added a project clip")
        preview.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "Preview Key Lock Door 46"), evaluatedWith: preview).waitUntilFulfilled(timeout: 3))
        XCTAssertEqual(clipCount.label, "0 clips")
        capture(app, name: "audio-tag-search-preview-stopped")
        try audioLibraryButton("studio.audio.catalogue.add." + soundID, app: app).tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "1 clips"), evaluatedWith: clipCount).waitUntilFulfilled(timeout: 10))
        XCTAssertFalse(app.staticTexts["studio.audio.notice"].exists)
        app.buttons["studio.audio.library.close"].tap()
        XCTAssertFalse(search.exists)
        XCTAssertTrue(app.buttons["studio.audio.timelinePlay"].isHittable)
        app.buttons["studio.audio.close"].tap()
        let save = app.buttons["studio.save"]
        XCTAssertTrue(save.isHittable); save.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "Saved"), evaluatedWith: save).waitUntilFulfilled(timeout: 8))
        app.terminate()
        let reopened = try launchGuestStudio()
        defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let reopenedAudio = reopened.buttons["studio.audio.open"]
        XCTAssertTrue(reopenedAudio.waitForExistence(timeout: 5)); reopenedAudio.tap()
        XCTAssertEqual(reopened.staticTexts["studio.audio.clip-count"].label, "1 clips")
        XCTAssertFalse(reopened.staticTexts["studio.audio.timelineNotice"].exists)
        reopened.buttons["studio.audio.timelinePlay"].tap()
        XCTAssertTrue(reopened.staticTexts["00:09.22"].waitForExistence(timeout: 15), "Saved auditioned sound failed real playback after cold reopen")
        capture(reopened, name: "audio-tag-selected-sound-cold-reopen")
    }

    @MainActor
    func testExpandedAACLibrarySoundPlaybackAndOfflineReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let projectName = try createProjectIfLibraryIsShown(app)
        let open = app.buttons["studio.audio.open"]
        let ready = expectation(for: NSPredicate(format: "exists == true AND hittable == true"), evaluatedWith: open)
        XCTAssertTrue(ready.waitUntilFulfilled(timeout: 8)); open.tap()
        let library = app.buttons["studio.audio.library.open"]
        XCTAssertTrue(library.waitForExistence(timeout: 5)); library.tap()
        let catalogueCount = app.staticTexts["studio.audio.catalogue.count"]
        XCTAssertTrue(catalogueCount.waitForExistence(timeout: 8), "Expanded catalogue never finished loading")
        XCTAssertEqual(catalogueCount.label, "2,127 offline sounds · CC0")
        let search = app.textFields["studio.audio.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Card Fan 1 Kenney\n")
        try audioLibraryButton("studio.audio.catalogue.add.7a6ba4661a10ff06cd0c8c758f671bb4347fa6b4d26e23b6e7cb9165ee9aa24a", app: app).tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "1 clips"), evaluatedWith: app.staticTexts["studio.audio.clip-count"]).waitUntilFulfilled(timeout: 10))
        capture(app, name: "audio-expanded-aac-library")
        app.buttons["studio.audio.library.close"].tap()
        let play = app.buttons["studio.audio.timelinePlay"]
        XCTAssertTrue(play.isHittable && play.isEnabled); play.tap()
        // The measured AAC lasts 0.720816 seconds; wait for actual player completion.
        XCTAssertTrue(app.staticTexts["00:00.72"].waitForExistence(timeout: 8), "New AAC sound never reached its real playback end")
        app.buttons["studio.audio.close"].tap()
        let save = app.buttons["studio.save"]
        XCTAssertTrue(save.isHittable); save.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "Saved"), evaluatedWith: save).waitUntilFulfilled(timeout: 8))
        app.terminate()
        let reopened = try launchGuestStudio()
        defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let reopenedAudio = reopened.buttons["studio.audio.open"]
        XCTAssertTrue(reopenedAudio.waitForExistence(timeout: 5)); reopenedAudio.tap()
        XCTAssertEqual(reopened.staticTexts["studio.audio.clip-count"].label, "1 clips")
        XCTAssertFalse(reopened.staticTexts["studio.audio.timelineNotice"].exists)
        let replay = reopened.buttons["studio.audio.timelinePlay"]
        XCTAssertTrue(replay.isHittable && replay.isEnabled); replay.tap()
        XCTAssertTrue(reopened.staticTexts["00:00.72"].waitForExistence(timeout: 8), "Saved AAC audio did not play after cold reopening")
        capture(reopened, name: "audio-expanded-aac-cold-reopen")
    }

    @MainActor
    func testAudioClipDuplicateUndoAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let projectName = try createProjectIfLibraryIsShown(app)
        func openAudio(_ target: XCUIApplication) {
            let open = target.buttons["studio.audio.open"]
            XCTAssertTrue(expectation(for: NSPredicate(format: "exists == true AND hittable == true"), evaluatedWith: open).waitUntilFulfilled(timeout: 8))
            open.tap()
        }
        func clipCount(_ expected: String, in target: XCUIApplication) {
            XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", expected), evaluatedWith: target.staticTexts["studio.audio.clip-count"]).waitUntilFulfilled(timeout: 10))
        }
        openAudio(app)
        let library = app.buttons["studio.audio.library.open"]
        XCTAssertTrue(library.waitForExistence(timeout: 5)); library.tap()
        let search = app.textFields["studio.audio.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Wood Cracking 02\n")
        try audioLibraryButton("studio.audio.catalogue.add.3b7a688684cf8d75a180aa50edd9f51e159635cb25432e82d3f32d9d173299e1", app: app).tap()
        clipCount("1 clips", in: app)
        app.buttons["studio.audio.library.close"].tap()
        let duplicate = app.buttons["studio.audio.duplicate"]
        let scroll = app.scrollViews["studio.audio.compact.scroll"]
        for _ in 0..<4 { if duplicate.exists && duplicate.isHittable { break }; scroll.swipeUp(velocity: .slow) }
        XCTAssertTrue(duplicate.exists && duplicate.isHittable)
        XCTAssertTrue(expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: duplicate).waitUntilFulfilled(timeout: 8)); duplicate.tap()
        clipCount("2 clips", in: app)
        XCTAssertTrue(app.staticTexts["studio.audio.clip-timing"].label.contains("Start 0.25s"), "Duplicate did not begin at selected source end")
        let zoomIn = app.buttons["studio.audio.zoom-in"]
        for _ in 0..<4 { if zoomIn.exists && zoomIn.isHittable { break }; scroll.swipeDown(velocity: .slow) }
        XCTAssertTrue(zoomIn.exists && zoomIn.isHittable)
        let clips = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "studio.audio.clip."))
        func adjacentClipFrames() -> [CGRect] {
            let frames = clips.allElementsBoundByIndex.map(\.frame).sorted { $0.minX < $1.minX }
            XCTAssertEqual(frames.count, 2)
            guard frames.count == 2 else { return frames }
            XCTAssertGreaterThan(frames[0].width, 0)
            XCTAssertLessThanOrEqual(frames[0].maxX, frames[1].minX + 1, "Short clip cards overlap their real timeline positions")
            XCTAssertEqual(frames[0].maxX, frames[1].minX, accuracy: 1, "Adjacent equal-duration clips must meet at their actual boundary")
            return frames
        }
        let originalFrames = adjacentClipFrames()
        capture(app, name: "audio-duplicate-selected-after-source")
        zoomIn.tap();zoomIn.tap()
        XCTAssertEqual(app.staticTexts["studio.audio.zoom-value"].label, "400%")
        let zoomedFrames = adjacentClipFrames()
        if originalFrames.count == 2 && zoomedFrames.count == 2 {
            XCTAssertEqual(zoomedFrames[0].width, originalFrames[0].width * 4, accuracy: 2)
        }
        XCTAssertTrue(app.staticTexts["studio.audio.clip-timing"].label.contains("Start 0.25s"), "Timeline zoom changed the saved clip timing")
        capture(app, name: "audio-duplicate-timing-at-four-times-zoom")
        app.buttons["studio.audio.zoom-out"].tap();app.buttons["studio.audio.zoom-out"].tap()
        let firstID = clips.allElementsBoundByIndex.sorted { $0.frame.minX < $1.frame.minX }.first?.identifier
        XCTAssertNotNil(firstID)
        app.buttons["studio.audio.clip-picker"].tap()
        if let firstID {
            let choose = app.buttons[firstID.replacingOccurrences(of: "studio.audio.clip.", with: "studio.audio.select-clip.")]
            XCTAssertTrue(choose.waitForExistence(timeout: 5) && choose.isHittable)
            choose.tap()
        }
        XCTAssertTrue(app.staticTexts["studio.audio.clip-timing"].label.contains("Start 0.00s"), "Clip picker did not select the original short clip")
        for _ in 0..<4 { if app.buttons["studio.audio.close"].isHittable { break }; scroll.swipeDown(velocity: .slow) }
        app.buttons["studio.audio.close"].tap()
        app.buttons["studio.undo"].tap();openAudio(app);clipCount("1 clips", in: app)
        app.buttons["studio.audio.close"].tap();app.buttons["studio.redo"].tap()
        openAudio(app);clipCount("2 clips", in: app)
        let play = app.buttons["studio.audio.timelinePlay"]
        XCTAssertTrue(play.isHittable && play.isEnabled);play.tap()
        // Two adjacent copies of the pinned0.2508125s source play through the
        // actual mixed AVAudioPlayer clock, rather than a fabricated status.
        XCTAssertTrue(app.staticTexts["00:00.50"].waitForExistence(timeout: 12))
        app.buttons["studio.audio.close"].tap()
        let save = app.buttons["studio.save"];XCTAssertTrue(save.isHittable);save.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "Saved"), evaluatedWith: save).waitUntilFulfilled(timeout: 8))
        app.terminate()
        let reopened = try launchGuestStudio();defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8));project.tap();openAudio(reopened);clipCount("2 clips", in: reopened)
        XCTAssertFalse(reopened.staticTexts["studio.audio.timelineNotice"].exists)
        capture(reopened, name: "audio-duplicate-cold-reopened")
    }

    @MainActor
    func testAudioTrackVolumePreservesClipSettingsUndoAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let projectName = try createProjectIfLibraryIsShown(app)
        // Run35521875012 tapped Audio at y709.66 during new-project keyboard
        // dismissal; its settled center was y817.05. Wait on real keyboard and
        // canvas geometry before the single normal accessibility tap.
        XCTAssertTrue(expectation(for: NSPredicate(format: "exists == false"),
                                  evaluatedWith: app.keyboards.firstMatch).waitUntilFulfilled(timeout: 5))
        try waitForStableCanvas(app.descendants(matching: .any)["studio.canvas"].firstMatch)
        func reveal(_ element: XCUIElement, in target: XCUIApplication, down: Bool) throws {
            let scroll = target.scrollViews["studio.audio.compact.scroll"]
            for _ in 0..<4 {
                if element.exists && element.isHittable { break }
                if down { scroll.swipeUp(velocity: .slow) } else { scroll.swipeDown(velocity: .slow) }
            }
            XCTAssertTrue(element.exists && element.isHittable, "Audio volume control is not reachable")
            XCTAssertTrue(expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: element).waitUntilFulfilled(timeout: 8))
        }
        func openAndSelect(_ target: XCUIApplication) throws {
            let audio = target.buttons["studio.audio.open"]
            XCTAssertTrue(audio.waitForExistence(timeout: 8) && audio.isHittable); audio.tap()
            let picker = target.buttons["studio.audio.clip-picker"]
            try reveal(picker, in: target, down: false); picker.tap()
            let clip = target.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "studio.audio.select-clip.")).firstMatch
            XCTAssertTrue(clip.waitForExistence(timeout: 5) && clip.isHittable); clip.tap()
        }
        func closeAudio(_ target: XCUIApplication) throws {
            let close = target.buttons["studio.audio.close"]
            try reveal(close, in: target, down: false); close.tap()
        }
        func gain(_ target: XCUIApplication) throws -> XCUIElement {
            let slider = target.sliders["studio.audio.track-volume.1"]
            try reveal(slider, in: target, down: true); return slider
        }
        let audio = app.buttons["studio.audio.open"]
        XCTAssertTrue(audio.exists && audio.isHittable); audio.tap()
        let library = app.buttons["studio.audio.library.open"]
        XCTAssertTrue(library.waitForExistence(timeout: 5) && library.isHittable); library.tap()
        let search = app.textFields["studio.audio.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Wood Cracking 02\n")
        try audioLibraryButton("studio.audio.catalogue.add.3b7a688684cf8d75a180aa50edd9f51e159635cb25432e82d3f32d9d173299e1", app: app).tap()
        XCTAssertTrue(app.staticTexts["studio.audio.clip-count"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts["studio.audio.clip-count"].label, "1 clips")
        app.buttons["studio.audio.library.close"].tap()
        let clipMute = app.buttons["studio.audio.clip-mute"]
        try reveal(clipMute, in: app, down: true); clipMute.tap()
        XCTAssertEqual(clipMute.label, "Unmute selected clip")
        let clipSlider = app.sliders["studio.audio.volume"]
        try reveal(clipSlider, in: app, down: true)
        XCTAssertEqual(clipSlider.value as? String, "80 percent")
        clipSlider.adjust(toNormalizedSliderPosition: 0.4)
        XCTAssertTrue(expectation(for: NSPredicate(format: "value != %@", "80 percent"), evaluatedWith: clipSlider).waitUntilFulfilled(timeout: 8))
        let clipVolume = try XCTUnwrap(clipSlider.value as? String)
        let clipPercent = try XCTUnwrap(Int(clipVolume.components(separatedBy: " ")[0]))
        XCTAssertTrue((35...45).contains(clipPercent), "Clip slider did not commit the requested region")
        XCTAssertEqual(app.staticTexts["studio.audio.clip-volume-value"].label, "\(clipPercent)%")
        XCTAssertEqual(clipMute.label, "Unmute selected clip")
        let slider = try gain(app)
        XCTAssertEqual(slider.value as? String, "100 percent")
        slider.adjust(toNormalizedSliderPosition: 0.25)
        XCTAssertTrue(expectation(for: NSPredicate(format: "value != %@", "100 percent"), evaluatedWith: slider).waitUntilFulfilled(timeout: 8))
        let savedValue = try XCTUnwrap(slider.value as? String)
        let percent = try XCTUnwrap(Int(savedValue.components(separatedBy: " ")[0]))
        XCTAssertTrue((20...30).contains(percent), "Track slider did not commit the requested region")
        XCTAssertEqual(app.sliders["studio.audio.volume"].value as? String, clipVolume)
        XCTAssertEqual(clipMute.label, "Unmute selected clip")
        capture(app, name: "audio-track-volume-independent-of-clip")
        try closeAudio(app); app.buttons["studio.undo"].tap(); try openAndSelect(app)
        XCTAssertEqual(try gain(app).value as? String, "100 percent")
        try closeAudio(app); app.buttons["studio.redo"].tap(); try openAndSelect(app)
        XCTAssertEqual(try gain(app).value as? String, savedValue)
        XCTAssertEqual(app.sliders["studio.audio.volume"].value as? String, clipVolume)
        XCTAssertEqual(app.buttons["studio.audio.clip-mute"].label, "Unmute selected clip")
        try closeAudio(app)
        let save = app.buttons["studio.save"]; save.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "Saved"), evaluatedWith: save).waitUntilFulfilled(timeout: 8))
        app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap(); try openAndSelect(reopened)
        XCTAssertEqual(try gain(reopened).value as? String, savedValue)
        XCTAssertEqual(reopened.sliders["studio.audio.volume"].value as? String, clipVolume)
        XCTAssertEqual(reopened.buttons["studio.audio.clip-mute"].label, "Unmute selected clip")
        capture(reopened, name: "audio-track-volume-cold-reopened")
    }

    @MainActor
    func testAudioTrackMutePreservesClipMuteUndoAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let projectName = try createProjectIfLibraryIsShown(app)
        func reveal(_ identifier: String, in target: XCUIApplication, towardBottom: Bool) throws -> XCUIElement {
            let button = target.buttons[identifier]
            let scroll = target.scrollViews["studio.audio.compact.scroll"]
            for _ in 0..<4 {
                if button.exists && button.isHittable { break }
                if towardBottom { scroll.swipeUp(velocity: .slow) }
                else { scroll.swipeDown(velocity: .slow) }
            }
            XCTAssertTrue(button.exists && button.isHittable, "Audio control unavailable: \(identifier)")
            XCTAssertTrue(expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: button).waitUntilFulfilled(timeout: 8))
            return button
        }
        func openAudio(_ target: XCUIApplication) throws {
            let open = target.buttons["studio.audio.open"]
            XCTAssertTrue(open.waitForExistence(timeout: 8) && open.isHittable); open.tap()
        }
        func checkBus(_ expected: String, in target: XCUIApplication) {
            XCTAssertTrue(expectation(for: NSPredicate(format: "value == %@", expected), evaluatedWith: target.buttons["studio.audio.track-mute.1"]).waitUntilFulfilled(timeout: 8))
        }
        try openAudio(app)
        app.buttons["studio.audio.library.open"].tap()
        let search = app.textFields["studio.audio.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Wood Cracking 02\n")
        try audioLibraryButton("studio.audio.catalogue.add.3b7a688684cf8d75a180aa50edd9f51e159635cb25432e82d3f32d9d173299e1", app: app).tap()
        XCTAssertTrue(app.staticTexts["studio.audio.clip-count"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts["studio.audio.clip-count"].label, "1 clips")
        app.buttons["studio.audio.library.close"].tap()
        try reveal("studio.audio.clip-mute", in: app, towardBottom: true).tap()
        XCTAssertEqual(app.buttons["studio.audio.clip-mute"].label, "Unmute selected clip")
        try reveal("studio.audio.track-mute.1", in: app, towardBottom: false).tap(); checkBus("Muted", in: app)
        try reveal("studio.audio.track-mute.1", in: app, towardBottom: false).tap(); checkBus("Audible", in: app)
        _ = try reveal("studio.audio.clip-mute", in: app, towardBottom: true)
        XCTAssertEqual(app.buttons["studio.audio.clip-mute"].label, "Unmute selected clip", "Track toggle destroyed the individual mute choice")
        try reveal("studio.audio.close", in: app, towardBottom: false).tap()
        app.buttons["studio.undo"].tap(); try openAudio(app); checkBus("Muted", in: app)
        try reveal("studio.audio.close", in: app, towardBottom: false).tap()
        app.buttons["studio.redo"].tap(); try openAudio(app); checkBus("Audible", in: app)
        try reveal("studio.audio.track-mute.1", in: app, towardBottom: false).tap(); checkBus("Muted", in: app)
        _ = try reveal("studio.audio.clip-mute", in: app, towardBottom: true)
        XCTAssertEqual(app.buttons["studio.audio.clip-mute"].label, "Unmute selected clip")
        XCTAssertEqual(app.staticTexts["studio.audio.selected-track-muted"].label, "Track 1 is muted")
        capture(app, name: "audio-track-and-clip-muted-independently")
        try reveal("studio.audio.close", in: app, towardBottom: false).tap()
        let save = app.buttons["studio.save"]; save.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "Saved"), evaluatedWith: save).waitUntilFulfilled(timeout: 8))
        app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap(); try openAudio(reopened)
        checkBus("Muted", in: reopened)
        try reveal("studio.audio.clip-picker", in: reopened, towardBottom: false).tap()
        let choose = reopened.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "studio.audio.select-clip.")).firstMatch
        XCTAssertTrue(choose.waitForExistence(timeout: 5) && choose.isHittable); choose.tap()
        _ = try reveal("studio.audio.clip-mute", in: reopened, towardBottom: true)
        XCTAssertEqual(reopened.buttons["studio.audio.clip-mute"].label, "Unmute selected clip")
        XCTAssertEqual(reopened.staticTexts["studio.audio.selected-track-muted"].label, "Track 1 is muted")
        try reveal("studio.audio.track-mute.1", in: reopened, towardBottom: false).tap(); checkBus("Audible", in: reopened)
        _ = try reveal("studio.audio.clip-mute", in: reopened, towardBottom: true)
        XCTAssertEqual(reopened.buttons["studio.audio.clip-mute"].label, "Unmute selected clip", "Reopened track toggle revived a muted clip")
        capture(reopened, name: "audio-track-unmuted-clip-stays-muted-after-cold-reopen")
    }

    @MainActor
    func testAudioFadesCancelApplyUndoAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let projectName = try createProjectIfLibraryIsShown(app)
        // Run35521875012 tapped Audio at y709.66 during new-project keyboard
        // dismissal; its settled center was y817.05. Wait on real keyboard and
        // canvas geometry before the single normal accessibility tap.
        XCTAssertTrue(expectation(for: NSPredicate(format: "exists == false"),
                                  evaluatedWith: app.keyboards.firstMatch).waitUntilFulfilled(timeout: 5))
        try waitForStableCanvas(app.descendants(matching: .any)["studio.canvas"].firstMatch)
        let scroll = app.scrollViews["studio.audio.compact.scroll"]
        func reveal(_ element: XCUIElement) {
            for _ in 0..<4 { if element.exists && element.isHittable { break };scroll.swipeUp(velocity: .slow) }
            XCTAssertTrue(element.exists && element.isHittable)
        }
        func replace(_ identifier: String, with text: String) {
            let field = app.textFields[identifier];reveal(field);field.tap()
            let previous = field.value as? String ?? ""
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count) + text)
        }
        func openAudio() { app.buttons["studio.audio.open"].tap() }
        func closeAudio() {
            let close = app.buttons["studio.audio.close"]
            for _ in 0..<4 { if close.exists && close.isHittable { break };scroll.swipeDown(velocity: .slow) }
            XCTAssertTrue(close.isHittable);close.tap()
        }
        openAudio()
        let library = app.buttons["studio.audio.library.open"]
        XCTAssertTrue(library.waitForExistence(timeout: 5) && library.isHittable); library.tap()
        let search = app.textFields["studio.audio.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5));search.tap();search.typeText("Wood Cracking 02\n")
        try audioLibraryButton("studio.audio.catalogue.add.3b7a688684cf8d75a180aa50edd9f51e159635cb25432e82d3f32d9d173299e1", app: app).tap()
        app.buttons["studio.audio.library.close"].tap()
        let status = app.staticTexts["studio.audio.fades.status"]
        let open = app.buttons["studio.audio.fades.open"];reveal(open);open.tap()
        replace("studio.audio.fades.in", with: "10")
        let apply = app.buttons["studio.audio.fades.apply"];reveal(apply);apply.tap()
        XCTAssertTrue(app.staticTexts["studio.audio.fades.notice"].waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "No fades", "Invalid fade changed the clip")
        let cancel = app.buttons["studio.audio.fades.cancel"];reveal(cancel);cancel.tap()
        XCTAssertFalse(app.textFields["studio.audio.fades.in"].exists)
        XCTAssertEqual(status.label, "No fades", "Cancel applied a draft")
        reveal(open);open.tap()
        replace("studio.audio.fades.in", with: "0.05")
        replace("studio.audio.fades.out", with: "0.10")
        reveal(apply);apply.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "Source fades on"), evaluatedWith: status).waitUntilFulfilled(timeout: 8))
        capture(app, name: "audio-fades-applied")
        closeAudio();app.buttons["studio.undo"].tap();openAudio()
        XCTAssertEqual(status.label, "No fades", "One Undo did not restore both fades")
        closeAudio();app.buttons["studio.redo"].tap();openAudio()
        XCTAssertEqual(status.label, "Source fades on")
        closeAudio();let save = app.buttons["studio.save"];save.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "Saved"), evaluatedWith: save).waitUntilFulfilled(timeout: 8))
        app.terminate()
        let reopened = try launchGuestStudio();defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8));project.tap()
        reopened.buttons["studio.audio.open"].tap()
        XCTAssertEqual(reopened.staticTexts["studio.audio.clip-count"].label, "1 clips")
        let savedClip = reopened.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "studio.audio.clip.")).firstMatch
        XCTAssertTrue(savedClip.waitForExistence(timeout: 8) && savedClip.isHittable)
        savedClip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let reopen = reopened.buttons["studio.audio.fades.open"]
        let savedScroll = reopened.scrollViews["studio.audio.compact.scroll"]
        for _ in 0..<4 { if reopen.exists && reopen.isHittable { break };savedScroll.swipeUp(velocity: .slow) }
        XCTAssertTrue(reopen.isHittable);reopen.tap()
        XCTAssertEqual(reopened.textFields["studio.audio.fades.in"].value as? String, "0.05")
        XCTAssertEqual(reopened.textFields["studio.audio.fades.out"].value as? String, "0.1")
        capture(reopened, name: "audio-fades-cold-reopened")
    }

    @MainActor
    func testAudioNumericTrimCancelApplyUndoAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let projectName = try createProjectIfLibraryIsShown(app)
        func openAudio() {
            let open = app.buttons["studio.audio.open"]
            XCTAssertTrue(open.waitForExistence(timeout: 8));open.tap()
        }
        let scroll = app.scrollViews["studio.audio.compact.scroll"]
        func reveal(_ element: XCUIElement) {
            for _ in 0..<4 { if element.exists && element.isHittable { break };scroll.swipeUp(velocity: .slow) }
            XCTAssertTrue(element.exists && element.isHittable)
        }
        func replace(_ identifier: String, with text: String) {
            let field = app.textFields[identifier];reveal(field);field.tap()
            let previous = field.value as? String ?? ""
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count) + text)
        }
        func closeAudio() {
            let close = app.buttons["studio.audio.close"]
            for _ in 0..<4 { if close.exists && close.isHittable { break };scroll.swipeDown(velocity: .slow) }
            XCTAssertTrue(close.isHittable);close.tap()
        }
        openAudio()
        app.buttons["studio.audio.library.open"].tap()
        let search = app.textFields["studio.audio.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5));search.tap();search.typeText("Wood Cracking 02\n")
        try audioLibraryButton("studio.audio.catalogue.add.3b7a688684cf8d75a180aa50edd9f51e159635cb25432e82d3f32d9d173299e1", app: app).tap()
        app.buttons["studio.audio.library.close"].tap()
        let timing = app.staticTexts["studio.audio.clip-timing"]
        let before = timing.label
        let openTrim = app.buttons["studio.audio.trim.open"];reveal(openTrim);openTrim.tap()
        replace("studio.audio.trim.source", with: "10")
        let apply = app.buttons["studio.audio.trim.apply"];reveal(apply);apply.tap()
        XCTAssertTrue(app.staticTexts["studio.audio.trim.notice"].waitForExistence(timeout: 5), "Out-of-source trim was not rejected")
        XCTAssertEqual(timing.label, before, "Invalid draft changed clip timing")
        let cancel = app.buttons["studio.audio.trim.cancel"];reveal(cancel);cancel.tap()
        XCTAssertFalse(app.textFields["studio.audio.trim.source"].exists)
        XCTAssertEqual(timing.label, before, "Cancel changed the original")
        reveal(openTrim);openTrim.tap()
        replace("studio.audio.trim.source", with: "0.05")
        replace("studio.audio.trim.duration", with: "0.10")
        reveal(apply);apply.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "label CONTAINS %@", "Source 0.05s · 0.10s"), evaluatedWith: timing).waitUntilFulfilled(timeout: 8))
        capture(app, name: "audio-numeric-trim-applied")
        closeAudio();app.buttons["studio.undo"].tap();openAudio()
        XCTAssertEqual(timing.label, before, "One Undo did not restore both fields")
        closeAudio();app.buttons["studio.redo"].tap();openAudio()
        XCTAssertTrue(timing.label.contains("Source 0.05s · 0.10s"))
        closeAudio()
        let save = app.buttons["studio.save"];save.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "Saved"), evaluatedWith: save).waitUntilFulfilled(timeout: 8))
        app.terminate()
        let reopened = try launchGuestStudio();defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8));project.tap()
        reopened.buttons["studio.audio.open"].tap()
        XCTAssertEqual(reopened.staticTexts["studio.audio.clip-count"].label, "1 clips")
        XCTAssertFalse(reopened.staticTexts["studio.audio.timelineNotice"].exists)
        let savedClip = reopened.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "studio.audio.clip.")).firstMatch
        XCTAssertTrue(savedClip.waitForExistence(timeout: 8) && savedClip.isHittable)
        savedClip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(reopened.staticTexts["studio.audio.clip-timing"].label.contains("Source 0.05s · 0.10s"), "Cold reopen lost the applied trim values")
        capture(reopened, name: "audio-numeric-trim-cold-reopened")
    }

    @MainActor
    func testAudioClipSplitUndoAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let projectName = try createProjectIfLibraryIsShown(app)
        func openAudio(_ target: XCUIApplication) {
            let open = target.buttons["studio.audio.open"]
            XCTAssertTrue(expectation(for: NSPredicate(format: "exists == true AND hittable == true"), evaluatedWith: open).waitUntilFulfilled(timeout: 8))
            open.tap()
        }
        func clipCount(_ expected: String, in target: XCUIApplication) {
            XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", expected), evaluatedWith: target.staticTexts["studio.audio.clip-count"]).waitUntilFulfilled(timeout: 10))
        }
        openAudio(app)
        let library = app.buttons["studio.audio.library.open"]
        XCTAssertTrue(library.waitForExistence(timeout: 5));library.tap()
        let search = app.textFields["studio.audio.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5));search.tap();search.typeText("Wood Cracking 02\n")
        try audioLibraryButton("studio.audio.catalogue.add.3b7a688684cf8d75a180aa50edd9f51e159635cb25432e82d3f32d9d173299e1", app: app).tap()
        clipCount("1 clips", in: app)
        app.buttons["studio.audio.library.close"].tap()
        let split = app.buttons["studio.audio.split"]
        XCTAssertTrue(split.exists);XCTAssertFalse(split.isEnabled, "Clip start cannot be split into an empty fragment")
        let ruler = app.descendants(matching: .any).matching(identifier: "studio.audio.playhead-ruler").firstMatch
        XCTAssertTrue(expectation(for: NSPredicate(format: "exists == true AND hittable == true"), evaluatedWith: ruler).waitUntilFulfilled(timeout: 8))
        // Tap the real 110pt/sec timeline near the middle of the 0.2508125s sound.
        ruler.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 13.75, dy: 13)).tap()
        let scroll = app.scrollViews["studio.audio.compact.scroll"]
        for _ in 0..<4 { if split.exists && split.isHittable { break };scroll.swipeUp(velocity: .slow) }
        XCTAssertTrue(split.exists && split.isHittable)
        XCTAssertTrue(expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: split).waitUntilFulfilled(timeout: 8));split.tap()
        clipCount("2 clips", in: app)
        let timing = app.staticTexts["studio.audio.clip-timing"].label
        XCTAssertNotNil(timing.range(of: #"Start 0\.1[0-5]s · Source 0\.1[0-5]s · 0\.1[0-5]s"#, options: .regularExpression), "The right half did not retain the playhead/source position: \(timing)")
        capture(app, name: "audio-split-right-half-selected")
        for _ in 0..<4 { if app.buttons["studio.audio.close"].isHittable { break };scroll.swipeDown(velocity: .slow) }
        app.buttons["studio.audio.close"].tap()
        app.buttons["studio.undo"].tap();openAudio(app);clipCount("1 clips", in: app)
        app.buttons["studio.audio.close"].tap();app.buttons["studio.redo"].tap()
        openAudio(app);clipCount("2 clips", in: app)
        let play = app.buttons["studio.audio.timelinePlay"]
        XCTAssertTrue(play.isHittable && play.isEnabled);play.tap()
        XCTAssertTrue(app.staticTexts["00:00.25"].waitForExistence(timeout: 12), "Actual mixed player did not reach the unchanged clip end")
        app.buttons["studio.audio.close"].tap()
        let save = app.buttons["studio.save"];XCTAssertTrue(save.isHittable);save.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "Saved"), evaluatedWith: save).waitUntilFulfilled(timeout: 8))
        app.terminate()
        let reopened = try launchGuestStudio();defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8));project.tap();openAudio(reopened);clipCount("2 clips", in: reopened)
        XCTAssertFalse(reopened.staticTexts["studio.audio.timelineNotice"].exists)
        capture(reopened, name: "audio-split-cold-reopened")
    }

    @MainActor
    func testBundledSoundLibraryMixAndOfflineReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let projectName = try createProjectIfLibraryIsShown(app)
        let open = app.buttons["studio.audio.open"]
        // Creation dismisses a native sheet. Wait for the real control to become
        // reachable; the previous failure captured an empty transition snapshot.
        let audioReady = expectation(for: NSPredicate(format: "exists == true AND hittable == true"), evaluatedWith: open)
        XCTAssertTrue(audioReady.waitUntilFulfilled(timeout: 8), "Studio audio did not become reachable after project creation")
        open.tap()
        let library = app.buttons["studio.audio.library.open"]
        XCTAssertTrue(library.waitForExistence(timeout: 5)); library.tap()
        let search = app.textFields["studio.audio.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Card Shuffle\n")
        let addID = "studio.audio.catalogue.add.f669c1b635f26e53e0d51f9f7abba2a6a3e499438095f89433ce7400ec74bde4"
        let count = app.staticTexts["studio.audio.clip-count"]
        for expected in ["1 clips", "2 clips"] {
            try audioLibraryButton(addID, app: app).tap()
            XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", expected), evaluatedWith: count).waitUntilFulfilled(timeout: 10))
        }
        capture(app, name: "audio-bundled-library-two-clips")
        app.buttons["studio.audio.library.close"].tap()
        let play = app.buttons["studio.audio.timelinePlay"]
        XCTAssertTrue(play.isHittable && play.isEnabled); play.tap()
        // This is the real AVAudioPlayer completion time for the integrity-pinned
        // 3.063492-second file, not a sleep followed by a fabricated success label.
        XCTAssertTrue(app.staticTexts["00:03.06"].waitForExistence(timeout: 12), "Mixed playback never reached the actual source end")
        let volume = app.sliders["studio.audio.volume"]
        XCTAssertTrue(volume.isHittable); volume.adjust(toNormalizedSliderPosition: 0.4)
        XCTAssertTrue(app.buttons["Mute selected clip"].isHittable)
        app.buttons["Mute selected clip"].tap()
        XCTAssertTrue(app.buttons["Unmute selected clip"].waitForExistence(timeout: 3))
        app.buttons["Unmute selected clip"].tap()
        capture(app, name: "audio-real-mix-selected-clip")
        app.buttons["studio.audio.close"].tap()
        let save = app.buttons["studio.save"]
        XCTAssertTrue(save.isHittable); save.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "Saved"), evaluatedWith: save).waitUntilFulfilled(timeout: 8))
        app.terminate()
        let reopened = try launchGuestStudio()
        defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        XCTAssertTrue(reopened.buttons["studio.audio.open"].waitForExistence(timeout: 5)); reopened.buttons["studio.audio.open"].tap()
        XCTAssertEqual(reopened.staticTexts["studio.audio.clip-count"].label, "2 clips", "Cold reopen lost saved library sounds")
        XCTAssertFalse(reopened.staticTexts["studio.audio.timelineNotice"].exists)
        let labels = reopened.descendants(matching: .any)["studio.audio.track-labels"].firstMatch
        let lanes = reopened.scrollViews["studio.audio.lanes"]
        XCTAssertTrue(labels.exists); XCTAssertTrue(lanes.exists)
        XCTAssertEqual(labels.frame.width, 44, accuracy: 1, "Track labels stole the timeline width")
        XCTAssertEqual(labels.frame.minY, lanes.frame.minY, accuracy: 1, "Track labels detached from the lanes")
        XCTAssertEqual(labels.frame.maxX, lanes.frame.minX, accuracy: 1, "Timeline has an expanding gutter")
        capture(reopened, name: "audio-offline-cold-reopen")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(expectation(for: NSPredicate { _, _ in reopened.frame.width > reopened.frame.height }, evaluatedWith: nil).waitUntilFulfilled(timeout: 8))
        let compact = reopened.scrollViews["studio.audio.compact.scroll"]
        XCTAssertTrue(compact.waitForExistence(timeout: 5), "Short audio layouts must scroll instead of clipping controls")
        XCTAssertTrue(reopened.buttons["studio.audio.close"].isHittable)
        compact.swipeUp(velocity: .slow)
        XCTAssertTrue(reopened.buttons["+ Add Sound"].isHittable, "Landscape audio footer is inaccessible")
        capture(reopened, name: "audio-landscape-scroll")
    }

    @MainActor
    private func audioLibraryButton(_ identifier: String, app: XCUIApplication) throws -> XCUIElement {
        let control = app.buttons[identifier], scroll = app.scrollViews["studio.audio.library.scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        for _ in 0..<10 {
            let viewport = scroll.frame
            if control.exists, control.isHittable, control.isEnabled, viewport.contains(control.frame) { return control }
            guard viewport.width > 0, viewport.height > 0 else { break }
            // A full-viewport swipe can skip a tile in the compact library.
            // Center an existing target in either direction; for unrealized lazy
            // rows advance less than one viewport so neighboring rows overlap.
            let inset = viewport.height * 0.15
            let maximumTravel = viewport.height - 2 * inset
            var movement = -maximumTravel
            if control.exists, control.frame.height > 0 {
                movement = min(maximumTravel, max(-maximumTravel, viewport.midY - control.frame.midY))
                if viewport.contains(control.frame) {
                    let ready = expectation(for: NSPredicate { _, _ in control.exists && control.isHittable && control.isEnabled }, evaluatedWith: control)
                    if ready.waitUntilFulfilled(timeout: 3), scroll.frame.contains(control.frame) { return control }
                    break
                }
            }
            let startY = movement < 0 ? viewport.maxY - inset : viewport.minY + inset
            let origin = scroll.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: viewport.width / 2, dy: startY - viewport.minY))
            let end = origin.withOffset(CGVector(dx: viewport.width / 2, dy: startY + movement - viewport.minY))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.25)
        }
        captureHierarchy(app, name: "audio-library-control-unreachable")
        XCTFail("Actual library control is not reachable: " + identifier)
        throw NSError(domain: "NativeAudioLibrary", code: 1)
    }

    @MainActor
    func testAudioFilesPickerCancellationPreservesBlankProject() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        _ = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 8))
        try waitForStableCanvas(canvas)
        let originalFrame = canvas.frame
        let before = try pixels(canvas.screenshot().image)
        XCTAssertFalse(app.buttons["studio.undo"].isEnabled)
        let open = app.buttons["studio.audio.open"]
        XCTAssertTrue(open.isHittable); open.tap()
        let library = app.buttons["studio.audio.library.open"]
        XCTAssertTrue(library.waitForExistence(timeout: 5)); library.tap()
        let importAudio = app.buttons["studio.audio.import"]
        XCTAssertTrue(importAudio.waitForExistence(timeout: 8)); XCTAssertTrue(importAudio.isEnabled)
        XCTAssertEqual(app.staticTexts["studio.audio.clip-count"].label, "0 clips")
        capture(app, name: "audio-empty-real-timeline")
        importAudio.tap()

        // This is the real system document picker. No injected app URL or
        // hidden importer call can satisfy the navigation and cancel checks.
        // The actual provider navigation has a stable system identifier.
        // The actual hierarchy can contain a noninteractive Cancel wrapper
        // before the real button. Never treat arbitrary firstMatch as actionable.
        let providerNavigation = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"]
        XCTAssertTrue(providerNavigation.waitForExistence(timeout: 10))
        @MainActor func interactiveCancel() -> XCUIElement? {
            let navigationFrame = providerNavigation.frame
            guard !navigationFrame.isEmpty else { return nil }
            // Prefer an actual button. Some system versions expose an Other;
            // accept that only when it independently passes all interaction gates.
            for type in [XCUIElement.ElementType.button, .other] {
                let candidates = app.descendants(matching: type).matching(NSPredicate(format: "label == %@", "Cancel"))
                guard candidates.count <= 8 else { return nil }
                for candidate in candidates.allElementsBoundByIndex {
                    let bounds = candidate.frame
                    if !bounds.isEmpty, navigationFrame.contains(bounds), candidate.isEnabled, candidate.isHittable { return candidate }
                }
            }
            return nil
        }
        capture(app, name: "audio-native-files-picker")
        captureHierarchy(app, name: "audio-native-files-picker-hierarchy")
        XCTAssertTrue(providerNavigation.exists, "Inspect the real Files provider hierarchy before changing this assertion")
        // The finalized failure hierarchy restored Browse / On My iPhone.
        // Navigate the real provider to Recents before asserting that page;
        // picker location persists independently of this new blank project.
        let providerTabs = app.tabBars["DOC.browsingModeTabBar"]
        let recents = providerTabs.buttons["Recents"]
        XCTAssertTrue(recents.waitForExistence(timeout: 5))
        XCTAssertTrue(recents.isEnabled && recents.isHittable)
        recents.tap()
        var selectedCancel: XCUIElement?
        let recentsReady = NSPredicate { _, _ in
            guard providerNavigation.staticTexts["Recents"].exists else { return false }
            selectedCancel = interactiveCancel()
            return selectedCancel != nil
        }
        XCTAssertTrue(expectation(for: recentsReady, evaluatedWith: nil).waitUntilFulfilled(timeout: 5),
                      "The real Files Recents page and interactive Cancel did not become ready")
        let cancel = try XCTUnwrap(selectedCancel, "No enabled, hittable Cancel in the provider navigation frame")
        // Empty Recents need not expose a File View collection; retain exact
        // provider navigation and selected-tab checks on the actual surface.
        XCTAssertTrue(providerTabs.buttons["Recents"].isSelected)
        XCTAssertTrue(providerTabs.buttons["Browse"].exists)
        XCTAssertTrue(providerTabs.buttons["Shared"].exists)
        XCTAssertTrue(cancel.isEnabled && cancel.isHittable)
        XCTAssertTrue(providerNavigation.frame.contains(cancel.frame))
        cancel.tap()
        XCTAssertTrue(importAudio.waitForExistence(timeout: 8)); XCTAssertTrue(importAudio.isEnabled)
        XCTAssertFalse(app.staticTexts["studio.audio.imported"].exists, "Picker cancellation invented an imported clip")
        XCTAssertFalse(app.buttons["studio.audio.cancel"].exists, "Picker cancellation left an import running")
        XCTAssertEqual(app.staticTexts["studio.audio.clip-count"].label, "0 clips")
        capture(app, name: "audio-files-cancelled-no-clips")
        let close = app.buttons["studio.audio.close"]
        XCTAssertTrue(close.isHittable); close.tap()
        XCTAssertTrue(canvas.waitForExistence(timeout: 5)); XCTAssertTrue(canvas.isHittable)
        try waitForStableCanvas(canvas, expected: originalFrame)
        XCTAssertFalse(app.buttons["studio.undo"].isEnabled, "Cancelling Files mutated the document history")
        XCTAssertLessThanOrEqual(try changedPixelCount(before, pixels(canvas.screenshot().image)), 4,
                                "Cancelling the actual audio picker changed the canvas")
    }

    @MainActor
    func testStudioSpatterLocalGuidanceAndUnconfiguredCloud() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let projectName = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 8))
        let before = try pixels(canvas.screenshot().image)
        let menu = app.buttons["studio.menu.open"]
        XCTAssertTrue(menu.isHittable); menu.tap()
        let open = app.buttons["studio.spatter.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 8)); XCTAssertTrue(open.isHittable); open.tap()
        let status = app.staticTexts["spatter.studio.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 8)); XCTAssertEqual(status.label, "Local guide")
        let cloud = app.switches["spatter.studio.cloud"]
        XCTAssertTrue(cloud.exists); XCTAssertEqual(cloud.value as? String, "0")
        let input = app.textFields["spatter.studio.input"]
        XCTAssertTrue(input.isHittable); input.tap(); input.typeText("onion skin")
        app.buttons["spatter.studio.send"].tap()
        let snapshot = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@",
            "Project snapshot: \(projectName), 1 frames at 12 FPS.")).firstMatch
        XCTAssertTrue(snapshot.waitForExistence(timeout: 8), "Local response lost the real submitted project context")
        XCTAssertTrue(snapshot.label.localizedCaseInsensitiveContains("onion"), "Local brain lookup ignored the submitted topic")
        XCTAssertTrue(app.staticTexts["LOCAL GUIDE"].exists)
        XCTAssertFalse(app.staticTexts["CLOUD ADVICE"].exists)
        capture(app, name: "spatter-real-local-guidance")

        // The verified built-app preflight has empty backend configuration.
        // Choosing cloud must produce an explicit unavailable state, never a
        // fabricated online reply or a test-only replacement responder.
        XCTAssertTrue(cloud.isHittable)
        // The recorded Switch AX frame includes the label and gap: tap() sent
        // its center to that gap. Target the visible right-hand switch within
        // this actual element, never an absolute window coordinate.
        cloud.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let cloudSelected = expectation(for: NSPredicate(format: "value == %@", "1"),
                                        evaluatedWith: cloud).waitUntilFulfilled(timeout: 5)
        if !cloudSelected {
            capture(app, name: "spatter-cloud-switch-failed")
            captureHierarchy(app, name: "spatter-cloud-switch-failed-hierarchy")
        }
        XCTAssertTrue(cloudSelected, "Tapping the actual switch thumb did not enable cloud advice")
        input.tap(); input.typeText("layers")
        app.buttons["spatter.studio.send"].tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "Cloud not configured · local guide"),
                                  evaluatedWith: status).waitUntilFulfilled(timeout: 10))
        let notice = app.staticTexts["spatter.studio.notice"]
        XCTAssertEqual(notice.label, "Spatter cloud is not configured. Local animation guidance remains available.")
        XCTAssertFalse(app.staticTexts["CLOUD ADVICE"].exists)
        capture(app, name: "spatter-unconfigured-cloud-local-fallback")
        captureHierarchy(app, name: "spatter-unconfigured-hierarchy")
        let close = app.buttons["spatter.studio.close"]
        XCTAssertTrue(close.isHittable); close.tap()
        XCTAssertTrue(canvas.waitForExistence(timeout: 8)); XCTAssertTrue(canvas.isHittable)
        XCTAssertFalse(app.buttons["studio.undo"].isEnabled, "Advice-only chat unexpectedly edited the document")
        XCTAssertLessThanOrEqual(try changedPixelCount(before, pixels(canvas.screenshot().image)), 4,
                                "Advice-only chat changed the actual canvas")
    }

    /// Uses real library controls and touch input. Comparing two families at
    /// identical settings catches a library that only changes its selected label.
    @MainActor
    func testBrushLibrarySettingsUndoAndPersistence() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let projectName = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 8)); XCTAssertTrue(canvas.isHittable)
        let undo = app.buttons["studio.undo"]
        let redo = app.buttons["studio.redo"]
        XCTAssertFalse(undo.isEnabled, "The brush journey requires a new blank project")

        try waitForButton("Brush", in: app).tap()
        let library = app.buttons["studio.brush-library"]
        XCTAssertTrue(library.waitForExistence(timeout: 5)); library.tap()
        let round = app.buttons["studio.brush-family.round"]
        XCTAssertTrue(round.waitForExistence(timeout: 5)); XCTAssertTrue(round.isHittable); round.tap()
        let size = app.sliders["studio.setting.size"]
        let opacity = app.sliders["studio.setting.opacity"]
        XCTAssertTrue(size.waitForExistence(timeout: 5)); XCTAssertTrue(size.isHittable)
        XCTAssertTrue(opacity.isHittable)
        let initialSize = try XCTUnwrap(size.value as? String)
        let initialOpacity = try XCTUnwrap(opacity.value as? String)
        size.adjust(toNormalizedSliderPosition: 0.75)
        opacity.adjust(toNormalizedSliderPosition: 0.6)
        let selectedSize = try XCTUnwrap(size.value as? String)
        let selectedOpacity = try XCTUnwrap(opacity.value as? String)
        XCTAssertNotEqual(selectedSize, initialSize)
        XCTAssertNotEqual(selectedOpacity, initialOpacity)
        capture(app, name: "brush-round-settings")
        let closeSettings = app.buttons["studio.tool-settings.close"]
        if !closeSettings.isHittable { captureHierarchy(app, name: "brush-popup-close-unreachable") }
        XCTAssertTrue(closeSettings.isHittable); closeSettings.tap()
        let before = try pixels(canvas.screenshot().image)
        XCTAssertTrue(exportInkMask(before).isEmpty, "The actual starting canvas contains red ink")

        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: undo).waitUntilFulfilled(timeout: 5),
                      "The real touch stroke did not commit and release its active-input guard")
        let roundRaster = try pixels(canvas.screenshot().image)
        let roundInk = exportInkMask(roundRaster)
        XCTAssertGreaterThan(roundInk.count, 12)
        // The default document is 1080 pixels wide. A size near 38 must produce
        // substantially more thickness than the default 3, at the actual scale.
        let inkRows = roundInk.map { $0 / roundRaster.width }
        let inkHeight = try XCTUnwrap(inkRows.max()) - XCTUnwrap(inkRows.min()) + 1
        XCTAssertGreaterThan(Double(inkHeight), Double(roundRaster.width) * 20 / 1080,
                             "Size changed its label without increasing rendered stroke width")
        let greenChannels = roundInk.map { Int(roundRaster.bytes[$0 * 4 + 1]) }.sorted()
        let medianGreen = greenChannels[greenChannels.count / 2]
        XCTAssertGreaterThan(medianGreen, 60, "Opacity stayed fully opaque despite the actual slider adjustment")
        XCTAssertLessThan(medianGreen, 180, "The selected opacity produced only nearly invisible ink")
        undo.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: redo).waitUntilFulfilled(timeout: 5))
        XCTAssertLessThanOrEqual(try changedPixelCount(before, pixels(canvas.screenshot().image)), 4)

        try waitForButton("Brush", in: app).tap()
        XCTAssertTrue(library.waitForExistence(timeout: 5)); library.tap()
        let stipple = app.buttons["studio.brush-family.stipple"]
        XCTAssertTrue(stipple.waitForExistence(timeout: 5)); XCTAssertTrue(stipple.isHittable); stipple.tap()
        XCTAssertTrue(library.label.contains("Stipple"))
        XCTAssertEqual(size.value as? String, selectedSize, "Changing family unexpectedly changed size")
        XCTAssertEqual(opacity.value as? String, selectedOpacity, "Changing family unexpectedly changed opacity")
        capture(app, name: "brush-stipple-settings")
        closeSettings.tap()
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: undo).waitUntilFulfilled(timeout: 5))
        let stippleRaster = try pixels(canvas.screenshot().image)
        let stippleInk = exportInkMask(stippleRaster)
        XCTAssertGreaterThan(stippleInk.count, 12, "Stipple rendered no visible dots")
        XCTAssertLessThan(Double(stippleInk.count), Double(roundInk.count) * 0.8,
                          "Stipple did not render distinctly sparser ink than Round at the same settings")
        XCTAssertGreaterThan(try changedPixelCount(roundRaster, stippleRaster), 12)
        capture(app, name: "brush-stipple-drawn")
        undo.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: redo).waitUntilFulfilled(timeout: 5))
        XCTAssertLessThanOrEqual(try changedPixelCount(before, pixels(canvas.screenshot().image)), 4,
                                 "Undo did not remove the complete styled stroke")
        redo.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: undo).waitUntilFulfilled(timeout: 5))
        XCTAssertLessThanOrEqual(try changedPixelCount(stippleRaster, pixels(canvas.screenshot().image)), 4,
                                 "Redo changed the deterministic Stipple pattern")

        let save = app.buttons["studio.save"]
        XCTAssertTrue(save.isHittable); save.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "Saved"), evaluatedWith: save).waitUntilFulfilled(timeout: 8))
        app.buttons["studio.back"].tap()
        let savedProject = app.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(savedProject.waitForExistence(timeout: 8))
        app.terminate()
        let reopenedApp = try launchGuestStudio()
        defer { reopenedApp.terminate() }
        let reopenedProject = reopenedApp.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(reopenedProject.waitForExistence(timeout: 8)); reopenedProject.tap()
        let reopenedCanvas = reopenedApp.descendants(matching: .any)["studio.canvas"].firstMatch
        XCTAssertTrue(reopenedCanvas.waitForExistence(timeout: 8))
        let reopened = try pixels(reopenedCanvas.screenshot().image)
        XCTAssertLessThanOrEqual(try changedPixelCount(stippleRaster, reopened), 4,
                                 "Save/relaunch/reopen did not retain the brush settings and stable seeded pattern")
        XCTAssertGreaterThan(try changedPixelCount(before, reopened), 12)
        capture(reopenedApp, name: "brush-stipple-persisted-reopened")
    }

    /// A different complete instruction from the example must create real
    /// editable content and a decoded exported file through ordinary controls.
    @MainActor
    func testSpatterSelectedAudioVolumeUndoAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let projectName = try createProjectIfLibraryIsShown(app)
        XCTAssertTrue(expectation(for: NSPredicate(format: "exists == false"),
                                  evaluatedWith: app.keyboards.firstMatch).waitUntilFulfilled(timeout: 5))
        try waitForStableCanvas(app.descendants(matching: .any)["studio.canvas"].firstMatch)
        func audioControl(_ identifier: String, in target: XCUIApplication, towardBottom: Bool) throws -> XCUIElement {
            let element = target.descendants(matching: .any)[identifier].firstMatch
            let scroll = target.scrollViews["studio.audio.compact.scroll"]
            XCTAssertTrue(scroll.waitForExistence(timeout: 8))
            for _ in 0..<4 {
                if element.exists && element.isHittable { break }
                if towardBottom { scroll.swipeUp(velocity: .slow) }
                else { scroll.swipeDown(velocity: .slow) }
            }
            XCTAssertTrue(element.exists && element.isHittable, "Audio inspector control unavailable: \(identifier)")
            return element
        }
        func openAudio(_ target: XCUIApplication) {
            let button = target.buttons["studio.audio.open"]
            XCTAssertTrue(button.waitForExistence(timeout: 8) && button.isHittable); button.tap()
        }
        func closeAudio(_ target: XCUIApplication) throws {
            try audioControl("studio.audio.close", in: target, towardBottom: false).tap()
        }
        func assertVolume(_ expected: String, in target: XCUIApplication) throws {
            let slider = try audioControl("studio.audio.volume", in: target, towardBottom: true)
            XCTAssertEqual(slider.value as? String, expected)
            XCTAssertEqual(target.buttons["studio.audio.clip-mute"].label, "Mute selected clip")
        }
        openAudio(app)
        let library = app.buttons["studio.audio.library.open"]
        XCTAssertTrue(library.waitForExistence(timeout: 5) && library.isHittable); library.tap()
        let search = app.textFields["studio.audio.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Wood Cracking 02\n")
        try audioLibraryButton("studio.audio.catalogue.add.3b7a688684cf8d75a180aa50edd9f51e159635cb25432e82d3f32d9d173299e1", app: app).tap()
        app.buttons["studio.audio.library.close"].tap()
        try assertVolume("80 percent", in: app); try closeAudio(app)
        app.buttons["studio.menu.open"].tap()
        let spatter = app.buttons["studio.spatter.open"]
        XCTAssertTrue(spatter.waitForExistence(timeout: 8)); spatter.tap()
        let local = app.buttons["spatter.studio.local-motion"]
        XCTAssertTrue(local.waitForExistence(timeout: 8) && local.isHittable); local.tap()
        try localMotionControl("spatter.audio.examples", app: app).tap()
        let example = app.buttons["spatter.audio.example.volume"]
        XCTAssertTrue(example.waitForExistence(timeout: 5) && example.isHittable); example.tap()
        let input = try localMotionControl("spatter.motion.input", app: app)
        XCTAssertEqual(input.value as? String, "Set selected audio clip volume to 40%.")
        let guidance = try localMotionControl("spatter.local-edit.guidance", app: app, scrollUp: false)
        XCTAssertTrue(guidance.label.contains("Volume uses 0–100%"))
        XCTAssertTrue(guidance.label.contains("Fade durations use seconds"))
        XCTAssertFalse(guidance.label.contains("canvas percentages"))
        capture(app, name: "spatter-audio-contextual-guidance")
        try localMotionControl("spatter.motion.apply", app: app).tap()
        let receipt = try localMotionControl("spatter.motion.result", app: app)
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@",
            "Updated the selected audio clip in one undoable local edit."),
            evaluatedWith: receipt).waitUntilFulfilled(timeout: 8))
        capture(app, name: "spatter-selected-audio-volume-receipt")
        let back = app.buttons["spatter.motion.back"]
        XCTAssertTrue(back.isHittable); back.tap()
        let done = app.buttons["spatter.studio.close"]
        XCTAssertTrue(done.waitForExistence(timeout: 5) && done.isHittable); done.tap()
        openAudio(app); try assertVolume("40 percent", in: app); try closeAudio(app)
        app.buttons["studio.undo"].tap()
        openAudio(app); try assertVolume("80 percent", in: app); try closeAudio(app)
        app.buttons["studio.redo"].tap()
        openAudio(app); try assertVolume("40 percent", in: app); try closeAudio(app)
        let save = app.buttons["studio.save"]; save.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "Saved"), evaluatedWith: save).waitUntilFulfilled(timeout: 8))
        app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap(); openAudio(reopened)
        try audioControl("studio.audio.clip-picker", in: reopened, towardBottom: false).tap()
        let clip = reopened.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "studio.audio.select-clip.")).firstMatch
        XCTAssertTrue(clip.waitForExistence(timeout: 5) && clip.isHittable); clip.tap()
        try assertVolume("40 percent", in: reopened)
        XCTAssertEqual(reopened.staticTexts["studio.audio.clip-count"].label, "1 clips")
        capture(reopened, name: "spatter-selected-audio-volume-cold-reopened")
    }

    @MainActor
    func testSpatterSelectedAudioPlacementUndoAndColdReopen() throws {
        // Measured public CI recovered a60s XCTest menu-animation notification delay; retain all placement/history/cold assertions.
        executionTimeAllowance = 240
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let projectName = try createProjectIfLibraryIsShown(app)
        XCTAssertTrue(expectation(for: NSPredicate(format: "exists == false"),
                                  evaluatedWith: app.keyboards.firstMatch).waitUntilFulfilled(timeout: 5))
        try waitForStableCanvas(app.descendants(matching: .any)["studio.canvas"].firstMatch)
        func audioControl(_ identifier: String, in target: XCUIApplication, towardBottom: Bool) throws -> XCUIElement {
            let element = target.descendants(matching: .any)[identifier].firstMatch
            let scroll = target.scrollViews["studio.audio.compact.scroll"]
            XCTAssertTrue(scroll.waitForExistence(timeout: 8))
            for _ in 0..<4 {
                if element.exists && element.isHittable { break }
                if towardBottom { scroll.swipeUp(velocity: .slow) }
                else { scroll.swipeDown(velocity: .slow) }
            }
            XCTAssertTrue(element.exists && element.isHittable, "Audio inspector control unavailable: \(identifier)")
            return element
        }
        func openAudio(_ target: XCUIApplication) {
            let button = target.buttons["studio.audio.open"]
            XCTAssertTrue(button.waitForExistence(timeout: 8) && button.isHittable); button.tap()
        }
        func closeAudio(_ target: XCUIApplication) throws {
            try audioControl("studio.audio.close", in: target, towardBottom: false).tap()
        }
        func assertVolume(_ expected: String, in target: XCUIApplication) throws {
            let slider = try audioControl("studio.audio.volume", in: target, towardBottom: true)
            XCTAssertEqual(slider.value as? String, expected)
            XCTAssertEqual(target.buttons["studio.audio.clip-mute"].label, "Mute selected clip")
        }
        openAudio(app)
        let library = app.buttons["studio.audio.library.open"]
        XCTAssertTrue(library.waitForExistence(timeout: 5) && library.isHittable); library.tap()
        let search = app.textFields["studio.audio.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Wood Cracking 02\n")
        try audioLibraryButton("studio.audio.catalogue.add.3b7a688684cf8d75a180aa50edd9f51e159635cb25432e82d3f32d9d173299e1", app: app).tap()
        app.buttons["studio.audio.library.close"].tap()
        try assertVolume("80 percent", in: app); try closeAudio(app)
        app.buttons["studio.menu.open"].tap()
        let spatter = app.buttons["studio.spatter.open"]
        XCTAssertTrue(spatter.waitForExistence(timeout: 8)); spatter.tap()
        let local = app.buttons["spatter.studio.local-motion"]
        XCTAssertTrue(local.waitForExistence(timeout: 8) && local.isHittable); local.tap()
        try localMotionControl("spatter.audio.examples", app: app).tap()
        let example = app.buttons["spatter.audio.example.placement"]
        XCTAssertTrue(example.waitForExistence(timeout: 5) && example.isHittable); example.tap()
        let input = try localMotionControl("spatter.motion.input", app: app)
        XCTAssertEqual(input.value as? String, "Move selected audio clip to 1.25 seconds on track 2.")
        let guidance = try localMotionControl("spatter.local-edit.guidance", app: app, scrollUp: false)
        XCTAssertTrue(guidance.label.contains("Volume uses 0–100%"))
        XCTAssertTrue(guidance.label.contains("Fade durations use seconds"))
        XCTAssertFalse(guidance.label.contains("canvas percentages"))
        capture(app, name: "spatter-placement-contextual-guidance")
        try localMotionControl("spatter.motion.apply", app: app).tap()
        let receipt = try localMotionControl("spatter.motion.result", app: app)
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@",
            "Updated the selected audio clip in one undoable local edit."),
            evaluatedWith: receipt).waitUntilFulfilled(timeout: 8))
        capture(app, name: "spatter-selected-audio-placement-receipt")
        let back = app.buttons["spatter.motion.back"]
        XCTAssertTrue(back.isHittable); back.tap()
        let done = app.buttons["spatter.studio.close"]
        XCTAssertTrue(done.waitForExistence(timeout: 5) && done.isHittable); done.tap()
        func assertPlacement(_ start: String, track: Int, in target: XCUIApplication) throws {
            try audioControl("studio.audio.clip-picker", in: target, towardBottom: false).tap()
            let selected = target.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "studio.audio.select-clip.")).firstMatch
            XCTAssertTrue(selected.waitForExistence(timeout: 5) && selected.isHittable)
            XCTAssertTrue(selected.label.hasPrefix("Track \(track) ·")); selected.tap()
            let timing = try audioControl("studio.audio.clip-timing", in: target, towardBottom: true)
            XCTAssertTrue(timing.label.hasPrefix("Start \(start)s · Source 0.00s"))
            try assertVolume("80 percent", in: target)
        }
        openAudio(app); try assertPlacement("1.25", track: 2, in: app); try closeAudio(app)
        app.buttons["studio.undo"].tap()
        openAudio(app); try assertPlacement("0.00", track: 1, in: app); try closeAudio(app)
        app.buttons["studio.redo"].tap()
        openAudio(app); try assertPlacement("1.25", track: 2, in: app); try closeAudio(app)
        let save = app.buttons["studio.save"]; save.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "Saved"), evaluatedWith: save).waitUntilFulfilled(timeout: 8))
        app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap(); openAudio(reopened)
        try assertPlacement("1.25", track: 2, in: reopened)
        XCTAssertEqual(reopened.staticTexts["studio.audio.clip-count"].label, "1 clips")
        capture(reopened, name: "spatter-selected-audio-placement-cold-reopened")
    }

    @MainActor
    func testSpatterLocalMotionEditsExportsAndReopens() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let projectName = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 8))
        let before = try pixels(canvas.screenshot().image)
        app.buttons["studio.menu.open"].tap()
        let open = app.buttons["studio.spatter.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 8)); open.tap()
        let motion = app.buttons["spatter.studio.local-motion"]
        XCTAssertTrue(motion.waitForExistence(timeout: 8)); XCTAssertTrue(motion.isHittable); motion.tap()
        let guidance = try localMotionControl("spatter.local-edit.guidance", app: app)
        XCTAssertTrue(guidance.label.contains("Positions use canvas percentages"))
        XCTAssertFalse(guidance.label.contains("Fade durations"))
        let instruction = "Append 5 frames of a blue outlined circle moving from (30%, 40%) to (70%, 60%), radius 6%, line width 12 px."
        let input = try localMotionControl("spatter.motion.input", app: app)
        input.tap(); input.typeText(instruction)
        let keyboardDone = app.buttons["spatter.motion.keyboard.done"]
        XCTAssertTrue(keyboardDone.waitForExistence(timeout: 5)); XCTAssertTrue(keyboardDone.isHittable); keyboardDone.tap()
        try localMotionControl("spatter.motion.apply", app: app).tap()
        let receipt = try localMotionControl("spatter.motion.result", app: app)
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@",
            "Added 5 editable frames at 12 FPS (0.417 seconds) in one undoable local edit."),
            evaluatedWith: receipt).waitUntilFulfilled(timeout: 8))
        let retainedInput = try localMotionControl("spatter.motion.input", app: app, scrollUp: false)
        XCTAssertEqual(retainedInput.value as? String, instruction, "Executing a recipe discarded the user's exact draft")
        try localMotionControl("spatter.motion.save", app: app).tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "Saved"),
            evaluatedWith: app.staticTexts["spatter.motion.save-state"]).waitUntilFulfilled(timeout: 8))
        capture(app, name: "spatter-five-frame-local-receipt")
        try localMotionControl("spatter.motion.export", app: app).tap()
        XCTAssertTrue(app.buttons["studio.export.format.png"].waitForExistence(timeout: 8),
                      "Spatter did not open the real native export controls")
        try exportControl("studio.export.format.spritesheet", app: app, scrollUp: false).tap()
        try exportControl("studio.export.start", app: app).tap()
        let preview = try waitForPNGPreview(app)
        let exported = try pixels(preview.screenshot().image)
        var blue = 0
        for index in stride(from: 0, to: exported.bytes.count, by: 4) {
            if exported.bytes[index + 2] > 130 && exported.bytes[index] < 100 && exported.bytes[index + 1] < 100 { blue += 1 }
        }
        XCTAssertGreaterThan(blue, 12, "The PNG decoded from the spritesheet contains no requested blue motion")
        capture(app, name: "spatter-motion-real-spritesheet-preview")
        try closeExportPanel(app)
        XCTAssertTrue(canvas.isHittable)
        let edited = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(before, edited), 12, "Spatter's receipt did not create visible editable content")
        let undo = app.buttons["studio.undo"], redo = app.buttons["studio.redo"]
        XCTAssertTrue(undo.isEnabled); undo.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: redo).waitUntilFulfilled(timeout: 5))
        XCTAssertLessThanOrEqual(try changedPixelCount(before, pixels(canvas.screenshot().image)), 4,
                                 "One Undo did not reverse the complete recipe")
        XCTAssertFalse(undo.isEnabled, "Recipe creation unexpectedly required multiple Undo operations")
        redo.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: undo).waitUntilFulfilled(timeout: 5))
        XCTAssertLessThanOrEqual(try changedPixelCount(edited, pixels(canvas.screenshot().image)), 4)
        let save = app.buttons["studio.save"]
        save.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "Saved"), evaluatedWith: save).waitUntilFulfilled(timeout: 8))
        app.buttons["studio.back"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch.waitForExistence(timeout: 8))
        app.terminate()
        let reopenedApp = try launchGuestStudio()
        defer { reopenedApp.terminate() }
        let savedProject = reopenedApp.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(savedProject.waitForExistence(timeout: 8)); savedProject.tap()
        let reopenedCanvas = reopenedApp.descendants(matching: .any)["studio.canvas"].firstMatch
        XCTAssertTrue(reopenedCanvas.waitForExistence(timeout: 8))
        XCTAssertLessThanOrEqual(try changedPixelCount(edited, pixels(reopenedCanvas.screenshot().image)), 4,
                                 "Relaunch lost the actual Spatter-created document")
        capture(reopenedApp, name: "spatter-motion-persisted-reopened")
    }

    @MainActor
    func testBottomCopyPasteUsesExplicitLinkedImageWithoutDrawingsOrFrameCopies() throws {
        let app = try launchGuestStudio(); defer { app.terminate() }
        _ = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas); let frame = canvas.frame
        let blank = try pixels(canvas.screenshot().image)
        try openImagePanel(app); try imageControl("studio.image.library", app: app).tap()
        let search = app.textFields["studio.image-library.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 8)); search.tap(); search.typeText("dragon\n")
        let dragon = app.buttons["studio.image-library.item.kenney.scribble-dungeons.dragon"]
        XCTAssertTrue(dragon.waitForExistence(timeout: 5)); dragon.tap()
        try imageControl("studio.image.apply", app: app).tap()
        XCTAssertTrue(try imageControl("studio.image.result", app: app).label.hasPrefix("Added Dungeon Dragon"))
        try closeImagePanel(app)
        @MainActor func moveControl(_ id: String) throws -> XCUIElement {
            let button = app.buttons[id]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            let popup = app.descendants(matching: .any)["studio.tool-settings"].firstMatch
            for _ in 0..<4 where !button.isHittable { popup.scrollViews.firstMatch.swipeUp(velocity: .slow) }
            XCTAssertTrue(button.isHittable)
            XCTAssertTrue(expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: button).waitUntilFulfilled(timeout: 8))
            return button
        }
        try selectToolbarTool("move", app: app)
        try moveControl("studio.image-placement.open").tap()
        try moveControl("studio.image-placement.half").tap()
        try moveControl("studio.image-placement.apply").tap()
        app.buttons["studio.tool-settings.close"].tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let originalHalf = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(blank, originalHalf), 100)
        // Seed a real older frame clipboard. The later image Copy must replace
        // bottom Paste's scope, not silently reuse this complete-frame copy.
        XCTAssertEqual(app.buttons["studio.copy"].label, "Copy frame")
        app.buttons["studio.copy"].tap()
        app.buttons["studio.layers.open"].tap()
        let originalRow = app.staticTexts["Image: Dungeon Dragon"].firstMatch
        XCTAssertTrue(originalRow.waitForExistence(timeout: 5)); originalRow.tap()
        let duplicate = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Duplicate")).firstMatch
        XCTAssertTrue(duplicate.waitForExistence(timeout: 5))
        let list = app.scrollViews["studio.layers.list"]
        for _ in 0..<4 where !duplicate.isHittable { list.swipeUp(velocity: .slow) }
        XCTAssertTrue(duplicate.isHittable && duplicate.isEnabled); duplicate.tap()
        let copyRow = app.staticTexts["Image: Dungeon Dragon Copy"].firstMatch
        XCTAssertTrue(copyRow.waitForExistence(timeout: 5))
        for _ in 0..<4 where !copyRow.isHittable { list.swipeDown(velocity: .slow) }
        XCTAssertTrue(copyRow.isHittable); copyRow.tap()
        app.buttons["studio.layers.close"].tap()
        _ = try preparePickerSourceStroke(app)
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertGreaterThan(imageFixtureColors(try pixels(canvas.screenshot().image))[1], 12, "Source frame has no real unrelated blue drawing to exclude")
        try selectToolbarTool("move", app: app)
        try moveControl("studio.image-move.target").tap()
        XCTAssertEqual(app.buttons["studio.image-move.target"].value as? String, "Image")
        let flip = try moveControl("studio.image-flip.horizontal")
        XCTAssertEqual(flip.value as? String, "Original"); flip.tap()
        XCTAssertEqual(flip.value as? String, "Flipped")
        app.buttons["studio.tool-settings.close"].tap()
        XCTAssertTrue((canvas.value as? String)?.contains("Selected image") == true)
        let copy = app.buttons["studio.copy"], paste = app.buttons["studio.paste"]
        XCTAssertEqual(copy.label, "Copy selected image"); XCTAssertTrue(copy.isEnabled); copy.tap()
        XCTAssertEqual(paste.label, "Paste image")
        XCTAssertFalse(paste.isEnabled, "Image paste must not replace the occupied source frame or fall back to its old frame clipboard")
        app.buttons["studio.add-frame"].tap()
        try waitForStableCanvas(canvas, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(blank, pixels(canvas.screenshot().image)), 4, "Add frame did not create the actual blank destination")
        XCTAssertTrue(expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: paste).waitUntilFulfilled(timeout: 8))
        paste.tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let pasted = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(blank, pasted), 100, "Bottom image paste produced no image pixels")
        XCTAssertGreaterThan(try changedPixelCount(originalHalf, pasted), 100, "Paste copied the unflipped primary instead of the explicitly selected linked copy")
        XCTAssertLessThanOrEqual(imageFixtureColors(pasted)[1], 8, "Image copy included the source frame's blue drawings")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "2 frames")).firstMatch.exists,
                      "Bottom image Paste inserted another timeline frame from the stale frame clipboard")
        try selectToolbarTool("move", app: app)
        XCTAssertEqual(try moveControl("studio.image-flip.horizontal").value as? String, "Flipped", "Pasted image lost chosen linked instance geometry")
        app.buttons["studio.tool-settings.close"].tap()
        capture(app, name: "bottom-image-copy-paste-excludes-linked-siblings-and-drawings")
    }

    @MainActor
    func testOptionalMicroPackImportRemovalAndColdReopen() throws {
        let app = try launchGuestStudio(); defer { app.terminate() }
        let projectName = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let frame = canvas.frame, blank = try pixels(canvas.screenshot().image)
        let packID = "kenney.micro-roguelike.v1"
        @MainActor func packButton(_ label: String) throws -> XCUIElement {
            let action = label == "Remove download" ? "remove" : "download"
            let button = app.buttons["studio.image-library.pack." + action + "." + packID]
            let scroll = app.scrollViews["studio.image-library.pack-list"]
            guard scroll.waitForExistence(timeout: 5) else {
                captureHierarchy(app, name: "micro-pack-list-missing")
                XCTFail("Optional pack list must expose its real scroll view")
                throw NSError(domain: "NativeOptionalPack", code: 2)
            }
            // Offscreen pack actions need not exist in the accessibility tree
            // until scrolling brings their real row into the viewport.
            for _ in 0..<5 {
                if button.exists && button.isHittable && scroll.frame.contains(button.frame) { break }
                scroll.swipeUp(velocity: .slow)
            }
            guard button.exists && button.isEnabled && button.isHittable &&
                    scroll.frame.contains(button.frame) else {
                captureHierarchy(app, name: "micro-pack-action-unreachable")
                capture(app, name: "micro-pack-action-unreachable")
                XCTFail("Micro Roguelike action is not fully reachable: " + label)
                throw NSError(domain: "NativeOptionalPack", code: 1)
            }
            captureHierarchy(app, name: "micro-pack-action-reachable")
            XCTAssertEqual(button.label, label)
            return button
        }
        @MainActor func pictureCount() throws -> Int {
            let label = app.staticTexts["studio.image-library.count"]
            XCTAssertTrue(label.waitForExistence(timeout: 8))
            return try XCTUnwrap(Int(label.label.split(separator: " ").first.map(String.init) ?? ""))
        }
        try openImagePanel(app); try imageControl("studio.image.library", app: app).tap()
        let more = app.buttons["More optional picture packs"]
        XCTAssertTrue(more.waitForExistence(timeout: 8)); more.tap()
        // Start with this optional pack absent; other installed packs are retained.
        let existing = app.buttons["studio.image-library.pack.remove." + packID]
        let available = app.buttons["studio.image-library.pack.download." + packID]
        let packList = app.scrollViews["studio.image-library.pack-list"]
        XCTAssertTrue(packList.waitForExistence(timeout: 5))
        for _ in 0..<5 {
            if existing.exists || available.exists { break }
            packList.swipeUp(velocity: .slow)
        }
        if existing.exists {
            try packButton("Remove download").tap()
            XCTAssertTrue(app.staticTexts["Downloaded library copy removed. Pictures already added to your projects are kept."].waitForExistence(timeout: 8))
        }
        let initialCount = try pictureCount()
        try packButton("Download 178 KB").tap()
        XCTAssertTrue(app.staticTexts["Pictures verified and available offline."].waitForExistence(timeout: 30),
                      "Real official download and verification did not complete")
        XCTAssertEqual(try pictureCount(), initialCount + 160)
        capture(app, name: "optional-micro-pack-downloaded-library")
        more.tap()
        let search = app.textFields["studio.image-library.search"]
        XCTAssertTrue(search.isHittable); search.tap(); search.typeText("Micro Roguelike tile 0000\n")
        let tile = app.buttons["studio.image-library.item.kenney.micro-roguelike.tile_0000"]
        XCTAssertTrue(tile.waitForExistence(timeout: 5) && tile.isHittable); tile.tap()
        try imageControl("studio.image.apply", app: app).tap()
        XCTAssertTrue(try imageControl("studio.image.result", app: app).label.hasPrefix("Added Micro Roguelike tile 0000"))
        try closeImagePanel(app); try settlePickerCanvasAfterSave(app, canvas: canvas)
        let imported = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(blank, imported), 4, "Downloaded tile must produce actual visible pixels")
        // Remove only the downloaded catalogue. The saved project owns its source.
        try openImagePanel(app); try imageControl("studio.image.library", app: app).tap()
        XCTAssertTrue(more.waitForExistence(timeout: 8)); more.tap()
        try packButton("Remove download").tap()
        XCTAssertTrue(app.staticTexts["Downloaded library copy removed. Pictures already added to your projects are kept."].waitForExistence(timeout: 8))
        XCTAssertEqual(try pictureCount(), initialCount)
        XCTAssertTrue(try packButton("Download 178 KB").isEnabled)
        app.buttons["studio.panel.close.Image Library"].tap()
        try closeImagePanel(app)
        XCTAssertLessThanOrEqual(try changedPixelCount(imported, pixels(canvas.screenshot().image)), 4)
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(imported, pixels(restored.screenshot().image)), 4,
                                "Removing the optional pack broke the saved project's owned image")
        capture(reopened, name: "optional-micro-pack-removed-project-cold-reopened")
    }

    @MainActor
    func testExplicitImageCutUndoPasteAndColdReopen() throws {
        let app = try launchGuestStudio(); defer { app.terminate() }
        let projectName = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let frame = canvas.frame, blank = try pixels(canvas.screenshot().image)
        try importLicensedImageForExport(app, canvas: canvas)
        let original = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(blank, original), 100, "Imported image fixture has no real pixels")
        // Import retains the drawing layer. Choose the actual image owner before
        // explicitly targeting its instance; this must not use singleton fallback.
        app.buttons["studio.layers.open"].tap()
        let imageLayer = app.staticTexts["Image: Dungeon Dragon"].firstMatch
        XCTAssertTrue(imageLayer.waitForExistence(timeout: 5))
        let layers = app.scrollViews["studio.layers.list"]
        for _ in 0..<4 where !imageLayer.isHittable { layers.swipeUp(velocity: .slow) }
        XCTAssertTrue(imageLayer.isHittable); imageLayer.tap()
        app.buttons["studio.layers.close"].tap()
        try selectToolbarTool("move", app: app)
        let target = try fillPreferenceControl("studio.image-move.target", app: app)
        XCTAssertEqual(target.value as? String, "Drawings")
        target.tap(); XCTAssertEqual(target.value as? String, "Image")
        let cut = try fillPreferenceControl("studio.image.cut", app: app)
        XCTAssertEqual(cut.label, "Cut selected image")
        XCTAssertTrue(cut.isEnabled && cut.isHittable); cut.tap()
        app.buttons["studio.tool-settings.close"].tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(blank, pixels(canvas.screenshot().image)), 4,
                                "Cut left the selected image pixels on the frame")
        let paste = app.buttons["studio.paste"]
        XCTAssertEqual(paste.label, "Paste image")
        XCTAssertTrue(paste.isEnabled, "Cut did not retain its image clipboard")
        app.buttons["studio.undo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4,
                                "One Undo did not restore the cut image")
        XCTAssertFalse(paste.isEnabled, "Image Paste must not overwrite the restored occupied frame")
        app.buttons["studio.redo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(blank, pixels(canvas.screenshot().image)), 4,
                                "One Redo did not remove the image again")
        XCTAssertEqual(paste.label, "Paste image")
        XCTAssertTrue(paste.isEnabled && paste.isHittable); paste.tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4,
                                "Cut image Paste did not restore the original rendered pixels")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "1 frames")).firstMatch.exists,
                      "Image Cut/Paste unexpectedly created another timeline frame")
        capture(app, name: "explicit-image-cut-undo-redo-paste")
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(restored.screenshot().image)), 4,
                                "Cut/Paste image pixels did not survive saved cold reopen")
        XCTAssertTrue(reopened.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "1 frames")).firstMatch.exists)
        capture(reopened, name: "explicit-image-cut-paste-cold-reopened")
    }

    @MainActor
    func testImageDeleteCancelUndoAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let projectName = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let frame = canvas.frame, blank = try pixels(canvas.screenshot().image)
        try openImagePanel(app)
        try imageControl("studio.image.library", app: app).tap()
        let search = app.textFields["studio.image-library.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 8));search.tap();search.typeText("dragon\n")
        let dragon = app.buttons["studio.image-library.item.kenney.scribble-dungeons.dragon"]
        XCTAssertTrue(dragon.waitForExistence(timeout: 5));dragon.tap()
        try imageControl("studio.image.apply", app: app).tap()
        XCTAssertTrue(try imageControl("studio.image.result", app: app).label.hasPrefix("Added Dungeon Dragon"))
        try closeImagePanel(app)
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let original = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(blank, original), 100)
        @MainActor func selectImageForBottomBar(_ enabled: Bool) throws {
            try selectToolbarTool("move", app: app)
            let target = app.buttons["studio.image-move.target"]
            XCTAssertTrue(target.waitForExistence(timeout: 5))
            let popup = app.descendants(matching: .any)["studio.tool-settings"].firstMatch
            for _ in 0..<4 where !target.isHittable { popup.scrollViews.firstMatch.swipeUp(velocity: .slow) }
            XCTAssertTrue(target.isHittable)
            if (target.value as? String == "Image") != enabled { target.tap() }
            XCTAssertEqual(target.value as? String, enabled ? "Image" : "Drawings")
            app.buttons["studio.tool-settings.close"].tap()
        }
        @MainActor func requestDeletion() throws {
            try selectImageForBottomBar(true)
            let deletion = app.buttons["studio.delete-selection"]
            XCTAssertEqual(deletion.label, "Delete selected image")
            XCTAssertTrue(deletion.isHittable && deletion.isEnabled)
            deletion.tap()
            XCTAssertTrue(app.buttons["Delete image"].waitForExistence(timeout: 5))
        }
        try requestDeletion()
        capture(app, name: "image-delete-confirmation")
        app.buttons["Cancel"].tap(); try selectImageForBottomBar(false)
        try waitForStableCanvas(canvas, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4, "Cancel removed actual image pixels")
        try requestDeletion();app.buttons["Delete image"].tap()
        capture(app, name: "image-delete-after-confirmation")
        XCTAssertFalse(app.buttons["studio.delete-selection"].isEnabled, "Last selected picture still exposes enabled bottom Delete")
        // Preserve the original popup absence assertion as well as the bottom
        // entrypoint assertion; reopening cannot manufacture an image target.
        try selectToolbarTool("move", app: app)
        XCTAssertTrue(expectation(for: NSPredicate(format: "exists == false"),
                                  evaluatedWith: app.buttons["studio.image-delete.open"]).waitUntilFulfilled(timeout: 5),
                      "Deleted picture still exposes Delete")
        app.buttons["studio.tool-settings.close"].tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(blank, pixels(canvas.screenshot().image)), 4, "Delete left picture pixels")
        app.buttons["studio.undo"].tap();try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4, "One Undo did not restore picture pixels")
        capture(app, name: "image-delete-undone")
        app.buttons["studio.redo"].tap();try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(blank, pixels(canvas.screenshot().image)), 4)
        app.buttons["studio.layers.open"].tap()
        XCTAssertTrue(app.staticTexts["Layer 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Dungeon Dragon")).firstMatch.exists,
                      "Deleting the picture deleted its layer")
        app.buttons["studio.layers.close"].tap()
        app.buttons["studio.back"].tap();app.terminate()
        let reopened = try launchGuestStudio();defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8));project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(blank, pixels(restored.screenshot().image)), 4, "Deleted picture returned on cold reopen")
        capture(reopened, name: "image-delete-cold-reopened")
    }

    @MainActor
    func testLinkedImageLayerDuplicateIndependentFlipUndoAndColdReopen() throws {
        let app = try launchGuestStudio(); defer { app.terminate() }
        let projectName = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas); let frame = canvas.frame
        try openImagePanel(app); try imageControl("studio.image.library", app: app).tap()
        let search = app.textFields["studio.image-library.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 8)); search.tap(); search.typeText("dragon\n")
        let dragon = app.buttons["studio.image-library.item.kenney.scribble-dungeons.dragon"]
        XCTAssertTrue(dragon.waitForExistence(timeout: 5)); dragon.tap()
        try imageControl("studio.image.apply", app: app).tap()
        XCTAssertTrue(try imageControl("studio.image.result", app: app).label.hasPrefix("Added Dungeon Dragon"))
        try closeImagePanel(app); try settlePickerCanvasAfterSave(app, canvas: canvas)
        let original = try pixels(canvas.screenshot().image)
        app.buttons["studio.layers.open"].tap()
        let originalRow = app.staticTexts["Image: Dungeon Dragon"].firstMatch
        XCTAssertTrue(originalRow.waitForExistence(timeout: 5)); originalRow.tap()
        // This existing production action combines its emoji and visible title;
        // it has no synthetic identifier or test-only target.
        let duplicate = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Duplicate")).firstMatch
        XCTAssertTrue(duplicate.waitForExistence(timeout: 5))
        let layers = app.scrollViews["studio.layers.list"]
        for _ in 0..<4 where !duplicate.isHittable { layers.swipeUp(velocity: .slow) }
        XCTAssertTrue(duplicate.isHittable); XCTAssertTrue(duplicate.isEnabled); duplicate.tap()
        let copyRow = app.staticTexts["Image: Dungeon Dragon Copy"].firstMatch
        XCTAssertTrue(copyRow.waitForExistence(timeout: 5))
        for _ in 0..<4 where !copyRow.isHittable { layers.swipeDown(velocity: .slow) }
        XCTAssertTrue(copyRow.isHittable); copyRow.tap()
        capture(app, name: "linked-image-layer-duplicated")
        app.buttons["studio.layers.close"].tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let duplicated = try pixels(canvas.screenshot().image)
        // PNG antialiasing can darken a few edge pixels under exact duplication;
        // compare Undo to this actual two-instance baseline, not a flattened image.
        @MainActor func flipControl() throws -> XCUIElement {
            try selectToolbarTool("move", app: app)
            let control = app.buttons["studio.image-flip.horizontal"]
            XCTAssertTrue(control.waitForExistence(timeout: 5))
            let popup = app.descendants(matching: .any)["studio.tool-settings"].firstMatch
            for _ in 0..<4 where !control.isHittable { popup.scrollViews.firstMatch.swipeUp(velocity: .slow) }
            XCTAssertTrue(control.isHittable)
            XCTAssertTrue(expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: control).waitUntilFulfilled(timeout: 8))
            return control
        }
        let flip = try flipControl(); XCTAssertEqual(flip.value as? String, "Original"); flip.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "value == %@", "Flipped"), evaluatedWith: flip).waitUntilFulfilled(timeout: 5))
        app.buttons["studio.tool-settings.close"].tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let transformed = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(duplicated, transformed), 100, "Linked transform changed no real pixels")
        app.buttons["studio.undo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(duplicated, pixels(canvas.screenshot().image)), 4, "One Undo did not restore duplicate geometry")
        app.buttons["studio.redo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(transformed, pixels(canvas.screenshot().image)), 4, "One Redo lost duplicate transform")
        app.buttons["studio.layers.open"].tap()
        let originalAgain = app.staticTexts["Image: Dungeon Dragon"].firstMatch
        XCTAssertTrue(originalAgain.waitForExistence(timeout: 5))
        for _ in 0..<4 where !originalAgain.isHittable { app.scrollViews["studio.layers.list"].swipeUp(velocity: .slow) }
        XCTAssertTrue(originalAgain.isHittable); originalAgain.tap(); app.buttons["studio.layers.close"].tap()
        XCTAssertEqual(try flipControl().value as? String, "Original", "Editing duplicate also flipped original instance")
        app.buttons["studio.tool-settings.close"].tap()
        capture(app, name: "linked-image-independent-flip")
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(transformed, pixels(restored.screenshot().image)), 4, "Cold reopen lost linked image composition")
        XCTAssertGreaterThan(try changedPixelCount(original, pixels(restored.screenshot().image)), 100, "Cold reopen kept only original image")
        capture(reopened, name: "linked-image-duplicate-cold-reopened")
    }

    @MainActor
    func testMixedDrawingImageMoveDeleteUndoAndColdReopen() throws {
        // Measured native trace reached cold reopen at184s after both-source move and Delete/Undo.
        executionTimeAllowance = 240
        let app = try launchGuestStudio(); defer { app.terminate() }
        let name = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let frame = canvas.frame, blank = try pixels(canvas.screenshot().image)
        _ = try preparePickerSourceStroke(app)
        try importLicensedImageForExport(app, canvas: canvas)
        try selectToolbarTool("move", app: app)
        try fillPreferenceControl("studio.image-placement.open", app: app).tap()
        try fillPreferenceControl("studio.image-placement.half", app: app).tap()
        try fillPreferenceControl("studio.image-placement.apply", app: app).tap()
        app.buttons["studio.tool-settings.close"].tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let original = try pixels(canvas.screenshot().image)
        @MainActor func centroid(_ raster: Raster, blue: Bool) throws -> CGPoint {
            var xs = 0.0, ys = 0.0, count = 0
            for y in 0..<raster.height { for x in 0..<raster.width {
                let i = (y * raster.width + x) * 4
                let red = Int(raster.bytes[i]), green = Int(raster.bytes[i + 1]), b = Int(raster.bytes[i + 2])
                let matches = blue ? b > 150 && b > red + 60 && b > green + 60 : max(red, max(green, b)) < 90
                if matches { xs += Double(x); ys += Double(y); count += 1 }
            } }
            XCTAssertGreaterThan(count, 12, blue ? "Actual blue drawing missing" : "Actual dark imported image missing")
            guard count > 12 else { throw NSError(domain: "NativeMixedArtwork", code: 1) }
            return CGPoint(x: xs / Double(count), y: ys / Double(count))
        }
        let originalBlue = try centroid(original, blue: true), originalImage = try centroid(original, blue: false)
        app.buttons["studio.layers.open"].tap()
        let imageLayer = app.staticTexts["Image: Dungeon Dragon"].firstMatch
        XCTAssertTrue(imageLayer.waitForExistence(timeout: 5) && imageLayer.isHittable); imageLayer.tap()
        app.buttons["studio.layers.close"].tap()
        @MainActor func encloseGroup(configure: Bool) throws {
            try selectToolbarTool("lasso", app: app)
            if configure {
                let target = app.buttons["studio.selection.target"]
                XCTAssertTrue(target.waitForExistence(timeout: 5) && target.isHittable); target.tap()
                let mixed = app.buttons["Drawings + image"]
                XCTAssertTrue(mixed.waitForExistence(timeout: 5) && mixed.isHittable); mixed.tap()
                try fillPreferenceControl("studio.selection.kind.rectangle", app: app).tap()
                try fillPreferenceControl("studio.selection.mode.new", app: app).tap()
            }
            app.buttons["studio.tool-settings.close"].tap()
            canvas.coordinate(withNormalizedOffset: .init(dx: 0.08, dy: 0.08)).press(forDuration: 0.1,
                thenDragTo: canvas.coordinate(withNormalizedOffset: .init(dx: 0.95, dy: 0.92)),
                withVelocity: .slow, thenHoldForDuration: 0.1)
            try selectToolbarTool("lasso", app: app)
            XCTAssertEqual(app.staticTexts["studio.selection.count"].label, "2 artwork items selected · 1 drawings, 1 image")
            app.buttons["studio.tool-settings.close"].tap()
            try selectToolbarTool("move", app: app); app.buttons["studio.tool-settings.close"].tap()
            XCTAssertTrue((canvas.value as? String ?? "").hasPrefix("Selected drawings and image:"))
            XCTAssertTrue(app.buttons["studio.copy"].isEnabled)
            XCTAssertEqual(app.buttons["studio.copy"].label, "Copy selected artwork", "Mixed Copy must explicitly include both kinds")
        }
        try encloseGroup(configure: true)
        canvas.coordinate(withNormalizedOffset: .init(dx: 0.22, dy: 0.50)).press(forDuration: 0.1,
            thenDragTo: canvas.coordinate(withNormalizedOffset: .init(dx: 0.26, dy: 0.50)),
            withVelocity: .slow, thenHoldForDuration: 0.1)
        canvas.coordinate(withNormalizedOffset: .init(dx: 0.03, dy: 0.03)).tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let moved = try pixels(canvas.screenshot().image)
        let blue = try centroid(moved, blue: true), image = try centroid(moved, blue: false)
        let expectedShift = CGFloat(original.width) * 0.04
        XCTAssertEqual(blue.x - originalBlue.x, expectedShift, accuracy: 3, "Group drag left the drawing behind")
        XCTAssertEqual(image.x - originalImage.x, expectedShift, accuracy: 3, "Group drag left the image behind")
        XCTAssertEqual(blue.y, originalBlue.y, accuracy: 3); XCTAssertEqual(image.y, originalImage.y, accuracy: 3)
        try encloseGroup(configure: false)
        let deletion = app.buttons["studio.delete-selection"]
        XCTAssertEqual(deletion.label, "Delete selected drawings and image")
        XCTAssertTrue(deletion.isEnabled && deletion.isHittable); deletion.tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(blank, pixels(canvas.screenshot().image)), 4,
                                "Group Delete left one selected source behind")
        app.buttons["studio.undo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(moved, pixels(canvas.screenshot().image)), 4,
                                "One Undo did not restore both selected sources")
        capture(app, name: "mixed-artwork-moved-delete-undone")
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(moved, pixels(restored.screenshot().image)), 4,
                                "Saved mixed drawing/image pixels did not survive cold reopen")
        capture(reopened, name: "mixed-artwork-cold-reopened")
    }

    @MainActor
    func testImageWandRegionCopyDeletePasteUndoAndColdReopen() throws {
        // Licensed import, screenshot-derived selection, clipboard/history and cold reopen share the bounded 240s journey ceiling.
        executionTimeAllowance = 240
        let app = try launchGuestStudio(); defer { app.terminate() }
        let name = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let frame = canvas.frame
        try importLicensedImageForExport(app, canvas: canvas)
        let original = try pixels(canvas.screenshot().image)
        capture(app, name: "wand-original-licensed-image")
        // Choose an actual dark interior sample from the rendered image, with a
        // 5x5 neighborhood to avoid transparent borders and antialiased edges.
        var seed: CGPoint?
        var darkest = Int.max
        for y in (original.height / 10)..<(original.height * 9 / 10) {
            for x in (original.width / 10)..<(original.width * 9 / 10) {
                var score = 0, dark = 0
                for dy in -2...2 { for dx in -2...2 {
                    let i = ((y + dy) * original.width + x + dx) * 4
                    let value = max(Int(original.bytes[i]), max(Int(original.bytes[i + 1]), Int(original.bytes[i + 2])))
                    score += value
                    if value < 90 { dark += 1 }
                } }
                let i = (y * original.width + x) * 4
                if dark >= 9 && max(original.bytes[i], max(original.bytes[i + 1], original.bytes[i + 2])) < 70 && score < darkest {
                    darkest = score; seed = CGPoint(x: CGFloat(x), y: CGFloat(y))
                }
            }
        }
        let selectedPixel = try XCTUnwrap(seed, "Licensed image has no stable dark interior seed")
        app.buttons["studio.layers.open"].tap()
        let imageLayer = app.staticTexts["Image: Dungeon Dragon"].firstMatch
        XCTAssertTrue(imageLayer.waitForExistence(timeout: 5) && imageLayer.isHittable); imageLayer.tap()
        app.buttons["studio.layers.close"].tap()
        try selectToolbarTool("wand", app: app)
        app.buttons["studio.tool-settings.close"].tap()
        canvas.coordinate(withNormalizedOffset: .init(dx: (selectedPixel.x + 0.5) / CGFloat(original.width),
                                                       dy: (selectedPixel.y + 0.5) / CGFloat(original.height))).tap()
        let copy = app.buttons["studio.copy"]
        let selected = expectation(for: NSPredicate(format: "enabled == true AND label == %@", "Copy selected image region"), evaluatedWith: copy)
        let ready = selected.waitUntilFulfilled(timeout: 8)
        if !ready { capture(app, name: "wand-selection-failure"); captureHierarchy(app, name: "wand-selection-failure-hierarchy") }
        XCTAssertTrue(ready, "Wand must select source pixels, not fall back to frame Copy")
        guard ready else { throw NSError(domain: "NativeWandSelection", code: 1) }
        XCTAssertTrue(copy.isHittable); copy.tap()
        XCTAssertEqual(app.buttons["studio.paste"].label, "Paste image")
        try selectToolbarTool("wand", app: app)
        let count = app.staticTexts["studio.wand.count"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        let countValue = try XCTUnwrap(Int(count.label.split(separator: " ").first.map(String.init) ?? ""))
        XCTAssertGreaterThan(countValue, 0, "Selection must contain actual source pixels")
        capture(app, name: "wand-selected-source-pixels")
        let delete = try fillPreferenceControl("studio.wand.delete", app: app)
        XCTAssertTrue(delete.isEnabled && delete.isHittable); delete.tap()
        app.buttons["studio.tool-settings.close"].tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let removed = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(original, removed), 4, "Delete did not remove selected image pixels")
        let sample = (Int(selectedPixel.y) * removed.width + Int(selectedPixel.x)) * 4
        XCTAssertGreaterThan(Int(removed.bytes[sample]) + Int(removed.bytes[sample + 1]) + Int(removed.bytes[sample + 2]), 600,
                             "The tapped dark region was not removed")
        capture(app, name: "wand-region-deleted")
        app.buttons["studio.undo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4, "One Undo failed to restore the original image")
        app.buttons["studio.redo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(removed, pixels(canvas.screenshot().image)), 4, "Redo changed the region deletion")
        try selectToolbarTool("move", app: app); app.buttons["studio.tool-settings.close"].tap()
        let paste = app.buttons["studio.paste"]
        XCTAssertEqual(paste.label, "Paste image")
        XCTAssertTrue(paste.isEnabled && paste.isHittable); paste.tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4,
                                "Pasted region and remainder did not restore the original image")
        capture(app, name: "wand-region-pasted")
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(restored.screenshot().image)), 4,
                                "Cold reopen lost the retained image source or region masks")
        capture(reopened, name: "wand-region-cold-reopened")
    }

    @MainActor
    func testMixedArtworkCopyCutPasteUndoAndColdReopen() throws {
        // Same licensed-image/mixed-selection setup as the measured >180s mixed journey; adds Copy/Cut/Paste and cold reopen.
        executionTimeAllowance = 240
        let app = try launchGuestStudio(); defer { app.terminate() }
        let name = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let frame = canvas.frame, blank = try pixels(canvas.screenshot().image)
        _ = try preparePickerSourceStroke(app)
        try importLicensedImageForExport(app, canvas: canvas)
        try selectToolbarTool("move", app: app)
        try fillPreferenceControl("studio.image-placement.open", app: app).tap()
        try fillPreferenceControl("studio.image-placement.half", app: app).tap()
        try fillPreferenceControl("studio.image-placement.apply", app: app).tap()
        app.buttons["studio.tool-settings.close"].tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let original = try pixels(canvas.screenshot().image)
        @MainActor func centroid(_ raster: Raster, blue: Bool) throws -> CGPoint {
            var xs = 0.0, ys = 0.0, count = 0
            for y in 0..<raster.height { for x in 0..<raster.width {
                let i = (y * raster.width + x) * 4
                let red = Int(raster.bytes[i]), green = Int(raster.bytes[i + 1]), b = Int(raster.bytes[i + 2])
                let matches = blue ? b > 150 && b > red + 60 && b > green + 60 : max(red, max(green, b)) < 90
                if matches { xs += Double(x); ys += Double(y); count += 1 }
            } }
            XCTAssertGreaterThan(count, 12, blue ? "Actual blue drawing missing" : "Actual dark imported image missing")
            guard count > 12 else { throw NSError(domain: "NativeMixedArtwork", code: 1) }
            return CGPoint(x: xs / Double(count), y: ys / Double(count))
        }
        _ = try centroid(original, blue: true); _ = try centroid(original, blue: false)
        app.buttons["studio.layers.open"].tap()
        let imageLayer = app.staticTexts["Image: Dungeon Dragon"].firstMatch
        XCTAssertTrue(imageLayer.waitForExistence(timeout: 5) && imageLayer.isHittable); imageLayer.tap()
        app.buttons["studio.layers.close"].tap()
        @MainActor func encloseGroup(configure: Bool) throws {
            try selectToolbarTool("lasso", app: app)
            if configure {
                let target = app.buttons["studio.selection.target"]
                XCTAssertTrue(target.waitForExistence(timeout: 5) && target.isHittable); target.tap()
                let mixed = app.buttons["Drawings + image"]
                XCTAssertTrue(mixed.waitForExistence(timeout: 5) && mixed.isHittable); mixed.tap()
                try fillPreferenceControl("studio.selection.kind.rectangle", app: app).tap()
                try fillPreferenceControl("studio.selection.mode.new", app: app).tap()
            }
            app.buttons["studio.tool-settings.close"].tap()
            canvas.coordinate(withNormalizedOffset: .init(dx: 0.08, dy: 0.08)).press(forDuration: 0.1,
                thenDragTo: canvas.coordinate(withNormalizedOffset: .init(dx: 0.95, dy: 0.92)),
                withVelocity: .slow, thenHoldForDuration: 0.1)
            try selectToolbarTool("lasso", app: app)
            XCTAssertEqual(app.staticTexts["studio.selection.count"].label, "2 artwork items selected · 1 drawings, 1 image")
            app.buttons["studio.tool-settings.close"].tap()
            try selectToolbarTool("move", app: app); app.buttons["studio.tool-settings.close"].tap()
            XCTAssertTrue((canvas.value as? String ?? "").hasPrefix("Selected drawings and image:"))
            XCTAssertTrue(app.buttons["studio.copy"].isEnabled)
            XCTAssertEqual(app.buttons["studio.copy"].label, "Copy selected artwork", "Mixed Copy must explicitly include both kinds")
        }
        try encloseGroup(configure: true)
        let copy = app.buttons["studio.copy"]
        XCTAssertTrue(copy.isEnabled && copy.isHittable); copy.tap()
        let paste = app.buttons["studio.paste"]
        XCTAssertEqual(paste.label, "Paste artwork", "Copy must retain both selected kinds")
        try selectToolbarTool("move", app: app)
        let cut = try fillPreferenceControl("studio.selection.cut", app: app)
        XCTAssertTrue(cut.isEnabled && cut.isHittable); cut.tap()
        app.buttons["studio.tool-settings.close"].tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(blank, pixels(canvas.screenshot().image)), 4,
                                "Cut left a selected drawing or image behind")
        XCTAssertEqual(paste.label, "Paste artwork")
        app.buttons["studio.undo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4,
                                "One Undo did not restore both source kinds")
        app.buttons["studio.redo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(blank, pixels(canvas.screenshot().image)), 4,
                                "Redo did not repeat the complete Cut")
        XCTAssertTrue(paste.isEnabled && paste.isHittable); paste.tap()
        canvas.coordinate(withNormalizedOffset: .init(dx: 0.03, dy: 0.03)).tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let pasted = try pixels(canvas.screenshot().image)
        _ = try centroid(pasted, blue: true); _ = try centroid(pasted, blue: false)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pasted), 4,
                                "Paste changed the drawing/image geometry or lost a source")
        capture(app, name: "mixed-artwork-cut-pasted")
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(restored.screenshot().image)), 4,
                                "Cold reopen lost pasted image source or drawing geometry")
        capture(reopened, name: "mixed-artwork-clipboard-cold-reopened")
    }

    @MainActor
    func testActiveLayerImageMarqueeDeleteUndoAndColdReopen() throws {
        // Measured public CI completed cold-image capture at180.54s after active import/selection/history progress.
        executionTimeAllowance = 240
        let app = try launchGuestStudio(); defer { app.terminate() }
        let projectName = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas); let frame = canvas.frame
        let blank = try pixels(canvas.screenshot().image)
        try openImagePanel(app); try imageControl("studio.image.library", app: app).tap()
        let search = app.textFields["studio.image-library.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 8)); search.tap(); search.typeText("dragon\n")
        let dragon = app.buttons["studio.image-library.item.kenney.scribble-dungeons.dragon"]
        XCTAssertTrue(dragon.waitForExistence(timeout: 5)); dragon.tap()
        try imageControl("studio.image.apply", app: app).tap()
        XCTAssertTrue(try imageControl("studio.image.result", app: app).label.hasPrefix("Added Dungeon Dragon"))
        try closeImagePanel(app)
        // Aspect-fit Half size centers the real image inside the middle half
        // of the canvas, so an inset 10–90% rectangle encloses its whole geometry.
        try selectToolbarTool("move", app: app)
        try fillPreferenceControl("studio.image-placement.open", app: app).tap()
        try fillPreferenceControl("studio.image-placement.half", app: app).tap()
        try fillPreferenceControl("studio.image-placement.apply", app: app).tap()
        app.buttons["studio.tool-settings.close"].tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let original = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(blank, original), 100)
        // Import deliberately retains the prior drawing layer. Select the actual
        // image row; this journey never relies on singleton image fallback.
        app.buttons["studio.layers.open"].tap()
        let imageLayer = app.staticTexts["Image: Dungeon Dragon"].firstMatch
        XCTAssertTrue(imageLayer.waitForExistence(timeout: 5) && imageLayer.isHittable); imageLayer.tap()
        app.buttons["studio.layers.close"].tap()
        try selectToolbarTool("lasso", app: app)
        // This native menu sits at the real scroll viewport's top edge. The
        // slider helper adds a 12-point thumb margin that does not apply here.
        let targetPicker = app.buttons["studio.selection.target"]
        let selectionScroll = app.descendants(matching: .any)["studio.tool-settings"].firstMatch.scrollViews.firstMatch
        XCTAssertTrue(targetPicker.waitForExistence(timeout: 5) && targetPicker.isEnabled && targetPicker.isHittable)
        XCTAssertTrue(selectionScroll.frame.intersection(app.frame).contains(targetPicker.frame),
                      "Selection target menu is outside the actual popup viewport")
        targetPicker.tap()
        let imageTarget = app.buttons["Image on active layer"]
        XCTAssertTrue(imageTarget.waitForExistence(timeout: 5) && imageTarget.isHittable); imageTarget.tap()
        try fillPreferenceControl("studio.selection.kind.rectangle", app: app).tap()
        try fillPreferenceControl("studio.selection.mode.new", app: app).tap()
        XCTAssertEqual(app.staticTexts["studio.selection.count"].label, "0 image selected")
        app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(canvas, expected: frame)
        canvas.coordinate(withNormalizedOffset: .init(dx: 0.10, dy: 0.10)).press(forDuration: 0.1,
            thenDragTo: canvas.coordinate(withNormalizedOffset: .init(dx: 0.90, dy: 0.90)),
            withVelocity: .slow, thenHoldForDuration: 0.1)
        try selectToolbarTool("lasso", app: app)
        XCTAssertEqual(app.staticTexts["studio.selection.count"].label, "1 image selected")
        app.buttons["studio.tool-settings.close"].tap()
        XCTAssertFalse(app.buttons["studio.copy"].isEnabled, "Image Lasso must not silently copy a frame")
        // Move must inherit the exact image selection. Do not tap Move's image
        // toggle: doing so would conceal a broken Lasso handoff.
        try selectToolbarTool("move", app: app)
        app.buttons["studio.tool-settings.close"].tap()
        let deletion = app.buttons["studio.delete-selection"]
        XCTAssertEqual(deletion.label, "Delete selected image")
        XCTAssertTrue(deletion.isEnabled && deletion.isHittable); deletion.tap()
        let confirm = app.buttons["Delete image"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(blank, pixels(canvas.screenshot().image)), 4,
                                "Image-area selection deleted no image or left pixels behind")
        app.buttons["studio.undo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4,
                                "One Undo failed to restore the actual selected image")
        capture(app, name: "image-area-selected-delete-undone")
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(restored.screenshot().image)), 4,
                                "Restored image pixels changed after a cold reopen")
        capture(reopened, name: "image-area-selection-cold-reopened")
    }

    @MainActor
    func testImageRotationHandleUndoAndColdReopen() throws {
        let app = try launchGuestStudio(); defer { app.terminate() }
        let projectName = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas); let frame = canvas.frame
        try openImagePanel(app); try imageControl("studio.image.library", app: app).tap()
        let search = app.textFields["studio.image-library.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 8)); search.tap(); search.typeText("dragon\n")
        let dragon = app.buttons["studio.image-library.item.kenney.scribble-dungeons.dragon"]
        XCTAssertTrue(dragon.waitForExistence(timeout: 5)); dragon.tap()
        try imageControl("studio.image.apply", app: app).tap()
        XCTAssertTrue(try imageControl("studio.image.result", app: app).label.hasPrefix("Added Dungeon Dragon"))
        try closeImagePanel(app); try settlePickerCanvasAfterSave(app, canvas: canvas)
        @MainActor func control(_ id: String) throws -> XCUIElement {
            // Reuse the existing fully-contained popup control helper; a partly
            // clipped but AX-hittable control is not an actionable target.
            try fillPreferenceControl(id, app: app)
        }
        try selectToolbarTool("move", app: app)
        try control("studio.image-placement.open").tap()
        try control("studio.image-placement.half").tap()
        @MainActor func number(_ name: String) throws -> Double {
            let field = app.textFields["studio.image-placement." + name]
            XCTAssertTrue(field.exists)
            return try XCTUnwrap(Double(field.value as? String ?? ""))
        }
        let x = try number("x"), y = try number("y"), width = try number("width"), height = try number("height")
        // This real library import is centered, and Half size preserves that
        // center. Read its actual numeric placement, not guessed image ink bounds.
        let documentWidth = 2*x + width, documentHeight = 2*y + height
        XCTAssertGreaterThan(documentWidth, width); XCTAssertGreaterThan(documentHeight, height)
        try control("studio.image-placement.apply").tap()
        app.buttons["studio.tool-settings.close"].tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let original = try pixels(canvas.screenshot().image)
        try selectToolbarTool("move", app: app)
        try control("studio.image-move.target").tap()
        app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(canvas, expected: frame)
        // Project opening establishes Fit (scale1). These are the production
        // StudioSelectionHandleGeometry rules: min22pt hit radius,8pt margin,
        // rotation knob30pt beyond the displayed top or bottom resize handles.
        let center = CGPoint(x: (x + width/2) / documentWidth * frame.width,
                             y: (y + height/2) / documentHeight * frame.height)
        let halfHeight = max(height / documentHeight * frame.height / 2, 22)
        let top = min(frame.height - 8, max(8, center.y - halfHeight))
        let bottom = min(frame.height - 8, max(8, center.y + halfHeight))
        let knob = CGPoint(x: min(frame.width - 8, max(8, center.x)),
                           y: top - 30 >= 8 ? top - 30 : min(frame.height - 8, bottom + 30))
        let dx = knob.x - center.x, dy = knob.y - center.y, factor = sqrt(0.5)
        let end = CGPoint(x: center.x + (dx - dy) * factor, y: center.y + (dx + dy) * factor)
        XCTAssertTrue(CGRect(origin: .zero, size: frame.size).contains(end))
        let origin = canvas.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: knob.x, dy: knob.y)).press(forDuration: 0.05,
            thenDragTo: origin.withOffset(CGVector(dx: end.x, dy: end.y)), withVelocity: .slow, thenHoldForDuration: 0.1)
        // Remove only editor selection chrome before comparing real artwork.
        try selectToolbarTool("brush", app: app)
        app.buttons["studio.tool-settings.close"].tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let rotated = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(original, rotated), 100, "Red image handle changed no artwork")
        XCTAssertEqual(original.width, rotated.width); XCTAssertEqual(original.height, rotated.height)
        let cx = Double(original.width)/2, cy = Double(original.height)/2
        var checked = 0, matched = 0
        for yy in stride(from: 0, to: original.height, by: 2) {
            for xx in stride(from: 0, to: original.width, by: 2) {
                let i = (yy * original.width + xx) * 4
                guard Int(original.bytes[i]) + Int(original.bytes[i+1]) + Int(original.bytes[i+2]) < 450 else { continue }
                let a = Double(xx) + 0.5 - cx, b = Double(yy) + 0.5 - cy
                let tx = Int((cx + (a-b)*factor).rounded(.down)), ty = Int((cy + (a+b)*factor).rounded(.down))
                checked += 1
                guard tx >= -3, ty >= -3, tx < rotated.width + 3, ty < rotated.height + 3 else { continue }
                var found = false
                for py in max(0,ty-3)...min(rotated.height-1,ty+3) {
                    for px in max(0,tx-3)...min(rotated.width-1,tx+3) {
                        let j = (py * rotated.width + px) * 4
                        if Int(rotated.bytes[j]) + Int(rotated.bytes[j+1]) + Int(rotated.bytes[j+2]) < 600 { found = true }
                    }
                }
                if found { matched += 1 }
            }
        }
        XCTAssertGreaterThan(checked, 30)
        XCTAssertGreaterThan(Double(matched)/Double(max(checked,1)), 0.85, "Gesture pixels do not match a clockwise45° rotation")
        app.buttons["studio.undo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4, "Handle gesture was not one Undo step")
        app.buttons["studio.redo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(rotated, pixels(canvas.screenshot().image)), 4, "Handle Redo changed pixels")
        capture(app, name: "image-rotation-handle-applied")
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(rotated, pixels(restored.screenshot().image)), 4, "Handle angle lost on cold reopen")
        capture(reopened, name: "image-rotation-handle-cold-reopened")
    }

    @MainActor
    func testImageAdditionalAngleUndoAndColdReopen() throws {
        // Separate from the measured 240-second quarter-turn case; this case
        // retains the default 180 seconds and imports through the real library.
        let app = try launchGuestStudio(); defer { app.terminate() }
        let projectName = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas); let canvasFrame = canvas.frame
        try openImagePanel(app); try imageControl("studio.image.library", app: app).tap()
        let search = app.textFields["studio.image-library.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 8)); search.tap(); search.typeText("dragon\n")
        let dragon = app.buttons["studio.image-library.item.kenney.scribble-dungeons.dragon"]
        XCTAssertTrue(dragon.waitForExistence(timeout: 5)); dragon.tap()
        try imageControl("studio.image.apply", app: app).tap()
        XCTAssertTrue(try imageControl("studio.image.result", app: app).label.hasPrefix("Added Dungeon Dragon"))
        try closeImagePanel(app); try settlePickerCanvasAfterSave(app, canvas: canvas)
        @MainActor func reveal(_ control: XCUIElement) throws -> XCUIElement {
            XCTAssertTrue(control.waitForExistence(timeout: 5))
            let scroll = app.descendants(matching: .any)["studio.tool-settings"].firstMatch.scrollViews.firstMatch
            XCTAssertTrue(scroll.exists)
            for _ in 0..<6 {
                let bounds = scroll.frame.intersection(app.frame)
                let viewport = bounds.insetBy(dx: 0, dy: min(12, bounds.height * 0.05))
                let target = control.frame
                if target.width > 0, target.height > 0, viewport.contains(target), control.isHittable, control.isEnabled { return control }
                guard target.height > 0, target.height <= viewport.height, !viewport.contains(target) else { break }
                let inset = bounds.height * 0.15, travel = bounds.height - 2 * inset
                let movement = min(travel, max(-travel, viewport.midY - target.midY))
                let startY = movement < 0 ? bounds.maxY - inset : bounds.minY + inset
                let origin = scroll.coordinate(withNormalizedOffset: .zero)
                let start = origin.withOffset(CGVector(dx: bounds.midX - scroll.frame.minX, dy: startY - scroll.frame.minY))
                let end = origin.withOffset(CGVector(dx: bounds.midX - scroll.frame.minX, dy: startY + movement - scroll.frame.minY))
                start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.25)
            }
            captureHierarchy(app, name: "additional-angle-control-unreachable")
            XCTFail("Image angle control is not fully visible and actionable")
            throw NSError(domain: "NativeImageAngle", code: 1)
        }
        let original = try pixels(canvas.screenshot().image)
        try selectToolbarTool("move", app: app)
        try reveal(app.buttons["studio.image-placement.open"]).tap()
        try reveal(app.buttons["studio.image-placement.half"]).tap()
        let angle = app.sliders.matching(NSPredicate(format: "label == %@", "Additional angle")).firstMatch
        try reveal(angle).adjust(toNormalizedSliderPosition: 0.625)
        let degrees = try XCTUnwrap(Double((angle.value as? String ?? "").replacingOccurrences(of: "°", with: "")))
        XCTAssertGreaterThan(degrees, 40); XCTAssertLessThan(degrees, 50)
        capture(app, name: "image-additional-angle-draft")
        try reveal(app.buttons["studio.image-placement.apply"]).tap()
        app.buttons["studio.tool-settings.close"].tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let rotated = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(original, rotated), 100, "Additional angle changed no artwork")
        // Match actual dark artwork against the combined half-size and clockwise
        // rotation about canvas center, not merely a changed screenshot.
        // The 3px neighborhood accommodates
        // native resampling and the displayed slider's integer rounding.
        XCTAssertEqual(original.width, rotated.width); XCTAssertEqual(original.height, rotated.height)
        let radians = degrees * .pi / 180, cosine = cos(radians), sine = sin(radians)
        let centerX = Double(original.width) / 2, centerY = Double(original.height) / 2
        var checked = 0, matched = 0
        for y in stride(from: 0, to: original.height, by: 2) {
            for x in stride(from: 0, to: original.width, by: 2) {
                let source = (y * original.width + x) * 4
                guard Int(original.bytes[source]) + Int(original.bytes[source + 1]) + Int(original.bytes[source + 2]) < 450 else { continue }
                let dx = (Double(x) + 0.5 - centerX) * 0.5
                let dy = (Double(y) + 0.5 - centerY) * 0.5
                let tx = Int((centerX + dx * cosine - dy * sine).rounded(.down))
                let ty = Int((centerY + dx * sine + dy * cosine).rounded(.down))
                checked += 1
                guard tx >= -3, ty >= -3, tx < rotated.width + 3, ty < rotated.height + 3 else { continue }
                var found = false
                for yy in max(0, ty - 3)...min(rotated.height - 1, ty + 3) {
                    for xx in max(0, tx - 3)...min(rotated.width - 1, tx + 3) {
                        let target = (yy * rotated.width + xx) * 4
                        if Int(rotated.bytes[target]) + Int(rotated.bytes[target + 1]) + Int(rotated.bytes[target + 2]) < 600 { found = true }
                    }
                }
                if found { matched += 1 }
            }
        }
        XCTAssertGreaterThan(checked, 30, "Licensed image fixture contains insufficient real artwork")
        XCTAssertGreaterThan(Double(matched) / Double(max(1, checked)), 0.85, "Image pixels do not follow the selected clockwise angle")
        app.buttons["studio.undo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4, "One Undo failed to restore full-size artwork before combined size/angle edit")
        app.buttons["studio.redo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(rotated, pixels(canvas.screenshot().image)), 4, "Redo changed angle pixels")
        capture(app, name: "image-additional-angle-applied")
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: canvasFrame)
        XCTAssertLessThanOrEqual(try changedPixelCount(rotated, pixels(restored.screenshot().image)), 4, "Cold reopen lost additional-angle pixels")
        capture(reopened, name: "image-additional-angle-cold-reopened")
    }

    @MainActor
    func testImageQuarterTurnsUndoAndColdReopen() throws {
        // Full CI reached cold reopen at 180s; the unchanged local journey
        // passed all pixel/history/reopen assertions in 182.757s.
        executionTimeAllowance = 240
        let app = try launchGuestStudio(); defer { app.terminate() }
        let projectName = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas); let frame = canvas.frame
        try openImagePanel(app); try imageControl("studio.image.library", app: app).tap()
        let search = app.textFields["studio.image-library.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 8)); search.tap(); search.typeText("dragon\n")
        let dragon = app.buttons["studio.image-library.item.kenney.scribble-dungeons.dragon"]
        XCTAssertTrue(dragon.waitForExistence(timeout: 5)); dragon.tap()
        try imageControl("studio.image.apply", app: app).tap()
        XCTAssertTrue(try imageControl("studio.image.result", app: app).label.hasPrefix("Added Dungeon Dragon"))
        try closeImagePanel(app); try settlePickerCanvasAfterSave(app, canvas: canvas)
        func control(_ id: String) throws -> XCUIElement {
            let button = app.buttons[id]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            let popup = app.descendants(matching: .any)["studio.tool-settings"].firstMatch
            for _ in 0..<4 where !button.isHittable {
                let scroll = popup.scrollViews.firstMatch
                XCTAssertTrue(scroll.exists); scroll.swipeUp(velocity: .slow)
            }
            XCTAssertTrue(button.isHittable)
            XCTAssertTrue(expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: button).waitUntilFulfilled(timeout: 8))
            return button
        }
        try selectToolbarTool("move", app: app)
        try control("studio.image-placement.open").tap()
        try control("studio.image-placement.half").tap()
        try control("studio.image-placement.apply").tap()
        app.buttons["studio.tool-settings.close"].tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let original = try pixels(canvas.screenshot().image)
        func turn(_ direction: String, degrees: Int) throws {
            try selectToolbarTool("move", app: app)
            let button = try control("studio.image-rotate." + direction)
            button.tap()
            XCTAssertTrue(expectation(for: NSPredicate(format: "value == %@", "\(degrees) degrees clockwise"), evaluatedWith: button).waitUntilFulfilled(timeout: 5))
            capture(app, name: "image-quarter-turn-\(degrees)-control")
            app.buttons["studio.tool-settings.close"].tap()
            try settlePickerCanvasAfterSave(app, canvas: canvas)
        }
        try turn("counterclockwise", degrees: 270)
        XCTAssertGreaterThan(try changedPixelCount(original, pixels(canvas.screenshot().image)), 100, "Left rotation changed no actual pixels")
        try turn("clockwise", degrees: 0)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4, "Right turn did not reverse left turn")
        try turn("clockwise", degrees: 90)
        let rotated = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(original, rotated), 100, "Right rotation changed no actual pixels")
        app.buttons["studio.undo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4, "One Undo failed")
        app.buttons["studio.redo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(rotated, pixels(canvas.screenshot().image)), 4, "One Redo failed")
        capture(app, name: "image-quarter-turn-applied")
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(rotated, pixels(restored.screenshot().image)), 4, "Cold reopen lost rotated pixels")
        capture(reopened, name: "image-quarter-turn-cold-reopened")
    }

    @MainActor
    func testImageDrawingOrderUndoAndColdReopen() throws {
        executionTimeAllowance = 240
        let app = try launchGuestStudio(); defer { app.terminate() }
        let projectName = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let frame = canvas.frame
        try importLicensedImageForExport(app, canvas: canvas)
        app.buttons["studio.layers.open"].tap()
        let imageLayer = app.staticTexts["Image: Dungeon Dragon"].firstMatch
        XCTAssertTrue(imageLayer.waitForExistence(timeout: 5) && imageLayer.isHittable); imageLayer.tap()
        app.buttons["studio.layers.close"].tap()
        let image = try pixels(canvas.screenshot().image)
        // Choose an actual opaque image row, rather than assuming the library
        // drawing occupies a hard-coded point. The stroke stays on its layer.
        var bestRow = image.height / 2, bestCount = 0
        for y in (image.height / 5)..<(image.height * 4 / 5) {
            var count = 0
            for x in (image.width / 10)..<(image.width * 9 / 10) {
                let i = (y * image.width + x) * 4
                if max(image.bytes[i], max(image.bytes[i + 1], image.bytes[i + 2])) < 90 { count += 1 }
            }
            if count > bestCount { bestCount = count; bestRow = y }
        }
        XCTAssertGreaterThan(bestCount, 12, "Imported image has no opaque test crossing")
        guard bestCount > 12 else { throw NSError(domain: "NativeImageOrder", code: 1) }
        try choosePickerTestColor("#FF0000", app: app)
        try pickerRailControl("studio.tool.brush", app: app, forward: false).tap()
        app.buttons["studio.brush-library"].tap()
        let round = app.buttons["studio.brush-family.round"]
        XCTAssertTrue(round.waitForExistence(timeout: 5)); round.tap()
        app.sliders["studio.setting.size"].adjust(toNormalizedSliderPosition: 0.7)
        app.sliders["studio.setting.opacity"].adjust(toNormalizedSliderPosition: 1)
        app.buttons["studio.tool-settings.close"].tap()
        let y = CGFloat(bestRow) / CGFloat(image.height)
        canvas.coordinate(withNormalizedOffset: .init(dx: 0.1, dy: y)).press(forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: y)))
        try waitForStableCanvas(canvas, expected: frame)
        let drawingOnTop = try pixels(canvas.screenshot().image)
        let originalColors = imageFixtureColors(drawingOnTop)
        XCTAssertGreaterThan(originalColors[0], 20, "Real red drawing was not added")
        @MainActor func orderImage(_ direction: String) throws {
            try selectToolbarTool("move", app: app)
            let target = try fillPreferenceControl("studio.image-move.target", app: app)
            if target.value as? String != "Image" { target.tap() }
            XCTAssertEqual(target.value as? String, "Image")
            let control = try fillPreferenceControl("studio.image-order." + direction, app: app)
            XCTAssertTrue(control.isEnabled && control.isHittable); control.tap()
            let deselect = try fillPreferenceControl("studio.image-move.target", app: app)
            if deselect.value as? String == "Image" { deselect.tap() }
            XCTAssertEqual(deselect.value as? String, "Drawings")
            app.buttons["studio.tool-settings.close"].tap()
            try waitForStableCanvas(canvas, expected: frame)
            XCTAssertEqual(canvas.frame, frame, "Ordering resized the Studio canvas")
        }
        try orderImage("forward")
        let imageOnTop = try pixels(canvas.screenshot().image)
        XCTAssertLessThan(imageFixtureColors(imageOnTop)[0], originalColors[0] - 12,
                          "Image Forward did not occlude the crossing red drawing on the same layer")
        XCTAssertGreaterThan(try changedPixelCount(drawingOnTop, imageOnTop), 20)
        capture(app, name: "same-layer-image-forward-real-crossing")
        app.buttons["studio.undo"].tap()
        XCTAssertLessThanOrEqual(try changedPixelCount(drawingOnTop, pixels(canvas.screenshot().image)), 4,
                                "One Undo did not restore image below drawing")
        app.buttons["studio.redo"].tap()
        XCTAssertLessThanOrEqual(try changedPixelCount(imageOnTop, pixels(canvas.screenshot().image)), 4,
                                "One Redo did not restore image above drawing")
        try orderImage("backward")
        XCTAssertLessThanOrEqual(try changedPixelCount(drawingOnTop, pixels(canvas.screenshot().image)), 4,
                                "Image Backward did not restore the original crossing")
        app.buttons["studio.undo"].tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(imageOnTop, pixels(canvas.screenshot().image)), 4)
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(imageOnTop, pixels(restored.screenshot().image)), 4,
                                "Cold reopening lost the persisted image-above-drawing order")
        capture(reopened, name: "same-layer-image-order-cold-reopened")
    }

    @MainActor
    func testImageFlipsUndoAndColdReopen() throws {
        let app = try launchGuestStudio(); defer { app.terminate() }
        let projectName = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let frame = canvas.frame
        try openImagePanel(app); try imageControl("studio.image.library", app: app).tap()
        let search = app.textFields["studio.image-library.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 8)); search.tap(); search.typeText("dragon\n")
        let dragon = app.buttons["studio.image-library.item.kenney.scribble-dungeons.dragon"]
        XCTAssertTrue(dragon.waitForExistence(timeout: 5)); dragon.tap()
        try imageControl("studio.image.apply", app: app).tap()
        XCTAssertTrue(try imageControl("studio.image.result", app: app).label.hasPrefix("Added Dungeon Dragon"))
        try closeImagePanel(app); try settlePickerCanvasAfterSave(app, canvas: canvas)
        func flip(_ axis: String) throws {
            try selectToolbarTool("move", app: app)
            let control = app.buttons["studio.image-flip." + axis]
            XCTAssertTrue(control.waitForExistence(timeout: 5))
            let popup = app.descendants(matching: .any)["studio.tool-settings"].firstMatch
            for _ in 0..<4 where !control.isHittable {
                let scroll = popup.scrollViews.firstMatch
                XCTAssertTrue(scroll.exists); scroll.swipeUp(velocity: .slow)
            }
            XCTAssertTrue(control.isHittable)
            XCTAssertTrue(expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: control).waitUntilFulfilled(timeout: 8))
            XCTAssertEqual(control.value as? String, "Original")
            control.tap()
            XCTAssertTrue(expectation(for: NSPredicate(format: "value == %@", "Flipped"), evaluatedWith: control).waitUntilFulfilled(timeout: 5))
            capture(app, name: "image-flip-" + axis + "-control")
            app.buttons["studio.tool-settings.close"].tap()
            try settlePickerCanvasAfterSave(app, canvas: canvas)
        }
        let original = try pixels(canvas.screenshot().image)
        try flip("horizontal")
        let horizontal = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(original, horizontal), 100, "Horizontal flip did not change actual artwork")
        app.buttons["studio.undo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4, "One Undo failed")
        app.buttons["studio.redo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(horizontal, pixels(canvas.screenshot().image)), 4, "One Redo failed")
        try flip("vertical")
        let both = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(horizontal, both), 100, "Vertical flip did not change actual artwork")
        capture(app, name: "image-both-flips-applied")
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(both, pixels(restored.screenshot().image)), 4, "Cold reopen lost reflected image pixels")
        capture(reopened, name: "image-flips-cold-reopened")
    }

    @MainActor
    func testImageCanvasDragUndoAndColdReopen() throws {
        let app = try launchGuestStudio();defer { app.terminate() }
        let projectName = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let frame = canvas.frame
        try openImagePanel(app);try imageControl("studio.image.library", app: app).tap()
        let search = app.textFields["studio.image-library.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 8));search.tap();search.typeText("dragon\n")
        let dragon = app.buttons["studio.image-library.item.kenney.scribble-dungeons.dragon"]
        XCTAssertTrue(dragon.waitForExistence(timeout: 5));dragon.tap()
        try imageControl("studio.image.apply", app: app).tap()
        XCTAssertTrue(try imageControl("studio.image.result", app: app).label.hasPrefix("Added Dungeon Dragon"))
        try closeImagePanel(app);try settlePickerCanvasAfterSave(app, canvas: canvas)
        func control(_ id: String) throws -> XCUIElement {
            let button = app.buttons[id]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            let popup = app.descendants(matching: .any)["studio.tool-settings"].firstMatch
            for _ in 0..<4 where !button.isHittable {
                let scroll = popup.scrollViews.firstMatch
                XCTAssertTrue(scroll.exists);scroll.swipeUp(velocity: .slow)
            }
            XCTAssertTrue(button.isHittable)
            XCTAssertTrue(expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: button).waitUntilFulfilled(timeout: 8))
            return button
        }
        try selectToolbarTool("move", app: app)
        try control("studio.image-placement.open").tap()
        try control("studio.image-placement.half").tap()
        try control("studio.image-placement.apply").tap()
        try control("studio.image-move.target").tap()
        XCTAssertEqual(app.buttons["studio.image-move.target"].value as? String, "Image")
        app.buttons["studio.tool-settings.close"].tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertTrue((canvas.value as? String)?.contains("Selected image") == true)
        let selected = try pixels(canvas.screenshot().image)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.68, dy: 0.65)))
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let moved = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(selected, moved), 100, "Real image drag changed no canvas pixels")
        capture(app, name: "image-canvas-drag")
        app.buttons["studio.undo"].tap();try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(selected, pixels(canvas.screenshot().image)), 4, "One Undo lost the prior image placement")
        app.buttons["studio.redo"].tap();try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(moved, pixels(canvas.screenshot().image)), 4, "One Redo lost the moved image")
        // Compare persisted artwork without transient red selection decoration.
        try selectToolbarTool("move", app: app);try control("studio.image-move.target").tap()
        XCTAssertEqual(app.buttons["studio.image-move.target"].value as? String, "Drawings")
        app.buttons["studio.tool-settings.close"].tap();try waitForStableCanvas(canvas, expected: frame)
        let plainMoved = try pixels(canvas.screenshot().image)
        app.buttons["studio.back"].tap();app.terminate()
        let reopened = try launchGuestStudio();defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8));project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(plainMoved, pixels(restored.screenshot().image)), 4, "Cold reopen lost dragged image pixels")
        capture(reopened, name: "image-canvas-drag-cold-reopened")
    }

    @MainActor
    func testImageCropCancelApplyUndoAndColdReopen() throws {
        // Measured at 133.467s; retain the standard 180s case limit.
        let app = try launchGuestStudio(); defer { app.terminate() }
        let projectName = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas); let frame = canvas.frame
        try openImagePanel(app); try imageControl("studio.image.library", app: app).tap()
        let search = app.textFields["studio.image-library.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 8)); search.tap(); search.typeText("dragon\n")
        let dragon = app.buttons["studio.image-library.item.kenney.scribble-dungeons.dragon"]
        XCTAssertTrue(dragon.waitForExistence(timeout: 5)); dragon.tap()
        try imageControl("studio.image.apply", app: app).tap()
        XCTAssertTrue(try imageControl("studio.image.result", app: app).label.hasPrefix("Added Dungeon Dragon"))
        try closeImagePanel(app); try settlePickerCanvasAfterSave(app, canvas: canvas)
        let original = try pixels(canvas.screenshot().image)
        func control(_ suffix: String) throws -> XCUIElement {
            let button = app.buttons["studio.image-crop." + suffix]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            let popup = app.descendants(matching: .any)["studio.tool-settings"].firstMatch
            for _ in 0..<4 where !button.isHittable { popup.scrollViews.firstMatch.swipeUp(velocity: .slow) }
            XCTAssertTrue(button.isHittable)
            XCTAssertTrue(expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: button).waitUntilFulfilled(timeout: 8))
            return button
        }
        func halveCrop() throws {
            try control("open").tap()
            let width = app.textFields["studio.image-crop.width"]
            XCTAssertTrue(width.waitForExistence(timeout: 5)); width.tap()
            let value = try XCTUnwrap(width.value as? String)
            width.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count) + "50")
            let done = app.buttons["studio.text.keyboard-dismiss"]
            XCTAssertTrue(done.waitForExistence(timeout: 5)); done.tap()
            XCTAssertEqual(width.value as? String, "50")
        }
        try selectToolbarTool("move", app: app); try halveCrop()
        capture(app, name: "image-crop-draft")
        try control("cancel").tap(); app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(canvas, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4, "Cancel changed original pixels")
        try selectToolbarTool("move", app: app); try halveCrop(); try control("apply").tap()
        app.buttons["studio.tool-settings.close"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        let cropped = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(original, cropped), 100, "Crop changed controls without changing artwork")
        capture(app, name: "image-crop-applied")
        app.buttons["studio.undo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4)
        app.buttons["studio.redo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(cropped, pixels(canvas.screenshot().image)), 4)
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(cropped, pixels(restored.screenshot().image)), 4, "Cold reopen lost crop pixels")
        capture(reopened, name: "image-crop-cold-reopened")
    }

    @MainActor
    func testImagePlacementCancelApplyUndoAndColdReopen() throws {
        // Run 35600568119 attempt 2 reached cold reopen/export at the 180s limit.
        executionTimeAllowance = 240
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let projectName = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let frame = canvas.frame
        try openImagePanel(app)
        try imageControl("studio.image.library", app: app).tap()
        let search = app.textFields["studio.image-library.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 8)); search.tap(); search.typeText("dragon\n")
        let dragon = app.buttons["studio.image-library.item.kenney.scribble-dungeons.dragon"]
        XCTAssertTrue(dragon.waitForExistence(timeout: 5)); dragon.tap()
        try imageControl("studio.image.apply", app: app).tap()
        XCTAssertTrue(try imageControl("studio.image.result", app: app).label.hasPrefix("Added Dungeon Dragon"))
        try closeImagePanel(app)
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let original = try pixels(canvas.screenshot().image)
        func control(_ suffix: String) throws -> XCUIElement {
            let button = app.buttons["studio.image-placement." + suffix]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            let popup = app.descendants(matching: .any)["studio.tool-settings"].firstMatch
            for _ in 0..<4 where !button.isHittable {
                let scroll = popup.scrollViews.firstMatch
                XCTAssertTrue(scroll.exists, "Image settings have no reachable popup scroll container")
                scroll.swipeUp(velocity: .slow)
            }
            XCTAssertTrue(button.isHittable)
            return button
        }
        try selectToolbarTool("move", app: app)
        let open = try control("open")
        XCTAssertTrue(expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: open).waitUntilFulfilled(timeout: 8))
        open.tap()
        let width = app.textFields["studio.image-placement.width"]
        XCTAssertTrue(width.waitForExistence(timeout: 5))
        let originalWidth = try XCTUnwrap(Double(try XCTUnwrap(width.value as? String)))
        try control("half").tap()
        XCTAssertEqual(try XCTUnwrap(Double(try XCTUnwrap(width.value as? String))), originalWidth / 2, accuracy: 0.000001)
        capture(app, name: "image-position-draft")
        try control("cancel").tap()
        app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(canvas, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4, "Cancel changed image pixels")
        try selectToolbarTool("move", app: app)
        try control("open").tap(); try control("half").tap()
        let x = app.textFields["studio.image-placement.x"]
        XCTAssertTrue(x.waitForExistence(timeout: 5)); x.tap()
        let existing = try XCTUnwrap(x.value as? String)
        x.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count) + "0")
        let done = app.buttons["studio.text.keyboard-dismiss"]
        XCTAssertTrue(done.waitForExistence(timeout: 5)); done.tap()
        XCTAssertEqual(x.value as? String, "0", "Image position field did not accept real keyboard input")
        try control("apply").tap()
        app.buttons["studio.tool-settings.close"].tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let placed = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(original, placed), 100, "Image size changed controls without changing real canvas pixels")
        capture(app, name: "image-position-applied")
        app.buttons["studio.undo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4, "One Undo did not restore image placement")
        app.buttons["studio.redo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(placed, pixels(canvas.screenshot().image)), 4, "One Redo did not restore image placement")
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(placed, pixels(restored.screenshot().image)), 4, "Cold reopen lost actual image placement pixels")
        capture(reopened, name: "image-position-cold-reopened")
    }

    @MainActor
    func testTwoIndependentImagesUndoAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let projectName = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let frame = canvas.frame, blank = try pixels(canvas.screenshot().image)
        try importLicensedImageForExport(app, canvas: canvas)
        // Make the first source smaller so the second source behind it has
        // visible pixels outside its bounds; identical or replaced art cannot
        // satisfy both the retained-outline and changed-canvas checks.
        try selectToolbarTool("move", app: app)
        try fillPreferenceControl("studio.image-placement.open", app: app).tap()
        try fillPreferenceControl("studio.image-placement.half", app: app).tap()
        try fillPreferenceControl("studio.image-placement.apply", app: app).tap()
        app.buttons["studio.tool-settings.close"].tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let first = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(blank, first), 100)
        let firstDark = (0..<(first.width * first.height)).filter { pixel in
            (0..<3).allSatisfy { first.bytes[pixel * 4 + $0] < 64 }
        }
        XCTAssertGreaterThan(firstDark.count, 100)
        capture(app, name: "independent-images-first-dragon")
        try openImagePanel(app)
        try imageControl("studio.image.library", app: app).tap()
        let search = app.textFields["studio.image-library.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 8)); search.tap(); search.typeText("chest\n")
        let chest = app.buttons["studio.image-library.item.kenney.scribble-dungeons.chest"]
        XCTAssertTrue(chest.waitForExistence(timeout: 8)); XCTAssertTrue(chest.isHittable); chest.tap()
        _ = try imageControl("studio.image.preview", app: app)
        XCTAssertTrue(app.staticTexts["studio.image.attribution"].label.contains("CC0-1.0"))
        try imageControl("studio.image.apply", app: app).tap()
        XCTAssertTrue(try imageControl("studio.image.result", app: app).label.hasPrefix("Added Dungeon Treasure Chest on a new image layer"))
        try closeImagePanel(app)
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let both = try pixels(canvas.screenshot().image)
        XCTAssertEqual(first.width, both.width); XCTAssertEqual(first.height, both.height)
        XCTAssertGreaterThan(try changedPixelCount(first, both), 100, "Second independent source added no visible artwork")
        let retainedDark = firstDark.filter { pixel in
            (0..<3).allSatisfy { both.bytes[pixel * 4 + $0] < 96 }
        }.count
        XCTAssertEqual(retainedDark, firstDark.count, "Second import replaced the foreground Dragon")
        capture(app, name: "independent-images-dragon-and-chest")
        app.buttons["studio.undo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(first, pixels(canvas.screenshot().image)), 4,
                                "One Undo did not remove only the second source")
        app.buttons["studio.redo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(both, pixels(canvas.screenshot().image)), 4)
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(both, pixels(restored.screenshot().image)), 4,
                                "Cold reopen lost either independent image source")
        capture(reopened, name: "independent-images-cold-reopened")
    }

    @MainActor
    func testLicensedImageLibraryUndoAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let projectName = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let frame = canvas.frame, before = try pixels(canvas.screenshot().image)
        app.buttons["studio.menu.open"].tap()
        let spatter = app.buttons["studio.spatter.open"]
        XCTAssertTrue(spatter.waitForExistence(timeout: 8)); spatter.tap()
        let localEdits = app.buttons["spatter.studio.local-motion"]
        XCTAssertTrue(localEdits.waitForExistence(timeout: 8)); XCTAssertTrue(localEdits.isHittable); localEdits.tap()
        try localMotionControl("spatter.picture.apply", app: app).tap()
        XCTAssertTrue(app.buttons["studio.image.files"].waitForExistence(timeout: 8))
        capture(app, name: "spatter-explicit-picture-import-handoff")
        try imageControl("studio.image.library", app: app).tap()
        let count = app.staticTexts["studio.image-library.count"]
        XCTAssertTrue(count.waitForExistence(timeout: 8))
        XCTAssertEqual(count.label, "207 free pictures · available offline")
        let search = app.textFields["studio.image-library.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("dragon\n")
        let picture = app.buttons["studio.image-library.item.kenney.scribble-dungeons.dragon"]
        XCTAssertTrue(picture.waitForExistence(timeout: 5)); XCTAssertTrue(picture.isHittable)
        capture(app, name: "licensed-image-library-search")
        picture.tap()
        let preview = try imageControl("studio.image.preview", app: app)
        let previewRaster = try pixels(preview.screenshot().image)
        // These licensed PNGs are monochrome. The export fixture's red-only
        // detector cannot measure their white fill and dark outlines.
        let light = (0..<(previewRaster.width * previewRaster.height)).filter { pixel in
            (0..<3).allSatisfy { previewRaster.bytes[pixel * 4 + $0] > 192 }
        }.count
        let dark = (0..<(previewRaster.width * previewRaster.height)).filter { pixel in
            (0..<3).allSatisfy { previewRaster.bytes[pixel * 4 + $0] < 96 }
        }.count
        XCTAssertGreaterThan(light, 25, "Library preview has no actual light artwork")
        XCTAssertGreaterThan(dark, 25, "Library preview lost its outline/background contrast")
        XCTAssertTrue(app.staticTexts["studio.image.dimensions"].label.hasPrefix("64 × 64 pixels"))
        XCTAssertTrue(app.staticTexts["studio.image.attribution"].label.contains("CC0-1.0"))
        try imageControl("studio.image.apply", app: app).tap()
        let receipt = try imageControl("studio.image.result", app: app)
        XCTAssertTrue(receipt.label.hasPrefix("Added Dungeon Dragon on a new image layer"))
        try closeImagePanel(app)
        try waitForStableCanvas(canvas, expected: frame)
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let edited = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(before, edited), 100, "Library Add did not change actual canvas pixels")
        capture(app, name: "licensed-image-library-added")
        app.buttons["studio.undo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(before, pixels(canvas.screenshot().image)), 4)
        XCTAssertFalse(app.buttons["studio.undo"].isEnabled, "Library Add needs more than one Undo")
        app.buttons["studio.redo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(edited, pixels(canvas.screenshot().image)), 4)
        app.buttons["studio.back"].tap(); app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let restored = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(restored, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(edited, pixels(restored.screenshot().image)), 4,
                                "Cold reopen changed actual library artwork")
        capture(reopened, name: "licensed-image-library-cold-reopened")
        try openExportPanel(reopened)
        try exportControl("studio.export.format.png", app: reopened, scrollUp: false).tap()
        try exportControl("studio.export.start", app: reopened).tap()
        _ = try waitForPNGPreview(reopened)
        let credits = try exportControl("studio.export.image-credits", app: reopened)
        XCTAssertEqual(credits.label, "1 image credit included in manifest")
        capture(reopened, name: "licensed-image-export-credit")
    }

    @MainActor
    func testImagePhotosAndFilesCancellationPreserveProject() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        _ = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 8))
        let before = try pixels(canvas.screenshot().image)
        try openImagePanel(app)
        app.buttons["studio.image.photos"].tap()
        let cancelPhotos = app.navigationBars.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancelPhotos.waitForExistence(timeout: 10))
        capture(app, name: "image-native-photos-cancel-picker")
        captureHierarchy(app, name: "image-native-photos-cancel-hierarchy")
        try waitForHittable(cancelPhotos, app: app, name: "image-photos-cancel-ready"); cancelPhotos.tap()
        let files = app.buttons["studio.image.files"]
        XCTAssertTrue(files.waitForExistence(timeout: 8)); XCTAssertTrue(files.isEnabled)
        files.tap()
        let filesNavigation = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"]
        let cancelFiles = filesNavigation.buttons["Cancel"]
        XCTAssertTrue(cancelFiles.waitForExistence(timeout: 10))
        XCTAssertTrue(app.collectionViews["File View"].exists)
        capture(app, name: "image-native-files-picker")
        captureHierarchy(app, name: "image-native-files-picker-hierarchy")
        XCTAssertTrue(cancelFiles.isHittable); cancelFiles.tap()
        let result = app.staticTexts["studio.image.result"]
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@",
            "Image import cancelled. No image was added by this pending selection."),
            evaluatedWith: result).waitUntilFulfilled(timeout: 8))
        XCTAssertFalse(app.buttons["studio.image.apply"].exists)
        // A fresh Photos presentation must still work after Files cancellation.
        let photos = app.buttons["studio.image.photos"]
        XCTAssertTrue(photos.isEnabled); photos.tap()
        try waitForHittable(cancelPhotos, app: app, name: "image-photos-second-cancel-ready"); cancelPhotos.tap()
        try closeImagePanel(app)
        XCTAssertFalse(app.buttons["studio.undo"].isEnabled)
        XCTAssertLessThanOrEqual(try changedPixelCount(before, pixels(canvas.screenshot().image)), 4)
        capture(app, name: "image-pickers-cancelled-unchanged-canvas")
    }

    @MainActor
    func testPhotoImportUndoPersistenceAndRealPNGExport() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let projectName = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 8))
        let before = try pixels(canvas.screenshot().image)
        try openImagePanel(app)
        app.buttons["studio.image.photos"].tap()
        XCTAssertTrue(app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 10))
        capture(app, name: "image-native-photos-fixture-picker")
        captureHierarchy(app, name: "image-native-photos-fixture-hierarchy")
        // CI adds an original generated four-color PNG to the system Photos
        // library. Locate its actual visible thumbnail by decoded pixels;
        // neither an app launch flag nor a hidden importer can satisfy this.
        let readyDeadline = Date().addingTimeInterval(30)
        var selected = false
        var capturedReadyGrid = false
        repeat {
            // This system picker exposes custom thumbnail Images whose
            // isHittable is false despite visible pixels. Resolve only the
            // observed Photos viewport and verify the actual thumbnail before
            // deriving a tap from its current frame; never use fixed positions.
            let photos = app.navigationBars["Photos"].firstMatch
            // These are the actual system viewport identifiers captured on
            // iOS 26.2 and 18.5. Require one visible Photos grid, never a generic
            // application scroll view or an arbitrary image outside the picker.
            let viewports = app.scrollViews.matching(NSPredicate(format: "identifier IN %@",
                ["photosView_content_scroll_view", "content_scroll_view"]))
                .allElementsBoundByIndex.prefix(3).filter {
                    $0.exists && !$0.frame.intersection(app.frame).isEmpty &&
                    $0.images.matching(identifier: "PXGGridLayout-Info").count > 0
                }
            if photos.exists, viewports.count == 1, let viewport = viewports.first {
                let visibleBounds = viewport.frame.intersection(app.frame)
                let candidates = viewport.images.matching(identifier: "PXGGridLayout-Info").allElementsBoundByIndex
                for candidate in candidates.prefix(12) {
                    guard Date() < readyDeadline else { break }
                    guard candidate.exists else { continue }
                    let frame = candidate.frame
                    guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy({ $0.isFinite }),
                          frame.width > 24, frame.height > 24, visibleBounds.contains(frame) else { continue }
                    if !capturedReadyGrid {
                        capture(app, name: "image-photos-grid-ready")
                        captureHierarchy(app, name: "image-photos-grid-ready-hierarchy")
                        capturedReadyGrid = true
                    }
                    let colors = imageFixtureColors(try pixels(candidate.screenshot().image))
                    if colors.allSatisfy({ $0 > 8 }) {
                        guard Date() < readyDeadline, photos.exists, viewport.exists, candidate.exists,
                              candidate.frame == frame,
                              viewport.frame.intersection(app.frame).contains(frame) else { continue }
                        candidate.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                        selected = true
                        break
                    }
                }
            }
            if !selected { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        } while !selected && Date() < readyDeadline
        if !selected {
            capture(app, name: "image-photos-grid-timeout")
            captureHierarchy(app, name: "image-photos-grid-timeout-hierarchy")
        }
        XCTAssertTrue(selected, "The generated fixture was not visible in the actual Photos grid; inspect the captured hierarchy")
        let preview = try imageControl("studio.image.preview", app: app)
        XCTAssertTrue(imageFixtureColors(try pixels(preview.screenshot().image)).allSatisfy({ $0 > 20 }),
                      "Decoded preview does not contain the selected still-image pixels")
        XCTAssertTrue(app.staticTexts["studio.image.dimensions"].label.hasPrefix("96 × 64 pixels"))
        capture(app, name: "image-decoded-photos-preview")
        try imageControl("studio.image.apply", app: app).tap()
        let receipt = try imageControl("studio.image.result", app: app)
        XCTAssertTrue(receipt.label.hasPrefix("Added "))
        XCTAssertTrue(receipt.label.hasSuffix("on a new image layer in one undoable edit."))
        XCTAssertTrue(["Unsaved", "Saving…", "Saved"].contains(app.staticTexts["studio.image.save-state"].label),
                      "Attachment must report the actual current autosave state")
        capture(app, name: "image-attached-save-receipt")
        try closeImagePanel(app)
        let edited = try pixels(canvas.screenshot().image)
        XCTAssertTrue(imageFixtureColors(edited).allSatisfy({ $0 > 20 }))
        let undo = app.buttons["studio.undo"], redo = app.buttons["studio.redo"]
        XCTAssertTrue(undo.isEnabled); undo.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: redo).waitUntilFulfilled(timeout: 5))
        XCTAssertLessThanOrEqual(try changedPixelCount(before, pixels(canvas.screenshot().image)), 4)
        XCTAssertFalse(undo.isEnabled, "Image attachment required more than one Undo")
        redo.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: undo).waitUntilFulfilled(timeout: 5))
        XCTAssertLessThanOrEqual(try changedPixelCount(edited, pixels(canvas.screenshot().image)), 4)
        let save = app.buttons["studio.save"]; save.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "Saved"), evaluatedWith: save).waitUntilFulfilled(timeout: 8))
        try openExportPanel(app)
        try exportControl("studio.export.format.png", app: app, scrollUp: false).tap()
        try exportControl("studio.export.start", app: app).tap()
        let exported = try pixels(waitForPNGPreview(app).screenshot().image)
        XCTAssertTrue(imageFixtureColors(exported).allSatisfy({ $0 > 20 }), "Actual exported PNG lost the imported still")
        capture(app, name: "image-real-png-export-preview")
        try closeExportPanel(app)
        app.buttons["studio.back"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch.waitForExistence(timeout: 8))
        app.terminate()
        let reopened = try launchGuestStudio()
        defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let reopenedCanvas = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        XCTAssertTrue(reopenedCanvas.waitForExistence(timeout: 8))
        XCTAssertLessThanOrEqual(try changedPixelCount(edited, pixels(reopenedCanvas.screenshot().image)), 4,
                                 "Saved imported image failed actual terminate/relaunch/reopen")
        capture(reopened, name: "image-photos-persisted-reopened")
    }

    /// Proposed eleventh native journey. It must execute against the real app;
    /// compilation alone does not verify encoded files or UIKit presentation.
    @MainActor
    func testMP4ExportReceiptAndNativeShareCancellation() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        _ = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 8)); XCTAssertTrue(canvas.isHittable)
        try importLicensedImageForExport(app, canvas: canvas)
        let before = try pixels(canvas.screenshot().image)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.4)).press(forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6)))
        XCTAssertTrue(expectation(for: NSPredicate(format: "enabled == true"),
            evaluatedWith: app.buttons["studio.undo"]).waitUntilFulfilled(timeout: 5))
        XCTAssertGreaterThan(try changedPixelCount(before, pixels(canvas.screenshot().image)), 12)
        try openExportPanel(app)
        try exportControl("studio.export.format.mp4", app: app, scrollUp: false).tap()
        let backgrounds = app.segmentedControls["studio.export.movie.background"]
        XCTAssertTrue(backgrounds.waitForExistence(timeout: 8))
        let transparent = backgrounds.buttons["Transparent (unsupported)"]
        XCTAssertTrue(transparent.isHittable); transparent.tap()
        try exportControl("studio.export.start", app: app).tap()
        let status = app.staticTexts["studio.export.status"]
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@",
            "H.264 MP4 cannot retain transparency. Explicitly choose the white background to export."),
            evaluatedWith: status).waitUntilFulfilled(timeout: 8))
        XCTAssertFalse(app.staticTexts["studio.export.movie.filename"].exists)
        XCTAssertFalse(app.buttons["studio.export.share"].exists)
        capture(app, name: "mp4-transparency-rejected")
        _ = try exportControl("studio.export.movie.background", app: app, scrollUp: false)
        XCTAssertTrue(backgrounds.buttons["White"].isHittable); backgrounds.buttons["White"].tap()
        try exportControl("studio.export.start", app: app).tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "label BEGINSWITH %@", "MP4 ready on this device from revision "),
            evaluatedWith: status).waitUntilFulfilled(timeout: 30))
        let receipt = try exportControl("studio.export.movie.receipt", app: app)
        XCTAssertEqual(try exportControl("studio.export.movie.image-credits", app: app).label,
                       "1 image credit included in manifest")
        XCTAssertTrue(receipt.label.contains("1,080 × 1,920"), "The generated portrait fixture was rescaled")
        XCTAssertTrue(receipt.label.contains("1 frames · 12 fps · revision "))
        XCTAssertEqual(app.staticTexts["studio.export.movie.filename"].label, "animation.mp4")
        XCTAssertFalse(app.descendants(matching: .any)["studio.export.preview"].exists,
                       "This slice must not show a fake video preview")
        capture(app, name: "mp4-actual-file-receipt")
        let share = try exportControl("studio.export.share", app: app)
        XCTAssertTrue(share.isEnabled); share.tap()
        let nativeShare = app.otherElements["ShareSheet.RemoteContainerView"].firstMatch
        let saveToFiles = nativeShare.cells.matching(NSPredicate(format: "label == %@", "Save to Files")).firstMatch
        let presented = saveToFiles.waitForExistence(timeout: 10)
        capture(app, name: "mp4-native-share-sheet")
        captureHierarchy(app, name: "mp4-native-share-sheet-hierarchy")
        XCTAssertTrue(presented); XCTAssertTrue(saveToFiles.isHittable)
        let dismiss = nativeShare.buttons["header.closeButton"]
        XCTAssertTrue(dismiss.isHittable); dismiss.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: dismiss).waitUntilFulfilled(timeout: 8))
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "Sharing cancelled. The MP4 remains available."),
            evaluatedWith: status).waitUntilFulfilled(timeout: 8))
        XCTAssertTrue(try exportControl("studio.export.share", app: app).isEnabled,
                      "Cancelling the real share sheet lost the owned MP4")
        capture(app, name: "mp4-share-cancelled-retained-receipt")
        try closeExportPanel(app)
        XCTAssertTrue(canvas.isHittable)
    }

    /// Real native consumer -> local Files copy -> source disposal/re-export ->
    /// cold launch -> real AVFoundation-backed Files import. No file seeding.
    @MainActor
    func testMP4FilesSaveSurvivesReexportAndColdSourceDisposal() throws {
        var app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let projectName = try createProjectIfLibraryIsShown(app)
        let folderName = "SDI-MP4-" + String(UUID().uuidString.prefix(8))
        var canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.25)).press(forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.35)))
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertGreaterThan(exportInkMask(try pixels(canvas.screenshot().image)).count, 12)

        func localFilesRoot() throws {
            // Save to Files launches an asynchronous system extension. Wait for
            // its actual location controls before resolving the local root.
            let providerReady = NSPredicate { _, _ in
                app.navigationBars["FullDocumentManagerViewControllerNavigationBar"].exists
                    || app.otherElements["DOC.browsingRoot Source: com.apple.FileProvider.LocalStorage, Title: On My iPhone"].exists
                    || app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Browse", "Locations")).firstMatch.exists
            }
            guard expectation(for: providerReady, evaluatedWith: app).waitUntilFulfilled(timeout: 10) else {
                capture(app, name: "mp4-files-provider-transition-failed")
                captureHierarchy(app, name: "mp4-files-provider-transition-failed-hierarchy")
                XCTFail("Actual Files provider did not finish presenting")
                throw NSError(domain: "SDIMP4FilesUI", code: 2)
            }
            for _ in 0..<5 {
                if app.otherElements["DOC.browsingRoot Source: com.apple.FileProvider.LocalStorage, Title: On My iPhone"].exists { return }
                let local = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "On My iPhone"))
                    .allElementsBoundByIndex.first { $0.exists && $0.isHittable }
                if let local { local.tap(); return }
                let browse = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Browse", "Locations"))
                    .allElementsBoundByIndex.first { $0.exists && $0.isHittable }
                if let browse { browse.tap() } else { break }
            }
            captureHierarchy(app, name: "mp4-files-local-location-missing")
            XCTFail("Actual local Files location unavailable; never substitute cloud or a remembered destination")
            throw NSError(domain: "SDIMP4FilesUI", code: 1)
        }
        func renderMovie() throws {
            try openExportPanel(app)
            try exportControl("studio.export.format.mp4", app: app, scrollUp: false).tap()
            try exportControl("studio.export.start", app: app).tap()
            XCTAssertTrue(expectation(for: NSPredicate(format: "label BEGINSWITH %@", "MP4 ready on this device from revision "),
                evaluatedWith: app.staticTexts["studio.export.status"]).waitUntilFulfilled(timeout: 30))
            let receipt = try exportControl("studio.export.movie.receipt", app: app)
            XCTAssertTrue(receipt.label.contains("1,080 × 1,920"))
            XCTAssertTrue(receipt.label.contains("1 frames · 12 fps · revision "))
            XCTAssertEqual(app.staticTexts["studio.export.movie.filename"].label, "animation.mp4")
        }
        try renderMovie()
        try exportControl("studio.export.share", app: app).tap()
        let share = app.otherElements["ShareSheet.RemoteContainerView"].firstMatch
        let files = share.cells.matching(NSPredicate(format: "label == %@", "Save to Files")).firstMatch
        XCTAssertTrue(files.waitForExistence(timeout: 10)); XCTAssertTrue(files.isHittable); files.tap()
        try localFilesRoot()
        captureHierarchy(app, name: "mp4-files-before-create-isolated-folder")
        // These are real system actions. Missing accessibility is a test failure
        // with evidence, not permission to write directly into a provider sandbox.
        var newFolder = app.buttons["New Folder"].firstMatch
        if !newFolder.isHittable {
            let more = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "More", "More Options"))
                .allElementsBoundByIndex.first { $0.exists && $0.isHittable }
            try XCTUnwrap(more, "System Files folder-creation menu unavailable").tap()
            newFolder = app.buttons["New Folder"].firstMatch
        }
        XCTAssertTrue(newFolder.waitForExistence(timeout: 5)); XCTAssertTrue(newFolder.isHittable); newFolder.tap()
        // The observed iOS18 provider creates a folder with an inline rename
        // field, not an alert. Only rename this newly focused system field.
        let folderInput = app.textViews["DOC.inlineRenameField"]
        XCTAssertTrue(folderInput.waitForExistence(timeout: 5)); XCTAssertTrue(folderInput.isHittable)
        if let value = folderInput.value as? String, !value.isEmpty {
            folderInput.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        folderInput.typeText(folderName)
        let done = app.keyboards.buttons["Done"]
        XCTAssertTrue(done.isHittable); done.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: folderInput)
            .waitUntilFulfilled(timeout: 5), "Actual folder rename must finish before choosing the destination")
        let destination = app.collectionViews["File View"].cells.matching(NSPredicate(format: "label CONTAINS %@", folderName)).firstMatch
        if destination.waitForExistence(timeout: 3) && destination.isHittable { destination.tap() }
        // Files exposes the folder title as an Actions Menu button. Match the
        // observed browsing-root identity to prove this exact local destination.
        let localDestination = app.otherElements["DOC.browsingRoot Source: com.apple.FileProvider.LocalStorage, Title: " + folderName]
        XCTAssertTrue(localDestination.waitForExistence(timeout: 5),
                      "Saving must target this test's unique local folder")
        captureHierarchy(app, name: "mp4-files-isolated-destination")
        let save = app.navigationBars.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Save", "Move"))
            .allElementsBoundByIndex.first { $0.exists && $0.isHittable }
        try XCTUnwrap(save, "Actual Files Save action missing").tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "The share sheet reported completion."),
            evaluatedWith: app.staticTexts["studio.export.status"]).waitUntilFulfilled(timeout: 15))
        capture(app, name: "mp4-files-real-share-completion")
        try closeExportPanel(app) // Ordinary production session.close disposes owned output.
        try waitForStableCanvas(canvas)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.75)).press(forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.75)))
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let secondCanvas = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(exportInkMask(secondCanvas).filter {
            Double($0 / secondCanvas.width) > Double(secondCanvas.height) * 0.65
        }.count, 12, "Second draw must visibly commit before testing export independence")
        try renderMovie() // New output differs; the first destination must remain first content.
        let secondPicture = try exportControl("studio.export.movie.preview", app: app)
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "Preview ready"),
            evaluatedWith: app.staticTexts["studio.export.movie.preview.status"]).waitUntilFulfilled(timeout: 8))
        let decodedLowerStroke = NSPredicate { _, _ in
            guard let raster = try? self.moviePreviewPixels(secondPicture, app: app) else { return false }
            return self.exportInkMask(raster).filter {
                Double($0 / raster.width) > Double(raster.height) * 0.65
            }.count > 12
        }
        XCTAssertTrue(expectation(for: decodedLowerStroke, evaluatedWith: nil).waitUntilFulfilled(timeout: 8),
                      "Actual second MP4 decoder must display the newly added lower stroke")
        capture(app, name: "mp4-files-second-real-export")
        try closeExportPanel(app)
        app.buttons["studio.back"].tap(); app.terminate()
        app = try launchGuestStudio()
        let project = app.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        app.buttons["studio.menu.open"].tap()
        try waitForButton("Rotoscope / Video", in: app).tap()
        let importFiles = app.buttons["studio.image.files"]
        XCTAssertTrue(importFiles.waitForExistence(timeout: 8)); importFiles.tap()
        try localFilesRoot()
        let savedFolder = app.collectionViews["File View"].cells.matching(NSPredicate(format: "label CONTAINS %@", folderName)).firstMatch
        XCTAssertTrue(savedFolder.waitForExistence(timeout: 8)); XCTAssertTrue(savedFolder.isHittable); savedFolder.tap()
        let movie = app.collectionViews["File View"].cells.matching(NSPredicate(format: "label CONTAINS %@", "animation")).firstMatch
        XCTAssertTrue(movie.waitForExistence(timeout: 8)); XCTAssertTrue(movie.isHittable); movie.tap()
        let preview = try imageControl("studio.image.preview", app: app)
        XCTAssertTrue(app.staticTexts["studio.image.dimensions"].label.hasPrefix("1,080 × 1,920 pixels"))
        XCTAssertTrue(try imageControl("studio.image.result", app: app).label.contains("Studio 0.000s"))
        let decoded = try pixels(preview.screenshot().image)
        let ink = exportInkMask(decoded)
        XCTAssertGreaterThan(ink.filter { Double($0 / decoded.width) < Double(decoded.height) * 0.5 }.count, 12,
                             "Independent saved movie did not decode the first upper stroke")
        XCTAssertEqual(ink.filter { Double($0 / decoded.width) > Double(decoded.height) * 0.65 }.count, 0,
                       "Re-export overwrote the first destination with the later lower stroke")
        capture(app, name: "mp4-files-cold-decoded-first-destination")
        app.buttons["studio.panel.close.Rotoscope / Video"].tap()
    }

    /// Actual animated GIF creation and native consumer cancellation; no public upload.
    @MainActor
    func testGIFExportFramesAndNativeShareCancellation() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        _ = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 8)); XCTAssertTrue(canvas.isHittable)
        let before = try pixels(canvas.screenshot().image)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.4)).press(forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6)))
        XCTAssertTrue(expectation(for: NSPredicate(format: "enabled == true"),
            evaluatedWith: app.buttons["studio.undo"]).waitUntilFulfilled(timeout: 5))
        XCTAssertGreaterThan(try changedPixelCount(before, pixels(canvas.screenshot().image)), 12)
        let add = app.buttons["studio.add-frame"]
        XCTAssertTrue(add.isHittable); add.tap() // second frame receives licensed artwork
        try importLicensedImageForExport(app, canvas: canvas)
        try openExportPanel(app)
        try exportControl("studio.export.format.gif", app: app, scrollUp: false).tap()
        try exportControl("studio.export.start", app: app).tap()
        let status = app.staticTexts["studio.export.status"]
        XCTAssertTrue(expectation(for: NSPredicate(format: "label BEGINSWITH %@", "GIF ready on this device from revision "),
            evaluatedWith: status).waitUntilFulfilled(timeout: 30))
        let receipt = try exportControl("studio.export.gif.receipt", app: app)
        XCTAssertEqual(try exportControl("studio.export.gif.image-credits", app: app).label,
                       "1 image credit included in manifest")
        XCTAssertTrue(receipt.label.contains("1,080 × 1,920"))
        XCTAssertTrue(receipt.label.contains("2 frames · 12 fps · revision "))
        XCTAssertEqual(app.staticTexts["studio.export.gif.filename"].label, "animation.gif")
        XCTAssertTrue(app.staticTexts["studio.export.gif.media"].label.contains("17 centiseconds · white · no audio"))
        let preview = try exportControl("studio.export.gif.preview", app: app)
        let first = try exportPreviewPixels(preview, app: app, name: "gif-actual-first-frame")
        XCTAssertGreaterThan(exportInkMask(first).count, 12, "GIF first-frame decode lost actual red drawing")
        capture(app, name: "gif-actual-two-frame-file-receipt")
        let share = try exportControl("studio.export.share", app: app)
        XCTAssertTrue(share.isEnabled); share.tap()
        let nativeShare = app.otherElements["ShareSheet.RemoteContainerView"].firstMatch
        let saveToFiles = nativeShare.cells.matching(NSPredicate(format: "label == %@", "Save to Files")).firstMatch
        XCTAssertTrue(saveToFiles.waitForExistence(timeout: 10)); XCTAssertTrue(saveToFiles.isHittable)
        capture(app, name: "gif-native-share-sheet")
        let dismiss = nativeShare.buttons["header.closeButton"]
        XCTAssertTrue(dismiss.isHittable); dismiss.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: dismiss).waitUntilFulfilled(timeout: 8))
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "Sharing cancelled. The GIF remains available."),
            evaluatedWith: status).waitUntilFulfilled(timeout: 8))
        XCTAssertTrue(try exportControl("studio.export.share", app: app).isEnabled)
        let retained = try exportPreviewPixels(try exportControl("studio.export.gif.preview", app: app),
            app: app, name: "gif-first-frame-after-sharing-cancelled")
        XCTAssertEqual(unmatchedExportInk(first, retained), 0, "Cancelling sharing changed actual GIF picture")
        capture(app, name: "gif-share-cancelled-file-retained")
        try closeExportPanel(app); XCTAssertTrue(canvas.isHittable)
    }

    @MainActor
    func testBundledAudioMP4AndNativeShareCancellation() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        _ = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 8) && canvas.isHittable)
        let before = try pixels(canvas.screenshot().image)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.4)).press(forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6)))
        XCTAssertTrue(expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["studio.undo"]).waitUntilFulfilled(timeout: 5))
        XCTAssertGreaterThan(try changedPixelCount(before, pixels(canvas.screenshot().image)), 12)
        app.buttons["studio.audio.open"].tap()
        let library = app.buttons["studio.audio.library.open"]
        XCTAssertTrue(library.waitForExistence(timeout: 5)); library.tap()
        let search = app.textFields["studio.audio.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Wood Cracking 02\n")
        try audioLibraryButton("studio.audio.catalogue.add.3b7a688684cf8d75a180aa50edd9f51e159635cb25432e82d3f32d9d173299e1", app: app).tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "1 clips"), evaluatedWith: app.staticTexts["studio.audio.clip-count"]).waitUntilFulfilled(timeout: 10))
        app.buttons["studio.audio.library.close"].tap()
        XCTAssertTrue(app.staticTexts["studio.audio.clip-timing"].label.contains("Start 0.00s"))
        app.sliders["studio.audio.volume"].adjust(toNormalizedSliderPosition: 0.4)
        app.buttons["studio.audio.close"].tap()
        // The pinned source is 0.2508125 seconds; four real frames at 12 fps
        // contain it without modifying the original source or extending export.
        let addFrame = app.buttons["studio.add-frame"]
        XCTAssertTrue(addFrame.isHittable)
        for _ in 0..<3 { addFrame.tap() }
        let save = app.buttons["studio.save"]; save.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "Saved"), evaluatedWith: save).waitUntilFulfilled(timeout: 8))
        try openExportPanel(app)
        try exportControl("studio.export.format.mp4", app: app, scrollUp: false).tap()
        try exportControl("studio.export.start", app: app).tap()
        let status = app.staticTexts["studio.export.status"]
        XCTAssertTrue(expectation(for: NSPredicate(format: "label CONTAINS %@", "Project audio is included as stereo AAC."), evaluatedWith: status).waitUntilFulfilled(timeout: 30))
        let receipt = try exportControl("studio.export.movie.receipt", app: app)
        XCTAssertTrue(receipt.label.contains("4 frames · 12 fps · revision "))
        XCTAssertTrue(try exportControl("studio.export.movie.media", app: app).label.contains("H.264 + AAC · white · stereo audio"))
        // Decode the actual first frame, seek into a later blank frame, then
        // finish playback before handing the same output to native sharing.
        let picture = try exportControl("studio.export.movie.preview", app: app)
        let previewStatus = app.staticTexts["studio.export.movie.preview.status"]
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "Preview ready"),
            evaluatedWith: previewStatus).waitUntilFulfilled(timeout: 8))
        let firstPicture = NSPredicate { _, _ in
            guard let raster = try? self.moviePreviewPixels(picture, app: app) else { return false }
            return self.exportForegroundMask(raster).count > 12
        }
        XCTAssertTrue(expectation(for: firstPicture, evaluatedWith: nil).waitUntilFulfilled(timeout: 8),
                      "The actual AVPlayerLayer never displayed the drawn first frame")
        capture(app, name: "mp4-actual-decoded-first-frame")
        let seek = try exportControl("studio.export.movie.preview.seek", app: app)
        seek.adjust(toNormalizedSliderPosition: 0.75)
        let timing = app.staticTexts["studio.export.movie.preview.time"]
        let sought = NSPredicate { _, _ in
            let parts = timing.label.split(separator: "/")
            guard let first = parts.first, let seconds = Double(first.trimmingCharacters(in: .whitespaces)),
                  seconds > 0.20 && seconds < 0.30 else { return false }
            return true
        }
        let reachedTime = expectation(for: sought, evaluatedWith: nil).waitUntilFulfilled(timeout: 8)
        if !reachedTime {
            capture(app, name: "mp4-seek-position-failure")
            captureHierarchy(app, name: "mp4-seek-position-failure-hierarchy")
        }
        XCTAssertTrue(reachedTime, "The MP4 decoder did not seek to the requested time; actual time: \(timing.label)")
        _ = try exportControl("studio.export.movie.preview", app: app)
        let blankPicture = NSPredicate { _, _ in
            guard let raster = try? self.moviePreviewPixels(picture, app: app) else { return false }
            return self.exportForegroundMask(raster).isEmpty
        }
        XCTAssertTrue(expectation(for: blankPicture, evaluatedWith: nil).waitUntilFulfilled(timeout: 8),
                      "Seeking did not display the actual later blank frame")
        capture(app, name: "mp4-actual-decoded-seek-frame")
        try exportControl("studio.export.movie.preview.play", app: app).tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "Playback finished"),
            evaluatedWith: previewStatus).waitUntilFulfilled(timeout: 8))
        capture(app, name: "mp4-bundled-audio-actual-receipt")
        try exportControl("studio.export.share", app: app).tap()
        let nativeShare = app.otherElements["ShareSheet.RemoteContainerView"].firstMatch
        let files = nativeShare.cells.matching(NSPredicate(format: "label == %@", "Save to Files")).firstMatch
        let dismiss = nativeShare.buttons["header.closeButton"]
        // Run35527329460 recorded the real MP4 share sheet and Save to Files,
        // but the action's first AX snapshots had no application children.
        // Wait for usable remote actions within the existing ten-second bound.
        // Do not retap Share, use coordinates, skip or substitute an app mock.
        let shareReady = expectation(for: NSPredicate { _, _ in
            nativeShare.exists && files.exists && files.isHittable && dismiss.isHittable
        }, evaluatedWith: nil).waitUntilFulfilled(timeout: 10)
        if !shareReady {
            capture(app, name: "mp4-native-share-readiness-failure")
            captureHierarchy(app, name: "mp4-native-share-readiness-failure-hierarchy")
        }
        XCTAssertTrue(shareReady, "Native MP4 share actions did not become accessible")
        capture(app, name: "mp4-bundled-audio-native-share")
        XCTAssertTrue(dismiss.isHittable); dismiss.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: dismiss).waitUntilFulfilled(timeout: 8))
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "Sharing cancelled. The MP4 remains available."), evaluatedWith: status).waitUntilFulfilled(timeout: 8))
        XCTAssertTrue(try exportControl("studio.export.share", app: app).isEnabled)
        capture(app, name: "mp4-bundled-audio-retained-after-share-cancel")
        try closeExportPanel(app)
        XCTAssertTrue(canvas.isHittable)
    }

    @MainActor
    func testEyedropperArtworkAndTransformedCanvas() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        _ = try createProjectIfLibraryIsShown(app)
        let prepared = try preparePickerSourceStroke(app)
        let canvas = prepared.canvas, original = prepared.original
        let undo = app.buttons["studio.undo"], redo = app.buttons["studio.redo"]
        try choosePickerTestColor("#FF0000", app:app)
        try pickerRailControl("studio.tool.eyedropper", app:app, forward:true).tap()
        canvas.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.2)).tap()
        let whiteReceipt = app.staticTexts["Sampled #FFFFFF from visible artwork."]
        XCTAssertTrue(whiteReceipt.waitForExistence(timeout:8),"Blank artwork did not sample actual white")
        try settlePickerCanvasAfterSave(app,canvas:canvas)
        XCTAssertFalse(redo.isEnabled)
        XCTAssertLessThanOrEqual(try changedPixelCount(original,pixels(canvas.screenshot().image)),4,
            "Sampling wrote pixels to the document")

        // Use the real Hand and zoom controls, then sample the center of the
        // actual transformed canvas. Its original blue line crosses center.
        try pickerRailControl("studio.tool.hand", app:app, forward:true).tap()
        app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(canvas)
        let beforePan = canvas.frame
        canvas.coordinate(withNormalizedOffset:CGVector(dx:0.45,dy:0.75)).press(forDuration:0.05,
            thenDragTo:canvas.coordinate(withNormalizedOffset:CGVector(dx:0.49,dy:0.75)))
        XCTAssertTrue(expectation(for:NSPredicate { _,_ in canvas.frame.minX > beforePan.minX + 2 },
            evaluatedWith:nil).waitUntilFulfilled(timeout:5),"Hand did not move the actual canvas")
        XCTAssertEqual(canvas.frame.width,beforePan.width,accuracy:1,"Hand unexpectedly changed scale")
        capture(app,name:"picker-hand-translated-canvas")
        let beforeZoom = canvas.frame
        try pickerRailControl("studio.tool.hand",app:app,forward:false).tap()
        XCTAssertTrue(app.buttons["studio.tool-settings.zoom-in"].isHittable)
        app.buttons["studio.tool-settings.zoom-in"].tap()
        XCTAssertTrue(expectation(for:NSPredicate { _,_ in canvas.frame.width > beforeZoom.width * 1.1 },
            evaluatedWith:nil).waitUntilFulfilled(timeout:5),"Zoom did not enlarge the actual canvas")
        capture(app,name:"picker-zoom-enlarged-canvas")
        try pickerRailControl("studio.tool.eyedropper", app:app, forward:false).tap()
        XCTAssertTrue(canvas.isHittable)
        canvas.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
        let blueReceipt = app.staticTexts["Sampled #0000FF from visible artwork."]
        XCTAssertTrue(blueReceipt.waitForExistence(timeout:8),"Transformed artwork sample did not select blue")
        capture(app,name:"picker-transformed-blue-sample")
        try pickerRailControl("studio.tool.hand",app:app,forward:true).tap()
        app.buttons["studio.tool-settings.fit"].tap()
        app.buttons["studio.tool-settings.close"].tap()
        try settlePickerCanvasAfterSave(app,canvas:canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(original,pixels(canvas.screenshot().image)),4,
            "Sampling or transformed canvas navigation changed artwork")
        capture(app, name: "picker-transform-preserved-artwork")
    }

    @MainActor
    func testEyedropperDrawingUndoColdReopenAndPNG() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let projectName = try createProjectIfLibraryIsShown(app)
        let prepared = try preparePickerSourceStroke(app)
        let canvas = prepared.canvas, original = prepared.original
        let undo = app.buttons["studio.undo"], redo = app.buttons["studio.redo"]
        try choosePickerTestColor("#FF0000", app:app)
        try pickerRailControl("studio.tool.eyedropper", app:app, forward:true).tap()
        canvas.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
        XCTAssertTrue(app.staticTexts["Sampled #0000FF from visible artwork."].waitForExistence(timeout:8))
        try settlePickerCanvasAfterSave(app,canvas:canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(original,pixels(canvas.screenshot().image)),4,
            "Sampling changed the source artwork before drawing")
        try pickerRailControl("studio.tool.brush", app:app, forward:false).tap()
        XCTAssertTrue(app.buttons["studio.tool-settings.close"].waitForExistence(timeout:5))
        app.buttons["studio.tool-settings.close"].tap()
        canvas.coordinate(withNormalizedOffset:CGVector(dx:0.2,dy:0.65)).press(forDuration:0.05,
            thenDragTo:canvas.coordinate(withNormalizedOffset:CGVector(dx:0.8,dy:0.65)))
        let twoStrokes = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(imageFixtureColors(twoStrokes)[1],imageFixtureColors(original)[1]+12,
            "The actual subsequent stroke did not use sampled blue")
        XCTAssertEqual(imageFixtureColors(twoStrokes)[0],0,"The old red drawing color was retained")
        undo.tap()
        XCTAssertTrue(expectation(for:NSPredicate(format:"enabled == true"), evaluatedWith:redo).waitUntilFulfilled(timeout:5))
        XCTAssertLessThanOrEqual(try changedPixelCount(original,pixels(canvas.screenshot().image)),4,
            "Picker added history or Undo failed to remove only the second stroke")
        redo.tap()
        XCTAssertLessThanOrEqual(try changedPixelCount(twoStrokes,pixels(canvas.screenshot().image)),4)
        capture(app,name:"picker-blue-strokes-undo-redo")
        let save = app.buttons["studio.save"]; save.tap()
        XCTAssertTrue(expectation(for:NSPredicate(format:"label == %@","Saved"), evaluatedWith:save).waitUntilFulfilled(timeout:8))
        app.buttons["studio.back"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format:"label == %@",projectName)).firstMatch.waitForExistence(timeout:8))
        app.terminate()
        let reopened = try launchGuestStudio()
        defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format:"label == %@",projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout:8)); project.tap()
        let reopenedCanvas = reopened.descendants(matching:.any)["studio.canvas"].firstMatch
        XCTAssertTrue(reopenedCanvas.waitForExistence(timeout:8))
        XCTAssertLessThanOrEqual(try changedPixelCount(twoStrokes,pixels(reopenedCanvas.screenshot().image)),4,
            "Cold reopen did not restore the actual sampled-color drawing")
        capture(reopened,name:"picker-persisted-blue-strokes")
        try openExportPanel(reopened)
        try exportControl("studio.export.format.png",app:reopened,scrollUp:false).tap()
        try exportControl("studio.export.start",app:reopened).tap()
        let preview = try waitForPNGPreview(reopened)
        let outputPixels = try exportPreviewPixels(preview,app:reopened,name:"picker-blue")
        XCTAssertGreaterThan(imageFixtureColors(outputPixels)[1],12,"Actual reopened PNG contains no sampled blue")
        XCTAssertEqual(imageFixtureColors(outputPixels)[0],0,"Actual PNG unexpectedly used the earlier red setting")
        capture(reopened,name:"picker-real-blue-png-export")
    }

    // Both bounded journeys create their source stroke through visible tools.
    // No injected document, shortened assertion or expanded execution allowance.
    @MainActor private func preparePickerSourceStroke(_ app: XCUIApplication) throws -> (canvas: XCUIElement, original: Raster) {
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout:8))
        try pickerRailControl("studio.tool.brush", app:app, forward:false).tap()
        let library = app.buttons["studio.brush-library"]
        XCTAssertTrue(library.waitForExistence(timeout:5)); library.tap()
        let round = app.buttons["studio.brush-family.round"]
        XCTAssertTrue(round.waitForExistence(timeout:5)); round.tap()
        app.sliders["studio.setting.size"].adjust(toNormalizedSliderPosition:0.7)
        app.sliders["studio.setting.opacity"].adjust(toNormalizedSliderPosition:1)
        app.buttons["studio.tool-settings.close"].tap()
        try choosePickerTestColor("#0000FF", app:app)
        canvas.coordinate(withNormalizedOffset:CGVector(dx:0.2,dy:0.5)).press(forDuration:0.05,
            thenDragTo:canvas.coordinate(withNormalizedOffset:CGVector(dx:0.8,dy:0.5)))
        let undo = app.buttons["studio.undo"]
        XCTAssertTrue(expectation(for:NSPredicate(format:"enabled == true"), evaluatedWith:undo).waitUntilFulfilled(timeout:5))
        let original = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(imageFixtureColors(original)[1],12,"The real source stroke must be blue")
        return (canvas, original)
    }

    @MainActor
    func testShapeFillRadiusUndoSaveReopenAndPNG() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let projectName = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 8))
        try choosePickerTestColor("#FF0000", app: app)
        try pickerRailControl("studio.tool.rectangle", app: app, forward: true).tap()
        // Tool preferences intentionally survive projects and earlier journeys.
        // Establish the visible default through the same Reset control as users.
        try resetToolPreferencesInPopup(app)
        let fill = app.buttons["studio.shape.fill"]
        XCTAssertTrue(fill.waitForExistence(timeout: 5) && fill.isHittable)
        XCTAssertEqual(fill.value as? String, "None")
        fill.tap(); XCTAssertEqual(fill.value as? String, "Solid")
        let radius = app.sliders["studio.setting.corner-radius"]
        XCTAssertTrue(radius.isHittable)
        let originalRadius = radius.value as? String
        radius.adjust(toNormalizedSliderPosition: 0.7)
        XCTAssertNotEqual(radius.value as? String, originalRadius)
        capture(app, name: "shape-fill-and-radius-popup")
        app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(canvas)
        let blank = try pixels(canvas.screenshot().image)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25,dy: 0.3)).press(forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.75,dy: 0.7)))
        let undo = app.buttons["studio.undo"], redo = app.buttons["studio.redo"]
        XCTAssertTrue(expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: undo).waitUntilFulfilled(timeout: 5))
        let drawn = try pixels(canvas.screenshot().image)
        let center = ((drawn.height / 2) * drawn.width + drawn.width / 2) * 4
        XCTAssertGreaterThan(drawn.bytes[center], 180)
        XCTAssertLessThan(drawn.bytes[center + 1], 90, "Fill setting did not paint the actual shape interior")
        XCTAssertLessThan(drawn.bytes[center + 2], 90)
        XCTAssertGreaterThan(try changedPixelCount(blank, drawn), 500)
        capture(app, name: "shape-actual-rounded-filled-canvas")
        undo.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: redo).waitUntilFulfilled(timeout: 5))
        XCTAssertLessThanOrEqual(try changedPixelCount(blank, pixels(canvas.screenshot().image)), 4)
        redo.tap()
        XCTAssertLessThanOrEqual(try changedPixelCount(drawn, pixels(canvas.screenshot().image)), 4)
        let save = app.buttons["studio.save"]; save.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "Saved"), evaluatedWith: save).waitUntilFulfilled(timeout: 8))
        app.buttons["studio.back"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch.waitForExistence(timeout: 8))
        app.terminate()
        let reopened = try launchGuestStudio()
        defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8)); project.tap()
        let reopenedCanvas = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        XCTAssertTrue(reopenedCanvas.waitForExistence(timeout: 8))
        try waitForStableCanvas(reopenedCanvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(drawn, pixels(reopenedCanvas.screenshot().image)), 4,
            "Saved shape lost its fill or radius on cold reopen")
        capture(reopened, name: "shape-filled-cold-reopened")
        try openExportPanel(reopened)
        try exportControl("studio.export.format.png", app: reopened, scrollUp: false).tap()
        try exportControl("studio.export.start", app: reopened).tap()
        let preview = try waitForPNGPreview(reopened)
        XCTAssertGreaterThan(imageFixtureColors(try pixels(preview.screenshot().image))[0], 500,
            "Real exported PNG lost the filled shape")
        capture(reopened, name: "shape-real-png-export-preview")
    }

    @MainActor
    func testFullCanvasFillUndoAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let projectName = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        XCTAssertTrue(canvas.waitUntilPresent(timeout: 8))
        try choosePickerTestColor("#0000FF", app: app)
        try pickerRailControl("studio.tool.fill", app: app, forward: false).tap()
        app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(canvas)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5,dy: 0.5)).tap()
        // Retain the original eight-second Saved assertion that caught the
        // blank portrait-canvas stall; no performance-specific deadline waiver.
        try settlePickerCanvasAfterSave(app,canvas:canvas)
        let filled = try pixels(canvas.screenshot().image)
        let blue = imageFixtureColors(filled)[1]
        XCTAssertGreaterThan(blue, filled.width * filled.height * 7 / 10)
        capture(app, name: "fill-full-portrait-real-blue-pixels")
        let undo=app.buttons["studio.undo"],redo=app.buttons["studio.redo"]
        XCTAssertTrue(undo.isEnabled);undo.tap()
        XCTAssertTrue(expectation(for:NSPredicate(format:"enabled == true"),evaluatedWith:redo).waitUntilFulfilled(timeout:5))
        XCTAssertLessThan(imageFixtureColors(try pixels(canvas.screenshot().image))[1],10)
        redo.tap()
        XCTAssertLessThanOrEqual(try changedPixelCount(filled,pixels(canvas.screenshot().image)),4)
        try settlePickerCanvasAfterSave(app,canvas:canvas)
        app.buttons["studio.back"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format:"label == %@",projectName)).firstMatch.waitUntilPresent(timeout:8))
        app.terminate()
        let reopened=try launchGuestStudio();defer { reopened.terminate() }
        let project=reopened.buttons.matching(NSPredicate(format:"label == %@",projectName)).firstMatch
        XCTAssertTrue(project.waitUntilPresent(timeout:8));project.tap()
        let restored=reopened.descendants(matching:.any)["studio.canvas"].firstMatch
        XCTAssertTrue(restored.waitUntilPresent(timeout:8));try waitForStableCanvas(restored)
        XCTAssertLessThanOrEqual(try changedPixelCount(filled,pixels(restored.screenshot().image)),4)
        capture(reopened,name:"fill-full-portrait-cold-reopened")
    }

    @MainActor
    func testBucketFillPopupUndoSaveReopenAndPNG() throws {
        // Run 35600568119 attempt 2 reached cold reopen/export at the 180s limit.
        executionTimeAllowance = 240
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let projectName = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        XCTAssertTrue(canvas.waitUntilPresent(timeout: 8))
        try choosePickerTestColor("#FF0000", app: app)
        // A real styled brush must remain editable when shapes and fill upgrade
        // the document format. Draw outside the intended closed rectangle.
        try pickerRailControl("studio.tool.brush", app: app, forward: false).tap()
        app.buttons["studio.brush-library"].tap()
        let round = app.buttons["studio.brush-family.round"]
        XCTAssertTrue(round.waitUntilPresent(timeout: 5)); round.tap()
        app.sliders["studio.setting.size"].adjust(toNormalizedSliderPosition: 0.2)
        app.sliders["studio.setting.opacity"].adjust(toNormalizedSliderPosition: 1)
        app.buttons["studio.tool-settings.close"].tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25,dy: 0.86)).press(forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.75,dy: 0.86)))
        try settlePickerCanvasAfterSave(app,canvas:canvas)
        let styledPixels = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(imageFixtureColors(styledPixels)[0], 12, "Actual styled brush must precede the shape and fill")
        try pickerRailControl("studio.tool.rectangle", app: app, forward: true).tap()
        XCTAssertEqual(app.buttons["studio.shape.fill"].value as? String, "None")
        app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(canvas)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25,dy: 0.25)).press(forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.75,dy: 0.7)))
        let undo = app.buttons["studio.undo"], redo = app.buttons["studio.redo"]
        XCTAssertTrue(expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: undo).waitUntilFulfilled(timeout: 5))
        let outlined = try pixels(canvas.screenshot().image)
        XCTAssertGreaterThan(imageFixtureColors(outlined)[0], imageFixtureColors(styledPixels)[0] + 12, "Adding a shape rejected or removed the existing styled brush")
        try choosePickerTestColor("#0000FF", app: app)
        try pickerRailControl("studio.tool.fill", app: app, forward: false).tap()
        let tolerance = app.sliders["studio.setting.tolerance"]
        XCTAssertTrue(tolerance.waitUntilPresent(timeout: 5) && tolerance.isHittable)
        tolerance.adjust(toNormalizedSliderPosition: 0)
        let contiguous = app.buttons["studio.fill.contiguous"]
        XCTAssertTrue(contiguous.isHittable)
        contiguous.tap()
        XCTAssertFalse(app.sliders["studio.setting.gap-close"].isEnabled)
        contiguous.tap()
        XCTAssertTrue(app.sliders["studio.setting.gap-close"].isEnabled)
        capture(app, name: "bucket-fill-existing-popup-settings")
        app.buttons["studio.tool-settings.close"].tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5,dy: 0.48)).tap()
        let deadline = Date().addingTimeInterval(20)
        var colored = try pixels(canvas.screenshot().image)
        while Date() < deadline {
            let middle = ((colored.height / 2) * colored.width + colored.width / 2) * 4
            if colored.bytes[middle + 2] > 180 && colored.bytes[middle] < 90 { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            colored = try pixels(canvas.screenshot().image)
        }
        // A real successful save dismisses the status banner. Compare the
        // same settled canvas size across fill, Undo, Redo and cold reopen.
        try settlePickerCanvasAfterSave(app,canvas:canvas)
        colored = try pixels(canvas.screenshot().image)
        let middle = ((colored.height / 2) * colored.width + colored.width / 2) * 4
        XCTAssertGreaterThan(colored.bytes[middle + 2], 180)
        XCTAssertLessThan(colored.bytes[middle], 90, "Native palette did not fill the real enclosed canvas with blue")
        XCTAssertGreaterThan(try changedPixelCount(outlined, colored), 500)
        capture(app, name: "bucket-fill-actual-blue-enclosed-region")
        XCTAssertTrue(undo.isEnabled); undo.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: redo).waitUntilFulfilled(timeout: 5))
        XCTAssertLessThanOrEqual(try changedPixelCount(outlined, pixels(canvas.screenshot().image)), 4)
        redo.tap()
        XCTAssertLessThanOrEqual(try changedPixelCount(colored, pixels(canvas.screenshot().image)), 4)
        let save = app.buttons["studio.save"]; save.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "Saved"), evaluatedWith: save).waitUntilFulfilled(timeout: 8))
        app.buttons["studio.back"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch.waitUntilPresent(timeout: 8))
        app.terminate()
        let reopened = try launchGuestStudio(); defer { reopened.terminate() }
        let project = reopened.buttons.matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(project.waitUntilPresent(timeout: 8)); project.tap()
        let reopenedCanvas = reopened.descendants(matching: .any)["studio.canvas"].firstMatch
        XCTAssertTrue(reopenedCanvas.waitUntilPresent(timeout: 8)); try waitForStableCanvas(reopenedCanvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(colored, pixels(reopenedCanvas.screenshot().image)), 4)
        capture(reopened, name: "bucket-fill-cold-reopened")
        try openExportPanel(reopened)
        try exportControl("studio.export.format.png", app: reopened, scrollUp: false).tap()
        try exportControl("studio.export.start", app: reopened).tap()
        let preview = try waitForPNGPreview(reopened)
        XCTAssertGreaterThan(imageFixtureColors(try pixels(preview.screenshot().image))[1], 500)
        capture(reopened, name: "bucket-fill-real-blue-png-export")
    }

    @MainActor private func pickerRailControl(_ id: String, app: XCUIApplication, forward: Bool) throws -> XCUIElement {
        let rail = app.descendants(matching: .any)["studio.toolbar"].firstMatch
        let element = app.buttons[id], scroll = rail.scrollViews.firstMatch
        XCTAssertTrue(rail.waitUntilPresent(timeout: 5) && scroll.exists)
        let vertical = rail.value as? String == "Vertical"
        for _ in 0..<12 {
            // Each AX attribute is a remote query. Reuse geometry only within
            // this iteration; every drag still requires fresh containment and
            // hittability before the actual button tap. No larger timeout.
            let viewport = scroll.frame.insetBy(dx: 1, dy: 1)
            let target = element.exists ? element.frame : nil
            if let target, viewport.contains(target), element.isHittable { return element }
            let length = vertical ? viewport.height : viewport.width
            // The retained 87c9 native failure had Brush ending at x392 while
            // the viewport ended at x390. Large flicks alternated past it.
            // Reveal the clipped edge, then hold before lifting to avoid inertia.
            var delta = (forward ? 1.0 : -1.0) * length * 0.4
            if let target {
                let leading = vertical ? target.minY - viewport.minY : target.minX - viewport.minX
                let trailing = vertical ? target.maxY - viewport.maxY : target.maxX - viewport.maxX
                if leading < 0 { delta = leading - 8 }
                else if trailing > 0 { delta = trailing + 8 }
                else {
                    // Full containment alone is insufficient; wait for the
                    // actual button to become hittable without moving the rail.
                    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                    continue
                }
            }
            let distance = min(max(24, abs(delta)), length * 0.4)
            let end = 0.5 - (delta > 0 ? distance : -distance) / max(1, length)
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: scroll.coordinate(withNormalizedOffset:
                    CGVector(dx: vertical ? 0.5 : end, dy: vertical ? end : 0.5)),
                    withVelocity: .slow, thenHoldForDuration: 0.25)
        }
        captureHierarchy(app, name: "picker-rail-unreachable-" + id)
        XCTFail("Actual toolbar control unreachable: " + id)
        throw NSError(domain: "NativePickerSmoke", code: 1)
    }

    @MainActor private func choosePickerTestColor(_ hex:String, app:XCUIApplication) throws {
        try pickerRailControl("studio.color.open",app:app,forward:false).tap()
        let preset = app.buttons["studio.color.preset."+hex]
        XCTAssertTrue(preset.waitUntilPresent(timeout:5)); XCTAssertTrue(preset.isHittable); preset.tap()
        XCTAssertEqual(app.staticTexts["studio.color.current"].label,hex)
        let close = app.buttons["studio.panel.close.Color"]
        XCTAssertTrue(close.isHittable); close.tap()
    }

    @MainActor private func settlePickerCanvasAfterSave(_ app:XCUIApplication, canvas:XCUIElement) throws {
        let save = app.buttons["studio.save"]
        // Context-menu dismissal can outlive the menu action. Run 35589511247
        // queried Save immediately and failed before its overlay disappeared.
        let ready = expectation(for: NSPredicate(format: "exists == true AND hittable == true"), evaluatedWith: save)
        let saveReady = ready.waitUntilFulfilled(timeout: 8)
        if !saveReady {
            capture(app, name: "save-readiness-timeout")
            captureHierarchy(app, name: "save-readiness-timeout-hierarchy")
        }
        XCTAssertTrue(saveReady, "Save must become reachable after the preceding action")
        guard saveReady else { throw NSError(domain: "NativeSaveReadiness", code: 1) }
        save.tap()
        XCTAssertTrue(expectation(for:NSPredicate(format:"label == %@","Saved"), evaluatedWith:save).waitUntilFulfilled(timeout:8))
        // Ask whether the query is empty. Resolving firstMatch's attributes
        // retries a nonexistent element, exhausting the old five-second wait
        // even when the recording visibly contains no sampled-color toast.
        let samplingMessages = app.staticTexts.matching(NSPredicate(format:"label BEGINSWITH %@","Sampled #"))
        let noSamplingMessage = NSPredicate { _, _ in samplingMessages.count == 0 }
        XCTAssertTrue(expectation(for: noSamplingMessage, evaluatedWith: nil).waitUntilFulfilled(timeout: 5))
        let appBounds = app.frame
        // Run35491555925 recorded the visible canvas throughout, while a
        // frame query (2.83s) plus a second hittability query (3.18s) consumed
        // nearly the entire 8s polling budget before a stable second sample.
        // Reuse the existing single-query geometry wait: same 8s/1s bounds,
        // then check existence, hittability and containment once. Preserve
        // every downstream pixel, undo, edit and cold-reopen assertion.
        try waitForStableCanvas(canvas)
        XCTAssertTrue(appBounds.contains(canvas.frame), "The settled canvas escaped the app bounds")
    }

    private func imageFixtureColors(_ raster: Raster) -> [Int] {
        var counts = [Int](repeating: 0, count: 4)
        for i in stride(from: 0, to: raster.bytes.count, by: 4) {
            let r = raster.bytes[i], g = raster.bytes[i + 1], b = raster.bytes[i + 2]
            if r > 180 && g < 90 && b < 90 { counts[0] += 1 }
            if b > 180 && r < 90 && g < 90 { counts[1] += 1 }
            if g > 180 && r < 90 && b < 90 { counts[2] += 1 }
            if r > 180 && g > 180 && b < 90 { counts[3] += 1 }
        }
        return counts
    }

    @MainActor private func waitForHittable(_ element: XCUIElement, app: XCUIApplication, name: String) throws {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element)
        let result = XCTWaiter.wait(for: [ready], timeout: 30)
        if result != .completed {
            capture(app, name: name + "-timeout")
            captureHierarchy(app, name: name + "-timeout-hierarchy")
        }
        XCTAssertEqual(result, .completed, "System Photos cancellation control did not become hittable")
        guard result == .completed else { throw NSError(domain: "NativePhotosReadiness", code: 1) }
    }

    @MainActor private func openImagePanel(_ app: XCUIApplication) throws {
        let menu = app.buttons["studio.menu.open"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5)); XCTAssertTrue(menu.isHittable); menu.tap()
        try waitForButton("Add Picture", in: app).tap()
        XCTAssertTrue(app.buttons["studio.image.photos"].waitForExistence(timeout: 8))
    }

    @MainActor private func closeImagePanel(_ app: XCUIApplication) throws {
        let close = app.buttons["studio.panel.close.Add Picture"]
        XCTAssertTrue(close.waitForExistence(timeout: 5)); XCTAssertTrue(close.isHittable); close.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "exists == false"),
            evaluatedWith: close).waitUntilFulfilled(timeout: 5))
    }

    @MainActor private func imageControl(_ identifier: String, app: XCUIApplication) throws -> XCUIElement {
        let scroll = app.scrollViews["studio.image.scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 8))
        let element = app.descendants(matching: .any)[identifier].firstMatch
        for attempt in 0...6 {
            if element.exists && scroll.frame.insetBy(dx: 0, dy: 2).contains(element.frame) && element.isHittable { return element }
            guard attempt < 6 else { break }
            scroll.swipeUp()
        }
        captureHierarchy(app, name: "image-control-unreachable-" + identifier)
        XCTFail("Image import control was not reachable: \(identifier)")
        throw NSError(domain: "NativeImageSmoke", code: 1)
    }

    @MainActor
    private func localMotionControl(_ identifier: String, app: XCUIApplication, scrollUp: Bool = true) throws -> XCUIElement {
        let scroll = app.scrollViews["spatter.motion.scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 8), "The actual local recipe ScrollView is missing")
        let element = app.descendants(matching: .any)[identifier].firstMatch
        for attempt in 0...8 {
            let exists = element.exists
            let frame = exists ? element.frame : CGRect.null
            let viewport = scroll.frame.insetBy(dx: 0, dy: 2)
            if exists && !frame.isEmpty && viewport.contains(frame) && element.isHittable {
                return element
            }
            guard attempt < 8 else { break }
            let upward = frame.isEmpty || frame.isNull ? scrollUp : frame.maxY > viewport.maxY
            let from = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: upward ? 0.75 : 0.35))
            let to = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: upward ? 0.4 : 0.7))
            from.press(forDuration: 0.1, thenDragTo: to)
        }
        captureHierarchy(app, name: "local-motion-control-unreachable-" + identifier)
        XCTFail("Local motion control is unreachable after eight bounded scrolls: \(identifier)")
        throw NSError(domain: "NativeSpatterMotionSmoke", code: 1)
    }

    @MainActor
    private func openExportPanel(_ app: XCUIApplication) throws {
        let open = app.buttons["studio.export.open"]
        XCTAssertTrue(open.waitUntilPresent(timeout: 5)); XCTAssertTrue(open.isHittable)
        open.tap()
        XCTAssertTrue(app.buttons["studio.export.format.png"].waitUntilPresent(timeout: 5))
    }

    @MainActor
    private func closeExportPanel(_ app: XCUIApplication) throws {
        let toggle = app.buttons["studio.export.open"]
        XCTAssertTrue(toggle.isHittable); toggle.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "exists == false"),
                                  evaluatedWith: app.buttons["studio.export.start"]).waitUntilFulfilled(timeout: 5))
    }

    @MainActor
    private func importLicensedImageForExport(_ app: XCUIApplication, canvas: XCUIElement) throws {
        try openImagePanel(app)
        try imageControl("studio.image.library", app: app).tap()
        let search = app.textFields["studio.image-library.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 8)); search.tap(); search.typeText("dragon\n")
        let picture = app.buttons["studio.image-library.item.kenney.scribble-dungeons.dragon"]
        XCTAssertTrue(picture.waitForExistence(timeout: 8)); XCTAssertTrue(picture.isHittable); picture.tap()
        _ = try imageControl("studio.image.preview", app: app)
        XCTAssertTrue(app.staticTexts["studio.image.attribution"].label.contains("CC0-1.0"))
        try imageControl("studio.image.apply", app: app).tap()
        XCTAssertTrue(try imageControl("studio.image.result", app: app).label.hasPrefix("Added Dungeon Dragon on a new image layer"))
        try closeImagePanel(app)
        try settlePickerCanvasAfterSave(app, canvas: canvas)
    }

    @MainActor
    private func exportControl(_ identifier: String, app: XCUIApplication, scrollUp: Bool = true,
                               waitForExistence: Bool = true) throws -> XCUIElement {
        let element = app.descendants(matching: .any)[identifier].firstMatch
        if waitForExistence {
            XCTAssertTrue(element.waitUntilPresent(timeout: 8), "Missing export control: \(identifier)")
        }
        // iOS prunes scrolled-offscreen format buttons from AX after sharing.
        // Locate the unique actual ancestor of the requested export control.
        let panels = app.scrollViews.containing(.any, identifier: identifier)
        let panelCount = panels.count
        if panelCount != 1 {
            captureHierarchy(app, name: "export-control-ancestor-failed-" + identifier)
        }
        XCTAssertEqual(panelCount, 1, "The requested export control has no unique ScrollView ancestor")
        let panel = panels.firstMatch
        // Each AX query can take a second on CI. Return as soon as the actual
        // element is fully visible; never re-evaluate a satisfied loop filter.
        for attempt in 0...8 {
            let panelFrame = panel.frame
            let elementFrame = element.frame
            if !elementFrame.isEmpty && panelFrame.insetBy(dx: 0, dy: 2).contains(elementFrame) {
                XCTAssertTrue(element.isHittable, "Export control is obstructed: \(identifier)")
                return element
            }
            guard attempt < 8 else { break }
            let upward = elementFrame.isEmpty ? scrollUp : elementFrame.maxY > panelFrame.maxY - 2
            // The centre can land on the background segmented control, which
            // consumes this drag. Use the panel's 16pt content padding instead.
            let start = panel.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: upward ? 0.7 : 0.3))
            let end = panel.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: upward ? 0.45 : 0.55))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        captureHierarchy(app, name: "export-control-unreachable-" + identifier)
        let bounds = XCTAttachment(string: "Panel: \(panel.frame); control: \(element.frame); hittable: \(element.isHittable)")
        bounds.name = "export-control-bounds-" + identifier; bounds.lifetime = .keepAlways; add(bounds)
        XCTFail("Export control is not fully reachable after eight scrolls: \(identifier)")
        throw NSError(domain: "NativeExportSmoke", code: 1)
    }

    @MainActor
    private func moviePreviewPixels(_ preview: XCUIElement, app: XCUIApplication) throws -> Raster {
        let screenshot = try XCTUnwrap(app.screenshot().image.cgImage)
        let image = try normalizedExportPreview(screenshot, previewFrame: preview.frame, appFrame: app.frame)
        return try pixels(UIImage(cgImage: image))
    }

    @MainActor
    private func waitForPNGPreview(_ app: XCUIApplication) throws -> XCUIElement {
        let preview = app.descendants(matching: .any)["studio.export.preview"].firstMatch
        XCTAssertTrue(preview.waitUntilPresent(timeout: 30), "No preview decoded from the actual PNG output appeared")
        let visible = try exportControl("studio.export.preview", app: app, waitForExistence: false)
        let frame = visible.frame
        XCTAssertGreaterThan(frame.width, 20); XCTAssertGreaterThan(frame.height, 20)
        XCTAssertTrue(app.staticTexts["studio.export.status"].label.contains("Export ready"))
        return visible
    }

    @MainActor
    private func exportPreviewPixels(_ preview: XCUIElement, app: XCUIApplication, name: String) throws -> Raster {
        let previewFrame = preview.frame
        let appFrame = app.frame
        let screenshot = try XCTUnwrap(app.screenshot().image.cgImage)
        let image = try normalizedExportPreview(screenshot, previewFrame: previewFrame, appFrame: appFrame)
        let attachment = XCTAttachment(image: UIImage(cgImage: image))
        attachment.name = "png-preview-normalized-" + name; attachment.lifetime = .keepAlways
        add(attachment)
        return try pixels(UIImage(cgImage: image))
    }

    // Export-specific fixture: default white 1080x1920 PNG, fitted in the real
    // 180pt preview. b3 native captures clipped the AX element to 538 vs 540px.
    // Crop from a full app capture instead, using the actual AX rectangle with
    // a 2pt rounding margin. White PNG bounds exclude the dark card/letterbox;
    // normalize those bounds, not the canvas or independently rounded AX image.
    private func normalizedExportPreview(_ screenshot: CGImage, previewFrame: CGRect,
                                         appFrame: CGRect) throws -> CGImage {
        func invalid(_ message: String) -> NSError {
            NSError(domain: "NativeExportSmoke", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard appFrame.width > 0, appFrame.height > 0,
              screenshot.width <= 4096, screenshot.height <= 4096,
              abs(previewFrame.height - 180) <= 1,
              appFrame.contains(previewFrame) else { throw invalid("Unexpected PNG preview capture geometry") }
        let scaleX = CGFloat(screenshot.width) / appFrame.width
        let scaleY = CGFloat(screenshot.height) / appFrame.height
        guard abs(scaleX - scaleY) < 0.01 else { throw invalid("Screenshot axes use different scales") }
        let padded = previewFrame.insetBy(dx: -2, dy: -2).intersection(appFrame)
        let bounds = CGRect(x: (padded.minX - appFrame.minX) * scaleX,
                            y: (padded.minY - appFrame.minY) * scaleY,
                            width: padded.width * scaleX, height: padded.height * scaleY).integral
        guard let crop = screenshot.cropping(to: bounds) else { throw invalid("Preview crop is outside screenshot") }
        let raster = try pixels(UIImage(cgImage: crop))
        var minX = raster.width, minY = raster.height, maxX = -1, maxY = -1, whiteCount = 0
        for y in 0..<raster.height {
            for x in 0..<raster.width {
                let offset = (y * raster.width + x) * 4
                if (0..<4).allSatisfy({ raster.bytes[offset + $0] >= 240 }) {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y); whiteCount += 1
                }
            }
        }
        let width = maxX - minX + 1, height = maxY - minY + 1
        guard width > 20, height > 20,
              abs(CGFloat(width) - CGFloat(height) * 9 / 16) <= 2,
              abs(CGFloat(height) - 180 * scaleY) <= 2,
              Double(whiteCount) / Double(width * height) > 0.9,
              let png = crop.cropping(to: CGRect(x: minX, y: minY, width: width, height: height)),
              let context = CGContext(data: nil, width: 288, height: 512, bitsPerComponent: 8,
                  bytesPerRow: 288 * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { throw invalid("Expected complete white portrait PNG is missing, clipped or obscured") }
        context.interpolationQuality = .high
        context.draw(png, in: CGRect(x: 0, y: 0, width: 288, height: 512))
        return try XCTUnwrap(context.makeImage())
    }

    private func exportInkMask(_ raster: Raster) -> Set<Int> {
        Set((0..<(raster.width * raster.height)).filter { pixel in
            let offset = pixel * 4
            let red = Int(raster.bytes[offset])
            return red - Int(raster.bytes[offset + 1]) > 24 && red - Int(raster.bytes[offset + 2]) > 24
        })
    }

    private func exportForegroundMask(_ raster: Raster) -> Set<Int> {
        Set((0..<(raster.width * raster.height)).filter { pixel in
            (0..<3).contains { raster.bytes[pixel * 4 + $0] < 231 }
        })
    }

    // Subpixel scrolling can alter edge antialiasing after sheet dismissal.
    // Both the red stroke and all nonwhite foreground must match in both
    // directions; new blue/black content cannot hide behind unchanged red ink.
    // At most one normalized pixel of rasterization movement is accepted.
    private func unmatchedExportInk(_ lhs: Raster, _ rhs: Raster) -> Int {
        guard lhs.width == rhs.width, lhs.height == rhs.height else { return Int.max }
        let a = exportInkMask(lhs), b = exportInkMask(rhs)
        func unmatched(_ source: Set<Int>, _ target: Set<Int>) -> Int {
            source.filter { pixel in
                let x = pixel % lhs.width, y = pixel / lhs.width
                return !(-1...1).contains { dy in
                    (-1...1).contains { dx in
                        let nx = x + dx, ny = y + dy
                        return nx >= 0 && nx < lhs.width && ny >= 0 && ny < lhs.height && target.contains(ny * lhs.width + nx)
                    }
                }
            }.count
        }
        let foregroundA = exportForegroundMask(lhs), foregroundB = exportForegroundMask(rhs)
        return unmatched(a, b) + unmatched(b, a)
            + unmatched(foregroundA, foregroundB) + unmatched(foregroundB, foregroundA)
    }

    @MainActor
    private func captureHierarchy(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func launchAtWelcome() throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        XCTAssertEqual(env["SDI_SMOKE_OFFLINE_PREFLIGHT"], "1", "Run the built-app configuration preflight before launching")
        let source = try XCTUnwrap(env["SDI_SMOKE_SOURCE_COMMIT"])
        XCTAssertNotNil(source.range(of: "^[0-9a-f]{40}$", options: .regularExpression))
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.willisnmb.stickdeathinfinity")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        capture(app, name: "launch-\(source.prefix(12))")
        XCTAssertTrue(app.buttons["welcome.guest"].waitForExistence(timeout: 20))
        return app
    }

    @MainActor
    private func tapWelcomeAction(_ identifier: String, in app: XCUIApplication) throws {
        let action = app.buttons[identifier]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        let content = app.scrollViews["welcome.content"]
        for _ in 0..<3 where !action.isHittable { content.swipeUp() }
        XCTAssertTrue(action.isHittable)
        action.tap()
    }

    @MainActor
    private func launchGuestStudio() throws -> XCUIApplication {
        let app = try launchAtWelcome()
        try tapWelcomeAction("welcome.guest", in: app)
        try waitForButton("Skip Tutorial", in: app).tap()
        try waitForButton("Studio", in: app).tap()
        return app
    }

    @MainActor
    private func createProjectIfLibraryIsShown(_ app: XCUIApplication) throws -> String {
        // The compiler-recovery head opens an empty Studio directly. The next
        // storage slice opens a real library; support that explicit native route.
        let library = app.descendants(matching: .any)["studio.library"].firstMatch
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        let ready = NSPredicate { _, _ in library.exists || canvas.exists || self.button("FIT", in: app).exists }
        XCTAssertTrue(expectation(for: ready, evaluatedWith: nil).waitUntilFulfilled(timeout: 8))
        let projectName = "Native smoke \(UUID().uuidString.prefix(8))"
        if library.exists {
            let create = app.buttons["studio.new-project"]
            XCTAssertTrue(create.waitUntilPresent(timeout: 5)); create.tap()
            let name = app.textFields["studio.project-name"]
            XCTAssertTrue(name.waitUntilPresent(timeout: 5))
            name.tap()
            if let value = name.value as? String, !value.isEmpty {
                name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
            }
            name.typeText(projectName)
            let confirm = app.buttons["studio.create-project"]
            XCTAssertTrue(confirm.waitUntilPresent(timeout: 5)); confirm.tap()
        }
        return projectName
    }

    @MainActor private func button(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ OR label ENDSWITH %@", label, ", " + label)).firstMatch
    }

    @MainActor @discardableResult
    private func waitForButton(_ label: String, in app: XCUIApplication, timeout: TimeInterval = 10) throws -> XCUIElement {
        let element = button(label, in: app)
        XCTAssertTrue(element.waitUntilPresent(timeout: timeout), "Missing native button: \(label)")
        XCTAssertTrue(expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: element).waitUntilFulfilled(timeout: timeout), "Native button is not reachable: \(label)")
        return element
    }

    @MainActor private func identifiedButton(_ id: String, fallback: String, app: XCUIApplication) -> XCUIElement {
        let identified = app.buttons[id]
        return identified.exists ? identified : button(fallback, in: app)
    }

    @MainActor private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private struct Raster { let width: Int; let height: Int; let bytes: [UInt8] }
    private func pixels(_ image: UIImage) throws -> Raster {
        let cg = try XCTUnwrap(image.cgImage)
        let width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(rendered)
        return Raster(width: width, height: height, bytes: bytes)
    }
    private func changedPixelCount(_ lhs: Raster, _ rhs: Raster) throws -> Int {
        XCTAssertEqual(lhs.width, rhs.width); XCTAssertEqual(lhs.height, rhs.height)
        guard lhs.width == rhs.width, lhs.height == rhs.height else { return Int.max }
        return stride(from: 0, to: lhs.bytes.count, by: 4).reduce(into: 0) { count, offset in
            if (0..<3).contains(where: { abs(Int(lhs.bytes[offset + $0]) - Int(rhs.bytes[offset + $0])) > 24 }) { count += 1 }
        }
    }
}

private extension XCTestExpectation {
    func waitUntilFulfilled(timeout: TimeInterval) -> Bool {
        XCTWaiter.wait(for: [self], timeout: timeout) == .completed
    }
}

// The recorded 5a6963a failure spent a one-second initial XCTest poll on
// already-present controls. Keep the same bounded wait for absent controls;
// presence alone does not replace any existing hittability/geometry assertion.
private extension XCUIElement {
    @MainActor func waitUntilPresent(timeout: TimeInterval) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        if exists { return true }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        return remaining > 0 && waitForExistence(timeout: remaining)
    }
}
