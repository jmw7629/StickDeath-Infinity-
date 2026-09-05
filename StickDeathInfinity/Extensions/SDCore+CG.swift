// ═══════════════════════════════════════════════════════════════════
// SDCore+CG — CGFloat bridge extensions for SwiftUI/CoreGraphics boundary
// On iOS: converts between Double (SDCore) and CGFloat (SwiftUI/CoreGraphics)
// On Linux: CGFloat is already Double, so these are identity operations
// ═══════════════════════════════════════════════════════════════════

import SwiftUI
import SDCore

// MARK: - StrokePoint CGFloat bridge

extension StrokePoint {
    /// Create from CGFloat values (iOS SwiftUI boundary)
    init(cgX: CGFloat, cgY: CGFloat, pressure: CGFloat? = nil, timestamp: TimeInterval? = nil) {
        self.init(x: Double(cgX), y: Double(cgY), pressure: pressure.map(Double.init), timestamp: timestamp)
    }

    /// X as CGFloat for rendering
    var cgX: CGFloat { CGFloat(x) }

    /// Y as CGFloat for rendering
    var cgY: CGFloat { CGFloat(y) }

    /// Pressure as CGFloat for rendering
    var cgPressure: CGFloat? { pressure.map(CGFloat.init) }
}

// MARK: - DrawnElement CGFloat bridge

extension DrawnElement {
    /// Width as CGFloat for rendering
    var cgWidth: CGFloat { CGFloat(width) }

    /// Create from CGFloat width (iOS SwiftUI boundary)
    init(
        id: String,
        tool: DrawingTool,
        points: [StrokePoint],
        color: String,
        cgWidth: CGFloat,
        opacity: Double,
        fillColor: String? = nil,
        layerID: String? = nil
    ) {
        self.init(id: id, tool: tool, points: points, color: color, width: Double(cgWidth), opacity: opacity, fillColor: fillColor, layerID: layerID)
    }
}

// MARK: - CanvasLayer CGFloat bridge

extension CanvasLayer {
    /// Opacity as CGFloat for rendering
    var cgOpacity: CGFloat { CGFloat(opacity) }
}
