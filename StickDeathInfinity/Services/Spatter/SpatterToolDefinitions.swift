// ═══════════════════════════════════════════════════════════════════
// SpatterToolDefinitions — OpenAI Responses API / function-calling
// tool schemas. Model name is configuration-driven, not hard-coded.
// ═══════════════════════════════════════════════════════════════════

import Foundation

// MARK: - Tool Definition

/// JSON-schema-compatible tool definition for the OpenAI Responses API.
struct SpatterToolDefinition: Codable, Sendable {
    let name: String
    let description: String
    let parameters: SpatterToolParameters
}

struct SpatterToolParameters: Codable, Sendable {
    let type: String
    let properties: [String: SpatterToolProperty]
    let required: [String]
}

struct SpatterToolProperty: Codable, Sendable {
    let type: String
    let description: String
    let enumValues: [String]?
    let items: SpatterToolItems?
    let properties: [String: SpatterToolProperty]?

    enum CodingKeys: String, CodingKey {
        case type, description, items, properties
        case enumValues = "enum"
    }
}

struct SpatterToolItems: Codable, Sendable {
    let type: String
    let properties: [String: SpatterToolProperty]?
}

// MARK: - All Tool Definitions

enum SpatterToolDefinitions {

    static let allTools: [SpatterToolDefinition] = [
        selectTool, setStrokeWidth, setStrokeColor, setFillColor,
        addFrames, duplicateFrame, deleteFrame, goToFrame,
        addLayer, selectLayer, setLayerVisibility, setLayerOpacity,
        addStroke, addLine, addRectangle, addCircle, addText,
        generateStoryboard, generateKeyPoseSequence,
        invokeExport, explainControl
    ]

    // MARK: - Tool: selectTool

    static let selectTool = SpatterToolDefinition(
        name: "select_tool",
        description: "Select an active drawing tool in the Studio.",
        parameters: SpatterToolParameters(
            type: "object",
            properties: [
                "tool": SpatterToolProperty(
                    type: "string",
                    description: "The tool to select.",
                    enumValues: DrawingTool.allCases.map(\.rawValue),
                    items: nil, properties: nil
                )
            ],
            required: ["tool"]
        )
    )

    // MARK: - Tool: setStrokeWidth

    static let setStrokeWidth = SpatterToolDefinition(
        name: "set_stroke_width",
        description: "Set the active stroke width (1.0–100.0).",
        parameters: SpatterToolParameters(
            type: "object",
            properties: [
                "width": SpatterToolProperty(type: "number", description: "Stroke width in points.", enumValues: nil, items: nil, properties: nil)
            ],
            required: ["width"]
        )
    )

    // MARK: - Tool: setStrokeColor

    static let setStrokeColor = SpatterToolDefinition(
        name: "set_stroke_color",
        description: "Set the active stroke color by hex value.",
        parameters: SpatterToolParameters(
            type: "object",
            properties: [
                "hex": SpatterToolProperty(type: "string", description: "Hex color (e.g. '#FF0000').", enumValues: nil, items: nil, properties: nil)
            ],
            required: ["hex"]
        )
    )

    // MARK: - Tool: setFillColor

    static let setFillColor = SpatterToolDefinition(
        name: "set_fill_color",
        description: "Set the active fill color by hex value.",
        parameters: SpatterToolParameters(
            type: "object",
            properties: [
                "hex": SpatterToolProperty(type: "string", description: "Hex color (e.g. '#00FF00').", enumValues: nil, items: nil, properties: nil)
            ],
            required: ["hex"]
        )
    )

    // MARK: - Tool: addFrames

    static let addFrames = SpatterToolDefinition(
        name: "add_frames",
        description: "Add blank frames to the timeline after the current frame.",
        parameters: SpatterToolParameters(
            type: "object",
            properties: [
                "count": SpatterToolProperty(type: "integer", description: "Number of frames to add (1–100).", enumValues: nil, items: nil, properties: nil)
            ],
            required: ["count"]
        )
    )

    // MARK: - Tool: duplicateFrame

