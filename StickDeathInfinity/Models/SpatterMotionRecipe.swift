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

/// Explicit active-layer styling; imported text never executes this instruction.
struct SpatterFrameReverseInstruction: Equatable {
    let frames: ClosedRange<Int>
    static let example = "Reverse frames 1 through 12."
    static func isInstruction(_ text: String) -> Bool {
        let words = Set(text.lowercased().split { !$0.isLetter }.map(String.init))
        return words.contains("reverse") && words.contains("frames")
    }
    enum Failure: LocalizedError {
        case unsupported
        var errorDescription: String? { "Use Reverse frames 1 through 12. Choose 2–96 existing consecutive frames and stop playback. Nothing changed." }
    }
    static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= SpatterMotionRecipe.maximumInstructionBytes,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.unsupported }
        let regex = try NSRegularExpression(pattern: #"\A\s*reverse\s+frames\s+([1-9][0-9]{0,3})\s+through\s+([1-9][0-9]{0,3})\.\s*\z"#, options: [.caseInsensitive])
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let a = Range(match.range(at: 1), in: text), let b = Range(match.range(at: 2), in: text),
              let first = Int(text[a]), let last = Int(text[b]), first < last, last-first < 96 else { throw Failure.unsupported }
        return .init(frames: first...last)
    }
    func prepare(in context: StudioCommandContext, requestID: UUID = UUID(),
                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StudioCommandRequest {
        try checkCancellation()
        guard frames.lowerBound >= 1, frames.upperBound <= context.frames.count,
              (1...95).contains(frames.upperBound-frames.lowerBound) else { throw Failure.unsupported }
        let ids = frames.map { context.frames[$0-1].id }
        return .init(requestID: requestID, projectID: context.projectID, expectedRevision: context.revision,
            action: .apply([.reverseFrames(.init(frameIDs: ids))]))
    }
}

struct SpatterFrameDuplicateRangeInstruction: Equatable {
    let frames: ClosedRange<Int>
    static let example = "Duplicate frames 1 through 12."
    static func isInstruction(_ text: String) -> Bool {
        let words = Set(text.lowercased().split { !$0.isLetter }.map(String.init))
        return words.contains("duplicate") && words.contains("frames")
    }
    enum Failure: LocalizedError {
        case unsupported
        var errorDescription: String? { "Use Duplicate frames 1 through 12. Choose 1–96 existing consecutive frames and stop playback. Nothing changed." }
    }
    static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= SpatterMotionRecipe.maximumInstructionBytes,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.unsupported }
        let regex = try NSRegularExpression(pattern: #"\A\s*duplicate\s+frames\s+([1-9][0-9]{0,3})\s+through\s+([1-9][0-9]{0,3})\.\s*\z"#, options: [.caseInsensitive])
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let a = Range(match.range(at: 1), in: text), let b = Range(match.range(at: 2), in: text),
              let first = Int(text[a]), let last = Int(text[b]), first <= last, last-first < 96 else { throw Failure.unsupported }
        return .init(frames: first...last)
    }
    func prepare(in context: StudioCommandContext, requestID: UUID = UUID(),
                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StudioCommandRequest {
        try checkCancellation()
        guard frames.lowerBound >= 1, frames.upperBound <= context.frames.count,
              context.frames.count + frames.count <= 1000,
              (0...95).contains(frames.upperBound-frames.lowerBound) else { throw Failure.unsupported }
        let ids = frames.map { context.frames[$0-1].id }
        return .init(requestID: requestID, projectID: context.projectID, expectedRevision: context.revision,
            action: .apply([.duplicateFrameRange(.init(frameIDs: ids))]))
    }
}

struct SpatterFrameExposureInstruction: Equatable {
    let ticks: Int
    var frames: ClosedRange<Int>? = nil
    static let rangeExample = "Set frames 1 through 12 exposure to 2 ticks."
    static let example = "Set selected frame exposure to 12 ticks."
    static func isInstruction(_ text: String) -> Bool {
        let words = Set(text.lowercased().split { !$0.isLetter }.map(String.init))
        return (words.contains("frame") || words.contains("frames")) && words.contains("exposure")
    }
    enum Failure: LocalizedError {
        case unsupported, invalidContext
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Use Set selected frame exposure to 12 ticks. or Set frames 1 through 12 exposure to 2 ticks. Use 1–600 ticks and at most 96 existing frames. Nothing changed."
            case .invalidContext: return "Select an existing frame before changing its exposure. Nothing changed."
            }
        }
    }
    static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= SpatterMotionRecipe.maximumInstructionBytes else { throw SpatterMotionRecipe.RecipeError.instructionTooLong }
        guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.unsupported }
        let rangePattern = try NSRegularExpression(pattern: #"\A\s*set\s+frames\s+([1-9][0-9]{0,3})\s+through\s+([1-9][0-9]{0,3})\s+exposure\s+to\s+([1-9][0-9]{0,2})\s+ticks\.\s*\z"#, options: [.caseInsensitive])
        if let match = rangePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            func number(_ group: Int) -> Int? { Range(match.range(at: group), in: text).flatMap { Int(text[$0]) } }
            guard let first = number(1), let last = number(2), let ticks = number(3),
                  first <= last, last <= 1000, last - first < 96, (1...600).contains(ticks) else { throw Failure.unsupported }
            return .init(ticks: ticks, frames: first...last)
        }
        let regex = try NSRegularExpression(pattern: #"\A\s*set\s+selected\s+frame\s+exposure\s+to\s+([1-9][0-9]{0,2})\s+ticks\.\s*\z"#, options: [.caseInsensitive])
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text), let ticks = Int(text[range]), (1...600).contains(ticks)
        else { throw Failure.unsupported }
        return .init(ticks: ticks)
    }
    func prepare(in context: StudioCommandContext, requestID: UUID = UUID(),
                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StudioCommandRequest {
        try checkCancellation()
        guard (1...600).contains(ticks) else { throw Failure.unsupported }
        guard context.frames.contains(where: { $0.id == context.activeFrameID }) else { throw Failure.invalidContext }
        if let frames {
            guard frames.lowerBound >= 1, frames.upperBound <= context.frames.count,
                  frames.upperBound - frames.lowerBound < 96 else { throw Failure.invalidContext }
            var commands: [StudioCommand] = []
            for number in frames {
                try checkCancellation()
                commands.append(.setFrameHold(.init(frame: .id(context.frames[number - 1].id), ticks: ticks)))
            }
            return .init(requestID: requestID, projectID: context.projectID, expectedRevision: context.revision, action: .apply(commands))
        }
        try checkCancellation()
        return .init(requestID: requestID, projectID: context.projectID, expectedRevision: context.revision,
            action: .apply([.setFrameHold(.init(frame: .id(context.activeFrameID), ticks: ticks))]))
    }
}

struct SpatterLayerGlowInstruction: Equatable {
    let color: String?
    let radius: Double?
    let strength: Double?
    static let example = "Set active layer glow to #00FF00 with radius 12 px and strength 75%."
    static let disableExample = "Disable active layer glow."
    static func isInstruction(_ text: String) -> Bool {
        let words = Set(text.lowercased().split { !$0.isLetter }.map(String.init))
        return words.contains("layer") && words.contains("glow")
    }
    enum Failure: LocalizedError {
        case unsupported, invalidContext
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Use one complete active-layer glow example with #RRGGBB color, radius 0–128 px and strength 0–100%. Nothing changed."
            case .invalidContext: return "Select an existing Studio layer before changing its glow. Nothing changed."
            }
        }
    }
    static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= SpatterMotionRecipe.maximumInstructionBytes else { throw SpatterMotionRecipe.RecipeError.instructionTooLong }
        let range = NSRange(text.startIndex..., in: text)
        if try NSRegularExpression(pattern: #"\A\s*disable\s+active\s+layer\s+glow\.?\s*\z"#, options: [.caseInsensitive]).firstMatch(in: text, range: range) != nil {
            return .init(color: nil, radius: nil, strength: nil)
        }
        let regex = try NSRegularExpression(pattern: #"\A\s*set\s+active\s+layer\s+glow\s+to\s+(#[0-9a-f]{6})\s+with\s+radius\s+((?:0|[1-9][0-9]*)(?:\.[0-9]+)?)\s+px\s+and\s+strength\s+((?:0|[1-9][0-9]*)(?:\.[0-9]+)?)\s*%\.?\s*\z"#, options: [.caseInsensitive])
        guard let match = regex.firstMatch(in: text, range: range),
              let c = Range(match.range(at: 1), in: text), let r = Range(match.range(at: 2), in: text),
              let s = Range(match.range(at: 3), in: text), let radius = Double(text[r]), let percent = Double(text[s]),
              radius.isFinite, (0...128).contains(radius), percent.isFinite, (0...100).contains(percent)
        else { throw Failure.unsupported }
        return .init(color: String(text[c]).uppercased(), radius: radius, strength: percent / 100)
    }
    func prepare(in context: StudioCommandContext, requestID: UUID = UUID(),
                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StudioCommandRequest {
        try checkCancellation()
        guard context.layers.contains(where: { $0.id == context.activeLayerID }) else { throw Failure.invalidContext }
        var settings = StudioCommandLayerSettings()
        if let color, let radius, let strength {
            guard CanvasLayer.isValidNewGlowColor(color), radius.isFinite, (0...128).contains(radius),
                  strength.isFinite, (0...1).contains(strength) else { throw Failure.unsupported }
            settings.glowEnabled = true; settings.glowColor = color; settings.glowRadius = radius; settings.glowStrength = strength
        } else {
            guard color == nil && radius == nil && strength == nil else { throw Failure.unsupported }
            settings.glowEnabled = false
        }
        try checkCancellation()
        return .init(requestID: requestID, projectID: context.projectID, expectedRevision: context.revision,
            action: .apply([.updateLayer(.init(layer: .id(context.activeLayerID), settings: settings))]))
    }
}

