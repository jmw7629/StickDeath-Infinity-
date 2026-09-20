// ═══════════════════════════════════════════════════════════════════
// Models — All data types for StickDeath Infinity
// Matches: Supabase schema + React TypeScript types exactly
// ═══════════════════════════════════════════════════════════════════

import Foundation
import SwiftUI

// MARK: - User Profile
struct UserProfile: Codable, Identifiable {
    let id: String
    var username: String?
    var email: String?
    var avatarURL: String?
    var bio: String?
    var role: UserRole?
    var subscriptionTier: String?
    var onboarded: Bool?
    var skillLevel: String?
    var interests: [String]?
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, username, email, bio, role, onboarded, interests
        case avatarURL = "avatar_url"
        case subscriptionTier = "subscription_tier"
        case skillLevel = "skill_level"
        case createdAt = "created_at"
    }

    enum UserRole: String, Codable {
        case user, creator, moderator, superadmin
    }
}

// MARK: - Studio Project
struct StudioProject: Codable, Identifiable {
    let id: String
    var userID: String
    var name: String
    var width: Int?
    var height: Int?
    var fps: Int?
    var frameCount: Int?
    var thumbnailURL: String?
    var createdAt: String?
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, width, height, fps
        case userID = "user_id"
        case frameCount = "frame_count"
        case thumbnailURL = "thumbnail_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Drawing Types
struct DrawnElement: Codable, Identifiable, Equatable {
    let id: String
    var tool: DrawingTool
    var points: [StrokePoint]
    var color: String       // hex color
    var width: CGFloat
    var opacity: Double
    var fillColor: String?  // for fill tool / shape fill
    var layerID: String?
    /// Absent on historical drawings: their original rendering stays unchanged.
    /// Width and opacity remain canonical above, never duplicated in this value.
    var brush: StudioBrushDescriptor? = nil
    /// Absent on historical shapes, which retain their original rendering.
    var shape: StudioShapeDescriptor? = nil
    /// Canonical bucket-fill coverage in document pixels, independent of guides.
    var fillMask: StudioFillMask? = nil
    /// Document-space translation preserves original brush samples and fill coverage.
    /// Optional for historical projects; nonzero translations require schema 7.
    var translation: StudioElementTranslation? = nil
    /// Reflection keeps original samples and sparse fill coverage editable.
    /// Absent in historical documents; reflected content requires schema8.
    var reflection: StudioElementReflection? = nil
    /// Schema9: explicit eraser coverage; nil preserves the historical clear renderer.
    var eraser: StudioEraserDescriptor? = nil
    /// Schema10 editable text. Legacy fillColor text keeps its original renderer.
    var text: StudioTextDescriptor? = nil
    /// Schema11: world-space affine transform, applied after legacy placement.
    var transform: StudioElementTransform? = nil

