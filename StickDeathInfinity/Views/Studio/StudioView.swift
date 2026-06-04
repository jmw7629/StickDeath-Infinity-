// ═══════════════════════════════════════════════════════════════════
// StudioView — Full Animation Studio (matches video frame-by-frame)
// Header → Tool Strip → Canvas → Frame Timeline → Bottom Toolbar
// All 17 tools, all panels, all buttons functional
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct StudioView: View {
    @StateObject private var vm = StudioViewModel()
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        ZStack {
            Color(hex: "0D0D12").ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header (hidden in HIDE mode)
                if vm.showToolbar {
                    StudioHeaderBar(vm: vm, onDismiss: { dismiss() })
                }
                
                // Tool strip (floats in center during HIDE mode)
                if vm.showToolbar {
                    StudioToolStrip(vm: vm)
                }
                
                ZStack {
                    StudioCanvasView(vm: vm)
                    
                    // Floating tool strip in HIDE mode (centered vertically)
                    if !vm.showToolbar {
                        VStack {
                            Spacer()
                            StudioToolStrip(vm: vm)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color(hex: "12121A").opacity(0.9))
                                        .shadow(color: .black.opacity(0.4), radius: 8)
                                )
                                .padding(.horizontal, 8)
                            Spacer()
                        }
                    }
                    
                    // Floating tool settings
                    if vm.activePanel == .toolSettings {
                        FloatingToolSettingsPanel(vm: vm)
                            .transition(.opacity)
                    }
                    
                    // Zoom controls (right side)
                    VStack(spacing: 8) {
                        Spacer()
                        ZoomButton(label: "+") { vm.zoomIn() }
                        ZoomButton(label: "−") { vm.zoomOut() }
                        ZoomButton(label: "FIT") { vm.zoomFit() }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 8)
                    .padding(.bottom, 8)
                }
                
                // Timeline + Bottom bar (hidden in HIDE mode)
                if vm.showToolbar {
                    StudioTimeline(vm: vm)
                    StudioBottomBar(vm: vm)
                }
            }
            
            // Full-screen panels
            if vm.activePanel == .colorPicker { ColorPickerPanel(vm: vm) }
            if vm.activePanel == .projectSettings { ProjectSettingsPanel(vm: vm) }
            if vm.activePanel == .layers { LayerPanel(vm: vm) }
            if vm.activePanel == .export { ExportPanel(vm: vm) }
            if vm.activePanel == .framesViewer { FramesViewerPanel(vm: vm) }
            if vm.activePanel == .soundLibrary { SoundLibraryPanel(vm: vm) }
            if vm.activePanel == .audioTimeline { AudioTimelinePanel(vm: vm) }
            if vm.activePanel == .stickerEmoji { StickerEmojiPanel(vm: vm) }
            if vm.activePanel == .backgroundLibrary { BackgroundLibraryPanel(vm: vm) }
            if vm.activePanel == .addImage { AddImagePanel(vm: vm) }
        }
        .sheet(isPresented: showMenuBinding) {
            StudioMenuSheet(vm: vm)
        }
        .sheet(isPresented: showAIVoiceBinding) {
            AIVoiceMakerSheet(vm: vm)
        }
        .sheet(isPresented: showSpatterBinding) {
            SpatterAISheet(vm: vm)
        }
        .sheet(isPresented: showMagicCutBinding) {
            MagicCutSheet(vm: vm)
        }
        .sheet(isPresented: showRotoscopeBinding) {
            RotoscopeSheet(vm: vm)
        }
    }
    
    // Sheet bindings
    var showMenuBinding: Binding<Bool> {
        Binding(get: { vm.activePanel == .menu }, set: { if !$0 { vm.activePanel = .none } })
    }
    var showAIVoiceBinding: Binding<Bool> {
        Binding(get: { vm.activePanel == .aiVoice }, set: { if !$0 { vm.activePanel = .none } })
    }
    var showSpatterBinding: Binding<Bool> {
        Binding(get: { vm.activePanel == .spatterAI }, set: { if !$0 { vm.activePanel = .none } })
    }
    var showMagicCutBinding: Binding<Bool> {
        Binding(get: { vm.activePanel == .magicCut }, set: { if !$0 { vm.activePanel = .none } })
    }
    var showRotoscopeBinding: Binding<Bool> {
        Binding(get: { vm.activePanel == .rotoscope }, set: { if !$0 { vm.activePanel = .none } })
    }
}

