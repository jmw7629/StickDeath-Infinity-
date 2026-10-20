import XCTest
import UIKit

/// Adaptive-layout (#264) and guest service-journey (#265, #273) checks that run
/// on both a phone and an iPad simulator in their own CI job
/// (`native-ios-journeys`, scripts/native-smoke/run_journey_ci.py).
///
/// This class lives in the same UI test bundle as StudioSmokeUITests but is
/// never selected by the sharded smoke run: each shard passes explicit
/// `-only-testing:StickDeathInfinityUITests/StudioSmokeUITests/<case>()`
/// selectors, and its receipt gate accepts only that class. The journey job
/// selects only this class.
///
/// The app is the same offline build the smoke shards use (empty public
/// settings, verified by prepare_offline_run.py), so community screens must
/// show their truthful not-configured and sign-in states. Signed-in feed,
/// room, War Room, approval-history and policy-acceptance journeys run
/// natively in Tests/AuthState/ServiceJourneyTests.swift over a local
/// URLProtocol fixture. Screenshots are kept as same-size visual evidence;
/// they are not a pixel-parity claim.
final class JourneyUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor private var idiom: String { UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "phone" }
    /// Smallest canvas side that still counts as a usable, uncollapsed canvas.
    @MainActor private var minimumCanvasSide: CGFloat { UIDevice.current.userInterfaceIdiom == .pad ? 300 : 150 }

    // MARK: #264 adaptive layouts

    @MainActor
    func testAdaptiveStudioCanvasToolbarAndFrameTimelineInBothOrientations() throws {
        let app = try launchGuestStudio(); defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        try createProject(app)
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            try rotate(app, to: orientation)
            let canvas = try settledCanvas(app)
            let toolbar = app.descendants(matching: .any)["studio.toolbar"].firstMatch
            XCTAssertTrue(toolbar.waitForExistence(timeout: 5), "Primary toolbar missing (\(orientation.rawValue))")
            XCTAssertTrue(app.frame.contains(toolbar.frame.insetBy(dx: 1, dy: 1)) || app.frame.intersects(toolbar.frame),
                          "Primary toolbar is off screen")
            let timeline = app.scrollViews["studio.frame-timeline"]
            XCTAssertTrue(timeline.waitForExistence(timeout: 5), "Frame timeline missing")
            XCTAssertTrue(app.frame.intersects(timeline.frame), "Frame timeline is off screen")
            let overlap = timeline.frame.intersection(canvas.frame)
            XCTAssertTrue(overlap.isNull || overlap.width * overlap.height < canvas.frame.width * canvas.frame.height * 0.1,
                          "Frame timeline covers the canvas")
            capture(app, name: "journey-\(idiom)-studio-\(orientation == .portrait ? "portrait" : "landscape")")
        }
    }

    @MainActor
    func testAdaptiveAudioWorkspaceKeepsCanvasAndControlsReachable() throws {
        let app = try launchGuestStudio(); defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        try createProject(app)
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            try rotate(app, to: orientation)
            _ = try settledCanvas(app)
            let open = app.buttons["studio.audio.open"]
            XCTAssertTrue(open.waitForExistence(timeout: 5) && open.isHittable, "Audio entry unreachable")
            open.tap()
            var sizes: [String] = []
            for id in ["studio.audio.library.open", "studio.audio.close", "studio.audio.snap", "studio.audio.timelinePlay"] {
                let control = app.buttons[id]
                XCTAssertTrue(control.waitForExistence(timeout: 5), "Missing audio control \(id)")
                XCTAssertTrue(control.isHittable, "Audio control \(id) is not reachable")
                XCTAssertTrue(app.frame.contains(control.frame), "Audio control \(id) is clipped")
                sizes.append("\(id) \(Int(control.frame.width))x\(Int(control.frame.height)) pt")
            }
            // Close is built as a 44 pt target. Other measured sizes are recorded
            // as actionable evidence (#264 touch targets), not asserted here.
            XCTAssertGreaterThanOrEqual(min(app.buttons["studio.audio.close"].frame.width, app.buttons["studio.audio.close"].frame.height), 44)
            let measured = XCTAttachment(string: sizes.joined(separator: "\n"))
            measured.name = "journey-\(idiom)-audio-touch-targets-\(orientation == .portrait ? "portrait" : "landscape")"
            measured.lifetime = .keepAlways
            add(measured)
            XCTAssertEqual(app.staticTexts["studio.audio.clip-count"].label, "0 clips")
            let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
            XCTAssertTrue(canvas.exists, "Opening audio removed the canvas")
            XCTAssertGreaterThan(canvas.frame.height, 80, "Audio workspace collapsed the canvas")
            XCTAssertGreaterThan(canvas.frame.width, 80, "Audio workspace collapsed the canvas")
            capture(app, name: "journey-\(idiom)-audio-\(orientation == .portrait ? "portrait" : "landscape")")
            app.buttons["studio.audio.close"].tap()
            XCTAssertTrue(waitUntilGone(app.buttons["studio.audio.close"]), "Audio workspace did not close")
        }
    }

    @MainActor
    func testAdaptiveOptionsPopoverStaysInsideWindowAndDismisses() throws {
        let app = try launchGuestStudio(); defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        try createProject(app)
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            try rotate(app, to: orientation)
            let canvas = try settledCanvas(app)
            let before = canvas.frame
            try railControl("studio.tool.pencil", app: app).tap()
            let popup = app.descendants(matching: .any)["studio.tool-settings"].firstMatch
            XCTAssertTrue(popup.waitForExistence(timeout: 5), "Options popup did not open")
            XCTAssertTrue(app.frame.insetBy(dx: -1, dy: -1).contains(popup.frame), "Options popup extends outside the window")
            let close = app.buttons["studio.tool-settings.close"]
            XCTAssertTrue(close.isHittable && min(close.frame.width, close.frame.height) >= 44, "Popup close unreachable")
            capture(app, name: "journey-\(idiom)-options-\(orientation == .portrait ? "portrait" : "landscape")")
            close.tap()
            XCTAssertTrue(waitUntilGone(popup), "Options popup did not dismiss")
            let after = try settledCanvas(app)
            XCTAssertEqual(after.frame, before, "Opening and dismissing options moved the canvas")
        }
    }

    // MARK: #265 guest journeys and #273 onboarding

    @MainActor
    func testGuestFeedRoomsAndWarRoomShowTruthfulUnconfiguredStates() throws {
        let app = try launchAtWelcome(); defer { app.terminate() }
        try tapWelcomeAction("welcome.guest", in: app)
        try waitForButton("Skip Tutorial", in: app).tap()
        let notConfigured = NSPredicate(format: "label CONTAINS %@", "not configured in this build")
        try waitForButton("Home", in: app).tap()
        XCTAssertTrue(app.buttons["feed.home.sign-in"].waitForExistence(timeout: 5), "Feed must ask a guest to sign in")
        XCTAssertTrue(app.staticTexts.matching(notConfigured).firstMatch.exists, "Feed must say services are not configured")
        XCTAssertFalse(app.descendants(matching: .any)["feed.card"].exists, "No feed card may appear without a service")
        capture(app, name: "journey-\(idiom)-feed-guest")
        try waitForButton("Rooms", in: app).tap()
        XCTAssertTrue(app.descendants(matching: .any)["rooms.not-configured"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["rooms.sign-in"].exists, "Rooms must ask a guest to sign in")
        XCTAssertFalse(app.descendants(matching: .any)["rooms.browser.room"].exists, "No room may appear without a service")
        capture(app, name: "journey-\(idiom)-rooms-guest")
        let warRoom = app.descendants(matching: .any)["rooms.warRoom"].firstMatch
        for _ in 0..<3 where !warRoom.isHittable { app.swipeUp() }
        XCTAssertTrue(warRoom.isHittable, "War Room entry unreachable")
        warRoom.tap()
        XCTAssertTrue(app.descendants(matching: .any)["warRoom.screen"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(notConfigured).firstMatch.exists, "War Room must say services are not configured")
        XCTAssertFalse(app.staticTexts["warRoom.match.result"].exists, "No invented result may appear")
        XCTAssertFalse(app.buttons["warRoom.match.play-left"].exists, "No invented matchup may appear")
        capture(app, name: "journey-\(idiom)-war-room-guest")
    }

    @MainActor
    func testGuidePolicyStepIsTruthfulWithoutServicesAndNeverBlocksStudio() throws {
        let app = try launchAtWelcome(); defer { app.terminate() }
        try tapWelcomeAction("welcome.guide", in: app)
        XCTAssertTrue(app.staticTexts["onboarding.position"].waitForExistence(timeout: 5))
        app.buttons["onboarding.dot.4"].tap()
        XCTAssertEqual(app.staticTexts["onboarding.position"].label, "5 of 5")
        let state = app.descendants(matching: .any)["onboarding.policies.not-configured"].firstMatch
        for _ in 0..<3 where !state.exists { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(state.waitForExistence(timeout: 5), "Offline build must state that acceptance is unavailable")
        XCTAssertTrue(app.descendants(matching: .any)["onboarding.policies.terms"].firstMatch.exists, "Terms link missing")
        XCTAssertTrue(app.descendants(matching: .any)["onboarding.policies.privacy"].firstMatch.exists, "Privacy link missing")
        XCTAssertFalse(app.buttons["onboarding.policies.accept"].exists, "Nothing may be accepted without a configured service")
        capture(app, name: "journey-\(idiom)-guide-policies")
        let next = app.buttons["onboarding.next"]
        XCTAssertTrue(next.isHittable, "Open Studio must stay reachable")
        next.tap()
        try waitForButton("Skip Tutorial", in: app).tap()
        XCTAssertTrue(app.descendants(matching: .any)["studio.library"].firstMatch.waitForExistence(timeout: 8),
                      "The policy step blocked Studio")
    }

    // MARK: Helpers (file-private; StudioSmokeUITests keeps its own)

    @MainActor private func launchAtWelcome() throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        XCTAssertEqual(env["SDI_SMOKE_OFFLINE_PREFLIGHT"], "1", "Run the built-app configuration preflight before launching")
        let source = try XCTUnwrap(env["SDI_SMOKE_SOURCE_COMMIT"])
        XCTAssertNotNil(source.range(of: "^[0-9a-f]{40}$", options: .regularExpression))
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.willisnmb.stickdeathinfinity")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-sdi.guest.chosen.v1", "NO", "-tutorial_completed", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["welcome.guest"].waitForExistence(timeout: 20))
        return app
    }

    @MainActor private func launchGuestStudio() throws -> XCUIApplication {
        let app = try launchAtWelcome()
        try tapWelcomeAction("welcome.guest", in: app)
        try waitForButton("Skip Tutorial", in: app).tap()
        try waitForButton("Studio", in: app).tap()
        return app
    }

    @MainActor private func tapWelcomeAction(_ identifier: String, in app: XCUIApplication) throws {
        let action = app.buttons[identifier]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        let content = app.scrollViews["welcome.content"]
        for _ in 0..<3 where !action.isHittable { content.swipeUp() }
        XCTAssertTrue(action.isHittable)
        action.tap()
    }

    @MainActor @discardableResult
    private func waitForButton(_ label: String, in app: XCUIApplication, timeout: TimeInterval = 10) throws -> XCUIElement {
        let element = app.buttons.matching(NSPredicate(format: "label == %@ OR label ENDSWITH %@", label, ", " + label)).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing native button: \(label)")
        let hittable = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: element)
        XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: timeout), .completed, "Native button is not reachable: \(label)")
        return element
    }

    @MainActor private func createProject(_ app: XCUIApplication) throws {
        let library = app.descendants(matching: .any)["studio.library"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 8), "Studio library missing")
        let create = app.buttons["studio.new-project"]
        XCTAssertTrue(create.waitForExistence(timeout: 5)); create.tap()
        let name = app.textFields["studio.project-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap()
        name.typeText("Journey \(UUID().uuidString.prefix(8))\n")
        let confirm = app.buttons["studio.create-project"]
        let scroll = app.scrollViews["studio.library.scroll"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        for _ in 0..<8 where !(confirm.isHittable && !app.keyboards.firstMatch.exists) { scroll.swipeUp() }
        XCTAssertTrue(confirm.isHittable, "Create must be reachable")
        confirm.tap()
    }

    @MainActor private func rotate(_ app: XCUIApplication, to orientation: UIDeviceOrientation) throws {
        XCUIDevice.shared.orientation = orientation
        let landscape = orientation.isLandscape
        let settled = NSPredicate { _, _ in (app.frame.width > app.frame.height) == landscape }
        let wait = expectation(for: settled, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [wait], timeout: 8), .completed, "Window did not reach orientation \(orientation.rawValue)")
    }

    /// Waits for unchanged canvas geometry for one second, then requires a
    /// usable size. A canvas narrower than the idiom's minimum is a collapse.
    @MainActor private func settledCanvas(_ app: XCUIApplication) throws -> XCUIElement {
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 8), "Canvas missing")
        var last = CGRect.null, since = Date()
        let stable = NSPredicate { _, _ in
            let frame = canvas.frame
            guard frame.width > 80, frame.height > 80 else { since = Date(); return false }
            if frame != last { last = frame; since = Date(); return false }
            return Date().timeIntervalSince(since) >= 1
        }
        let wait = expectation(for: stable, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [wait], timeout: 10), .completed, "Canvas geometry did not settle")
        let visible = canvas.frame.intersection(app.frame)
        // The canvas aspect-fits the project document, so a portrait document in
        // a short landscape phone stage is narrow by design (the 2026-10-20 run
        // measured 108 x 192 pt filling the whole stage height). A collapse is a
        // short long side, or a canvas that fills neither axis of the space the
        // docked toolbar leaves.
        XCTAssertGreaterThanOrEqual(max(visible.width, visible.height), minimumCanvasSide,
                                    "Canvas collapsed to \(visible.size) on \(idiom)")
        let available = availableCanvasArea(app)
        XCTAssertTrue(visible.width >= available.width * 0.75 || visible.height >= available.height * 0.75,
                      "Canvas \(visible.size) does not fill the available \(available.size) on \(idiom)")
        return canvas
    }

    /// The stage minus the side the primary toolbar occupies (a vertical rail
    /// docks beside the canvas; a horizontal rail sits above it).
    @MainActor private func availableCanvasArea(_ app: XCUIApplication) -> CGSize {
        let stage = app.descendants(matching: .any)["studio.toolbar.stage"].firstMatch
        XCTAssertTrue(stage.exists, "Studio stage missing")
        let bounds = stage.frame.intersection(app.frame)
        let rail = app.descendants(matching: .any)["studio.toolbar"].firstMatch
        guard rail.exists else { return bounds.size }
        let railFrame = rail.frame.intersection(bounds)
        guard !railFrame.isNull else { return bounds.size }
        return railFrame.height > railFrame.width
            ? CGSize(width: max(0, bounds.width - railFrame.width), height: bounds.height)
            : CGSize(width: bounds.width, height: max(0, bounds.height - railFrame.height))
    }

    /// Scrolls the snapping toolbar until the control is fully visible and hittable.
    @MainActor private func railControl(_ id: String, app: XCUIApplication) throws -> XCUIElement {
        let rail = app.descendants(matching: .any)["studio.toolbar"].firstMatch
        let element = app.buttons[id], scroll = rail.scrollViews.firstMatch
        XCTAssertTrue(rail.waitForExistence(timeout: 5) && scroll.exists, "Toolbar missing")
        let vertical = rail.value as? String == "Vertical"
        for attempt in 0..<12 {
            let viewport = scroll.frame.insetBy(dx: 1, dy: 1)
            if element.exists, viewport.contains(element.frame), element.isHittable { return element }
            let forward = attempt < 6
            let end = forward ? 0.2 : 0.8
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: scroll.coordinate(withNormalizedOffset:
                    CGVector(dx: vertical ? 0.5 : end, dy: vertical ? end : 0.5)),
                    withVelocity: .slow, thenHoldForDuration: 0.25)
        }
        XCTFail("Toolbar control unreachable: " + id)
        throw NSError(domain: "JourneyUITests", code: 1)
    }

    @MainActor private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

    @MainActor private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
