import XCTest
import UIKit

/// Runs against the real app and an isolated simulator. The build preflight must
/// verify empty backend settings; setting app.launchEnvironment cannot do that.
final class StudioSmokeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testGuestStudioPortraitAndLandscape() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        _ = try createProjectIfLibraryIsShown(app)
        try waitForButton("FIT", in: app)
        capture(app, name: "studio-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = NSPredicate { _, _ in app.frame.width > app.frame.height }
        XCTAssertTrue(expectation(for: landscape, evaluatedWith: nil).waitUntilFulfilled(timeout: 8))
        capture(app, name: "studio-landscape")
        XCTAssertTrue(button("FIT", in: app).isHittable, "Landscape fit control is inaccessible")
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5), "The actual rendered canvas needs its accessibility identifier")
        XCTAssertGreaterThan(canvas.frame.width, 80, "Landscape canvas collapsed")
        XCTAssertGreaterThan(canvas.frame.height, 80, "Landscape canvas collapsed")
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
        let blankPixels = try pixels(blankPreview.screenshot().image)
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
        let drawnPixels = try pixels(drawnPreview.screenshot().image)
        XCTAssertGreaterThan(try changedPixelCount(blankPixels, drawnPixels), 12,
                             "Drawing did not change the preview decoded from the actual exported PNG")
        XCTAssertTrue(app.staticTexts["frame_000000.png"].exists)
        capture(app, name: "png-export-drawn-preview")
        let share = try exportControl("studio.export.share", app: app)
        XCTAssertTrue(share.isEnabled); share.tap()

        // Save to Files is a native share action, not a button in our panel.
        // Assert its presentation but do not invoke a destination or upload.
        let saveToFiles = app.buttons.matching(NSPredicate(format: "label == %@", "Save to Files")).firstMatch
        let sheetPresented = saveToFiles.waitForExistence(timeout: 10)
        capture(app, name: "png-native-share-sheet")
        captureHierarchy(app, name: "png-native-share-sheet-hierarchy")
        XCTAssertTrue(sheetPresented, "The native share sheet did not expose its file action")
        let closeCandidates = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Close", "Cancel"))
        let dismiss = try XCTUnwrap(closeCandidates.allElementsBoundByIndex.first(where: { $0.isHittable }),
                                   "Native share sheet has no accessible dismissal control; inspect its recorded hierarchy")
        dismiss.tap()
        let status = app.staticTexts["studio.export.status"]
        XCTAssertTrue(expectation(for: NSPredicate(format: "label == %@", "Sharing cancelled. Your export is still available."),
                                  evaluatedWith: status).waitUntilFulfilled(timeout: 8))
        let retainedPreview = try exportControl("studio.export.preview", app: app)
        XCTAssertLessThanOrEqual(try changedPixelCount(drawnPixels, pixels(retainedPreview.screenshot().image)), 4,
                                 "Cancelling the share sheet lost or changed the export preview")
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
        XCTAssertTrue(app.staticTexts["Original canvas · 1080 × 1920"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Lossless PNG · 7 frames")).firstMatch.exists)
        try exportControl("studio.export.format.spritesheet", app: app, scrollUp: false).tap()
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
    private func exportControl(_ identifier: String, app: XCUIApplication, scrollUp: Bool = true) throws -> XCUIElement {
        let element = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 8), "Missing export control: \(identifier)")
        let panel = app.scrollViews.containing(.button, identifier: "studio.export.format.png").firstMatch
        func isFullyVisible() -> Bool {
            element.isHittable && panel.exists && panel.frame.insetBy(dx: 0, dy: 2).contains(element.frame)
        }
        for _ in 0..<8 where !isFullyVisible() {
            XCTAssertTrue(panel.exists, "The export ScrollView is missing")
            let upward = element.frame.isEmpty ? scrollUp : element.frame.maxY > panel.frame.maxY - 2
            // Small drags within the actual ScrollView avoid overshooting a
            // partially visible preview; no guessed window coordinates.
            let start = panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.7 : 0.3))
            let end = panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.45 : 0.55))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        XCTAssertTrue(isFullyVisible(), "Export control is not fully reachable: \(identifier)")
        return element
    }

    @MainActor
    private func waitForPNGPreview(_ app: XCUIApplication) throws -> XCUIElement {
        let preview = app.descendants(matching: .any)["studio.export.preview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 30), "No preview decoded from the actual PNG output appeared")
        let visible = try exportControl("studio.export.preview", app: app)
        XCTAssertGreaterThan(visible.frame.width, 20); XCTAssertGreaterThan(visible.frame.height, 20)
        XCTAssertTrue(app.staticTexts["studio.export.status"].label.contains("Export ready"))
        return visible
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
