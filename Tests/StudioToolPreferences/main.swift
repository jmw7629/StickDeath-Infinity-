import AppKit
import SwiftUI
import ImageIO
import AVFoundation

typealias UIImage = NSImage
extension Image { init(uiImage: NSImage) { self.init(nsImage: uiImage) } }
private struct Failure: Error { let message: String }

@main @MainActor struct ToolPreferenceTests {
    static var passed = 0
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(message: message) }
    }
    static func rejects(_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw Failure(message: "Invalid operation succeeded")
    }
    static func pass(_ name: String) { passed += 1; print("PASS " + name) }
    static func shape(_ layer: String, tool: DrawingTool = .rectangle,
                      fill: String? = "#FF0000", radius: Double = 0, opacity: Double = 1) -> DrawnElement {
        .init(id: UUID().uuidString, tool: tool,
              points: [.init(x: 16, y: 16), .init(x: 112, y: 112)], color: "#FF0000",
              width: 8, opacity: opacity, layerID: layer,
              shape: .init(fillColor: fill, cornerRadius: radius))
    }
    static func document(_ element: DrawnElement? = nil) throws -> StudioDocument {
        var d = try StudioDocument.new(name: "Real shape settings", width: 128, height: 128, fps: 12)
        if var element { element.layerID = d.activeLayerID; d.frames[0].elements = [element]; d.schemaVersion = 5 }
        return d
    }
    static func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let success = bytes.withUnsafeMutableBytes { data -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: data.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)); return true
        }
        try require(success, "Actual image pixel decode")
        return bytes
    }
    static func render(_ d: StudioDocument, size: Int = 128) throws -> [UInt8] {
        let frame = d.frames[0], brushes = try StudioFrameRenderer.prepare(frame: frame)
        var failure: Error?
        let content = Canvas { context, actual in
            failure = StudioFrameRenderer.draw(context: &context, frame: frame, layers: d.layers,
                canvasSize: CGSize(width: d.width, height: d.height), size: actual, preparedBrushes: brushes)
        }.frame(width: CGFloat(size), height: CGFloat(size))
        let renderer = ImageRenderer(content: content); renderer.scale = 1
        guard let image = renderer.cgImage else { throw Failure(message: "Actual canonical shape renderer") }
        if let failure { throw failure }
        return try pixels(image)
    }
    static func channel(_ pixels: [UInt8], _ x: Int, _ y: Int, _ c: Int = 3, width: Int = 128) -> UInt8 {
        pixels[(y * width + x) * 4 + c]
    }
    static func main() async throws {
        setbuf(stdout, nil)
        let constraintSuite = "sdi-constraint-prefs-" + UUID().uuidString
        let constraintDefaults = UserDefaults(suiteName: constraintSuite)!
        defer { constraintDefaults.removePersistentDomain(forName: constraintSuite) }
        let constrainedVM = StudioViewModel(toolDefaults: constraintDefaults)
        constrainedVM.selectedTool = .line; constrainedVM.lineAngleSnap = 45
        constrainedVM.lineRulerEnabled = true; constrainedVM.lineRulerAngle = 30
        constrainedVM.lineRulerFixedLength = true; constrainedVM.lineRulerLength = 48
        constrainedVM.selectedTool = .rectangle; constrainedVM.equalShapeSides = true; constrainedVM.mirrorMode = .both
        constrainedVM.selectedTool = .circle
        try require(!constrainedVM.equalShapeSides && constrainedVM.lineAngleSnap == 0, "Constraints leaked to another tool")
        let restoredConstraints = StudioViewModel(toolDefaults: constraintDefaults)
        restoredConstraints.selectedTool = .line
        try require(restoredConstraints.lineAngleSnap == 45, "Line snapping did not survive relaunch")
        try require(restoredConstraints.lineRulerEnabled && restoredConstraints.lineRulerAngle == 30 && restoredConstraints.lineRulerFixedLength && restoredConstraints.lineRulerLength == 48, "Ruler settings did not survive relaunch")
        restoredConstraints.selectedTool = .rectangle
        try require(restoredConstraints.equalShapeSides && restoredConstraints.mirrorMode == .both, "Square/mirror preference did not survive relaunch")
        var oldConstraintEntry = StudioDrawingToolPreferences.Entry()
        let legacyConstraintData = try JSONEncoder().encode(oldConstraintEntry)
        try require(try JSONDecoder().decode(StudioDrawingToolPreferences.Entry.self, from: legacyConstraintData).isValid, "Legacy preference migration failed")
        oldConstraintEntry.lineAngleSnap = 17
        try require(!oldConstraintEntry.isValid, "Invalid snap angle persisted")
        pass("line and shape constraints restore independently per tool without changing legacy preferences")

        let suite = "sdi-tool-preferences-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let storage = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("Documents"), cachesDirectory: root.appendingPathComponent("Cache"))
        let vm = StudioViewModel(storage: storage, toolDefaults: defaults)
        let made = await vm.createProject(name: "Independent tool settings", width: 128, height: 128, fps: 12)
        try require(made, "Actual project creation")
        let original = vm.document
        vm.selectDrawingTool(.pencil); try require(vm.strokeWidth == 2 && vm.brushFamily == .round, "Pencil defaults")
        vm.selectDrawingTool(.marker); try require(vm.strokeWidth == 12 && vm.strokeOpacity == 0.75 && vm.brushFamily == .calligraphy, "Marker defaults")
        vm.selectDrawingTool(.crayon); try require(vm.strokeWidth == 8 && vm.brushFamily == .grain && vm.smoothing == 1, "Crayon defaults")
        vm.selectDrawingTool(.pen); try require(vm.strokeWidth == 3 && vm.brushFamily == .roughPen, "Pen defaults")
        vm.selectDrawingTool(.eraser); try require(vm.strokeWidth == 8 && vm.strokeOpacity == 1, "Eraser defaults")
        try require(vm.document == original && !vm.isDirty && !vm.canUndo, "Tool defaults changed saved project/history")
        pass("distinct actual tool defaults do not mutate document or history")

        vm.selectDrawingTool(.brush)
        vm.strokeWidth = 18; vm.strokeOpacity = 0.4; vm.smoothing = 7
        vm.brushFamily = .hatchLeft; vm.brushTipAngle = 120; vm.brushTexture = 0.8; vm.brushGrain = 0.65
        vm.brushGradientEndColor = Color(red: 0, green: 1, blue: 0)
        vm.selectDrawingTool(.pen); vm.strokeWidth = 6; vm.strokeOpacity = 0.8; vm.brushFamily = .dipPen
        vm.selectDrawingTool(.brush)
        try require(vm.strokeWidth == 18 && vm.strokeOpacity == 0.4 && vm.smoothing == 7 && vm.brushFamily == .hatchLeft && vm.brushTipAngle == 120 && vm.brushTexture == 0.8 && vm.brushGrain == 0.65, "Brush settings bled into another tool")
        vm.selectDrawingTool(.pen); vm.selectDrawingTool(.pen)
        try require(vm.strokeWidth == 6 && vm.strokeOpacity == 0.8 && vm.brushFamily == .dipPen, "Same-tool reselect reset custom family")
        // Compatibility assignments use the same preference path as toolbar selection.
        vm.selectedTool = .brush; try require(vm.brushFamily == .hatchLeft && vm.strokeWidth == 18, "Direct selection bypassed preference restore")
        try require(vm.document == original && !vm.isDirty && !vm.canUndo, "Preference edits dirtied a saved project")
        pass("per-tool size opacity family smoothing texture grain and nib survive switching and retap")

        vm.selectDrawingTool(.rectangle); vm.shapeFilled = true; vm.shapeCornerRadius = 23; vm.strokeWidth = 5
        vm.selectDrawingTool(.circle); try require(!vm.shapeFilled && vm.shapeCornerRadius == 0 && vm.strokeWidth == 3, "Rectangle leaked into ellipse")
        vm.selectDrawingTool(.rectangle)
        try require(vm.shapeDescriptor()?.fillColor != nil && vm.shapeDescriptor()?.cornerRadius == 23 && vm.strokeWidth == 5, "Actual shape capture lost preferences")
        vm.selectDrawingTool(.fill); vm.strokeOpacity = 0.3
        vm.selectDrawingTool(.eraser); vm.strokeOpacity = 0.6
        vm.selectDrawingTool(.fill); try require(vm.strokeOpacity == 0.3, "Fill opacity was overwritten by eraser")
        pass("rectangle ellipse fill and eraser keep independent applicable settings")

        vm.selectDrawingTool(.fill)
        vm.fillTolerance = 17.5; vm.fillExpand = -2; vm.fillGapClose = 3
        vm.fillContiguous = false; vm.fillAntiAlias = false; vm.fillSampleAll = true
        vm.selectDrawingTool(.brush)
        try require(vm.fillTolerance == 32 && vm.fillExpand == 0 && vm.fillGapClose == 0
            && vm.fillContiguous && vm.fillAntiAlias && !vm.fillSampleAll, "Fill settings leaked into another tool")
        vm.selectDrawingTool(.fill)
        try require(vm.fillTolerance == 17.5 && vm.fillExpand == -2 && vm.fillGapClose == 3
            && !vm.fillContiguous && !vm.fillAntiAlias && vm.fillSampleAll, "Switching lost fill controls")
        let fillCold = StudioViewModel(storage: storage, toolDefaults: UserDefaults(suiteName: suite))
        fillCold.selectDrawingTool(.fill)
        try require(fillCold.fillTolerance == 17.5 && fillCold.fillExpand == -2 && fillCold.fillGapClose == 3
            && !fillCold.fillContiguous && !fillCold.fillAntiAlias && fillCold.fillSampleAll, "Fresh VM lost fill preferences")
        let beforeFillReset = vm.document
        vm.resetCurrentDrawingToolPreferences()
        try require(vm.fillTolerance == 32 && vm.fillExpand == 0 && vm.fillGapClose == 0
            && vm.fillContiguous && vm.fillAntiAlias && !vm.fillSampleAll && vm.strokeOpacity == 1,
            "Fill Reset did not restore every displayed control")
        try require(vm.document == beforeFillReset && !vm.canUndo && !vm.isDirty, "Fill preferences or Reset changed artwork/history")
        let resetCold = StudioViewModel(storage: storage, toolDefaults: UserDefaults(suiteName: suite))
        resetCold.selectDrawingTool(.fill)
        try require(resetCold.fillTolerance == 32 && resetCold.fillExpand == 0 && resetCold.fillGapClose == 0
            && resetCold.fillContiguous && resetCold.fillAntiAlias && !resetCold.fillSampleAll, "Fill Reset was not persisted")
        vm.selectDrawingTool(.brush)
        try require(vm.strokeWidth == 18 && vm.strokeOpacity == 0.4 && vm.brushFamily == .hatchLeft,
            "Fill Reset changed another tool")
        pass("all fill controls persist independently through fresh VM and Reset without artwork/history edits")

        var legacyFill = StudioDrawingToolPreferences()
        legacyFill.values[DrawingTool.fill.rawValue] = .init(opacity: 0.3)
        let legacyFillBytes = try legacyFill.encoded()
        let legacyFillDecoded = try StudioDrawingToolPreferences.decode(legacyFillBytes)
        try require(legacyFillDecoded.settings(for: .fill).fillTolerance == nil
            && legacyFillDecoded.settings(for: .fill).opacity == 0.3, "Old version1 Fill settings did not decode")
        for invalid in [Double.nan, Double.infinity, -1, 129] {
            var corrupt = legacyFill; corrupt.values[DrawingTool.fill.rawValue]?.fillTolerance = invalid
            try rejects { _ = try corrupt.encoded() }
        }
        for invalid in [-6.0, 6, Double.nan] {
            var corrupt = legacyFill; corrupt.values[DrawingTool.fill.rawValue]?.fillExpand = invalid
            try rejects { _ = try corrupt.encoded() }
        }
        for invalid in [-1.0, 6, Double.infinity] {
            var corrupt = legacyFill; corrupt.values[DrawingTool.fill.rawValue]?.fillGapClose = invalid
            try rejects { _ = try corrupt.encoded() }
        }
        vm.selectDrawingTool(.fill)
        let validFillBytes = defaults.data(forKey: StudioViewModel.toolPreferencesKey)
        vm.fillTolerance = .nan
        try require(defaults.data(forKey: StudioViewModel.toolPreferencesKey) == validFillBytes,
            "Invalid runtime Fill setting poisoned stored preferences")
        vm.selectDrawingTool(.brush); vm.selectDrawingTool(.fill)
        try require(vm.fillTolerance == 32, "Invalid runtime Fill setting survived tool restore")
        pass("optional version1 fill fields preserve legacy data and reject invalid persisted/runtime ranges")

        let persisted = try StudioDrawingToolPreferences.decode(defaults.data(forKey: StudioViewModel.toolPreferencesKey)!)
        let end = persisted.settings(for: .brush).gradientEnd
        try require(end.green > 0.99 && end.red < 0.01 && end.blue < 0.01, "Actual gradient endpoint was not serialized")
        let cold = StudioViewModel(storage: storage, toolDefaults: UserDefaults(suiteName: suite))
        cold.selectDrawingTool(.brush); try require(cold.strokeWidth == 18 && cold.brushFamily == .hatchLeft && cold.strokeOpacity == 0.4, "New production instance lost brush preferences")
        cold.selectDrawingTool(.pen); try require(cold.brushFamily == .dipPen && cold.strokeWidth == 6, "New production instance lost pen preferences")
        cold.selectDrawingTool(.rectangle); try require(cold.shapeFilled && cold.shapeCornerRadius == 23, "New production instance lost shape preferences")
        pass("actual UserDefaults and fresh production view model restore persisted preferences")
        vm.selectDrawingTool(.brush); vm.pressureSensitivity = true
        let pressureCapture = try vm.brushDescriptor(elementID: "pressure-captured")
        try require(pressureCapture.pressureEnabled, "Pressure toggle did not change the real brush descriptor")
        vm.selectDrawingTool(.pen)
        try require(!vm.pressureSensitivity, "Pressure preference leaked into another tool")
        let pressureReopened = StudioViewModel(toolDefaults: UserDefaults(suiteName: suite))
        pressureReopened.selectDrawingTool(.brush)
        try require(pressureReopened.pressureSensitivity, "Pressure preference was lost on cold launch")
        vm.selectDrawingTool(.brush); vm.pressureSensitivity = false
        try require(pressureCapture.pressureEnabled && !(try vm.brushDescriptor(elementID: "pressure-off")).pressureEnabled,
                    "Changing pressure modified an already captured stroke or failed to affect the next stroke")


        vm.selectDrawingTool(.brush); vm.brushFamily = .calligraphy; vm.pencilTiltEnabled = true
        let tiltCapture = try vm.brushDescriptor(elementID: "tilt-captured")
        try require(tiltCapture.tiltEnabled == true && tiltCapture.version == 2, "Tilt toggle did not affect capture")
        vm.selectDrawingTool(.pen); try require(!vm.pencilTiltEnabled, "Tilt preference leaked across tools")
        let tiltReopened = StudioViewModel(toolDefaults: UserDefaults(suiteName: suite))
        tiltReopened.selectDrawingTool(.brush)
        try require(tiltReopened.pencilTiltEnabled, "Cold settings restore lost tilt")
        vm.selectDrawingTool(.brush); vm.brushFamily = .round
        try require(try vm.brushDescriptor(elementID: "round-no-tilt").tiltEnabled != true, "Tilt leaked into an inapplicable brush family")

        vm.selectDrawingTool(.brush); vm.resetCurrentDrawingToolPreferences()
        try require(vm.strokeWidth == 3 && vm.strokeOpacity == 1 && vm.brushFamily == .round, "Reset failed")
        vm.selectDrawingTool(.pen); try require(vm.strokeWidth == 6 && vm.brushFamily == .dipPen, "Reset changed another tool")
        let afterReset = StudioViewModel(toolDefaults: UserDefaults(suiteName: suite))
        try require(afterReset.strokeWidth == 3 && afterReset.brushFamily == .round, "Reset did not persist")
        try require(vm.document == original && !vm.canUndo, "Reset changed actual document")
        pass("reset affects only the selected tool and is persisted without history")

        for family in [StudioBrushFamily.airbrush, .watercolor, .neon] {
            vm.selectDrawingTool(.brush); vm.brushFamily = family
            vm.brushTexture = 0.73; vm.brushGrain = 0.41
            let captured = try vm.brushDescriptor(elementID: "extended-" + family.rawValue, seed: 76)
            vm.selectDrawingTool(.pen)
            let cold = StudioViewModel(toolDefaults: UserDefaults(suiteName: suite))
            cold.selectDrawingTool(.brush)
            try require(cold.brushFamily == family && cold.brushTexture == 0.73 && cold.brushGrain == 0.41, "Extended family settings did not survive cold per-tool restore")
            try require(try cold.brushDescriptor(elementID: "extended-" + family.rawValue, seed: 76) == captured, "Restored extended brush capture differs")
            try require(vm.brushFamily == .dipPen, "New family changed independent Pen settings")
        }
        pass("Airbrush, Watercolor and Neon settings persist independently and restore identical capture descriptors")

        var arrowPixels = Set<Data>()
        for ends in [StudioArrowEnds.start, .end, .both] {
            var d = try StudioDocument.new(name: "Arrow", width: 128, height: 128, fps: 12)
            let descriptor = StudioShapeDescriptor(version: 2, arrowEnds: ends, arrowLength: 24)
            let element = DrawnElement(id: "arrow", tool: .line, points: [.init(x: 16, y: 64), .init(x: 112, y: 64)],
                color: "#FF0000", width: 4, opacity: 0.5, layerID: d.activeLayerID, shape: descriptor)
            var editor = try StudioDocumentEditor(document: d); try editor.commit(element, frameID: d.activeFrameID); d = editor.document
            try require(d.schemaVersion == 26 && (element.selectionBounds?.height ?? 0) >= 24, "Arrow version or selectable head bounds missing")
            let actual = try render(d); arrowPixels.insert(Data(actual))
            try require(stride(from: 3, to: actual.count, by: 4).map { actual[$0] }.max()! <= 129, "Arrow shaft/head overlap compounded opacity")
            let output = try await StudioExportService().export(document: d, format: .pngSequence, outputParent: root, background: .transparent)
            let source = CGImageSourceCreateWithURL(output.imageURLs[0] as CFURL, nil)!
            guard let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure(message: "Arrow PNG could not reopen") }
            try require(try pixels(decoded) == actual, "Arrow PNG differs from actual canvas pixels")
            let archive = try StudioDocumentArchive(document: d, rasterFrameIndices: [:]).encoded()
            try require(StudioDocumentArchive.decode(archive).document == d, "Arrow archive changed")
            var old = d; old.schemaVersion = 25; try rejects { try old.validate() }
            editor.undo(); try require(editor.document.frames[0].elements.isEmpty, "Arrow undo failed")
            editor.redo(); try require(try render(editor.document) == actual, "Arrow redo changed actual pixels")
        }
        try require(arrowPixels.count == 3, "Start/end/both arrowheads render identically")
        let shortHeads = StudioShapeDescriptor(version: 2, arrowEnds: .both, arrowLength: 100)
        let triangles = shortHeads.arrowTriangles(from: .zero, to: .init(x: 4, y: 0))
        try require(triangles.count == 2 && triangles.flatMap { $0 }.allSatisfy { $0.x >= 0 && $0.x <= 4 && abs($0.y) <= 1 }, "Short arrow heads reverse or exceed the shaft")
        try require(shortHeads.arrowTriangles(from: .zero, to: .zero).isEmpty, "Zero-length arrow created invalid head geometry")
        var badHead = shortHeads; badHead.arrowLength = .nan
        try rejects { try badHead.validate(tool: .line) }
        try rejects { try shortHeads.validate(tool: .rectangle) }
        vm.selectDrawingTool(.line); vm.lineArrowEnds = .both; vm.lineArrowLength = 32
        let savedArrowDescriptor = try vm.shapeDescriptor()
        vm.selectDrawingTool(.rectangle); try require(vm.lineArrowEnds == .none, "Arrow options leaked to Rectangle")
        let coldArrow = StudioViewModel(toolDefaults: UserDefaults(suiteName: suite)); coldArrow.selectDrawingTool(.line)
        try require(coldArrow.lineArrowEnds == .both && coldArrow.lineArrowLength == 32 && coldArrow.shapeDescriptor() == savedArrowDescriptor, "Arrow options failed cold per-tool restore")
        let arrowStore = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("arrows"))
        let arrowVM = StudioViewModel(storage: arrowStore)
        let arrowCreated = await arrowVM.createProject(name: "Saved arrow", width: 128, height: 128, fps: 12); try require(arrowCreated, "Arrow create failed")
        arrowVM.selectedTool = .line; arrowVM.lineArrowEnds = .end; arrowVM.lineArrowLength = 20
        var arrowInput = StudioStrokeInput(id: "captured-arrow", frameID: arrowVM.currentFrame.id, layerID: arrowVM.activeLayerID,
            tool: .line, color: "#FF0000", width: 4, opacity: 0.5, brush: nil, documentSize: .init(width: 128, height: 128),
            viewportSize: .init(width: 128, height: 128), startedAt: Date(timeIntervalSince1970: 0), shape: try arrowVM.shapeDescriptor(), angleSnapDegrees: 45)
        try arrowInput.append(location: .init(x: 16, y: 16), time: Date(timeIntervalSince1970: 0))
        try arrowInput.append(location: .init(x: 96, y: 78), time: Date(timeIntervalSince1970: 1))
        arrowVM.lineArrowEnds = .none
        try require(arrowInput.element.shape?.arrowEnds == .end && arrowVM.commitElement(arrowInput.element), "Captured arrow changed after settings edit")
        let savedArrowPixels = try render(arrowVM.document)
        let arrowSaved = await arrowVM.save(); try require(arrowSaved, "Actual arrow save failed")
        let coldArrowProject = StudioViewModel(storage: arrowStore)
        let arrowReopened = await coldArrowProject.openProject(arrowStore.listAnimations()[0]); try require(arrowReopened, "Arrow cold reopen failed")
        try require(try render(coldArrowProject.document) == savedArrowPixels, "Arrow pixels changed across actual cold reopen")
        pass("Arrowhead geometry, alpha, schema26, Undo/Redo, selectable bounds, per-tool cold preferences and actual save/reopen")

        // A settings edit after capture cannot rewrite the in-progress operation.
        vm.selectDrawingTool(.brush); vm.strokeWidth = 4; vm.strokeOpacity = 1; vm.brushFamily = .round
        func capturedStroke(id: String, y: CGFloat) throws -> StudioStrokeInput {
            var input = StudioStrokeInput(id: id, frameID: vm.currentFrame.id, layerID: vm.activeLayerID,
                tool: vm.selectedTool, color: vm.strokeColorHex, width: vm.strokeWidth, opacity: vm.capturedStrokeOpacity,
                brush: try vm.brushDescriptor(elementID: id, seed: 99), documentSize: .init(width: 128, height: 128),
                viewportSize: .init(width: 128, height: 128), startedAt: Date(timeIntervalSince1970: 0))
            try input.append(location: .init(x: 16, y: y), time: Date(timeIntervalSince1970: 0))
            try input.append(location: .init(x: 112, y: y), time: Date(timeIntervalSince1970: 0.1))
            return input
        }
        let thin = try capturedStroke(id: "thin", y: 32)
        vm.selectDrawingTool(.marker); vm.strokeWidth = 30
        try require(thin.element.width == 4 && thin.element.brush?.family == .round && thin.element.opacity == 1, "Tool change rewrote captured stroke")
        vm.selectDrawingTool(.brush); try require(vm.strokeWidth == 4, "Brush width lost during capture")
        try require(vm.commitElement(thin.element), "Actual thin stroke commit")
        let thinPixels = try render(vm.document)
        vm.strokeWidth = 24
        let wide = try capturedStroke(id: "wide", y: 96)
        try require(vm.commitElement(wide.element), "Actual wide stroke commit")
        let widePixels = try render(vm.document)
        let thinCoverage = thinPixels.enumerated().filter { $0.offset % 4 == 3 && $0.element > 0 }.count
        let wideCoverage = widePixels.enumerated().filter { $0.offset % 4 == 3 && $0.element > 0 }.count - thinCoverage
        try require(thinCoverage > 0 && wideCoverage > thinCoverage * 3, "Actual width preference did not materially change pixels")
        vm.undo(); try require(try render(vm.document) == thinPixels, "Undo did not restore actual earlier pixels")
        vm.redo(); try require(try render(vm.document) == widePixels, "Redo did not restore actual wider stroke pixels")
        let saved = await vm.save(); try require(saved, "Actual save failed")
        let reopened = StudioViewModel(storage: storage, toolDefaults: UserDefaults(suiteName: suite))
        let listed = try storage.listAnimationsReportingFailures().animations
        let opened = await reopened.openProject(listed.first { $0.id == vm.document.id }!)
        try require(opened && reopened.strokeWidth == 24 && (try render(reopened.document)) == widePixels, "Cold project reopen changed artwork or preferences")
        pass("real captured strokes change rendered pixels and survive undo redo production save and fresh reopen")

        let validData = defaults.data(forKey: StudioViewModel.toolPreferencesKey)!
        vm.strokeWidth = .nan
        try require(defaults.data(forKey: StudioViewModel.toolPreferencesKey) == validData, "Non-finite value poisoned persisted preferences")
        vm.selectDrawingTool(.pen); vm.selectDrawingTool(.brush)
        try require(vm.strokeWidth == 24, "Invalid width poisoned next selection")
        vm.brushTipAngle = .infinity
        try require(defaults.data(forKey: StudioViewModel.toolPreferencesKey) == validData, "Invalid tip angle poisoned persisted preferences")
        vm.selectDrawingTool(.pen); vm.selectDrawingTool(.brush)
        try require(vm.brushTipAngle.isFinite, "Invalid tip angle poisoned restore")
        pass("invalid runtime input cannot poison saved preferences or another tool")

        var invalid = persisted; invalid.version = 99
        try rejects { _ = try StudioDrawingToolPreferences.decode(JSONEncoder().encode(invalid)) }
        invalid = persisted; invalid.values["not-a-tool"] = .init()
        try rejects { _ = try invalid.encoded() }
        invalid = persisted; invalid.values["brush"]!.opacity = 2
        try rejects { _ = try StudioDrawingToolPreferences.decode(JSONEncoder().encode(invalid)) }
        try rejects { _ = try StudioDrawingToolPreferences.decode(Data(repeating: 0, count: 32_769)) }
        let corrupt = Data("{invalid preferences}".utf8)
        defaults.set(corrupt, forKey: StudioViewModel.toolPreferencesKey)
        let recovered = StudioViewModel(storage: storage, toolDefaults: defaults)
        try require(recovered.toolPreferencesWarning != nil && recovered.strokeWidth == 3 && defaults.data(forKey: StudioViewModel.toolPreferencesKey) == corrupt, "Invalid stored bytes were overwritten or treated as valid")
        let recoveredOpen = await recovered.openProject(listed.first { $0.id == vm.document.id }!)
        try require(recoveredOpen && (try render(recovered.document)) == widePixels, "Corrupt device preferences damaged saved artwork")
        pass("bounded strict preference decoding falls back without overwriting corrupt bytes or project artwork")
        let paletteStorage = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("PaletteDocuments"), cachesDirectory: root.appendingPathComponent("PaletteCache"))
        let palette = StudioViewModel(storage: paletteStorage, toolDefaults: constraintDefaults)
        let paletteMade = await palette.createProject(name: "Real custom color", width: 128, height: 128, fps: 12)
        try require(paletteMade, "Palette project creation")
        let cleanPaletteDocument = palette.document
        try require(palette.applyCustomColorHex("  1280fe  ") && palette.strokeColorHex == "#1280FE", "Custom drawing color did not apply exact bytes")
        try require(palette.applyCustomColorHex("#34A057", gradientEnd: true) && palette.brushGradientEndColorHex == "#34A057" && palette.strokeColorHex == "#1280FE", "Gradient endpoint changed drawing color")
        let recentBeforeInvalid = palette.recentColorHexes
        for invalid in ["", "#12", "#12345678", "GG0000", "12345🙂"] {
            try require(!palette.applyCustomColorHex(invalid) && palette.recentColorHexes == recentBeforeInvalid && palette.strokeColorHex == "#1280FE", "Invalid custom color changed state")
        }
        try require(palette.document == cleanPaletteDocument && !palette.isDirty && !palette.canUndo, "Color choices created document edits")
        for i in 0..<24 { palette.rememberRecentColor(String(format: "#%06X", i)) }
        palette.rememberRecentColor("#000016")
        try require(palette.recentColorHexes.count == 16 && Set(palette.recentColorHexes).count == 16 && palette.recentColorHexes.first == "#000016", "Recent colors were not bounded and deduplicated")
        let restoredPalette = StudioViewModel(storage: paletteStorage, toolDefaults: constraintDefaults)
        try require(restoredPalette.recentColorHexes == palette.recentColorHexes, "Recent swatches did not survive relaunch")
        let colorStroke = DrawnElement(id: "custom-color", tool: .line, points: [.init(x:16,y:64),.init(x:112,y:64)], color: palette.strokeColorHex, width: 8, opacity: 1, layerID: palette.activeLayerID)
        try require(palette.commitElement(colorStroke), "Custom color stroke failed")
        let colorPixels = try render(palette.document)
        try require(abs(Int(channel(colorPixels,64,64,0))-18)<=1 && abs(Int(channel(colorPixels,64,64,1))-128)<=1 && abs(Int(channel(colorPixels,64,64,2))-254)<=1, "Custom color bytes did not reach canonical rendered pixels")
        constraintDefaults.set(["bad", "#ffffff", "FFFFFF", "#102030"], forKey: StudioViewModel.recentColorsKey)
        let sanitizedPalette = StudioViewModel(storage: paletteStorage, toolDefaults: constraintDefaults)
        try require(sanitizedPalette.recentColorHexes == ["#FFFFFF", "#102030"], "Stored swatches were not normalized and deduplicated")
        pass("custom drawing and gradient colors validate exact bytes; recent swatches persist bounded without document edits and render real pixels")
        let renameStore = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("Rename"))
        let renameVM = StudioViewModel(storage: renameStore)
        let madeRename = await renameVM.createProject(name: "Before", width: 128, height: 128, fps: 12)
        try require(madeRename, "Rename project creation failed")
        let renameOriginal = renameVM.document
        try require(renameVM.renameProject("  After  ", expectedProjectID: renameOriginal.id, expectedRevision: renameOriginal.revision), "Valid rename rejected")
        try require(renameVM.projectName == "After" && renameVM.document.id == renameOriginal.id && renameVM.document.frames == renameOriginal.frames && renameVM.document.layers == renameOriginal.layers, "Rename changed project identity or artwork")
        renameVM.undo(); try require(renameVM.projectName == "Before", "Rename undo lost title")
        renameVM.redo(); try require(renameVM.projectName == "After", "Rename redo failed")
        let renamed = renameVM.document
        try require(!renameVM.renameProject("Stale", expectedProjectID: renameOriginal.id, expectedRevision: renameOriginal.revision) && renameVM.document == renamed, "Stale rename overwrote intervening edit")
        try require(!renameVM.renameProject("Wrong", expectedProjectID: UUID(), expectedRevision: renamed.revision) && renameVM.document == renamed, "Foreign project rename accepted")
        for invalid in ["  ", String(repeating: "a", count: 121), "bad\u{0000}name"] {
            try require(!renameVM.renameProject(invalid, expectedProjectID: renamed.id, expectedRevision: renamed.revision) && renameVM.document == renamed, "Invalid name mutated project")
        }
        try require(renameVM.renameProject("After", expectedProjectID: renamed.id, expectedRevision: renamed.revision) && renameVM.document == renamed, "No-op rename changed revision")
        let renameSaved = await renameVM.save(); try require(renameSaved, "Renamed project save failed")
        let reopenedRename = StudioViewModel(storage: renameStore); await reopenedRename.loadProjects()
        try require(reopenedRename.savedProjects.count == 1 && reopenedRename.savedProjects[0].title == "After" && reopenedRename.savedProjects[0].id == renameOriginal.id, "Rename created another project or stale library entry")
        let renameOpened = await reopenedRename.openProject(reopenedRename.savedProjects[0])
        try require(renameOpened && reopenedRename.projectName == "After" && reopenedRename.document.frames == renameOriginal.frames, "Cold reopen lost renamed title or artwork")
        pass("project rename preserves identity artwork one-step Undo Redo and actual cold persistence; stale invalid and no-op edits are bounded")
        reopenedRename.projectThumbnailRenderer = { document, raster in
            try StudioExportService().projectThumbnail(document: document, raster: raster)
        }
        await reopenedRename.backToProjects()
        let originalMetadata = reopenedRename.savedProjects[0]
        try require(originalMetadata.thumbnailData?.isEmpty == false, "Returning to library did not persist a real thumbnail")
        let thumbnail = originalMetadata.thumbnailData!
        guard let thumbSource = CGImageSourceCreateWithData(thumbnail as CFData, nil),
              let thumbImage = CGImageSourceCreateImageAtIndex(thumbSource, 0, nil) else {
            throw Failure(message: "Saved thumbnail is not a decodable image")
        }
        try require(thumbImage.width == 128 && thumbImage.height == 128, "Thumbnail dimensions changed aspect ratio")
        await reopenedRename.duplicateProject(originalMetadata)
        try require(reopenedRename.savedProjects.count == 2, "Duplicate not listed")
        guard let duplicateMetadata = reopenedRename.savedProjects.first(where: { $0.id != renameOriginal.id }) else { throw Failure(message: "Duplicate identity missing") }
        let duplicateOpened = await reopenedRename.openProject(duplicateMetadata)
        try require(duplicateOpened && reopenedRename.projectName == "After Copy" && reopenedRename.document.frames == renameOriginal.frames, "Duplicate lost artwork/name")
        await reopenedRename.backToProjects()
        await reopenedRename.moveProjectToRecovery(duplicateMetadata.id)
        try require(reopenedRename.savedProjects.count == 1 && reopenedRename.recoverableProjects.count == 1, "VM removal did not refresh listings")
        await reopenedRename.restoreProject(duplicateMetadata.id)
        try require(reopenedRename.savedProjects.count == 2 && reopenedRename.recoverableProjects.isEmpty, "VM restore did not refresh listings")
        pass("project duplicate uses distinct identity and actual archive validation; recoverable removal and restore refresh actual library")
        let selectionSuite = "sdi-selection-preferences-" + UUID().uuidString
        let selectionDefaults = UserDefaults(suiteName: selectionSuite)!
        defer { selectionDefaults.removePersistentDomain(forName: selectionSuite) }
        let selectionVM = StudioViewModel(toolDefaults: selectionDefaults)
        let selectionDocument = selectionVM.document
        selectionVM.selectDrawingTool(.move); selectionVM.selectionMode = .add
        selectionVM.selectDrawingTool(.lasso)
        try require(selectionVM.selectionMode == .new, "Move mode leaked into Lasso")
        selectionVM.selectionMode = .subtract; selectionVM.areaSelectionKind = .polygon; selectionVM.areaSelectionSmoothing = 7
        selectionVM.selectDrawingTool(.move)
        try require(selectionVM.selectionMode == .add, "Move mode was not independently remembered")
        let selectionCold = StudioViewModel(toolDefaults: UserDefaults(suiteName: selectionSuite))
        selectionCold.selectDrawingTool(.lasso)
        try require(selectionCold.selectionMode == .subtract && selectionCold.areaSelectionKind == .polygon
            && selectionCold.areaSelectionSmoothing == 7 && selectionCold.selectedElementIDs.isEmpty,
            "Fresh Lasso preferences failed or persisted selection identities")
        selectionCold.resetCurrentDrawingToolPreferences()
        try require(selectionCold.selectionMode == .new && selectionCold.areaSelectionKind == .freehand
            && selectionCold.areaSelectionSmoothing == 3 && selectionCold.selectedElementIDs.isEmpty,
            "Lasso Reset missed exposed controls")
        selectionCold.selectDrawingTool(.move)
        try require(selectionCold.selectionMode == .add, "Lasso Reset erased Move preferences")
        selectionCold.resetCurrentDrawingToolPreferences()
        try require(selectionCold.selectionMode == .new, "Move Reset failed")
        let resetSelectionCold = StudioViewModel(toolDefaults: UserDefaults(suiteName: selectionSuite))
        resetSelectionCold.selectDrawingTool(.lasso)
        try require(resetSelectionCold.selectionMode == .new && resetSelectionCold.areaSelectionKind == .freehand
            && resetSelectionCold.areaSelectionSmoothing == 3, "Selection Reset did not persist")
        try require(selectionVM.document == selectionDocument && !selectionVM.canUndo && !selectionVM.canRedo,
            "Selection preferences changed document/history")
        var legacySelection = StudioDrawingToolPreferences()
        legacySelection.values[DrawingTool.lasso.rawValue] = .init()
        let legacySelectionBytes = try legacySelection.encoded()
        try require(StudioDrawingToolPreferences.decode(legacySelectionBytes).settings(for: .lasso).selectionMode == nil,
            "Legacy version1 selection defaults failed")
        for value in [-1.0, 11, Double.nan, Double.infinity] {
            var invalid = legacySelection; invalid.values[DrawingTool.lasso.rawValue]?.areaSelectionSmoothing = value
            try rejects { _ = try invalid.encoded() }
        }
        var invalidEnums = legacySelection
        invalidEnums.values[DrawingTool.lasso.rawValue]?.selectionMode = .add
        invalidEnums.values[DrawingTool.lasso.rawValue]?.areaSelectionKind = .polygon
        let validEnums = String(decoding: try invalidEnums.encoded(), as: UTF8.self)
        for (old, new) in [("\"add\"", "\"unknown-mode\""), ("\"polygon\"", "\"unknown-kind\"")] {
            let invalid = validEnums.replacingOccurrences(of: old, with: new)
            try require(invalid != validEnums, "Invalid enum fixture was unchanged")
            try rejects { _ = try StudioDrawingToolPreferences.decode(Data(invalid.utf8)) }
        }
        selectionCold.selectDrawingTool(.lasso)
        let selectionBytes = selectionDefaults.data(forKey: StudioViewModel.toolPreferencesKey)
        selectionCold.areaSelectionSmoothing = .nan
        try require(selectionDefaults.data(forKey: StudioViewModel.toolPreferencesKey) == selectionBytes,
            "Invalid selection smoothing poisoned stored settings")
        pass("Move and Lasso independent settings persist reset and validate without storing selected identities")
        print("PASS \(passed) production tool-preference groups")
    }
}
