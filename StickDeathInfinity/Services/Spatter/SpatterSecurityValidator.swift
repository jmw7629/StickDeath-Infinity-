// ═══════════════════════════════════════════════════════════════════
// SpatterSecurityValidator — Input and command validation
// Prevents: arbitrary code execution, prompt injection, commands
// outside the allowlist, and commands that violate canvas constraints.
// ═══════════════════════════════════════════════════════════════════

import Foundation

// MARK: - Validator

enum SpatterSecurityValidator {

    // MARK: - Command Validation

    /// Validate a command envelope against current Studio constraints.
    static func validate(
        _ envelope: SpatterCommandEnvelope,
        context: SpatterStudioContext
    ) -> [SpatterValidationError] {
        var errors: [SpatterValidationError] = []

        for (index, command) in envelope.commands.enumerated() {
            let cmdErrors = validateCommand(command, at: index, context: context)
            errors.append(contentsOf: cmdErrors)
        }

        return errors
    }

    private static func validateCommand(
        _ command: SpatterCommand,
        at index: Int,
        context: SpatterStudioContext
    ) -> [SpatterValidationError] {
        var errors: [SpatterValidationError] = []

        switch command {
        case .createProject(let params):
            if params.width < 1 || params.width > 4096 { errors.append(.outOfBounds(index, "Canvas width must be 1–4096")) }
            if params.height < 1 || params.height > 4096 { errors.append(.outOfBounds(index, "Canvas height must be 1–4096")) }
            if params.fps < 1 || params.fps > 120 { errors.append(.outOfBounds(index, "FPS must be 1–120")) }

        case .setCanvasDimensions(let params):
            if params.width < 1 || params.width > 4096 { errors.append(.outOfBounds(index, "Canvas width must be 1–4096")) }
            if params.height < 1 || params.height > 4096 { errors.append(.outOfBounds(index, "Canvas height must be 1–4096")) }

        case .setFPS(let params):
            if params.fps < 1 || params.fps > 120 { errors.append(.outOfBounds(index, "FPS must be 1–120")) }

        case .addFrames(let params):
            if params.count < 1 || params.count > 200 { errors.append(.outOfBounds(index, "Frame count must be 1–200")) }

        case .deleteFrame(let params):
            if params.atIndex < 0 || params.atIndex >= context.timeline.totalFrames {
                errors.append(.outOfBounds(index, "Frame index \(params.atIndex) out of range (0–\(context.timeline.totalFrames - 1))"))
            }
            if context.timeline.totalFrames <= 1 {
                errors.append(.validationFailed(index, "Cannot delete the last frame"))
            }

        case .goToFrame(let params):
            if params.index < 0 || params.index >= context.timeline.totalFrames {
                errors.append(.outOfBounds(index, "Frame index \(params.index) out of range"))
            }

        case .addStroke(let params):
            let limit = context.canvas.width * context.canvas.height
            if params.points.count > limit / 10 { errors.append(.tooManyElements(index, "Stroke has too many points")) }
            validateColor(params.color, at: index, errors: &errors)

        case .addLine(let params):
            validateCoordinate(params.startX, params.startY, context: context, at: index, label: "start", errors: &errors)
            validateCoordinate(params.endX, params.endY, context: context, at: index, label: "end", errors: &errors)
            validateColor(params.color, at: index, errors: &errors)

        case .addRectangle(let params):
            validateCoordinate(params.x, params.y, context: context, at: index, label: "origin", errors: &errors)
            if params.width < 0 || params.height < 0 { errors.append(.outOfBounds(index, "Rectangle dimensions must be non-negative")) }
            if let c = params.strokeColor { validateColor(c, at: index, errors: &errors) }
            if let c = params.fillColor { validateColor(c, at: index, errors: &errors) }

        case .addCircle(let params):
            if params.radius < 0 { errors.append(.outOfBounds(index, "Circle radius must be non-negative")) }
            if let c = params.strokeColor { validateColor(c, at: index, errors: &errors) }
            if let c = params.fillColor { validateColor(c, at: index, errors: &errors) }

        case .addText(let params):
            if params.text.isEmpty { errors.append(.validationFailed(index, "Text cannot be empty")) }
            if params.text.count > 5000 { errors.append(.validationFailed(index, "Text too long (max 5000 chars)")) }
            validateColor(params.color, at: index, errors: &errors)

        case .selectTool(let params):
            guard DrawingTool(rawValue: params.tool) != nil else {
                errors.append(.unknownTool(index, "Unknown tool: \(params.tool)"))
            }

        case .setStrokeWidth(let params):
            if params.width < 0.1 || params.width > 100 { errors.append(.outOfBounds(index, "Stroke width must be 0.1–100")) }

        case .setStrokeColor(let params):
            validateColor(params.hex, at: index, errors: &errors)

        case .setFillColor(let params):
            validateColor(params.hex, at: index, errors: &errors)

        case .addLayer, .selectLayer, .setLayerVisibility, .setLayerOpacity,
             .duplicateLayer, .deleteLayer, .renameLayer, .reorderLayers,
             .setLayerLock, .setLayerBlendMode:
            break

        case .setStrokeOpacity(let params):
            if params.opacity < 0 || params.opacity > 1 { errors.append(.outOfBounds(index, "Opacity must be 0–1")) }

        case .setToolOpacity(let params):
            if params.opacity < 0 || params.opacity > 1 { errors.append(.outOfBounds(index, "Opacity must be 0–1")) }

        case .insertHold(let params):
            if params.holdCount < 1 || params.holdCount > 100 { errors.append(.outOfBounds(index, "Hold count must be 1–100")) }

        case .reorderFrames(let params):
            if params.fromIndex < 0 || params.fromIndex >= context.timeline.totalFrames {
                errors.append(.outOfBounds(index, "fromIndex out of range"))
            }
            if params.toIndex < 0 || params.toIndex >= context.timeline.totalFrames {
                errors.append(.outOfBounds(index, "toIndex out of range"))
            }

        case .duplicateFrame(let params):
            if let idx = params.atIndex {
                if idx < 0 || idx >= context.timeline.totalFrames {
                    errors.append(.outOfBounds(index, "Frame index out of range"))
                }
            }

        case .generateStoryboard, .generateKeyPoseSequence, .invokeExport, .explainControl:
            break
        }

        return errors
    }