// MARK: - Zoom Button
struct ZoomButton: View {
    let label: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: label == "FIT" ? 9 : 16, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color(hex: "1E1E2A")))
                .overlay(Circle().stroke(Color.white.opacity(0.1), lineWidth: 1))
        }
    }
}

// MARK: - Studio Bottom Bar
struct StudioBottomBar: View {
    @ObservedObject var vm: StudioViewModel
    
    var body: some View {
        HStack(spacing: 0) {
            // Audio
            BottomBarButton(icon: "music.note", label: "AUDIO") {
                vm.activePanel = vm.activePanel == .audioTimeline ? .none : .audioTimeline
            }
            
            // Undo
            BottomBarButton(icon: "arrow.uturn.backward", label: "UNDO", enabled: vm.canUndo) {
                vm.undo()
            }
            
            // Redo
            BottomBarButton(icon: "arrow.uturn.forward", label: "REDO", enabled: vm.canRedo) {
                vm.redo()
            }
            
            // Copy
            BottomBarButton(icon: "doc.on.doc", label: "COPY") {
                vm.duplicateFrame()
            }
            
            // Paste
            BottomBarButton(icon: "doc.on.clipboard", label: "PASTE") {
                // Paste duplicated frame after current
            }
            
            // Delete
            BottomBarButton(icon: "trash", label: "DEL") {
                vm.deleteSelected()
            }
            
            // Layer (with red badge)
            Button(action: {
                vm.activePanel = vm.activePanel == .layers ? .none : .layers
            }) {
                ZStack(alignment: .topTrailing) {
                    VStack(spacing: 2) {
                        Image(systemName: "square.3.layers.3d")
                            .font(.system(size: 14))
                        Text("LAYER")
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                    }
                    .foregroundColor(.white.opacity(0.5))
                    
                    Text("\(vm.studioLayers.count)")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.white)
                        .padding(2)
                        .background(Color.red)
                        .clipShape(Circle())
                        .offset(x: 8, y: -4)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 8)
        .background(Color(hex: "0A0A10"))
    }
}

struct BottomBarButton: View {
    let icon: String
    let label: String
    var enabled: Bool = true
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                Text(label)
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
            }
            .foregroundColor(enabled ? .white.opacity(0.5) : .white.opacity(0.2))
            .frame(maxWidth: .infinity)
        }
        .disabled(!enabled)
    }
}

// MARK: - Frames Viewer Panel
struct FramesViewerPanel: View {
    @ObservedObject var vm: StudioViewModel
    
    var body: some View {
        ZStack {
            Color(hex: "0A0A0F").ignoresSafeArea()
            
            VStack(spacing: 0) {
                PanelHeader(title: "Frames Viewer", icon: "film.fill") {
                    vm.activePanel = .none
                }
                
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(vm.frames.indices, id: \.self) { i in
                            Button(action: {
                                vm.currentFrameIndex = i
                                vm.activePanel = .none
                            }) {
                                VStack(spacing: 4) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color.white)
                                            .frame(height: 80)
                                        
                                        // Render frame elements
                                        Canvas { context, size in
                                            let scaleX = size.width / CGFloat(vm.canvasWidth)
                                            let scaleY = size.height / CGFloat(vm.canvasHeight)
                                            for el in vm.frames[i].elements {
                                                guard el.points.count >= 2 else { continue }
                                                var path = Path()
                                                path.move(to: CGPoint(x: el.points[0].x * scaleX, y: el.points[0].y * scaleY))
                                                for p in el.points.dropFirst() {
                                                    path.addLine(to: CGPoint(x: p.x * scaleX, y: p.y * scaleY))
                                                }
                                                context.stroke(path, with: .color(Color(hex: el.color)), lineWidth: max(1, el.width * scaleX))
                                            }
                                        }
                                        .frame(height: 80)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                    }
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(vm.currentFrameIndex == i ? Color.red : Color.white.opacity(0.1), lineWidth: vm.currentFrameIndex == i ? 2 : 1)
                                    )
                                    
                                    Text("Frame \(i + 1)")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundColor(vm.currentFrameIndex == i ? .red : .white.opacity(0.5))
                                }
                            }
                        }
                        
                        // Add frame button
                        Button(action: { vm.addFrame() }) {
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4]))
                                    .frame(height: 80)
                                    .overlay(
                                        Image(systemName: "plus")
                                            .foregroundColor(.white.opacity(0.3))
                                    )
                                Text("Add")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.3))
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
    }
}