    var selectionBounds: CGRect? {
        let bounds: CGRect
        if let text, let point = points.first {
            bounds = text.style.bounds(at: CGPoint(x: point.x, y: point.y))
        } else if let mask = fillMask {
            guard let first = mask.spans.first, let last = mask.spans.last,
                  let left = mask.spans.map(\.start).min(), let right = mask.spans.map(\.end).max() else { return nil }
            bounds = CGRect(x: left, y: first.row, width: right - left, height: last.row - first.row + 1)
        } else {
            guard let left = points.map(\.x).min(), let right = points.map(\.x).max(),
                  let top = points.map(\.y).min(), let bottom = points.map(\.y).max() else { return nil }
            bounds = CGRect(x: left, y: top, width: right - left, height: bottom - top).insetBy(dx: -width / 2, dy: -width / 2)
        }
        var transformed = bounds
        if reflection?.horizontal == true { transformed.origin.x = -bounds.maxX }
        if reflection?.vertical == true { transformed.origin.y = -bounds.maxY }
        let placed = transformed.offsetBy(dx: translation?.x ?? 0, dy: translation?.y ?? 0)
        return transform?.bounds(placed) ?? placed
    }
}

/// A compact transform preserves samples, sparse fills, text and brush seeds.
/// Matrix maps (x,y) to (a*x+c*y+tx, b*x+d*y+ty).
struct StudioElementTransform: Codable, Equatable, Sendable {
    enum Failure: LocalizedError {
        case limits, settings
        var errorDescription: String? {
            switch self {
            case .limits: return "The transform exceeds the supported scale or position limits. Nothing changed."
            case .settings: return "Scale must be 10–1,000% and rotation between −180° and 180°. Nothing changed."
            }
        }
    }
    var a: Double = 1, b: Double = 0, c: Double = 0, d: Double = 1
    var tx: Double = 0, ty: Double = 0
    func validate() throws {
        let determinant = a*d-b*c
        let norm = max(abs(a)+abs(c), abs(b)+abs(d))
        let inverseNorm = max(abs(d)+abs(c), abs(b)+abs(a)) / abs(determinant)
        guard [a,b,c,d,tx,ty].allSatisfy(\.isFinite), abs(tx) <= 100_000, abs(ty) <= 100_000,
              abs(determinant) > 0.000001, norm <= 64, inverseNorm <= 64 else {
            throw Failure.limits
        }
    }
    func point(_ p: CGPoint) -> CGPoint { CGPoint(x: a*p.x+c*p.y+tx, y: b*p.x+d*p.y+ty) }
    func inversePoint(_ p: CGPoint) throws -> CGPoint {
        try validate()
        let determinant = a*d-b*c, x = p.x-tx, y = p.y-ty
        return CGPoint(x: (d*x-c*y)/determinant, y: (a*y-b*x)/determinant)
    }
    func bounds(_ rect: CGRect) -> CGRect {
        guard !rect.isNull else { return .null }
        let p = [CGPoint(x:rect.minX,y:rect.minY),CGPoint(x:rect.maxX,y:rect.minY),
                 CGPoint(x:rect.maxX,y:rect.maxY),CGPoint(x:rect.minX,y:rect.maxY)].map(point)
        let xs=p.map(\.x), ys=p.map(\.y)
        return CGRect(x:xs.min()!,y:ys.min()!,width:xs.max()!-xs.min()!,height:ys.max()!-ys.min()!)
    }
    /// Apply self after inner: world-space edits retain earlier rotations.
    func after(_ inner: Self) -> Self {
        .init(a:a*inner.a+c*inner.b, b:b*inner.a+d*inner.b,
              c:a*inner.c+c*inner.d, d:b*inner.c+d*inner.d,
              tx:a*inner.tx+c*inner.ty+tx, ty:b*inner.tx+d*inner.ty+ty)
    }
    static func scaleRotation(x: Double, y: Double, degrees: Double, center: CGPoint) throws -> Self {
        guard x.isFinite,y.isFinite,degrees.isFinite,(0.1...10).contains(x),(0.1...10).contains(y),
              (-180...180).contains(degrees),center.x.isFinite,center.y.isFinite else {
            throw Failure.settings
        }
        let theta=degrees * .pi/180, cosine=cos(theta), sine=sin(theta)
        let a=cosine*x,b=sine*x,c = -sine*y,d=cosine*y
        let result=Self(a:a,b:b,c:c,d:d,tx:center.x-a*center.x-c*center.y,ty:center.y-b*center.x-d*center.y)
        try result.validate();return result
    }
}

enum StudioTextAlignment: String, Codable, CaseIterable { case left, center, right }
enum StudioTextFont: String, Codable, CaseIterable { case system, monospaced, serif }

struct StudioTextStyle: Codable, Equatable {
    var font: StudioTextFont = .monospaced
    var size: Double = 32
    var alignment: StudioTextAlignment = .left
    var bold = false
    var italic = false
    var boxWidth: Double = 240
    var boxHeight: Double = 120
    var rotation: Double = 0
    var isValid: Bool {
        size.isFinite && (8...240).contains(size) &&
        boxWidth.isFinite && (16...4096).contains(boxWidth) &&
        boxHeight.isFinite && (16...4096).contains(boxHeight) &&
        rotation.isFinite && (-180...180).contains(rotation)
    }
    func bounds(at point: CGPoint) -> CGRect {
        let rect = CGRect(x: point.x, y: point.y, width: boxWidth, height: boxHeight)
        let angle = rotation * .pi / 180, c = abs(cos(angle)), s = abs(sin(angle))
        let w = boxWidth * c + boxHeight * s, h = boxWidth * s + boxHeight * c
        return CGRect(x: rect.midX-w/2, y: rect.midY-h/2, width: w, height: h)
    }
}

struct StudioTextDescriptor: Codable, Equatable {
    var version = 1
    var content: String
    var style = StudioTextStyle()
    static let maximumBytes = 8_192
    var paragraphs: [String] { content.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines) }
    enum Failure: LocalizedError {
        case invalid
        var errorDescription: String? { "Text needs 1–2,048 characters, valid typography and one text-box origin. Nothing changed." }
    }
    func validate(element: DrawnElement) throws {
        guard version == 1, style.isValid, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              content.count <= 2_048, content.utf8.count <= Self.maximumBytes,
              paragraphs.count <= 65,
              element.tool == .text, element.points.count == 1,
              element.brush == nil, element.shape == nil, element.fillMask == nil, element.eraser == nil,
              element.opacity.isFinite, (0...1).contains(element.opacity),
              element.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 100_000 && abs($0.y) <= 100_000 }) else { throw Failure.invalid }
        let hex = element.color.hasPrefix("#") ? String(element.color.dropFirst()) : element.color
        guard hex.utf8.count == 6, hex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { throw Failure.invalid }
    }
}

