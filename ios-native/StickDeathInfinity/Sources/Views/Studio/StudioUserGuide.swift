// StudioUserGuide.swift
// Interactive step-by-step user guide for the Animation Studio

import SwiftUI

// MARK: - Data Model

private struct GuideChapter: Identifiable {
    let id = UUID()
    let number: Int
    let icon: String
    let title: String
    let color: Color
    let sections: [GuideSection]
}

private struct GuideSection: Identifiable {
    let id = UUID()
    let title: String
    let steps: [GuideStep]
}

private struct GuideStep: Identifiable {
    let id = UUID()
    let icon: String?       // optional SF Symbol
    let text: String
    let isProTip: Bool
}

// MARK: - Guide Content

private let chapters: [GuideChapter] = [

    // ─────── Chapter 1: First Animation ───────
    GuideChapter(number: 1, icon: "star.fill", title: "Your First Animation", color: .red, sections: [
        GuideSection(title: "Create a Project", steps: [
            GuideStep(icon: "plus.circle.fill", text: "Open the Studio tab and tap '+' to start a new project.", isProTip: false),
            GuideStep(icon: "character.cursor.ibeam", text: "Name your project — this shows in your gallery and when you publish.", isProTip: false),
            GuideStep(icon: "figure.stand", text: "A stick figure appears on the canvas. This is Frame 1.", isProTip: false),
        ]),
        GuideSection(title: "Pose Your Figure", steps: [
            GuideStep(icon: "hand.point.up.left.fill", text: "Make sure you're in Pose mode (the figure icon in the top toolbar).", isProTip: false),
            GuideStep(icon: "circle.fill", text: "Drag any joint (the circles on the figure) to move it. Connected bones follow.", isProTip: false),
            GuideStep(icon: nil, text: "Pose the figure in a starting position — arms up, legs apart, whatever you like.", isProTip: false),
        ]),
        GuideSection(title: "Add Frames", steps: [
            GuideStep(icon: "plus.rectangle.fill", text: "Tap '+' on the bottom timeline to add Frame 2.", isProTip: false),
            GuideStep(icon: nil, text: "The new frame copies the previous pose. Make small changes — move an arm, bend a knee.", isProTip: false),
            GuideStep(icon: "circle.dotted", text: "Turn on Onion Skin (the dotted circle in toolbar) — you'll see a ghost of the last frame to guide you.", isProTip: false),
            GuideStep(icon: nil, text: "Add 5–8 frames total, moving the figure a little each time.", isProTip: false),
        ]),
        GuideSection(title: "Preview & Publish", steps: [
            GuideStep(icon: "play.fill", text: "Hit Play ▶ in the toolbar to watch your animation loop!", isProTip: false),
            GuideStep(icon: "arrow.uturn.backward", text: "Not happy? Undo (↩) takes you back up to 50 steps.", isProTip: false),
            GuideStep(icon: "paperplane.fill", text: "When it looks good, tap Publish (red paper plane) to share with the community.", isProTip: false),
            GuideStep(icon: nil, text: "Start simple — a 5-frame walk cycle or wave is a great first project.", isProTip: true),
        ]),
    ]),

    // ─────── Chapter 2: The Toolbar ───────
    GuideChapter(number: 2, icon: "slider.horizontal.3", title: "Using the Toolbar", color: .cyan, sections: [
        GuideSection(title: "The Scrollable Top Bar", steps: [
            GuideStep(icon: "hand.draw", text: "The top toolbar is a horizontal slider — swipe left/right to see all tools.", isProTip: false),
            GuideStep(icon: nil, text: "Back button and project name are pinned on the left. Publish is pinned on the right.", isProTip: false),
            GuideStep(icon: nil, text: "Everything in between scrolls: modes, undo/redo, play, toggles, import, panels.", isProTip: false),
        ]),
        GuideSection(title: "The Five Modes", steps: [
            GuideStep(icon: "figure.stand", text: "Pose — drag joints to animate figures. This is your primary mode.", isProTip: false),
            GuideStep(icon: "hand.draw", text: "Move — pan and zoom the canvas. Pinch to zoom, double-tap to reset.", isProTip: false),
            GuideStep(icon: "pencil.tip", text: "Draw — freehand sketching for backgrounds, effects, props.", isProTip: false),
            GuideStep(icon: "cursorarrow", text: "Select — tap objects/images to select, drag to move, corner handles to resize.", isProTip: false),
            GuideStep(icon: "figure.stand.line.dotted.figure.stand", text: "Rig — build bone skeletons with IK (inverse kinematics). Advanced tool.", isProTip: false),
        ]),
        GuideSection(title: "Left Side Panel", steps: [
            GuideStep(icon: nil, text: "When you pick Draw or Rig mode, a sub-tool panel appears on the left edge.", isProTip: false),
            GuideStep(icon: "pencil.tip", text: "Draw mode: Pen, Line, Rectangle, Circle, Arrow, Eraser, Text + color/width controls.", isProTip: false),
            GuideStep(icon: "figure.stand.line.dotted.figure.stand", text: "Rig mode: Select, Add Bone, Add Joint, Delete, IK Drag, Pin, Style.", isProTip: false),
            GuideStep(icon: nil, text: "Tap the Tool Key (🔑) in the ⋯ menu to see every icon explained.", isProTip: true),
        ]),
        GuideSection(title: "The ⋯ More Menu", steps: [
            GuideStep(icon: "ellipsis", text: "The ⋯ button opens a dropdown with extra options.", isProTip: false),
            GuideStep(icon: nil, text: "Export Video — save to camera roll. Templates — start from a preset. Tool Key — icon legend. User Guide — you're reading it!", isProTip: false),
        ]),
    ]),

    // ─────── Chapter 3: Drawing ───────
    GuideChapter(number: 3, icon: "pencil.tip", title: "Drawing & Sketching", color: .orange, sections: [
        GuideSection(title: "Freehand Drawing", steps: [
            GuideStep(icon: "pencil.tip", text: "Switch to Draw mode. The left panel shows drawing sub-tools.", isProTip: false),
            GuideStep(icon: nil, text: "Pick Pen (default) and draw on the canvas with your finger.", isProTip: false),
            GuideStep(icon: nil, text: "Tap the color circle to change stroke color. Use the slider for brush width.", isProTip: false),
        ]),
        GuideSection(title: "Shape Tools", steps: [
            GuideStep(icon: "line.diagonal", text: "Line — drag from start to end for a straight line.", isProTip: false),
            GuideStep(icon: "rectangle", text: "Rectangle — drag to define the bounding box.", isProTip: false),
            GuideStep(icon: "circle", text: "Circle — drag to define the bounding box for an ellipse.", isProTip: false),
            GuideStep(icon: "arrow.up.right", text: "Arrow — like Line but with an arrowhead at the end.", isProTip: false),
            GuideStep(icon: nil, text: "Toggle Fill to add solid fill color inside shapes.", isProTip: true),
        ]),
        GuideSection(title: "Text & Eraser", steps: [
            GuideStep(icon: "textformat", text: "Text — tap the canvas to place a text label. Type your text in the panel.", isProTip: false),
            GuideStep(icon: "eraser.fill", text: "Eraser — tap any drawn element to remove it. Works on individual strokes/shapes.", isProTip: false),
            GuideStep(icon: nil, text: "Drawings are per-frame. Draw an explosion on one frame for impact effects!", isProTip: true),
        ]),
    ]),

    // ─────── Chapter 4: Rig & Bones ───────
    GuideChapter(number: 4, icon: "figure.stand.line.dotted.figure.stand", title: "Rig & Bone Animation", color: .cyan, sections: [
        GuideSection(title: "What Is Rigging?", steps: [
            GuideStep(icon: nil, text: "Rigging lets you build a bone skeleton and move it with inverse kinematics (IK).", isProTip: false),
            GuideStep(icon: nil, text: "IK means: drag a hand → the elbow and shoulder move naturally to follow.", isProTip: false),
            GuideStep(icon: nil, text: "This is faster than posing each joint individually, especially for complex figures.", isProTip: false),
        ]),
        GuideSection(title: "Building a Skeleton", steps: [
            GuideStep(icon: "figure.stand.line.dotted.figure.stand", text: "Switch to Rig mode. The left panel shows rig sub-tools.", isProTip: false),
            GuideStep(icon: "line.diagonal", text: "Select 'Add Bone' and tap a joint, then drag to create a new bone.", isProTip: false),
            GuideStep(icon: "plus.circle", text: "'Add Joint' splits an existing bone — inserts a joint at the midpoint.", isProTip: false),
            GuideStep(icon: nil, text: "Or use a template: tap the bone icon at the bottom of the rig panel for Humanoid, Quadruped, Spider, or Snake.", isProTip: true),
        ]),
        GuideSection(title: "IK Dragging", steps: [
            GuideStep(icon: "arrow.triangle.branch", text: "Select 'IK Drag' and drag any joint — the whole chain follows naturally.", isProTip: false),
            GuideStep(icon: "pin.fill", text: "'Pin Joint' locks a joint in place — it won't move during IK. Great for feet on the ground.", isProTip: false),
            GuideStep(icon: nil, text: "Pinned joints show as yellow diamonds on the canvas.", isProTip: false),
        ]),
        GuideSection(title: "Bone Styles", steps: [
            GuideStep(icon: "paintbrush.pointed", text: "Select 'Style' and tap a bone to customize it.", isProTip: false),
            GuideStep(icon: nil, text: "4 render styles: Stick (simple line), Tapered (thick→thin), Block (rectangle), Rounded (capsule).", isProTip: false),
            GuideStep(icon: nil, text: "Adjust thickness and color per bone for expressive characters.", isProTip: false),
            GuideStep(icon: nil, text: "Toggle bone overlay visibility with the 👁 eye icon in the toolbar (Rig mode only).", isProTip: true),
        ]),
    ]),

    // ─────── Chapter 5: Timeline & Frames ───────
    GuideChapter(number: 5, icon: "timeline.selection", title: "Timeline & Frames", color: .green, sections: [
        GuideSection(title: "The Timeline", steps: [
            GuideStep(icon: nil, text: "The bottom strip shows thumbnails of every frame in your animation.", isProTip: false),
            GuideStep(icon: nil, text: "Tap a frame to jump to it. The current frame is highlighted.", isProTip: false),
            GuideStep(icon: "plus.rectangle.fill", text: "'+' adds a new frame after the current one (copies the pose).", isProTip: false),
            GuideStep(icon: "doc.on.doc", text: "'⧉' duplicates the current frame — great for tiny tweaks.", isProTip: false),
            GuideStep(icon: "trash", text: "'🗑' deletes the current frame.", isProTip: false),
        ]),
        GuideSection(title: "Frames Grid", steps: [
            GuideStep(icon: "rectangle.split.3x3", text: "Tap 'Frames' in the toolbar to see all frames in a grid.", isProTip: false),
            GuideStep(icon: nil, text: "Tap any frame to jump to it. Long-press for copy/paste/delete options.", isProTip: false),
            GuideStep(icon: nil, text: "This is faster than scrolling the timeline for animations with many frames.", isProTip: true),
        ]),
        GuideSection(title: "Onion Skinning", steps: [
            GuideStep(icon: "circle.dotted", text: "Toggle Onion Skin in the toolbar to see a ghost of the previous frame.", isProTip: false),
            GuideStep(icon: nil, text: "The ghost appears faded so you can see the difference between frames.", isProTip: false),
            GuideStep(icon: nil, text: "Essential for smooth animation — always keep this on while posing.", isProTip: true),
        ]),
        GuideSection(title: "Project Settings", steps: [
            GuideStep(icon: nil, text: "Tap the project name in the top-left to open Project Settings.", isProTip: false),
            GuideStep(icon: nil, text: "Change FPS (6–30), canvas size presets (TikTok, YouTube, Instagram, HD), and project name.", isProTip: false),
            GuideStep(icon: nil, text: "Higher FPS = smoother animation but more frames needed. 12 FPS is a good starting point.", isProTip: true),
        ]),
    ]),

    // ─────── Chapter 6: Layers & Figures ───────
    GuideChapter(number: 6, icon: "square.3.layers.3d", title: "Layers & Multiple Figures", color: .blue, sections: [
        GuideSection(title: "Adding Figures", steps: [
            GuideStep(icon: "square.3.layers.3d", text: "Tap 'Layers' in the toolbar to open the layers panel.", isProTip: false),
            GuideStep(icon: "plus", text: "Tap 'Add Figure' to create a new stick figure on a separate layer.", isProTip: false),
            GuideStep(icon: nil, text: "Each figure has its own color. Tap a layer to select that figure for editing.", isProTip: false),
        ]),
        GuideSection(title: "Managing Layers", steps: [
            GuideStep(icon: "eye.fill", text: "Use the eye icon to show/hide figures per frame.", isProTip: false),
            GuideStep(icon: nil, text: "Drag layers to reorder — top layer draws on top.", isProTip: false),
            GuideStep(icon: nil, text: "Great for fight scenes: have two figures on separate layers, pose them independently.", isProTip: true),
        ]),
    ]),

    // ─────── Chapter 7: Import & Assets ───────
    GuideChapter(number: 7, icon: "cube.fill", title: "Importing & Assets", color: .mint, sections: [
        GuideSection(title: "Photo Import", steps: [
            GuideStep(icon: "photo.badge.plus", text: "Tap 'Photo' in the toolbar to import an image from your camera roll.", isProTip: false),
            GuideStep(icon: nil, text: "The image lands on the canvas. Switch to Select mode to move/resize it.", isProTip: false),
            GuideStep(icon: nil, text: "Use photos as backgrounds or reference images for tracing.", isProTip: true),
        ]),
        GuideSection(title: "Asset Browser", steps: [
            GuideStep(icon: "cube.fill", text: "Tap 'Assets' to browse 1,000+ objects and sound effects.", isProTip: false),
            GuideStep(icon: nil, text: "Categories: weapons, backgrounds, effects, props, sounds.", isProTip: false),
            GuideStep(icon: nil, text: "Tap any asset to add it to the current frame.", isProTip: false),
        ]),
        GuideSection(title: "AI Assistant (Pro)", steps: [
            GuideStep(icon: "sparkles", text: "Tap 'AI' to open the AI panel (Pro subscribers only).", isProTip: false),
            GuideStep(icon: nil, text: "Describe what you want: 'walking cycle', 'backflip', 'sword fight'.", isProTip: false),
            GuideStep(icon: nil, text: "AI generates a suggestion — tap Apply to use it, then refine manually.", isProTip: false),
            GuideStep(icon: nil, text: "Be specific: 'a 12-frame running cycle with arms pumping' works better than just 'run'.", isProTip: true),
        ]),
    ]),

    // ─────── Chapter 8: Exporting ───────
    GuideChapter(number: 8, icon: "square.and.arrow.down", title: "Exporting & Publishing", color: .green, sections: [
        GuideSection(title: "Export to Camera Roll", steps: [
            GuideStep(icon: "square.and.arrow.down", text: "Tap 'Export' in the toolbar (or ⋯ → Export Video).", isProTip: false),
            GuideStep(icon: nil, text: "Choose your export settings. Pro users can remove the watermark.", isProTip: false),
            GuideStep(icon: nil, text: "The animation renders as a video and saves to your camera roll.", isProTip: false),
        ]),
        GuideSection(title: "Publishing to the Community", steps: [
            GuideStep(icon: "paperplane.fill", text: "Tap the red Publish button (top-right) when your animation is ready.", isProTip: false),
            GuideStep(icon: nil, text: "Give it a title — this appears on the community feed.", isProTip: false),
            GuideStep(icon: nil, text: "Your video uploads to StickDeath's official channels (TikTok, YouTube, Instagram, etc).", isProTip: false),
            GuideStep(icon: nil, text: "Connect your own social accounts in Profile → Connected Accounts to cross-post.", isProTip: true),
        ]),
    ]),
]