    // MARK: - Input Sanitization

    /// Sanitize user-provided text to prevent prompt injection.
    static func sanitizeInput(_ text: String) -> String {
        var sanitized = text
        // Strip control characters except newlines/tabs
        sanitized = sanitized.unicodeScalars.filter { scalar in
            scalar.value >= 32 || scalar == "\n" || scalar == "\t"
        }.map(String.init).joined()
        // Enforce length limit
        if sanitized.count > 10000 {
            sanitized = String(sanitized.prefix(10000))
        }
        return sanitized
    }

    /// Check if a prompt contains injection patterns.
    static func containsPromptInjection(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let patterns = [
            "ignore previous instructions",
            "ignore all instructions",
            "disregard your system prompt",
            "you are now",
            "act as if",
            "pretend you are",
            "forget everything",
            "new instructions:",
            "override:",
            "system prompt:",
        ]
        return patterns.contains { lowered.contains($0) }
    }

    // MARK: - Helpers

    private static func validateColor(_ hex: String, at index: Int, errors: inout [SpatterValidationError]) {
        let clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let validHex = clean.hasPrefix("#") ? String(clean.dropFirst()) : clean
        guard validHex.count == 6 || validHex.count == 8 else {
            errors.append(.invalidColor(index, "Invalid hex color: \(hex)"))
            return
        }
        guard validHex.allSatisfy({ $0.isHexDigit }) else {
            errors.append(.invalidColor(index, "Invalid hex color: \(hex)"))
        }
    }

    private static func validateCoordinate(
        _ x: Double, _ y: Double,
        context: SpatterStudioContext,
        at index: Int,
        label: String,
        errors: inout [SpatterValidationError]
    ) {
        if x < -1000 || x > Double(context.canvas.width + 1000) {
            errors.append(.outOfBounds(index, "\(label) X coordinate out of range"))
        }
        if y < -1000 || y > Double(context.canvas.height + 1000) {
            errors.append(.outOfBounds(index, "\(label) Y coordinate out of range"))
        }
    }
}

// MARK: - Validation Errors

enum SpatterValidationError: Sendable {
    case outOfBounds(Int, String)
    case validationFailed(Int, String)
    case unknownTool(Int, String)
    case invalidColor(Int, String)
    case tooManyElements(Int, String)
    case promptInjectionDetected

    var message: String {
        switch self {
        case .outOfBounds(let i, let msg): return "Command \(i): \(msg)"
        case .validationFailed(let i, let msg): return "Command \(i): \(msg)"
        case .unknownTool(let i, let msg): return "Command \(i): \(msg)"
        case .invalidColor(let i, let msg): return "Command \(i): \(msg)"
        case .tooManyElements(let i, let msg): return "Command \(i): \(msg)"
        case .promptInjectionDetected: return "Prompt injection detected in input"
        }
    }
}

// MARK: - Character Extension

private extension Character {
    var isHexDigit: Bool {
        "0123456789abcdefABCDEF".contains(self)
    }
}
