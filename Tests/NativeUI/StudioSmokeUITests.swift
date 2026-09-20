import XCTest
import UIKit

/// Runs against the real app and an isolated simulator. The build preflight must
/// verify empty backend settings; setting app.launchEnvironment cannot do that.
final class StudioSmokeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

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
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Layer 1".count))
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
        let popup = app.descendants(matching: .any)["studio.tool-settings"].firstMatch
        XCTAssertTrue(popup.exists && app.buttons["studio.tool-settings.close"].isHittable)
        XCTAssertFalse(popup.frame.intersects(canvas.frame), "Docked Hand popup covers the fitted portrait canvas in landscape")
        let landscapeCapture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        landscapeCapture.name = "studio-landscape"
        landscapeCapture.lifetime = .keepAlways
        add(landscapeCapture)
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
        app.buttons["studio.tool-settings.close"].tap()
        canvas.coordinate(withNormalizedOffset:CGVector(dx:0.25,dy:0.4)).tap()
        try selectToolbarTool("move",app:app)
        let copy = app.buttons["studio.selection.copy"]
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

        // Restore Pencil while its button is already visible. Doing this after
        // cold reopen required four remote rail drags and consumed 25 seconds
        // of the 180-second Eraser journey in run 35475037181.
        try pickerRailControl("studio.tool.pencil", app: app, forward: false).tap()
        try resetToolPreferencesInPopup(app)
        app.buttons["studio.tool-settings.close"].tap()

        try pickerRailControl("studio.tool.eraser", app: app, forward: true).tap()
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
        let capturedStrength = try XCTUnwrap(strength.value as? String)
        capture(app, name: "soft-eraser-strength-popup")
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
        try pickerRailControl("studio.tool.eraser", app: reopened, forward: true).tap()
        XCTAssertEqual(reopened.buttons["studio.eraser.mode.soft"].value as? String, "Selected")
        XCTAssertEqual(reopened.sliders["studio.setting.strength"].value as? String, capturedStrength)
        try resetToolPreferencesInPopup(reopened)
        XCTAssertEqual(reopened.buttons["studio.eraser.mode.hard"].value as? String, "Selected")
        reopened.buttons["studio.tool-settings.close"].tap()
    }

    @MainActor
    private func createEditableTextFixture(_ content: String, app: XCUIApplication, chooseRed: Bool = true, keepTextSelected: Bool = false) throws -> (name: String, canvas: XCUIElement, frame: CGRect, pixels: Raster) {
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
        let fontSize = app.sliders["studio.setting.font-size"]
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
    func testEditableTextCancelUndoAndEdit() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let fixture = try createEditableTextFixture("SDI", app: app, chooseRed: false)
        let canvas = fixture.canvas, frame = fixture.frame, original = fixture.pixels
        let input = app.descendants(matching: .any)["studio.text.content"].firstMatch
        capture(app, name: "editable-text-original-glyphs")
        app.buttons["studio.undo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        let blank = try pixels(canvas.screenshot().image)
        XCTAssertLessThan(exportInkMask(blank).count, exportInkMask(original).count, "Undo left text pixels behind")
        app.buttons["studio.redo"].tap(); try settlePickerCanvasAfterSave(app, canvas: canvas)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
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
        try selectToolbarTool("move", app: app)
        app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(canvas, expected: frame)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.05)).tap()
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
    func testRectangleSelectionDeleteUndoAndColdReopen() throws {
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
                if control.isHittable { return }
                XCTAssertTrue(scroll.exists, "Transform controls have no reachable popup scroll container")
                scroll.swipeUp(velocity: .slow)
            }
            XCTAssertTrue(control.isHittable, "Transform control is unreachable in its sole popup")
        }
        try revealTransformControl(scale)
        scale.adjust(toNormalizedSliderPosition: 0.4667) // roughly 200% in 25...400
        try revealTransformControl(angle)
        angle.adjust(toNormalizedSliderPosition: 0.75) // roughly 90 degrees
        try revealTransformControl(apply)
        capture(app, name: "selection-scale-rotate-popup")
        apply.tap()
        app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(canvas, expected: stableFrame)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.04)).tap()
        try settlePickerCanvasAfterSave(app, canvas: canvas)
        let changed = try pixels(canvas.screenshot().image), changedInk = exportInkMask(changed)
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
            if control.exists, control.isHittable, control.isEnabled, scroll.frame.contains(control.frame) { return control }
            scroll.swipeUp(velocity: .slow)
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
        func requestDeletion() throws {
            try selectToolbarTool("move", app: app)
            let button = app.buttons["studio.image-delete.open"]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            let popup = app.descendants(matching: .any)["studio.tool-settings"].firstMatch
            for _ in 0..<4 where !button.isHittable {
                let scroll = popup.scrollViews.firstMatch
                XCTAssertTrue(scroll.exists);scroll.swipeUp(velocity: .slow)
            }
            XCTAssertTrue(button.isHittable)
            XCTAssertTrue(expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: button).waitUntilFulfilled(timeout: 8))
            button.tap()
            XCTAssertTrue(app.buttons["Delete image"].waitForExistence(timeout: 5))
        }
        try requestDeletion()
        capture(app, name: "image-delete-confirmation")
        app.buttons["Cancel"].tap();app.buttons["studio.tool-settings.close"].tap()
        try waitForStableCanvas(canvas, expected: frame)
        XCTAssertLessThanOrEqual(try changedPixelCount(original, pixels(canvas.screenshot().image)), 4, "Cancel removed actual image pixels")
        try requestDeletion();app.buttons["Delete image"].tap()
        capture(app, name: "image-delete-after-confirmation")
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
    func testImagePlacementCancelApplyUndoAndColdReopen() throws {
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
    func testLicensedImageLibraryUndoAndColdReopen() throws {
        let app = try launchGuestStudio()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let projectName = try createProjectIfLibraryIsShown(app)
        let canvas = app.descendants(matching: .any)["studio.canvas"].firstMatch
        try waitForStableCanvas(canvas)
        let frame = canvas.frame, before = try pixels(canvas.screenshot().image)
        try openImagePanel(app)
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
        XCTAssertTrue(add.isHittable); add.tap() // second actual frame is blank
        try openExportPanel(app)
        try exportControl("studio.export.format.gif", app: app, scrollUp: false).tap()
        try exportControl("studio.export.start", app: app).tap()
        let status = app.staticTexts["studio.export.status"]
        XCTAssertTrue(expectation(for: NSPredicate(format: "label BEGINSWITH %@", "GIF ready on this device from revision "),
            evaluatedWith: status).waitUntilFulfilled(timeout: 30))
        let receipt = try exportControl("studio.export.gif.receipt", app: app)
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
    func testBucketFillPopupUndoSaveReopenAndPNG() throws {
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
        for _ in 0..<12 {
            if element.exists, element.isHittable, scroll.frame.insetBy(dx: 1, dy: 1).contains(element.frame) { return element }
            let vertical = rail.value as? String == "Vertical"
            let viewport = scroll.frame.insetBy(dx: 1, dy: 1)
            let length = vertical ? viewport.height : viewport.width
            // The retained 87c9 native failure had Brush ending at x392 while
            // the viewport ended at x390. Large flicks alternated past it.
            // Reveal the clipped edge, then hold before lifting to avoid inertia.
            var delta = (forward ? 1.0 : -1.0) * length * 0.4
            if element.exists {
                let target = element.frame
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
        XCTAssertTrue(save.isHittable); save.tap()
        XCTAssertTrue(expectation(for:NSPredicate(format:"label == %@","Saved"), evaluatedWith:save).waitUntilFulfilled(timeout:8))
        let samplingMessage = app.staticTexts.matching(NSPredicate(format:"label BEGINSWITH %@","Sampled #")).firstMatch
        XCTAssertTrue(expectation(for:NSPredicate(format:"exists == false"), evaluatedWith:samplingMessage).waitUntilFulfilled(timeout:5))
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