/// A project title is data; quoted instruction-like text never becomes another action.
struct SpatterProjectRenameInstruction: Equatable {
    let name: String
    static let example = "Rename project to \"Sunset\"."
    static func isInstruction(_ text: String) -> Bool {
        text.split(whereSeparator: { $0.isWhitespace }).first?.lowercased() == "rename"
    }
    enum Failure: LocalizedError {
        case unsupported
        var errorDescription: String? { "Use Rename project to \"Sunset\". with one quoted name. Nothing changed." }
    }
    static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= SpatterMotionRecipe.maximumInstructionBytes else { throw SpatterMotionRecipe.RecipeError.instructionTooLong }
        let expression = try NSRegularExpression(pattern: #"\A\s*rename\s+project\s+to\s+"([^"\r\n]*)"\.?\s*\z"#, options: [.caseInsensitive])
        guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { throw Failure.unsupported }
        return .init(name: try StudioDocument.validatedProjectName(String(text[range])))
    }
    func prepare(in context: StudioCommandContext, requestID: UUID = UUID(),
                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StudioCommandRequest {
        try checkCancellation()
        let title = try StudioDocument.validatedProjectName(name)
        try checkCancellation()
        return .init(requestID: requestID, projectID: context.projectID, expectedRevision: context.revision,
            action: .apply([.renameProject(.init(name: title))]))
    }
}

/// Explicit local audio instructions only. No provider text, file path or
/// imported metadata can enter this parser without a separate user submission.
struct SpatterAudioInstruction: Equatable {
    let settings: StudioAudioClipSettings
    let duplicates: Bool
    let additionalCopies: Int
    let splitTime: Double?
    let deletes: Bool
    init(settings: StudioAudioClipSettings, duplicates: Bool = false, splitTime: Double? = nil, deletes: Bool = false, additionalCopies: Int = 1) {
        self.settings = settings; self.duplicates = duplicates; self.additionalCopies = additionalCopies; self.splitTime = splitTime; self.deletes = deletes
    }
    enum Example: String, CaseIterable, Identifiable {
        case volume, mute, unmute, fades, clear, placement, trim, duplicate, repetition, split, delete
        var id: String { rawValue }
        var title: String {
            switch self {
            case .split: return "Split clip"
            case .delete: return "Delete selected clip"
            case .repetition: return "Repeat clip"
            case .duplicate: return "Duplicate clip"
            case .trim: return "Trim clip"
            case .placement: return "Move clip"
            case .volume: return "Set volume"
            case .mute: return "Mute clip"
            case .unmute: return "Unmute clip"
            case .fades: return "Set fades"
            case .clear: return "Clear fades"
            }
        }
        var instruction: String {
            switch self {
            case .split: return "Split selected audio clip at 0.5 timeline seconds."
            case .delete: return "Delete selected audio clip."
            case .repetition: return "Repeat selected audio clip with 4 additional copies."
            case .duplicate: return "Duplicate selected audio clip."
            case .trim: return "Trim selected audio clip from source 0.10 seconds for 0.50 seconds."
            case .placement: return "Move selected audio clip to 1.25 seconds on track 2."
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
            case .invalidValue: return "Use volume 0–100%, fades within the clip, start 0–1,000 seconds on track 1–4, a source trim containing playable audio, or 1–32 additional copies. Nothing changed."
            case .missingClip: return "Select a playable clip in the Audio workspace, then reopen Spatter. Nothing changed."
            }
        }
    }
    static func isAudioInstruction(_ text: String) -> Bool {
        let first = text.split(whereSeparator: { $0.isWhitespace }).first?.lowercased()
        return ["set", "mute", "unmute", "fade", "clear", "move", "trim", "duplicate", "repeat", "split", "delete"].contains(first ?? "")
    }
    private static let patterns: [(String, String)] = [
        ("repeat", #"\A\s*repeat\s+selected\s+audio\s+clip\s+with\s+([1-9][0-9]?)\s+additional\s+copies\.?\s*\z"#),
        ("split", #"\A\s*split\s+selected\s+audio\s+clip\s+at\s+([^\s]+)\s+timeline\s+seconds?\.?\s*\z"#),
        ("delete", #"\A\s*delete\s+selected\s+audio\s+clip\.?\s*\z"#),
        ("duplicate", #"\A\s*duplicate\s+selected\s+audio\s+clip\.?\s*\z"#),
        ("trim", #"\A\s*trim\s+selected\s+audio\s+clip\s+from\s+source\s+([^\s]+)\s+seconds?\s+for\s+([^\s]+)\s+seconds?\.?\s*\z"#),
        ("placement", #"\A\s*move\s+selected\s+audio\s+clip\s+to\s+([^\s]+)\s+seconds?\s+on\s+track\s+([0-9]+)\.?\s*\z"#),
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
            case "split": return .init(settings: .init(), splitTime: try number(1, maximum: 1300))
            case "delete": return .init(settings: .init(), deletes: true)
            case "repeat":
                guard let count = Int(try token(1)), (1...32).contains(count) else { throw InstructionError.invalidValue }
                return .init(settings: .init(), duplicates: true, additionalCopies: count)
            case "duplicate": return .init(settings: .init(), duplicates: true)
            case "trim":
                let offset = try number(1, maximum: 300), duration = try number(2, maximum: 300)
                guard duration >= 1 / 48_000.0 else { throw InstructionError.invalidValue }
                return .init(settings: .init(trim: .init(sourceOffset: offset, duration: duration)))
            case "placement":
                let start = try number(1, maximum: 1000), rawTrack = try token(2)
                guard rawTrack.utf8.count <= 2, let track = Int(rawTrack), (1...4).contains(track) else { throw InstructionError.invalidValue }
                return .init(settings: .init(placement: .init(startTime: start, track: track)))
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
        if let splitTime {
            _ = try clip.splitTiming(at: splitTime)
            try checkCancellation()
            return .init(requestID: requestID, projectID: context.projectID, expectedRevision: context.revision,
                action: .apply([.splitAudioClip(.init(clipID: clip.id, seconds: splitTime, newClipID: UUID().uuidString))]))
        }
        if deletes {
            try checkCancellation()
            return .init(requestID: requestID, projectID: context.projectID, expectedRevision: context.revision,
                action: .apply([.deleteAudioClip(.init(clipID: clip.id))]))
        }
        if duplicates {
            guard (1...32).contains(additionalCopies) else { throw InstructionError.invalidValue }
            var commands: [StudioCommand] = []
            var source = clip.id
            for _ in 0..<additionalCopies {
                try checkCancellation()
                let next = UUID().uuidString
                commands.append(.duplicateAudioClip(.init(clipID: source, newClipID: next)))
                source = next
            }
            return .init(requestID: requestID, projectID: context.projectID, expectedRevision: context.revision,
                action: .apply(commands))
        }
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

/// Two locally generated actors, sampled at every project tick. Never stretch a
/// handful of poses with holds to satisfy a longer requested duration.
struct SpatterTwoActorBrief: Equatable {
    struct Actor: Equatable { let color: String; let action: SpatterStickFigureRecipe.Action; let movesRight: Bool }
    let actors: [Actor]
    let seconds: Double
    static let example = "Two stick figures: red walks left to right; blue waves right to left; 2 seconds."
    static func isBrief(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("two ") }
    enum Failure: LocalizedError {
        case syntax, timing
        var errorDescription: String? {
            switch self {
            case .syntax: return "Use the complete two-figure example with a color, walks/runs/jumps/waves and direction for each actor. Other actions, props, audio or extra clauses are unavailable. Nothing changed."
            case .timing: return "Two-figure motion needs 12–60 project FPS and 8–24 distinct frames, one pose per tick. At 12 FPS choose up to 2 seconds; at 24 FPS up to 1 second. Longer motion is unavailable; no poses were stretched."
            }
        }
    }
    private static let syntax = try? NSRegularExpression(pattern:
        #"\A\s*two\s+stick\s+figures:\s*([^\s]+)\s+(walks|runs|jumps|waves)\s+(left\s+to\s+right|right\s+to\s+left)\s*;\s*([^\s]+)\s+(walks|runs|jumps|waves)\s+(left\s+to\s+right|right\s+to\s+left)\s*;\s*([0-9]+(?:\.[0-9]+)?)\s+seconds?\.?\s*\z"#, options: [.caseInsensitive])
    static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= SpatterMotionRecipe.maximumInstructionBytes else { throw SpatterMotionRecipe.RecipeError.instructionTooLong }
        guard let syntax, let match = syntax.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { throw Failure.syntax }
        func token(_ n: Int) -> String { String(text[Range(match.range(at: n), in: text)!]).lowercased() }
        let verbs: [String: SpatterStickFigureRecipe.Action] = ["walks": .walking, "runs": .running, "jumps": .jumping, "waves": .waving]
        var actors: [Actor] = []
        for index in [1, 4] {
            let color = try SpatterStickFigureRecipe.parse("Append 8 frames of a \(token(index)) stick figure walking from (25%, 80%) to (75%, 80%), height 35%, line width 3 px.").color
            guard let action = verbs[token(index + 1)] else { throw Failure.syntax }
            actors.append(.init(color: color, action: action, movesRight: token(index + 2).hasPrefix("left")))
        }
        guard let seconds = Double(token(7)), seconds.isFinite, seconds > 0, seconds <= 2 else { throw Failure.timing }
        return .init(actors: actors, seconds: seconds)
    }
    func prepare(in context: StudioCommandContext, requestID: UUID = UUID(),
                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> SpatterMotionRecipe.Prepared {
        try checkCancellation()
        guard actors.count == 2, (12...60).contains(context.fps), seconds.isFinite, seconds > 0, seconds <= 2 else { throw Failure.timing }
        let count = Int((seconds * Double(context.fps)).rounded())
        guard (8...24).contains(count) else { throw Failure.timing }
        guard context.layers.count <= 126, context.frames.count <= 1000 - count, let last = context.frames.last else { throw SpatterStickFigureRecipe.Failure.context }
        var poses: [[[StudioCommandStroke]]] = []
        for (index, actor) in actors.enumerated() {
            try checkCancellation()
            let low = index == 0 ? 15.0 : 60.0, high = index == 0 ? 40.0 : 85.0
            let start = actor.movesRight ? low : high
            let end = actor.action == .waving ? start : (actor.movesRight ? high : low)
            var recipe = SpatterStickFigureRecipe(frameCount: count, color: actor.color, action: actor.action,
                start: .init(x: start, y: 80), end: .init(x: end, y: 80), heightPercent: 28, lineWidth: 3)
            recipe.neutralFacing = actor.movesRight ? 1 : -1
            let plan = try recipe.prepare(in: context, requestID: requestID, checkCancellation: checkCancellation)
            guard case .apply(let generated) = plan.request.action else { throw Failure.syntax }
            let frames: [[StudioCommandStroke]] = generated.compactMap { command in
                guard case .draw(let draw) = command else { return nil }; return draw.strokes
            }
            guard frames.count == count else { throw Failure.syntax }; poses.append(frames)
        }
        var commands: [StudioCommand] = actors.enumerated().map { index, actor in
            .addLayer(.init(name: "Spatter actor \(index + 1) · \(actor.action.rawValue)", result: "duo_layer_\(index)"))
        }
        var after = StudioCommandReference.id(last.id)
        for frame in 0..<count {
            try checkCancellation()
            let alias = "duo_frame_\(frame)"
            commands.append(.addFrame(.init(after: after, result: alias)))
            for actor in 0..<2 {
                let strokes = poses[actor][frame].enumerated().map { part, stroke in
                    StudioCommandStroke(id: "duo-\(requestID.uuidString)-\(actor)-\(frame)-\(part)", tool: stroke.tool,
                        points: stroke.points, color: stroke.color, width: stroke.width, opacity: stroke.opacity)
                }
                commands.append(.draw(.init(frame: .created(alias), layer: .created("duo_layer_\(actor)"), strokes: strokes)))
            }
            after = .created(alias)
        }
        commands.append(.selectFrame(.created("duo_frame_0")))
        guard commands.count <= StudioCommandExecutor.maximumCommands else { throw StudioCommandError.limitExceeded }
        return .init(request: .init(requestID: requestID, projectID: context.projectID, expectedRevision: context.revision,
            action: .apply(commands)), framesToAdd: count, durationSeconds: Double(count) / Double(context.fps),
            appendedAfterFrameID: last.id, firstNewFrameAlias: "duo_frame_0")
    }
}

/// One explicit local line mask, bound to the selection captured by the editing session.
struct SpatterSelectedErasureInstruction: Equatable {
    let startX: Double
    let startY: Double
    let endX: Double
    let endY: Double
    let mode: StudioEraserMode
    let width: Double
    let strength: Double
    static let example = "Erase selected drawings from (25%, 50%) to (75%, 50%) with hard eraser size 24 px and strength 100%."
    enum Failure: LocalizedError {
        case unsupported, missingSelection, invalidContext
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Use one complete selected eraser example with canvas positions 0–100%, hard or soft mode, size 1–512 px and strength 0–100%. Nothing changed."
            case .missingSelection: return "Select 1–256 drawn objects before opening Spatter. Images and whole layers are not selected eraser targets. Nothing changed."
            case .invalidContext: return "The current frame or active layer is unavailable for selected erasing. Nothing changed."
            }
        }
    }
    static func isInstruction(_ text: String) -> Bool {
        text.split(whereSeparator: { $0.isWhitespace }).first?.lowercased() == "erase"
    }
    static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= SpatterMotionRecipe.maximumInstructionBytes else {
            throw SpatterMotionRecipe.RecipeError.instructionTooLong
        }
        let number = #"((?:0|[1-9][0-9]*)(?:\.[0-9]+)?)"#
        let pattern = #"\A\s*erase\s+selected\s+drawings\s+from\s+\("# + number
            + #"%\s*,\s*"# + number + #"%\)\s+to\s+\("# + number + #"%\s*,\s*"# + number
            + #"%\)\s+with\s+(hard|soft)\s+eraser\s+size\s+"# + number
            + #"\s+px\s+and\s+strength\s+"# + number + #"%\.?\s*\z"#
        let expression = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            throw Failure.unsupported
        }
        func token(_ index: Int) throws -> String {
            guard let range = Range(match.range(at: index), in: text) else { throw Failure.unsupported }
            return String(text[range])
        }
        func value(_ index: Int, range: ClosedRange<Double>) throws -> Double {
            let raw = try token(index)
            guard raw.utf8.count <= 32, let value = Double(raw), value.isFinite, range.contains(value) else { throw Failure.unsupported }
            return value
        }
        guard let mode = StudioEraserMode(rawValue: try token(5).lowercased()) else { throw Failure.unsupported }
        return try .init(startX: value(1, range: 0...100), startY: value(2, range: 0...100),
            endX: value(3, range: 0...100), endY: value(4, range: 0...100), mode: mode,
            width: value(6, range: 1...512), strength: value(7, range: 0...100) / 100)
    }
    func prepare(in context: StudioCommandContext, selectedElementIDs: Set<String>, requestID: UUID = UUID(),
                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StudioCommandRequest {
        try checkCancellation()
        guard !selectedElementIDs.isEmpty, selectedElementIDs.count <= 256,
              selectedElementIDs.allSatisfy({ !$0.isEmpty && $0.count <= 160 }) else { throw Failure.missingSelection }
        guard [startX, startY, endX, endY].allSatisfy({ $0.isFinite && (0...100).contains($0) }),
              width.isFinite, (1...512).contains(width), strength.isFinite, (0...1).contains(strength) else { throw Failure.unsupported }
        guard context.width > 0, context.height > 0,
              context.frames.contains(where: { $0.id == context.activeFrameID }),
              let layer = context.layers.first(where: { $0.id == context.activeLayerID }),
              layer.visible, layer.opacity > 0, !layer.isFullyLocked, layer.lockMode == "free" else { throw Failure.invalidContext }
        let points: [StrokePoint] = [.init(x: CGFloat(startX / 100 * Double(context.width)), y: CGFloat(startY / 100 * Double(context.height))),
                                     .init(x: CGFloat(endX / 100 * Double(context.width)), y: CGFloat(endY / 100 * Double(context.height)))]
        try checkCancellation()
        return .init(requestID: requestID, projectID: context.projectID, expectedRevision: context.revision,
            action: .apply([.eraseSelectedElements(.init(frame: .id(context.activeFrameID), layer: .id(context.activeLayerID),
                elementIDs: selectedElementIDs.sorted(), points: points, width: width, opacity: strength, mode: mode))]))
    }
}

/// Explicit same-command layer duplication; no imported content is executed.
/// Explicit one-based navigation resolves to captured stable identities.
struct SpatterNavigationInstruction: Equatable {
    enum Target: String { case frame, layer }
    let target: Target
    let number: Int
    var example: String { "Select \(target.rawValue) \(number)." }
    static let frameExample = "Select frame 1."
    static let layerExample = "Select layer 1."
    static func isInstruction(_ text: String) -> Bool {
        text.range(of: #"\A\s*select\s+(?:frame|layer)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
    enum Failure: LocalizedError {
        case unsupported, missing
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Use Select frame 1. or Select layer 1. with a positive whole number. Nothing changed."
            case .missing: return "That frame or layer does not exist in the captured project. Nothing changed."
            }
        }
    }
    static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= SpatterMotionRecipe.maximumInstructionBytes else { throw SpatterMotionRecipe.RecipeError.instructionTooLong }
        guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.unsupported }
        let expression = try NSRegularExpression(pattern: #"\A\s*select\s+(frame|layer)\s+([1-9][0-9]{0,3})\.\s*\z"#, options: [.caseInsensitive])
        guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let kind = Range(match.range(at: 1), in: text), let value = Range(match.range(at: 2), in: text),
              let target = Target(rawValue: text[kind].lowercased()), let number = Int(text[value]) else { throw Failure.unsupported }
        return .init(target: target, number: number)
    }
    func prepare(in context: StudioCommandContext, requestID: UUID = UUID(),
                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StudioCommandRequest {
        try checkCancellation()
        let command: StudioCommand
        switch target {
        case .frame:
            guard number > 0, number <= context.frames.count else { throw Failure.missing }
            command = .selectFrame(.id(context.frames[number - 1].id))
        case .layer:
            guard number > 0, number <= context.layers.count else { throw Failure.missing }
            command = .selectLayer(.id(context.layers[number - 1].id))
        }
        return .init(requestID: requestID, projectID: context.projectID, expectedRevision: context.revision, action: .apply([command]))
    }
}

struct SpatterLayerStructureInstruction: Equatable {
    enum Action: Equatable { case add, delete }
    let action: Action
    let name: String?
    static let addExample = "Add layer named \"Foreground\"."
    static let deleteExample = "Delete active layer."
    var example: String { action == .delete ? Self.deleteExample : "Add layer named \"\(name ?? "Foreground")\"." }
    enum Failure: LocalizedError {
        case unsupported, unavailable
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Use Add layer named \"Foreground\". or Delete active layer. as one complete instruction. Nothing changed."
            case .unavailable: return "Select an existing layer. Keep at least one layer and at most 128 layers. Nothing changed."
            }
        }
    }
    static func isInstruction(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter }
        return ["add", "delete"].contains(words.first.map(String.init) ?? "") && words.contains("layer")
    }
    static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= SpatterMotionRecipe.maximumInstructionBytes else { throw SpatterMotionRecipe.RecipeError.instructionTooLong }
        guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.unsupported }
        if text.range(of: #"\A\s*delete\s+active\s+layer\.\s*\z"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .init(action: .delete, name: nil)
        }
        let expression = try NSRegularExpression(pattern: #"\A\s*add\s+layer\s+named\s+"([^"\r\n]+)"\.\s*\z"#, options: [.caseInsensitive])
        guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { throw Failure.unsupported }
        let name = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard StudioCommandExecutor.isValidLayerName(name) else { throw Failure.unsupported }
        return .init(action: .add, name: name)
    }
    func prepare(in context: StudioCommandContext, requestID: UUID = UUID(),
                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StudioCommandRequest {
        try checkCancellation()
        guard context.layers.contains(where: { $0.id == context.activeLayerID }) else { throw Failure.unavailable }
        let command: StudioCommand
        switch action {
        case .add:
            guard context.layers.count < 128, let name, StudioCommandExecutor.isValidLayerName(name) else { throw Failure.unavailable }
            command = .addLayer(.init(name: name, result: "new_layer"))
        case .delete:
            guard context.layers.count > 1 else { throw Failure.unavailable }
            command = .deleteLayer(.id(context.activeLayerID))
        }
        try checkCancellation()
        return .init(requestID: requestID, projectID: context.projectID, expectedRevision: context.revision, action: .apply([command]))
    }
}

struct SpatterLayerDuplicateInstruction: Equatable {
    static let example = "Duplicate active layer."
    static func isInstruction(_ text: String) -> Bool {
        let words = Set(text.lowercased().split { !$0.isLetter }.map(String.init))
        return words.contains("duplicate") && words.contains("layer")
    }
    enum Failure: LocalizedError {
        case unsupported, invalidContext
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Use Duplicate active layer. as one complete instruction. Nothing changed."
            case .invalidContext: return "Select an existing layer with room for another layer before duplicating. Nothing changed."
            }
        }
    }
    static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= SpatterMotionRecipe.maximumInstructionBytes else { throw SpatterMotionRecipe.RecipeError.instructionTooLong }
        let pattern = #"\A\s*duplicate\s+active\s+layer\.\s*\z"#
        guard try NSRegularExpression(pattern:pattern,options:[.caseInsensitive]).firstMatch(in:text,range:NSRange(text.startIndex...,in:text)) != nil else { throw Failure.unsupported }
        return Self()
    }
    func prepare(in context: StudioCommandContext, requestID: UUID = UUID(),
                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StudioCommandRequest {
        try checkCancellation()
        guard context.layers.count < 128, context.layers.contains(where:{$0.id == context.activeLayerID}) else { throw Failure.invalidContext }
        try checkCancellation()
        return .init(requestID:requestID,projectID:context.projectID,expectedRevision:context.revision,
            action:.apply([.duplicateLayer(.init(source:.id(context.activeLayerID),result:"duplicated_layer"))]))
    }
}

struct SpatterLayerUpdateInstruction: Equatable {
    let name: String?
    let opacity: Double?
    var visible: Bool? = nil
    var blend: StudioCommandBlend? = nil
    var lock: StudioCommandLock? = nil
    static let lockModes: [StudioCommandLock] = [.free, .full, .position, .alpha]
    static func lockExample(_ mode: StudioCommandLock) -> String { "Set active layer lock to \(mode.rawValue)." }
    static let blendModes: [StudioCommandBlend] = StudioLayerBlendMode.allCases
    static func blendExample(_ mode: StudioCommandBlend) -> String { "Set active layer blend to \(mode.rawValue)." }
    static let renameExample = "Rename active layer to \"Foreground\"."
    static let hideExample = "Hide active layer."
    static let showExample = "Show active layer."
    static let opacityExample = "Set active layer opacity to 50%."
    static func isInstruction(_ text: String) -> Bool {
        text.range(of:#"\A\s*(?:rename\s+active\s+layer|set\s+active\s+layer\s+(?:opacity|blend|lock)|(?:hide|show)\s+active\s+layer)\b"#, options:[.regularExpression,.caseInsensitive]) != nil
    }
    enum Failure: LocalizedError {
        case unsupported, invalidContext
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Use Rename active layer to \"Foreground\". or Set active layer opacity to 50%. Hide active layer. and Show active layer. change visibility. Set active layer blend to multiply. supports normal, multiply, screen, overlay, darken and lighten. Set active layer lock to position. supports free, full, position and alpha. Names use 1–120 characters and opacity is 0–100%. Nothing changed."
            case .invalidContext: return "Select an existing active layer before changing its settings. Nothing changed."
            }
        }
    }
    static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= SpatterMotionRecipe.maximumInstructionBytes else { throw SpatterMotionRecipe.RecipeError.instructionTooLong }
        guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.unsupported }
        let range = NSRange(text.startIndex...,in:text)
        let lockExpression = try NSRegularExpression(pattern: #"\A\s*set\s+active\s+layer\s+lock\s+to\s+(free|full|position|alpha)\.\s*\z"#, options: [.caseInsensitive])
        if let match = lockExpression.firstMatch(in: text, range: range),
           let value = Range(match.range(at: 1), in: text),
           let mode = StudioCommandLock(rawValue: text[value].lowercased()) {
            return .init(name: nil, opacity: nil, lock: mode)
        }
        let blendExpression = try NSRegularExpression(pattern: #"\A\s*set\s+active\s+layer\s+blend\s+to\s+(normal|darken|multiply|color-burn|linear-burn|lighten|screen|color-dodge|linear-dodge|overlay|soft-light|hard-light|difference|exclusion|hue|saturation|color|luminosity)\.\s*\z"#, options: [.caseInsensitive])
        if let match = blendExpression.firstMatch(in: text, range: range),
           let value = Range(match.range(at: 1), in: text),
           let mode = StudioCommandBlend(rawValue: text[value].lowercased()) {
            return .init(name: nil, opacity: nil, blend: mode)
        }
        let visibility = try NSRegularExpression(pattern:#"\A\s*(hide|show)\s+active\s+layer\.\s*\z"#,options:[.caseInsensitive])
        if let match = visibility.firstMatch(in:text,range:range), let word = Range(match.range(at:1),in:text) {
            return .init(name:nil,opacity:nil,visible:text[word].lowercased() == "show")
        }

        let rename = try NSRegularExpression(pattern:#"\A\s*rename\s+active\s+layer\s+to\s+"([^"\r\n]+)"\.\s*\z"#,options:[.caseInsensitive])
        if let match = rename.firstMatch(in:text,range:range), let value = Range(match.range(at:1),in:text) {
            let name = String(text[value]).trimmingCharacters(in:.whitespacesAndNewlines)
            guard StudioCommandExecutor.isValidLayerName(name) else { throw Failure.unsupported }
            return .init(name:name,opacity:nil)
        }
        let alpha = try NSRegularExpression(pattern:#"\A\s*set\s+active\s+layer\s+opacity\s+to\s+((?:0|[1-9][0-9]*)(?:\.[0-9]+)?)%\.\s*\z"#,options:[.caseInsensitive])
        guard let match = alpha.firstMatch(in:text,range:range), let value = Range(match.range(at:1),in:text),
              let percent = Double(text[value]), percent.isFinite, (0...100).contains(percent) else { throw Failure.unsupported }
        return .init(name:nil,opacity:percent/100)
    }
    func prepare(in context: StudioCommandContext, requestID: UUID = UUID(),
                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StudioCommandRequest {
        try checkCancellation()
        guard context.layers.contains(where:{$0.id == context.activeLayerID}) else { throw Failure.invalidContext }
        guard [name != nil, opacity != nil, visible != nil, blend != nil, lock != nil].filter({$0}).count == 1, name.map(StudioCommandExecutor.isValidLayerName) ?? true,
              opacity.map({$0.isFinite && (0...1).contains($0)}) ?? true else { throw Failure.unsupported }
        var settings = StudioCommandLayerSettings(); settings.name = name; settings.opacity = opacity; settings.visible = visible; settings.blend = blend; settings.lock = lock
        try checkCancellation()
        return .init(requestID:requestID,projectID:context.projectID,expectedRevision:context.revision,
            action:.apply([.updateLayer(.init(layer:.id(context.activeLayerID),settings:settings))]))
    }
}

/// Explicit image intent only. The session separately owns the selected image
/// token; this context check never substitutes a preferred/fallback image.
struct SpatterImageReflectionInstruction: Equatable {
    let axis: StudioReflectionAxis
    static let horizontalExample = "Flip selected image horizontally."
    static let verticalExample = "Flip selected image vertically."
    enum Failure: LocalizedError {
        case unsupported, invalidContext
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Use Flip selected image horizontally. or Flip selected image vertically. as one complete instruction. Nothing changed."
            case .invalidContext: return "Select the image on its visible, unlocked active layer with Move before opening Spatter. Nothing changed."
            }
        }
    }
    static func isInstruction(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter }
        return words.first == "flip" && words.dropFirst().contains("image")
    }
    static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= SpatterMotionRecipe.maximumInstructionBytes else {
            throw SpatterMotionRecipe.RecipeError.instructionTooLong
        }
        guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.unsupported }
        let expression = try NSRegularExpression(
            pattern: #"\A\s*flip\s+selected\s+image\s+(horizontally|vertically)\.?\s*\z"#,
            options: [.caseInsensitive])
        guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { throw Failure.unsupported }
        return .init(axis: text[range].lowercased() == "horizontally" ? .horizontal : .vertical)
    }
    func prepare(in context: StudioCommandContext, frameID: String, layerID: String, assetID: String,
                 requestID: UUID = UUID(),
                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StudioCommandRequest {
        try checkCancellation()
        guard frameID == context.activeFrameID, layerID == context.activeLayerID,
              let frame = context.frames.first(where: { $0.id == frameID }),
              frame.imageLayerID == layerID, frame.imageAssetID == assetID, frame.imagePlacement != nil,
              assetID.hasPrefix("image-"), UUID(uuidString: String(assetID.dropFirst(6))) != nil,
              let layer = context.layers.first(where: { $0.id == layerID }),
              layer.visible, layer.opacity > 0, !layer.isFullyLocked, layer.lockMode == "free" else {
            throw Failure.invalidContext
        }
        try checkCancellation()
        return .init(requestID: requestID, projectID: context.projectID, expectedRevision: context.revision,
            action: .apply([.reflectImage(.init(frame: .id(frameID), assetID: assetID, axis: axis, layer: .id(layerID)))]))
    }
}


/// Explicit local ordering only; the session owns captured selection authority.
struct SpatterAudioTrackInstruction: Equatable {
    let track: Int
    var volume: Double? = nil
    var muted: Bool? = nil
    /// −1 (L100) … 0 (center) … 1 (R100), matching the editor's pan range.
    var pan: Double? = nil
    var soloed: Bool? = nil
    static let volumeExample = "Set audio track 1 volume to 40%."
    static let muteExample = "Mute audio track 1."
    static let unmuteExample = "Unmute audio track 1."
    static let panExample = "Pan audio track 2 to L40."
    static let centerExample = "Pan audio track 2 to center."
    static let soloExample = "Solo audio track 3."
    static let unsoloExample = "Unsolo audio track 3."
    enum Failure: LocalizedError {
        case unsupported
        var errorDescription: String? { "Use Set audio track 1 volume to 40%., Mute audio track 1., Unmute audio track 1., Pan audio track 2 to L40. (L100–R100 or center), Solo audio track 3., or Unsolo audio track 3. Choose track 1–4 and volume 0–100%. Nothing changed." }
    }
    static func isInstruction(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter }
        return words.contains("audio") && words.contains("track") && !words.contains("clip")
    }
    static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= SpatterMotionRecipe.maximumInstructionBytes else { throw SpatterMotionRecipe.RecipeError.instructionTooLong }
        guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.unsupported }
        let patterns = [#"\A\s*set\s+audio\s+track\s+([1-4])\s+volume\s+to\s+([0-9]{1,3}(?:\.[0-9]{1,6})?)\s*%\.?\s*\z"#,
                        #"\A\s*(mute|unmute)\s+audio\s+track\s+([1-4])\.?\s*\z"#,
                        #"\A\s*pan\s+audio\s+track\s+([1-4])\s+to\s+(center|centre|[LR](?:100|[1-9]?[0-9]))\.?\s*\z"#,
                        #"\A\s*(solo|unsolo)\s+audio\s+track\s+([1-4])\.?\s*\z"#]
        for (index, pattern) in patterns.enumerated() {
            let expression = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let first = Range(match.range(at: 1), in: text), let second = Range(match.range(at: 2), in: text) else { continue }
            switch index {
            case 0:
                guard let track = Int(text[first]), let percent = Double(text[second]), percent.isFinite,
                      (0...100).contains(percent) else { throw Failure.unsupported }
                return .init(track: track, volume: percent / 100)
            case 1:
                guard let track = Int(text[second]) else { throw Failure.unsupported }
                return .init(track: track, muted: text[first].lowercased() == "mute")
            case 2:
                guard let track = Int(text[first]) else { throw Failure.unsupported }
                let position = text[second].lowercased()
                if position.hasPrefix("cent") { return .init(track: track, pan: 0) }
                guard let magnitude = Double(position.dropFirst()), magnitude.isFinite, (0...100).contains(magnitude) else { throw Failure.unsupported }
                return .init(track: track, pan: (position.hasPrefix("l") ? -magnitude : magnitude) / 100)
            default:
                guard let track = Int(text[second]) else { throw Failure.unsupported }
                return .init(track: track, soloed: text[first].lowercased() == "solo")
            }
        }
        throw Failure.unsupported
    }
    func prepare(in context: StudioCommandContext, requestID: UUID = UUID(),
                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StudioCommandRequest {
        try checkCancellation()
        return .init(requestID: requestID, projectID: context.projectID, expectedRevision: context.revision,
            action: .apply([.updateAudioTrack(.init(track: track, volume: volume, muted: muted, pan: pan, soloed: soloed))]))
    }
}

