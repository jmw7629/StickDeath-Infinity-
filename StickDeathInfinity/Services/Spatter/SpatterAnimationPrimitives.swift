// ═══════════════════════════════════════════════════════════════════
// SpatterAnimationPrimitives — Reusable animation building blocks
// Deterministic helpers for generating frame sequences from
// explicit key poses and motion primitives.
// ═══════════════════════════════════════════════════════════════════

import Foundation
import CoreGraphics

// MARK: - Easing Functions

enum SpatterEasing {
    case linear
    case easeIn
    case easeOut
    case easeInOut
    case bounce
    case elastic
    case snap

    func interpolate(_ t: Double) -> Double {
        let t = max(0, min(1, t))
        switch self {
        case .linear: return t
        case .easeIn: return t * t
        case .easeOut: return 1 - (1 - t) * (1 - t)
        case .easeInOut: return t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        case .bounce: return bounceEase(t)
        case .elastic: return t == 0 ? 0 : t == 1 ? 1 : pow(2, -10 * t) * sin((t * 10 - 0.75) * (.pi * 2 / 3)) + 1
        case .snap: return t < 0.2 ? 0 : 1
        }
    }

    private func bounceEase(_ t: Double) -> Double {
        let n1 = 7.5625
        let d1 = 2.75
        if t < 1 / d1 { return n1 * t * t }
        else if t < 2 / d1 { let t2 = t - 1.5 / d1; return n1 * t2 * t2 + 0.75 }
        else if t < 2.5 / d1 { let t2 = t - 2.25 / d1; return n1 * t2 * t2 + 0.9375 }
        else { let t2 = t - 2.625 / d1; return n1 * t2 * t2 + 0.984375 }
    }
}

// MARK: - Motion Primitive

struct SpatterMotionPrimitive {
    let type: MotionType
    let startFrame: Int
    let durationFrames: Int
    let easing: SpatterEasing

    enum MotionType {
        case hold
        case move(dx: Double, dy: Double)
        case rotate(degrees: Double)
        case scale(factorX: Double, factorY: Double)
        case fade(opacityStart: Double, opacityEnd: Double)
        case impactShake(intensity: Double)
        case anticipation(delay: Double)
        case recovery(frames: Int)
    }
}

// MARK: - Pose Transition

/// Interpolate between two sets of drawn elements (key poses).
struct SpatterPoseTransition {
    let fromElements: [DrawnElement]
    let toElements: [DrawnElement]
    let frameCount: Int
    let easing: SpatterEasing

    /// Generate intermediate frames by interpolating point positions.
    func interpolate() -> [[DrawnElement]] {
        guard frameCount > 1 else { return [toElements] }
        var frames: [[DrawnElement]] = []

        for frame in 0..<frameCount {
            let t = easing.interpolate(Double(frame) / Double(frameCount - 1))
            let interpolated = interpolateElements(from: fromElements, to: toElements, t: t)
            frames.append(interpolated)
        }
        return frames
    }

    private func interpolateElements(from: [DrawnElement], to: [DrawnElement], t: Double) -> [DrawnElement] {
        let count = max(from.count, to.count)
        return (0..<count).map { i in
            let fromEl = i < from.count ? from[i] : to[i]
            let toEl = i < to.count ? to[i] : fromEl
            return lerpElement(from: fromEl, to: toEl, t: t)
        }
    }

    private func lerpElement(from: DrawnElement, to: DrawnElement, t: Double) -> DrawnElement {
        let maxPoints = max(from.points.count, to.points.count)
        var points: [StrokePoint] = []
        for i in 0..<maxPoints {
            let p1 = i < from.points.count ? from.points[i] : (from.points.last ?? StrokePoint(x: 0, y: 0))
            let p2 = i < to.points.count ? to.points[i] : (to.points.last ?? StrokePoint(x: 0, y: 0))
            points.append(StrokePoint(
                x: p1.x + (p2.x - p1.x) * CGFloat(t),
                y: p1.y + (p2.y - p1.y) * CGFloat(t),
                pressure: p1.pressure,
                timestamp: p1.timestamp
            ))
        }
        return DrawnElement(
            id: UUID().uuidString,
            tool: to.tool,
            points: points,
            color: to.color,
            width: from.width + (to.width - from.width) * CGFloat(t),
            opacity: from.opacity + (to.opacity - from.opacity) * t,
            fillColor: to.fillColor,
            layerID: to.layerID
        )
    }
}

// MARK: - Frame Sequence Generator

/// Generates a sequence of frames from motion primitives applied to a base set of elements.
enum SpatterFrameGenerator {

