// ═══════════════════════════════════════════════════════════════════
// Models — All data types for StickDeath Infinity
// Matches: Supabase schema + React TypeScript types exactly
// ═══════════════════════════════════════════════════════════════════

import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

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
    /// Schema17: replayable color drag. The preceding editable artwork is preserved.
    var smudge: StudioSmudgeDescriptor? = nil
    /// Schema18: ordered Gaussian blur; original artwork stays editable.
    var blur: StudioBlurDescriptor? = nil

    /// Schema19: ordered RGB unsharp mask with preserved original alpha.
    var sharpen: StudioSharpenDescriptor? = nil
    var dodgeBurn: StudioDodgeBurnDescriptor? = nil
    /// Schema24: paint RGB over preceding raw-layer coverage without changing its alpha.
    var preservesLayerAlpha: Bool? = nil

    /// Schema29: local erasure coverage; source geometry remains editable.
    var selectionErasures: [StudioElementErasure]? = nil

    func erasurePlacement() throws -> StudioElementTransform {
        if let translation { try translation.validate() }
        if let reflection { try reflection.validate() }
        let reflected = StudioElementTransform(a: reflection?.horizontal == true ? -1 : 1,
                                              d: reflection?.vertical == true ? -1 : 1)
        let translated = StudioElementTransform(tx: translation?.x ?? 0, ty: translation?.y ?? 0)
        let result = (transform ?? StudioElementTransform()).after(translated).after(reflected)
        try result.validate()
        return result
    }

    var hasPixelEffect: Bool { smudge != nil || blur != nil || sharpen != nil || dodgeBurn != nil }

    var selectionBounds: CGRect? {
        let bounds: CGRect
        if let text, let point = points.first {
            bounds = text.style.bounds(at: CGPoint(x: point.x, y: point.y))
        } else if tool == .text {
            // Historical text lives in fillColor and uses a top-leading,
            // unwrapped monospaced font. Its single origin is not its hit box.
            guard let content = fillColor, let point = points.first,
                  let measured = StudioLegacyTextGeometry.bounds(content: content,
                    at: CGPoint(x: point.x, y: point.y), fontSize: width * 3) else { return nil }
            bounds = measured
        } else if let mask = fillMask {
            guard let first = mask.spans.first, let last = mask.spans.last,
                  let left = mask.spans.map(\.start).min(), let right = mask.spans.map(\.end).max() else { return nil }
            bounds = CGRect(x: left, y: first.row, width: right - left, height: last.row - first.row + 1)
        } else if tool == .line, let shape, points.count == 2 {
            let vertices = points.map { CGPoint(x: $0.x, y: $0.y) } + shape.arrowTriangles(from: CGPoint(x: points[0].x, y: points[0].y), to: CGPoint(x: points[1].x, y: points[1].y)).flatMap { $0 }
            let left = vertices.map(\.x).min()!, right = vertices.map(\.x).max()!
            let top = vertices.map(\.y).min()!, bottom = vertices.map(\.y).max()!
            bounds = CGRect(x: left, y: top, width: right-left, height: bottom-top).insetBy(dx: -width/2, dy: -width/2)
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

/// Measures historical text without rewriting the original or changing its renderer.
/// All selection, group transform and reflection paths consume these same bounds.
enum StudioLegacyTextGeometry {
    static func bounds(content: String, at origin: CGPoint, fontSize: CGFloat) -> CGRect? {
        guard fontSize.isFinite, fontSize > 0, fontSize <= 3072,
              origin.x.isFinite, origin.y.isFinite,
              content.utf8.count <= 65_536,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        #if canImport(UIKit)
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        #elseif canImport(AppKit)
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        #endif
        let measured = (content as NSString).boundingRect(
            with: CGSize(width: 100_000, height: 100_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font], context: nil)
        guard measured.width.isFinite, measured.height.isFinite,
              measured.width > 0, measured.height > 0 else { return nil }
        return CGRect(x: origin.x, y: origin.y,
                      width: ceil(measured.width), height: ceil(measured.height))
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
    func invertedForErasure() throws -> Self {
        try validate()
        let determinant = a*d-b*c
        let result = Self(a: d/determinant, b: -b/determinant,
                          c: -c/determinant, d: a/determinant,
                          tx: (c*ty-d*tx)/determinant, ty: (b*tx-a*ty)/determinant)
        try result.validate()
        return result
    }
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

/// A world-space eraser path captured relative to one object's complete placement.
/// Keeping the inverse affine (rather than transformed points/width) preserves
/// circular coverage when the object has anisotropic scale or reflection.
struct StudioElementErasure: Codable, Equatable {
    var version = 1
    var points: [StrokePoint]
    var width: CGFloat
    var opacity: Double
    var mode: StudioEraserMode
    var pathToElement: StudioElementTransform

    func element(for target: DrawnElement) throws -> DrawnElement {
        guard version == 1, [.pencil, .pen, .brush, .marker, .crayon, .line, .rectangle, .circle, .fill, .text].contains(target.tool), target.eraser == nil,
              !target.hasPixelEffect, target.preservesLayerAlpha != true else {
            throw StudioEraserDescriptor.Failure.invalid
        }
        guard points.allSatisfy({ point in
            (point.pressure.map { $0.isFinite && (0...1).contains($0) } ?? true) &&
            (point.timestamp?.isFinite ?? true) && (point.tilt?.isValid ?? true)
        }) else { throw StudioEraserDescriptor.Failure.invalid }
        try pathToElement.validate()
        let placement = try target.erasurePlacement().after(pathToElement)
        try placement.validate()
        let result = DrawnElement(id: target.id + "-selection-erasure", tool: .eraser,
            points: points, color: "#000000", width: width, opacity: opacity,
            fillColor: nil, layerID: target.layerID,
            eraser: StudioEraserDescriptor(mode: mode), transform: placement)
        try result.eraser!.validate(element: result)
        return result
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

enum StudioArrowEnds: String, Codable, CaseIterable { case none, start, end, both }

struct StudioShapeDescriptor: Codable, Equatable {
    var version = 1
    var fillColor: String? = nil
    var cornerRadius: Double = 0
    var arrowEnds: StudioArrowEnds? = nil
    var arrowLength: Double? = nil

    func validate(tool: DrawingTool) throws {
        if tool == .line {
            guard version == 2, let arrowEnds, arrowEnds != .none,
                  let arrowLength, arrowLength.isFinite, (1...100).contains(arrowLength),
                  fillColor == nil, cornerRadius == 0 else { throw Failure.invalid }
            return
        }
        guard version == 1, arrowEnds == nil, arrowLength == nil, [.rectangle, .circle].contains(tool),
              cornerRadius.isFinite, (0...50).contains(cornerRadius),
              tool == .rectangle || cornerRadius == 0 else { throw Failure.invalid }
        if let fillColor {
            let hex = fillColor.hasPrefix("#") ? String(fillColor.dropFirst()) : fillColor
            guard hex.utf8.count == 6, hex.utf8.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }) else { throw Failure.invalid }
        }
    }
    /// Canvas-space filled heads, capped to the shaft so short arrows never
    /// reverse direction. Both-head arrows reserve half the shaft per head.
    func arrowTriangles(from start: CGPoint, to end: CGPoint) -> [[CGPoint]] {
        guard let arrowEnds, arrowEnds != .none, let arrowLength,
              start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite else { return [] }
        let distance = hypot(end.x-start.x, end.y-start.y)
        guard distance > 0, arrowLength.isFinite, arrowLength > 0 else { return [] }
        let length = min(CGFloat(arrowLength), distance / (arrowEnds == .both ? 2 : 1))
        func head(_ tip: CGPoint, _ toward: CGPoint) -> [CGPoint] {
            let ux = (toward.x-tip.x)/distance, uy = (toward.y-tip.y)/distance
            let base = CGPoint(x: tip.x + ux*length, y: tip.y + uy*length)
            return [tip, CGPoint(x: base.x - uy*length*0.5, y: base.y + ux*length*0.5),
                    CGPoint(x: base.x + uy*length*0.5, y: base.y - ux*length*0.5)]
        }
        var result: [[CGPoint]] = []
        if arrowEnds == .start || arrowEnds == .both { result.append(head(start, end)) }
        if arrowEnds == .end || arrowEnds == .both { result.append(head(end, start)) }
        return result
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
    var tiltEnabled: Bool? = nil

    func settings(width: Double, opacity: Double) throws -> StudioBrushSettings {
        guard (1...2).contains(version), tiltEnabled != true || (version == 2 && family == .calligraphy) else { throw StudioBrushError.invalidSettings("This brush document version is unavailable.") }
        let result = StudioBrushSettings(family: family, size: width, opacity: opacity,
            smoothing: smoothing, pressureEnabled: pressureEnabled, tipAngleDegrees: tipAngleDegrees,
            texture: texture, grain: grain, gradientEndColor: gradientEndColor, tiltEnabled: tiltEnabled ?? false)
        try result.validate()
        // DrawnElement's current color is opaque RGB; picker alpha is captured
        // once into its canonical opacity. Unequal endpoint alpha is unsupported.
        if family == .gradient, gradientEndColor?.alpha != 1 {
            throw StudioBrushError.invalidSettings("Gradient endpoint transparency is unavailable. Choose an opaque end color.")
        }
        return result
    }
}

/// Angles in radians in the untransformed canvas coordinate system.
struct StudioPencilTilt: Codable, Equatable {
    var altitude: Double
    var azimuth: Double
    var isValid: Bool {
        altitude.isFinite && (0...Double.pi / 2).contains(altitude) &&
        azimuth.isFinite && (0..<Double.pi * 2).contains(azimuth)
    }
    func interpolated(to other: Self, fraction: Double) -> Self {
        let delta = atan2(sin(other.azimuth - azimuth), cos(other.azimuth - azimuth))
        let angle = (azimuth + delta * fraction).truncatingRemainder(dividingBy: .pi * 2)
        return Self(altitude: altitude + (other.altitude - altitude) * fraction,
                    azimuth: angle < 0 ? angle + .pi * 2 : angle)
    }
}

struct StrokePoint: Codable, Equatable {
    var x: CGFloat
    var y: CGFloat
    var pressure: CGFloat?
    var timestamp: TimeInterval?
    var tilt: StudioPencilTilt? = nil
}

enum StudioMirrorMode: String, Codable, CaseIterable {
    case off, vertical, horizontal, both
    var title: String { rawValue.capitalized }
}

/// Captured at touch start. Copies retain original samples and brush seed;
/// canonical reflection/translation makes their pixels true mirror images.
struct StudioMirrorCapture: Equatable {
    let mode: StudioMirrorMode
    let width: Double
    let height: Double
    func elements(from source: DrawnElement) throws -> [DrawnElement] {
        guard width.isFinite, height.isFinite, (1...8192).contains(width), (1...8192).contains(height),
              [.pencil,.pen,.brush,.marker,.crayon,.line,.rectangle,.circle].contains(source.tool),
              source.translation == nil, source.reflection == nil, source.transform == nil,
              source.selectionErasures?.isEmpty != false else {
            throw StudioBrushError.invalidSettings("This mirror draft cannot be applied. The original remains unchanged.")
        }
        var result = [source]
        let axes: [(Bool,Bool)]
        switch mode {
        case .off: axes = []
        case .vertical: axes = [(true,false)]
        case .horizontal: axes = [(false,true)]
        case .both: axes = [(true,false),(false,true),(true,true)]
        }
        for (x,y) in axes {
            result.append(DrawnElement(id: source.id + "-mirror-" + (x ? "x" : "") + (y ? "y" : ""),
                tool: source.tool, points: source.points, color: source.color, width: source.width,
                opacity: source.opacity, fillColor: source.fillColor, layerID: source.layerID,
                brush: source.brush, shape: source.shape,
                translation: .init(x: x ? width : 0, y: y ? height : 0),
                reflection: .init(horizontal: x, vertical: y), preservesLayerAlpha: source.preservesLayerAlpha))
        }
        return result
    }
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
    var angleSnapDegrees: Double = 0
    var equalShapeSides = false
    var rulerAngleDegrees: Double? = nil
    var rulerLength: Double? = nil
    var mirror: StudioMirrorCapture? = nil
    var preservesLayerAlpha = false
    private(set) var points: [StrokePoint] = []
    private(set) var estimatedSampleIndices: [Int64: Int] = [:]
    private(set) var estimatedUpdatesClosed = false

    /// Updates only this live capture. No document/history entry is edited.
    @discardableResult
    mutating func updateEstimatedSample(strokeID: String, estimationIndex: Int64,
        location: CGPoint, pressure: CGFloat?, tilt: StudioPencilTilt?, expectsMoreUpdates: Bool) throws -> Bool {
        guard !estimatedUpdatesClosed, strokeID == id, brush != nil,
              let index = estimatedSampleIndices[estimationIndex], points.indices.contains(index) else { return false }
        let original = points[index]
        // Reuse capture validation and coordinate conversion before any mutation.
        var probe = self
        probe.points = []; probe.estimatedSampleIndices = [:]
        try probe.append(location: location, time: startedAt.addingTimeInterval(original.timestamp ?? 0), pressure: pressure, tilt: tilt)
        var corrected = probe.points[0]; corrected.timestamp = original.timestamp
        points[index] = corrected
        if !expectsMoreUpdates { estimatedSampleIndices.removeValue(forKey: estimationIndex) }
        return true
    }
    /// Finger-up finalizes with the latest received values, never waits forever
    /// and never permits a late OS update to rewrite committed artwork.
    @discardableResult
    mutating func finishEstimatedUpdates() -> Int {
        let unresolved = estimatedSampleIndices.count
        estimatedSampleIndices.removeAll(); estimatedUpdatesClosed = true
        return unresolved
    }

    mutating func append(location: CGPoint, time: Date, pressure: CGFloat? = nil, tilt: StudioPencilTilt? = nil, estimationIndex: Int64? = nil) throws {
        guard location.x.isFinite, location.y.isFinite, viewportSize.width > 0, viewportSize.height > 0 else {
            throw StudioBrushError.invalidSettings("Touch coordinates are unavailable.")
        }
        guard (pressure.map({ $0.isFinite && (0...1).contains($0) }) ?? true), tilt?.isValid ?? true else {
            throw StudioBrushError.invalidSettings("Touch pressure must be normalized from zero to one.")
        }
        let limit = brush == nil && eraser == nil ? 100_000 : 8_192
        guard points.count < limit else {
            throw StudioBrushError.workLimit("Touch capture reached its \(limit) sample limit. This entire stroke was rejected; no shortened stroke was saved. Discard the draft and draw a shorter stroke.")
        }
        let elapsed = time.timeIntervalSince(startedAt)
        guard elapsed.isFinite, elapsed >= 0, elapsed >= (points.last?.timestamp ?? 0) else {
            throw StudioBrushError.invalidSettings("Touch event timing changed unexpectedly. The stroke was not committed.")
        }
        guard [0.0, 15, 45, 90].contains(angleSnapDegrees),
              angleSnapDegrees == 0 || tool == .line,
              !equalShapeSides || [.rectangle, .circle].contains(tool),
              rulerAngleDegrees.map({ $0.isFinite && (-180...180).contains($0) && tool == .line && angleSnapDegrees == 0 }) ?? true,
              rulerLength.map({ $0.isFinite && (1...4096).contains($0) && rulerAngleDegrees != nil }) ?? true else {
            throw StudioBrushError.invalidSettings("These drawing constraints are invalid for this tool.")
        }
        var point = CGPoint(x: min(max(location.x / viewportSize.width, 0), 1) * documentSize.width,
                            y: min(max(location.y / viewportSize.height, 0), 1) * documentSize.height)
        if let start = points.first {
            var dx = point.x-start.x, dy = point.y-start.y
            if let rulerAngleDegrees {
                let radians = CGFloat(rulerAngleDegrees * .pi / 180)
                let unitX = cos(radians), unitY = sin(radians)
                let projection = dx*unitX + dy*unitY
                let length = rulerLength.map { CGFloat($0) } ?? abs(projection)
                let direction: CGFloat = projection < 0 ? -1 : 1
                dx = unitX*length*direction; dy = unitY*length*direction
            } else if tool == .line, angleSnapDegrees > 0 {
                let step = CGFloat(angleSnapDegrees * .pi / 180)
                let angle = (atan2(dy, dx) / step).rounded() * step
                let length = hypot(dx, dy)
                dx = cos(angle) * length; dy = sin(angle) * length
            } else if equalShapeSides {
                let side = max(abs(dx), abs(dy))
                dx = dx < 0 ? -side : side; dy = dy < 0 ? -side : side
            }
            // Clamp along the ray, never per axis: a canvas edge must not
            // break the snapped angle or equal-sided shape.
            if angleSnapDegrees > 0 || equalShapeSides || rulerAngleDegrees != nil {
                var fraction: CGFloat = 1
                if dx > 0 { fraction = min(fraction, (documentSize.width-start.x)/dx) }
                if dx < 0 { fraction = min(fraction, -start.x/dx) }
                if dy > 0 { fraction = min(fraction, (documentSize.height-start.y)/dy) }
                if dy < 0 { fraction = min(fraction, -start.y/dy) }
                point = CGPoint(x: start.x+dx*fraction, y: start.y+dy*fraction)
            }
        }
        if let estimationIndex, brush != nil, !estimatedUpdatesClosed {
            guard estimatedSampleIndices[estimationIndex] == nil, estimatedSampleIndices.count < 8_192 else {
                throw StudioBrushError.invalidSettings("Estimated sample identity is duplicated or exceeds the capture limit.")
            }
            estimatedSampleIndices[estimationIndex] = points.count
        }
        points.append(StrokePoint(x: point.x, y: point.y, pressure: pressure, timestamp: elapsed, tilt: tilt))
    }
    /// Editor-only ruler guide, never part of a DrawnElement or export.
    var rulerGuide: [CGPoint] {
        guard tool == .line, let angle = rulerAngleDegrees, angle.isFinite,
              let start = points.first else { return [] }
        let radians = CGFloat(angle * .pi / 180), dx = cos(radians), dy = sin(radians)
        func endpoint(_ sign: CGFloat) -> CGPoint {
            let x = dx*sign, y = dy*sign
            var distance = hypot(documentSize.width, documentSize.height)
            if x > 0.000001 { distance = min(distance, (documentSize.width-start.x)/x) }
            if x < -0.000001 { distance = min(distance, -start.x/x) }
            if y > 0.000001 { distance = min(distance, (documentSize.height-start.y)/y) }
            if y < -0.000001 { distance = min(distance, -start.y/y) }
            return CGPoint(x: start.x+x*distance, y: start.y+y*distance)
        }
        return [endpoint(-1), endpoint(1)]
    }
    var element: DrawnElement {
        let shape = [.line, .rectangle, .circle].contains(tool)
        let rendered = shape && points.count > 1 ? [points[0], points[points.count - 1]] : points
        return DrawnElement(id: id, tool: tool, points: rendered, color: color,
            width: width, opacity: opacity, layerID: layerID, brush: brush, shape: self.shape, eraser: eraser,
            preservesLayerAlpha: preservesLayerAlpha ? true : nil)
    }
}

enum DrawingTool: String, Codable, CaseIterable {
    case pen, pencil, marker, brush, crayon, eraser, fill, eyedropper
    case line, rectangle, circle, text, lasso, wand
    case arrow, image, ruler, gradient, blur
    case airbrush, watercolor, neon, calligraphy
    case smudge, sharpen, dodge, burn, move, hand, zoom
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
    /// Version 16: clockwise quarter turns, 1...3. Placement is the visible
    /// axis-aligned bounding box; nil keeps the original orientation.
    var rasterQuarterTurns: Int? = nil
    /// Schema 30: additional canvas-space rotation after historical quarter turns/flips.
    var rasterRotationDegrees: Double? = nil
    /// Version 21: exposure in project-FPS ticks. Nil preserves legacy one-tick frames.
    var holdTicks: Int? = nil
    /// Version 22: normalized crop in the original upright image, before flips/rotation.
    var rasterCrop: StudioImageCrop? = nil
    /// Version 27 linked instances share this frame's immutable raster source.
    var rasterAliases: [StudioRasterLayerInstance]? = nil
    /// Schema32: nondestructive source-pixel visibility, nil preserves full image.
    var rasterRegionMask: StudioImageRegionMask? = nil
    /// Schema33: same-layer persisted elements below the image; nil preserves legacy bottom placement.
    var rasterStackPosition: Int? = nil
    var durationTicks: Int { min(600, max(1, holdTicks ?? 1)) }

    var rasterLayerInstances: [StudioRasterLayerInstance] {
        guard rasterAssetID != nil, let rasterLayerID else { return [] }
        return [.init(layerID: rasterLayerID, placement: rasterPlacement, reflection: rasterReflection,
                      quarterTurns: rasterQuarterTurns, crop: rasterCrop, rotationDegrees: rasterRotationDegrees, regionMask: rasterRegionMask, stackPosition: rasterStackPosition)] + (rasterAliases ?? [])
    }
    /// Resolve source identity without changing historical nil alias metadata.
    func rasterAssetID(on layerID: String) -> String? {
        guard let instance = rasterInstance(on: layerID) else { return nil }
        return instance.assetID ?? rasterAssetID
    }
    var referencedRasterAssetIDs: Set<String> {
        var ids = Set(rasterLayerInstances.compactMap { $0.assetID ?? rasterAssetID })
        if let rasterAssetID { ids.insert(rasterAssetID) }
        return ids
    }
    mutating func appendRasterInstance(_ instance: StudioRasterLayerInstance, assetID: String) throws {
        guard rasterInstance(on: instance.layerID) == nil, rasterLayerInstances.count < 128,
              instance.placement != nil, !assetID.isEmpty,
              instance.assetID == nil || instance.assetID == assetID else { throw StudioRasterLayerInstance.Failure.invalid }
        var added = instance
        if rasterAssetID == nil {
            guard rasterAliases?.isEmpty ?? true else { throw StudioRasterLayerInstance.Failure.invalid }
            rasterAssetID = assetID; added.assetID = nil; assignPrimaryRasterInstance(added)
        } else {
            // Preserve opaque legacy frame records without reinterpreting them
            // as managed image objects in this additive format.
            guard rasterPlacement != nil else { throw StudioRasterLayerInstance.Failure.invalid }
            added.assetID = assetID == rasterAssetID ? nil : assetID
            rasterAliases = (rasterAliases ?? []) + [added]
        }
    }
    func rasterInstance(on layerID: String) -> StudioRasterLayerInstance? {
        let matches = rasterLayerInstances.filter { $0.layerID == layerID }
        return matches.count == 1 ? matches[0] : nil
    }
    func visibleRasterInstances(in layers: [CanvasLayer]) -> [StudioRasterLayerInstance] {
        let visible = Set(layers.filter { $0.visible && $0.opacity > 0 }.map(\.id))
        return rasterLayerInstances.filter { visible.contains($0.layerID) }
    }
    func preferredRasterInstance(activeLayerID: String) -> StudioRasterLayerInstance? {
        if let selected = rasterInstance(on: activeLayerID) { return selected }
        let instances = rasterLayerInstances
        return instances.count == 1 ? instances[0] : nil
    }
    func projectedRasterFrame(on layerID: String) -> AnimationFrame? {
        guard let instance = rasterInstance(on: layerID) else { return nil }
        var frame = self
        frame.rasterAssetID = rasterAssetID(on: layerID)
        frame.assignPrimaryRasterInstance(instance); frame.rasterAliases = nil
        return frame
    }
    mutating func updateRasterInstance(_ instance: StudioRasterLayerInstance) throws {
        guard let prior = rasterInstance(on: instance.layerID), prior.assetID == instance.assetID else { throw StudioRasterLayerInstance.Failure.invalid }
        if rasterLayerID == instance.layerID { assignPrimaryRasterInstance(instance) }
        else if let index = rasterAliases?.firstIndex(where: { $0.layerID == instance.layerID }) {
            rasterAliases?[index] = instance
        } else { throw StudioRasterLayerInstance.Failure.invalid }
    }
    mutating func removeRasterInstance(on layerID: String) throws {
        guard rasterInstance(on: layerID) != nil else { throw StudioRasterLayerInstance.Failure.invalid }
        if rasterLayerID == layerID {
            var aliases = rasterAliases ?? []
            if !aliases.isEmpty {
                let oldSource = rasterAssetID
                let promoted = aliases.removeFirst()
                let newSource = promoted.assetID ?? oldSource
                aliases = aliases.map { entry in
                    var entry = entry
                    let resolved = entry.assetID ?? oldSource
                    entry.assetID = resolved == newSource ? nil : resolved
                    return entry
                }
                rasterAssetID = newSource
                assignPrimaryRasterInstance(promoted)
                rasterAliases = aliases.isEmpty ? nil : aliases
            } else {
                rasterAssetID = nil; rasterLayerID = nil; rasterPlacement = nil
                rasterReflection = nil; rasterQuarterTurns = nil; rasterRotationDegrees = nil; rasterCrop = nil; rasterAliases = nil; rasterRegionMask = nil; rasterStackPosition = nil
            }
        } else {
            rasterAliases?.removeAll { $0.layerID == layerID }
            if rasterAliases?.isEmpty == true { rasterAliases = nil }
        }
    }
    /// Canonical bottom-to-top order within one layer. Images retain their
    /// immutable source identity; this token only marks their compositing slot.
    func orderedContent(on layerID: String) throws -> [LayerContentToken] {
        let drawings = elements.filter { $0.layerID == layerID }
        guard Set(drawings.map(\.id)).count == drawings.count else { throw StudioRasterLayerInstance.Failure.invalid }
        var tokens = drawings.map { LayerContentToken.drawing($0.id) }
        if let image = rasterInstance(on: layerID) {
            let position = image.stackPosition ?? 0
            guard (0...drawings.count).contains(position) else { throw StudioRasterLayerInstance.Failure.invalid }
            tokens.insert(.image, at: position)
        }
        return tokens
    }
    /// Reorder only existing members, preserving every other layer's order and
    /// all element/image metadata. Invalid or duplicate tokens are never clamped.
    mutating func setOrderedContent(_ tokens: [LayerContentToken], on layerID: String) throws {
        let positions = elements.indices.filter { elements[$0].layerID == layerID }
        let originals = positions.map { elements[$0] }
        let drawingIDs = tokens.compactMap { token -> String? in
            if case .drawing(let id) = token { return id }; return nil
        }
        let imageCount = tokens.filter { $0 == .image }.count
        var image = rasterInstance(on: layerID)
        guard drawingIDs.count == originals.count, Set(drawingIDs).count == drawingIDs.count,
              Set(drawingIDs) == Set(originals.map(\.id)), imageCount == (image == nil ? 0 : 1) else {
            throw StudioRasterLayerInstance.Failure.invalid
        }
        let byID = Dictionary(uniqueKeysWithValues: originals.map { ($0.id, $0) })
        var next = self
        for (position, id) in zip(positions, drawingIDs) { next.elements[position] = byID[id]! }
        if image != nil, let index = tokens.firstIndex(of: .image) {
            if (image!.stackPosition ?? 0) != index {
                image!.stackPosition = index == 0 ? nil : index
                try next.updateRasterInstance(image!)
            }
        }
        self = next
    }
    /// Ordinary appends stay above existing content. Deleting drawings below
    /// an unchanged image slot removes those slots, not the image's ordering.
    /// Explicit image reorders and new frame/layer/source copies retain theirs.
    mutating func reconcileRasterStackPositions(afterDeletingElementsFrom previous: AnimationFrame) throws {
        guard id == previous.id, rasterLayerInstances.contains(where: { ($0.stackPosition ?? 0) > 0 }) else { return }
        var next = self
        var remainingByLayer: [String: Set<String>] = [:]
        for element in elements { if let layer = element.layerID { remainingByLayer[layer, default: []].insert(element.id) } }
        for var image in rasterLayerInstances {
            guard let old = previous.rasterInstance(on: image.layerID),
                  rasterAssetID(on: image.layerID) == previous.rasterAssetID(on: image.layerID),
                  (image.stackPosition ?? 0) == (old.stackPosition ?? 0),
                  let position = old.stackPosition, position > 0 else { continue }
            let below = previous.elements.lazy.filter { $0.layerID == image.layerID }.prefix(position)
            let remaining = remainingByLayer[image.layerID, default: []]
            let removed = below.filter { !remaining.contains($0.id) }.count
            guard removed > 0 else { continue }
            let updated = position - removed
            guard updated >= 0 else { throw StudioRasterLayerInstance.Failure.invalid }
            image.stackPosition = updated == 0 ? nil : updated
            try next.updateRasterInstance(image)
        }
        self = next
    }
    private mutating func assignPrimaryRasterInstance(_ instance: StudioRasterLayerInstance) {
        rasterLayerID = instance.layerID; rasterPlacement = instance.placement
        rasterReflection = instance.reflection; rasterQuarterTurns = instance.quarterTurns; rasterCrop = instance.crop
        rasterRotationDegrees = instance.rotationDegrees; rasterRegionMask = instance.regionMask; rasterStackPosition = instance.stackPosition
    }
}

enum LayerContentToken: Equatable {
    case drawing(String), image
}

struct StudioRasterLayerInstance: Codable, Equatable {
    var layerID: String
    var placement: StudioRasterPlacement? = nil
    var reflection: StudioRasterReflection? = nil
    var quarterTurns: Int? = nil
    var crop: StudioImageCrop? = nil
    var rotationDegrees: Double? = nil
    /// Schema31 source override; nil inherits the frame primary source.
    var assetID: String? = nil
    var regionMask: StudioImageRegionMask? = nil
    var stackPosition: Int? = nil
    enum Failure: LocalizedError {
        case invalid
        var errorDescription: String? { "The selected linked image is unavailable or ambiguous. Nothing changed." }
    }
}

struct StudioImageCrop: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    static let full = Self(x: 0, y: 0, width: 1, height: 1)
    enum Failure: LocalizedError {
        case invalid
        var errorDescription: String? { "Choose a crop inside the original image, at least 1% wide and high." }
    }
    func validate() throws {
        guard [x, y, width, height].allSatisfy(\.isFinite), x >= 0, y >= 0,
              width >= 0.01, height >= 0.01, x + width <= 1.000000001, y + height <= 1.000000001 else {
            throw Failure.invalid
        }
    }
}

enum StudioImageQuarterTurn: String, Codable {
    case clockwise, counterclockwise
    var offset: Int { self == .clockwise ? 1 : -1 }
}

struct StudioRasterReflection: Codable, Equatable, Sendable {
    var horizontal = false
    var vertical = false
}

struct StudioRasterPlacement: Codable, Equatable, Sendable {
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
    /// Document-space radius; omitted fields retain legacy full-resolution appearance.
    var glowRadius: Double?
    var glowStrength: Double?
    var effectiveGlowRadius: Double { glowRadius ?? 5 }
    var effectiveGlowStrength: Double { glowStrength ?? 1 }
    var hasValidGlowSettings: Bool {
        effectiveGlowRadius.isFinite && (0...128).contains(effectiveGlowRadius) &&
        effectiveGlowStrength.isFinite && (0...1).contains(effectiveGlowStrength)
    }
    /// New user edits use canonical RGB; historical colors remain opaque metadata.
    static func isValidNewGlowColor(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 7 && bytes.first == 35 && bytes.dropFirst().allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }

    var colorLabel: String?

    enum CodingKeys: String, CodingKey {
        case id, name, visible, locked, opacity, lockMode, blendMode
        case glowEnabled, glowColor, glowRadius, glowStrength, colorLabel
    }

    init(id: String, name: String, visible: Bool = true, locked: Bool = false, opacity: Double = 1,
         lockMode: String = "free", blendMode: String = "normal", glowEnabled: Bool = false,
         glowColor: String? = nil, colorLabel: String? = nil, glowRadius: Double? = nil, glowStrength: Double? = nil) {
        self.id = id; self.name = name; self.visible = visible; self.locked = locked
        self.opacity = opacity; self.lockMode = locked ? "full" : lockMode
        self.blendMode = blendMode; self.glowEnabled = glowEnabled
        self.glowColor = glowColor; self.colorLabel = colorLabel
        self.glowRadius = glowRadius; self.glowStrength = glowStrength
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
        glowRadius = try c.decodeIfPresent(Double.self, forKey: .glowRadius)
        glowStrength = try c.decodeIfPresent(Double.self, forKey: .glowStrength)
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
    struct Placement: Codable, Equatable {
        let startTime: Double
        let track: Int
    }
    struct Trim: Codable, Equatable {
        let sourceOffset: Double
        let duration: Double
    }
    var trim: Trim? = nil
    var placement: Placement? = nil
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

/// Geometry shared by image editing, viewport input and validation. Placement
/// dimensions remain editable source axes; only the displayed bounds rotate.
struct StudioImageRotationGeometry {
    enum Failure: LocalizedError {
        case outsideCanvas, largerThanCanvas
        var errorDescription: String? {
            switch self {
            case .outsideCanvas:
                return "The rotated image extends outside the canvas. Reduce its size or use Fit canvas. Nothing changed."
            case .largerThanCanvas:
                return "This rotated image is larger than the canvas. Reduce its size or use Fit canvas. Nothing changed."
            }
        }
    }
    let placement: StudioRasterPlacement
    let degrees: Double
    var center: CGPoint { .init(x: placement.x + placement.width / 2, y: placement.y + placement.height / 2) }
    var corners: [CGPoint] {
        let angle = degrees * .pi / 180, c = cos(angle), s = sin(angle)
        return [(-0.5, -0.5), (0.5, -0.5), (0.5, 0.5), (-0.5, 0.5)].map { x, y in
            let dx = x * placement.width, dy = y * placement.height
            return CGPoint(x: center.x + dx*c - dy*s, y: center.y + dx*s + dy*c)
        }
    }
    var bounds: CGRect {
        let points = corners
        let x = points.map(\.x), y = points.map(\.y)
        return CGRect(x: x.min()!, y: y.min()!, width: x.max()! - x.min()!, height: y.max()! - y.min()!)
    }
    func contains(_ point: CGPoint) -> Bool {
        let angle = degrees * .pi / 180, c = cos(angle), s = sin(angle)
        let dx = point.x - center.x, dy = point.y - center.y
        return abs(dx*c + dy*s) <= placement.width / 2 && abs(-dx*s + dy*c) <= placement.height / 2
    }
    func validate(canvasWidth: Int, canvasHeight: Int) throws {
        guard degrees.isFinite, (-180...180).contains(degrees),
              [placement.x, placement.y, placement.width, placement.height].allSatisfy({ $0.isFinite }),
              placement.width > 0, placement.height > 0 else { throw StudioRasterLayerInstance.Failure.invalid }
        let b = bounds
        guard b.minX >= -0.000001, b.minY >= -0.000001,
              b.maxX <= Double(canvasWidth) + 0.000001, b.maxY <= Double(canvasHeight) + 0.000001 else {
            throw Failure.outsideCanvas
        }
    }
    func fitted(canvasWidth: Int, canvasHeight: Int, allowingShrink: Bool, fillCanvas: Bool = false) throws -> StudioRasterPlacement {
        guard degrees.isFinite, (-180...180).contains(degrees),
              [placement.x, placement.y, placement.width, placement.height].allSatisfy({ $0.isFinite }),
              placement.width > 0, placement.height > 0 else { throw StudioRasterLayerInstance.Failure.invalid }
        let b = bounds
        let canvasFit = min(Double(canvasWidth) / b.width, Double(canvasHeight) / b.height)
        let fit = fillCanvas ? canvasFit : min(1, canvasFit)
        guard allowingShrink || fit >= 1 - 0.000000001 else {
            throw Failure.largerThanCanvas
        }
        let scale = allowingShrink ? fit : 1
        let width = placement.width * scale, height = placement.height * scale
        let candidate = StudioRasterPlacement(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        let rotated = Self(placement: candidate, degrees: degrees).bounds
        let dx = max(0, -rotated.minX) - max(0, rotated.maxX - Double(canvasWidth))
        let dy = max(0, -rotated.minY) - max(0, rotated.maxY - Double(canvasHeight))
        let result = StudioRasterPlacement(x: candidate.x + dx, y: candidate.y + dy, width: width, height: height)
        try Self(placement: result, degrees: degrees).validate(canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        return result
    }
}

/// Schema32 source-pixel clip. Original image bytes are sampled unchanged;
/// selection boundaries are binary and do not apply a second alpha multiplier.
struct StudioImageRegionMask: Codable, Equatable, Sendable {
    struct Span: Codable, Equatable, Sendable {
        let row: Int, start: Int, end: Int
    }
    enum Failure: LocalizedError {
        case invalid
        var errorDescription: String? { "The image region has invalid dimensions, spans or resource bounds." }
    }
    static let maximumSpans = 262_144
    static let maximumDocumentSpans = 262_144
    let width: Int, height: Int
    let spans: [Span]
    var inverted = false
    /// Original source-space render clip, distinct from a compact placement crop.
    var sourceClip: StudioImageCrop? = nil
    var samplingGeometry: Geometry? = nil
    var placementGeometry: Geometry? = nil
    struct Geometry: Codable, Equatable, Sendable {
        let placement: StudioRasterPlacement
        let crop: StudioImageCrop?
        let reflection: StudioRasterReflection?
        let quarterTurns: Int?
        let rotationDegrees: Double?
        init?(_ instance: StudioRasterLayerInstance) {
            guard let placement = instance.placement else { return nil }
            self.placement = placement; crop = instance.crop; reflection = instance.reflection
            quarterTurns = instance.quarterTurns; rotationDegrees = instance.rotationDegrees
        }
        func applying(to instance: StudioRasterLayerInstance) -> StudioRasterLayerInstance {
            var result = instance; result.placement = placement; result.crop = crop; result.reflection = reflection
            result.quarterTurns = quarterTurns; result.rotationDegrees = rotationDegrees; return result
        }
        func validate() throws {
            let p = placement
            guard [p.x,p.y,p.width,p.height].allSatisfy({ $0.isFinite }), abs(p.x) <= 262144, abs(p.y) <= 262144,
                  p.width > 0, p.height > 0, p.width <= 262144, p.height <= 262144,
                  (0...3).contains(quarterTurns ?? 0), (rotationDegrees ?? 0).isFinite,
                  (-180...180).contains(rotationDegrees ?? 0) else { throw Failure.invalid }
            try crop?.validate()
        }
        /// Deterministic compact geometry; validation rejects spoofed origins.
        func compact(for mask: StudioImageRegionMask) throws -> Geometry {
            guard !mask.inverted, let first = mask.spans.first else { throw Failure.invalid }
            var minX = first.start, maxX = first.end, minY = first.row, maxY = first.row + 1
            for span in mask.spans { minX = min(minX,span.start); maxX = max(maxX,span.end); minY = min(minY,span.row); maxY = max(maxY,span.row+1) }
            let crop = self.crop ?? .full, p = placement
            let x0 = max(crop.x, Double(max(0,minX-2))/Double(mask.width))
            let y0 = max(crop.y, Double(max(0,minY-2))/Double(mask.height))
            let x1 = min(crop.x+crop.width, Double(min(mask.width,maxX+2))/Double(mask.width))
            let y1 = min(crop.y+crop.height, Double(min(mask.height,maxY+2))/Double(mask.height))
            let w = max(0.01,x1-x0), h = max(0.01,y1-y0)
            let cx = max(crop.x,min(x0,crop.x+crop.width-w)), cy = max(crop.y,min(y0,crop.y+crop.height-h))
            return try reframed(crop: .init(x:cx,y:cy,width:w,height:h))
        }
        func reframed(crop next: StudioImageCrop) throws -> Geometry {
            try next.validate()
            let crop = self.crop ?? .full, p = placement
            let cx = next.x, cy = next.y, w = next.width, h = next.height
            let odd = (quarterTurns ?? 0) % 2 != 0
            let preW = odd ? p.height : p.width, preH = odd ? p.width : p.height
            var x = ((cx+w/2-crop.x)/crop.width-0.5)*preW, y = ((cy+h/2-crop.y)/crop.height-0.5)*preH
            let q = Double(quarterTurns ?? 0) * .pi/2, qx = x*cos(q)-y*sin(q), qy = x*sin(q)+y*cos(q)
            x = reflection?.horizontal == true ? -qx:qx; y = reflection?.vertical == true ? -qy:qy
            let angle = (rotationDegrees ?? 0)*Double.pi/180
            let centerX = p.x+p.width/2+x*cos(angle)-y*sin(angle), centerY = p.y+p.height/2+x*sin(angle)+y*cos(angle)
            let localW = preW*w/crop.width, localH = preH*h/crop.height
            let placedW = odd ? localH:localW, placedH = odd ? localW:localH
            var instance = applying(to: .init(layerID:"region"))
            instance.placement = .init(x:centerX-placedW/2,y:centerY-placedH/2,width:placedW,height:placedH)
            instance.crop = .init(x:cx,y:cy,width:w,height:h)
            guard let result = Geometry(instance) else { throw Failure.invalid }; return result
        }
    }
    func sampledInstance(_ instance: StudioRasterLayerInstance) -> StudioRasterLayerInstance {
        guard let samplingGeometry, let placementGeometry, let current = Geometry(instance) else { return instance }
        if current == placementGeometry { return samplingGeometry.applying(to: instance) }
        // Lift a transformed compact placement back to the same source crop.
        // Rendering, hit mapping and shared decode detail use this one geometry.
        guard let lifted = try? current.reframed(crop: samplingGeometry.crop ?? .full) else { return instance }
        var result = lifted.applying(to:instance); result.crop = samplingGeometry.crop
        return result
    }
    func validate() throws {
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              width <= 4_194_304 / height, spans.count <= Self.maximumSpans else {
            throw Failure.invalid
        }
        var row = -1, end = -1
        for span in spans {
            guard span.row >= 0, span.row < height, span.start >= 0, span.end <= width, span.start < span.end,
                  span.row > row || (span.row == row && span.start > end) else {
                throw Failure.invalid
            }
            row = span.row; end = span.end
        }
        try sourceClip?.validate()
        guard (samplingGeometry == nil) == (placementGeometry == nil) else { throw Failure.invalid }
        if let samplingGeometry, let placementGeometry {
            try samplingGeometry.validate(); try placementGeometry.validate()
            if samplingGeometry != placementGeometry {
                guard let crop = placementGeometry.crop, try samplingGeometry.reframed(crop:crop) == placementGeometry else { throw Failure.invalid }
            }
        }
    }
    func contains(x: Int, y: Int) -> Bool {
        guard x >= 0, y >= 0, x < width, y < height else { return false }
        // Find first span whose (row,end) can contain this pixel.
        var low = 0, high = spans.count
        while low < high {
            let mid = (low + high) / 2, span = spans[mid]
            if span.row < y || (span.row == y && span.end <= x) { low = mid + 1 } else { high = mid }
        }
        let inside = low < spans.count && spans[low].row == y && spans[low].start <= x && x < spans[low].end
        return inverted ? !inside : inside
    }
}
