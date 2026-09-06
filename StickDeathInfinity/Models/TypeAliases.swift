// ═══════════════════════════════════════════════════════════════════
// TypeAliases — Bridge SDCore types to legacy app type names
// These ensure existing code referencing AnimationFrame, DrawnElement,
// etc. continues to compile without changes.
// ═══════════════════════════════════════════════════════════════════

import Foundation
import SDCore

// Core drawing/layer/project type aliases
public typealias AnimationFrame = SDFrame
public typealias DrawnElement = SDCore.DrawnElement
public typealias StrokePoint = SDCore.StrokePoint
public typealias DrawingTool = SDCore.DrawingTool
public typealias CanvasLayer = SDCore.CanvasLayer
public typealias LayerLockMode = SDCore.LayerLockMode
public typealias StudioProject = SDCore.StudioProject
public typealias AudioClip = SDCore.SDAudioClip
public typealias ExportFormat = SDCore.ExportFormat
public typealias ExportQuality = SDCore.ExportQuality
public typealias SDBlendMode = SDCore.SDBlendMode
