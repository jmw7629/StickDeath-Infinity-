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
    /// Selected drawings (#149): the effect is clipped to their coverage.
    let selection: Set<String>

    @MainActor static func current(_ vm: StudioViewModel, ownedStroke: String? = nil) -> Self? {
        let settings = StudioDodgeBurn.Settings(mode: vm.selectedTool == .burn ? .burn : .dodge, diameter: vm.strokeWidth, hardness: vm.dodgeBurnHardness, exposure: vm.dodgeBurnExposure, range: vm.dodgeBurnRange, protectTones: vm.dodgeBurnProtectTones, opacity: vm.strokeOpacity)
        guard vm.isEditing, !vm.isPlaying, !vm.isSaving, (vm.selectedTool == .dodge || vm.selectedTool == .burn),
              vm.activeStrokeID == ownedStroke, vm.pendingBrushStroke == nil, vm.textDraft == nil,
              (try? settings.validate()) != nil,
              let layer = vm.layers.first(where: { $0.id == vm.activeLayerID }), layer.visible,
              layer.opacity > 0, !layer.isFullyLocked, layer.lockMode == "free" else { return nil }
        return Self(projectID: vm.document.id, revision: vm.document.revision,
            frameID: vm.currentFrame.id, layerID: vm.activeLayerID,
            width: vm.canvasWidth, height: vm.canvasHeight, settings: settings,
            selection: vm.selectedElementIDs)
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
        return try StudioPixelEffectSettings.dodgeBurn(context.settings).element(id: id, layerID: context.layerID,
            points: points.map { .init(x: $0.x, y: $0.y) }, width: context.width, height: context.height)
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
            guard let capture = vm.capturePixelEffect(ownedStroke: id) else { throw StudioCommandError.staleRevision }
            let element = try vm.preparePixelEffect(input.element(id: id), capture: capture, ownedStroke: id)
            let captured = try StudioBlurCapture.capturePixelEffect(element: element, document: vm.document,
                selection: vm.selectedElementIDs, raster: vm.rasterData(vm.currentFrame.rasterAssetID),
                rasterDataByID: vm.rasterSources(for: vm.currentFrame))
            let worker = Task.detached(priority: .userInitiated) { () throws -> StudioDodgeBurn.Pixels in
                let original = try StudioSmudge.Pixels(width: captured.pixels.width, height: captured.pixels.height, rgba: captured.pixels.rgba)
                let effected = try StudioSmudgeReplay.applyPixelEffect(element, to: original)
                return try StudioDodgeBurn.Pixels(width: effected.width, height: effected.height, rgba: effected.rgba)
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
            _ = try vm.commitPixelEffect(element, capture: capture, ownedStroke: id)
            vm.message = input.context.settings.mode == .dodge ? "Lightened \(element.selectionMask == nil ? "the active layer" : "the selected area"). Undo restores the original." : "Darkened \(element.selectionMask == nil ? "the active layer" : "the selected area"). Undo restores the original."
            return true
        } catch is CancellationError {
            vm.message = "Dodge/Burn cancelled. Nothing was added."
            return false
        } catch {
            vm.message = error.localizedDescription
            return false
        }
    }
}