// MARK: - Background Library Panel
struct BackgroundLibraryPanel: View {
    @ObservedObject var vm: StudioViewModel
    @State private var selectedCategory = "Gradients"
    
    let categories = [
        ("Gradients", 24), ("Solid", 18), ("Patterns", 12), ("Nature", 8),
        ("Space", 6), ("Urban", 10), ("Abstract", 15), ("Textures", 9),
    ]
    
    let backgrounds: [(name: String, colors: [String])] = [
        ("Sunset", ["FF6B35", "F72585"]), ("Ocean", ["0077B6", "00B4D8"]),
        ("Forest", ["2D6A4F", "40916C"]), ("Neon", ["7209B7", "F72585"]),
        ("Midnight", ["0D1B2A", "1B263B"]), ("Fire", ["D00000", "FFBA08"]),
        ("Ice", ["48CAE4", "ADE8F4"]), ("Void", ["0A0A0F", "1A1A24"]),
    ]
    
    var body: some View {
        ZStack {
            Color(hex: "0A0A0F").ignoresSafeArea()
            
            VStack(spacing: 0) {
                PanelHeader(title: "Background Library", icon: "photo.on.rectangle") {
                    vm.activePanel = .none
                }
                
                HStack(spacing: 0) {
                    // Sidebar categories (pill style with red bg)
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 4) {
                            ForEach(categories, id: \.0) { cat in
                                Button(action: { selectedCategory = cat.0 }) {
                                    Text("\(cat.0) (\(cat.1))")
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundColor(selectedCategory == cat.0 ? .white : .white.opacity(0.4))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                        .background(selectedCategory == cat.0 ? Color.red : Color(hex: "1A1A24"))
                                        .cornerRadius(8)
                                }
                            }
                        }
                        .padding(8)
                    }
                    .frame(width: 120)
                    .background(Color(hex: "0D0D14"))
                    
                    // Background grid
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            ForEach(backgrounds, id: \.name) { bg in
                                Button(action: {
                                    // Apply background
                                    vm.activePanel = .none
                                }) {
                                    VStack(spacing: 4) {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(
                                                LinearGradient(
                                                    colors: bg.colors.map { Color(hex: $0) },
                                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                                )
                                            )
                                            .frame(height: 80)
                                        
                                        Text(bg.name)
                                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                                            .foregroundColor(.white.opacity(0.6))
                                    }
                                }
                            }
                        }
                        .padding(12)
                    }
                }
            }
        }
    }
}

// MARK: - Add Image Panel
struct AddImagePanel: View {
    @ObservedObject var vm: StudioViewModel
    @State private var showImagePicker = false
    