// MARK: - View

struct StudioUserGuide: View {
    @Environment(\.dismiss) var dismiss
    @State private var expandedChapter: UUID?

    var body: some View {
        NavigationStack {
            ZStack {
                ThemeManager.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // Hero
                        VStack(spacing: 6) {
                            Text("STICKDEATH ∞")
                                .font(.custom("SpecialElite-Regular", size: 14, relativeTo: .caption))
                                .foregroundStyle(.red)
                                .tracking(2)
                            Text("Studio User Guide")
                                .font(.title2.bold())
                                .foregroundStyle(.white)
                            Text("Everything you need to\nCreate. Animate. Annihilate.")
                                .font(.subheadline)
                                .foregroundStyle(.gray)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 8)
                        .padding(.bottom, 4)

                        // Chapters
                        ForEach(chapters) { chapter in
                            chapterCard(chapter)
                        }

                        // Footer
                        VStack(spacing: 8) {
                            Divider().background(.white.opacity(0.1))
                            Text("Need more help?")
                                .font(.subheadline.bold())
                                .foregroundStyle(.white)
                            Text("Visit Help Center from your Profile tab,\nor ask Spatter AI for tips inside the app.")
                                .font(.caption)
                                .foregroundStyle(.gray)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 40)
                    }
                }
            }
            .navigationTitle("User Guide")
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