    /// Apply a single motion primitive to elements for the given frame index within the motion.
    static func applyMotion(
        _ primitive: SpatterMotionPrimitive,
        to elements: [DrawnElement],
        at frameOffset: Int
    ) -> [DrawnElement] {
        let t = primitive.durationFrames > 1
            ? Double(frameOffset) / Double(primitive.durationFrames - 1)
            : 0
        let eased = primitive.easing.interpolate(t)

        switch primitive.type {
        case .hold:
            return elements
        case .move(let dx, let dy):
            return elements.map { el in
                DrawnElement(
                    id: el.id, tool: el.tool,
                    points: el.points.map { p in
                        StrokePoint(x: p.x + CGFloat(dx * eased), y: p.y + CGFloat(dy * eased), pressure: p.pressure, timestamp: p.timestamp)
                    },
                    color: el.color, width: el.width, opacity: el.opacity, fillColor: el.fillColor, layerID: el.layerID
                )
            }
        case .rotate(let degrees):
            let radians = degrees * .pi / 180 * eased
            let cosA = cos(radians)
            let sinA = sin(radians)
            return elements.map { el in
                DrawnElement(
                    id: el.id, tool: el.tool,
                    points: el.points.map { p in
                        StrokePoint(x: p.x * cosA - p.y * sinA, y: p.x * sinA + p.y * cosA, pressure: p.pressure, timestamp: p.timestamp)
                    },
                    color: el.color, width: el.width, opacity: el.opacity, fillColor: el.fillColor, layerID: el.layerID
                )
            }
        case .scale(let factorX, let factorY):
            return elements.map { el in
                DrawnElement(
                    id: el.id, tool: el.tool,
                    points: el.points.map { p in
                        let scale = 1.0 + (factorX - 1.0) * eased
                        let scaleY = 1.0 + (factorY - 1.0) * eased
                        return StrokePoint(x: p.x * scale, y: p.y * scaleY, pressure: p.pressure, timestamp: p.timestamp)
                    },
                    color: el.color, width: el.width, opacity: el.opacity, fillColor: el.fillColor, layerID: el.layerID
                )
            }
        case .fade(let opacityStart, let opacityEnd):
            let opacity = opacityStart + (opacityEnd - opacityStart) * eased
            return elements.map { el in
                DrawnElement(
                    id: el.id, tool: el.tool, points: el.points,
                    color: el.color, width: el.width, opacity: opacity, fillColor: el.fillColor, layerID: el.layerID
                )
            }
        case .impactShake(let intensity):
            let shakeX = CGFloat.random(in: -intensity...intensity) * CGFloat(1 - eased)
            let shakeY = CGFloat.random(in: -intensity...intensity) * CGFloat(1 - eased)
            return elements.map { el in
                DrawnElement(
                    id: el.id, tool: el.tool,
                    points: el.points.map { p in
                        StrokePoint(x: p.x + shakeX, y: p.y + shakeY, pressure: p.pressure, timestamp: p.timestamp)
                    },
                    color: el.color, width: el.width, opacity: el.opacity, fillColor: el.fillColor, layerID: el.layerID
                )
            }
        case .anticipation:
            return elements
        case .recovery:
            return elements
        }
    }
}

// MARK: - Storyboard Builder

/// Converts a storyboard description into a sequence of frame arrays
/// using the Studio's drawing primitives.
enum SpatterStoryboardBuilder {

    struct StoryboardPlan {
        let scenes: [ScenePlan]
    }

    struct ScenePlan {
        let title: String
        let frames: [[DrawnElement]]
    }

    /// Build a storyboard from SpatterCommand.StoryboardParams
    static func buildPlan(from params: SpatterCommand.StoryboardParams) -> StoryboardPlan {
        let scenePlans = params.scenes.map { scene in
            ScenePlan(
                title: scene.title,
                frames: generateSceneFrames(scene: scene)
            )
        }
        return StoryboardPlan(scenes: scenePlans)
    }

    private static func generateSceneFrames(scene: SpatterCommand.StoryboardScene) -> [[DrawnElement]] {
        var frames: [[DrawnElement]] = []
        for _ in 0..<scene.frameCount {
            frames.append([])
        }
        return frames
    }
}

// MARK: - Key Pose Sequence Builder

/// Translates explicit key poses into full frame arrays with interpolation.
enum SpatterKeyPoseBuilder {

    struct SequencePlan {
        let frames: [[DrawnElement]]
    }

    static func buildPlan(from params: SpatterCommand.KeyPoseSequenceParams) -> SequencePlan {
        guard params.poses.count >= 2 else {
            let singleFrame = params.poses.first?.elements ?? []
            return SequencePlan(frames: [singleFrame])
        }

        var allFrames: [[DrawnElement]] = []

        for poseIndex in 0..<(params.poses.count - 1) {
            let from = params.poses[poseIndex].elements
            let to = params.poses[poseIndex + 1].elements

            let transition = SpatterPoseTransition(
                fromElements: from,
                toElements: to,
                frameCount: params.holdFrames + params.interpolationFrames,
                easing: .easeInOut
            )
            allFrames += transition.interpolate()
        }

        // Add final hold of last pose
        if let lastElements = params.poses.last?.elements {
            for _ in 0..<params.holdFrames {
                allFrames.append(lastElements)
            }
        }

        return SequencePlan(frames: allFrames)
    }
}