    static let duplicateFrame = SpatterToolDefinition(
        name: "duplicate_frame",
        description: "Duplicate the current frame (or a specific frame index).",
        parameters: SpatterToolParameters(
            type: "object",
            properties: [
                "at_index": SpatterToolProperty(type: "integer", description: "Optional frame index to duplicate. If nil, duplicates current frame.", enumValues: nil, items: nil, properties: nil)
            ],
            required: []
        )
    )

    // MARK: - Tool: deleteFrame

    static let deleteFrame = SpatterToolDefinition(
        name: "delete_frame",
        description: "Delete a frame at the given index.",
        parameters: SpatterToolParameters(
            type: "object",
            properties: [
                "at_index": SpatterToolProperty(type: "integer", description: "Frame index to delete.", enumValues: nil, items: nil, properties: nil)
            ],
            required: ["at_index"]
        )
    )

    // MARK: - Tool: goToFrame

    static let goToFrame = SpatterToolDefinition(
        name: "go_to_frame",
        description: "Navigate to a specific frame index in the timeline.",
        parameters: SpatterToolParameters(
            type: "object",
            properties: [
                "index": SpatterToolProperty(type: "integer", description: "Frame index to navigate to.", enumValues: nil, items: nil, properties: nil)
            ],
            required: ["index"]
        )
    )

    // MARK: - Tool: addLayer

    static let addLayer = SpatterToolDefinition(
        name: "add_layer",
        description: "Add a new named layer to the layer stack.",
        parameters: SpatterToolParameters(
            type: "object",
            properties: [
                "name": SpatterToolProperty(type: "string", description: "Optional layer name. Defaults to 'Layer N'.", enumValues: nil, items: nil, properties: nil)
            ],
            required: []
        )
    )

    // MARK: - Tool: selectLayer

    static let selectLayer = SpatterToolDefinition(
        name: "select_layer",
        description: "Select a layer by its ID.",
        parameters: SpatterToolParameters(
            type: "object",
            properties: [
                "layer_id": SpatterToolProperty(type: "string", description: "The layer ID to select.", enumValues: nil, items: nil, properties: nil)
            ],
            required: ["layer_id"]
        )
    )

    // MARK: - Tool: setLayerVisibility

    static let setLayerVisibility = SpatterToolDefinition(
        name: "set_layer_visibility",
        description: "Show or hide a layer.",
        parameters: SpatterToolParameters(
            type: "object",
            properties: [
                "layer_id": SpatterToolProperty(type: "string", description: "The layer ID.", enumValues: nil, items: nil, properties: nil),
                "visible": SpatterToolProperty(type: "boolean", description: "Whether the layer should be visible.", enumValues: nil, items: nil, properties: nil)
            ],
            required: ["layer_id", "visible"]
        )
    )

    // MARK: - Tool: setLayerOpacity

    static let setLayerOpacity = SpatterToolDefinition(
        name: "set_layer_opacity",
        description: "Set the opacity of a layer (0.0–1.0).",
        parameters: SpatterToolParameters(
            type: "object",
            properties: [
                "layer_id": SpatterToolProperty(type: "string", description: "The layer ID.", enumValues: nil, items: nil, properties: nil),
                "opacity": SpatterToolProperty(type: "number", description: "Opacity from 0.0 (invisible) to 1.0 (opaque).", enumValues: nil, items: nil, properties: nil)
            ],
            required: ["layer_id", "opacity"]
        )
    )

    // MARK: - Tool: addStroke

    static let addStroke = SpatterToolDefinition(
        name: "add_stroke",
        description: "Add a freehand stroke with multiple points to the current frame.",
        parameters: SpatterToolParameters(
            type: "object",
            properties: [
                "points": SpatterToolProperty(
                    type: "array",
                    description: "Array of {x, y, pressure?} points.",
                    enumValues: nil,
                    items: SpatterToolItems(type: "object", properties: [
                        "x": SpatterToolProperty(type: "number", description: "X coordinate (0–canvasWidth).", enumValues: nil, items: nil, properties: nil),
                        "y": SpatterToolProperty(type: "number", description: "Y coordinate (0–canvasHeight).", enumValues: nil, items: nil, properties: nil),
                        "pressure": SpatterToolProperty(type: "number", description: "Optional pressure (0.0–1.0).", enumValues: nil, items: nil, properties: nil)
                    ]),
                    properties: nil
                ),
                "color": SpatterToolProperty(type: "string", description: "Hex color.", enumValues: nil, items: nil, properties: nil),
                "width": SpatterToolProperty(type: "number", description: "Stroke width.", enumValues: nil, items: nil, properties: nil),
                "opacity": SpatterToolProperty(type: "number", description: "Stroke opacity.", enumValues: nil, items: nil, properties: nil),
                "layer_id": SpatterToolProperty(type: "string", description: "Target layer ID. If nil, uses active layer.", enumValues: nil, items: nil, properties: nil)
            ],
            required: ["points", "color", "width", "opacity"]
        )
    )

