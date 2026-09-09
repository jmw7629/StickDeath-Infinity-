import Foundation

/// A deliberately limited local instruction builder. It is not an AI provider,
/// chat responder, permission grant, or document mutation. The caller must use
/// the actual Studio VM adapter and report its receipt and save state separately.
struct SpatterMotionRecipe: Equatable {
    static let maximumInstructionBytes = 1024
    static let maximumFrames = 24
    struct PercentPoint: Equatable { let x: Double; let y: Double }
    let frameCount: Int
    let colorHex: String
    let start: PercentPoint
    let end: PercentPoint
    let radiusPercent: Double
    let lineWidth: Double

    struct Prepared {
        let request: StudioCommandRequest
        let framesToAdd: Int
        let durationSeconds: Double
        let appendedAfterFrameID: String
        let firstNewFrameAlias: String
    }

    private init(frameCount: Int, colorHex: String, start: PercentPoint, end: PercentPoint,
                 radiusPercent: Double, lineWidth: Double) {
        self.frameCount = frameCount; self.colorHex = colorHex; self.start = start; self.end = end
        self.radiusPercent = radiusPercent; self.lineWidth = lineWidth
    }

    // All captures are bounded by the complete 1 KiB instruction. Anchors and
    // fixed units reject an unsupported suffix instead of executing its prefix.
    private static let syntax = try? NSRegularExpression(pattern:
        #"\A\s*append\s+([^\s]+)\s+frames\s+of\s+(?:a|an)\s+([^\s]+)\s+outlined\s+circle\s+moving\s+from\s*\(\s*([^\s%,()]+)\s*%\s*,\s*([^\s%,()]+)\s*%\s*\)\s+to\s*\(\s*([^\s%,()]+)\s*%\s*,\s*([^\s%,()]+)\s*%\s*\)\s*,\s*radius\s+([^\s%,()]+)\s*%\s*,\s*line\s+width\s+([^\s%,()]+)\s+px\.?\s*\z"#,
        options: [.caseInsensitive])
    private static let namedColors = ["red": "#FF0000", "green": "#00FF00", "blue": "#0000FF",
        "black": "#000000", "white": "#FFFFFF", "yellow": "#FFFF00", "cyan": "#00FFFF",
        "magenta": "#FF00FF", "orange": "#FF8000", "purple": "#800080"]

