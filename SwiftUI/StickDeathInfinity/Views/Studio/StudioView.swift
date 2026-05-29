// ═══════════════════════════════════════════════════════════════════
// StudioView — Animation Studio (main tab)
// Matches: src/pages/StudioScreen.tsx exactly
// Two modes:
//   1. NewProjectView — SD logo header, +New Animation, project list
//   2. StudioEditor — Full canvas with toolbar, timeline, layers
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct StudioView: View {
    @StateObject private var vm = StudioViewModel()
    @State private var showEditor = false

    var body: some View {
        if showEditor {
            StudioEditorView(vm: vm, onBack: {
                showEditor = false
            })
        } else {
            StudioProjectListView(vm: vm, onOpenProject: {
                showEditor = true
            })
        }
    }
}

// MARK: - Project List View (matches NewProjectView in React)
struct StudioProjectListView: View {
    @ObservedObject var vm: StudioViewModel
    let onOpenProject: () -> Void

    @State private var showCreate = false
    @State private var projectName = ""
    @State private var selectedFPS = 12
    @State private var canvasWidth = 1080
    @State private var canvasHeight = 1920

    private let canvasPresets = [
        ("Portrait (1080×1920)", 1080, 1920),
        ("Landscape (1920×1080)", 1920, 1080),
        ("Square (1080×1080)", 1080, 1080),
        ("TikTok (1080×1920)", 1080, 1920),
        ("YouTube (1920×1080)", 1920, 1080),
        ("Instagram (1080×1350)", 1080, 1350),
        ("SD (640×480)", 640, 480),
        ("HD (1280×720)", 1280, 720),
    ]

    private let fpsOptions = [6, 8, 10, 12, 15, 24, 30]

    var body: some View {
        VStack(spacing: 0) {
            // Header: SD logo + StickDeath Studio
            HStack(spacing: 12) {
                // SD Logo
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: "#DC2626"), Color(hex: "#991B1B")],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 44, height: 44)
                    Text("☠️")
                        .font(.system(size: 22))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("StickDeath ∞")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Text("Animation Studio")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                }

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Color(hex: "#1a1a24"))

            ScrollView {
                VStack(spacing: 16) {
                    // New Animation button
                    Button(action: { showCreate = true }) {
                        HStack(spacing: 10) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 22))
                            Text("New Animation")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(
                                    LinearGradient(
                                        colors: [Color(hex: "#DC2626"), Color(hex: "#991B1B")],
                                        startPoint: .leading, endPoint: .trailing
                                    )
                                )
                        )
                    }
                    .padding(.horizontal, 20)

                    // Recent Projects
                    if !vm.savedProjects.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("RECENT PROJECTS")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.3))
                                .tracking(1)
                                .padding(.horizontal, 20)

                            ForEach(vm.savedProjects) { proj in
                                Button(action: {
                                    vm.openProject(proj)
                                    onOpenProject()
                                }) {
                                    HStack(spacing: 12) {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.white.opacity(0.06))
                                            .frame(width: 50, height: 40)
                                            .overlay(
                                                Text("🎬")
                                                    .font(.system(size: 18))
                                            )

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(proj.name)
                                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                                .foregroundColor(.white)
                                            Text("\(proj.fps ?? 12) FPS · \(proj.frameCount ?? 1) frames")
                                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                                .foregroundColor(.white.opacity(0.35))
                                        }

                                        Spacer()

                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 10))
                                            .foregroundColor(.white.opacity(0.2))
                                    }
                                    .padding(12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(Color(hex: "#12121a"))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 10)
                                                    .stroke(Color.white.opacity(0.05), lineWidth: 1)
                                            )
                                    )
                                }
                                .padding(.horizontal, 20)
                            }
                        }
                    }
                }
                .padding(.vertical, 16)
            }
        }
        .background(Color(hex: "#0d0d14").ignoresSafeArea())
        .sheet(isPresented: $showCreate) {
            CreateProjectSheet(
                name: $projectName,
                selectedFPS: $selectedFPS,
                width: $canvasWidth,
                height: $canvasHeight,
                presets: canvasPresets,
                fpsOptions: fpsOptions,
                onCreate: {
                    vm.createProject(name: projectName.isEmpty ? "Untitled Animation" : projectName, width: canvasWidth, height: canvasHeight, fps: selectedFPS)
                    showCreate = false
                    onOpenProject()
                }
            )
            .presentationDetents([.medium])
        }
    }
}