    // MARK: - Tool: addLine

    static let addLine = SpatterToolDefinition(
        name: "add_line",
        description: "Add a straight line from start to end point.",
        parameters: SpatterToolParameters(
            type: "object",
            properties: [
                "start_x": SpatterToolProperty(type: "number", description: "Start X.", enumValues: nil, items: nil, properties: nil),
                "start_y": SpatterToolProperty(type: "number", description: "Start Y.", enumValues: nil, items: nil, properties: nil),
                "end_x": SpatterToolProperty(type: "number", description: "End X.", enumValues: nil, items: nil, properties: nil),
                "end_y": SpatterToolProperty(type: "number", description: "End Y.", enumValues: nil, items: nil, properties: nil),
                "color": SpatterToolProperty(type: "string", description: "Hex color.", enumValues: nil, items: nil, properties: nil),
                "width": SpatterToolProperty(type: "number", description: "Line width.", enumValues: nil, items: nil, properties: nil),
                "opacity": SpatterToolProperty(type: "number", description: "Line opacity.", enumValues: nil, items: nil, properties: nil)
            ],
            required: ["start_x", "start_y", "end_x", "end_y", "color", "width", "opacity"]
        )
    )

    // MARK: - Tool: addRectangle

    static let addRectangle = SpatterToolDefinition(
        name: "add_rectangle",
        description: "Add a rectangle to the current frame.",
        parameters: SpatterToolParameters(
            type: "object",
            properties: [
                "x": SpatterToolProperty(type: "number", description: "Top-left X.", enumValues: nil, items: nil, properties: nil),
                "y": SpatterToolProperty(type: "number", description: "Top-left Y.", enumValues: nil, items: nil, properties: nil),
                "width": SpatterToolProperty(type: "number", description: "Width.", enumValues: nil, items: nil, properties: nil),
                "height": SpatterToolProperty(type: "number", description: "Height.", enumValues: nil, items: nil, properties: nil),
                "stroke_color": SpatterToolProperty(type: "string", description: "Hex stroke color.", enumValues: nil, items: nil, properties: nil),
                "fill_color": SpatterToolProperty(type: "string", description: "Hex fill color.", enumValues: nil, items: nil, properties: nil),
                "stroke_width": SpatterToolProperty(type: "number", description: "Stroke width.", enumValues: nil, items: nil, properties: nil)
            ],
            required: ["x", "y", "width", "height", "stroke_width"]
        )
    )

    // MARK: - Tool: addCircle

    static let addCircle = SpatterToolDefinition(
        name: "add_circle",
        description: "Add a circle/ellipse to the current frame.",
        parameters: SpatterToolParameters(
            type: "object",
            properties: [
                "center_x": SpatterToolProperty(type: "number", description: "Center X.", enumValues: nil, items: nil, properties: nil),
                "center_y": SpatterToolProperty(type: "number", description: "Center Y.", enumValues: nil, items: nil, properties: nil),
                "radius": SpatterToolProperty(type: "number", description: "Radius.", enumValues: nil, items: nil, properties: nil),
                "stroke_color": SpatterToolProperty(type: "string", description: "Hex stroke color.", enumValues: nil, items: nil, properties: nil),
                "fill_color": SpatterToolProperty(type: "string", description: "Hex fill color.", enumValues: nil, items: nil, properties: nil),
                "stroke_width": SpatterToolProperty(type: "number", description: "Stroke width.", enumValues: nil, items: nil, properties: nil)
            ],
            required: ["center_x", "center_y", "radius", "stroke_width"]
        )
    )

