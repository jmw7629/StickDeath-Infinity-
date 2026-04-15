// BoneRig.swift
// Bone hierarchy, IK solver, constraints, rig templates
// Stick Nodes-style rigging for STICKDEATH ∞

import SwiftUI
import Foundation

// MARK: - Bone Definition
struct Bone: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var parentId: UUID?             // nil = root bone
    var jointA: String              // Start joint name (parent end)
    var jointB: String              // End joint name (child end)
    var length: CGFloat             // Rest length
    var thickness: CGFloat          // Visual thickness (1–12 pt)
    var color: String               // Hex
    var locked: Bool                // Prevent dragging
    var angleConstraint: AngleConstraint?
    var style: BoneStyle

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: Bone, rhs: Bone) -> Bool { lhs.id == rhs.id }
}

struct AngleConstraint: Codable, Hashable {
    var minAngle: CGFloat           // Degrees, relative to parent bone
    var maxAngle: CGFloat
    var stiffness: CGFloat          // 0.0 (loose) – 1.0 (rigid)
}

enum BoneStyle: String, Codable, CaseIterable, Hashable {
    case stick      // Simple line (classic stick figure)
    case tapered    // Thick at joint, thin at tip
    case block      // Rectangular/block bone
    case rounded    // Rounded capsule
    case hidden     // Invisible (for IK chains)

    var label: String {
        switch self {
        case .stick: return "Stick"
        case .tapered: return "Taper"
        case .block: return "Block"
        case .rounded: return "Round"
        case .hidden: return "Hidden"
        }
    }

    var icon: String {
        switch self {
        case .stick: return "line.diagonal"
        case .tapered: return "triangle.fill"
        case .block: return "rectangle.fill"
        case .rounded: return "capsule.fill"
        case .hidden: return "eye.slash"
        }
    }
}

// MARK: - Rig (collection of bones + joints)
struct BoneRig: Codable {
    var bones: [Bone]
    var customJoints: [String: CGPoint]     // User-added joints beyond default 13
    var ikChains: [IKChain]

    static let empty = BoneRig(bones: [], customJoints: [:], ikChains: [])

    /// Build default humanoid rig from StickFigure.bones
    static func defaultHumanoid() -> BoneRig {
        let defaultBones: [Bone] = StickFigure.bones.enumerated().map { idx, pair in
            Bone(
                id: UUID(),
                name: "\(pair.0)→\(pair.1)",
                parentId: nil, // Will be resolved
                jointA: pair.0,
                jointB: pair.1,
                length: defaultBoneLength(from: pair.0, to: pair.1),
                thickness: pair.0 == "neck" && pair.1 == "hip" ? 3 : 2.5,
                color: "#FFFFFF",
                locked: false,
                angleConstraint: defaultConstraint(for: pair.1),
                style: .stick
            )
        }

        // Resolve parent IDs (bone whose jointB == this bone's jointA)
        var resolved = defaultBones
        for i in resolved.indices {
            let parentJoint = resolved[i].jointA
            resolved[i].parentId = resolved.first(where: { $0.jointB == parentJoint })?.id
        }

        let defaultChains: [IKChain] = [
            IKChain(id: UUID(), name: "Left Arm", jointNames: ["leftShoulder", "leftElbow", "leftHand"], pinned: false),
            IKChain(id: UUID(), name: "Right Arm", jointNames: ["rightShoulder", "rightElbow", "rightHand"], pinned: false),
            IKChain(id: UUID(), name: "Left Leg", jointNames: ["hip", "leftKnee", "leftFoot"], pinned: false),
            IKChain(id: UUID(), name: "Right Leg", jointNames: ["hip", "rightKnee", "rightFoot"], pinned: false),
        ]

        return BoneRig(bones: resolved, customJoints: [:], ikChains: defaultChains)
    }

    private static func defaultBoneLength(from a: String, to b: String) -> CGFloat {
        guard let pa = StickFigure.defaultJoints[a],
              let pb = StickFigure.defaultJoints[b] else { return 30 }
        return hypot(pb.x - pa.x, pb.y - pa.y)
    }

    private static func defaultConstraint(for joint: String) -> AngleConstraint? {
        switch joint {
        case "leftElbow", "rightElbow":
            return AngleConstraint(minAngle: -160, maxAngle: 0, stiffness: 0.5)
        case "leftKnee", "rightKnee":
            return AngleConstraint(minAngle: 0, maxAngle: 160, stiffness: 0.5)
        case "leftHand", "rightHand":
            return AngleConstraint(minAngle: -90, maxAngle: 90, stiffness: 0.3)
        case "leftFoot", "rightFoot":
            return AngleConstraint(minAngle: -45, maxAngle: 45, stiffness: 0.3)
        default: return nil
        }
    }

