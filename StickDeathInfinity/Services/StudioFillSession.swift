import Foundation
import SwiftUI

struct StudioFillContext: Equatable {
    let projectID: UUID
    let revision: Int
    let frameID: String
    let layerID: String
    let width: Int
    let height: Int
    let color: String
    let opacity: Double
    let settings: StudioFillRegion.Settings
    let sampleAllLayers: Bool

    @MainActor static func current(_ vm: StudioViewModel, ownedStroke: String? = nil) -> Self? {
        guard vm.isEditing, !vm.isPlaying, vm.selectedTool == .fill,
              vm.activeStrokeID == ownedStroke, vm.pendingBrushStroke == nil,
              vm.fillTolerance.isFinite, (0...128).contains(vm.fillTolerance),
              vm.fillExpand.isFinite, (-5...5).contains(vm.fillExpand),
              vm.fillGapClose.isFinite, (0...5).contains(vm.fillGapClose),
              let layer = vm.layers.first(where: { $0.id == vm.activeLayerID }), layer.visible,
              !layer.isFullyLocked, ["free", "position"].contains(layer.lockMode) else { return nil }
        let opacity = vm.capturedStrokeOpacity
        guard opacity.isFinite, (0...1).contains(opacity) else { return nil }
        return Self(projectID: vm.document.id, revision: vm.document.revision,
            frameID: vm.currentFrame.id, layerID: vm.activeLayerID,
            width: vm.canvasWidth, height: vm.canvasHeight, color: vm.strokeColorHex, opacity: opacity,
            settings: .init(tolerance: Int(vm.fillTolerance.rounded()), contiguous: vm.fillContiguous,
                expand: Int(vm.fillExpand.rounded()), gapClose: vm.fillContiguous ? Int(vm.fillGapClose.rounded()) : 0,
                antiAlias: vm.fillAntiAlias), sampleAllLayers: vm.fillSampleAll)
    }
}

/// A touch may not turn into a fill after an invalid start, nor acquire new
/// settings or another viewport partway through the same physical gesture.
struct StudioFillGesture {
    typealias Layout = StudioColorSampleGesture.Layout
    private enum State { case idle, unavailable, cancelled, captured(StudioFillContext, Layout) }
    private var state = State.idle
    var startedAsFill: Bool {
        switch state { case .captured, .cancelled: return true; default: return false }
    }
    mutating func invalidate() { if startedAsFill { state = .cancelled } }
    mutating func update(context: StudioFillContext?, layout: Layout, foreground: Bool) {
        switch state {
        case .idle:
            guard let context, foreground, layout.isValid else { state = .unavailable; return }
            state = .captured(context, layout)
        case .captured(let original, let previous):
            if !foreground || context != original || layout != previous || !layout.isValid { state = .cancelled }
        case .unavailable, .cancelled: break
        }
    }
    func resolve(location: CGPoint, context: StudioFillContext?, layout: Layout, foreground: Bool)
        -> (context: StudioFillContext, point: CGPoint)? {
        guard case .captured(let captured, let original) = state, foreground,
              context == captured, layout == original, layout.isValid,
              location.x.isFinite, location.y.isFinite, location.x >= 0, location.y >= 0,
              location.x < layout.viewport.width, location.y < layout.viewport.height else { return nil }
        return (captured, CGPoint(x: location.x / layout.viewport.width * CGFloat(captured.width),
                                  y: location.y / layout.viewport.height * CGFloat(captured.height)))
    }
}

@MainActor
final class StudioFillSession: ObservableObject {
    @Published private(set) var isFilling = false
    private var operationID: String?
    private var work: Task<DrawnElement, Error>?

    func cancel() { work?.cancel() }

    @discardableResult
    func fill(_ vm: StudioViewModel, context: StudioFillContext, point: CGPoint) async -> Bool {
        guard !isFilling, StudioFillContext.current(vm) == context else {
            vm.message = "Studio changed before fill started. Tap the current artwork again."
            return false
        }
        let id = UUID().uuidString
        guard vm.beginStrokeInput(id: id) else { return false }
        operationID = id; isFilling = true
        defer {
            if operationID == id {
                work = nil; operationID = nil; isFilling = false
                vm.finishStrokeInput(id: id)
            }
        }
        do {
            let captured = try StudioFillService.capture(document: vm.document,
                frameID: context.frameID, layerID: context.layerID, point: point,
                color: context.color, opacity: context.opacity, settings: context.settings,
                sampleAllLayers: context.sampleAllLayers, rasterData: vm.rasterData(vm.currentFrame.rasterAssetID))
            let worker = Task.detached(priority: .userInitiated) {
                try StudioFillService.element(from: captured, id: id)
            }
            work = worker
            let element = try await withTaskCancellationHandler(operation: { try await worker.value },
                onCancel: { worker.cancel() })
            guard !Task.isCancelled, !worker.isCancelled, operationID == id,
                  StudioFillContext.current(vm, ownedStroke: id) == context else {
                vm.message = "Fill was cancelled or Studio changed. Nothing was added."
                return false
            }
            let committed = vm.commitElement(element, frameID: context.frameID)
            if committed { vm.message = "Filled the selected artwork region." }
            return committed
        } catch is CancellationError {
            vm.message = "Fill cancelled. Nothing was added."
            return false
        } catch {
            vm.message = error.localizedDescription
            return false
        }
    }
}
