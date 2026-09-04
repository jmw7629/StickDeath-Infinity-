// ═══════════════════════════════════════════════════════════════════
// SpatterStudioContext — Complete snapshot of Studio state
// Sent to the AI provider so Spatter can reason about the project.
// ═══════════════════════════════════════════════════════════════════

import Foundation
import SwiftUI

// MARK: - Top-level Context

struct SpatterStudioContext: Codable, Sendable {
    let project: ProjectInfo
    let canvas: CanvasInfo
    let timeline: TimelineInfo
    let layers: [LayerInfo]
    let tool: ToolInfo
    let colors: ColorInfo
    let view: ViewInfo
    let media: MediaInfo
    let audio: AudioInfo
    let export: ExportInfo
    let navigation: NavigationInfo

    // MARK: - Nested Info Types

    struct ProjectInfo: Codable, Sendable {
        let id: String?
        let name: String
        let isUntitled: Bool
    }

    struct CanvasInfo: Codable, Sendable {
        let width: Int
        let height: Int
        let fps: Int
        let onionSkinEnabled: Bool
        let gridEnabled: Bool
    }

    struct TimelineInfo: Codable, Sendable {
        let totalFrames: Int
        let currentFrameIndex: Int
        let isPlaying: Bool
    }

    struct LayerInfo: Codable, Sendable {
        let id: String
        let name: String
        let visible: Bool
        let locked: Bool
        let opacity: Double
        let lockMode: String
        let blendMode: String
        let isSelected: Bool
        let elementCount: Int
    }

    struct ToolInfo: Codable, Sendable {
        let selectedTool: String
        let strokeWidth: Double
        let strokeOpacity: Double
        let toolOpacity: Double
        let smoothing: Double
        let pressureSensitivity: Bool
    }

    struct ColorInfo: Codable, Sendable {
        let strokeColorHex: String
        let fillColorHex: String?
    }

    struct ViewInfo: Codable, Sendable {
        let canvasScale: Double
        let activePanel: String
        let showToolbar: Bool
    }

    struct MediaInfo: Codable, Sendable {
        let importedImageCount: Int
        let importedVideoCount: Int
    }

    struct AudioInfo: Codable, Sendable {
        let clipCount: Int
        let totalDuration: Double
        let playheadTime: Double
    }

    struct ExportInfo: Codable, Sendable {
        let format: String
        let quality: String
        let isInProgress: Bool
    }

    struct NavigationInfo: Codable, Sendable {
        let currentScreen: String
        let activeSheet: String?
    }
}

// MARK: - Context Builder

extension SpatterStudioContext {
    /// Build a snapshot from the live StudioViewModel. Must be called on @MainActor.
    @MainActor
    static func from(vm: StudioViewModel) -> SpatterStudioContext {
        let fillColor = vm.fillSampleAll ? vm.strokeColorHex : nil

        let layerInfos: [LayerInfo] = vm.studioLayers.map { layer in
            let canvasLayerID = layer.id.uuidString
            let elementCount = vm.frames[safe: vm.currentFrameIndex]?.elements.filter {
                $0.layerID == canvasLayerID
            }.count ?? 0
            return LayerInfo(
                id: canvasLayerID,
                name: layer.name,
                visible: layer.visible,
                locked: layer.lockMode != .free,
                opacity: layer.opacity,
                lockMode: layer.lockMode.rawValue,
                blendMode: layer.blendMode,
                isSelected: canvasLayerID == vm.activeLayerID,
                elementCount: elementCount
            )
        }

        return SpatterStudioContext(
            project: ProjectInfo(
                id: vm.currentProjectID,
                name: vm.projectName,
                isUntitled: vm.projectName == "Untitled Animation"
            ),
            canvas: CanvasInfo(
                width: vm.canvasWidth,
                height: vm.canvasHeight,
                fps: vm.fps,
                onionSkinEnabled: vm.showOnionSkin,
                gridEnabled: vm.gridEnabled
            ),
            timeline: TimelineInfo(
                totalFrames: vm.frames.count,
                currentFrameIndex: vm.currentFrameIndex,
                isPlaying: vm.isPlaying
            ),
            layers: layerInfos,
            tool: ToolInfo(
                selectedTool: vm.selectedTool.rawValue,
                strokeWidth: vm.strokeWidth,
                strokeOpacity: vm.strokeOpacity,
                toolOpacity: vm.toolOpacity,
                smoothing: vm.smoothing,
                pressureSensitivity: vm.pressureSensitivity
            ),
            colors: ColorInfo(
                strokeColorHex: vm.strokeColorHex,
                fillColorHex: fillColor
            ),
            view: ViewInfo(
                canvasScale: Double(vm.canvasScale),
                activePanel: vm.activePanel.rawValue,
                showToolbar: vm.showToolbar
            ),
            media: MediaInfo(
                importedImageCount: 0,
                importedVideoCount: 0
            ),
            audio: AudioInfo(
                clipCount: vm.audioClips.count,
                totalDuration: vm.audioDuration,
                playheadTime: vm.audioPlayheadTime
            ),
            export: ExportInfo(
                format: vm.exportFormat.rawValue,
                quality: vm.exportQuality.rawValue,
                isInProgress: false
            ),
            navigation: NavigationInfo(
                currentScreen: "studio",
                activeSheet: nil
            )
        )
    }
}