    // MARK: - Chapter Card

    private func chapterCard(_ chapter: GuideChapter) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — always visible, tappable
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    expandedChapter = expandedChapter == chapter.id ? nil : chapter.id
                }
            } label: {
                HStack(spacing: 14) {
                    // Chapter number badge
                    Text("\(chapter.number)")
                        .font(.caption2.bold())
                        .foregroundStyle(.black)
                        .frame(width: 22, height: 22)
                        .background(chapter.color)
                        .clipShape(Circle())

                    Image(systemName: chapter.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(chapter.color)
                        .frame(width: 24)

                    Text(chapter.title)
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)

                    Spacer()

                    Image(systemName: expandedChapter == chapter.id ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }

            // Expanded content
            if expandedChapter == chapter.id {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(chapter.sections) { section in
                        sectionView(section, color: chapter.color)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(ThemeManager.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
    }

    // MARK: - Section

    private func sectionView(_ section: GuideSection, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.title)
                .font(.caption.bold())
                .foregroundStyle(color.opacity(0.9))
                .textCase(.uppercase)
                .tracking(0.5)

            ForEach(Array(section.steps.enumerated()), id: \.element.id) { idx, step in
                stepRow(step, number: idx + 1, color: color)
            }
        }
    }

    private func stepRow(_ step: GuideStep, number: Int, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if step.isProTip {
                // Pro tip styling
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.yellow)
                    .frame(width: 20, height: 20)
            } else if let icon = step.icon {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(color.opacity(0.7))
                    .frame(width: 20, height: 20)
            } else {
                Text("\(number)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 20, height: 20)
            }

            Text(step.isProTip ? "💡 \(step.text)" : step.text)
                .font(.caption)
                .foregroundStyle(step.isProTip ? .yellow.opacity(0.85) : .white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
