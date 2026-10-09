import Foundation

/// Replayable RGB unsharp masking in the same ordered stream as its sources.
/// Width and opacity remain canonical on the element, never stored twice.
struct StudioSharpenDescriptor: Codable, Equatable {
    var version = 1
    var hardness: Double = 0.5
    var radius: Double = 2
    var amount: Double = 0.5
    var threshold: Double = 0.02

    func settings(for element: DrawnElement) -> StudioSharpen.Settings {
        .init(diameter: Double(element.width), hardness: hardness, radius: radius,
              amount: amount, threshold: threshold, opacity: element.opacity)
    }

    @discardableResult
    func validate(element: DrawnElement, width: Int, height: Int) throws -> StudioBlur.Work {
        guard version == 1, element.tool == .sharpen,
              element.brush == nil, element.shape == nil, element.fillMask == nil,
              element.eraser == nil, element.text == nil, element.fillColor == nil,
              element.smudge == nil, element.blur == nil, element.translation == nil,
              element.reflection == nil, element.transform == nil, element.dodgeBurn == nil else {
            throw StudioSharpen.Failure.invalidSettings
        }
        return try StudioSharpen.validateWork(width: width, height: height,
            path: element.points.map { .init(x: $0.x, y: $0.y) }, settings: settings(for: element))
    }
}