    /// Supported complete form:
    /// Append 8 frames of a red outlined circle moving from (20%, 50%) to
    /// (80%, 50%), radius 8%, line width 3 px.
    /// Radius is a percentage of the shorter canvas side; coordinates are
    /// percentages of their corresponding side. The project FPS is unchanged.
    static func parse(_ instruction: String) throws -> Self {
        guard instruction.utf8.count <= maximumInstructionBytes else { throw RecipeError.instructionTooLong }
        guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RecipeError.emptyInstruction }
        guard !instruction.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0)
        }), let syntax, let match = syntax.firstMatch(in: instruction,
            range: NSRange(instruction.startIndex..., in: instruction)), match.numberOfRanges == 9 else { throw RecipeError.unsupportedInstruction }
        func capture(_ index: Int) throws -> String {
            guard let range = Range(match.range(at: index), in: instruction) else { throw RecipeError.unsupportedInstruction }
            return String(instruction[range])
        }
        guard let count = Int(try capture(1)), (2...maximumFrames).contains(count) else { throw RecipeError.frameLimit }
        let colorToken = try capture(2), color: String
        if let named = namedColors[colorToken.lowercased()] { color = named }
        else {
            let bytes = Array(colorToken.utf8)
            guard bytes.count == 7, bytes[0] == 35, bytes.dropFirst().allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }) else { throw RecipeError.unsupportedColor }
            color = colorToken.uppercased()
        }
        func number(_ index: Int) throws -> Double {
            guard let value = Double(try capture(index)), value.isFinite else { throw RecipeError.invalidNumber }
            return value
        }
        let start = PercentPoint(x: try number(3), y: try number(4))
        let end = PercentPoint(x: try number(5), y: try number(6))
        let radius = try number(7), width = try number(8)
        guard [start.x, start.y, end.x, end.y].allSatisfy({ (0...100).contains($0) }),
              radius > 0, radius <= 50, (0.1...1024).contains(width) else { throw RecipeError.invalidNumber }
        guard start != end else { throw RecipeError.noMotion }
        return .init(frameCount: count, colorHex: color, start: start, end: end, radiusPercent: radius, lineWidth: width)
    }

    /// Produces a plan, never a success receipt. Preparation may happen before
    /// user edits, so the original project/revision guard must not be rewritten
    /// when this request reaches applyStudioCommands. Request-specific element
    /// IDs make the same prepared request stable and prevent duplicate identities.
    func prepare(in context: StudioCommandContext, requestID: UUID = UUID(),
                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> Prepared {
        try checkCancellation()
        guard (16...4096).contains(context.width), (16...4096).contains(context.height),
              (1...60).contains(context.fps), context.revision >= 0,
              !context.frames.isEmpty, !context.layers.isEmpty,
              Set(context.frames.map(\.id)).count == context.frames.count,
              Set(context.layers.map(\.id)).count == context.layers.count,
              context.frames.allSatisfy({ !$0.id.isEmpty }), context.layers.allSatisfy({ !$0.id.isEmpty }),
              context.frames.contains(where: { $0.id == context.activeFrameID }),
              context.layers.contains(where: { $0.id == context.activeLayerID }),
              context.supportedTools.contains(.circle), let lastFrame = context.frames.last else { throw RecipeError.invalidContext }
        guard context.frames.count <= 1000 - frameCount, context.layers.count < 128 else { throw RecipeError.documentCapacity }
        let canvasWidth = Double(context.width), canvasHeight = Double(context.height)
        let radius = Double(min(context.width, context.height)) * radiusPercent / 100
        let margin = radius + lineWidth / 2
        func center(_ point: PercentPoint) -> PercentPoint {
            .init(x: canvasWidth * point.x / 100, y: canvasHeight * point.y / 100)
        }
        let first = center(start), last = center(end)
        guard radius > 0, first != last else { throw RecipeError.geometryTooSmall }
        func fits(_ point: PercentPoint) -> Bool {
            let fitsX = point.x >= margin && point.x <= canvasWidth - margin
            let fitsY = point.y >= margin && point.y <= canvasHeight - margin
            return fitsX && fitsY
        }
        guard fits(first), fits(last) else { throw RecipeError.geometryOutOfBounds }
        let layerAlias = "motion_layer", firstAlias = "motion_frame_0"
        var commands: [StudioCommand] = [.addLayer(.init(name: "Spatter motion", result: layerAlias))]
        var after: StudioCommandReference = .id(lastFrame.id)
        for index in 0..<frameCount {
            try checkCancellation()
            let t = Double(index) / Double(frameCount - 1)
            let x = first.x + (last.x - first.x) * t, y = first.y + (last.y - first.y) * t
            guard x - radius < x + radius, y - radius < y + radius else { throw RecipeError.geometryTooSmall }
            let alias = "motion_frame_\(index)"
            commands.append(.addFrame(.init(after: after, result: alias)))
            commands.append(.draw(.init(frame: .created(alias), layer: .created(layerAlias), strokes: [
                .init(id: "motion-\(requestID.uuidString)-\(index)", tool: .circle,
                      points: [.init(x: CGFloat(x - radius), y: CGFloat(y - radius)),
                               .init(x: CGFloat(x + radius), y: CGFloat(y + radius))],
                      color: colorHex, width: lineWidth, opacity: 1)
            ])))
            after = .created(alias)
        }
        commands.append(.selectFrame(.created(firstAlias)))
        guard commands.count <= StudioCommandExecutor.maximumCommands else { throw StudioCommandError.limitExceeded }
        try checkCancellation()
        return .init(request: .init(requestID: requestID, projectID: context.projectID,
            expectedRevision: context.revision, action: .apply(commands)), framesToAdd: frameCount,
            durationSeconds: Double(frameCount) / Double(context.fps), appendedAfterFrameID: lastFrame.id,
            firstNewFrameAlias: firstAlias)
    }

    enum RecipeError: LocalizedError, Equatable {
        case emptyInstruction, instructionTooLong, unsupportedInstruction, unsupportedColor
        case frameLimit, invalidNumber, noMotion, geometryOutOfBounds, geometryTooSmall, invalidContext, documentCapacity
        var errorDescription: String? {
            switch self {
            case .emptyInstruction: return "Enter a complete local circle-motion instruction. Nothing changed."
            case .instructionTooLong: return "Local motion instructions are limited to 1,024 UTF-8 bytes. Nothing changed."
            case .unsupportedInstruction: return "This local recipe supports only the complete outlined-circle motion form, with percentages, frame count and line width in px. Additional actions are unavailable. Nothing changed."
            case .unsupportedColor: return "Use red, green, blue, black, white, yellow, cyan, magenta, orange, purple or a six-digit #RRGGBB color. Nothing changed."
            case .frameLimit: return "Choose 2 to 24 new frames as a whole number. Nothing changed."
            case .invalidNumber: return "Use finite coordinates from 0–100%, radius above 0–50%, and line width from 0.1–1,024 px. Nothing changed."
            case .noMotion: return "Choose different starting and ending positions for the motion. Nothing changed."
            case .geometryOutOfBounds: return "The complete outlined circle must fit inside the canvas at both ends. Reduce its size or move the endpoints inward. Nothing changed."
            case .geometryTooSmall: return "The radius or motion is too small to represent in Studio coordinates. Increase it. Nothing changed."
            case .invalidContext: return "Open a supported current Studio project before preparing this motion. Nothing changed."
            case .documentCapacity: return "The project does not have room for the requested new frames and layer. Nothing changed."
            }
        }
    }
}