/// Local, complete-instruction grammar; never falls back to a provider or an implicit target.
struct SpatterDrawingDuplicateInstruction: Equatable {
    static let example = "Duplicate selected drawings."
    enum Failure: LocalizedError {
        case unsupported, selection
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Use Duplicate selected drawings. as one complete instruction. Nothing changed."
            case .selection: return "Select 1–1024 drawings with Move before opening Spatter. Images and mixed artwork are not drawing duplication targets. Nothing changed."
            }
        }
    }
    static func isInstruction(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter }
        return words.first == "duplicate" && words.contains("drawings")
    }
    static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= SpatterMotionRecipe.maximumInstructionBytes else { throw SpatterMotionRecipe.RecipeError.instructionTooLong }
        guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.unsupported }
        let expression = try NSRegularExpression(pattern: #"\A\s*duplicate\s+selected\s+drawings\.?\s*\z"#, options: [.caseInsensitive])
        guard expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { throw Failure.unsupported }
        return .init()
    }
    func prepare(in context: StudioCommandContext, selectedElementIDs: Set<String>, requestID: UUID = UUID(),
                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StudioCommandRequest {
        try checkCancellation()
        guard !selectedElementIDs.isEmpty, selectedElementIDs.count <= 1024,
              selectedElementIDs.allSatisfy({ !$0.isEmpty && $0.count <= 160 }),
              let frame = context.frames.first(where: { $0.id == context.activeFrameID }),
              selectedElementIDs.count <= frame.elementCount else { throw Failure.selection }
        return .init(requestID: requestID, projectID: context.projectID, expectedRevision: context.revision,
            action: .apply([.duplicateElements(.init(frame: .id(context.activeFrameID), elementIDs: selectedElementIDs.sorted()))]))
    }
}

struct SpatterArtworkOrderInstruction: Equatable {
    let forward: Bool
    static let forwardExample = "Bring selected artwork forward."
    static let backwardExample = "Send selected artwork backward."
    enum Failure: LocalizedError {
        case unsupported, selection
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Use Bring selected artwork forward. or Send selected artwork backward. as one complete instruction. Nothing changed."
            case .selection: return "Select drawings, an image, or mixed artwork with Move before opening Spatter. Nothing changed."
            }
        }
    }
    static func isInstruction(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter }
        return ["bring", "send"].contains(words.first.map(String.init) ?? "") && words.contains("artwork")
    }
    static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= SpatterMotionRecipe.maximumInstructionBytes else { throw SpatterMotionRecipe.RecipeError.instructionTooLong }
        guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.unsupported }
        let expression = try NSRegularExpression(pattern: #"\A\s*(bring\s+selected\s+artwork\s+forward|send\s+selected\s+artwork\s+backward)\.?\s*\z"#, options: [.caseInsensitive])
        guard expression.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)) != nil else { throw Failure.unsupported }
        return .init(forward: text.trimmingCharacters(in:.whitespacesAndNewlines).lowercased().hasPrefix("bring"))
    }
    func prepare(in context: StudioCommandContext, selectedElementIDs: Set<String>,
                 image: StudioCommand.SelectedArtworkImage?, requestID: UUID = UUID(),
                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StudioCommandRequest {
        try checkCancellation()
        guard !selectedElementIDs.isEmpty || image != nil, selectedElementIDs.count <= 1024,
              selectedElementIDs.allSatisfy({ !$0.isEmpty && $0.count <= 160 }),
              let frame = context.frames.first(where: { $0.id == context.activeFrameID }),
              selectedElementIDs.count <= frame.elementCount else { throw Failure.selection }
        if let image {
            guard frame.imageLayerID == image.layerID, frame.imageAssetID == image.assetID,
                  frame.imagePlacement != nil, image.layerID == context.activeLayerID,
                  let layer = context.layers.first(where: { $0.id == image.layerID }),
                  layer.visible, layer.opacity > 0, !layer.isFullyLocked, layer.lockMode == "free" else { throw Failure.selection }
        }
        try checkCancellation()
        return .init(requestID:requestID,projectID:context.projectID,expectedRevision:context.revision,
            action:.apply([.orderSelectedArtwork(.init(frame:.id(context.activeFrameID),elementIDs:selectedElementIDs.sorted(),
                image:image,direction:forward ? .later : .earlier))]))
    }
}


struct SpatterLayerOrderInstruction: Equatable {
    let up: Bool
    static let upExample = "Move active layer up."
    static let downExample = "Move active layer down."
    enum Failure: LocalizedError {
        case unsupported, unavailable, boundary
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Use Move active layer up. or Move active layer down. as one complete instruction. Nothing changed."
            case .unavailable: return "Select an existing active layer before changing layer order. Nothing changed."
            case .boundary: return "The active layer cannot move farther in this direction. Nothing changed."
            }
        }
    }
    static func isInstruction(_ text: String) -> Bool {
        text.range(of:#"\A\s*move\s+active\s+layer\b"#,options:[.regularExpression,.caseInsensitive]) != nil
    }
    static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= SpatterMotionRecipe.maximumInstructionBytes else { throw SpatterMotionRecipe.RecipeError.instructionTooLong }
        guard !text.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else { throw Failure.unsupported }
        let pattern = try NSRegularExpression(pattern:#"\A\s*move\s+active\s+layer\s+(up|down)\.\s*\z"#,options:[.caseInsensitive])
        guard let match = pattern.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)),
              let word = Range(match.range(at:1),in:text) else { throw Failure.unsupported }
        return .init(up:text[word].lowercased() == "up")
    }
    func prepare(in context: StudioCommandContext, requestID: UUID = UUID(),
                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StudioCommandRequest {
        try checkCancellation()
        guard let index = context.layers.firstIndex(where:{$0.id == context.activeLayerID}) else { throw Failure.unavailable }
        guard context.layers.indices.contains(index + (up ? -1 : 1)) else { throw Failure.boundary }
        try checkCancellation()
        return .init(requestID:requestID,projectID:context.projectID,expectedRevision:context.revision,
            action:.apply([.moveLayer(.init(target:.id(context.activeLayerID),direction:up ? .earlier : .later))]))
    }
}


/// One explicit active-frame operation. Never infer a plural frame selection.
struct SpatterFrameActionInstruction: Equatable {
    enum Action: String, CaseIterable { case add, duplicate, earlier, later, delete
        var example: String {
            switch self {
            case .add: return "Add blank frame."
            case .duplicate: return "Duplicate active frame."
            case .earlier: return "Move active frame earlier."
            case .later: return "Move active frame later."
            case .delete: return "Delete active frame."
            }
        }
    }
    let action: Action
    let count: Int
    init(action: Action, count: Int = 1) { self.action = action; self.count = count }
    var example: String {
        if action == .add && count > 1 { return "Add \(count) blank frames." }
        if action == .duplicate && count > 1 { return "Duplicate active frame \(count) times." }
        return action.example
    }
    enum Failure: LocalizedError {
        case unsupported, unavailable, boundary, lastFrame, capacity
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Use Add blank frame., Add 12 blank frames. (1–96), Duplicate active frame., Duplicate active frame 12 times. (1–96), Move active frame earlier., Move active frame later., or Delete active frame. as one complete instruction. Nothing changed."
            case .unavailable: return "Select an existing active frame and stop playback before editing frames. Nothing changed."
            case .boundary: return "The active frame cannot move farther in this direction. Nothing changed."
            case .lastFrame: return "The last frame cannot be deleted. Nothing changed."
            case .capacity: return "The project has reached its 1,000-frame limit. Nothing changed."
            }
        }
    }
    static func isInstruction(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter }
        return ["add","duplicate","move","delete"].contains(words.first.map(String.init) ?? "")
            && words.contains(where:{$0 == "frame" || $0 == "frames"})
    }
    static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= SpatterMotionRecipe.maximumInstructionBytes else { throw SpatterMotionRecipe.RecipeError.instructionTooLong }
        guard !text.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else { throw Failure.unsupported }
        let addition = try NSRegularExpression(pattern: #"\A\s*add\s+(?:blank\s+frame|([1-9][0-9]?)\s+blank\s+frames)\.\s*\z"#, options: [.caseInsensitive])
        if let match = addition.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            let count = Range(match.range(at: 1), in: text).flatMap { Int(text[$0]) } ?? 1
            guard (1...96).contains(count) else { throw Failure.unsupported }
            return .init(action: .add, count: count)
        }
        let duplicates = try NSRegularExpression(pattern: #"\A\s*duplicate\s+active\s+frame\s+([1-9][0-9]?)\s+times\.\s*\z"#, options: [.caseInsensitive])
        if let match = duplicates.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let value = Range(match.range(at: 1), in: text), let count = Int(text[value]) {
            guard (1...96).contains(count) else { throw Failure.unsupported }
            return .init(action: .duplicate, count: count)
        }
        let pattern = try NSRegularExpression(pattern:#"\A\s*(duplicate\s+active\s+frame|delete\s+active\s+frame|move\s+active\s+frame\s+(?:earlier|later))\.\s*\z"#,options:[.caseInsensitive])
        guard pattern.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)) != nil else { throw Failure.unsupported }
        let words = text.lowercased().split { !$0.isLetter }
        return .init(action:words.first == "duplicate" ? .duplicate : words.first == "delete" ? .delete : words.last == "earlier" ? .earlier : .later)
    }
    func prepare(in context: StudioCommandContext, requestID: UUID = UUID(),
                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StudioCommandRequest {
        try checkCancellation()
        guard let index = context.frames.firstIndex(where:{$0.id == context.activeFrameID}) else { throw Failure.unavailable }
        guard action == .add || action == .duplicate || count == 1 else { throw Failure.unsupported }
        let command: StudioCommand
        switch action {
        case .add:
            guard (1...96).contains(count), context.frames.count <= 1000 - count else { throw Failure.capacity }
            var commands: [StudioCommand] = []
            var previous = StudioCommandReference.id(context.activeFrameID)
            for number in 0..<count {
                try checkCancellation()
                let alias = "blank_frame_\(number)"
                commands.append(.addFrame(.init(after: previous, result: alias)))
                previous = .created(alias)
            }
            return .init(requestID: requestID, projectID: context.projectID, expectedRevision: context.revision, action: .apply(commands))
        case .duplicate:
            guard (1...96).contains(count), context.frames.count <= 1000 - count else { throw Failure.capacity }
            var commands: [StudioCommand] = []
            var previous = StudioCommandReference.id(context.activeFrameID)
            for number in 0..<count {
                try checkCancellation()
                let alias = number == 0 ? "duplicated_frame" : "duplicated_frame_\(number)"
                commands.append(.duplicateFrame(.init(source: previous, result: alias)))
                previous = .created(alias)
            }
            return .init(requestID: requestID, projectID: context.projectID, expectedRevision: context.revision, action: .apply(commands))
        case .delete:
            guard context.frames.count > 1 else { throw Failure.lastFrame }
            command = .deleteFrame(.id(context.activeFrameID))
        case .earlier, .later:
            guard context.frames.indices.contains(index + (action == .earlier ? -1 : 1)) else { throw Failure.boundary }
            command = .moveFrame(.init(target:.id(context.activeFrameID),direction:action == .earlier ? .earlier : .later))
        }
        try checkCancellation()
        return .init(requestID:requestID,projectID:context.projectID,expectedRevision:context.revision,action:.apply([command]))
    }
}


/// Complete, explicit local guide settings. Configuring does not implicitly
/// enable guides; visibility does not replace the remembered settings.
struct SpatterOnionInstruction: Equatable {
    let visible: Bool?
    let settings: StudioOnionSettings?
    static let showExample = "Show onion skin."
    static let hideExample = "Hide onion skin."
    static let settingsExample = "Set onion skin to 2 previous frames, 1 next frame, 35% opacity, tinted."
    static func isInstruction(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter }
        return ["show", "hide", "set"].contains(words.first.map(String.init) ?? "") && words.contains("onion")
    }
    enum Failure: LocalizedError {
        case unsupported, unavailable
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Use Show onion skin. or Hide onion skin. To configure all settings, use Set onion skin to 2 previous frames, 1 next frame, 35% opacity, tinted. Counts are 0–2, opacity is 5–80%, and tint is tinted or untinted. Nothing changed."
            case .unavailable: return "Open an existing frame and stop playback before changing onion-skin guides. Nothing changed."
            }
        }
    }
    static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= SpatterMotionRecipe.maximumInstructionBytes else { throw SpatterMotionRecipe.RecipeError.instructionTooLong }
        guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.unsupported }
        let range = NSRange(text.startIndex..., in: text)
        let visibility = try NSRegularExpression(pattern: #"\A\s*(show|hide)\s+onion\s+skin\.\s*\z"#, options: [.caseInsensitive])
        if let match = visibility.firstMatch(in: text, range: range), let word = Range(match.range(at: 1), in: text) {
            return .init(visible: text[word].lowercased() == "show", settings: nil)
        }
        let pattern = try NSRegularExpression(pattern: #"\A\s*set\s+onion\s+skin\s+to\s+([0-2])\s+previous\s+frames?,\s+([0-2])\s+next\s+frames?,\s+([5-9]|[1-7][0-9]|80)%\s+opacity,\s+(tinted|untinted)\.\s*\z"#, options: [.caseInsensitive])
        guard let match = pattern.firstMatch(in: text, range: range) else { throw Failure.unsupported }
        func part(_ index: Int) -> String { String(text[Range(match.range(at: index), in: text)!]) }
        guard let previous = Int(part(1)), let next = Int(part(2)), let percent = Int(part(3)) else { throw Failure.unsupported }
        return .init(visible: nil, settings: .init(previousCount: previous, nextCount: next,
            opacity: Double(percent) / 100, tinted: part(4).lowercased() == "tinted"))
    }
    func prepare(in context: StudioCommandContext, requestID: UUID = UUID(),
                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StudioCommandRequest {
        try checkCancellation()
        guard context.frames.contains(where: { $0.id == context.activeFrameID }) else { throw Failure.unavailable }
        guard (visible != nil) != (settings != nil), settings?.isValid != false else { throw Failure.unsupported }
        try checkCancellation()
        return .init(requestID: requestID, projectID: context.projectID, expectedRevision: context.revision,
            action: .apply([.canvasOptions(.init(onion: visible, onionSettings: settings))]))
    }
}


/// Complete grid guide settings; no background media or artwork is created.
struct SpatterGridInstruction: Equatable {
    let visible: Bool?
    let settings: StudioGridSettings?
    static let showExample = "Show grid."
    static let hideExample = "Hide grid."
    static let settingsExample = "Set grid to 32 canvas points spacing, 25% opacity, red tint."
    static func isInstruction(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter }
        return ["show", "hide", "set"].contains(words.first.map(String.init) ?? "") && words.contains("grid")
    }
    enum Failure: LocalizedError {
        case unsupported, unavailable
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Use Show grid. or Hide grid. To configure all settings, use Set grid to 32 canvas points spacing, 25% opacity, red tint. Spacing is 8–160 whole canvas points, opacity is 5–60%, and tint is blue, gray or red. Nothing changed."
            case .unavailable: return "Open an existing frame and stop playback before changing grid guides. Nothing changed."
            }
        }
    }
    static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= SpatterMotionRecipe.maximumInstructionBytes else { throw SpatterMotionRecipe.RecipeError.instructionTooLong }
        guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.unsupported }
        let range = NSRange(text.startIndex..., in: text)
        let visibility = try NSRegularExpression(pattern: #"\A\s*(show|hide)\s+grid\.\s*\z"#, options: [.caseInsensitive])
        if let match = visibility.firstMatch(in: text, range: range), let word = Range(match.range(at: 1), in: text) {
            return .init(visible: text[word].lowercased() == "show", settings: nil)
        }
        let pattern = try NSRegularExpression(pattern: #"\A\s*set\s+grid\s+to\s+([8-9]|[1-9][0-9]|1[0-5][0-9]|160)\s+canvas\s+points\s+spacing,\s+([5-9]|[1-5][0-9]|60)%\s+opacity,\s+(blue|gray|red)\s+tint\.\s*\z"#, options: [.caseInsensitive])
        guard let match = pattern.firstMatch(in: text, range: range) else { throw Failure.unsupported }
        func part(_ index: Int) -> String { String(text[Range(match.range(at: index), in: text)!]) }
        guard let spacing = Int(part(1)), let percent = Int(part(2)),
              let tint = StudioGridSettings.Tint(rawValue: part(3).lowercased()) else { throw Failure.unsupported }
        return .init(visible: nil, settings: .init(spacing: Double(spacing), opacity: Double(percent) / 100, tint: tint))
    }
    func prepare(in context: StudioCommandContext, requestID: UUID = UUID(),
                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StudioCommandRequest {
        try checkCancellation()
        guard context.frames.contains(where: { $0.id == context.activeFrameID }) else { throw Failure.unavailable }
        guard (visible != nil) != (settings != nil), settings?.isValid != false else { throw Failure.unsupported }
        try checkCancellation()
        return .init(requestID: requestID, projectID: context.projectID, expectedRevision: context.revision,
            action: .apply([.canvasOptions(.init(grid: visible, gridSettings: settings))]))
    }
}

/// Explicit local command; additional instructions never become implicit edits.
struct SpatterFrameCutInstruction {
    static let example = "Cut current frame."
    static func isInstruction(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter }
        return words.first == "cut" && words.contains("frame")
    }
    static func prepare(_ text: String, in context: StudioCommandContext, requestID: UUID,
                        checkCancellation: () throws -> Void) throws -> StudioCommandRequest {
        try checkCancellation()
        guard text.utf8.count <= SpatterMotionRecipe.maximumInstructionBytes,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw StudioCommandError.invalidSettings
        }
        let expression = try NSRegularExpression(pattern: #"\A\s*cut\s+current\s+frame\.?\s*\z"#, options: [.caseInsensitive])
        guard expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else {
            throw StudioDocumentError.invalid("Use Cut current frame. as one complete instruction. Nothing changed.")
        }
        guard context.frames.count > 1 else { throw StudioCommandError.cannotDeleteLastFrame }
        return .init(requestID: requestID, projectID: context.projectID, expectedRevision: context.revision,
            action: .apply([.cutFrame(.id(context.activeFrameID))]))
    }
}


// MARK: - Selection, image and text grammars (October 12, 2026)
//
// Each grammar is a complete anchored instruction: a trailing clause rejects the
// whole instruction rather than executing its prefix. The session supplies the
// captured selection; nothing here infers a target from prose or a provider.

/// Shared bounds and capture helper for the grammars below. Private to this file.
private enum SpatterGrammarSupport {
    static func checked(_ text: String) throws {
        guard text.utf8.count <= SpatterMotionRecipe.maximumInstructionBytes else { throw SpatterMotionRecipe.RecipeError.instructionTooLong }
        guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw SpatterMotionRecipe.RecipeError.unsupportedInstruction }
    }
    /// Captures for the first anchored pattern that matches; nil ranges become "".
    static func captures(_ text: String, patterns: [String]) throws -> (Int, [String])? {
        for (index, pattern) in patterns.enumerated() {
            let expression = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }
            var values: [String] = []
            for group in 1..<match.numberOfRanges {
                values.append(Range(match.range(at: group), in: text).map { String(text[$0]) } ?? "")
            }
            return (index, values)
        }
        return nil
    }
    static func number(_ token: String, in range: ClosedRange<Double>) -> Double? {
        guard let value = Double(token), value.isFinite, range.contains(value) else { return nil }
        return value
    }
    static func requireSelection(_ ids: Set<String>, in context: StudioCommandContext) -> Bool {
        guard !ids.isEmpty, ids.count <= 1024, ids.allSatisfy({ !$0.isEmpty && $0.count <= 160 }),
              let frame = context.frames.first(where: { $0.id == context.activeFrameID }),
              ids.count <= frame.elementCount else { return false }
        return true
    }
    /// Same eligibility the reflection grammar applies to a captured selected image.
    static func requireImage(frameID: String, layerID: String, assetID: String, in context: StudioCommandContext) -> Bool {
        guard frameID == context.activeFrameID, layerID == context.activeLayerID,
              let frame = context.frames.first(where: { $0.id == frameID }),
              frame.imageLayerID == layerID, frame.imageAssetID == assetID, frame.imagePlacement != nil,
              assetID.hasPrefix("image-"), UUID(uuidString: String(assetID.dropFirst(6))) != nil,
              let layer = context.layers.first(where: { $0.id == layerID }),
              layer.visible, layer.opacity > 0, !layer.isFullyLocked, layer.lockMode == "free" else { return false }
        return true
    }
    static let percent = #"([^\s%,()]+)\s*%"#
}

