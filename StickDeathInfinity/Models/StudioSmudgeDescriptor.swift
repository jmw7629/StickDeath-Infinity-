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
              element.translation == nil, element.reflection == nil, element.transform == nil else {
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
            } else { continue }
            // A mixed frame shares one processing budget, not one per tool.
            count += 1; touched += touchedPixels; renderedPixels += width * height
            guard count <= 16, touched <= 33_554_432, renderedPixels <= 16_777_216 else {
                throw StudioSmudge.Failure.workLimit
            }
        }
    }
}