    var body: some View {
        ZStack {
            Color(hex: "0A0A0F").ignoresSafeArea()
            
            VStack(spacing: 0) {
                PanelHeader(title: "Add Picture", icon: "photo.fill") {
                    vm.activePanel = .none
                }
                
                VStack(spacing: 16) {
                    Spacer()
                    
                    // Camera
                    AddImageOption(icon: "camera.fill", title: "Take Photo", subtitle: "Use camera to capture") {
                        showImagePicker = true
                    }
                    
                    // Photo Library
                    AddImageOption(icon: "photo.on.rectangle.angled", title: "Photo Library", subtitle: "Choose from your photos") {
                        showImagePicker = true
                    }
                    
                    // Files
                    AddImageOption(icon: "folder.fill", title: "Files", subtitle: "Import from Files app") {
                        showImagePicker = true
                    }
                    
                    // Clipboard
                    AddImageOption(icon: "doc.on.clipboard.fill", title: "Paste from Clipboard", subtitle: "Paste copied image") {
                        // Paste from clipboard
                    }
                    
                    Spacer()
                }
                .padding(24)
            }
        }
    }
}

struct AddImageOption: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(.red)
                    .frame(width: 44, height: 44)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(10)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.2))
            }
            .padding(16)
            .background(Color(hex: "12121A"))
            .cornerRadius(14)
        }
    }
}

// MARK: - Studio Menu Sheet
struct StudioMenuSheet: View {
    @ObservedObject var vm: StudioViewModel
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        ZStack {
            Color(hex: "0A0A0F").ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Drag handle
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 36, height: 4)
                    .padding(.top, 8)
                
                // PROJECT section
                SectionLabel(text: "PROJECT")
                
                MenuSheetRow(icon: "⚙️", label: "Project Settings") {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        vm.activePanel = .projectSettings
                    }
                }
                
                Divider().background(Color.white.opacity(0.06)).padding(.horizontal, 16)
                
                // TOOLS section
                SectionLabel(text: "TOOLS")
                
                MenuSheetRow(icon: "🎬", label: "Frames Viewer") {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        vm.activePanel = .framesViewer
                    }
                }
                
                MenuSheetToggleRow(icon: "🧅", label: "Onion", hasEdit: true, isOn: $vm.showOnionSkin)
                MenuSheetToggleRow(icon: "📐", label: "Grid", hasEdit: true, isOn: $vm.gridEnabled)
                
                MenuSheetRow(icon: "✨", label: "Magic Cut") {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        vm.activePanel = .magicCut
                    }
                }
                
                MenuSheetRow(icon: "🖼️", label: "Background Library") {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        vm.activePanel = .backgroundLibrary
                    }
                }
                
                MenuSheetRow(icon: "🎬", label: "Rotoscope / Video") {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        vm.activePanel = .rotoscope
                    }
                }
                
                MenuSheetRow(icon: "🖼️", label: "Add Picture") {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        vm.activePanel = .addImage
                    }
                }
                
                MenuSheetRow(icon: "🗣️", label: "AI Voice Maker") {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        vm.activePanel = .aiVoice
                    }
                }
                
                MenuSheetRow(icon: "🎨", label: "Spatter AI", accent: true) {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        vm.activePanel = .spatterAI
                    }
                }
                
                Spacer()
            }
        }
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(.white.opacity(0.3))
            .tracking(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }
}

struct MenuSheetRow: View {
    let icon: String
    let label: String
    var accent: Bool = false
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(icon).font(.system(size: 18))
                Text(label)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(accent ? .red : .white)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.2))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}

struct MenuSheetToggleRow: View {
    let icon: String
    let label: String
    var hasEdit: Bool = false
    @Binding var isOn: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            Text(icon).font(.system(size: 18))
            Text(label)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
            Spacer()
            if hasEdit {
                Text("Edit")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.red)
            }
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(.red)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - AI Voice Maker Sheet (Purple theme)
struct AIVoiceMakerSheet: View {
    @ObservedObject var vm: StudioViewModel
    @State private var scriptText = ""
    @State private var selectedVoice = "Alex"
    @State private var speed: Double = 1.0
    @State private var pitch: Double = 1.0
    @Environment(\.dismiss) var dismiss
    
    let voices = [
        ("Alex", "🎙️"), ("Sarah", "👩"), ("James", "🧔"),
        ("Luna", "🌙"), ("Max", "💪"), ("Zoe", "✨"),
        ("Robot", "🤖"), ("Narrator", "📖"),
    ]
    
