// ═══════════════════════════════════════════════════════════════════
// SpatterCommand — Strict Codable command types for Studio operations
// These are the allowlisted actions Spatter can request via tool calls.
// Each command maps 1:1 to a verified StudioViewModel operation.
// ═══════════════════════════════════════════════════════════════════

import Foundation

// MARK: - Command Envelope

struct SpatterCommandEnvelope: Codable, Sendable {
    let commands: [SpatterCommand]
    let description: String?
}

// MARK: - Command Enum

/// All commands must be validated against canvas/frame/layer constraints
/// before being applied. Unknown commands are rejected.
enum SpatterCommand: Codable, Sendable {
    // Project
    case createProject(CreateProjectParams)
    case renameProject(RenameProjectParams)
    case setCanvasDimensions(SetCanvasParams)
    case setFPS(SetFPSParams)

    // Frames
    case addFrames(AddFramesParams)
    case duplicateFrame(DuplicateFrameParams)
    case deleteFrame(DeleteFrameParams)
    case reorderFrames(ReorderFramesParams)
    case goToFrame(GoToFrameParams)
    case insertHold(InsertHoldParams)

    // Tools
    case selectTool(SelectToolParams)
    case setStrokeWidth(SetStrokeWidthParams)
    case setStrokeOpacity(SetStrokeOpacityParams)
    case setToolOpacity(SetToolOpacityParams)

    // Colors
    case setStrokeColor(SetColorParams)
    case setFillColor(SetColorParams)

    // Layers
    case addLayer(AddLayerParams)
    case renameLayer(RenameLayerParams)
    case duplicateLayer(DuplicateLayerParams)
    case deleteLayer(DeleteLayerParams)
    case reorderLayers(ReorderLayersParams)
    case selectLayer(SelectLayerParams)
    case setLayerVisibility(SetLayerVisibilityParams)
    case setLayerLock(SetLayerLockParams)
    case setLayerOpacity(SetLayerOpacityParams)
    case setLayerBlendMode(SetLayerBlendModeParams)

    // Drawing Primitives
    case addStroke(AddStrokeParams)
    case addLine(AddLineParams)
    case addRectangle(AddRectangleParams)
    case addCircle(AddCircleParams)
    case addText(AddTextParams)

    // Animation Sequences
    case generateStoryboard(StoryboardParams)
    case generateKeyPoseSequence(KeyPoseSequenceParams)

    // Export
    case invokeExport(InvokeExportParams)

    // Navigation / UI
    case explainControl(ExplainControlParams)

    // MARK: - Param Types

    struct CreateProjectParams: Codable, Sendable {
        let name: String
        let width: Int
        let height: Int
        let fps: Int
    }

    struct RenameProjectParams: Codable, Sendable {
        let name: String
    }

    struct SetCanvasParams: Codable, Sendable {
        let width: Int
        let height: Int
    }

    struct SetFPSParams: Codable, Sendable {
        let fps: Int
    }

    struct AddFramesParams: Codable, Sendable {
        let count: Int
    }

    struct DuplicateFrameParams: Codable, Sendable {
        let atIndex: Int?
    }

    struct DeleteFrameParams: Codable, Sendable {
        let atIndex: Int
    }

    struct ReorderFramesParams: Codable, Sendable {
        let fromIndex: Int
        let toIndex: Int
    }

    struct GoToFrameParams: Codable, Sendable {
        let index: Int
    }

    struct InsertHoldParams: Codable, Sendable {
        let frameIndex: Int
        let holdCount: Int
    }

    struct SelectToolParams: Codable, Sendable {
        let tool: String
    }

    struct SetStrokeWidthParams: Codable, Sendable {
        let width: Double
    }

    struct SetStrokeOpacityParams: Codable, Sendable {
        let opacity: Double
    }

    struct SetToolOpacityParams: Codable, Sendable {
        let opacity: Double
    }

    struct SetColorParams: Codable, Sendable {
        let hex: String
    }

    struct AddLayerParams: Codable, Sendable {
        let name: String?
    }

    struct RenameLayerParams: Codable, Sendable {
        let layerID: String
        let name: String
    }

    struct DuplicateLayerParams: Codable, Sendable {
        let layerID: String
    }

    struct DeleteLayerParams: Codable, Sendable {
        let layerID: String
    }

    struct ReorderLayersParams: Codable, Sendable {
        let layerID: String
        let toIndex: Int
    }

    struct SelectLayerParams: Codable, Sendable {
        let layerID: String
    }

    struct SetLayerVisibilityParams: Codable, Sendable {
        let layerID: String
        let visible: Bool
    }

    struct SetLayerLockParams: Codable, Sendable {
        let layerID: String
        let lockMode: String
    }

    struct SetLayerOpacityParams: Codable, Sendable {
        let layerID: String
        let opacity: Double
    }

    struct SetLayerBlendModeParams: Codable, Sendable {
        let layerID: String
        let blendMode: String
    }

    struct AddStrokeParams: Codable, Sendable {
        let points: [CommandPoint]
        let color: String
        let width: Double
        let opacity: Double
        let layerID: String?
    }

    struct AddLineParams: Codable, Sendable {
        let startX: Double
        let startY: Double
        let endX: Double
        let endY: Double
        let color: String
        let width: Double
        let opacity: Double
        let layerID: String?
    }

    struct AddRectangleParams: Codable, Sendable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let strokeColor: String?
        let fillColor: String?
        let strokeWidth: Double
        let layerID: String?
    }

    struct AddCircleParams: Codable, Sendable {
        let centerX: Double
        let centerY: Double
        let radius: Double
        let strokeColor: String?
        let fillColor: String?
        let strokeWidth: Double
        let layerID: String?
    }

    struct AddTextParams: Codable, Sendable {
        let x: Double
        let y: Double
        let text: String
        let color: String
        let fontSize: Double
        let layerID: String?
    }

    struct StoryboardParams: Codable, Sendable {
        let scenes: [StoryboardScene]
    }

    struct StoryboardScene: Codable, Sendable {
        let title: String
        let description: String
        let frameCount: Int
        let keyElements: [String]
    }

    struct KeyPoseSequenceParams: Codable, Sendable {
        let poses: [KeyPose]
        let holdFrames: Int
        let interpolationFrames: Int
    }

    struct KeyPose: Codable, Sendable {
        let elements: [DrawnElement]
    }

    struct InvokeExportParams: Codable, Sendable {
        let format: String?
        let quality: String?
    }

    struct ExplainControlParams: Codable, Sendable {
        let controlName: String
    }

    // MARK: - Helper Types

    struct CommandPoint: Codable, Sendable {
        let x: Double
        let y: Double
        let pressure: Double?
    }
}

// MARK: - Command Result

/// Structured result returned to Spatter after command execution.
struct SpatterCommandResult: Sendable {
    let succeeded: Bool
    let appliedCommands: Int
    let failedCommands: Int
    let errors: [SpatterCommandError]
    let summary: String

    struct SpatterCommandError: Sendable {
        let commandIndex: Int
        let reason: String
    }
}