/// "Move selected drawings by (10%, -5%)." Percentages of the canvas width/height.
struct SpatterSelectionTranslateInstruction: Equatable {
    let dxPercent: Double
    let dyPercent: Double
    static let example = "Move selected drawings by (10%, -5%)."
    enum Failure: LocalizedError {
        case unsupported, selection
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Use Move selected drawings by (10%, -5%). with offsets between -100% and 100% of the canvas. Nothing changed."
            case .selection: return "Select 1–1,024 drawings with Move before opening Spatter. Images and mixed artwork are not drawing targets. Nothing changed."
            }
        }
    }
    static func isInstruction(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter }
        return words.first == "move" && words.contains("drawings")
    }
    static func parse(_ text: String) throws -> Self {
        try SpatterGrammarSupport.checked(text)
        let pattern = #"\A\s*move\s+selected\s+drawings\s+by\s*\(\s*"# + SpatterGrammarSupport.percent + #"\s*,\s*"# + SpatterGrammarSupport.percent + #"\s*\)\.?\s*\z"#
        guard let (_, values) = try SpatterGrammarSupport.captures(text, patterns: [pattern]),
              let dx = SpatterGrammarSupport.number(values[0], in: -100...100),
              let dy = SpatterGrammarSupport.number(values[1], in: -100...100) else { throw Failure.unsupported }
        return .init(dxPercent: dx, dyPercent: dy)
    }
    func prepare(in context: StudioCommandContext, selectedElementIDs: Set<String>, requestID: UUID = UUID(),
                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StudioCommandRequest {
        try checkCancellation()
        guard SpatterGrammarSupport.requireSelection(selectedElementIDs, in: context) else { throw Failure.selection }
        // Multiply before dividing so whole-percent offsets land on the correctly
        // rounded pixel value (10% of 128 is exactly 12.8, not 12.8 + 1 ulp).
        let dx = dxPercent * Double(context.width) / 100, dy = dyPercent * Double(context.height) / 100
        try StudioElementTranslation(x: dx, y: dy).validate()
        return .init(requestID: requestID, projectID: context.projectID, expectedRevision: context.revision,
            action: .apply([.translateElements(.init(frame: .id(context.activeFrameID), elementIDs: selectedElementIDs.sorted(), dx: dx, dy: dy))]))
    }
}

/// "Scale selected drawings to 150% and rotate 45 degrees." Either clause alone is accepted.
struct SpatterSelectionTransformInstruction: Equatable {
    let scalePercent: Double
    let rotationDegrees: Double
    static let example = "Scale selected drawings to 150% and rotate 45 degrees."
    static let scaleExample = "Scale selected drawings to 50%."
    static let rotateExample = "Rotate selected drawings 90 degrees."
    enum Failure: LocalizedError {
        case unsupported, selection
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Use Scale selected drawings to 150% and rotate 45 degrees., Scale selected drawings to 50%., or Rotate selected drawings 90 degrees. Scale is 10–1,000% and rotation -180 to 180 degrees. Nothing changed."
            case .selection: return "Select 1–1,024 drawings or text boxes with Move before opening Spatter. Images and mixed artwork are not drawing targets. Nothing changed."
            }
        }
    }
    static func isInstruction(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter }
        return ["scale", "rotate"].contains(words.first.map(String.init) ?? "") && words.contains("drawings")
    }
    static func parse(_ text: String) throws -> Self {
        try SpatterGrammarSupport.checked(text)
        let patterns = [#"\A\s*scale\s+selected\s+drawings\s+to\s+"# + SpatterGrammarSupport.percent + #"\s+and\s+rotate\s+([^\s]+)\s+degrees?\.?\s*\z"#,
                        #"\A\s*scale\s+selected\s+drawings\s+to\s+"# + SpatterGrammarSupport.percent + #"\.?\s*\z"#,
                        #"\A\s*rotate\s+selected\s+drawings\s+(?:by\s+)?([^\s]+)\s+degrees?\.?\s*\z"#]
        guard let (index, values) = try SpatterGrammarSupport.captures(text, patterns: patterns) else { throw Failure.unsupported }
        switch index {
        case 0:
            guard let scale = SpatterGrammarSupport.number(values[0], in: 10...1000),
                  let rotation = SpatterGrammarSupport.number(values[1], in: -180...180) else { throw Failure.unsupported }
            return .init(scalePercent: scale, rotationDegrees: rotation)
        case 1:
            guard let scale = SpatterGrammarSupport.number(values[0], in: 10...1000) else { throw Failure.unsupported }
            return .init(scalePercent: scale, rotationDegrees: 0)
        default:
            guard let rotation = SpatterGrammarSupport.number(values[0], in: -180...180) else { throw Failure.unsupported }
            return .init(scalePercent: 100, rotationDegrees: rotation)
        }
    }
    func prepare(in context: StudioCommandContext, selectedElementIDs: Set<String>, requestID: UUID = UUID(),
                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StudioCommandRequest {
        try checkCancellation()
        guard SpatterGrammarSupport.requireSelection(selectedElementIDs, in: context) else { throw Failure.selection }
        let scale = scalePercent / 100
        return .init(requestID: requestID, projectID: context.projectID, expectedRevision: context.revision,
            action: .apply([.transformElements(.init(frame: .id(context.activeFrameID), elementIDs: selectedElementIDs.sorted(),
                scaleX: scale, scaleY: scale, rotation: rotationDegrees))]))
    }
}

/// "Flip selected drawings horizontally." Reflects around the group's combined bounds.
struct SpatterSelectionReflectInstruction: Equatable {
    let axis: StudioReflectionAxis
    static let horizontalExample = "Flip selected drawings horizontally."
    static let verticalExample = "Flip selected drawings vertically."
    enum Failure: LocalizedError {
        case unsupported, selection
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Use Flip selected drawings horizontally. or Flip selected drawings vertically. as one complete instruction. Nothing changed."
            case .selection: return "Select 1–1,024 drawings with Move before opening Spatter. Use the image flip instruction for a selected image. Nothing changed."
            }
        }
    }
    static func isInstruction(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter }
        return words.first == "flip" && words.contains("drawings")
    }
    static func parse(_ text: String) throws -> Self {
        try SpatterGrammarSupport.checked(text)
        guard let (_, values) = try SpatterGrammarSupport.captures(text, patterns: [#"\A\s*flip\s+selected\s+drawings\s+(horizontally|vertically)\.?\s*\z"#]) else { throw Failure.unsupported }
        return .init(axis: values[0].lowercased() == "horizontally" ? .horizontal : .vertical)
    }
    func prepare(in context: StudioCommandContext, selectedElementIDs: Set<String>, requestID: UUID = UUID(),
                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StudioCommandRequest {
        try checkCancellation()
        guard SpatterGrammarSupport.requireSelection(selectedElementIDs, in: context) else { throw Failure.selection }
        return .init(requestID: requestID, projectID: context.projectID, expectedRevision: context.revision,
            action: .apply([.reflectElements(.init(frame: .id(context.activeFrameID), elementIDs: selectedElementIDs.sorted(), axis: axis))]))
    }
}

/// "Rotate selected image clockwise." One quarter turn of the captured selected image.
struct SpatterImageRotationInstruction: Equatable {
    let direction: StudioImageQuarterTurn
    static let clockwiseExample = "Rotate selected image clockwise."
    static let counterclockwiseExample = "Rotate selected image counterclockwise."
    enum Failure: LocalizedError {
        case unsupported, invalidContext
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Use Rotate selected image clockwise. or Rotate selected image counterclockwise. as one complete instruction. Nothing changed."
            case .invalidContext: return "Select the image on its visible, unlocked active layer with Move before opening Spatter. Nothing changed."
            }
        }
    }
    static func isInstruction(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter }
        return words.first == "rotate" && words.contains("image")
    }
    static func parse(_ text: String) throws -> Self {
        try SpatterGrammarSupport.checked(text)
        guard let (_, values) = try SpatterGrammarSupport.captures(text, patterns: [#"\A\s*rotate\s+selected\s+image\s+(clockwise|counterclockwise|counter-clockwise|anticlockwise)\.?\s*\z"#]) else { throw Failure.unsupported }
        return .init(direction: values[0].lowercased() == "clockwise" ? .clockwise : .counterclockwise)
    }
    func prepare(in context: StudioCommandContext, frameID: String, layerID: String, assetID: String, requestID: UUID = UUID(),
                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StudioCommandRequest {
        try checkCancellation()
        guard SpatterGrammarSupport.requireImage(frameID: frameID, layerID: layerID, assetID: assetID, in: context) else { throw Failure.invalidContext }
        return .init(requestID: requestID, projectID: context.projectID, expectedRevision: context.revision,
            action: .apply([.rotateImage(.init(frame: .id(frameID), assetID: assetID, direction: direction, layer: .id(layerID)))]))
    }
}

/// "Crop selected image to (10%, 10%, 80%, 80%)." x, y, width, height of the upright source.
struct SpatterImageCropInstruction: Equatable {
    let crop: StudioImageCrop
    static let example = "Crop selected image to (10%, 10%, 80%, 80%)."
    enum Failure: LocalizedError {
        case unsupported, invalidContext
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Use Crop selected image to (10%, 10%, 80%, 80%). with x, y, width and height percentages of the original image; the rectangle must stay inside it and be at least 1% wide and high. Nothing changed."
            case .invalidContext: return "Select the image on its visible, unlocked active layer with Move before opening Spatter. Nothing changed."
            }
        }
    }
    static func isInstruction(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter }
        return words.first == "crop" && words.contains("image")
    }
    static func parse(_ text: String) throws -> Self {
        try SpatterGrammarSupport.checked(text)
        let p = SpatterGrammarSupport.percent
        let pattern = #"\A\s*crop\s+selected\s+image\s+to\s*\(\s*"# + p + #"\s*,\s*"# + p + #"\s*,\s*"# + p + #"\s*,\s*"# + p + #"\s*\)\.?\s*\z"#
        guard let (_, values) = try SpatterGrammarSupport.captures(text, patterns: [pattern]),
              let x = SpatterGrammarSupport.number(values[0], in: 0...100), let y = SpatterGrammarSupport.number(values[1], in: 0...100),
              let width = SpatterGrammarSupport.number(values[2], in: 1...100), let height = SpatterGrammarSupport.number(values[3], in: 1...100) else { throw Failure.unsupported }
        let crop = StudioImageCrop(x: x / 100, y: y / 100, width: width / 100, height: height / 100)
        do { try crop.validate() } catch { throw Failure.unsupported }
        return .init(crop: crop)
    }
    func prepare(in context: StudioCommandContext, frameID: String, layerID: String, assetID: String, requestID: UUID = UUID(),
                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StudioCommandRequest {
        try checkCancellation()
        guard SpatterGrammarSupport.requireImage(frameID: frameID, layerID: layerID, assetID: assetID, in: context) else { throw Failure.invalidContext }
        return .init(requestID: requestID, projectID: context.projectID, expectedRevision: context.revision,
            action: .apply([.cropImage(.init(frame: .id(frameID), assetID: assetID, crop: crop, layer: .id(layerID)))]))
    }
}

/// "Place selected image at (10%, 20%) with size (40%, 30%) and angle 25 degrees."
/// Canvas percentages; the complete unrotated box must fit inside the canvas.
struct SpatterImagePlacementInstruction: Equatable {
    let xPercent: Double, yPercent: Double, widthPercent: Double, heightPercent: Double
    let angleDegrees: Double?
    static let example = "Place selected image at (10%, 20%) with size (40%, 30%)."
    static let angleExample = "Place selected image at (10%, 20%) with size (40%, 30%) and angle 25 degrees."
    enum Failure: LocalizedError {
        case unsupported, invalidContext
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Use Place selected image at (10%, 20%) with size (40%, 30%). optionally followed by and angle 25 degrees. Position and size are canvas percentages; the box must stay inside the canvas with size 1–100% and angle -180 to 180. Nothing changed."
            case .invalidContext: return "Select the image on its visible, unlocked active layer with Move before opening Spatter. Nothing changed."
            }
        }
    }
    static func isInstruction(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter }
        return words.first == "place" && words.contains("image")
    }
    static func parse(_ text: String) throws -> Self {
        try SpatterGrammarSupport.checked(text)
        let p = SpatterGrammarSupport.percent
        let head = #"\A\s*place\s+selected\s+image\s+at\s*\(\s*"# + p + #"\s*,\s*"# + p + #"\s*\)\s+with\s+size\s*\(\s*"# + p + #"\s*,\s*"# + p + #"\s*\)"#
        let patterns = [head + #"\s+and\s+angle\s+([^\s]+)\s+degrees?\.?\s*\z"#, head + #"\.?\s*\z"#]
        guard let (index, values) = try SpatterGrammarSupport.captures(text, patterns: patterns),
              let x = SpatterGrammarSupport.number(values[0], in: 0...100), let y = SpatterGrammarSupport.number(values[1], in: 0...100),
              let width = SpatterGrammarSupport.number(values[2], in: 1...100), let height = SpatterGrammarSupport.number(values[3], in: 1...100),
              x + width <= 100.000001, y + height <= 100.000001 else { throw Failure.unsupported }
        var angle: Double?
        if index == 0 {
            guard let value = SpatterGrammarSupport.number(values[4], in: -180...180) else { throw Failure.unsupported }
            angle = value
        }
        return .init(xPercent: x, yPercent: y, widthPercent: width, heightPercent: height, angleDegrees: angle)
    }
    func placement(canvasWidth: Int, canvasHeight: Int) -> StudioRasterPlacement {
        let w = Double(canvasWidth), h = Double(canvasHeight)
        // Multiply first so whole-percent values round to the exact pixel literal.
        return .init(x: xPercent * w / 100, y: yPercent * h / 100, width: widthPercent * w / 100, height: heightPercent * h / 100)
    }
    func prepare(in context: StudioCommandContext, frameID: String, layerID: String, assetID: String, requestID: UUID = UUID(),
                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StudioCommandRequest {
        try checkCancellation()
        guard SpatterGrammarSupport.requireImage(frameID: frameID, layerID: layerID, assetID: assetID, in: context) else { throw Failure.invalidContext }
        return .init(requestID: requestID, projectID: context.projectID, expectedRevision: context.revision,
            action: .apply([.updateImagePlacement(.init(frame: .id(frameID), assetID: assetID,
                placement: placement(canvasWidth: context.width, canvasHeight: context.height), rotationDegrees: angleDegrees, layer: .id(layerID)))]))
    }
}

/// "Set selected text to \"Hello\" in #FF0000." Replaces content, keeps typography.
struct SpatterTextUpdateInstruction: Equatable {
    let content: String
    let colorHex: String?
    static let example = "Set selected text to \"Hello\"."
    static let colorExample = "Set selected text to \"Hello\" in #FF0000."
    enum Failure: LocalizedError {
        case unsupported, selection
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Use Set selected text to \"Hello\". or Set selected text to \"Hello\" in #FF0000. with one quoted text of 1–2,048 characters and an optional six-digit color. The quoted text is content, never another instruction. Nothing changed."
            case .selection: return "Select exactly one text box on a visible, unlocked layer with Move before opening Spatter. Nothing changed."
            }
        }
    }
    static func isInstruction(_ text: String) -> Bool {
        text.range(of: #"\A\s*set\s+selected\s+text\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
    static func parse(_ text: String) throws -> Self {
        try SpatterGrammarSupport.checked(text)
        let patterns = [#"\A\s*set\s+selected\s+text\s+to\s+"([^"\\]{1,2048})"\s+in\s+(#[0-9A-Fa-f]{6})\.?\s*\z"#,
                        #"\A\s*set\s+selected\s+text\s+to\s+"([^"\\]{1,2048})"\.?\s*\z"#]
        guard let (index, values) = try SpatterGrammarSupport.captures(text, patterns: patterns),
              !values[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, values[0].utf8.count <= StudioTextDescriptor.maximumBytes else { throw Failure.unsupported }
        return .init(content: values[0], colorHex: index == 0 ? values[1].uppercased() : nil)
    }
    func prepare(in context: StudioCommandContext, element: DrawnElement, requestID: UUID = UUID(),
                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StudioCommandRequest {
        try checkCancellation()
        guard element.tool == .text, var descriptor = element.text, let layerID = element.layerID,
              let layer = context.layers.first(where: { $0.id == layerID }),
              layer.visible, layer.opacity > 0, !layer.isFullyLocked, layer.lockMode == "free",
              let frame = context.frames.first(where: { $0.id == context.activeFrameID }), frame.elementCount > 0 else { throw Failure.selection }
        descriptor.content = content
        var updated = element; updated.text = descriptor
        do { try descriptor.validate(element: updated) } catch { throw Failure.unsupported }
        return .init(requestID: requestID, projectID: context.projectID, expectedRevision: context.revision,
            action: .apply([.updateText(.init(frame: .id(context.activeFrameID), elementID: element.id, text: descriptor,
                color: colorHex ?? element.color, opacity: element.opacity))]))
    }
}

// MARK: - Deterministic generation support (October 13, 2026)
//
// Everything below is Foundation-only and seeded, so the same brief and seed
// produce the same geometry on every platform. Coordinates are quantized to
// 1/64 canvas point before they become strokes, which keeps golden fingerprints
// stable across libm implementations.

/// SplitMix64. Not cryptographic; it only makes creative scatter reproducible.
struct SpatterDeterministicRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) / 9_007_199_254_740_992 }
    mutating func within(_ range: ClosedRange<Double>) -> Double { range.lowerBound + (range.upperBound - range.lowerBound) * unit() }
}

enum SpatterGeometry {
    /// 1/64 canvas point: finer than any renderer, coarse enough to absorb ulp drift.
    static func quantized(_ value: Double) -> Double { (value * 64).rounded() / 64 }
    static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash ^= UInt64(byte); hash &*= 0x0000_0100_0000_01b3 }
        return hash
    }
    static func smoothstep(_ t: Double) -> Double { let x = min(1, max(0, t)); return x * x * (3 - 2 * x) }
    static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
}

/// A generated primitive before it becomes a typed stroke. Lines use both
/// points; circles use them as the bounding square corners (Studio's circle tool).
struct SpatterPrimitive: Equatable {
    enum Kind: String { case line, circle }
    let kind: Kind
    let x0: Double, y0: Double, x1: Double, y1: Double
    let color: String
    let width: Double
    let opacity: Double
    init(kind: Kind, x0: Double, y0: Double, x1: Double, y1: Double, color: String, width: Double, opacity: Double) {
        self.kind = kind
        self.x0 = SpatterGeometry.quantized(x0); self.y0 = SpatterGeometry.quantized(y0)
        self.x1 = SpatterGeometry.quantized(x1); self.y1 = SpatterGeometry.quantized(y1)
        self.color = color; self.width = SpatterGeometry.quantized(width); self.opacity = (opacity * 1000).rounded() / 1000
    }
    static func circle(centerX: Double, centerY: Double, radius: Double, color: String, width: Double, opacity: Double = 1) -> SpatterPrimitive {
        .init(kind: .circle, x0: centerX - radius, y0: centerY - radius, x1: centerX + radius, y1: centerY + radius, color: color, width: width, opacity: opacity)
    }
    var tool: DrawingTool { kind == .line ? .line : .circle }
    func fits(width canvasWidth: Double, height canvasHeight: Double) -> Bool {
        let margin = width / 2
        return [x0, x1].allSatisfy { $0.isFinite && $0 >= margin && $0 <= canvasWidth - margin }
            && [y0, y1].allSatisfy { $0.isFinite && $0 >= margin && $0 <= canvasHeight - margin }
    }
    func stroke(id: String) -> StudioCommandStroke {
        .init(id: id, tool: tool, points: [.init(x: CGFloat(x0), y: CGFloat(y0)), .init(x: CGFloat(x1), y: CGFloat(y1))],
              color: color, width: width, opacity: opacity)
    }
    /// Canonical text used by golden-fingerprint tests.
    var canonical: String { "\(kind.rawValue) \(x0) \(y0) \(x1) \(y1) \(color) \(width) \(opacity)" }
    static func fingerprint(_ frames: [[SpatterPrimitive]]) -> UInt64 {
        SpatterGeometry.fnv1a(frames.map { $0.map(\.canonical).joined(separator: "|") }.joined(separator: "\n"))
    }
}

// MARK: - Blood and impact primitive (#280)

/// Deterministic splatter burst: streaks that fly from an origin along a
/// direction, fall under gravity, pool where they meet the ground and fade.
/// Palette values are a starting point; creative tuning is owner-managed.
struct SpatterImpactPrimitive: Equatable {
    enum Palette: String, CaseIterable, Codable {
        case blood, spark, dust
        var colors: [String] {
            switch self {
            case .blood: return ["#B3001B", "#8A0014", "#E3192E"]
            case .spark: return ["#FFD23F", "#FF8C1A", "#FFF2B3"]
            case .dust: return ["#8C8C8C", "#B5B5B5", "#5E5E5E"]
            }
        }
        /// Gravity in reference-scale units per second squared; sparks and dust hang longer.
        var gravity: Double { self == .blood ? 6 : 3 }
        var pools: Bool { self == .blood }
    }
    static let frameRange = 2...24
    let seed: UInt64
    let originX: Double, originY: Double
    /// Radians, 0 = +x; y grows downward, so −π/2 points up the canvas.
    let directionRadians: Double
    let intensity: Double
    let palette: Palette
    let frameCount: Int
    let fps: Int
    /// Reference size in canvas points (a figure's height); speeds scale with it.
    let scale: Double
    /// Pooling baseline in canvas points; nil disables pooling.
    let groundY: Double?

    enum Failure: LocalizedError {
        case invalid
        var errorDescription: String? { "Impact primitives need a finite origin, 2–24 frames, 1–60 FPS, intensity 0–100% and a positive scale. Nothing changed." }
    }

    func validate() throws {
        guard originX.isFinite, originY.isFinite, directionRadians.isFinite, intensity.isFinite, (0...1).contains(intensity),
              Self.frameRange.contains(frameCount), (1...60).contains(fps), scale.isFinite, scale > 0,
              groundY.map(\.isFinite) ?? true else { throw Failure.invalid }
    }

