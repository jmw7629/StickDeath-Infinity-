import Foundation

/// Replayable Gaussian blur in the same ordered stream as its editable sources.
/// Canonical width and opacity supply diameter and strength exactly once.
struct StudioBlurDescriptor: Codable, Equatable {
    var version = 1
    var hardness: Double = 0.5
    var radius: Double = 4

    func settings(for element: DrawnElement) -> StudioBlur.Settings {
        .init(diameter: Double(element.width), hardness: hardness, radius: radius, strength: element.opacity)
    }

    @discardableResult
    func validate(element: DrawnElement, width: Int, height: Int) throws -> StudioBlur.Work {
        guard version == 1, element.tool == .blur,
              element.brush == nil, element.shape == nil, element.fillMask == nil,
              element.eraser == nil, element.text == nil, element.fillColor == nil,
              element.smudge == nil, element.translation == nil,
              element.reflection == nil, element.transform == nil else { throw StudioBlur.Failure.invalidSettings }
        return try StudioBlur.validateWork(width: width, height: height,
            path: element.points.map { .init(x: $0.x, y: $0.y) }, settings: settings(for: element))
    }
}