    // MARK: - Bone queries
    func bone(for jointB: String) -> Bone? {
        bones.first { $0.jointB == jointB }
    }

    func children(of boneId: UUID) -> [Bone] {
        bones.filter { $0.parentId == boneId }
    }

    func rootBones() -> [Bone] {
        bones.filter { $0.parentId == nil }
    }

    /// All joint names (default + custom)
    func allJointNames() -> [String] {
        var names = Set(StickFigure.defaultJoints.keys)
        for bone in bones {
            names.insert(bone.jointA)
            names.insert(bone.jointB)
        }
        names.formUnion(customJoints.keys)
        return names.sorted()
    }
}

// MARK: - IK Chain
struct IKChain: Codable, Identifiable {
    let id: UUID
    var name: String
    var jointNames: [String]        // Ordered from root to tip
    var pinned: Bool                // Pin endpoint in place
}

// MARK: - IK Solver (CCD — Cyclic Coordinate Descent)
/// Fast, stable, works great for 2–4 bone chains
struct IKSolver {
    static let maxIterations = 10
    static let tolerance: CGFloat = 1.0

    /// Solve IK for a chain: move tip joint toward target, propagate up
    static func solve(
        chain: IKChain,
        target: CGPoint,
        joints: inout [String: CGPoint],
        constraints: [String: AngleConstraint],
        iterations: Int = maxIterations
    ) {
        guard chain.jointNames.count >= 2 else { return }

        let names = chain.jointNames
        let tipName = names.last!

        for _ in 0..<iterations {
            // Check convergence
            guard let tipPos = joints[tipName] else { return }
            if hypot(tipPos.x - target.x, tipPos.y - target.y) < tolerance { return }

            // CCD: iterate from second-to-last to first
            for i in stride(from: names.count - 2, through: 0, by: -1) {
                let pivotName = names[i]
                guard let pivot = joints[pivotName],
                      let tip = joints[tipName] else { continue }

                // Angle from pivot to current tip
                let angleToCurrent = atan2(tip.y - pivot.y, tip.x - pivot.x)
                // Angle from pivot to target
                let angleToTarget = atan2(target.y - pivot.y, target.x - pivot.x)
                // Rotation needed
                var rotation = angleToTarget - angleToCurrent

                // Normalize to [-π, π]
                while rotation > .pi { rotation -= 2 * .pi }
                while rotation < -.pi { rotation += 2 * .pi }

                // Apply constraint stiffness
                if let constraint = constraints[pivotName] {
                    let maxRad = constraint.maxAngle * .pi / 180
                    let minRad = constraint.minAngle * .pi / 180
                    rotation = max(minRad, min(maxRad, rotation))
                    rotation *= constraint.stiffness
                }

                // Rotate all joints from i+1 onward around pivot
                for j in (i + 1)..<names.count {
                    let jName = names[j]
                    guard let jPos = joints[jName] else { continue }
                    joints[jName] = rotatePoint(jPos, around: pivot, by: rotation)
                }
            }
        }
    }

    /// Rotate a point around a center by angle (radians)
    private static func rotatePoint(_ point: CGPoint, around center: CGPoint, by angle: CGFloat) -> CGPoint {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let cosA = cos(angle)
        let sinA = sin(angle)
        return CGPoint(
            x: center.x + dx * cosA - dy * sinA,
            y: center.y + dx * sinA + dy * cosA
        )
    }

    /// Enforce bone length constraint (keep distance fixed between joints)
    static func enforceLengths(
        bones: [Bone],
        joints: inout [String: CGPoint]
    ) {
        for bone in bones {
            guard let posA = joints[bone.jointA],
                  let posB = joints[bone.jointB] else { continue }
            let currentLen = hypot(posB.x - posA.x, posB.y - posA.y)
            guard currentLen > 0.01 else { continue }
            let ratio = bone.length / currentLen
            // Move jointB to maintain length
            joints[bone.jointB] = CGPoint(
                x: posA.x + (posB.x - posA.x) * ratio,
                y: posA.y + (posB.y - posA.y) * ratio
            )
        }
    }
}

// MARK: - Rig Templates
struct RigTemplate: Identifiable {
    let id: String
    let name: String
    let icon: String
    let description: String
    let joints: [String: CGPoint]
    let bones: [(String, String)]

