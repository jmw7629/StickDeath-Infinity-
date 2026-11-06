import Foundation

/// A replayable color-drag operation in the ordered editable element stream.
/// Original drawings and image bytes remain intact; no flattened result is
/// persisted. Size, opacity and samples are owned by DrawnElement.
struct StudioSmudgeDescriptor: Codable, Equatable {
    var version = 1
    var strength: Double = 0.5

    func settings(for element: DrawnElement) -> StudioSmudge.Settings {
        .init(diameter: Double(element.width), strength: strength, opacity: element.opacity)
    }
    @discardableResult
    func validate(element: DrawnElement, width: Int, height: Int) throws -> StudioSmudge.Work {
        guard version == 1, element.tool == .smudge,
              element.brush == nil, element.shape == nil, element.fillMask == nil,
              element.eraser == nil, element.text == nil, element.fillColor == nil, element.blur == nil, element.sharpen == nil,
              element.translation == nil, element.reflection == nil, element.transform == nil, element.dodgeBurn == nil else {
            throw StudioSmudge.Failure.invalidSettings
        }
        return try StudioSmudge.validateWork(width: width, height: height,
            path: element.points.map { .init(x: $0.x, y: $0.y) }, settings: settings(for: element))
    }

    /// Shared by document validation and replay, before any bitmap allocation.
    static func validateFrame(_ frame: AnimationFrame, width: Int, height: Int) throws {
        var count = 0, touched = 0, renderedPixels = 0
        for element in frame.elements {
            let touchedPixels: Int
            if let descriptor = element.smudge {
                touchedPixels = try descriptor.validate(element: element, width: width, height: height).touchedPixels
            } else if let descriptor = element.blur {
                touchedPixels = try descriptor.validate(element: element, width: width, height: height).touchedPixels
            } else if let descriptor = element.sharpen {
                touchedPixels = try descriptor.validate(element: element, width: width, height: height).touchedPixels
            } else if let descriptor = element.dodgeBurn {
                touchedPixels = try descriptor.validate(element: element, width: width, height: height).touchedPixels
            } else if let descriptor = element.gradient {
                touchedPixels = try descriptor.validate(element: element, width: width, height: height)
            } else { continue }
            // A mixed frame shares one processing budget, not one per tool.
            count += 1; touched += touchedPixels; renderedPixels += width * height
            guard count <= 16, touched <= 33_554_432, renderedPixels <= 16_777_216 else {
                throw StudioSmudge.Failure.workLimit
            }
        }
    }
}


/// Tagged native settings for one editable raster-tool gesture. Touch input
/// and typed local instructions share this factory; unrelated options cannot
/// leak between tools and no remembered UI settings need to be changed.
enum StudioPixelEffectSettings: Equatable {
    case smudge(StudioSmudge.Settings)
    case blur(StudioBlur.Settings)
    case sharpen(StudioSharpen.Settings)
    case dodgeBurn(StudioDodgeBurn.Settings)
    var tool: DrawingTool {
        switch self {
        case .smudge: return .smudge
        case .blur: return .blur
        case .sharpen: return .sharpen
        case .dodgeBurn(let value): return value.mode == .dodge ? .dodge : .burn
        }
    }
    func element(id: String, layerID: String, points: [StrokePoint], width: Int, height: Int) throws -> DrawnElement {
        guard !id.isEmpty, id.utf8.count <= 128, !layerID.isEmpty else { throw StudioSmudge.Failure.invalidSettings }
        let result: DrawnElement
        switch self {
        case .smudge(let value):
            try value.validate()
            result = .init(id: id, tool: .smudge, points: points, color: "#000000", width: value.diameter,
                opacity: value.opacity, layerID: layerID, smudge: .init(strength: value.strength))
        case .blur(let value):
            try value.validate()
            result = .init(id: id, tool: .blur, points: points, color: "#000000", width: value.diameter,
                opacity: value.strength, layerID: layerID, blur: .init(hardness: value.hardness, radius: value.radius))
        case .sharpen(let value):
            try value.validate()
            result = .init(id: id, tool: .sharpen, points: points, color: "#000000", width: value.diameter,
                opacity: value.opacity, layerID: layerID,
                sharpen: .init(hardness: value.hardness, radius: value.radius, amount: value.amount, threshold: value.threshold))
        case .dodgeBurn(let value):
            try value.validate()
            result = .init(id: id, tool: tool, points: points, color: "#000000", width: value.diameter,
                opacity: value.opacity, layerID: layerID,
                dodgeBurn: .init(hardness: value.hardness, exposure: value.exposure, range: value.range, protectTones: value.protectTones))
        }
        try Self.validate(result, width: width, height: height)
        return result
    }
    static func validate(_ element: DrawnElement, width: Int, height: Int) throws {
        switch element.tool {
        case .smudge:
            guard let descriptor = element.smudge else { throw StudioSmudge.Failure.invalidSettings }
            _ = try descriptor.validate(element: element, width: width, height: height)
        case .blur:
            guard let descriptor = element.blur else { throw StudioBlur.Failure.invalidSettings }
            _ = try descriptor.validate(element: element, width: width, height: height)
        case .sharpen:
            guard let descriptor = element.sharpen else { throw StudioSharpen.Failure.invalidSettings }
            _ = try descriptor.validate(element: element, width: width, height: height)
        case .dodge, .burn:
            guard let descriptor = element.dodgeBurn else { throw StudioDodgeBurn.Failure.invalidSettings }
            _ = try descriptor.validate(element: element, width: width, height: height)
        default: throw StudioSmudge.Failure.invalidSettings
        }
    }
}
