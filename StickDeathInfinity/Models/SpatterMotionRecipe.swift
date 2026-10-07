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

/// Explicit local audio instructions only. No provider text, file path or
/// imported metadata can enter this parser without a separate user submission.
struct SpatterAudioInstruction: Equatable {
    let settings: StudioAudioClipSettings
    enum Example: String, CaseIterable, Identifiable {
        case volume, mute, unmute, fades, clear
        var id: String { rawValue }
        var title: String {
            switch self {
            case .volume: return "Set volume"
            case .mute: return "Mute clip"
            case .unmute: return "Unmute clip"
            case .fades: return "Set fades"
            case .clear: return "Clear fades"
            }
        }
        var instruction: String {
            switch self {
            case .volume: return "Set selected audio clip volume to 40%."
            case .mute: return "Mute selected audio clip."
            case .unmute: return "Unmute selected audio clip."
            case .fades: return "Fade selected audio clip in over 0.05 seconds and out over 0.10 seconds."
            case .clear: return "Clear selected audio clip fades."
            }
        }
    }
    enum InstructionError: LocalizedError, Equatable {
        case unsupported, invalidValue, missingClip
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Use one complete audio instruction from the examples. Additional actions are unavailable. Nothing changed."
            case .invalidValue: return "Use a volume from 0–100% or finite nonnegative fade durations that fit the selected clip. Nothing changed."
            case .missingClip: return "Select a playable clip in the Audio workspace, then reopen Spatter. Nothing changed."
            }
        }
    }
    static func isAudioInstruction(_ text: String) -> Bool {
        let first = text.split(whereSeparator: { $0.isWhitespace }).first?.lowercased()
        return ["set", "mute", "unmute", "fade", "clear"].contains(first ?? "")
    }
    private static let patterns: [(String, String)] = [
        ("volume", #"\A\s*set\s+selected\s+audio\s+clip\s+volume\s+to\s+([^\s%]+)\s*%\.?\s*\z"#),
        ("mute", #"\A\s*(mute|unmute)\s+selected\s+audio\s+clip\.?\s*\z"#),
        ("fades", #"\A\s*fade\s+selected\s+audio\s+clip\s+in\s+over\s+([^\s]+)\s+seconds\s+and\s+out\s+over\s+([^\s]+)\s+seconds\.?\s*\z"#),
        ("clear", #"\A\s*clear\s+selected\s+audio\s+clip\s+fades\.?\s*\z"#)
    ]
    static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= SpatterMotionRecipe.maximumInstructionBytes else {
            throw SpatterMotionRecipe.RecipeError.instructionTooLong
        }
        guard !text.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0)
        }) else { throw InstructionError.unsupported }
        for (kind, pattern) in patterns {
            let expression = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }
            func token(_ index: Int) throws -> String {
                guard let range = Range(match.range(at: index), in: text) else { throw InstructionError.unsupported }
                return String(text[range])
            }
            func number(_ index: Int, maximum: Double) throws -> Double {
                let raw = try token(index)
                guard raw.utf8.count <= 32, let value = Double(raw), value.isFinite, value >= 0, value <= maximum else {
                    throw InstructionError.invalidValue
                }
                return value
            }
            switch kind {
            case "volume": return .init(settings: .init(volume: try number(1, maximum: 100) / 100))
            case "mute": return .init(settings: .init(isMuted: try token(1).lowercased() == "mute"))
            case "fades": return .init(settings: .init(fades: .init(fadeIn: try number(1, maximum: 300), fadeOut: try number(2, maximum: 300))))
            case "clear": return .init(settings: .init(fades: .init(fadeIn: 0, fadeOut: 0)))
            default: throw InstructionError.unsupported
            }
        }
        throw InstructionError.unsupported
    }
    func prepare(in context: StudioCommandContext, selectedClipID: String?, requestID: UUID = UUID(),
                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StudioCommandRequest {
        try checkCancellation()
        guard let selectedClipID, let clip = context.editableAudioClips.first(where: { $0.id == selectedClipID }),
              clip.assetID != nil else { throw InstructionError.missingClip }
        _ = try settings.applying(to: clip)
        try checkCancellation()
        return .init(requestID: requestID, projectID: context.projectID, expectedRevision: context.revision,
            action: .apply([.updateAudioClip(.init(clipID: clip.id, settings: settings))]))
    }
}