// MARK: - Create Project Sheet
struct CreateProjectSheet: View {
    @Binding var name: String
    @Binding var selectedFPS: Int
    @Binding var width: Int
    @Binding var height: Int
    let presets: [(String, Int, Int)]
    let fpsOptions: [Int]
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("New Animation")
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.top, 16)

            TextField("Project Name", text: $name)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(hex: "#12121a"))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1)))
                )
                .padding(.horizontal, 20)

            // Canvas size presets
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(presets, id: \.0) { preset in
                        Button(action: { width = preset.1; height = preset.2 }) {
                            Text(preset.0)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(width == preset.1 && height == preset.2 ? Color(hex: "#DC2626") : .white.opacity(0.4))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(width == preset.1 && height == preset.2 ? Color(hex: "#DC2626").opacity(0.15) : Color.white.opacity(0.04))
                                )
                        }
                    }
                }
                .padding(.horizontal, 20)
            }

            // FPS selector
            HStack {
                Text("FPS:")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                ForEach(fpsOptions, id: \.self) { fps in
                    Button(action: { selectedFPS = fps }) {
                        Text("\(fps)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(selectedFPS == fps ? Color(hex: "#DC2626") : .white.opacity(0.4))
                            .frame(width: 32, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(selectedFPS == fps ? Color(hex: "#DC2626").opacity(0.15) : Color.white.opacity(0.04))
                            )
                    }
                }
            }
            .padding(.horizontal, 20)

            Button(action: onCreate) {
                Text("CREATE")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(hex: "#DC2626"))
                    )
            }
            .padding(.horizontal, 20)

            Spacer()
        }
        .background(Color(hex: "#1a1a24").ignoresSafeArea())
    }
}

// ═══════════════════════════════════════════════════════════════════════
// MAIN STUDIO EDITOR — Full layout matching the video tour
// ═══════════════════════════════════════════════════════════════════════

struct StudioEditorView: View {
    @ObservedObject var vm: StudioViewModel
    let onBack: () -> Void

    var body: some View {
        ZStack {
            Color(hex: "#0d0d14").ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Header Bar ──
                StudioHeaderBar(vm: vm, onBack: onBack)

                // ── Tool Strip ──
                if vm.showToolbar {
                    StudioToolStrip(vm: vm)
                }

                // ── Canvas Area ──
                ZStack {
                    Color(hex: "#12121a")

                    StudioCanvasView(vm: vm)
                        .scaleEffect(vm.canvasScale)
                        .offset(vm.canvasOffset)

                    // Zoom controls (right side)
                    VStack(spacing: 8) {
                        Spacer()
                        ZoomButton(label: "+") { vm.zoomIn() }
                        ZoomButton(label: "−") { vm.zoomOut() }
                        ZoomButton(label: "FIT") { vm.zoomFit() }
                        Spacer().frame(height: 60)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 12)
                }
                .clipped()

                // ── Timeline ──
                StudioTimelineBar(vm: vm)

                // ── Bottom Toolbar ──
                StudioBottomBar(vm: vm)
            }

            // ── Slide-up Panels ──
            if vm.activePanel != .none {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation { vm.activePanel = .none } }

                VStack {
                    Spacer()
                    panelContent
                }
                .transition(.move(edge: .bottom))
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: vm.activePanel)
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    var panelContent: some View {
        switch vm.activePanel {
        case .toolSettings: ToolSettingsPanel(vm: vm)
        case .colorPicker: ColorPickerPanel(vm: vm)
        case .export: ExportPanel(vm: vm)
        case .framesViewer: FramesViewerPanel(vm: vm)
        case .projectSettings: ProjectSettingsPanel(vm: vm)
        case .layers: LayerPanel(vm: vm)
        case .stickerEmoji: StickerEmojiPanel(vm: vm)
        case .addImage: AddImagePanel(vm: vm)
        case .audioTimeline: AudioTimelinePanel(vm: vm)
        case .soundLibrary: SoundLibraryPanel(vm: vm)
        default: EmptyView()
        }
    }
}

// MARK: - Zoom Button
struct ZoomButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: label == "FIT" ? 10 : 16, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))
                )
        }
    }
}
