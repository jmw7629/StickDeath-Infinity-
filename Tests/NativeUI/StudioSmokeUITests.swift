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
