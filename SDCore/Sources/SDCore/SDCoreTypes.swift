// ═══════════════════════════════════════════════════════════════════
// SDCoreTypes — Shared data types for the core module
// ═══════════════════════════════════════════════════════════════════

import Foundation

// MARK: - Project

public struct ProjectSnapshot: Codable, Equatable {
    public let id: String
    public var name: String
    public var frames: [FrameData]
    public var layers: [LayerData]
    public var activeLayerID: String
    public var canvasWidth: Int
    public var canvasHeight: Int
    public var fps: Int
    public var updatedAt: Date

    public init(
        id: String,
        name: String = "Untitled Animation",
        frames: [FrameData] = [],
        layers: [LayerData] = [],
        activeLayerID: String = "",
        canvasWidth: Int = 1080,
        canvasHeight: Int = 1080,
        fps: Int = 12,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.frames = frames
        self.layers = layers
        self.activeLayerID = activeLayerID
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.fps = fps
        self.updatedAt = updatedAt
    }
}

// MARK: - Frame

public struct FrameData: Codable, Equatable, Identifiable {
    public let id: String
    public var elements: [ElementData]

    public init(id: String = UUID().uuidString, elements: [ElementData] = []) {
        self.id = id
        self.elements = elements
    }
}

// MARK: - Element

public struct ElementData: Codable, Equatable, Identifiable {
    public let id: String
    public var tool: String
    public var points: [PointData]
    public var color: String
    public var width: Double
    public var opacity: Double
    public var fillColor: String?
    public var layerID: String?

    public init(
        id: String = UUID().uuidString,
        tool: String = "pen",
        points: [PointData] = [],
        color: String = "#FF0000",
        width: Double = 3.0,
        opacity: Double = 1.0,
        fillColor: String? = nil,
        layerID: String? = nil
    ) {
        self.id = id
        self.tool = tool
        self.points = points
        self.color = color
        self.width = width
        self.opacity = opacity
        self.fillColor = fillColor
        self.layerID = layerID
    }
}

// MARK: - Stroke Point

public struct PointData: Codable, Equatable {
    public var x: Double
    public var y: Double
    public var pressure: Double?
    public var timestamp: Double?

    public init(x: Double = 0, y: Double = 0, pressure: Double? = nil, timestamp: Double? = nil) {
        self.x = x
        self.y = y
        self.pressure = pressure
        self.timestamp = timestamp
    }
}

// MARK: - Layer

public struct LayerData: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var visible: Bool
    public var locked: Bool
    public var opacity: Double
    public var lockMode: String
    public var blendMode: String

    public init(
        id: String = UUID().uuidString,
        name: String = "Layer",
        visible: Bool = true,
        locked: Bool = false,
        opacity: Double = 1.0,
        lockMode: String = "free",
        blendMode: String = "normal"
    ) {
        self.id = id
        self.name = name
        self.visible = visible
        self.locked = locked
        self.opacity = opacity
        self.lockMode = lockMode
        self.blendMode = blendMode
    }
}

// MARK: - Remote Version

public struct RemoteVersion: Codable {
    public let id: String
    public let projectID: String
    public let frameData: String
    public let createdAt: String

    public init(id: String, projectID: String, frameData: String, createdAt: String) {
        self.id = id
        self.projectID = projectID
        self.frameData = frameData
        self.createdAt = createdAt
    }
}
