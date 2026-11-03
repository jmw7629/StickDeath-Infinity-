import Foundation
import SwiftUI

/// Settings and edit identity are captured once, before a physical drag. The
/// foreground paint color deliberately has no role in softening existing artwork.
struct StudioBlurContext: Equatable {
    let projectID: UUID
    let revision: Int
    let frameID: String
    let layerID: String
    let width: Int
    let height: Int
    let settings: StudioBlur.Settings
    /// Selected drawings (#149): the effect is clipped to their coverage.
    let selection: Set<String>

    @MainActor static func current(_ vm: StudioViewModel, ownedStroke: String? = nil) -> Self? {
        let settings = StudioBlur.Settings(diameter: vm.strokeWidth, hardness: vm.blurHardness, radius: vm.blurRadius, strength: vm.strokeOpacity)
        guard vm.isEditing, !vm.isPlaying, !vm.isSaving, vm.selectedTool == .blur,
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
struct StudioBlurInput {
    struct Layout: Equatable {
        let viewport: CGSize
        let scale: CGFloat
        let offset: CGSize
        var isValid: Bool {
            viewport.width.isFinite && viewport.height.isFinite && viewport.width > 0 && viewport.height > 0 &&
            scale.isFinite && scale > 0 && offset.width.isFinite && offset.height.isFinite
        }
    }
    let context: StudioBlurContext
    let layout: Layout
    private(set) var points: [StudioBlur.Point] = []
    private(set) var isCancelled = false

    mutating func cancel() { isCancelled = true }
    mutating func append(_ location: CGPoint, current: StudioBlurContext?, layout currentLayout: Layout,
                         foreground: Bool) throws {
        guard !isCancelled, foreground, current == context, currentLayout == layout, layout.isValid,
              location.x.isFinite, location.y.isFinite,
              (0...layout.viewport.width).contains(location.x),
              (0...layout.viewport.height).contains(location.y) else {
            isCancelled = true; throw CancellationError()
        }
        let point = StudioBlur.Point(x: Double(location.x / layout.viewport.width) * Double(context.width),
                                      y: Double(location.y / layout.viewport.height) * Double(context.height))
        if points.last == point { return }
        guard points.count < StudioBlur.maximumPoints else {
            isCancelled = true; throw StudioBlur.Failure.workLimit
        }
        points.append(point)
    }
    func element(id: String) throws -> DrawnElement {
        guard !isCancelled else { throw CancellationError() }
        return try StudioPixelEffectSettings.blur(context.settings).element(id: id, layerID: context.layerID,
            points: points.map { .init(x: $0.x, y: $0.y) }, width: context.width, height: context.height)
    }
}

/// The pixel operation runs off the main actor. Only its validated descriptor
/// enters document history; originals stay editable and output pixels are never
/// written back as a flattened replacement. Capture still uses the main-actor
/// compositor and must be measured separately before enabling canvas input.
@MainActor final class StudioBlurSession: ObservableObject {
    @Published private(set) var isApplying = false
    private var work: Task<StudioBlur.Pixels, Error>?
    func cancel() { work?.cancel() }

    @discardableResult
    func apply(_ vm: StudioViewModel, input: StudioBlurInput) async -> Bool {
        guard !isApplying, !Task.isCancelled, !input.isCancelled,
              StudioBlurContext.current(vm) == input.context else { return false }
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
            let worker = Task.detached(priority: .userInitiated) { () throws -> StudioBlur.Pixels in
                let original = try StudioSmudge.Pixels(width: captured.pixels.width, height: captured.pixels.height, rgba: captured.pixels.rgba)
                let effected = try StudioSmudgeReplay.applyPixelEffect(element, to: original)
                return try StudioBlur.Pixels(width: effected.width, height: effected.height, rgba: effected.rgba)
            }
            work = worker
            let pixels = try await withTaskCancellationHandler(operation: { try await worker.value },
                onCancel: { worker.cancel() })
            guard !Task.isCancelled, !worker.isCancelled,
                  StudioBlurContext.current(vm, ownedStroke: id) == input.context,
                  captured.isCurrent(vm.document, selection: vm.selectedElementIDs) else {
                vm.message = "Blur cancelled because Studio changed. Nothing was added."
                return false
            }
            guard pixels != captured.pixels else {
                vm.message = "This drag did not change the layer."
                return false
            }
            _ = try vm.commitPixelEffect(element, capture: capture, ownedStroke: id)
            vm.message = "Blurred \(element.selectionMask == nil ? "the active layer" : "the selected area"). Undo restores the original."
            return true
        } catch is CancellationError {
            vm.message = "Blur cancelled. Nothing was added."
            return false
        } catch {
            vm.message = error.localizedDescription
            return false
        }
    }
}

/// Gradient tool (#149). It shares Blur's validated active-layer capture: the
/// replayable gradient is computed off the main actor against the real layer
/// pixels, and only a gradient that changes them enters document history.
@MainActor final class StudioGradientSession: ObservableObject {
    @Published private(set) var isApplying = false
    private var work: Task<StudioSmudge.Pixels, Error>?
    func cancel() { work?.cancel() }

    @discardableResult
    func apply(_ vm: StudioViewModel, capture: StudioViewModel.GradientCapture, from start: CGPoint, to end: CGPoint) async -> Bool {
        guard !isApplying, !Task.isCancelled, vm.captureGradient() == capture else {
            vm.message = "Studio changed before the gradient was applied. Nothing was added."
            return false
        }
        let id = UUID().uuidString
        guard vm.beginStrokeInput(id: id) else { return false }
        isApplying = true
        defer { work = nil; isApplying = false; vm.finishStrokeInput(id: id) }
        do {
            let element = try vm.gradientElement(capture, from: start, to: end, id: id)
            let captured = try StudioBlurCapture.captureGradient(element: element, document: vm.document, selection: vm.selectedElementIDs,
                raster: vm.rasterData(vm.currentFrame.rasterAssetID), rasterDataByID: vm.rasterSources(for: vm.currentFrame))
            let original = try StudioSmudge.Pixels(width: captured.pixels.width, height: captured.pixels.height, rgba: captured.pixels.rgba)
            let worker = Task.detached(priority: .userInitiated) { () throws -> StudioSmudge.Pixels in
                try StudioSmudgeReplay.applyGradient(element, to: original)
            }
            work = worker
            let pixels = try await withTaskCancellationHandler(operation: { try await worker.value },
                onCancel: { worker.cancel() })
            guard !Task.isCancelled, !worker.isCancelled, vm.activeStrokeID == id,
                  vm.document.id == capture.projectID, vm.document.revision == capture.revision,
                  vm.currentFrame.id == capture.frameID, vm.activeLayerID == capture.layerID,
                  vm.selectedElementIDs == capture.selection, vm.selectedTool == .gradient,
                  captured.isCurrent(vm.document, selection: vm.selectedElementIDs) else {
                vm.message = "Gradient cancelled because Studio changed. Nothing was added."
                return false
            }
            guard pixels != original else {
                vm.message = "This gradient does not change any pixels here. Nothing was added."
                return false
            }
            _ = try vm.commitGradient(element, capture: capture, ownedStroke: id)
            vm.message = (capture.selection.isEmpty ? "Filled the active layer" : "Filled the selected area")
                + " with a \(element.gradient?.shape == .radial ? "radial" : "linear") gradient. Undo removes it; the artwork below stays editable."
            return true
        } catch is CancellationError {
            vm.message = "Gradient cancelled. Nothing was added."
            return false
        } catch {
            vm.message = error.localizedDescription
            return false
        }
    }
}
