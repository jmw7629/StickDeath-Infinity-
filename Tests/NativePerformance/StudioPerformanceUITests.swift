import XCTest

/// XCTMetric baselines for #266: cold launch, one real canvas stroke and a PNG
/// export, measured against the production app from a UI-test runner.
///
/// This file is a **separate target candidate** (`StickDeathInfinityPerformanceTests`,
/// see docs/PERFORMANCE_MEASUREMENT_PROTOCOL.md for the project.yml entry). It is
/// deliberately not part of `Tests/NativeUI`, whose bounded inventory, shard
/// budgets and source pin must not absorb repeated `measure` iterations.
///
/// Measurements only mean something on the owner's physical device with a
/// Release build; simulator runs are recorded as "simulator" and never compared
/// with device numbers. Nothing here is a pass until a device run exists.
final class StudioPerformanceUITests: XCTestCase {
    private let bundleIdentifier = "com.willisbmb.StickDeathInfinity"

    override func setUpWithError() throws { continueAfterFailure = false }

    /// Cold launch to the Welcome screen; five iterations as the protocol requires.
    @MainActor
    func testColdLaunchToWelcome() throws {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
            let app = XCUIApplication(bundleIdentifier: bundleIdentifier)
            app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launch()
            XCTAssertTrue(app.buttons["welcome.guest"].waitForExistence(timeout: 20), "Welcome did not appear")
            app.terminate()
        }
    }

    /// Wall clock, CPU and memory for one real drag on the rendered canvas
    /// followed by Undo, so each iteration starts from the same blank raster.
    @MainActor
    func testCanvasStrokeAndUndo() throws {
        let app = try launchGuestStudioWithNewProject()
        defer { app.terminate() }
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        let undo = app.buttons["studio.undo"]
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(application: app), XCTMemoryMetric(application: app)], options: options) {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.4))
                .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.6)))
            XCTAssertTrue(waitUntil(timeout: 5) { undo.isEnabled }, "The stroke did not reach the document history")
            undo.tap()
            XCTAssertTrue(waitUntil(timeout: 5) { !undo.isEnabled }, "Undo did not clear the single stroke")
        }
    }

    /// Wall clock and memory from tapping Export until the preview decoded from
    /// the actual PNG file appears. The export panel is closed between iterations.
    @MainActor
    func testPNGExportToPreview() throws {
        let app = try launchGuestStudioWithNewProject()
        defer { app.terminate() }
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.4))
            .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6)))
        XCTAssertTrue(waitUntil(timeout: 5) { app.buttons["studio.undo"].isEnabled })
        let toggle = app.buttons["studio.export.open"]
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric(application: app)], options: options) {
            toggle.tap()
            let png = app.descendants(matching: .any)["studio.export.format.png"].firstMatch
            XCTAssertTrue(png.waitForExistence(timeout: 5)); png.tap()
            let start = app.descendants(matching: .any)["studio.export.start"].firstMatch
            XCTAssertTrue(start.waitForExistence(timeout: 5)); start.tap()
            let preview = app.descendants(matching: .any)["studio.export.preview"].firstMatch
            XCTAssertTrue(preview.waitForExistence(timeout: 30), "No PNG preview appeared")
            XCTAssertTrue(app.staticTexts["studio.export.status"].label.contains("Export ready"))
            toggle.tap()
            XCTAssertTrue(waitUntil(timeout: 5) { !start.exists })
        }
    }

    // MARK: - Minimal launch path (mirrors the smoke suite's guest route; no fixtures)

    @MainActor
    private func launchGuestStudioWithNewProject() throws -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: bundleIdentifier)
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        try tapLabelled("welcome.guest", in: app, byIdentifier: true)
        try tapLabelled("Skip Tutorial", in: app)
        try tapLabelled("Studio", in: app)
        let library = app.descendants(matching: .any)["studio.library"].firstMatch
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        XCTAssertTrue(waitUntil(timeout: 8) { library.exists || canvas.exists })
        if library.exists {
            let create = app.buttons["studio.new-project"]
            XCTAssertTrue(create.waitForExistence(timeout: 5)); create.tap()
            let name = app.textFields["studio.project-name"]
            XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap()
            name.typeText("Perf \(UUID().uuidString.prefix(6))\n")
            let confirm = app.buttons["studio.create-project"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            let scroll = app.scrollViews["studio.library.scroll"]
            for _ in 0..<8 where !(confirm.isHittable && !app.keyboards.firstMatch.exists) { scroll.swipeUp() }
            XCTAssertTrue(confirm.isHittable, "Create must be reachable"); confirm.tap()
        }
        XCTAssertTrue(canvas.waitForExistence(timeout: 8))
        XCTAssertTrue(waitUntil(timeout: 8) { canvas.frame.width > 80 && canvas.frame.height > 80 && canvas.isHittable })
        return app
    }

    @MainActor
    private func tapLabelled(_ text: String, in app: XCUIApplication, byIdentifier: Bool = false) throws {
        let element = byIdentifier ? app.buttons[text]
            : app.buttons.matching(NSPredicate(format: "label == %@ OR label ENDSWITH %@", text, ", " + text)).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 20), "Missing native button: \(text)")
        XCTAssertTrue(waitUntil(timeout: 10) { element.isHittable }, "Native button is not reachable: \(text)")
        element.tap()
    }

    private func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
