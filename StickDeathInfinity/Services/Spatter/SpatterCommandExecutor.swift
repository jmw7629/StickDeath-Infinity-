// ═══════════════════════════════════════════════════════════════════
// SpatterCommandExecutor — Allowlisted command application
// Applies validated SpatterCommands to the StudioViewModel.
// All mutations go through this executor. Returns structured results.
// ═══════════════════════════════════════════════════════════════════

import Foundation
import SwiftUI

@MainActor
final class SpatterCommandExecutor {

    static let shared = SpatterCommandExecutor()

    private init() {}

    // MARK: - Execute Envelope

    /// Create an undo checkpoint, then apply all commands transactionally.
    func execute(
        _ envelope: SpatterCommandEnvelope,
        on vm: StudioViewModel
    ) -> SpatterCommandResult {
        // Validate
        let context = SpatterStudioContext.from(vm: vm)
        let validationErrors = SpatterSecurityValidator.validate(envelope, context: context)
        if !validationErrors.isEmpty {
            return SpatterCommandResult(
                succeeded: false, appliedCommands: 0, failedCommands: envelope.commands.count,
                errors: validationErrors.map { .init(commandIndex: 0, reason: $0.message) },
                summary: "Validation failed: \(validationErrors.first?.message ?? "unknown")"
            )
        }

        // Push undo checkpoint for bulk operations
        if envelope.commands.count > 1 {
            vm.pushUndoCheckpoint()
        }

        var applied = 0
        var failed = 0
        var errors: [SpatterCommandResult.SpatterCommandError] = []

        for (index, command) in envelope.commands.enumerated() {
            do {
                try applyCommand(command, on: vm)
                applied += 1
            } catch {
                failed += 1
                errors.append(.init(commandIndex: index, reason: error.localizedDescription))
            }
        }

        let summary = buildSummary(applied: applied, failed: failed, errors: errors)
        return SpatterCommandResult(
            succeeded: failed == 0,
            appliedCommands: applied,
            failedCommands: failed,
            errors: errors,
            summary: summary
        )
    }

    // MARK: - Apply Single Command