    static let templates: [RigTemplate] = [
        RigTemplate(
            id: "humanoid",
            name: "Humanoid",
            icon: "figure.stand",
            description: "Classic stick figure — 13 joints",
            joints: StickFigure.defaultJoints,
            bones: StickFigure.bones
        ),
        RigTemplate(
            id: "quadruped",
            name: "Quadruped",
            icon: "hare",
            description: "4-legged creature — dog, cat, horse",
            joints: [
                "head": CGPoint(x: -60, y: -20),
                "neck": CGPoint(x: -40, y: -10),
                "spine1": CGPoint(x: -10, y: 0),
                "spine2": CGPoint(x: 20, y: 0),
                "tail": CGPoint(x: 50, y: -10),
                "frontLeftShoulder": CGPoint(x: -30, y: 0),
                "frontLeftKnee": CGPoint(x: -30, y: 25),
                "frontLeftFoot": CGPoint(x: -30, y: 50),
                "frontRightShoulder": CGPoint(x: -10, y: 0),
                "frontRightKnee": CGPoint(x: -10, y: 25),
                "frontRightFoot": CGPoint(x: -10, y: 50),
                "backLeftHip": CGPoint(x: 20, y: 0),
                "backLeftKnee": CGPoint(x: 20, y: 25),
                "backLeftFoot": CGPoint(x: 20, y: 50),
                "backRightHip": CGPoint(x: 40, y: 0),
                "backRightKnee": CGPoint(x: 40, y: 25),
                "backRightFoot": CGPoint(x: 40, y: 50),
            ],
            bones: [
                ("head", "neck"), ("neck", "spine1"), ("spine1", "spine2"), ("spine2", "tail"),
                ("spine1", "frontLeftShoulder"), ("frontLeftShoulder", "frontLeftKnee"), ("frontLeftKnee", "frontLeftFoot"),
                ("spine1", "frontRightShoulder"), ("frontRightShoulder", "frontRightKnee"), ("frontRightKnee", "frontRightFoot"),
                ("spine2", "backLeftHip"), ("backLeftHip", "backLeftKnee"), ("backLeftKnee", "backLeftFoot"),
                ("spine2", "backRightHip"), ("backRightHip", "backRightKnee"), ("backRightKnee", "backRightFoot"),
            ]
        ),
        RigTemplate(
            id: "spider",
            name: "Spider / Bug",
            icon: "ant",
            description: "8-legged creature",
            joints: {
                var j: [String: CGPoint] = [
                    "head": CGPoint(x: -30, y: 0),
                    "body": CGPoint(x: 0, y: 0),
                    "abdomen": CGPoint(x: 30, y: 0),
                ]
                let angles: [CGFloat] = [-60, -30, 30, 60]
                for (i, angle) in angles.enumerated() {
                    let rad = angle * .pi / 180
                    let lx = cos(rad) * 20, ly = sin(rad) * 20
                    let mx = cos(rad) * 40, my = sin(rad) * 40
                    let fx = cos(rad) * 55, fy = sin(rad) * 55
                    j["legL\(i)_hip"] = CGPoint(x: -5 + lx, y: ly)
                    j["legL\(i)_knee"] = CGPoint(x: -5 + mx, y: my)
                    j["legL\(i)_foot"] = CGPoint(x: -5 + fx, y: fy)
                    j["legR\(i)_hip"] = CGPoint(x: 5 - lx, y: ly)
                    j["legR\(i)_knee"] = CGPoint(x: 5 - mx, y: my)
                    j["legR\(i)_foot"] = CGPoint(x: 5 - fx, y: fy)
                }
                return j
            }(),
            bones: {
                var b: [(String, String)] = [("head", "body"), ("body", "abdomen")]
                for i in 0..<4 {
                    b.append(("body", "legL\(i)_hip"))
                    b.append(("legL\(i)_hip", "legL\(i)_knee"))
                    b.append(("legL\(i)_knee", "legL\(i)_foot"))
                    b.append(("body", "legR\(i)_hip"))
                    b.append(("legR\(i)_hip", "legR\(i)_knee"))
                    b.append(("legR\(i)_knee", "legR\(i)_foot"))
                }
                return b
            }()
        ),
        RigTemplate(
            id: "snake",
            name: "Snake / Chain",
            icon: "point.topleft.down.to.point.bottomright.curvepath",
            description: "Flexible spine — rope, tentacle, tail",
            joints: {
                var j: [String: CGPoint] = [:]
                for i in 0..<10 {
                    j["seg\(i)"] = CGPoint(x: CGFloat(i) * 15 - 60, y: 0)
                }
                return j
            }(),
            bones: (0..<9).map { ("seg\($0)", "seg\($0 + 1)") }
        ),
    ]
}