    /// Per-frame primitives, clipped to the canvas. Deterministic for a seed.
    func frames(canvasWidth: Int, canvasHeight: Int, lineWidth: Double) throws -> [[SpatterPrimitive]] {
        try validate()
        guard canvasWidth >= 16, canvasHeight >= 16, lineWidth.isFinite, (0.1...1024).contains(lineWidth) else { throw Failure.invalid }
        var random = SpatterDeterministicRandom(seed: seed)
        struct Particle { let angle: Double; let speed: Double; let color: String; let width: Double; var landedAt: (x: Double, frame: Int)? }
        let count = Int((8 + intensity * 16).rounded())
        let halfSpread = 0.35 + 0.25 * (1 - intensity)
        var particles: [Particle] = (0..<count).map { index in
            Particle(angle: directionRadians + random.within(-halfSpread...halfSpread),
                     speed: scale * random.within(1.2...3.2) * (0.5 + 0.8 * intensity),
                     color: palette.colors[index % palette.colors.count],
                     width: lineWidth * random.within(0.6...1.4), landedAt: nil)
        }
        let width = Double(canvasWidth), height = Double(canvasHeight), gravity = palette.gravity * scale
        // The widest streak is 1.4× the line width; clamp with that half-width so
        // every clamped endpoint still passes `fits` for its own stroke.
        let margin = lineWidth * 0.7
        func clamp(_ x: Double, _ y: Double) -> (Double, Double) {
            (min(width - margin, max(margin, x)), min(height - margin, max(margin, y)))
        }
        func position(_ particle: Particle, at seconds: Double) -> (Double, Double) {
            (originX + cos(particle.angle) * particle.speed * seconds,
             originY + sin(particle.angle) * particle.speed * seconds + 0.5 * gravity * seconds * seconds)
        }
        var output: [[SpatterPrimitive]] = []
        let dt = 1 / Double(fps)
        for frame in 0..<frameCount {
            let now = Double(frame + 1) * dt, before = Double(frame) * dt
            let fade = 1 - 0.6 * Double(frame) / Double(max(1, frameCount - 1))
            var primitives: [SpatterPrimitive] = []
            if frame < 2 {
                // Central burst: six short rays around the impact point.
                let radius = scale * (frame == 0 ? 0.08 : 0.16)
                for ray in 0..<6 {
                    let angle = Double(ray) * .pi / 3 + directionRadians
                    let (ax, ay) = clamp(originX + cos(angle) * radius * 0.4, originY + sin(angle) * radius * 0.4)
                    let (bx, by) = clamp(originX + cos(angle) * radius, originY + sin(angle) * radius)
                    if ax != bx || ay != by {
                        primitives.append(.init(kind: .line, x0: ax, y0: ay, x1: bx, y1: by, color: palette.colors[0], width: lineWidth * 1.2, opacity: 1))
                    }
                }
            }
            for index in particles.indices {
                if let landed = particles[index].landedAt {
                    guard palette.pools, let groundY else { continue }
                    let age = Double(frame - landed.frame)
                    let radius = lineWidth * min(1.6, 0.5 + 0.25 * age)
                    let (px, py) = clamp(landed.x, groundY - radius)
                    primitives.append(.circle(centerX: px, centerY: py, radius: radius, color: particles[index].color, width: lineWidth * 0.8, opacity: max(0.35, fade)))
                    continue
                }
                var (sx, sy) = position(particles[index], at: before)
                var (ex, ey) = position(particles[index], at: now)
                if let groundY, ey >= groundY {
                    particles[index].landedAt = (ex, frame); ey = groundY
                    if sy > groundY { sy = groundY }
                }
                (sx, sy) = clamp(sx, sy); (ex, ey) = clamp(ex, ey)
                guard sx != ex || sy != ey else { continue }
                primitives.append(.init(kind: .line, x0: sx, y0: sy, x1: ex, y1: ey, color: particles[index].color, width: particles[index].width, opacity: fade))
            }
            output.append(primitives)
        }
        return output
    }
}

// MARK: - Stick-figure action vocabulary and pose generator (#206)

/// Actions a brief clause may name. Terminal actions end the actor's motion.
enum SpatterBriefAction: String, CaseIterable, Codable {
    case walk, run, jump, wave, fall, punch, kick, sit, duck, `throw`, explode
    static let verbs: [String: SpatterBriefAction] = [
        "walk": .walk, "walks": .walk, "walking": .walk, "run": .run, "runs": .run, "running": .run,
        "jump": .jump, "jumps": .jump, "jumping": .jump, "wave": .wave, "waves": .wave, "waving": .wave,
        "fall": .fall, "falls": .fall, "falling": .fall, "punch": .punch, "punches": .punch, "punching": .punch,
        "kick": .kick, "kicks": .kick, "kicking": .kick, "sit": .sit, "sits": .sit, "sitting": .sit,
        "duck": .duck, "ducks": .duck, "ducking": .duck, "throw": .throw, "throws": .throw, "throwing": .throw,
        "explode": .explode, "explodes": .explode, "exploding": .explode
    ]
    /// Canvas percent per second along the facing direction.
    var speedPercentPerSecond: Double {
        switch self { case .walk: return 20; case .run: return 40; case .jump: return 10; default: return 0 }
    }
    /// After these the actor stays down or is gone; later clauses are rejected.
    var isTerminal: Bool { self == .fall || self == .explode }
    var strideCyclesPerSecond: Double { self == .run ? 2.5 : 1.5 }
}

/// Builds editable stick-figure poses: nine limb/torso lines and one head circle,
/// with constant bone lengths through two-bone inverse kinematics. Offsets are in
/// figure heights; x offsets follow `facing`, y grows downward.
struct SpatterStickPoseGenerator {
    struct Point: Equatable { var x: Double; var y: Double }
    struct Pose: Equatable {
        var hip = Point(x: 0, y: -0.44), shoulder = Point(x: 0, y: -0.72), head = Point(x: 0, y: -0.865)
        var footBack = Point(x: -0.10, y: -0.02), footFront = Point(x: 0.10, y: -0.02)
        var handBack = Point(x: -0.10, y: -0.43), handFront = Point(x: 0.10, y: -0.43)
        static let standing = Pose()
        func mixed(with other: Pose, _ t: Double) -> Pose {
            func m(_ a: Point, _ b: Point) -> Point { .init(x: SpatterGeometry.mix(a.x, b.x, t), y: SpatterGeometry.mix(a.y, b.y, t)) }
            return .init(hip: m(hip, other.hip), shoulder: m(shoulder, other.shoulder), head: m(head, other.head),
                         footBack: m(footBack, other.footBack), footFront: m(footFront, other.footFront),
                         handBack: m(handBack, other.handBack), handFront: m(handFront, other.handFront))
        }
    }
    static let legBone = 0.25, armBone = 0.20, headRadius = 0.095
    let height: Double
    let lineWidth: Double
    let color: String
    let facing: Double

    enum Failure: LocalizedError {
        case bounds
        var errorDescription: String? { "The planned figure does not fit the canvas in every frame. Use a larger canvas or a shorter travel. Nothing changed." }
    }

    /// Keyframed poses for the non-cyclic actions, t in 0...1 within the clause.
    static func keyframes(_ action: SpatterBriefAction) -> [(Double, Pose)] {
        let stand = Pose.standing
        switch action {
        case .jump:
            let crouch = Pose(hip: .init(x: 0, y: -0.34), shoulder: .init(x: 0.02, y: -0.60), head: .init(x: 0.03, y: -0.745),
                              handBack: .init(x: -0.16, y: -0.36), handFront: .init(x: -0.12, y: -0.38))
            let apex = Pose(hip: .init(x: 0, y: -0.79), shoulder: .init(x: 0, y: -1.07), head: .init(x: 0, y: -1.215),
                            footBack: .init(x: -0.06, y: -0.32), footFront: .init(x: 0.08, y: -0.34),
                            handBack: .init(x: -0.14, y: -1.10), handFront: .init(x: 0.14, y: -1.12))
            return [(0, stand), (0.25, crouch), (0.5, apex), (0.75, crouch), (1, stand)]
        case .fall:
            let lean = Pose(hip: .init(x: -0.05, y: -0.42), shoulder: .init(x: -0.25, y: -0.65), head: .init(x: -0.33, y: -0.78),
                            footBack: .init(x: -0.10, y: -0.02), footFront: .init(x: 0.15, y: -0.02),
                            handBack: .init(x: -0.35, y: -0.55), handFront: .init(x: -0.05, y: -0.75))
            let down = Pose(hip: .init(x: -0.25, y: -0.12), shoulder: .init(x: -0.52, y: -0.14), head: .init(x: -0.68, y: -0.16),
                            footBack: .init(x: 0, y: -0.02), footFront: .init(x: 0.12, y: -0.04),
                            handBack: .init(x: -0.75, y: -0.10), handFront: .init(x: -0.45, y: -0.25))
            let lying = Pose(hip: .init(x: -0.28, y: -0.08), shoulder: .init(x: -0.56, y: -0.08), head: .init(x: -0.72, y: -0.11),
                             footBack: .init(x: 0.05, y: -0.02), footFront: .init(x: 0.15, y: -0.02),
                             handBack: .init(x: -0.80, y: -0.04), handFront: .init(x: -0.50, y: -0.12))
            return [(0, stand), (0.3, lean), (0.65, down), (0.8, lying), (1, lying)]
        case .punch:
            let stance = Pose(hip: .init(x: 0, y: -0.44), shoulder: .init(x: 0.02, y: -0.72), head: .init(x: 0.03, y: -0.865),
                              footBack: .init(x: -0.16, y: -0.02), footFront: .init(x: 0.16, y: -0.02),
                              handBack: .init(x: 0.08, y: -0.70), handFront: .init(x: 0.12, y: -0.66))
            var windup = stance; windup.handFront = .init(x: -0.12, y: -0.70); windup.shoulder = .init(x: -0.02, y: -0.72)
            var extended = stance
            extended.hip = .init(x: 0.05, y: -0.44); extended.shoulder = .init(x: 0.10, y: -0.72); extended.head = .init(x: 0.11, y: -0.865)
            extended.handFront = .init(x: 0.46, y: -0.72); extended.handBack = .init(x: 0.05, y: -0.70)
            return [(0, stance), (0.3, windup), (0.5, extended), (0.7, extended), (1, stance)]
        case .kick:
            let stance = Pose(footBack: .init(x: -0.12, y: -0.02), footFront: .init(x: 0.12, y: -0.02))
            var chamber = stance; chamber.footFront = .init(x: 0.14, y: -0.38)
            chamber.handBack = .init(x: -0.20, y: -0.60); chamber.handFront = .init(x: 0.20, y: -0.62)
            var extended = chamber; extended.footFront = .init(x: 0.45, y: -0.50)
            extended.hip = .init(x: -0.02, y: -0.44); extended.shoulder = .init(x: -0.04, y: -0.70); extended.head = .init(x: -0.05, y: -0.845)
            extended.handBack = .init(x: -0.25, y: -0.62); extended.handFront = .init(x: 0.22, y: -0.66)
            return [(0, stance), (0.3, chamber), (0.5, extended), (0.65, extended), (1, stance)]
        case .sit:
            let seated = Pose(hip: .init(x: -0.06, y: -0.26), shoulder: .init(x: -0.08, y: -0.54), head: .init(x: -0.08, y: -0.685),
                              footBack: .init(x: 0.16, y: -0.02), footFront: .init(x: 0.22, y: -0.02),
                              handBack: .init(x: 0.10, y: -0.30), handFront: .init(x: 0.14, y: -0.30))
            return [(0, stand), (0.4, seated), (1, seated)]
        case .duck:
            let crouch = Pose(hip: .init(x: 0, y: -0.26), shoulder: .init(x: 0.04, y: -0.46), head: .init(x: 0.06, y: -0.60),
                              footBack: .init(x: -0.14, y: -0.02), footFront: .init(x: 0.14, y: -0.02),
                              handBack: .init(x: -0.06, y: -0.66), handFront: .init(x: 0.16, y: -0.66))
            return [(0, stand), (0.3, crouch), (0.7, crouch), (1, stand)]
        case .throw:
            var windup = stand; windup.handFront = .init(x: -0.22, y: -1.02); windup.shoulder = .init(x: -0.03, y: -0.72); windup.handBack = .init(x: 0.15, y: -0.72)
            var release = stand; release.handFront = .init(x: 0.40, y: -0.90); release.shoulder = .init(x: 0.06, y: -0.72)
            release.head = .init(x: 0.08, y: -0.865); release.handBack = .init(x: 0, y: -0.55)
            var follow = stand; follow.handFront = .init(x: 0.35, y: -0.45); follow.shoulder = .init(x: 0.08, y: -0.70); follow.head = .init(x: 0.09, y: -0.845)
            return [(0, stand), (0.35, windup), (0.5, release), (0.75, follow), (1, stand)]
        case .walk, .run, .wave, .explode:
            return [(0, stand), (1, stand)]
        }
    }

    /// Pose at clause progress `t`. `seconds` is the clause length (cycle count).
    static func pose(_ action: SpatterBriefAction, t: Double, seconds: Double) -> Pose {
        let t = min(1, max(0, t))
        switch action {
        case .walk, .run:
            let cycles = max(1, (seconds * action.strideCyclesPerSecond).rounded())
            let phase = t * .pi * 2 * cycles
            // Stride 0.15 keeps hip→foot within the two 0.25 leg bones; running arms
            // swing less and ride higher (bent elbows) so they stay within reach of
            // the leaned shoulder.
            let strideAmplitude = 0.15, liftAmplitude = action == .run ? 0.16 : 0.10
            let armAmplitude = action == .run ? 0.12 : 0.15, handHeight = action == .run ? -0.55 : -0.43
            var pose = Pose.standing
            let bob = cos(phase * 2) * 0.012
            pose.hip.y += bob; pose.shoulder.y += bob; pose.head.y += bob
            if action == .run { pose.shoulder.x += 0.06; pose.head.x += 0.08 }
            func leg(_ gait: Double) -> Point { .init(x: sin(gait) * strideAmplitude, y: -0.02 - max(0, cos(gait)) * liftAmplitude) }
            func arm(_ gait: Double) -> Point { .init(x: -sin(gait) * armAmplitude, y: handHeight + cos(gait) * 0.025) }
            pose.footBack = leg(phase + .pi); pose.footFront = leg(phase)
            pose.footBack.x -= 0.10; pose.footFront.x += 0.10
            pose.handBack = arm(phase + .pi); pose.handFront = arm(phase)
            pose.handBack.x -= 0.10; pose.handFront.x += 0.10
            return pose
        case .wave:
            var pose = Pose.standing
            pose.handFront = .init(x: 0.25 + sin(t * .pi * 4) * 0.06, y: -0.92 + cos(t * .pi * 4) * 0.025)
            return pose
        case .explode:
            return .standing
        default:
            let keys = keyframes(action)
            for index in 1..<keys.count where t <= keys[index].0 {
                let (t0, a) = keys[index - 1], (t1, b) = keys[index]
                let local = t1 > t0 ? SpatterGeometry.smoothstep((t - t0) / (t1 - t0)) : 1
                return a.mixed(with: b, local)
            }
            return keys.last!.1
        }
    }

    /// Two-bone joint between root and tip with fixed bone length; `bend` picks the side.
    private func joint(_ root: Point, _ tip: Point, length: Double, bend: Double) throws -> Point {
        let dx = tip.x - root.x, dy = tip.y - root.y
        let distance = max(0.000001, (dx * dx + dy * dy).squareRoot())
        guard distance <= length * 2 + 0.000001 else { throw Failure.bounds }
        let offset = max(0, length * length - (distance / 2) * (distance / 2)).squareRoot()
        return .init(x: root.x + dx * 0.5 - dy / distance * offset * bend, y: root.y + dy * 0.5 + dx / distance * offset * bend)
    }

    /// Nine lines (torso, 2×2 legs, 2×2 arms) then the head circle, anchored at the
    /// feet baseline `(x, y)` in canvas points.
    func primitives(_ pose: Pose, x: Double, y: Double) throws -> [SpatterPrimitive] {
        func p(_ point: Point) -> Point { .init(x: x + point.x * height * facing, y: y + point.y * height) }
        let hip = p(pose.hip), shoulder = p(pose.shoulder), head = p(pose.head)
        let neck = Point(x: shoulder.x + (head.x - shoulder.x) * 0.35, y: shoulder.y + (head.y - shoulder.y) * 0.35)
        var segments: [(Point, Point)] = [(hip, neck)]
        for foot in [p(pose.footBack), p(pose.footFront)] {
            let knee = try joint(hip, foot, length: height * Self.legBone, bend: -facing)
            segments += [(hip, knee), (knee, foot)]
        }
        for (hand, side) in [(p(pose.handBack), -1.0), (p(pose.handFront), 1.0)] {
            let elbow = try joint(shoulder, hand, length: height * Self.armBone, bend: side * facing)
            segments += [(shoulder, elbow), (elbow, hand)]
        }
        var result = segments.map { SpatterPrimitive(kind: .line, x0: $0.0.x, y0: $0.0.y, x1: $0.1.x, y1: $0.1.y, color: color, width: lineWidth, opacity: 1) }
        result.append(.circle(centerX: head.x, centerY: head.y, radius: height * Self.headRadius, color: color, width: lineWidth))
        return result
    }
}

// MARK: - Storyboard (#214)

/// Human-readable, machine-checkable plan for a generated scene. Attached to
/// render reviews beside the source-project digest so the owner approves what
/// was planned and exactly what was rendered.
struct SpatterStoryboard: Codable, Equatable {
    static let schema = "spatter_storyboard"
    struct Clause: Codable, Equatable {
        let action: String
        let direction: String?
        let startTick: Int
        let ticks: Int
        let travelPercent: Double
    }
    struct Actor: Codable, Equatable {
        let index: Int
        let color: String
        let layerName: String
        let startXPercent: Double
        let facing: Int
        let clauses: [Clause]
    }
    var schema = SpatterStoryboard.schema
    var version = 1
    let brief: String
    let seed: UInt64
    let fps: Int
    let totalTicks: Int
    let poseHoldTicks: Int
    let frameCount: Int
    let generatedElementCount: Int
    let actors: [Actor]
    var durationSeconds: Double { Double(totalTicks) / Double(max(1, fps)) }
    func json() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

/// Canonical bytes of an editable document: the input to the review digest.
/// Any change to frames, layers, audio or settings changes the digest.
enum SpatterProjectDigest {
    static func canonicalData(_ document: StudioDocument) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(document)
    }
}

// MARK: - Multi-clause brief planner (#206)

/// General brief grammar, superset of the two historical brief forms:
///
///   A red stick figure walks left to right for 1 second, then punches, then falls;
///   a blue stick figure runs right to left, then ducks; 3 seconds; seed 7.
///
/// Up to three actors separated by `;`, up to six clauses per actor joined with
/// `, then`, optional per-clause `for N seconds`, optional total duration
/// (default 2 seconds) and optional `seed N`. Every pose is generated per tick;
/// when the element budget would be exceeded the planner holds each pose for
/// 2–4 ticks and says so, and refuses longer briefs instead of flattening them.
struct SpatterMultiClauseBrief: Equatable {
    struct Clause: Equatable {
        let action: SpatterBriefAction
        /// +1 left→right, −1 right→left, nil keeps the actor's facing.
        let direction: Int?
        let seconds: Double?
    }
    struct Actor: Equatable { let color: String; let clauses: [Clause] }
    let actors: [Actor]
    let seconds: Double
    let seed: UInt64
    let normalized: String
    static let maximumActors = 3, maximumClauses = 6
    static let secondsRange = 0.5...60.0
    static let example = "A red stick figure walks left to right for 1 second, then punches, then falls; 3 seconds."
    static let twoActorExample = "A red stick figure runs left to right, then kicks; a blue stick figure ducks, then jumps; 2.5 seconds."
    static let explosionExample = "A black stick figure walks left to right, then explodes; 2 seconds; seed 7."

    enum Failure: LocalizedError, Equatable {
        case syntax(String), timing, actors, terminal, budget(Int), bounds
        var errorDescription: String? {
            switch self {
            case .syntax(let detail): return "Use: \(SpatterMultiClauseBrief.example) Actions: walks, runs, jumps, waves, falls, punches, kicks, sits, ducks, throws, explodes; directions left to right / right to left; up to three actors separated by semicolons. \(detail) Nothing changed."
            case .timing: return "Choose 0.5–60 seconds in total and per-clause durations that fit inside it, covering at least one project tick each. Nothing changed."
            case .actors: return "Briefs support one to three stick figures with one to six actions each. Nothing changed."
            case .terminal: return "After falls or explodes an actor stays down; put those last. Nothing changed."
            case .budget(let seconds): return "This brief needs more editable geometry than one edit may create. At this frame rate and actor count the longest supported brief is about \(seconds) seconds; split it into two edits. Nothing changed."
            case .bounds: return "The planned figures do not fit this canvas. Use a larger or wider canvas. Nothing changed."
            }
        }
    }