enum StudioEraserMode: String, Codable, CaseIterable { case hard, soft }

struct StudioEraserDescriptor: Codable, Equatable {
    var version = 1
    var mode: StudioEraserMode = .hard
    static let maximumSamples = 8_192
    enum Failure: LocalizedError {
        case invalid
        var errorDescription: String? { "These eraser settings are invalid or exceed the 8,192 sample limit. Nothing changed." }
    }
    func validate(element: DrawnElement) throws {
        guard version == 1, element.tool == .eraser,
              element.brush == nil, element.shape == nil, element.fillMask == nil, element.text == nil,
              element.width.isFinite, (1...512).contains(element.width),
              element.opacity.isFinite, (0...1).contains(element.opacity),
              (1...Self.maximumSamples).contains(element.points.count),
              element.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 100_000 && abs($0.y) <= 100_000 }) else {
            throw Failure.invalid
        }
    }
}

enum StudioReflectionAxis: String, Codable, Sendable { case horizontal, vertical }

struct StudioElementReflection: Codable, Equatable, Sendable {
    var horizontal = false
    var vertical = false
    enum Failure: LocalizedError {
        case invalid
        var errorDescription: String? { "Empty artwork reflection is invalid. The original has not changed." }
    }
    func validate() throws {
        guard horizontal || vertical else { throw Failure.invalid }
    }
}

struct StudioElementTranslation: Codable, Equatable, Sendable {
    enum Failure: LocalizedError {
        case invalid
        var errorDescription: String? { "The artwork move exceeds the supported canvas range. Nothing changed." }
    }
    var x: Double
    var y: Double
    func validate() throws {
        guard x.isFinite, y.isFinite, abs(x) <= 100_000, abs(y) <= 100_000 else {
            throw Failure.invalid
        }
    }
}

struct StudioFillMask: Codable, Equatable, Sendable {
    static let maximumSpans = 65_536
    static let maximumDocumentSpans = 262_144
    var version = 1
    let width: Int
    let height: Int
    var spans: [Span]
    struct Span: Codable, Equatable, Sendable {
        let row: Int
        let start: Int
        let end: Int
        let alpha: UInt8
    }
    func validate() throws {
        guard version == 1, (16...4096).contains(width), (16...4096).contains(height),
              width <= 4_194_304 / height, !spans.isEmpty, spans.count <= Self.maximumSpans else { throw Failure.invalid }
        var previous: Span?
        for span in spans {
            guard (0..<height).contains(span.row), span.start >= 0, span.start < span.end,
                  span.end <= width, span.alpha > 0 else { throw Failure.invalid }
            if let previous {
                guard span.row > previous.row || (span.row == previous.row && span.start >= previous.end) else {
                    throw Failure.invalid
                }
                guard span.row != previous.row || span.start != previous.end || span.alpha != previous.alpha else {
                    throw Failure.invalid
                }
            }
            previous = span
        }
    }
    enum Failure: LocalizedError {
        case invalid
        var errorDescription: String? { "This fill region is invalid or exceeds the editable limit. Nothing has changed." }
    }
}

