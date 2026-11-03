import Foundation

/// An explicit native Pencil/Pen/Marker/Crayon gesture (#204). The tool tag and
/// captured brush descriptor both survive the canonical Draw command. No live
/// tool preference, pressure, tilt, mirror or ruler state is read or changed.
struct SpatterFreehandInstruction: Equatable {
    static let tools: [DrawingTool] = [.pencil, .pen, .marker, .crayon]
    static let maximumPoints = 32
    let tool: DrawingTool
    let points: [SpatterMotionRecipe.PercentPoint]
    let color: String
    let size: Double
    let opacity: Double
    let family: StudioBrushFamily
    let smoothing: Double
    let tipAngle: Double?
    let texture: Double?
    let grain: Double?

    static func example(_ tool: DrawingTool) -> String {
        let path = "along (10%, 20%), (50%, 70%), (90%, 20%) in #000000"
        switch tool {
        case .pen: return "Draw a pen stroke \(path), size 3 px, opacity 100%, family rough pen, smoothing 3, texture 50%."
        case .marker: return "Draw a marker stroke \(path), size 12 px, opacity 75%, family calligraphy, smoothing 3, tip 45 degrees."
        case .crayon: return "Draw a crayon stroke \(path), size 8 px, opacity 90%, family grain, smoothing 1, texture 50%, grain 30%."
        default: return "Draw a pencil stroke \(path), size 2 px, opacity 100%, family round, smoothing 2."
        }
    }
    static let help = "Use a complete Pencil/Pen/Marker/Crayon example: 2–32 distinct adjacent canvas-percent points, #RRGGBB, size 1–50 px, opacity greater than 0 and at most 100%, family and smoothing 0–10. Round takes no extra settings; rough pen requires texture 0–100%; calligraphy requires tip 0–179.9999 degrees; grain requires texture and grain 0–100%. Pressure, tilt, mirror and ruler are off; other families/settings are unavailable here. Nothing changed."
    enum Failure: LocalizedError {
        case syntax, geometry, layer
        var errorDescription: String? {
            switch self {
            case .syntax: return SpatterFreehandInstruction.help
            case .geometry: return "The native freehand path needs 2–32 finite points within this canvas, without adjacent duplicates. Nothing changed."
            case .layer: return "Select an existing frame and a visible positive-opacity layer with Free or Alpha lock before drawing native freehand. The requested tool and brush family must be supported. Nothing changed."
            }
        }
    }
    var summary: String {
        func n(_ value: Double) -> String { String(format: "%.6g", value) }
        var settings = "\(tool.rawValue) stroke along " + points.map { "(\(n($0.x))%, \(n($0.y))%)" }.joined(separator: ", ")
        settings += " in \(color), size \(n(size)) px, opacity \(n(opacity * 100))%, family \(SpatterBrushStrokeInstruction.name(family)), smoothing \(n(smoothing))"
        if let tipAngle { settings += ", tip \(n(tipAngle)) degrees" }
        if let texture { settings += ", texture \(n(texture * 100))%" }
        if let grain { settings += ", grain \(n(grain * 100))%" }
        return settings
    }
    static func isInstruction(_ text: String) -> Bool {
        text.range(of: #"\A\s*draw\s+(?:a\s+)?(?:pencil|pen|marker|crayon)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
    static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= SpatterMotionRecipe.maximumInstructionBytes else { throw SpatterMotionRecipe.RecipeError.instructionTooLong }
        guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.syntax }
        let n = #"([0-9]{1,3}(?:\.[0-9]{1,4})?)"#
        let point = #"\(\s*[0-9]{1,3}(?:\.[0-9]{1,4})?\s*%\s*,\s*[0-9]{1,3}(?:\.[0-9]{1,4})?\s*%\s*\)"#
        let path = "(" + point + #"(?:\s*,\s*"# + point + #"){1,31})"#
        let pattern = #"\A\s*draw\s+a\s+(pencil|pen|marker|crayon)\s+stroke\s+along\s*"# + path
            + #"\s+in\s+(#[0-9a-f]{6})\s*,\s*size\s+"# + n + #"\s+px\s*,\s*opacity\s+"# + n
            + #"\s*%\s*,\s*family\s+(round|rough\s+pen|calligraphy|grain)\s*,\s*smoothing\s+"# + n
            + #"(?:\s*,\s*tip\s+"# + n + #"\s+degrees)?(?:\s*,\s*texture\s+"# + n + #"\s*%)?(?:\s*,\s*grain\s+"# + n + #"\s*%)?\s*\.\s*\z"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { throw Failure.syntax }
        func token(_ index: Int) -> String? { Range(match.range(at: index), in: text).map { String(text[$0]) } }
        func number(_ index: Int, _ bounds: ClosedRange<Double>) throws -> Double {
            guard let raw = token(index), let value = Double(raw), value.isFinite, bounds.contains(value) else { throw Failure.syntax }
            return value
        }
        guard let rawTool = token(1), let tool = DrawingTool(rawValue: rawTool.lowercased()), tools.contains(tool),
              let pathText = token(2), let color = token(3), let rawFamily = token(6) else { throw Failure.syntax }
        let familyName = rawFamily.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard let family = SpatterBrushStrokeInstruction.familyNames.first(where: { $0.0 == familyName })?.1 else { throw Failure.syntax }
        let pointRegex = try NSRegularExpression(pattern: #"\(\s*([0-9]{1,3}(?:\.[0-9]{1,4})?)\s*%\s*,\s*([0-9]{1,3}(?:\.[0-9]{1,4})?)\s*%\s*\)"#)
        let points: [SpatterMotionRecipe.PercentPoint] = try pointRegex.matches(in: pathText, range: NSRange(pathText.startIndex..., in: pathText)).map { point in
            guard let xr = Range(point.range(at: 1), in: pathText), let yr = Range(point.range(at: 2), in: pathText),
                  let x = Double(pathText[xr]), let y = Double(pathText[yr]), x.isFinite, y.isFinite,
                  (0...100).contains(x), (0...100).contains(y) else { throw Failure.geometry }
            return .init(x: x, y: y)
        }
        let result = Self(tool: tool, points: points, color: color.uppercased(), size: try number(4, 1...50),
            opacity: try number(5, 0...100) / 100, family: family, smoothing: try number(7, 0...10),
            tipAngle: try token(8).map { _ in try number(8, 0...179.9999) },
            texture: try token(9).map { _ in try number(9, 0...100) / 100 },
            grain: try token(10).map { _ in try number(10, 0...100) / 100 })
        try result.validate()
        return result
    }
    private func validate() throws {
        guard Self.tools.contains(tool), (2...Self.maximumPoints).contains(points.count),
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...100).contains($0.x) && (0...100).contains($0.y) }),
              zip(points, points.dropFirst()).allSatisfy({ $0 != $1 }) else { throw Failure.geometry }
        guard size.isFinite, (1...50).contains(size), opacity.isFinite, opacity > 0, opacity <= 1,
              smoothing.isFinite, (0...10).contains(smoothing), color.range(of: #"\A#[0-9A-Fa-f]{6}\z"#, options: .regularExpression) != nil else { throw Failure.syntax }
        switch family {
        case .round: guard tipAngle == nil, texture == nil, grain == nil else { throw Failure.syntax }
        case .roughPen: guard tipAngle == nil, texture != nil, grain == nil else { throw Failure.syntax }
        case .calligraphy: guard tipAngle != nil, texture == nil, grain == nil else { throw Failure.syntax }
        case .grain: guard tipAngle == nil, texture != nil, grain != nil else { throw Failure.syntax }
        default: throw Failure.syntax
        }
        guard tipAngle.map({ $0.isFinite && (0..<180).contains($0) }) ?? true,
              texture.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
              grain.map({ $0.isFinite && (0...1).contains($0) }) ?? true else { throw Failure.syntax }
    }
    func prepare(in context: StudioCommandContext, requestID: UUID = UUID(),
                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StudioCommandRequest {
        try checkCancellation(); try validate()
        guard context.frames.contains(where: { $0.id == context.activeFrameID }), context.supportedTools.contains(tool),
              context.supportedBrushFamilies.contains(family),
              let layer = context.layers.first(where: { $0.id == context.activeLayerID }), layer.visible, layer.opacity > 0,
              !layer.isFullyLocked, layer.lockMode == "free" || layer.lockMode == "alpha" else { throw Failure.layer }
        guard (16...4096).contains(context.width), (16...4096).contains(context.height) else { throw Failure.geometry }
        let id = "freehand-\(requestID.uuidString)"
        // Match the manual touch factory and brush engine, including its seed
        // derivation. Explicit settings replace no remembered per-tool defaults.
        var brush = StudioBrushDescriptor(family: family, seed: StudioBrushRenderer.seed(for: id), smoothing: smoothing, pressureEnabled: false)
        if let tipAngle { brush.tipAngleDegrees = tipAngle }
        if let texture { brush.texture = texture }
        if let grain { brush.grain = grain }
        _ = try brush.settings(width: size, opacity: opacity)
        let dimensions = CGSize(width: context.width, height: context.height)
        let began = Date(timeIntervalSince1970: 0)
        var capture = StudioStrokeInput(id: id, frameID: context.activeFrameID, layerID: context.activeLayerID,
            tool: tool, color: color, width: size, opacity: opacity, brush: brush,
            documentSize: dimensions, viewportSize: dimensions, startedAt: began)
        for (index, point) in points.enumerated() {
            try checkCancellation()
            try capture.append(location: .init(x: point.x * Double(context.width) / 100, y: point.y * Double(context.height) / 100),
                time: began.addingTimeInterval(Double(index) / 60))
        }
        capture.finishEstimatedUpdates()
        let element = capture.element
        try checkCancellation()
        return .init(requestID: requestID, projectID: context.projectID, expectedRevision: context.revision,
            action: .apply([.draw(.init(frame: .id(context.activeFrameID), layer: .id(context.activeLayerID), strokes: [
                .init(id: element.id, tool: element.tool, points: element.points, color: element.color,
                    width: Double(element.width), opacity: element.opacity, brush: element.brush)]))]))
    }
}
