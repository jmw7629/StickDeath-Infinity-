import XCTest
import UIKit

/// Runs against the real app and an isolated simulator. The build preflight must
/// verify empty backend settings; setting app.launchEnvironment cannot do that.
final class StudioSmokeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

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
        capture(app, name: "toolbar-floating-popup")
    }

    @MainActor
    private func waitForStableCanvas(_ canvas: XCUIElement, expected: CGRect? = nil) throws {
        var last = CGRect.null
        var since = Date()
        let settled = NSPredicate { _, _ in
            let frame = canvas.frame
            guard canvas.exists, canvas.isHittable, frame.width > 80, frame.height > 80,
                  expected == nil || frame == expected else { since = Date(); return false }
            if last != frame { last = frame; since = Date(); return false }
            return Date().timeIntervalSince(since) >= 1
        }
        XCTAssertTrue(expectation(for: settled, evaluatedWith: nil).waitUntilFulfilled(timeout: 8),
                      "The real canvas did not settle at its expected geometry")
    }

    @MainActor
    private func selectToolbarTool(_ name: String, app: XCUIApplication) throws {
        let rail = app.descendants(matching: .any)["studio.toolbar"].firstMatch
        let tool = app.buttons["studio.tool." + name]
        let scroll = rail.scrollViews.firstMatch
        XCTAssertTrue(rail.waitForExistence(timeout: 5) && scroll.exists)
        for _ in 0..<12 {
            if tool.exists, tool.isHittable, scroll.frame.insetBy(dx: 1, dy: 1).contains(tool.frame) {
                tool.tap(); return
            }
            let vertical = rail.value as? String == "Vertical"
            let forward = !tool.exists || (vertical ? tool.frame.midY > scroll.frame.midY : tool.frame.midX > scroll.frame.midX)
            let a = forward ? 0.8 : 0.2, b = forward ? 0.2 : 0.8
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: vertical ? 0.5 : a, dy: vertical ? a : 0.5))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: vertical ? 0.5 : b, dy: vertical ? b : 0.5))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        captureHierarchy(app, name: "toolbar-control-unreachable-" + name)
        XCTFail("Actual toolbar tool unreachable after twelve bounded scrolls: " + name)
        throw NSError(domain: "NativeToolbarSmoke", code: 1)
    }

    @MainActor
    func testGuestStudioPortraitAndLandscape() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        _ = try createProjectIfLibraryIsShown(app)
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
        let landscapeCapture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        landscapeCapture.name = "studio-landscape"
        landscapeCapture.lifetime = .keepAlways
        add(landscapeCapture)
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
        let importAudio = app.buttons["studio.audio.import"]
        XCTAssertTrue(importAudio.waitForExistence(timeout: 8)); XCTAssertTrue(importAudio.isEnabled)
        XCTAssertTrue(app.staticTexts["Animation only"].exists)
        capture(app, name: "audio-empty-real-timeline")
        importAudio.tap()

        // This is the real system document picker. No injected app URL or
        // hidden importer call can satisfy the navigation and cancel checks.
        // The recorded iOS 26 Files bar has a stable system identifier; its
        // visible page title is a child, not the navigation-bar identifier.
        let providerNavigation = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"]
        let cancel = providerNavigation.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        capture(app, name: "audio-native-files-picker")
        captureHierarchy(app, name: "audio-native-files-picker-hierarchy")
        XCTAssertTrue(providerNavigation.exists, "Inspect the real Files provider hierarchy before changing this assertion")
        XCTAssertTrue(providerNavigation.staticTexts["Recents"].exists, "The actual Files Recents page is missing")
        XCTAssertTrue(app.collectionViews["File View"].exists, "The real Files provider collection is missing")
        XCTAssertTrue(app.tabBars["DOC.browsingModeTabBar"].buttons["Browse"].exists)
        XCTAssertTrue(cancel.isHittable); cancel.tap()
        XCTAssertTrue(importAudio.waitForExistence(timeout: 8)); XCTAssertTrue(importAudio.isEnabled)
        XCTAssertFalse(app.staticTexts["studio.audio.imported"].exists, "Picker cancellation invented an imported clip")
        XCTAssertFalse(app.buttons["studio.audio.cancel"].exists, "Picker cancellation left an import running")
        XCTAssertTrue(app.staticTexts["No imported clips. Historical audio records are preserved in the project."].exists)
        capture(app, name: "audio-files-cancelled-no-clips")
        let close = app.buttons["studio.panel.close.Audio Timeline"]
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
        XCTAssertTrue(open.waitForExistence(timeout: 5)); XCTAssertTrue(open.isHittable)
        open.tap()
        XCTAssertTrue(app.buttons["studio.export.format.png"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func closeExportPanel(_ app: XCUIApplication) throws {
        let toggle = app.buttons["studio.export.open"]
        XCTAssertTrue(toggle.isHittable); toggle.tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "exists == false"),
                                  evaluatedWith: app.buttons["studio.export.start"]).waitUntilFulfilled(timeout: 5))
    }

    @MainActor
    private func exportControl(_ identifier: String, app: XCUIApplication, scrollUp: Bool = true,
                               waitForExistence: Bool = true) throws -> XCUIElement {
        let element = app.descendants(matching: .any)[identifier].firstMatch
        if waitForExistence {
            XCTAssertTrue(element.waitForExistence(timeout: 8), "Missing export control: \(identifier)")
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
            // Small drags use the actual ScrollView, never window coordinates.
            let start = panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.7 : 0.3))
            let end = panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.45 : 0.55))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        captureHierarchy(app, name: "export-control-unreachable-" + identifier)
        let bounds = XCTAttachment(string: "Panel: \(panel.frame); control: \(element.frame); hittable: \(element.isHittable)")
        bounds.name = "export-control-bounds-" + identifier; bounds.lifetime = .keepAlways; add(bounds)
        XCTFail("Export control is not fully reachable after eight scrolls: \(identifier)")
        throw NSError(domain: "NativeExportSmoke", code: 1)
    }

    @MainActor
    private func waitForPNGPreview(_ app: XCUIApplication) throws -> XCUIElement {
        let preview = app.descendants(matching: .any)["studio.export.preview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 30), "No preview decoded from the actual PNG output appeared")
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
    private func launchGuestStudio() throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        XCTAssertEqual(env["SDI_SMOKE_OFFLINE_PREFLIGHT"], "1", "Run the built-app configuration preflight before launching")
        let source = try XCTUnwrap(env["SDI_SMOKE_SOURCE_COMMIT"])
        XCTAssertNotNil(source.range(of: "^[0-9a-f]{40}$", options: .regularExpression))
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.willisnmb.stickdeathinfinity")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        capture(app, name: "launch-\(source.prefix(12))")
        try waitForButton("Continue as Guest", in: app, timeout: 20).tap()
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
            XCTAssertTrue(create.waitForExistence(timeout: 5)); create.tap()
            let name = app.textFields["studio.project-name"]
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            name.tap()
            if let value = name.value as? String, !value.isEmpty {
                name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
            }
            name.typeText(projectName)
            let confirm = app.buttons["studio.create-project"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        }
        return projectName
    }

    @MainActor private func button(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ OR label ENDSWITH %@", label, ", " + label)).firstMatch
    }

    @MainActor @discardableResult
    private func waitForButton(_ label: String, in app: XCUIApplication, timeout: TimeInterval = 10) throws -> XCUIElement {
        let element = button(label, in: app)
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing native button: \(label)")
        XCTAssertTrue(element.isHittable, "Native button is not reachable: \(label)")
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