struct StudioShapeDescriptor: Codable, Equatable {
    var version = 1
    var fillColor: String? = nil
    var cornerRadius: Double = 0

    func validate(tool: DrawingTool) throws {
        guard version == 1, [.rectangle, .circle].contains(tool),
              cornerRadius.isFinite, (0...50).contains(cornerRadius),
              tool == .rectangle || cornerRadius == 0 else { throw Failure.invalid }
        if let fillColor {
            let hex = fillColor.hasPrefix("#") ? String(fillColor.dropFirst()) : fillColor
            guard hex.utf8.count == 6, hex.utf8.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }) else { throw Failure.invalid }
        }
    }
    enum Failure: LocalizedError {
        case invalid
        var errorDescription: String? { "These shape settings are invalid or unsupported. The drawing has not changed." }
    }
}

struct StudioBrushDescriptor: Codable, Equatable {
    var version = 1
    var family: StudioBrushFamily
    var seed: UInt64
    var smoothing: Double = 3
    var pressureEnabled = false
    var tipAngleDegrees: Double = 45
    var texture: Double = 0.5
    var grain: Double = 0.3
    var gradientEndColor: StudioBrushColor?

    func settings(width: Double, opacity: Double) throws -> StudioBrushSettings {
        guard version == 1 else { throw StudioBrushError.invalidSettings("This brush document version is unavailable.") }
        let result = StudioBrushSettings(family: family, size: width, opacity: opacity,
            smoothing: smoothing, pressureEnabled: pressureEnabled, tipAngleDegrees: tipAngleDegrees,
            texture: texture, grain: grain, gradientEndColor: gradientEndColor)
        try result.validate()
        // DrawnElement's current color is opaque RGB; picker alpha is captured
        // once into its canonical opacity. Unequal endpoint alpha is unsupported.
        if family == .gradient, gradientEndColor?.alpha != 1 {
            throw StudioBrushError.invalidSettings("Gradient endpoint transparency is unavailable. Choose an opaque end color.")
        }
        return result
    }
}

struct StrokePoint: Codable, Equatable {
    var x: CGFloat
    var y: CGFloat
    var pressure: CGFloat?
    var timestamp: TimeInterval?
}

/// Captures one touch operation's identity/settings and actual event times.
/// The same element is previewed and committed; copying it later retains seed.
struct StudioStrokeInput {
    let id: String
    let frameID: String
    let layerID: String
    let tool: DrawingTool
    let color: String
    let width: Double
    let opacity: Double
    let brush: StudioBrushDescriptor?
    let documentSize: CGSize
    let viewportSize: CGSize
    let startedAt: Date
    var shape: StudioShapeDescriptor? = nil
    var eraser: StudioEraserDescriptor? = nil
    private(set) var points: [StrokePoint] = []

    mutating func append(location: CGPoint, time: Date) throws {
        guard location.x.isFinite, location.y.isFinite, viewportSize.width > 0, viewportSize.height > 0 else {
            throw StudioBrushError.invalidSettings("Touch coordinates are unavailable.")
        }
        let limit = brush == nil && eraser == nil ? 100_000 : 8_192
        guard points.count < limit else {
            throw StudioBrushError.workLimit("Touch capture reached its \(limit) sample limit. This entire stroke was rejected; no shortened stroke was saved. Discard the draft and draw a shorter stroke.")
        }
        let elapsed = time.timeIntervalSince(startedAt)
        guard elapsed.isFinite, elapsed >= 0, elapsed >= (points.last?.timestamp ?? 0) else {
            throw StudioBrushError.invalidSettings("Touch event timing changed unexpectedly. The stroke was not committed.")
        }
        points.append(StrokePoint(x: min(max(location.x / viewportSize.width, 0), 1) * documentSize.width,
            y: min(max(location.y / viewportSize.height, 0), 1) * documentSize.height,
            pressure: nil, timestamp: elapsed))
    }
    var element: DrawnElement {
        let shape = [.line, .rectangle, .circle].contains(tool)
        let rendered = shape && points.count > 1 ? [points[0], points[points.count - 1]] : points
        return DrawnElement(id: id, tool: tool, points: rendered, color: color,
            width: width, opacity: opacity, layerID: layerID, brush: brush, shape: self.shape, eraser: eraser)
    }
}

