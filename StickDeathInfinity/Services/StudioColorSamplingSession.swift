import Foundation
import SwiftUI

/// Captured at the beginning of a picker gesture, so a late touch cannot sample
/// another frame, revision or project. Sampling changes a drawing setting only.
struct StudioColorSampleContext: Equatable {
    let projectID: UUID
    let revision: Int
    let frameID: String
    let width: Int
    let height: Int
}

/// One attempt per physical gesture. An unavailable start cannot become a
/// picker later; an observed context/layout change permanently invalidates it.
struct StudioColorSampleGesture {
    struct Layout: Equatable {
        let viewport: CGSize
        let scale: CGFloat
        let offset: CGSize
        var isValid: Bool {
            viewport.width.isFinite && viewport.height.isFinite && viewport.width > 0 && viewport.height > 0 &&
            scale.isFinite && scale > 0 && offset.width.isFinite && offset.height.isFinite
        }
    }
    private enum State {
        case idle, unavailable, cancelled
        case captured(StudioColorSampleContext, Layout)
    }
    private var state = State.idle
    var startedAsPicker: Bool {
        switch state { case .captured, .cancelled: return true; default: return false }
    }
    mutating func invalidate() {
        if startedAsPicker { state = .cancelled }
    }
    mutating func update(context: StudioColorSampleContext?, layout: Layout, foreground: Bool) {
        switch state {
        case .idle:
            guard foreground, layout.isValid, let context else { state = .unavailable; return }
            state = .captured(context, layout)
        case .captured(let original, let originalLayout):
            if !foreground || context != original || !layout.isValid || layout != originalLayout { state = .cancelled }
        case .unavailable, .cancelled: break
        }
    }
    func resolve(location: CGPoint, context: StudioColorSampleContext?, layout: Layout, foreground: Bool)
        -> (context: StudioColorSampleContext, point: CGPoint)? {
        guard case .captured(let captured, let original) = state, foreground,
              context == captured, layout == original, layout.isValid,
              location.x.isFinite, location.y.isFinite,
              location.x >= 0, location.y >= 0,
              location.x < layout.viewport.width, location.y < layout.viewport.height else { return nil }
        // SwiftUI reports location in this gesture's untransformed local view.
        return (captured, CGPoint(x: location.x / layout.viewport.width * CGFloat(captured.width),
                                  y: location.y / layout.viewport.height * CGFloat(captured.height)))
    }
}

@MainActor
extension StudioViewModel {
    func beginColorSample() -> StudioColorSampleContext? {
        guard isEditing, !isPlaying, selectedTool == .eyedropper,
              activeStrokeID == nil, pendingBrushStroke == nil else { return nil }
        return .init(projectID: document.id, revision: document.revision,
            frameID: currentFrame.id, width: document.width, height: document.height)
    }

    @discardableResult
    func sampleArtworkColor(at point: CGPoint, captured: StudioColorSampleContext) -> Bool {
        guard beginColorSample() == captured else {
            message = "Studio changed during color sampling. Tap the current artwork again."
            return false
        }
        let snapshot = document
        let raster = rasterData(currentFrame.rasterAssetID)
        do {
            let sample = try StudioColorSamplingService.sample(document: snapshot,
                frameID: captured.frameID, point: point, rasterData: raster)
            guard beginColorSample() == captured else {
                message = "Studio changed before the color sample was ready. Tap again."
                return false
            }
            strokeColor = Color(.sRGB, red: Double(sample.red) / 255,
                green: Double(sample.green) / 255, blue: Double(sample.blue) / 255, opacity: 1)
            message = "Sampled " + sample.hex + " from visible artwork."
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }
}
