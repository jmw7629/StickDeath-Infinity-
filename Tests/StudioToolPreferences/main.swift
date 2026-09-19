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

        let persisted = try StudioDrawingToolPreferences.decode(defaults.data(forKey: StudioViewModel.toolPreferencesKey)!)
        let end = persisted.settings(for: .brush).gradientEnd
        try require(end.green > 0.99 && end.red < 0.01 && end.blue < 0.01, "Actual gradient endpoint was not serialized")
        let cold = StudioViewModel(storage: storage, toolDefaults: UserDefaults(suiteName: suite))
        cold.selectDrawingTool(.brush); try require(cold.strokeWidth == 18 && cold.brushFamily == .hatchLeft && cold.strokeOpacity == 0.4, "New production instance lost brush preferences")
        cold.selectDrawingTool(.pen); try require(cold.brushFamily == .dipPen && cold.strokeWidth == 6, "New production instance lost pen preferences")
        cold.selectDrawingTool(.rectangle); try require(cold.shapeFilled && cold.shapeCornerRadius == 23, "New production instance lost shape preferences")
        pass("actual UserDefaults and fresh production view model restore persisted preferences")

        vm.selectDrawingTool(.brush); vm.resetCurrentDrawingToolPreferences()
        try require(vm.strokeWidth == 3 && vm.strokeOpacity == 1 && vm.brushFamily == .round, "Reset failed")
        vm.selectDrawingTool(.pen); try require(vm.strokeWidth == 6 && vm.brushFamily == .dipPen, "Reset changed another tool")
        let afterReset = StudioViewModel(toolDefaults: UserDefaults(suiteName: suite))
        try require(afterReset.strokeWidth == 3 && afterReset.brushFamily == .round, "Reset did not persist")
        try require(vm.document == original && !vm.canUndo, "Reset changed actual document")
        pass("reset affects only the selected tool and is persisted without history")

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
        print("PASS \(passed) production tool-preference groups")
    }
}