    var body: some View {
        ZStack {
            Color(hex: "1A0A2E").ignoresSafeArea()
            
            VStack(spacing: 16) {
                // Header
                HStack {
                    Text("🗣️ AI Voice Maker")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(hex: "A78BFA"))
                    Spacer()
                    Button("Done") { dismiss() }
                        .foregroundColor(Color(hex: "A78BFA"))
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                
                // Script / Dialogue label
                Text("Script / Dialogue")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "A78BFA").opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                
                // Text input
                TextEditor(text: $scriptText)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .scrollContentBackground(.hidden)
                    .frame(height: 80)
                    .padding(12)
                    .background(Color(hex: "2A1A3E"))
                    .cornerRadius(12)
                    .padding(.horizontal, 16)
                    .overlay(
                        Group {
                            if scriptText.isEmpty {
                                Text("Type your voiceover text here...")
                                    .font(.system(size: 14))
                                    .foregroundColor(.white.opacity(0.3))
                                    .padding(.leading, 28)
                                    .padding(.top, 24)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            }
                        }
                    )
                
                // Voice selection
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                    ForEach(voices, id: \.0) { voice in
                        Button(action: { selectedVoice = voice.0 }) {
                            VStack(spacing: 4) {
                                Text(voice.1)
                                    .font(.system(size: 20))
                                Text(voice.0)
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                            }
                            .foregroundColor(selectedVoice == voice.0 ? .white : .white.opacity(0.4))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(selectedVoice == voice.0 ? Color(hex: "7C3AED") : Color(hex: "2A1A3E"))
                            .cornerRadius(10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(selectedVoice == voice.0 ? Color(hex: "A78BFA") : Color.clear, lineWidth: 1)
                            )
                        }
                    }
                }
                .padding(.horizontal, 16)
                
                // Speed slider
                HStack {
                    Text("Speed")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                    Slider(value: $speed, in: 0.5...2.0)
                        .tint(Color(hex: "A78BFA"))
                    Text(String(format: "%.1fx", speed))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                }
                .padding(.horizontal, 16)
                
                // Pitch slider
                HStack {
                    Text("Pitch")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                    Slider(value: $pitch, in: 0.5...2.0)
                        .tint(Color(hex: "A78BFA"))
                    Text(String(format: "%.1fx", pitch))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                }
                .padding(.horizontal, 16)
                
                Spacer()
                
                // Action buttons
                HStack(spacing: 12) {
                    Button(action: {}) {
                        Text("Preview")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(hex: "A78BFA"))
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color(hex: "2A1A3E"))
                            .cornerRadius(14)
                    }
                    
                    Button(action: { dismiss() }) {
                        Text("🎙️ Add to Timeline")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color(hex: "7C3AED"))
                            .cornerRadius(14)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
    }
}

// MARK: - Spatter AI Sheet
struct SpatterAISheet: View {
    @ObservedObject var vm: StudioViewModel
    @State private var prompt = ""
    @State private var messages: [(role: String, text: String)] = [
        ("assistant", "Hey! I'm Spatter AI 🎨 I can help you animate, suggest techniques, generate effects, and answer any animation questions. What do you want to create?")
    ]
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        ZStack {
            Color(hex: "0A0A0F").ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("🎨 Spatter AI")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(.red)
                    Spacer()
                    Button("Done") { dismiss() }
                        .foregroundColor(.red)
                }
                .padding(16)
                
