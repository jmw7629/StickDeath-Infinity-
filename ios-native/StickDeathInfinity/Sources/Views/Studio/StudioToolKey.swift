// StudioToolKey.swift
// Visual icon legend — every tool in the Studio explained at a glance

import SwiftUI

struct StudioToolKey: View {
    @Environment(\.dismiss) var dismiss

    // MARK: - Data

    private struct ToolEntry: Identifiable {
        let id = UUID()
        let icon: String
        let name: String
        let description: String
        let tint: Color
    }

    private struct ToolGroup: Identifiable {
        let id = UUID()
        let title: String
        let tools: [ToolEntry]
    }

    private let groups: [ToolGroup] = [
        ToolGroup(title: "Creative Modes", tools: [
            ToolEntry(icon: "figure.stand", name: "Pose", description: "Drag joints to pose stick figures. Each frame stores a unique pose.", tint: .red),
            ToolEntry(icon: "hand.draw", name: "Move", description: "Pan and zoom the canvas. Pinch to zoom, drag to pan, double-tap to reset.", tint: .red),
            ToolEntry(icon: "pencil.tip", name: "Draw", description: "Freehand sketching — backgrounds, effects, props. Opens drawing sub-tools on the left.", tint: .red),
            ToolEntry(icon: "cursorarrow", name: "Select", description: "Tap to select objects & imported images. Drag to move, corner handles to resize.", tint: .red),
            ToolEntry(icon: "figure.stand.line.dotted.figure.stand", name: "Rig", description: "Bone/rig animation. Build skeletons, drag with IK, pin joints. Opens rig panel on the left.", tint: .red),
        ]),
        ToolGroup(title: "Drawing Sub-Tools (Draw Mode)", tools: [
            ToolEntry(icon: "pencil.tip", name: "Pen", description: "Freehand pencil — draw anything with your finger.", tint: .orange),
            ToolEntry(icon: "line.diagonal", name: "Line", description: "Straight line — tap start point, drag to end.", tint: .orange),
            ToolEntry(icon: "rectangle", name: "Rectangle", description: "Rectangle or square shape.", tint: .orange),
            ToolEntry(icon: "circle", name: "Circle", description: "Circle or ellipse shape.", tint: .orange),
            ToolEntry(icon: "arrow.up.right", name: "Arrow", description: "Arrow line — great for annotations and motion guides.", tint: .orange),
            ToolEntry(icon: "eraser.fill", name: "Eraser", description: "Erase drawn elements by tapping them.", tint: .orange),
            ToolEntry(icon: "textformat", name: "Text", description: "Add text labels to the canvas.", tint: .orange),
        ]),
        ToolGroup(title: "Rig Sub-Tools (Rig Mode)", tools: [
            ToolEntry(icon: "cursorarrow", name: "Select", description: "Select and move bones or joints.", tint: .cyan),
            ToolEntry(icon: "line.diagonal", name: "Add Bone", description: "Tap a joint, drag to create a new bone extending from it.", tint: .cyan),
            ToolEntry(icon: "plus.circle", name: "Add Joint", description: "Tap a bone to split it — inserts a joint at the midpoint.", tint: .cyan),
            ToolEntry(icon: "minus.circle", name: "Delete Bone", description: "Tap a bone to remove it from the skeleton.", tint: .cyan),
            ToolEntry(icon: "arrow.triangle.branch", name: "IK Drag", description: "Inverse kinematics — drag an endpoint and the whole chain follows naturally.", tint: .cyan),
            ToolEntry(icon: "pin.fill", name: "Pin Joint", description: "Lock a joint in place as an IK anchor. Pinned joints won't move during IK drag.", tint: .cyan),
            ToolEntry(icon: "paintbrush.pointed", name: "Style", description: "Edit bone appearance — thickness, color, and render style (stick/tapered/block/rounded).", tint: .cyan),
        ]),
        ToolGroup(title: "Playback & History", tools: [
            ToolEntry(icon: "arrow.uturn.backward", name: "Undo", description: "Undo last action — up to 50 steps.", tint: .white),
            ToolEntry(icon: "arrow.uturn.forward", name: "Redo", description: "Redo a previously undone action.", tint: .white),
            ToolEntry(icon: "play.fill", name: "Play", description: "Preview your animation. Tap again to pause.", tint: .red),
        ]),
        ToolGroup(title: "Canvas Overlays", tools: [
            ToolEntry(icon: "circle.dotted", name: "Onion Skin", description: "Show a ghost of the previous frame — essential for smooth animation.", tint: .blue),
            ToolEntry(icon: "grid", name: "Grid", description: "Show grid lines on the canvas for alignment.", tint: .white),
            ToolEntry(icon: "eye.fill", name: "Bone Overlay", description: "Toggle bone visibility on/off (only in Rig mode).", tint: .green),
        ]),
        ToolGroup(title: "Content & Import", tools: [
            ToolEntry(icon: "photo.badge.plus", name: "Photo Import", description: "Import an image from your camera roll onto the canvas.", tint: .green),
            ToolEntry(icon: "cube.fill", name: "Assets", description: "Browse 1,000+ objects and sound effects to add to your scene.", tint: .mint),
            ToolEntry(icon: "sparkles", name: "AI Assist", description: "Let AI generate animation suggestions — describe what you want. Pro only.", tint: .purple),
        ]),
        ToolGroup(title: "Panels & Output", tools: [
            ToolEntry(icon: "rectangle.split.3x3", name: "Frames", description: "Grid view of all frames. Tap to jump, long-press for options.", tint: .white),
            ToolEntry(icon: "square.3.layers.3d", name: "Layers", description: "Manage multiple stick figures — add, reorder, show/hide per frame.", tint: .white),
            ToolEntry(icon: "square.and.arrow.down", name: "Export", description: "Export your animation as a video to your camera roll.", tint: .white),
            ToolEntry(icon: "paperplane.fill", name: "Publish", description: "Share your finished animation to the StickDeath community.", tint: .red),
        ]),
        ToolGroup(title: "Canvas Handles", tools: [
            ToolEntry(icon: "circle.fill", name: "Joint (Circle)", description: "Pose mode — drag to move a joint. Orange = selected.", tint: .white),
            ToolEntry(icon: "diamond.fill", name: "Joint (Diamond)", description: "Rig mode — diamond-shaped handles for bone joints.", tint: .cyan),
            ToolEntry(icon: "diamond.fill", name: "Pinned Joint", description: "Yellow diamond — this joint is pinned (locked) for IK.", tint: .yellow),
        ]),
    ]

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                ThemeManager.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        // Header card
                        VStack(spacing: 8) {
                            Image(systemName: "key.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(.red)
                            Text("Every icon in the Studio, explained.")
                                .font(.subheadline)
                                .foregroundStyle(.gray)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 8)

                        // Tool groups
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(group.title)
                                    .font(.caption.bold())
                                    .foregroundStyle(.gray)
                                    .textCase(.uppercase)
                                    .tracking(1)
                                    .padding(.horizontal, 20)

                                VStack(spacing: 0) {
                                    ForEach(Array(group.tools.enumerated()), id: \.element.id) { idx, tool in
                                        toolRow(tool)
                                        if idx < group.tools.count - 1 {
                                            Divider()
                                                .background(.white.opacity(0.06))
                                                .padding(.leading, 60)
                                        }
                                    }
                                }
                                .background(ThemeManager.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .padding(.horizontal, 16)
                            }
                        }

                        // Footer
                        Text("Swipe the top toolbar to see all tools.\nTap any mode to reveal its sub-tools on the left.")
                            .font(.caption)
                            .foregroundStyle(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.bottom, 32)
                    }
                }
            }
            .navigationTitle("Tool Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.gray)
                    }
                }
            }
        }
    }

    // MARK: - Row

    private func toolRow(_ tool: ToolEntry) -> some View {
        HStack(spacing: 14) {
            Image(systemName: tool.icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tool.tint)
                .frame(width: 32, height: 32)
                .background(tool.tint.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                Text(tool.description)
                    .font(.caption)
                    .foregroundStyle(.gray)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
