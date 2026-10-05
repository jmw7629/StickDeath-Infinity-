import Foundation
import SwiftUI

/// Settings and edit identity are captured once, before a physical drag. The
/// foreground paint color deliberately has no role in adjusting exposure in existing artwork.
struct StudioDodgeBurnContext: Equatable {
    let projectID: UUID
    let revision: Int
    let frameID: String
    let layerID: String
    let width: Int
    let height: Int
    let settings: StudioDodgeBurn.Settings

    @MainActor static func current(_ vm: StudioViewModel, ownedStroke: String? = nil) -> Self? {
        let settings = StudioDodgeBurn.Settings(mode: vm.selectedTool == .burn ? .burn : .dodge, diameter: vm.strokeWidth, hardness: vm.dodgeBurnHardness, exposure: vm.dodgeBurnExposure, range: vm.dodgeBurnRange, protectTones: vm.dodgeBurnProtectTones, opacity: vm.strokeOpacity)
        guard vm.isEditing, !vm.isPlaying, !vm.isSaving, (vm.selectedTool == .dodge || vm.selectedTool == .burn),
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
struct StudioDodgeBurnInput {
    struct Layout: Equatable {
        let viewport: CGSize
        let scale: CGFloat
        let offset: CGSize
        var isValid: Bool {
            viewport.width.isFinite && viewport.height.isFinite && viewport.width > 0 && viewport.height > 0 &&
            scale.isFinite && scale > 0 && offset.width.isFinite && offset.height.isFinite
        }
    }
    let context: StudioDodgeBurnContext
    let layout: Layout
    private(set) var points: [StudioDodgeBurn.Point] = []
    private(set) var isCancelled = false

    mutating func cancel() { isCancelled = true }
    mutating func append(_ location: CGPoint, current: StudioDodgeBurnContext?, layout currentLayout: Layout,
                         foreground: Bool) throws {
        guard !isCancelled, foreground, current == context, currentLayout == layout, layout.isValid,
              location.x.isFinite, location.y.isFinite,
              (0...layout.viewport.width).contains(location.x),
              (0...layout.viewport.height).contains(location.y) else {
            isCancelled = true; throw CancellationError()
        }
        let point = StudioDodgeBurn.Point(x: Double(location.x / layout.viewport.width) * Double(context.width),
                                      y: Double(location.y / layout.viewport.height) * Double(context.height))
        if points.last == point { return }
        guard points.count < StudioBlur.maximumPoints else {
            isCancelled = true; throw StudioDodgeBurn.Failure.workLimit
        }
        points.append(point)
    }
    func element(id: String) throws -> DrawnElement {
        guard !isCancelled else { throw CancellationError() }
        let result = DrawnElement(id: id, tool: context.settings.mode == .burn ? .burn : .dodge,
            points: points.map { .init(x: $0.x, y: $0.y) }, color: "#000000",
            width: context.settings.diameter, opacity: context.settings.opacity, layerID: context.layerID,
            dodgeBurn: .init(hardness: context.settings.hardness, exposure: context.settings.exposure, range: context.settings.range, protectTones: context.settings.protectTones))
        try result.dodgeBurn!.validate(element: result, width: context.width, height: context.height)
        return result
    }
}

/// The pixel operation runs off the main actor. Only its validated descriptor
/// enters document history; originals stay editable and output pixels are never
/// written back as a flattened replacement. Capture still uses the main-actor
/// compositor and must be measured separately before enabling canvas input.
@MainActor final class StudioDodgeBurnSession: ObservableObject {
    @Published private(set) var isApplying = false
    private var work: Task<StudioDodgeBurn.Pixels, Error>?
    func cancel() { work?.cancel() }

    @discardableResult
    func apply(_ vm: StudioViewModel, input: StudioDodgeBurnInput) async -> Bool {
        guard !isApplying, !Task.isCancelled, !input.isCancelled,
              StudioDodgeBurnContext.current(vm) == input.context else { return false }
        let id = UUID().uuidString
        guard vm.beginStrokeInput(id: id) else { return false }
        isApplying = true
        defer { work = nil; isApplying = false; vm.finishStrokeInput(id: id) }
        do {
            let element = try input.element(id: id)
            // Reject cumulative document budgets before rendering any bitmap.
            var frame = vm.currentFrame; frame.elements.append(element)
            try StudioSmudgeDescriptor.validateFrame(frame, width: input.context.width, height: input.context.height)
            let captured = try StudioDodgeBurnCapture.capture(document: vm.document,
                selection: vm.selectedElementIDs, raster: vm.rasterData(vm.currentFrame.rasterAssetID))
            let worker = Task.detached(priority: .userInitiated) {
                try StudioDodgeBurn.apply(to: captured.pixels, path: input.points, settings: input.context.settings)
            }
            work = worker
            let pixels = try await withTaskCancellationHandler(operation: { try await worker.value },
                onCancel: { worker.cancel() })
            guard !Task.isCancelled, !worker.isCancelled,
                  StudioDodgeBurnContext.current(vm, ownedStroke: id) == input.context,
                  captured.isCurrent(vm.document, selection: vm.selectedElementIDs) else {
                vm.message = "Dodge/Burn cancelled because Studio changed. Nothing was added."
                return false
            }
            guard pixels != captured.pixels else {
                vm.message = "This drag did not change the layer."
                return false
            }
            let committed = vm.commitElement(element, frameID: input.context.frameID)
            if committed { vm.message = input.context.settings.mode == .dodge ? "Lightened the active layer. Undo restores the original." : "Darkened the active layer. Undo restores the original." }
            return committed
        } catch is CancellationError {
            vm.message = "Dodge/Burn cancelled. Nothing was added."
            return false
        } catch {
            vm.message = error.localizedDescription
            return false
        }
    }
}