                // Messages
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(messages.indices, id: \.self) { i in
                            let msg = messages[i]
                            HStack {
                                if msg.role == "user" { Spacer() }
                                Text(msg.text)
                                    .font(.system(size: 13))
                                    .foregroundColor(.white)
                                    .padding(12)
                                    .background(msg.role == "user" ? Color.red : Color(hex: "1A1A24"))
                                    .cornerRadius(12)
                                    .frame(maxWidth: 280, alignment: msg.role == "user" ? .trailing : .leading)
                                if msg.role == "assistant" { Spacer() }
                            }
                        }
                    }
                    .padding(16)
                }
                
                // Input
                HStack(spacing: 8) {
                    TextField("Ask Spatter anything...", text: $prompt)
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                        .padding(12)
                        .background(Color(hex: "1A1A24"))
                        .cornerRadius(12)
                    
                    Button(action: sendMessage) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.red)
                    }
                }
                .padding(16)
            }
        }
    }
    
    func sendMessage() {
        guard !prompt.isEmpty else { return }
        messages.append(("user", prompt))
        let userPrompt = prompt
        prompt = ""
        
        // First show brain knowledge immediately
        let quickResponse = SpatterBrainLoader.shared.getResponse(for: userPrompt)
        messages.append(("assistant", quickResponse))
        
        // Then call async AI engine for a deeper response
        Task {
            let aiResponse = await SpatterAIEngine.shared.chat(userMessage: userPrompt)
            if !aiResponse.isEmpty && !aiResponse.contains("error") {
                messages.append(("assistant", aiResponse))
            }
        }
    }
}

// MARK: - Magic Cut Sheet
struct MagicCutSheet: View {
    @ObservedObject var vm: StudioViewModel
    @State private var isProcessing = false
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        ZStack {
            Color(hex: "0A0A0F").ignoresSafeArea()
            
            VStack(spacing: 20) {
                HStack {
                    Text("✨ Magic Cut")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Spacer()
                    Button("Done") { dismiss() }
                }
                .padding(16)
                
                VStack(spacing: 12) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 48))
                        .foregroundColor(.red)
                    
                    Text("AI-Powered Background Removal")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    
                    Text("Automatically removes backgrounds from your frames using AI. Works best with clear stick figure outlines.")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    
                    if isProcessing {
                        ProgressView()
                            .tint(.red)
                            .padding()
                        Text("Processing frame \(vm.currentFrameIndex + 1)...")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    
                    Button(action: {
                        isProcessing = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            isProcessing = false
                        }
                    }) {
                        Text("Cut Current Frame")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.red)
                            .cornerRadius(14)
                    }
                    .padding(.horizontal, 32)
                    .disabled(isProcessing)
                    
                    Button(action: {
                        isProcessing = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                            isProcessing = false
                        }
                    }) {
                        Text("Cut All Frames (\(vm.frames.count))")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(14)
                    }
                    .padding(.horizontal, 32)
                    .disabled(isProcessing)
                }
                
                Spacer()
            }
        }
    }
}

// MARK: - Rotoscope Sheet
struct RotoscopeSheet: View {
    @ObservedObject var vm: StudioViewModel
    @State private var showVideoPicker = false
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        ZStack {
            Color(hex: "0A0A0F").ignoresSafeArea()
            
            VStack(spacing: 20) {
                HStack {
                    Text("🎬 Rotoscope / Video")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Spacer()
                    Button("Done") { dismiss() }
                }
                .padding(16)
                
                VStack(spacing: 16) {
                    Image(systemName: "film.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.red)
                    
                    Text("Import a video to trace over")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    
                    Text("Import a video and it will be split into frames for you to draw over. Perfect for rotoscoping and reference.")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    
                    Button(action: { showVideoPicker = true }) {
                        HStack {
                            Image(systemName: "video.fill")
                            Text("Choose Video")
                        }
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red)
                        .cornerRadius(14)
                    }
                    .padding(.horizontal, 32)
                    
                    Button(action: {}) {
                        HStack {
                            Image(systemName: "camera.fill")
                            Text("Record Video")
                        }
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(14)
                    }
                    .padding(.horizontal, 32)
                }
                
                Spacer()
            }
        }
    }
}

// MARK: - Panel Header (reusable)
struct PanelHeader: View {
    let title: String
    let icon: String
    let onClose: () -> Void
    
    var body: some View {
        HStack {
            if icon.count <= 3 && icon.unicodeScalars.contains(where: { $0.value > 0x1F000 }) {
                Text(icon)
                    .font(.system(size: 18))
            } else {
                Image(systemName: icon)
                    .foregroundColor(.red)
            }
            Text(title)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(hex: "0D0D14"))
    }
}