enum DrawingTool: String, Codable, CaseIterable {
    case pen, pencil, marker, brush, crayon, eraser, fill, eyedropper
    case line, rectangle, circle, text, lasso, wand
    case arrow, image, ruler, gradient, blur
    case airbrush, watercolor, neon, calligraphy
    case smudge, sharpen, move, hand, zoom
}

struct AnimationFrame: Codable, Identifiable, Equatable {
    let id: String
    var elements: [DrawnElement]
    // An immutable original frame record (pixels and/or opaque layer metadata)
    // is retained separately from editable strokes.
    var rasterAssetID: String? = nil
    var rasterLayerID: String? = nil
    /// Version 3 managed still placement. Nil keeps historical full-canvas stretch.
    var rasterPlacement: StudioRasterPlacement? = nil
    /// Version 15: nondestructive reflections around the placed image center.
    /// Nil preserves historical image orientation and original encoded bytes.
    var rasterReflection: StudioRasterReflection? = nil
}

struct StudioRasterReflection: Codable, Equatable {
    var horizontal = false
    var vertical = false
}

struct StudioRasterPlacement: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    static func aspectFit(imageWidth: Int, imageHeight: Int, canvasWidth: Int, canvasHeight: Int) -> Self {
        let scale = min(Double(canvasWidth) / Double(imageWidth), Double(canvasHeight) / Double(imageHeight))
        // Division followed by multiplication can exceed the fitted edge by
        // one ULP (for example 147 pixels fitted to 160). Keep a valid image
        // centered inside the canvas rather than producing a negative origin.
        let width = min(Double(canvasWidth), Double(imageWidth) * scale)
        let height = min(Double(canvasHeight), Double(imageHeight) * scale)
        return .init(x: (Double(canvasWidth) - width) / 2, y: (Double(canvasHeight) - height) / 2, width: width, height: height)
    }
}

// Lock mode enum for type safety
enum LayerLockMode: String, Codable, CaseIterable {
    case free, full, position, alpha
}

struct CanvasLayer: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var visible: Bool
    var locked: Bool
    var opacity: Double
    var lockMode: String = "free"      // free, full, position, alpha
    var blendMode: String = "normal"   // normal, multiply, screen, overlay, etc.
    var glowEnabled: Bool = false
    var glowColor: String?
    var colorLabel: String?

    enum CodingKeys: String, CodingKey {
        case id, name, visible, locked, opacity, lockMode, blendMode
        case glowEnabled, glowColor, colorLabel
    }

    init(id: String, name: String, visible: Bool = true, locked: Bool = false, opacity: Double = 1,
         lockMode: String = "free", blendMode: String = "normal", glowEnabled: Bool = false,
         glowColor: String? = nil, colorLabel: String? = nil) {
        self.id = id; self.name = name; self.visible = visible; self.locked = locked
        self.opacity = opacity; self.lockMode = locked ? "full" : lockMode
        self.blendMode = blendMode; self.glowEnabled = glowEnabled
        self.glowColor = glowColor; self.colorLabel = colorLabel
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        lockMode = locked ? "full" : (try c.decodeIfPresent(String.self, forKey: .lockMode) ?? "free")
        blendMode = try c.decodeIfPresent(String.self, forKey: .blendMode) ?? "normal"
        glowEnabled = try c.decodeIfPresent(Bool.self, forKey: .glowEnabled) ?? false
        glowColor = try c.decodeIfPresent(String.self, forKey: .glowColor)
        colorLabel = try c.decodeIfPresent(String.self, forKey: .colorLabel)
    }

    var isFullyLocked: Bool { locked || lockMode == "full" }
}

// MARK: - Audio Clip
struct AudioClip: Codable, Identifiable, Equatable {
    let id: String
    var soundName: String
    var track: Int
    var startTime: Double
    var duration: Double
    var volume: Double = 0.8
    /// Immutable audio bytes in the same AnimationProject snapshot; nil for legacy clips.
    var assetID: UUID? = nil
    /// Source time is independent of placement on the animation timeline.
    var sourceOffset: Double = 0
    var isMuted: Bool = false
    /// Sample-aligned source envelope; trimming/splitting preserves its phase.
    var fadeEnvelope: AudioFadeEnvelope? = nil