/// Original procedural stick-figure motion, with explicit bounded syntax. This
/// creates editable line/circle frames, not an AI-generated or publishable movie.
struct SpatterStickFigureRecipe: Equatable {
    enum Action: String, CaseIterable, Identifiable {
        case walking, running, jumping, waving
        var id: String { rawValue }
        var example: String {
            let end = self == .waving ? "25%" : "75%"
            return "Append 20 frames of a black stick figure \(rawValue) from (25%, 80%) to (\(end), 80%), height 35%, line width 3 px."
        }
    }
    struct Point: Equatable { let x: Double; let y: Double }
    let frameCount: Int
    let color: String
    let action: Action
    let start: Point
    let end: Point
    let heightPercent: Double
    let lineWidth: Double
    // Composite briefs use a common neutral pose at both ends of every action.
    // Existing single-action recipes retain their original motion unchanged.
    var neutralTransitions = false
    var neutralFacing: Double? = nil
    enum Failure: LocalizedError {
        case syntax, limits, bounds, context
        var errorDescription: String? {
            switch self {
            case .syntax: return "Use a complete stick figure example: walking, running, jumping or waving, with frame count, start/end percentages, height and line width. Other actions are unavailable. Nothing changed."
            case .limits: return "Choose 8–20 frames, a named or #RRGGBB color, coordinates 0–100%, height 5–70%, and line width 0.5–32 px. Nothing changed."
            case .bounds: return "The complete animated figure must fit inside the canvas in every frame. Reduce height or move the feet-baseline coordinates inward. Nothing changed."
            case .context: return "Open a current Studio project with line/circle support and room for the new frames and layer. Nothing changed."
            }
        }
    }
    static func isStickFigureInstruction(_ text: String) -> Bool {
        text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").contains("stick figure")
    }
    private static let syntax = try? NSRegularExpression(pattern:
        #"\A\s*append\s+(\d+)\s+frames\s+of\s+(?:a|an)\s+([^\s]+)\s+stick\s+figure\s+(walking|running|jumping|waving)\s+from\s*\(\s*([^\s%,()]+)\s*%\s*,\s*([^\s%,()]+)\s*%\s*\)\s+to\s*\(\s*([^\s%,()]+)\s*%\s*,\s*([^\s%,()]+)\s*%\s*\)\s*,\s*height\s+([^\s%,()]+)\s*%\s*,\s*line\s+width\s+([^\s%,()]+)\s+px\.?\s*\z"#, options: [.caseInsensitive])
    static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= SpatterMotionRecipe.maximumInstructionBytes else { throw SpatterMotionRecipe.RecipeError.instructionTooLong }
        guard let syntax, let match = syntax.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.numberOfRanges == 10 else { throw Failure.syntax }
        func token(_ index: Int) -> String { String(text[Range(match.range(at: index), in: text)!]) }
        let named = ["black": "#000000", "white": "#FFFFFF", "red": "#FF0000", "green": "#00FF00", "blue": "#0000FF",
                     "yellow": "#FFFF00", "cyan": "#00FFFF", "magenta": "#FF00FF", "orange": "#FF8000", "purple": "#800080"]
        let color = named[token(2).lowercased()] ?? token(2).uppercased()
        guard let count = Int(token(1)), (8...20).contains(count), let action = Action(rawValue: token(3).lowercased()),
              color.utf8.count == 7, color.first == "#", color.dropFirst().allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let x0 = Double(token(4)), let y0 = Double(token(5)), let x1 = Double(token(6)), let y1 = Double(token(7)),
              let height = Double(token(8)), let width = Double(token(9)),
              [x0, y0, x1, y1, height, width].allSatisfy(\.isFinite),
              [x0, y0, x1, y1].allSatisfy({ (0...100).contains($0) }),
              (5...70).contains(height), (0.5...32).contains(width) else { throw Failure.limits }
        return .init(frameCount: count, color: color, action: action, start: .init(x: x0, y: y0),
                     end: .init(x: x1, y: y1), heightPercent: height, lineWidth: width)
    }
    func prepare(in context: StudioCommandContext, requestID: UUID = UUID(),
                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> SpatterMotionRecipe.Prepared {
        try checkCancellation()
        guard (16...4096).contains(context.width), (16...4096).contains(context.height), (1...60).contains(context.fps),
              context.revision >= 0, context.supportedTools.contains(.line), context.supportedTools.contains(.circle),
              context.frames.count <= 1000 - frameCount, context.layers.count < 128,
              context.frames.contains(where: { $0.id == context.activeFrameID }),
              context.layers.contains(where: { $0.id == context.activeLayerID }),
              let last = context.frames.last else { throw Failure.context }
        let width = Double(context.width), height = Double(context.height)
        let h = Double(min(context.width, context.height)) * heightPercent / 100
        let first = Point(x: start.x * width / 100, y: start.y * height / 100)
        let final = Point(x: end.x * width / 100, y: end.y * height / 100)
        let facing = neutralFacing ?? (final.x < first.x ? -1.0 : 1.0)
        let layer = "stick_layer", firstAlias = "stick_frame_0"
        var commands: [StudioCommand] = [.addLayer(.init(name: "Spatter · " + action.rawValue, result: layer))]
        var after: StudioCommandReference = .id(last.id)
        // Two-bone inverse kinematics keeps limb segment lengths consistent.
        func joint(_ root: Point, _ tip: Point, length: Double, bend: Double) throws -> Point {
            let dx = tip.x - root.x, dy = tip.y - root.y
            let distance = max(0.000001, hypot(dx, dy))
            guard distance <= length * 2 else { throw Failure.bounds }
            let along = distance / 2
            let offset = sqrt(max(0, length * length - along * along))
            return .init(x: root.x + dx * 0.5 - dy / distance * offset * bend,
                         y: root.y + dy * 0.5 + dx / distance * offset * bend)
        }
        for index in 0..<frameCount {
            try checkCancellation()
            let t = Double(index) / Double(frameCount - 1)
            let phase = t * .pi * (action == .running ? 4 : 2)
            let envelope = neutralTransitions ? pow(sin(t * .pi), 2) : 1
            let jump = action == .jumping ? 4 * t * (1 - t) : 0
            let bob = (action == .walking || action == .running) ? cos(phase * 2) * h * 0.012 * envelope : 0
            let x = first.x + (final.x - first.x) * t
            let baseline = first.y + (final.y - first.y) * t - jump * h * 0.35
            func p(_ dx: Double, _ dy: Double) -> Point { .init(x: x + dx * h * facing, y: baseline + dy * h + bob) }
            let hip = p(0, -0.44), shoulder = p(0, -0.72), head = p(0, -0.865), radius = h * 0.095
            var segments: [(Point, Point)] = [(hip, p(0, -0.77))]
            for side in [-1.0, 1.0] {
                let gait = phase + (side < 0 ? .pi : 0)
                let moving = action == .walking || action == .running
                let stride = moving ? sin(gait) * 0.15 * envelope : 0
                let lift = moving ? max(0, cos(gait)) * (action == .running ? 0.16 : 0.10) * envelope : jump * 0.08
                let legRoot = hip
                let foot = p(side * 0.10 + stride, -0.02 - lift)
                let knee = try joint(legRoot, foot, length: h * 0.25, bend: -facing)
                segments += [(legRoot, knee), (knee, foot)]
                let armRoot = shoulder
                let hand: Point
                if action == .waving && side > 0 {
                    hand = neutralTransitions
                        ? p(0.10 + (0.15 + sin(t * .pi * 4) * 0.06) * envelope,
                            -0.43 + (-0.49 + cos(t * .pi * 4) * 0.025) * envelope)
                        : p(0.25 + sin(t * .pi * 4) * 0.06, -0.92 + cos(t * .pi * 4) * 0.025)
                } else if action == .jumping {
                    hand = p(side * (neutralTransitions ? 0.10 + jump * 0.13 : 0.13 + jump * 0.10), -0.43 - jump * 0.42)
                } else {
                    hand = p(side * 0.10 - stride, -0.43 + (moving ? cos(gait) * 0.025 * envelope : 0))
                }
                let elbow = try joint(armRoot, hand, length: h * 0.20, bend: side * facing)
                segments += [(armRoot, elbow), (elbow, hand)]
            }
            let margin = lineWidth / 2
            func fits(_ point: Point) -> Bool {
                point.x.isFinite && point.y.isFinite && point.x >= margin && point.x <= width - margin
                    && point.y >= margin && point.y <= height - margin
            }
            let headStart = Point(x: head.x - radius, y: head.y - radius)
            let headEnd = Point(x: head.x + radius, y: head.y + radius)
            guard fits(headStart), fits(headEnd), segments.allSatisfy({ fits($0.0) && fits($0.1) }) else { throw Failure.bounds }
            var strokes = segments.enumerated().map { part, segment in
                StudioCommandStroke(id: "stick-\(requestID.uuidString)-\(index)-\(part)", tool: .line,
                    points: [.init(x: CGFloat(segment.0.x), y: CGFloat(segment.0.y)), .init(x: CGFloat(segment.1.x), y: CGFloat(segment.1.y))],
                    color: color, width: lineWidth, opacity: 1)
            }
            strokes.append(.init(id: "stick-\(requestID.uuidString)-\(index)-head", tool: .circle,
                points: [.init(x: CGFloat(headStart.x), y: CGFloat(headStart.y)), .init(x: CGFloat(headEnd.x), y: CGFloat(headEnd.y))],
                color: color, width: lineWidth, opacity: 1))
            let alias = "stick_frame_\(index)"
            commands.append(.addFrame(.init(after: after, result: alias)))
            commands.append(.draw(.init(frame: .created(alias), layer: .created(layer), strokes: strokes)))
            after = .created(alias)
        }
        commands.append(.selectFrame(.created(firstAlias)))
        guard commands.count <= StudioCommandExecutor.maximumCommands else { throw StudioCommandError.limitExceeded }
        try checkCancellation()
        return .init(request: .init(requestID: requestID, projectID: context.projectID, expectedRevision: context.revision,
            action: .apply(commands)), framesToAdd: frameCount, durationSeconds: Double(frameCount) / Double(context.fps),
            appendedAfterFrameID: last.id, firstNewFrameAlias: firstAlias)
    }
}

/// A fully consumed, local two-action brief grammar. It does not call a provider
/// or infer unsupported characters, props, soundtracks or publication permission.
struct SpatterSceneBrief: Equatable {
    let color: String
    let actions: [SpatterStickFigureRecipe.Action]
    let movesRight: Bool
    let seconds: Double
    static let example = "A red stick figure walks left to right, then waves; 2 seconds."
    static func isBrief(_ text: String) -> Bool {
        let words = text.lowercased().split(whereSeparator: { $0.isWhitespace })
        return words.first == "a" || words.first == "an"
    }
    enum Failure: LocalizedError {
        case syntax, timing
        var errorDescription: String? {
            switch self {
            case .syntax: return "Use: A red stick figure walks left to right, then waves; 2 seconds. Choose walks, runs, jumps or waves, left to right or right to left, and a named or #RRGGBB color. At least one action must travel. Other clauses are unsupported; nothing changed."
            case .timing: return "Choose 0.5–10 seconds covering at least 16 project-FPS ticks. The local brief uses 16–20 editable poses with frame holds; timing rounds to the nearest project tick. Nothing changed."
            }
        }
    }
    private static let syntax = try? NSRegularExpression(pattern:
        #"\A\s*(?:a|an)\s+([^\s]+)\s+stick\s+figure\s+(walks|runs|jumps|waves)\s+(left\s+to\s+right|right\s+to\s+left)\s*,\s*then\s+(walks|runs|jumps|waves)\s*;\s*([0-9]+(?:\.[0-9]+)?)\s+seconds?\.?\s*\z"#, options: [.caseInsensitive])
    static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= SpatterMotionRecipe.maximumInstructionBytes else { throw SpatterMotionRecipe.RecipeError.instructionTooLong }
        guard let syntax, let match = syntax.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { throw Failure.syntax }
        func token(_ index: Int) -> String { String(text[Range(match.range(at: index), in: text)!]).lowercased() }
        let verbs: [String: SpatterStickFigureRecipe.Action] = ["walks": .walking, "runs": .running, "jumps": .jumping, "waves": .waving]
        guard let first = verbs[token(2)], let second = verbs[token(4)], first != .waving || second != .waving else { throw Failure.syntax }
        guard let seconds = Double(token(5)), seconds.isFinite, (0.5...10).contains(seconds) else { throw Failure.timing }
        // Reuse the established color validation without maintaining another list.
        let checked = try SpatterStickFigureRecipe.parse("Append 8 frames of a \(token(1)) stick figure walking from (25%, 80%) to (75%, 80%), height 35%, line width 3 px.")
        return .init(color: checked.color, actions: [first, second], movesRight: token(3).hasPrefix("left"), seconds: seconds)
    }
    func prepare(in context: StudioCommandContext, requestID: UUID = UUID(),
                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> SpatterMotionRecipe.Prepared {
        try checkCancellation()
        guard (1...60).contains(context.fps), seconds.isFinite, (0.5...10).contains(seconds),
              actions.count == 2, actions.contains(where: { $0 != .waving }) else { throw Failure.timing }
        let ticks = Int((seconds * Double(context.fps)).rounded())
        guard ticks >= 16 else { throw Failure.timing }
        let count = min(20, ticks), firstCount = count / 2
        guard context.frames.count <= 1000 - count, context.layers.count < 128, let last = context.frames.last else {
            throw SpatterStickFigureRecipe.Failure.context
        }
        let layer = "brief_layer", firstAlias = "brief_frame_0"
        var commands: [StudioCommand] = [.addLayer(.init(name: "Spatter · two-action brief", result: layer))]
        var after = StudioCommandReference.id(last.id), offset = 0
        var x = movesRight ? 25.0 : 75.0
        let movingCount = actions.filter { $0 != .waving }.count
        let distance = (movesRight ? 50.0 : -50.0) / Double(movingCount)
        for (index, action) in actions.enumerated() {
            try checkCancellation()
            let end = action == .waving ? x : x + distance
            var recipe = SpatterStickFigureRecipe(frameCount: index == 0 ? firstCount : count - firstCount,
                color: color, action: action, start: .init(x: x, y: 80), end: .init(x: end, y: 80), heightPercent: 35, lineWidth: 3)
            recipe.neutralTransitions = true; recipe.neutralFacing = movesRight ? 1 : -1
            // Facing is tied to the brief even for stationary waving.
            let plan = try recipe.prepare(in: context, requestID: requestID, checkCancellation: checkCancellation)
            guard case .apply(let generated) = plan.request.action else { throw Failure.syntax }
            for command in generated {
                guard case .draw(let drawing) = command else { continue }
                let alias = "brief_frame_\(offset)"
                let strokes = drawing.strokes.enumerated().map { part, stroke in
                    StudioCommandStroke(id: "brief-\(requestID.uuidString)-\(offset)-\(part)", tool: stroke.tool,
                        points: stroke.points, color: stroke.color, width: stroke.width, opacity: stroke.opacity)
                }
                commands.append(.addFrame(.init(after: after, result: alias)))
                commands.append(.draw(.init(frame: .created(alias), layer: .created(layer), strokes: strokes)))
                let hold = ticks / count + (offset < ticks % count ? 1 : 0)
                if hold > 1 { commands.append(.setFrameHold(.init(frame: .created(alias), ticks: hold))) }
                after = .created(alias); offset += 1
            }
            x = end
        }
        commands.append(.selectFrame(.created(firstAlias)))
        guard offset == count, commands.count <= StudioCommandExecutor.maximumCommands else { throw StudioCommandError.limitExceeded }
        try checkCancellation()
        return .init(request: .init(requestID: requestID, projectID: context.projectID, expectedRevision: context.revision,
            action: .apply(commands)), framesToAdd: count, durationSeconds: Double(ticks) / Double(context.fps),
            appendedAfterFrameID: last.id, firstNewFrameAlias: firstAlias)
    }
}