    private func applyCommand(_ command: SpatterCommand, on vm: StudioViewModel) throws {
        switch command {

        // Project
        case .createProject(let p):
            vm.createProject(name: p.name, width: p.width, height: p.height, fps: p.fps)
        case .renameProject(let p):
            vm.projectName = p.name
        case .setCanvasDimensions(let p):
            vm.canvasWidth = p.width
            vm.canvasHeight = p.height
        case .setFPS(let p):
            vm.fps = p.fps

        // Frames
        case .addFrames(let p):
            for _ in 0..<p.count { vm.addFrame() }
        case .duplicateFrame(let p):
            if let idx = p.atIndex {
                let saved = vm.currentFrameIndex
                vm.currentFrameIndex = idx
                vm.duplicateFrame()
                vm.currentFrameIndex = saved
            } else {
                vm.duplicateFrame()
            }
        case .deleteFrame(let p):
            let saved = vm.currentFrameIndex
            vm.currentFrameIndex = p.atIndex
            vm.deleteFrame()
            vm.currentFrameIndex = min(saved, vm.frames.count - 1)
        case .reorderFrames(let p):
            guard p.fromIndex != p.toIndex,
                  p.fromIndex >= 0, p.fromIndex < vm.frames.count,
                  p.toIndex >= 0, p.toIndex < vm.frames.count else { return }
            let frame = vm.frames.remove(at: p.fromIndex)
            vm.frames.insert(frame, at: p.toIndex)
        case .goToFrame(let p):
            vm.currentFrameIndex = min(max(0, p.index), vm.frames.count - 1)
        case .insertHold(let p):
            guard p.frameIndex >= 0, p.frameIndex < vm.frames.count else { return }
            let original = vm.frames[p.frameIndex]
            for _ in 0..<p.holdCount {
                let copy = AnimationFrame(
                    id: UUID().uuidString,
                    elements: original.elements.map { el in
                        DrawnElement(
                            id: UUID().uuidString, tool: el.tool, points: el.points,
                            color: el.color, width: el.width, opacity: el.opacity,
                            fillColor: el.fillColor, layerID: el.layerID
                        )
                    }
                )
                vm.frames.insert(copy, at: p.frameIndex + 1)
            }

        // Tools
        case .selectTool(let p):
            guard let tool = DrawingTool(rawValue: p.tool) else {
                throw SpatterProviderError.invalidToolCall("Unknown tool: \(p.tool)")
            }
            vm.selectedTool = tool
        case .setStrokeWidth(let p):
            vm.strokeWidth = p.width
        case .setStrokeOpacity(let p):
            vm.strokeOpacity = p.opacity
        case .setToolOpacity(let p):
            vm.toolOpacity = p.opacity

        // Colors
        case .setStrokeColor(let p):
            vm.strokeColor = Color(hex: p.hex)
        case .setFillColor(let p):
            vm.strokeColor = Color(hex: p.hex)

        // Layers
        case .addLayer(let p):
            vm.addLayer()
            if let name = p.name, let first = vm.studioLayers.first {
                if let idx = vm.studioLayers.firstIndex(where: { $0.id == first.id }) {
                    vm.studioLayers[idx].name = name
                }
            }
        case .renameLayer(let p):
            if let uuid = UUID(uuidString: p.layerID),
               let idx = vm.studioLayers.firstIndex(where: { $0.id == uuid }) {
                vm.studioLayers[idx].name = p.name
            }
        case .duplicateLayer(let p):
            if let uuid = UUID(uuidString: p.layerID) {
                vm.duplicateLayer(uuid)
            }
        case .deleteLayer(let p):
            if let uuid = UUID(uuidString: p.layerID) {
                if let idx = vm.studioLayers.firstIndex(where: { $0.id == uuid }) {
                    vm.studioLayers.remove(at: idx)
                    if let canvasIdx = vm.layers.firstIndex(where: { $0.id == p.layerID }) {
                        vm.layers.remove(at: canvasIdx)
                    }
                }
            }
        case .reorderLayers(let p):
            if let uuid = UUID(uuidString: p.layerID),
               let idx = vm.studioLayers.firstIndex(where: { $0.id == uuid }) {
                let layer = vm.studioLayers.remove(at: idx)
                let target = min(p.toIndex, vm.studioLayers.count)
                vm.studioLayers.insert(layer, at: target)
            }
        case .selectLayer(let p):
            vm.activeLayerID = p.layerID
            if let idx = vm.layers.firstIndex(where: { $0.id == p.layerID }) {
                vm.currentLayerIndex = idx
            }
        case .setLayerVisibility(let p):
            vm.toggleLayerVisibility(p.layerID)
        case .setLayerLock(let p):
            guard let mode = LayerLockMode(rawValue: p.lockMode) else { return }
            if let uuid = UUID(uuidString: p.layerID) {
                vm.setLayerLockMode(uuid, mode: mode)
            }
        case .setLayerOpacity(let p):
            if let uuid = UUID(uuidString: p.layerID),
               let idx = vm.studioLayers.firstIndex(where: { $0.id == uuid }) {
                vm.studioLayers[idx].opacity = p.opacity
            }
        case .setLayerBlendMode(let p):
            if let uuid = UUID(uuidString: p.layerID),
               let idx = vm.studioLayers.firstIndex(where: { $0.id == uuid }) {
                vm.studioLayers[idx].blendMode = p.blendMode
            }

        // Drawing Primitives
        case .addStroke(let p):
            let element = DrawnElement(
                id: UUID().uuidString,
                tool: .brush,
                points: p.points.map { StrokePoint(x: $0.x, y: $0.y, pressure: $0.pressure) },
                color: p.color,
                width: p.width,
                opacity: p.opacity,
                fillColor: nil,
                layerID: p.layerID
            )
            vm.commitElement(element)

        case .addLine(let p):
            let points = [
                StrokePoint(x: p.startX, y: p.startY),
                StrokePoint(x: p.endX, y: p.endY)
            ]
            let element = DrawnElement(
                id: UUID().uuidString, tool: .line, points: points,
                color: p.color, width: p.width, opacity: p.opacity,
                fillColor: nil, layerID: p.layerID
            )
            vm.commitElement(element)

        case .addRectangle(let p):
            let points = [
                StrokePoint(x: p.x, y: p.y),
                StrokePoint(x: p.x + p.width, y: p.y),
                StrokePoint(x: p.x + p.width, y: p.y + p.height),
                StrokePoint(x: p.x, y: p.y + p.height)
            ]
            let element = DrawnElement(
                id: UUID().uuidString, tool: .rectangle, points: points,
                color: p.strokeColor ?? "#000000", width: p.strokeWidth, opacity: 1.0,
                fillColor: p.fillColor, layerID: p.layerID
            )
            vm.commitElement(element)

        case .addCircle(let p):
            let points = [
                StrokePoint(x: p.centerX - p.radius, y: p.centerY),
                StrokePoint(x: p.centerX + p.radius, y: p.centerY),
                StrokePoint(x: p.centerX, y: p.centerY - p.radius),
                StrokePoint(x: p.centerX, y: p.centerY + p.radius)
            ]
            let element = DrawnElement(
                id: UUID().uuidString, tool: .circle, points: points,
                color: p.strokeColor ?? "#000000", width: p.strokeWidth, opacity: 1.0,
                fillColor: p.fillColor, layerID: p.layerID
            )
            vm.commitElement(element)

        case .addText(let p):
            let points = [StrokePoint(x: p.x, y: p.y)]
            let element = DrawnElement(
                id: UUID().uuidString, tool: .text, points: points,
                color: p.color, width: p.fontSize, opacity: 1.0,
                fillColor: nil, layerID: p.layerID
            )
            vm.commitElement(element)

        // Animation Sequences
        case .generateStoryboard(let params):
            let plan = SpatterStoryboardBuilder.buildPlan(from: params)
            var insertIndex = vm.currentFrameIndex + 1
            for scene in plan.frames {
                for frameElements in scene {
                    let frame = AnimationFrame(id: UUID().uuidString, elements: frameElements)
                    vm.frames.insert(frame, at: insertIndex)
                    insertIndex += 1
                }
            }

        case .generateKeyPoseSequence(let params):
            let plan = SpatterKeyPoseBuilder.buildPlan(from: params)
            var insertIndex = vm.currentFrameIndex + 1
            for frameElements in plan.frames {
                let frame = AnimationFrame(id: UUID().uuidString, elements: frameElements)
                vm.frames.insert(frame, at: insertIndex)
                insertIndex += 1
            }

        // Export
        case .invokeExport(let p):
            if let fmt = p.format, let f = ExportFormat.allCases.first(where: { $0.rawValue.lowercased() == fmt.lowercased() }) {
                vm.exportFormat = f
            }
            if let q = p.quality, let quality = ExportQuality.allCases.first(where: { $0.rawValue.lowercased() == q.lowercased() }) {
                vm.exportQuality = quality
            }
            // Export is triggered through the existing ExportPanel
            break

        // Navigation
        case .explainControl(let p):
            // The executor returns the explanation in the result; no VM mutation needed.
            break
        }
    }

    // MARK: - Summary Builder

    private func buildSummary(applied: Int, failed: Int, errors: [SpatterCommandResult.SpatterCommandError]) -> String {
        var parts: [String] = []
        if applied > 0 { parts.append("\(applied) command\(applied == 1 ? "" : "s") applied") }
        if failed > 0 {
            parts.append("\(failed) command\(failed == 1 ? "" : "s") failed")
            if let first = errors.first { parts.append("(\(first.reason))") }
        }
        return parts.joined(separator: " • ")
    }
}