    enum CodingKeys: String, CodingKey {
        case id, soundName, track, startTime, duration, volume, assetID, sourceOffset, isMuted, fadeEnvelope
    }
    init(id: String, soundName: String, track: Int, startTime: Double, duration: Double,
         volume: Double = 0.8, assetID: UUID? = nil, sourceOffset: Double = 0, isMuted: Bool = false,
         fadeEnvelope: AudioFadeEnvelope? = nil) {
        self.id = id; self.soundName = soundName; self.track = track; self.startTime = startTime
        self.duration = duration; self.volume = volume; self.assetID = assetID
        self.sourceOffset = sourceOffset; self.isMuted = isMuted
        self.fadeEnvelope = fadeEnvelope
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); soundName = try c.decode(String.self, forKey: .soundName)
        track = try c.decode(Int.self, forKey: .track); startTime = try c.decode(Double.self, forKey: .startTime)
        duration = try c.decode(Double.self, forKey: .duration)
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 0.8
        assetID = try c.decodeIfPresent(UUID.self, forKey: .assetID)
        sourceOffset = try c.decodeIfPresent(Double.self, forKey: .sourceOffset) ?? 0
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        fadeEnvelope = try c.decodeIfPresent(AudioFadeEnvelope.self, forKey: .fadeEnvelope)
    }
}

/// Linear fade-in/out on the mixer's 48 kHz source grid. Envelope phase stays
/// attached to original audio through trim, split, duplicate and timeline moves.
/// Reapplying fades establishes a new envelope for the currently selected clip.
struct AudioFadeEnvelope: Codable, Equatable, Sendable {
    let sourceStartFrame: Int
    let frameCount: Int
    let fadeInFrames: Int
    let fadeOutFrames: Int
    enum Failure: Error, LocalizedError {
        case invalid
        var errorDescription: String? { "Audio fades must fit within the selected clip and contain finite nonnegative durations." }
    }
    func validate() throws {
        let maximumFrames = 14_400_000 // Same 300-second source limit at48kHz.
        guard (0...maximumFrames).contains(sourceStartFrame), (1...maximumFrames).contains(frameCount),
              sourceStartFrame <= maximumFrames - frameCount,
              (0...frameCount).contains(fadeInFrames), (0...frameCount).contains(fadeOutFrames),
              fadeInFrames <= frameCount - fadeOutFrames,
              fadeInFrames > 0 || fadeOutFrames > 0 else { throw Failure.invalid }
    }
    /// Call only after document validation. The edge gain holds when a trim
    /// reveals source outside the original fade range; it never restarts a fade.
    func gain(atSourceFrame frame: Int) -> Double {
        if frame < sourceStartFrame { return fadeInFrames == 0 ? 1 : 0 }
        if frame >= sourceStartFrame + frameCount { return fadeOutFrames == 0 ? 1 : 0 }
        let relative = frame - sourceStartFrame
        let incoming = fadeInFrames == 0 ? 1 : min(1, Double(relative) / Double(fadeInFrames))
        let outgoing = fadeOutFrames == 0 ? 1 : min(1, Double(frameCount - 1 - relative) / Double(fadeOutFrames))
        return min(incoming, outgoing)
    }
}

/// Optional values preserve existing settings. A pair of zero fade durations
/// explicitly clears the envelope; omission preserves its original source phase.
struct StudioAudioClipSettings: Codable, Equatable {
    struct Fades: Codable, Equatable {
        let fadeIn: Double
        let fadeOut: Double
    }
    var volume: Double? = nil
    var isMuted: Bool? = nil
    var fades: Fades? = nil


}

/// One validated command is committed per finished gesture, never per drag tick.
enum StudioAudioClipEdit: Equatable {
    case place(start: Double, track: Int)
    case trim(sourceOffset: Double, duration: Double)
    case volume(Double)
    case mute(Bool)
}

enum StudioAudioTimelineGeometry {
    /// One sample grid for editable clip boundaries and rendered audio.
    static let sampleRate = 48_000.0

    static func snapped(_ time: Double, fps: Int, enabled: Bool) -> Double? {
        guard time.isFinite, (1...60).contains(fps), time >= 0, time <= 1000 else { return nil }
        return enabled ? (time * Double(fps)).rounded() / Double(fps) : time
    }
    static func time(at x: Double, pointsPerSecond: Double, fps: Int, snap: Bool) -> Double? {
        guard x.isFinite, pointsPerSecond.isFinite, pointsPerSecond > 0 else { return nil }
        return snapped(max(0, x / pointsPerSecond), fps: fps, enabled: snap)
    }
}