    // MARK: - Tool: addText

    static let addText = SpatterToolDefinition(
        name: "add_text",
        description: "Add a text element to the current frame.",
        parameters: SpatterToolParameters(
            type: "object",
            properties: [
                "x": SpatterToolProperty(type: "number", description: "Text X position.", enumValues: nil, items: nil, properties: nil),
                "y": SpatterToolProperty(type: "number", description: "Text Y position.", enumValues: nil, items: nil, properties: nil),
                "text": SpatterToolProperty(type: "string", description: "Text content.", enumValues: nil, items: nil, properties: nil),
                "color": SpatterToolProperty(type: "string", description: "Hex color.", enumValues: nil, items: nil, properties: nil),
                "font_size": SpatterToolProperty(type: "number", description: "Font size in points.", enumValues: nil, items: nil, properties: nil)
            ],
            required: ["x", "y", "text", "color", "font_size"]
        )
    )

    // MARK: - Tool: generateStoryboard

    static let generateStoryboard = SpatterToolDefinition(
        name: "generate_storyboard",
        description: "Generate a multi-frame storyboard as a sequence of scenes, each with a title, description, frame count, and key elements.",
        parameters: SpatterToolParameters(
            type: "object",
            properties: [
                "scenes": SpatterToolProperty(
                    type: "array",
                    description: "Array of storyboard scenes.",
                    enumValues: nil,
                    items: SpatterToolItems(type: "object", properties: [
                        "title": SpatterToolProperty(type: "string", description: "Scene title.", enumValues: nil, items: nil, properties: nil),
                        "description": SpatterToolProperty(type: "string", description: "Scene description.", enumValues: nil, items: nil, properties: nil),
                        "frame_count": SpatterToolProperty(type: "integer", description: "Number of frames for this scene.", enumValues: nil, items: nil, properties: nil),
                        "key_elements": SpatterToolProperty(type: "string", description: "Comma-separated key drawing elements.", enumValues: nil, items: nil, properties: nil)
                    ]),
                    properties: nil
                )
            ],
            required: ["scenes"]
        )
    )

    // MARK: - Tool: generateKeyPoseSequence

    static let generateKeyPoseSequence = SpatterToolDefinition(
        name: "generate_key_pose_sequence",
        description: "Generate frame sequences from explicit key poses using deterministic interpolation.",
        parameters: SpatterToolParameters(
            type: "object",
            properties: [
                "poses": SpatterToolProperty(type: "integer", description: "Number of key poses to generate (2+).", enumValues: nil, items: nil, properties: nil),
                "hold_frames": SpatterToolProperty(type: "integer", description: "Frames to hold each pose.", enumValues: nil, items: nil, properties: nil),
                "interpolation_frames": SpatterToolProperty(type: "integer", description: "Frames of interpolated transition between poses.", enumValues: nil, items: nil, properties: nil)
            ],
            required: ["poses", "hold_frames", "interpolation_frames"]
        )
    )

    // MARK: - Tool: invokeExport

    static let invokeExport = SpatterToolDefinition(
        name: "invoke_export",
        description: "Start the native export pipeline for the current animation.",
        parameters: SpatterToolParameters(
            type: "object",
            properties: [
                "format": SpatterToolProperty(type: "string", description: "Export format (mp4, gif, png, spritesheet).", enumValues: ["mp4", "gif", "png", "spritesheet"], items: nil, properties: nil),
                "quality": SpatterToolProperty(type: "string", description: "Export quality (standard, hd, fullHD).", enumValues: ["standard", "hd", "fullHD"], items: nil, properties: nil)
            ],
            required: []
        )
    )

    // MARK: - Tool: explainControl

    static let explainControl = SpatterToolDefinition(
        name: "explain_control",
        description: "Explain what a Studio control does and how to use it.",
        parameters: SpatterToolParameters(
            type: "object",
            properties: [
                "control_name": SpatterToolProperty(type: "string", description: "Name or ID of the control to explain.", enumValues: nil, items: nil, properties: nil)
            ],
            required: ["control_name"]
        )
    )
}
