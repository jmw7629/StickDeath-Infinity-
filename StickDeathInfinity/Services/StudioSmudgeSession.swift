import Foundation
import SwiftUI

/// Settings and edit identity are captured once, before a physical drag. The
/// foreground paint color deliberately has no role in dragging existing color.
struct StudioSmudgeContext: Equatable {
    let projectID: UUID
    let revision: Int
    let frameID: String
    let layerID: String
    let width: Int
    let height: Int
    let settings: StudioSmudge.Settings

    @MainActor static func current(_ vm: StudioViewModel, ownedStroke: String? = nil) -> Self? {
        let settings = StudioSmudge.Settings(diameter: vm.strokeWidth, strength: 0.5, opacity: vm.strokeOpacity)
        guard vm.isEditing, !vm.isPlaying, !vm.isSaving, vm.selectedTool == .smudge,
              vm.activeStrokeID == ownedStroke, vm.pendingBrushStroke == nil, vm.textDraft == nil,
              vm.selectedElementIDs.isEmpty, (try? settings.validate()) != nil,
              let layer = vm.layers.first(where: { $0.id == vm.activeLayerID }), layer.visible,
              layer.opacity > 0, !layer.isFullyLocked, layer.lockMode == "free" else { return nil }
        return Self(projectID: vm.document.id, revision: vm.document.revision,
            frameID: vm.currentFrame.id, layerID: vm.activeLayerID,
            width: vm.canvasWidth, height: vm.canvasHeight, settings: settings)
    }
}

/// A bounded, latched gesture. Changing settings, the viewport or edit context
/// cancels the entire drag; returning to the old values cannot revive it.
struct StudioSmudgeInput {
    struct Layout: Equatable {
        let viewport: CGSize
        let scale: CGFloat
        let offset: CGSize
        var isValid: Bool {
            viewport.width.isFinite && viewport.height.isFinite && viewport.width > 0 && viewport.height > 0 &&
            scale.isFinite && scale > 0 && offset.width.isFinite && offset.height.isFinite
        }
    }
    let context: StudioSmudgeContext
    let layout: Layout
    private(set) var points: [StudioSmudge.Point] = []
    private(set) var isCancelled = false

    mutating func cancel() { isCancelled = true }
    mutating func append(_ location: CGPoint, current: StudioSmudgeContext?, layout currentLayout: Layout,
                         foreground: Bool) throws {
        guard !isCancelled, foreground, current == context, currentLayout == layout, layout.isValid,
              location.x.isFinite, location.y.isFinite,
              (0...layout.viewport.width).contains(location.x),
              (0...layout.viewport.height).contains(location.y) else {
            isCancelled = true; throw CancellationError()
        }
        let point = StudioSmudge.Point(x: Double(location.x / layout.viewport.width) * Double(context.width),
                                      y: Double(location.y / layout.viewport.height) * Double(context.height))
        if points.last == point { return }
        guard points.count < StudioSmudge.maximumPoints else {
            isCancelled = true; throw StudioSmudge.Failure.workLimit
        }
        points.append(point)
    }
    func element(id: String) throws -> DrawnElement {
        guard !isCancelled else { throw CancellationError() }
        let result = DrawnElement(id: id, tool: .smudge,
            points: points.map { .init(x: $0.x, y: $0.y) }, color: "#000000",
            width: context.settings.diameter, opacity: context.settings.opacity, layerID: context.layerID,
            smudge: .init(strength: context.settings.strength))
        try result.smudge!.validate(element: result, width: context.width, height: context.height)
        return result
    }
}

/// The pixel operation runs off the main actor. Only its validated descriptor
/// enters document history; originals stay editable and output pixels are never
/// written back as a flattened replacement. Capture still uses the main-actor
/// compositor and must be measured separately before enabling canvas input.
@MainActor final class StudioSmudgeSession: ObservableObject {
    @Published private(set) var isApplying = false
    private var work: Task<StudioSmudge.Pixels, Error>?
    func cancel() { work?.cancel() }

    @discardableResult
    func apply(_ vm: StudioViewModel, input: StudioSmudgeInput) async -> Bool {
        guard !isApplying, !Task.isCancelled, !input.isCancelled,
              StudioSmudgeContext.current(vm) == input.context else { return false }
        let id = UUID().uuidString
        guard vm.beginStrokeInput(id: id) else { return false }
        isApplying = true
        defer { work = nil; isApplying = false; vm.finishStrokeInput(id: id) }
        do {
            let element = try input.element(id: id)
            // Reject cumulative document budgets before rendering any bitmap.
            var frame = vm.currentFrame; frame.elements.append(element)
            try StudioSmudgeDescriptor.validateFrame(frame, width: input.context.width, height: input.context.height)
            let captured = try StudioSmudgeCapture.capture(document: vm.document,
                selection: vm.selectedElementIDs, raster: vm.rasterData(vm.currentFrame.rasterAssetID),
                rasterDataByID: vm.rasterSources(for: vm.currentFrame))
            let worker = Task.detached(priority: .userInitiated) {
                try StudioSmudge.apply(to: captured.pixels, path: input.points, settings: input.context.settings)
            }
            work = worker
            let pixels = try await withTaskCancellationHandler(operation: { try await worker.value },
                onCancel: { worker.cancel() })
            guard !Task.isCancelled, !worker.isCancelled,
                  StudioSmudgeContext.current(vm, ownedStroke: id) == input.context,
                  captured.isCurrent(vm.document, selection: vm.selectedElementIDs) else {
                vm.message = "Smudge cancelled because Studio changed. Nothing was added."
                return false
            }
            guard pixels != captured.pixels else {
                vm.message = "This drag did not change the layer."
                return false
            }
            let committed = vm.commitElement(element, frameID: input.context.frameID)
            if committed { vm.message = "Smudged the active layer. Undo restores the original." }
            return committed
        } catch is CancellationError {
            vm.message = "Smudge cancelled. Nothing was added."
            return false
        } catch {
            vm.message = error.localizedDescription
            return false
        }
    }
}