// MARK: - Sound Effect
struct SoundEffect: Identifiable {
    let id: String
    let name: String
    let duration: String
    let tag: String
    let waveform: [CGFloat]
    
    init(id: String = UUID().uuidString, name: String, duration: String, tag: String) {
        self.id = id
        self.name = name
        self.duration = duration
        self.tag = tag
        self.waveform = [] // Catalog labels have no licensed/decoded audio asset yet.
    }
}

// MARK: - Sticker
struct Sticker: Identifiable {
    let id: String
    let name: String
    let emoji: String
}

// MARK: - Share Target
struct ShareTarget: Identifiable {
    let id: String
    let name: String
    let icon: String
    let isPro: Bool
    var isEnabled: Bool
}

// MARK: - Export Enums
enum ExportFormat: String, CaseIterable {
    case mp4 = "MP4", gif = "GIF", png = "PNG", spritesheet = "Spritesheet"
    var icon: String {
        switch self { case .mp4: return "🎬"; case .gif: return "🎞"; case .png: return "🖼"; case .spritesheet: return "⊞" }
    }
    var subtitle: String {
        switch self { case .mp4: return "Video · social media"; case .gif: return "Animated · loops forever"; case .png: return "Individual frames"; case .spritesheet: return "All frames in one" }
    }
}

enum ExportQuality: String, CaseIterable {
    case standard = "Standard", hd = "HD", fullHD = "Full HD"
    var resolution: String {
        switch self { case .standard: return "480p"; case .hd: return "720p"; case .fullHD: return "1080p" }
    }
}

// MARK: - Lock Mode
enum LockMode: String, CaseIterable {
    case free = "Free", full = "Full", position = "Pos", alpha = "Alpha"
    var icon: String {
        switch self { case .free: return "🔓"; case .full: return "🔒"; case .position: return "📌"; case .alpha: return "🎨" }
    }
}

// MARK: - Blend Mode
enum SDBlendMode: String, CaseIterable {
    case normal = "Normal", multiply = "Multiply", screen = "Screen", overlay = "Overlay"
    case darken = "Darken", lighten = "Lighten", colorDodge = "Color Dodge", colorBurn = "Color Burn"
}

// MARK: - Social
struct Post: Codable, Identifiable {
    let id: Int
    var userID: String?
    var username: String?
    var content: String?
    var mediaURL: String?
    var likeCount: Int
    var commentCount: Int
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, username, content
        case userID = "user_id"
        case mediaURL = "media_url"
        case likeCount = "like_count"
        case commentCount = "comment_count"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        userID = try c.decodeIfPresent(String.self, forKey: .userID)
        username = try c.decodeIfPresent(String.self, forKey: .username)
        content = try c.decodeIfPresent(String.self, forKey: .content)
        mediaURL = try c.decodeIfPresent(String.self, forKey: .mediaURL)
        likeCount = (try? c.decode(Int.self, forKey: .likeCount)) ?? 0
        commentCount = (try? c.decode(Int.self, forKey: .commentCount)) ?? 0
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
    }
}

struct Comment: Codable, Identifiable {
    let id: Int
    var postID: Int
    var userID: String
    var content: String
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, content
        case postID = "post_id"
        case userID = "user_id"
        case createdAt = "created_at"
    }
}

// MARK: - Messaging
struct ChatRoom: Codable, Identifiable {
    let id: Int
    var name: String?
    var type: String?         // "dm", "group", "channel"
    var emoji: String?
    var jitsiRoomID: String?  // legacy, now LiveKit room name
    var lastMessage: String?
    var lastMessageAt: String?
    var memberCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, type, emoji
        case jitsiRoomID = "jitsi_room_id"
        case lastMessage = "last_message"
        case lastMessageAt = "last_message_at"
        case memberCount = "member_count"
    }
}

enum MessageType: String, Codable {
    case text, voice, image, video, location, contact, document, poll, animation, system
}

enum MessageReadStatus: String, Codable {
    case sent, delivered, read
}

struct ReactionData: Codable {
    var count: Int
    var reacted: Bool
}