    static func isBrief(_ text: String) -> Bool {
        text.range(of: #"\A\s*(?:(?:a|an|the)\s+)?(?:two|three|[^\s;:]+)\s+stick\s+figures?\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static let namedColors = ["red": "#FF0000", "green": "#00FF00", "blue": "#0000FF", "black": "#000000", "white": "#FFFFFF",
                                      "yellow": "#FFFF00", "cyan": "#00FFFF", "magenta": "#FF00FF", "orange": "#FF8000", "purple": "#800080"]
    static func color(_ token: String) -> String? {
        if let named = namedColors[token.lowercased()] { return named }
        let bytes = Array(token.utf8)
        guard bytes.count == 7, bytes[0] == 35, bytes.dropFirst().allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        return token.uppercased()
    }

    static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= SpatterMotionRecipe.maximumInstructionBytes else { throw SpatterMotionRecipe.RecipeError.instructionTooLong }
        guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0) }) else { throw Failure.syntax("Control characters are not allowed.") }
        var body = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasSuffix(".") { body.removeLast() }
        body = body.trimmingCharacters(in: .whitespaces)
        // Optional "Two stick figures:" / "Three stick figures:" header.
        if let match = body.range(of: #"\A(?:two|three)\s+stick\s+figures\s*:\s*"#, options: [.regularExpression, .caseInsensitive]) {
            body = String(body[match.upperBound...])
        }
        var segments = body.split(separator: ";", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard !segments.isEmpty, segments.allSatisfy({ !$0.isEmpty }) else { throw Failure.syntax("Separate actors with single semicolons.") }
        var seconds: Double?
        var seed: UInt64?
        let durationPattern = try NSRegularExpression(pattern: #"\A([0-9]+(?:\.[0-9]+)?)\s+seconds?\z"#, options: [.caseInsensitive])
        let seedPattern = try NSRegularExpression(pattern: #"\Aseed\s+([0-9]{1,18})\z"#, options: [.caseInsensitive])
        while let last = segments.last {
            let range = NSRange(last.startIndex..., in: last)
            if seconds == nil, let match = durationPattern.firstMatch(in: last, range: range), let captured = Range(match.range(at: 1), in: last) {
                guard let value = Double(last[captured]), value.isFinite, secondsRange.contains(value) else { throw Failure.timing }
                seconds = value; segments.removeLast(); continue
            }
            if seed == nil, let match = seedPattern.firstMatch(in: last, range: range), let captured = Range(match.range(at: 1), in: last), let value = UInt64(last[captured]) {
                seed = value; segments.removeLast(); continue
            }
            break
        }
        guard (1...maximumActors).contains(segments.count) else { throw Failure.actors }
        let actorPattern = try NSRegularExpression(pattern: #"\A(?:(?:a|an|the)\s+)?([^\s]+)\s+(?:stick\s+figure\s+)?(.+)\z"#, options: [.caseInsensitive])
        let clausePattern = try NSRegularExpression(pattern: #"\A([a-z]+)(?:\s+(left\s+to\s+right|right\s+to\s+left))?(?:\s+for\s+([0-9]+(?:\.[0-9]+)?)\s+seconds?)?\z"#, options: [.caseInsensitive])
        var actors: [Actor] = []
        for segment in segments {
            guard let match = actorPattern.firstMatch(in: segment, range: NSRange(segment.startIndex..., in: segment)),
                  let colorRange = Range(match.range(at: 1), in: segment), let rest = Range(match.range(at: 2), in: segment),
                  let color = color(String(segment[colorRange])) else { throw Failure.syntax("Each actor starts with a named or #RRGGBB color.") }
            let clauseTexts = String(segment[rest]).replacingOccurrences(of: #"\s*,\s*then\s+|\s+then\s+|\s*,\s*"#, with: "\u{1F}", options: .regularExpression)
                .split(separator: "\u{1F}").map { $0.trimmingCharacters(in: .whitespaces) }
            guard (1...maximumClauses).contains(clauseTexts.count) else { throw Failure.actors }
            var clauses: [Clause] = []
            for clauseText in clauseTexts {
                guard let clause = clausePattern.firstMatch(in: clauseText, range: NSRange(clauseText.startIndex..., in: clauseText)),
                      let verbRange = Range(clause.range(at: 1), in: clauseText),
                      let action = SpatterBriefAction.verbs[clauseText[verbRange].lowercased()] else { throw Failure.syntax("Unsupported clause: \u{201C}\(clauseText.prefix(40))\u{201D}.") }
                var direction: Int?
                if let range = Range(clause.range(at: 2), in: clauseText) { direction = clauseText[range].lowercased().hasPrefix("left") ? 1 : -1 }
                var clauseSeconds: Double?
                if let range = Range(clause.range(at: 3), in: clauseText) {
                    guard let value = Double(clauseText[range]), value.isFinite, value > 0, value <= secondsRange.upperBound else { throw Failure.timing }
                    clauseSeconds = value
                }
                if let previous = clauses.last, previous.action.isTerminal { throw Failure.terminal }
                clauses.append(.init(action: action, direction: direction, seconds: clauseSeconds))
            }
            actors.append(.init(color: color, clauses: clauses))
        }
        let total = seconds ?? 2
        for actor in actors {
            let explicit = actor.clauses.compactMap(\.seconds).reduce(0, +)
            guard explicit <= total + 0.000001 else { throw Failure.timing }
        }
        let normalized = body.lowercased()
        return .init(actors: actors, seconds: total, seed: seed ?? SpatterGeometry.fnv1a(normalized), normalized: normalized)
    }

    struct Plan {
        let prepared: SpatterMotionRecipe.Prepared
        let storyboard: SpatterStoryboard
        let generatedLayerAliases: [String]
    }

    /// Lays out actors in lanes, assigns ticks to clauses, picks the pose hold,
    /// generates every frame, merges identical consecutive poses into held frames
    /// and emits one typed request: `addLayer` per actor, one `appendFrames`,
    /// then `selectFrame`.
    func prepare(in context: StudioCommandContext, requestID: UUID = UUID(),
                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> Plan {
        try checkCancellation()
        guard (16...4096).contains(context.width), (16...4096).contains(context.height), (1...60).contains(context.fps),
              context.revision >= 0, context.supportedTools.contains(.line), context.supportedTools.contains(.circle),
              context.layers.count + actors.count <= 128, context.frames.contains(where: { $0.id == context.activeFrameID }),
              let last = context.frames.last else { throw SpatterStickFigureRecipe.Failure.context }
        let totalTicks = Int((seconds * Double(context.fps)).rounded())
        guard totalTicks >= 1 else { throw Failure.timing }
        let width = Double(context.width), height = Double(context.height)
        let figureHeight = Double(min(context.width, context.height)) * (actors.count == 1 ? 0.35 : 0.28)
        let lineWidth = 3.0, baselineY = height * 0.8
        let lanes: [Double] = actors.count == 1 ? [50] : actors.count == 2 ? [30, 70] : [20, 50, 80]

        // Tick allocation per clause: explicit seconds first, the rest shared
        // evenly; an actor whose clauses end early holds its last clause.
        struct Timed { let clause: Clause; let startTick: Int; var ticks: Int }
        var timelines: [[Timed]] = []
        for actor in actors {
            let explicitTicks = actor.clauses.map { $0.seconds.map { Int(($0 * Double(context.fps)).rounded()) } }
            let used = explicitTicks.compactMap { $0 }.reduce(0, +)
            guard used <= totalTicks else { throw Failure.timing }
            var remaining = totalTicks - used
            var timed: [Timed] = []
            var cursor = 0
            for (index, clause) in actor.clauses.enumerated() {
                let ticks: Int
                if let explicit = explicitTicks[index] { ticks = explicit }
                else {
                    let openLeft = explicitTicks[index...].filter { $0 == nil }.count
                    ticks = remaining / openLeft + (remaining % openLeft > 0 ? 1 : 0)
                    remaining -= ticks
                }
                guard ticks >= 1 else { throw Failure.timing }
                timed.append(.init(clause: clause, startTick: cursor, ticks: ticks)); cursor += ticks
            }
            if cursor < totalTicks { timed[timed.count - 1].ticks += totalTicks - cursor }
            timelines.append(timed)
        }

        // Lane placement and travel, clamped so the figure's reach stays on canvas.
        struct Placement { let startX: Double; let facing: Double; let travel: [Double] }
        var placements: [Placement] = []
        let reach = figureHeight * 0.85 + lineWidth
        let minX = max(width * 0.12, reach), maxX = min(width * 0.88, width - reach)
        guard minX < maxX, baselineY - figureHeight * 1.32 >= lineWidth else { throw Failure.bounds }
        for (index, timeline) in timelines.enumerated() {
            let initialFacing = timeline.first(where: { $0.clause.direction != nil })?.clause.direction.map(Double.init) ?? 1
            var x = width * lanes[index] / 100
            if let firstTravel = timeline.first(where: { $0.clause.action.speedPercentPerSecond > 0 }) {
                x -= Double(firstTravel.clause.direction ?? Int(initialFacing)) * width * 0.15
            }
            x = min(maxX, max(minX, x))
            var facing = initialFacing, cursor = x, travel: [Double] = []
            for timed in timeline {
                if let direction = timed.clause.direction { facing = Double(direction) }
                let wanted = facing * width * timed.clause.action.speedPercentPerSecond / 100 * Double(timed.ticks) / Double(context.fps)
                let end = min(maxX, max(minX, cursor + wanted))
                travel.append(end - cursor); cursor = end
            }
            placements.append(.init(startX: x, facing: initialFacing, travel: travel))
        }

        // Pose hold: one pose per tick unless the element budget forces 2–4 ticks.
        let clauses = actors.flatMap(\.clauses)
        let perFrameEstimate = actors.count * 10 + (clauses.contains { $0.action == .explode } ? 40 : 0) + (clauses.contains { $0.action == .throw } ? 1 : 0)
        let elementBudget = StudioCommandExecutor.maximumGeneratedElements - 16
        var hold = 1
        while hold <= 4 {
            let frames = (totalTicks + hold - 1) / hold
            if frames <= StudioCommandExecutor.maximumAppendedFrames, frames * perFrameEstimate <= elementBudget,
               context.frames.count + frames <= 1000 { break }
            hold += 1
        }
        guard hold <= 4 else {
            let maxFrames = min(StudioCommandExecutor.maximumAppendedFrames, elementBudget / max(1, perFrameEstimate))
            throw Failure.budget(max(1, Int(Double(maxFrames * 4) / Double(context.fps))))
        }
        let sampledFrameCount = (totalTicks + hold - 1) / hold

        var storyboardActors: [SpatterStoryboard.Actor] = []
        for (actorIndex, timeline) in timelines.enumerated() {
            let placement = placements[actorIndex]
            storyboardActors.append(.init(index: actorIndex + 1, color: actors[actorIndex].color,
                layerName: "Spatter actor \(actorIndex + 1) · " + timeline.map { $0.clause.action.rawValue }.joined(separator: ", "),
                startXPercent: SpatterGeometry.quantized(placement.startX / width * 100), facing: Int(placement.facing),
                clauses: timeline.enumerated().map { index, timed in
                    .init(action: timed.clause.action.rawValue, direction: timed.clause.direction.map { $0 > 0 ? "left to right" : "right to left" },
                          startTick: timed.startTick, ticks: timed.ticks, travelPercent: SpatterGeometry.quantized(placement.travel[index] / width * 100))
                }))
        }

        var random = SpatterDeterministicRandom(seed: seed)
        var explosions: [Int: [[SpatterPrimitive]]] = [:]
        var fragments: [Int: [(angle: Double, speed: Double, spin: Double, length: Double)]] = [:]
        struct Draft: Equatable { var holdTicks: Int; let actors: [Int: [SpatterPrimitive]] }
        var drafts: [Draft] = []
        let margin = lineWidth / 2
        func clamp(_ x: Double, _ y: Double) -> (Double, Double) { (min(width - margin, max(margin, x)), min(height - margin, max(margin, y))) }
        for frameIndex in 0..<sampledFrameCount {
            try checkCancellation()
            let tick = frameIndex * hold
            let holdTicks = min(hold, totalTicks - tick)
            var frameActors: [Int: [SpatterPrimitive]] = [:]
            for (actorIndex, timeline) in timelines.enumerated() {
                let actor = actors[actorIndex], placement = placements[actorIndex]
                guard let clauseIndex = timeline.lastIndex(where: { $0.startTick <= tick }) else { continue }
                let timed = timeline[clauseIndex], action = timed.clause.action
                let clauseTick = min(tick - timed.startTick, timed.ticks - 1)
                let progress = timed.ticks > 1 ? Double(clauseTick) / Double(timed.ticks - 1) : 1
                var facing = placement.facing, x = placement.startX
                for index in 0..<clauseIndex {
                    x += placement.travel[index]
                    if let direction = timeline[index].clause.direction { facing = Double(direction) }
                }
                if let direction = timed.clause.direction { facing = Double(direction) }
                let clauseSeconds = Double(timed.ticks) / Double(context.fps)
                let generator = SpatterStickPoseGenerator(height: figureHeight, lineWidth: lineWidth, color: actor.color, facing: facing)
                var primitives: [SpatterPrimitive] = []
                if action == .explode {
                    let localTick = tick - timed.startTick, flashTicks = max(1, timed.ticks / 6)
                    if localTick < flashTicks {
                        primitives = try generator.primitives(.standing, x: x, y: baselineY)
                    } else {
                        let burstFrames = max(SpatterImpactPrimitive.frameRange.lowerBound, min(SpatterImpactPrimitive.frameRange.upperBound, (timed.ticks - flashTicks + hold - 1) / hold))
                        if explosions[actorIndex] == nil {
                            let burst = SpatterImpactPrimitive(seed: seed &+ UInt64(actorIndex + 1) &* 0x9E37_79B9, originX: x, originY: baselineY - figureHeight * 0.58,
                                directionRadians: -.pi / 2, intensity: 1, palette: .blood, frameCount: burstFrames, fps: max(1, context.fps / hold), scale: figureHeight, groundY: baselineY)
                            explosions[actorIndex] = try burst.frames(canvasWidth: context.width, canvasHeight: context.height, lineWidth: lineWidth)
                            fragments[actorIndex] = (0..<6).map { _ in
                                (angle: random.within((-.pi * 0.9)...(-.pi * 0.1)), speed: figureHeight * random.within(1...2.4),
                                 spin: random.within(-6...6), length: figureHeight * random.within(0.15...0.25))
                            }
                        }
                        let burstIndex = min(burstFrames - 1, max(0, (localTick - flashTicks) / hold))
                        primitives = explosions[actorIndex]?[burstIndex] ?? []
                        let elapsed = Double(burstIndex + 1) * Double(hold) / Double(context.fps)
                        for fragment in fragments[actorIndex] ?? [] {
                            let cx = x + cos(fragment.angle) * fragment.speed * elapsed
                            let cy = min(baselineY, baselineY - figureHeight * 0.58 + sin(fragment.angle) * fragment.speed * elapsed + 3 * figureHeight * elapsed * elapsed)
                            let angle = fragment.spin * elapsed, half = fragment.length / 2
                            let (ax, ay) = clamp(cx - cos(angle) * half, cy - sin(angle) * half), (bx, by) = clamp(cx + cos(angle) * half, cy + sin(angle) * half)
                            if ax != bx || ay != by { primitives.append(.init(kind: .line, x0: ax, y0: ay, x1: bx, y1: by, color: actor.color, width: lineWidth, opacity: 1)) }
                        }
                    }
                } else {
                    let pose = SpatterStickPoseGenerator.pose(action, t: progress, seconds: clauseSeconds)
                    let travel = placement.travel[clauseIndex] * progress
                    primitives = try generator.primitives(pose, x: x + travel, y: baselineY)
                    if action == .throw, progress >= 0.5 {
                        let tau = (progress - 0.5) * clauseSeconds
                        let hand = SpatterStickPoseGenerator.pose(.throw, t: 0.5, seconds: clauseSeconds).handFront
                        let px = x + travel + hand.x * figureHeight * facing + facing * 1.6 * figureHeight * tau
                        let py = baselineY + hand.y * figureHeight - 0.9 * figureHeight * tau + 1.5 * figureHeight * tau * tau
                        let radius = figureHeight * 0.04
                        if py + radius <= baselineY, px - radius >= lineWidth, px + radius <= width - lineWidth {
                            primitives.append(.circle(centerX: px, centerY: py, radius: radius, color: actor.color, width: lineWidth))
                        }
                    }
                }
                guard primitives.allSatisfy({ $0.fits(width: width, height: height) }) else { throw Failure.bounds }
                if !primitives.isEmpty { frameActors[actorIndex] = primitives }
            }
            guard !frameActors.isEmpty else { throw Failure.bounds }
            if let previous = drafts.last, previous.actors == frameActors, previous.holdTicks + holdTicks <= 600 {
                drafts[drafts.count - 1].holdTicks += holdTicks
            } else {
                drafts.append(.init(holdTicks: holdTicks, actors: frameActors))
            }
        }
        var generated = 0
        var frames: [StudioCommand.AppendFrames.Frame] = []
        for (frameIndex, draft) in drafts.enumerated() {
            var drawings: [StudioCommand.AppendFrames.Drawing] = []
            for actorIndex in draft.actors.keys.sorted() {
                let strokes = (draft.actors[actorIndex] ?? []).enumerated().map { part, primitive in
                    primitive.stroke(id: "brief-\(requestID.uuidString)-\(frameIndex)-\(actorIndex)-\(part)")
                }
                generated += strokes.count
                drawings.append(.init(layer: .created("brief_layer_\(actorIndex)"), strokes: strokes))
            }
            frames.append(.init(result: "brief_frame_\(frameIndex)", holdTicks: draft.holdTicks, drawings: drawings))
        }
        guard generated <= StudioCommandExecutor.maximumGeneratedElements, !frames.isEmpty,
              frames.count <= StudioCommandExecutor.maximumAppendedFrames else { throw Failure.budget(Int(seconds)) }
        var commands: [StudioCommand] = storyboardActors.map { StudioCommand.addLayer(.init(name: $0.layerName, result: "brief_layer_\($0.index - 1)")) }
        commands.append(.appendFrames(.init(after: .id(last.id), frames: frames)))
        commands.append(.selectFrame(.created("brief_frame_0")))
        try checkCancellation()
        let storyboard = SpatterStoryboard(brief: normalized, seed: seed, fps: context.fps, totalTicks: totalTicks, poseHoldTicks: hold,
                                           frameCount: frames.count, generatedElementCount: generated, actors: storyboardActors)
        let prepared = SpatterMotionRecipe.Prepared(request: .init(requestID: requestID, projectID: context.projectID, expectedRevision: context.revision,
            action: .apply(commands)), framesToAdd: frames.count, durationSeconds: Double(totalTicks) / Double(context.fps),
            appendedAfterFrameID: last.id, firstNewFrameAlias: "brief_frame_0")
        return .init(prepared: prepared, storyboard: storyboard, generatedLayerAliases: storyboardActors.map { "brief_layer_\($0.index - 1)" })
    }
}

// MARK: - Registry extensions (#204): tween, frame clipboard, project settings, brush families

/// "Tween 4 in-betweens between frames 1 and 2 with ease-in-out easing."
/// Endpoint frames must be adjacent; the editor pairs drawings in order.
struct SpatterTweenInstruction: Equatable {
    let inbetweens: Int
    let firstFrame: Int
    let easing: StudioTweenEasing
    static let example = "Tween 4 in-betweens between frames 1 and 2 with ease-in-out easing."
    static let linearExample = "Tween 2 in-betweens between frames 1 and 2."
    static let easings: [String: StudioTweenEasing] = ["linear": .linear, "ease-in": .easeIn, "ease-out": .easeOut, "ease-in-out": .easeInOut, "easy-ease": .easyEase]
    enum Failure: LocalizedError {
        case unsupported, frames, capacity
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Use Tween 4 in-betweens between frames 1 and 2 with ease-in-out easing. Choose 1–24 in-betweens, two adjacent existing frames and linear, ease-in, ease-out, ease-in-out or easy-ease. Nothing changed."
            case .frames: return "Choose two adjacent existing frames whose drawings match in count and style. Nothing changed."
            case .capacity: return "The project does not have room for the requested in-betweens. Nothing changed."
            }
        }
    }
    static func isInstruction(_ text: String) -> Bool { text.split(whereSeparator: { $0.isWhitespace }).first?.lowercased() == "tween" }
    static func parse(_ text: String) throws -> Self {
        try SpatterGrammarSupport.checked(text)
        let pattern = #"\A\s*tween\s+([1-9]|1[0-9]|2[0-4])\s+in-?betweens?\s+between\s+frames\s+([1-9][0-9]{0,3})\s+and\s+([1-9][0-9]{0,3})(?:\s+with\s+(linear|ease-in|ease-out|ease-in-out|easy-ease)\s+easing)?\.?\s*\z"#
        guard let (_, values) = try SpatterGrammarSupport.captures(text, patterns: [pattern]),
              let count = Int(values[0]), let first = Int(values[1]), let second = Int(values[2]), second == first + 1 else { throw Failure.unsupported }
        let easing = values[3].isEmpty ? StudioTweenEasing.linear : easings[values[3].lowercased()]
        guard let easing else { throw Failure.unsupported }
        return .init(inbetweens: count, firstFrame: first, easing: easing)
    }
    func prepare(in context: StudioCommandContext, requestID: UUID = UUID(),
                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StudioCommandRequest {
        try checkCancellation()
        guard (1...24).contains(inbetweens), firstFrame >= 1, firstFrame < context.frames.count else { throw Failure.frames }
        guard context.frames.count + inbetweens <= 1000 else { throw Failure.capacity }
        let start = context.frames[firstFrame - 1], end = context.frames[firstFrame]
        guard start.elementCount == end.elementCount, start.elementCount > 0 || start.imageAssetID != nil else { throw Failure.frames }
        return .init(requestID: requestID, projectID: context.projectID, expectedRevision: context.revision,
            action: .apply([.tweenFrames(.init(after: .id(start.id), to: .id(end.id), inbetweenCount: inbetweens, easing: easing))]))
    }
}

/// "Copy frame 1 and paste it after frame 2." / "Copy frame 1." / "Paste frame after active frame."
/// A combined copy+paste is self-contained; a bare paste uses the frame clipboard.
struct SpatterFrameClipboardInstruction: Equatable {
    enum Target: Equatable { case active, number(Int) }
    let source: Target?
    let destination: Target?
    static let copyExample = "Copy frame 1."
    static let pasteExample = "Paste frame after active frame."
    static let copyPasteExample = "Copy frame 1 and paste it after frame 2."
    enum Failure: LocalizedError {
        case unsupported, missing, capacity
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Use Copy frame 1., Paste frame after active frame., or Copy frame 1 and paste it after frame 2. Frame numbers are one-based. Nothing changed."
            case .missing: return "That frame does not exist in the captured project. Nothing changed."
            case .capacity: return "The project has reached its 1,000-frame limit. Nothing changed."
            }
        }
    }
    static func isInstruction(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter }
        return ["copy", "paste"].contains(words.first.map(String.init) ?? "") && words.contains("frame")
    }
    private static let target = #"(?:frame\s+([1-9][0-9]{0,3})|(active)\s+frame)"#
    static func parse(_ text: String) throws -> Self {
        try SpatterGrammarSupport.checked(text)
        let tail: String = #"\.?\s*\z"#
        let combined: String = #"\A\s*copy\s+"# + Self.target + #"\s+and\s+paste\s+it\s+after\s+"# + Self.target + tail
        let copyOnly: String = #"\A\s*copy\s+"# + Self.target + tail
        let pasteOnly: String = #"\A\s*paste\s+frame\s+after\s+"# + Self.target + tail
        let patterns = [combined, copyOnly, pasteOnly]
        guard let (index, values) = try SpatterGrammarSupport.captures(text, patterns: patterns) else { throw Failure.unsupported }
        func target(_ number: String, _ active: String) -> Target? {
            if !active.isEmpty { return .active }
            return Int(number).map { .number($0) }
        }
        switch index {
        case 0:
            guard let source = target(values[0], values[1]), let destination = target(values[2], values[3]) else { throw Failure.unsupported }
            return .init(source: source, destination: destination)
        case 1:
            guard let source = target(values[0], values[1]) else { throw Failure.unsupported }
            return .init(source: source, destination: nil)
        default:
            guard let destination = target(values[0], values[1]) else { throw Failure.unsupported }
            return .init(source: nil, destination: destination)
        }
    }
    func prepare(in context: StudioCommandContext, requestID: UUID = UUID(),
                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StudioCommandRequest {
        try checkCancellation()
        func id(_ target: Target) throws -> String {
            switch target {
            case .active:
                guard context.frames.contains(where: { $0.id == context.activeFrameID }) else { throw Failure.missing }
                return context.activeFrameID
            case .number(let number):
                guard number >= 1, number <= context.frames.count else { throw Failure.missing }
                return context.frames[number - 1].id
            }
        }
        var commands: [StudioCommand] = []
        if let source { commands.append(.copyFrame(.init(source: .id(try id(source))))) }
        if let destination {
            guard context.frames.count < 1000 else { throw Failure.capacity }
            commands.append(.pasteFrame(.init(after: .id(try id(destination)))))
        }
        guard !commands.isEmpty else { throw Failure.unsupported }
        return .init(requestID: requestID, projectID: context.projectID, expectedRevision: context.revision, action: .apply(commands))
    }
}

/// "Set project size to 640 by 480 pixels at 24 FPS." / "Set project frame rate to 24 FPS."
struct SpatterProjectSettingsInstruction: Equatable {
    let width: Int?
    let height: Int?
    let fps: Int?
    static let sizeExample = "Set project size to 640 by 480 pixels."
    static let fpsExample = "Set project frame rate to 24 FPS."
    static let bothExample = "Set project size to 640 by 480 pixels at 24 FPS."
    enum Failure: LocalizedError {
        case unsupported
        var errorDescription: String? { "Use Set project size to 640 by 480 pixels., Set project frame rate to 24 FPS., or both with at 24 FPS. Sides are 16–4096 pixels and FPS is 1–60. Resizing keeps artwork coordinates; changing FPS changes speed. Nothing changed." }
    }
    static func isInstruction(_ text: String) -> Bool {
        text.range(of: #"\A\s*set\s+project\s+(?:size|frame\s+rate)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
    static func parse(_ text: String) throws -> Self {
        try SpatterGrammarSupport.checked(text)
        let patterns = [#"\A\s*set\s+project\s+size\s+to\s+([1-9][0-9]{0,3})\s+by\s+([1-9][0-9]{0,3})\s+pixels(?:\s+at\s+([1-9][0-9]?)\s+fps)?\.?\s*\z"#,
                        #"\A\s*set\s+project\s+frame\s+rate\s+to\s+([1-9][0-9]?)\s+fps\.?\s*\z"#]
        guard let (index, values) = try SpatterGrammarSupport.captures(text, patterns: patterns) else { throw Failure.unsupported }
        if index == 0 {
            guard let width = Int(values[0]), let height = Int(values[1]), (16...4096).contains(width), (16...4096).contains(height) else { throw Failure.unsupported }
            var fps: Int?
            if !values[2].isEmpty { guard let value = Int(values[2]), (1...60).contains(value) else { throw Failure.unsupported }; fps = value }
            return .init(width: width, height: height, fps: fps)
        }
        guard let fps = Int(values[0]), (1...60).contains(fps) else { throw Failure.unsupported }
        return .init(width: nil, height: nil, fps: fps)
    }
    func prepare(in context: StudioCommandContext, requestID: UUID = UUID(),
                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StudioCommandRequest {
        try checkCancellation()
        guard width != nil || fps != nil, width.map({ (16...4096).contains($0) }) ?? true, height.map({ (16...4096).contains($0) }) ?? true,
              fps.map({ (1...60).contains($0) }) ?? true else { throw Failure.unsupported }
        return .init(requestID: requestID, projectID: context.projectID, expectedRevision: context.revision,
            action: .apply([.updateProjectSettings(.init(name: nil, width: width, height: height, fps: fps))]))
    }
}

/// "Draw a round brush line from (10%, 20%) to (90%, 20%) in #000000, size 6 px, opacity 100%."
/// One straight brush stroke on the active frame and layer, in any brush family.
struct SpatterBrushStrokeInstruction: Equatable {
    let family: StudioBrushFamily
    let start: SpatterMotionRecipe.PercentPoint
    let end: SpatterMotionRecipe.PercentPoint
    let color: String
    let endColor: String?
    let size: Double
    let opacity: Double
    static let familyNames: [(String, StudioBrushFamily)] = [("round", .round), ("stipple", .stipple), ("grain", .grain), ("rough pen", .roughPen),
        ("calligraphy", .calligraphy), ("dip pen", .dipPen), ("halftone", .halftone), ("hatch right", .hatchRight), ("hatch left", .hatchLeft),
        ("gradient", .gradient), ("airbrush", .airbrush), ("watercolor", .watercolor), ("neon", .neon)]
    static func name(_ family: StudioBrushFamily) -> String { familyNames.first { $0.1 == family }?.0 ?? family.rawValue }
    static func example(_ family: StudioBrushFamily) -> String {
        family == .gradient ? gradientExample
            : "Draw a \(name(family)) brush line from (10%, 20%) to (90%, 20%) in #000000, size 6 px, opacity 100%."
    }
    static let example = "Draw a round brush line from (10%, 20%) to (90%, 20%) in #000000, size 6 px, opacity 100%."
    static let gradientExample = "Draw a gradient brush line from (10%, 40%) to (90%, 40%) in #FF0000 to #0000FF, size 8 px, opacity 100%."
    enum Failure: LocalizedError {
        case unsupported, layer
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Use Draw a round brush line from (10%, 20%) to (90%, 20%) in #000000, size 6 px, opacity 100%. Families: round, stipple, grain, rough pen, calligraphy, dip pen, halftone, hatch right, hatch left, gradient (needs in #RRGGBB to #RRGGBB), airbrush, watercolor, neon. Size 1–50 px, opacity 0–100%, different start and end. Nothing changed."
            case .layer: return "Select a visible layer that is not locked or position-locked before drawing with Spatter. Nothing changed."
            }
        }
    }
    static func isInstruction(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter }
        return words.first == "draw" && words.contains("brush")
    }
    static func parse(_ text: String) throws -> Self {
        try SpatterGrammarSupport.checked(text)
        let p = SpatterGrammarSupport.percent
        let pattern = #"\A\s*draw\s+(?:a|an)\s+(round|stipple|grain|rough\s+pen|calligraphy|dip\s+pen|halftone|hatch\s+right|hatch\s+left|gradient|airbrush|watercolor|neon)\s+brush\s+line\s+from\s*\(\s*"#
            + p + #"\s*,\s*"# + p + #"\s*\)\s+to\s*\(\s*"# + p + #"\s*,\s*"# + p
            + #"\s*\)\s+in\s+(#[0-9a-f]{6})(?:\s+to\s+(#[0-9a-f]{6}))?\s*,\s*size\s+([0-9]+(?:\.[0-9]+)?)\s+px\s*,\s*opacity\s+([0-9]+(?:\.[0-9]+)?)\s*%\.?\s*\z"#
        guard let (_, values) = try SpatterGrammarSupport.captures(text, patterns: [pattern]) else { throw Failure.unsupported }
        let familyName = values[0].lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard let family = familyNames.first(where: { $0.0 == familyName })?.1,
              let x0 = SpatterGrammarSupport.number(values[1], in: 0...100), let y0 = SpatterGrammarSupport.number(values[2], in: 0...100),
              let x1 = SpatterGrammarSupport.number(values[3], in: 0...100), let y1 = SpatterGrammarSupport.number(values[4], in: 0...100),
              let size = SpatterGrammarSupport.number(values[7], in: 1...50), let opacity = SpatterGrammarSupport.number(values[8], in: 0...100),
              x0 != x1 || y0 != y1 else { throw Failure.unsupported }
        let endColor = values[6].isEmpty ? nil : values[6].uppercased()
        guard (family == .gradient) == (endColor != nil) else { throw Failure.unsupported }
        return .init(family: family, start: .init(x: x0, y: y0), end: .init(x: x1, y: y1), color: values[5].uppercased(), endColor: endColor, size: size, opacity: opacity / 100)
    }
    static func brushColor(_ hex: String) -> StudioBrushColor? {
        let digits = Array(hex.dropFirst().utf8)
        guard hex.hasPrefix("#"), digits.count == 6 else { return nil }
        func component(_ offset: Int) -> Double? {
            guard let value = UInt8(String(decoding: digits[offset..<offset + 2], as: UTF8.self), radix: 16) else { return nil }
            return Double(value) / 255
        }
        guard let red = component(0), let green = component(2), let blue = component(4) else { return nil }
        return .init(red: red, green: green, blue: blue, alpha: 1)
    }
    func prepare(in context: StudioCommandContext, requestID: UUID = UUID(),
                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StudioCommandRequest {
        try checkCancellation()
        guard context.frames.contains(where: { $0.id == context.activeFrameID }), context.supportedTools.contains(.brush),
              context.supportedBrushFamilies.contains(family) else { throw Failure.layer }
        guard let layer = context.layers.first(where: { $0.id == context.activeLayerID }), layer.visible, layer.opacity > 0,
              !layer.isFullyLocked, layer.lockMode == "free" || layer.lockMode == "alpha" else { throw Failure.layer }
        var endpoint: StudioBrushColor?
        if let endColor {
            guard let parsed = Self.brushColor(endColor) else { throw Failure.unsupported }
            endpoint = parsed
        }
        let seed = SpatterGeometry.fnv1a(requestID.uuidString)
        let descriptor = StudioBrushDescriptor(family: family, seed: seed, smoothing: 3, pressureEnabled: false, tipAngleDegrees: 45,
                                               texture: 0.5, grain: 0.3, gradientEndColor: endpoint, tiltEnabled: nil)
        do { _ = try descriptor.settings(width: size, opacity: opacity) } catch { throw Failure.unsupported }
        let width = Double(context.width), height = Double(context.height)
        let count = 24
        let points: [StrokePoint] = (0...count).map { index in
            let t = Double(index) / Double(count)
            return .init(x: CGFloat(SpatterGeometry.quantized(width * SpatterGeometry.mix(start.x, end.x, t) / 100)),
                         y: CGFloat(SpatterGeometry.quantized(height * SpatterGeometry.mix(start.y, end.y, t) / 100)))
        }
        try checkCancellation()
        return .init(requestID: requestID, projectID: context.projectID, expectedRevision: context.revision,
            action: .apply([.draw(.init(frame: .id(context.activeFrameID), layer: .id(context.activeLayerID), strokes: [
                .init(id: "brush-\(requestID.uuidString)", tool: .brush, points: points, color: color, width: size, opacity: opacity, brush: descriptor)]))]))
    }
}

// MARK: - Router, batches and plan preview (#205)

/// Classification shared by the batch grammar, the plan preview and tests. The
/// order mirrors SpatterStudioEditSession's dispatch so an instruction is owned
/// by exactly one grammar.
enum SpatterInstructionRouter {
    enum Kind: String, CaseIterable {
        case batch, frameDuplicateRange, frameReverse, navigation, layerStructure, grid, onionSkin, frameAction, layerOrder, audioTrack
        case frameCut, drawingDuplicate, artworkOrder, imageReflection, selectionTranslate, selectionTransform, selectionReflect
        case imageRotation, imageCrop, imagePlacement, textUpdate, tween, frameClipboard, projectSettings, brushStroke
        case selectedErasure, projectRename, frameExposure, layerUpdate, layerDuplicate, layerGlow, audioClip
        case multiClauseBrief, twoActorBrief, sceneBrief, stickFigure, circleMotion
        /// Grammars whose preparation needs only the captured document, not a selection.
        var isContextOnly: Bool {
            switch self {
            case .frameDuplicateRange, .frameReverse, .navigation, .layerStructure, .grid, .onionSkin, .frameAction, .layerOrder, .audioTrack,
                 .tween, .frameClipboard, .projectSettings, .projectRename, .frameExposure, .layerUpdate, .layerDuplicate, .layerGlow, .brushStroke:
                return true
            default: return false
            }
        }
    }
    static func classify(_ draft: String) -> Kind? {
        if SpatterInstructionBatch.isBatch(draft) { return .batch }
        if SpatterFrameDuplicateRangeInstruction.isInstruction(draft) { return .frameDuplicateRange }
        if SpatterFrameReverseInstruction.isInstruction(draft) { return .frameReverse }
        if SpatterNavigationInstruction.isInstruction(draft) { return .navigation }
        if SpatterLayerStructureInstruction.isInstruction(draft) { return .layerStructure }
        let isLayerUpdate = SpatterLayerUpdateInstruction.isInstruction(draft)
        let isRename = !isLayerUpdate && SpatterProjectRenameInstruction.isInstruction(draft)
        if !isLayerUpdate, !isRename {
            if SpatterGridInstruction.isInstruction(draft) { return .grid }
            if SpatterOnionInstruction.isInstruction(draft) { return .onionSkin }
            if SpatterFrameActionInstruction.isInstruction(draft) { return .frameAction }
            if SpatterLayerOrderInstruction.isInstruction(draft) { return .layerOrder }
        }
        if SpatterAudioTrackInstruction.isInstruction(draft) { return .audioTrack }
        if SpatterFrameCutInstruction.isInstruction(draft) { return .frameCut }
        if SpatterDrawingDuplicateInstruction.isInstruction(draft) { return .drawingDuplicate }
        if !isLayerUpdate, !isRename {
            if SpatterArtworkOrderInstruction.isInstruction(draft) { return .artworkOrder }
            if SpatterImageReflectionInstruction.isInstruction(draft) { return .imageReflection }
        }
        if SpatterSelectionTranslateInstruction.isInstruction(draft) { return .selectionTranslate }
        if SpatterSelectionTransformInstruction.isInstruction(draft) { return .selectionTransform }
        if SpatterSelectionReflectInstruction.isInstruction(draft) { return .selectionReflect }
        if SpatterImageRotationInstruction.isInstruction(draft) { return .imageRotation }
        if SpatterImageCropInstruction.isInstruction(draft) { return .imageCrop }
        if SpatterImagePlacementInstruction.isInstruction(draft) { return .imagePlacement }
        if SpatterTextUpdateInstruction.isInstruction(draft) { return .textUpdate }
        if SpatterTweenInstruction.isInstruction(draft) { return .tween }
        if SpatterFrameClipboardInstruction.isInstruction(draft) { return .frameClipboard }
        if SpatterProjectSettingsInstruction.isInstruction(draft) { return .projectSettings }
        if SpatterBrushStrokeInstruction.isInstruction(draft) { return .brushStroke }
        if SpatterSelectedErasureInstruction.isInstruction(draft) { return .selectedErasure }
        if isRename { return .projectRename }
        if !isLayerUpdate, SpatterFrameExposureInstruction.isInstruction(draft) { return .frameExposure }
        if isLayerUpdate { return .layerUpdate }
        if SpatterLayerDuplicateInstruction.isInstruction(draft) { return .layerDuplicate }
        if SpatterLayerGlowInstruction.isInstruction(draft) { return .layerGlow }
        if SpatterAudioInstruction.isAudioInstruction(draft) { return .audioClip }
        // The historical brief grammars keep their exact behaviour for the briefs
        // they accept; everything else in brief form goes to the general planner.
        if SpatterTwoActorBrief.isBrief(draft), (try? SpatterTwoActorBrief.parse(draft)) != nil { return .twoActorBrief }
        if SpatterSceneBrief.isBrief(draft), (try? SpatterSceneBrief.parse(draft)) != nil { return .sceneBrief }
        if SpatterMultiClauseBrief.isBrief(draft) { return .multiClauseBrief }
        if SpatterTwoActorBrief.isBrief(draft) { return .twoActorBrief }
        if SpatterSceneBrief.isBrief(draft) { return .sceneBrief }
        if SpatterStickFigureRecipe.isStickFigureInstruction(draft) { return .stickFigure }
        if draft.range(of: #"\A\s*append\s+"#, options: [.regularExpression, .caseInsensitive]) != nil { return .circleMotion }
        return nil
    }

    /// Prepares one context-only instruction. Selection, image, text, audio-clip
    /// and generative grammars are not routed here; they keep their captured-authority paths.
    static func prepareContextOnly(_ line: String, kind: Kind, in context: StudioCommandContext, requestID: UUID,
                                   checkCancellation: () throws -> Void) throws -> StudioCommandRequest {
        switch kind {
        case .frameDuplicateRange: return try SpatterFrameDuplicateRangeInstruction.parse(line).prepare(in: context, requestID: requestID, checkCancellation: checkCancellation)
        case .frameReverse: return try SpatterFrameReverseInstruction.parse(line).prepare(in: context, requestID: requestID, checkCancellation: checkCancellation)
        case .navigation: return try SpatterNavigationInstruction.parse(line).prepare(in: context, requestID: requestID, checkCancellation: checkCancellation)
        case .layerStructure: return try SpatterLayerStructureInstruction.parse(line).prepare(in: context, requestID: requestID, checkCancellation: checkCancellation)
        case .grid: return try SpatterGridInstruction.parse(line).prepare(in: context, requestID: requestID, checkCancellation: checkCancellation)
        case .onionSkin: return try SpatterOnionInstruction.parse(line).prepare(in: context, requestID: requestID, checkCancellation: checkCancellation)
        case .frameAction: return try SpatterFrameActionInstruction.parse(line).prepare(in: context, requestID: requestID, checkCancellation: checkCancellation)
        case .layerOrder: return try SpatterLayerOrderInstruction.parse(line).prepare(in: context, requestID: requestID, checkCancellation: checkCancellation)
        case .audioTrack: return try SpatterAudioTrackInstruction.parse(line).prepare(in: context, requestID: requestID, checkCancellation: checkCancellation)
        case .tween: return try SpatterTweenInstruction.parse(line).prepare(in: context, requestID: requestID, checkCancellation: checkCancellation)
        case .frameClipboard: return try SpatterFrameClipboardInstruction.parse(line).prepare(in: context, requestID: requestID, checkCancellation: checkCancellation)
        case .projectSettings: return try SpatterProjectSettingsInstruction.parse(line).prepare(in: context, requestID: requestID, checkCancellation: checkCancellation)
        case .projectRename: return try SpatterProjectRenameInstruction.parse(line).prepare(in: context, requestID: requestID, checkCancellation: checkCancellation)
        case .frameExposure: return try SpatterFrameExposureInstruction.parse(line).prepare(in: context, requestID: requestID, checkCancellation: checkCancellation)
        case .layerUpdate: return try SpatterLayerUpdateInstruction.parse(line).prepare(in: context, requestID: requestID, checkCancellation: checkCancellation)
        case .layerDuplicate: return try SpatterLayerDuplicateInstruction.parse(line).prepare(in: context, requestID: requestID, checkCancellation: checkCancellation)
        case .layerGlow: return try SpatterLayerGlowInstruction.parse(line).prepare(in: context, requestID: requestID, checkCancellation: checkCancellation)
        case .brushStroke: return try SpatterBrushStrokeInstruction.parse(line).prepare(in: context, requestID: requestID, checkCancellation: checkCancellation)
        default: throw SpatterInstructionBatch.Failure.unsupportedLine(0, line)
        }
    }
}

extension StudioCommand {
    /// Namespaces result aliases so several prepared instructions can share one
    /// request without colliding; identities (`.id`) are untouched.
    func prefixingAliases(_ prefix: String) -> StudioCommand {
        func reference(_ value: StudioCommandReference) -> StudioCommandReference {
            if case .created(let alias) = value { return .created(prefix + alias) }
            return value
        }
        switch self {
        case .addFrame(let value): return .addFrame(.init(after: reference(value.after), result: prefix + value.result))
        case .duplicateFrame(let value): return .duplicateFrame(.init(source: reference(value.source), result: prefix + value.result))
        case .addLayer(let value): return .addLayer(.init(name: value.name, result: prefix + value.result))
        case .duplicateLayer(let value): return .duplicateLayer(.init(source: reference(value.source), result: prefix + value.result))
        case .selectFrame(let value): return .selectFrame(reference(value))
        case .selectLayer(let value): return .selectLayer(reference(value))
        case .setFrameHold(let value): return .setFrameHold(.init(frame: reference(value.frame), ticks: value.ticks))
        case .draw(let value): return .draw(.init(frame: reference(value.frame), layer: reference(value.layer), strokes: value.strokes))
        default: return self
        }
    }
}

/// Several complete context-only instructions, one per line, applied as one
/// typed request: one revision, one Undo step, nothing applied on any failure.
/// Every line is resolved against the same captured document, so frame numbers
/// refer to the project as it was when Spatter opened.
struct SpatterInstructionBatch: Equatable {
    struct Line: Equatable { let number: Int; let text: String; let kind: SpatterInstructionRouter.Kind }
    let lines: [Line]
    static let maximumLines = 8
    static let example = "Add 3 blank frames.\nSet frames 1 through 2 exposure to 2 ticks.\nRename project to \"Batch\"."
    enum Failure: LocalizedError, Equatable {
        case lineCount, unsupportedLine(Int, String), tooManyCommands
        var errorDescription: String? {
            switch self {
            case .lineCount: return "A batch holds 2–8 complete instructions, one per line. Nothing changed."
            case .unsupportedLine(let number, let text): return "Line \(number) is not a complete context-only instruction (\u{201C}\(text.prefix(48))\u{201D}). Batches accept frame, layer, exposure, grid, onion, audio-track, tween, clipboard, project-setting, rename and brush-stroke instructions; selection, image, text, audio-clip and brief instructions run on their own. Nothing changed."
            case .tooManyCommands: return "This batch expands to more than 96 typed commands. Split it into two batches. Nothing changed."
            }
        }
    }
    static func isBatch(_ text: String) -> Bool { splitLines(text).count >= 2 }
    static func splitLines(_ text: String) -> [String] {
        text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= SpatterMotionRecipe.maximumInstructionBytes else { throw SpatterMotionRecipe.RecipeError.instructionTooLong }
        let texts = splitLines(text)
        guard (2...maximumLines).contains(texts.count) else { throw Failure.lineCount }
        var lines: [Line] = []
        for (index, line) in texts.enumerated() {
            guard let kind = SpatterInstructionRouter.classify(line), kind.isContextOnly else { throw Failure.unsupportedLine(index + 1, line) }
            lines.append(.init(number: index + 1, text: line, kind: kind))
        }
        return .init(lines: lines)
    }
    func prepare(in context: StudioCommandContext, requestID: UUID = UUID(),
                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StudioCommandRequest {
        var commands: [StudioCommand] = []
        for line in lines {
            try checkCancellation()
            let request: StudioCommandRequest
            do { request = try SpatterInstructionRouter.prepareContextOnly(line.text, kind: line.kind, in: context, requestID: requestID, checkCancellation: checkCancellation) }
            catch is CancellationError { throw CancellationError() }
            catch let error as SpatterInstructionBatch.Failure { throw error }
            catch { throw Failure.unsupportedLine(line.number, (error as? LocalizedError)?.errorDescription ?? line.text) }
            guard case .apply(let list) = request.action else { throw Failure.unsupportedLine(line.number, line.text) }
            commands += list.map { $0.prefixingAliases("b\(line.number)_") }
        }
        guard commands.count <= StudioCommandExecutor.maximumCommands else { throw Failure.tooManyCommands }
        try checkCancellation()
        return .init(requestID: requestID, projectID: context.projectID, expectedRevision: context.revision, action: .apply(commands))
    }
    var summary: String { "\(lines.count) instructions (" + lines.map { $0.kind.rawValue }.joined(separator: ", ") + ")" }
    /// Shown when every line prepared but the combined typed request failed while
    /// committing (a later line conflicting with an earlier one, a work budget or
    /// a document limit). The executor stages a copy, so the editor, its history
    /// and the clipboard are exactly as they were before Apply.
    static func rollbackNotice(_ error: Error) -> String {
        let reason = ((error as? LocalizedError)?.errorDescription ?? String(describing: error))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "The batch could not be applied as a whole: \(reason.prefix(240)) Every line was rolled back; nothing changed and no Undo step was added."
    }
}

/// Text shown before Apply: what the draft was recognized as and, when the
/// grammar needs only the captured document, exactly what it would do. It never
/// mutates anything; a thrown error becomes the preview text.
enum SpatterInstructionPreview {
    static func plan(_ draft: String, context: StudioCommandContext?) -> String {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "Type or choose a complete instruction to preview its plan." }
        guard let kind = SpatterInstructionRouter.classify(text) else {
            return "No supported instruction recognized yet. Choose an example from the menus; Apply executes only complete instructions."
        }
        func describe(_ request: StudioCommandRequest) -> String {
            guard case .apply(let commands) = request.action else { return "no typed commands" }
            var counts: [String: Int] = [:]
            for command in commands {
                let name = String(describing: command).split(separator: "(").first.map(String.init) ?? "command"
                counts[name, default: 0] += 1
            }
            let parts = counts.sorted { $0.key < $1.key }.map { "\($0.value)× \($0.key)" }
            return "\(commands.count) typed command\(commands.count == 1 ? "" : "s") (\(parts.joined(separator: ", ")))"
        }
        let probe = UUID()
        do {
            switch kind {
            case .batch:
                let batch = try SpatterInstructionBatch.parse(text)
                guard let context else { return "Batch of \(batch.summary). Open the project to preview its commands." }
                let request = try batch.prepare(in: context, requestID: probe, checkCancellation: {})
                return "Plan: batch of \(batch.summary) → \(describe(request)) against revision \(context.revision), committed as one Undo step. Nothing has changed yet."
            case .multiClauseBrief:
                let brief = try SpatterMultiClauseBrief.parse(text)
                guard let context else { return "Brief with \(brief.actors.count) actor(s) over \(brief.seconds) seconds. Open the project to preview frames." }
                let plan = try brief.prepare(in: context, requestID: probe, checkCancellation: {})
                let story = plan.storyboard
                let actors = story.actors.map { actor in
                    "actor \(actor.index) (\(actor.color)): " + actor.clauses.map { "\($0.action) \($0.ticks) ticks" }.joined(separator: " → ")
                }.joined(separator: "; ")
                return "Plan: \(story.frameCount) editable frames (\(String(format: "%.2f", story.durationSeconds)) s at \(story.fps) FPS, each pose held \(story.poseHoldTicks) tick\(story.poseHoldTicks == 1 ? "" : "s")), \(story.generatedElementCount) drawings on \(story.actors.count) new layer(s), seed \(story.seed). \(actors). One Undo step. Nothing has changed yet."
            case .sceneBrief:
                let brief = try SpatterSceneBrief.parse(text)
                guard let context else { return "Two-action brief. Open the project to preview frames." }
                let plan = try brief.prepare(in: context, requestID: probe, checkCancellation: {})
                return "Plan: \(plan.framesToAdd) editable frames over \(String(format: "%.2f", plan.durationSeconds)) s on one new layer → \(describe(plan.request)). Nothing has changed yet."
            case .twoActorBrief:
                let brief = try SpatterTwoActorBrief.parse(text)
                guard let context else { return "Two-actor brief. Open the project to preview frames." }
                let plan = try brief.prepare(in: context, requestID: probe, checkCancellation: {})
                return "Plan: \(plan.framesToAdd) editable frames over \(String(format: "%.2f", plan.durationSeconds)) s on two new layers → \(describe(plan.request)). Nothing has changed yet."
            case .stickFigure:
                let recipe = try SpatterStickFigureRecipe.parse(text)
                guard let context else { return "Stick-figure recipe (\(recipe.action.rawValue), \(recipe.frameCount) frames). Open the project to preview." }
                let plan = try recipe.prepare(in: context, requestID: probe, checkCancellation: {})
                return "Plan: \(plan.framesToAdd) \(recipe.action.rawValue) frames over \(String(format: "%.2f", plan.durationSeconds)) s on one new layer → \(describe(plan.request)). Nothing has changed yet."
            case .circleMotion:
                let recipe = try SpatterMotionRecipe.parse(text)
                guard let context else { return "Outlined-circle motion (\(recipe.frameCount) frames). Open the project to preview." }
                let plan = try recipe.prepare(in: context, requestID: probe, checkCancellation: {})
                return "Plan: \(plan.framesToAdd) circle frames over \(String(format: "%.2f", plan.durationSeconds)) s on one new layer → \(describe(plan.request)). Nothing has changed yet."
            default:
                if kind.isContextOnly, let context {
                    let request = try SpatterInstructionRouter.prepareContextOnly(text, kind: kind, in: context, requestID: probe, checkCancellation: {})
                    return "Plan: \(kind.rawValue) → \(describe(request)) against revision \(context.revision), one Undo step. Nothing has changed yet."
                }
                return "Recognized as \(kind.rawValue). Apply validates the captured selection, image, clip or text target against the current project before committing one Undo step. Nothing has changed yet."
            }
        } catch {
            return "Plan unavailable: " + ((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }
}

// `SpatterSourceReference` lives in StudioDocument.swift so suites that compile the document alone see it (#279).

/// Decides whether generation may proceed from a reference. The owner decides
/// the rule (sdi:owner-gate); until then only an explicit, recorded basis passes.
enum SpatterSourceRightsGate {
    struct Decision: Equatable { let allowed: Bool; let reason: String }
    static func evaluate(_ reference: SpatterSourceReference?, now: Date = Date()) -> Decision {
        guard let reference else {
            return .init(allowed: true, reason: "No external source: the brief is original text and the output is generated locally.")
        }
        do { try reference.validate() } catch { return .init(allowed: false, reason: (error as? LocalizedError)?.errorDescription ?? "Invalid source reference.") }
        guard reference.recordedAt <= now.addingTimeInterval(60) else { return .init(allowed: false, reason: "The rights record is dated in the future; record it again.") }
        switch reference.rightsBasis {
        case .unknown:
            return .init(allowed: false, reason: "The source's rights basis is unknown. Record owner authorization, a licence or the creator's confirmation before using it as a reference.")
        case .ownerAuthorized, .licensed, .creatorConfirmed:
            return .init(allowed: true, reason: "Reference allowed on a \(reference.rightsBasis.label) basis recorded \(ISO8601DateFormatter().string(from: reference.recordedAt)). Output must stay independently generated; no footage, frames or audio are copied.")
        }
    }
}

/// Target length and the current exporter limits for source-referenced videos.
enum SpatterSourceVideoBounds {
    static let minimumSeconds = 20.0, maximumSeconds = 60.0
    /// StudioMovieExportService's current cap (#182, #202); distinct frames, not ticks.
    static let exporterFrameCap = 240
    enum Check: Equatable { case inRange, tooShort, tooLong }
    static func check(seconds: Double) -> Check {
        guard seconds.isFinite else { return .tooShort }
        if seconds < minimumSeconds { return .tooShort }
        if seconds > maximumSeconds { return .tooLong }
        return .inRange
    }
    /// How many distinct frames the exporter allows at this FPS and what that
    /// means for a 20–60 second target: holds carry the remaining ticks.
    static func frameCapNote(fps: Int) -> String {
        let fps = max(1, min(60, fps))
        let distinctSeconds = Double(exporterFrameCap) / Double(fps)
        let minimumHold = Int((minimumSeconds * Double(fps) / Double(exporterFrameCap)).rounded(.up))
        let maximumHold = Int((maximumSeconds * Double(fps) / Double(exporterFrameCap)).rounded(.up))
        return "At \(fps) FPS the MP4 exporter's \(exporterFrameCap)-frame cap covers \(String(format: "%.1f", distinctSeconds)) s of distinct frames; a 20–60 s video therefore needs each pose held \(minimumHold)–\(maximumHold) ticks, or the cap raised under #182/#202. Measured, not promised."
    }
}

// MARK: - Quality report (#213)

/// Deterministic measurements over an editable document. These are findings for
/// a human reviewer, not an automatic pass/fail verdict; owner approval of the
/// exact render stays required. Audio alignment and decoded MP4 counts are
/// measured only when the caller supplies them from the real export.
struct SpatterQualityReport: Equatable {
    struct Finding: Equatable {
        enum Kind: String { case blankFrame, frozenFrame, outOfCanvas, limbVariance, timingMismatch, movieFrameCount, movieDuration, audioOffset }
        let kind: Kind
        let frameIndex: Int?
        let detail: String
    }
    /// Measured from a decoded export; `expected` values come from the manifest.
    struct MovieMeasurement: Equatable {
        let decodedFrameCount: Int
        let decodedDurationSeconds: Double
        let audioOffsetSeconds: Double?
        let expectedFrameCount: Int
        let expectedDurationSeconds: Double
    }
    /// Reviewer-adjustable limits. Defaults reject any blank frame, unintended
    /// freeze or off-canvas point, allow 15% limb drift and a one-tick duration drift.
    struct Thresholds: Equatable {
        var maximumBlankFrames = 0
        var maximumFrozenFrames = 0
        var maximumOutOfCanvasElements = 0
        var limbVarianceTolerance = 0.15
        var allowTimingMismatch = false
        var movieDurationToleranceTicks = 1
        var maximumAudioOffsetSeconds = 0.05
    }
    struct Verdict: Equatable {
        let passes: Bool
        let failures: [String]
        static let note = "Findings for a human reviewer; owner approval of the exact render is still required."
    }
    let frameCount: Int
    let fps: Int
    let actualTicks: Int
    let requestedTicks: Int?
    let findings: [Finding]
    let unmeasured: [String]
    var blankFrameCount: Int { findings.filter { $0.kind == .blankFrame }.count }
    var frozenFrameCount: Int { findings.filter { $0.kind == .frozenFrame }.count }
    var outOfCanvasCount: Int { findings.filter { $0.kind == .outOfCanvas }.count }
    var durationSeconds: Double { fps > 0 ? Double(actualTicks) / Double(fps) : 0 }

    /// `requestedTicks` is the tick count a brief or recipe asked for, if any.
    /// `generatedLayerIDs` marks stick-figure layers whose limb lengths should be stable.
    static func analyze(_ document: StudioDocument, requestedTicks: Int? = nil,
                        generatedLayerIDs: Set<String> = [], limbVarianceTolerance: Double = 0.15,
                        movie: MovieMeasurement? = nil, thresholds: Thresholds = .init()) -> SpatterQualityReport {
        var findings: [Finding] = []
        let width = Double(document.width), height = Double(document.height)
        var actualTicks = 0
        var previousSignature: [String]?
        for (index, frame) in document.frames.enumerated() {
            actualTicks += frame.durationTicks
            let visibleElements = frame.elements.filter { element in
                guard let layerID = element.layerID, let layer = document.layers.first(where: { $0.id == layerID }) else { return true }
                return layer.visible && layer.opacity > 0
            }
            let hasImage = frame.rasterAssetID != nil && frame.rasterPlacement != nil
            if visibleElements.isEmpty && !hasImage {
                findings.append(.init(kind: .blankFrame, frameIndex: index, detail: "Frame \(index + 1) has no visible drawings or image."))
            }
            // A deliberate hold uses holdTicks on one frame; identical consecutive
            // frames without a hold are an unintended freeze.
            let geometry = visibleElements.map { element in
                element.tool.rawValue + "|" + element.points.map { "\($0.x),\($0.y)" }.joined(separator: ";")
                    + "|" + (element.translation.map { "\($0.x),\($0.y)" } ?? "") + "|" + (element.transform.map { "\($0.a),\($0.b),\($0.c),\($0.d),\($0.tx),\($0.ty)" } ?? "")
            }
            if let previous = previousSignature, !geometry.isEmpty, previous == geometry, frame.holdTicks == nil,
               document.frames[index - 1].holdTicks == nil {
                findings.append(.init(kind: .frozenFrame, frameIndex: index, detail: "Frame \(index + 1) repeats frame \(index) exactly without a frame hold."))
            }
            previousSignature = geometry
            for element in visibleElements {
                let offsetX = element.translation?.x ?? 0, offsetY = element.translation?.y ?? 0
                if element.points.contains(where: { point in
                    let x = Double(point.x) + Double(offsetX), y = Double(point.y) + Double(offsetY)
                    return !x.isFinite || !y.isFinite || x < -0.5 || y < -0.5 || x > width + 0.5 || y > height + 0.5
                }) {
                    findings.append(.init(kind: .outOfCanvas, frameIndex: index, detail: "Frame \(index + 1) element \(element.id.prefix(8)) has points outside the \(document.width)×\(document.height) canvas."))
                }
            }
        }
        // Limb-length variance: for generated stick layers, every line element on
        // the layer should keep a stable length across frames (per ordinal position).
        for layerID in generatedLayerIDs.sorted() {
            var lengthsByPosition: [Int: [Double]] = [:]
            for frame in document.frames {
                let lines = frame.elements.filter { $0.layerID == layerID && $0.tool == .line && $0.points.count == 2 }
                for (position, line) in lines.enumerated() {
                    let dx = Double(line.points[1].x - line.points[0].x), dy = Double(line.points[1].y - line.points[0].y)
                    lengthsByPosition[position, default: []].append((dx * dx + dy * dy).squareRoot())
                }
            }
            for (position, lengths) in lengthsByPosition.sorted(by: { $0.key < $1.key }) where lengths.count > 1 {
                let mean = lengths.reduce(0, +) / Double(lengths.count)
                guard mean > 0 else { continue }
                let maxDeviation = lengths.map { abs($0 - mean) / mean }.max() ?? 0
                if maxDeviation > limbVarianceTolerance {
                    findings.append(.init(kind: .limbVariance, frameIndex: nil,
                        detail: "Layer \(layerID.prefix(8)) limb \(position + 1) length varies \(Int((maxDeviation * 100).rounded()))% from its mean across frames."))
                }
            }
        }
        if let requestedTicks, requestedTicks != actualTicks {
            findings.append(.init(kind: .timingMismatch, frameIndex: nil, detail: "Requested \(requestedTicks) ticks but the document holds \(actualTicks) ticks at \(document.fps) FPS."))
        }
        var unmeasured = ["decodedMovieFrameCount", "decodedMovieDuration", "audioOffsetSeconds"]
        if let movie {
            unmeasured.removeAll { $0 == "decodedMovieFrameCount" || $0 == "decodedMovieDuration" }
            if movie.decodedFrameCount != movie.expectedFrameCount {
                findings.append(.init(kind: .movieFrameCount, frameIndex: nil, detail: "The exported movie decoded \(movie.decodedFrameCount) frames but the manifest expected \(movie.expectedFrameCount)."))
            }
            let tolerance = Double(max(0, thresholds.movieDurationToleranceTicks)) / Double(max(1, document.fps))
            if !movie.decodedDurationSeconds.isFinite || abs(movie.decodedDurationSeconds - movie.expectedDurationSeconds) > tolerance + 0.0005 {
                findings.append(.init(kind: .movieDuration, frameIndex: nil, detail: "The exported movie lasts \(String(format: "%.3f", movie.decodedDurationSeconds)) s but the manifest expected \(String(format: "%.3f", movie.expectedDurationSeconds)) s."))
            }
            if let offset = movie.audioOffsetSeconds {
                unmeasured.removeAll { $0 == "audioOffsetSeconds" }
                if !offset.isFinite || abs(offset) > thresholds.maximumAudioOffsetSeconds {
                    findings.append(.init(kind: .audioOffset, frameIndex: nil, detail: "Audio starts \(String(format: "%.3f", offset)) s away from the video; the limit is \(String(format: "%.3f", thresholds.maximumAudioOffsetSeconds)) s."))
                }
            }
        }
        return .init(frameCount: document.frames.count, fps: document.fps, actualTicks: actualTicks, requestedTicks: requestedTicks,
                     findings: findings, unmeasured: unmeasured)
    }

    /// Applies thresholds to the findings. A failing verdict means "rework or
    /// reject"; a passing verdict never replaces the owner's approval.
    func verdict(_ thresholds: Thresholds = .init()) -> Verdict {
        var failures: [String] = []
        if blankFrameCount > thresholds.maximumBlankFrames { failures.append("\(blankFrameCount) blank frame(s); limit \(thresholds.maximumBlankFrames).") }
        if frozenFrameCount > thresholds.maximumFrozenFrames { failures.append("\(frozenFrameCount) unintended freeze(s); limit \(thresholds.maximumFrozenFrames).") }
        if outOfCanvasCount > thresholds.maximumOutOfCanvasElements { failures.append("\(outOfCanvasCount) element(s) leave the canvas; limit \(thresholds.maximumOutOfCanvasElements).") }
        for finding in findings where finding.kind == .limbVariance { failures.append(finding.detail) }
        if !thresholds.allowTimingMismatch, let mismatch = findings.first(where: { $0.kind == .timingMismatch }) { failures.append(mismatch.detail) }
        for finding in findings where [.movieFrameCount, .movieDuration, .audioOffset].contains(finding.kind) { failures.append(finding.detail) }
        return .init(passes: failures.isEmpty, failures: failures)
    }
}
