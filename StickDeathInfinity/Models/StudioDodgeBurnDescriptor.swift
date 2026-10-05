import Foundation

/// Exposure is replayed in the ordered artwork stream. Tool chooses direction;
/// element owns size and opacity, while this descriptor owns exposure controls.
struct StudioDodgeBurnDescriptor: Codable, Equatable {
    var version = 1
    var hardness: Double = 0.5
    var exposure: Double = 0.25
    var range: StudioDodgeBurn.TonalRange = .midtones
    var protectTones = true

    func settings(for element: DrawnElement) -> StudioDodgeBurn.Settings {
        .init(mode: element.tool == .burn ? .burn : .dodge,
              diameter: Double(element.width), hardness: hardness, exposure: exposure,
              range: range, protectTones: protectTones, opacity: element.opacity)
    }
    @discardableResult
    func validate(element: DrawnElement, width: Int, height: Int) throws -> StudioBlur.Work {
        guard version == 1, element.tool == .dodge || element.tool == .burn,
              element.brush == nil, element.shape == nil, element.fillMask == nil,
              element.eraser == nil, element.text == nil, element.fillColor == nil,
              element.smudge == nil, element.blur == nil, element.sharpen == nil,
              element.translation == nil, element.reflection == nil, element.transform == nil else {
            throw StudioDodgeBurn.Failure.invalidSettings
        }
        return try StudioDodgeBurn.validateWork(width: width, height: height,
            path: element.points.map { .init(x: $0.x, y: $0.y) }, settings: settings(for: element))
    }
}