struct ReplyRef: Codable {
    var sender: String
    var content: String
}

struct ChatMessage: Codable, Identifiable {
    let id: Int
    var roomID: Int
    var senderID: String
    var senderUsername: String?
    var content: String
    var createdAt: String?
    var mediaURL: String?
    var type: MessageType?
    var reactions: [String: ReactionData]
    var replyTo: ReplyRef?
    var readStatus: MessageReadStatus?
    var edited: Bool?
    var voiceDuration: Int?
    var threadCount: Int?

    init(
        id: Int, roomID: Int, senderID: String, senderUsername: String? = nil,
        content: String, createdAt: String? = nil, mediaURL: String? = nil,
        type: MessageType? = nil, reactions: [String: ReactionData] = [:],
        replyTo: ReplyRef? = nil, readStatus: MessageReadStatus? = nil,
        edited: Bool? = nil, voiceDuration: Int? = nil, threadCount: Int? = nil
    ) {
        self.id = id
        self.roomID = roomID
        self.senderID = senderID
        self.senderUsername = senderUsername
        self.content = content
        self.createdAt = createdAt
        self.mediaURL = mediaURL
        self.type = type
        self.reactions = reactions
        self.replyTo = replyTo
        self.readStatus = readStatus
        self.edited = edited
        self.voiceDuration = voiceDuration
        self.threadCount = threadCount
    }

    var timeString: String {
        // Parse ISO date or return time
        guard let created = createdAt else { return "" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: created) {
            let tf = DateFormatter()
            tf.dateFormat = "h:mm a"
            return tf.string(from: date)
        }
        return ""
    }

    enum CodingKeys: String, CodingKey {
        case id, content, type, reactions, edited
        case roomID = "room_id"
        case senderID = "sender_id"
        case senderUsername = "sender_username"
        case createdAt = "created_at"
        case mediaURL = "media_url"
        case replyTo = "reply_to"
        case readStatus = "read_status"
        case voiceDuration = "voice_duration"
        case threadCount = "thread_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        roomID = try container.decode(Int.self, forKey: .roomID)
        senderID = try container.decode(String.self, forKey: .senderID)
        senderUsername = try container.decodeIfPresent(String.self, forKey: .senderUsername)
        content = try container.decode(String.self, forKey: .content)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        mediaURL = try container.decodeIfPresent(String.self, forKey: .mediaURL)
        type = try container.decodeIfPresent(MessageType.self, forKey: .type)
        reactions = try container.decodeIfPresent([String: ReactionData].self, forKey: .reactions) ?? [:]
        replyTo = try container.decodeIfPresent(ReplyRef.self, forKey: .replyTo)
        readStatus = try container.decodeIfPresent(MessageReadStatus.self, forKey: .readStatus)
        edited = try container.decodeIfPresent(Bool.self, forKey: .edited)
        voiceDuration = try container.decodeIfPresent(Int.self, forKey: .voiceDuration)
        threadCount = try container.decodeIfPresent(Int.self, forKey: .threadCount)
    }
}

// MARK: - Challenges
struct Challenge: Codable, Identifiable {
    let id: Int
    var title: String
    var description: String?
    var thumbnailURL: String?
    var startDate: String?
    var endDate: String?
    var status: ChallengeStatus?
    var submissionCount: Int?
    var prizeDescription: String?

    enum CodingKeys: String, CodingKey {
        case id, title, description, status
        case thumbnailURL = "thumbnail_url"
        case startDate = "start_date"
        case endDate = "end_date"
        case submissionCount = "submission_count"
        case prizeDescription = "prize_description"
    }

    enum ChallengeStatus: String, Codable {
        case upcoming, active, ended
    }
}

// MARK: - Tip
struct Tip: Codable, Identifiable {
    let id: Int
    var senderID: String
    var receiverID: String
    var amount: Double
    var type: String?
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, amount, type
        case senderID = "sender_id"
        case receiverID = "receiver_id"
        case createdAt = "created_at"
    }
}

// MARK: - R3 Call State
struct R3CallState {
    var isActive = false
    var rateTier: AppConfig.CallRateTier = .standard
    var duration: TimeInterval = 0
    var currentCost: Double = 0
    var spendLimit: Double = 50.0
    var isIdle = false
    var personalityLine: String? = nil
}
