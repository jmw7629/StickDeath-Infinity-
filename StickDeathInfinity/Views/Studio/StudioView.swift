import SwiftUI
import PencilKit

// MARK: - Studio View
struct StudioView: View {
    @StateObject private var studioState = StudioState()
    @State private var showMenu = false
    @State private var showLayers = false
    @State private var showExport = false
    @State private var showProjectSettings = false
    
    var body: some View {
        ZStack {
            Color(hex: "0D0D12").ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                StudioHeader(state: studioState, onMenu: { showMenu = true }, onExport: { showExport = true })
                
                // Tool Strip
                ToolStrip(state: studioState)
                
                // Canvas
                StudioCanvas(state: studioState)
                
                // Zoom Controls overlay
                // Frame Timeline
                FrameTimeline(state: studioState)
                
                // Bottom Toolbar
                BottomToolbar(state: studioState, onLayers: { showLayers = true })
            }
        }
        .sheet(isPresented: $showMenu) {
            StudioMenuSheet(state: studioState)
        }
        .sheet(isPresented: $showLayers) {
            LayerSheet(state: studioState)
        }
        .sheet(isPresented: $showExport) {
            ExportSheet(state: studioState)
        }
    }
}

// MARK: - Studio State
class StudioState: ObservableObject {
    @Published var projectName = "Untitled Animation"
    @Published var fps = 12
    @Published var canvasWidth = 1920
    @Published var canvasHeight = 1080
    @Published var selectedTool: StudioTool = .pencil
    @Published var currentColor = Color.red
    @Published var brushSize: CGFloat = 8
    @Published var brushOpacity: Double = 1.0
    @Published var smoothing: Double = 0.5
    @Published var pressureSensitivity = true
    @Published var frames: [AnimationFrame] = [AnimationFrame(id: "f1", index: 0)]
    @Published var currentFrameIndex = 0
    @Published var layers: [AnimationLayer] = [AnimationLayer(id: "l1", name: "Layer 1")]
    @Published var currentLayerIndex = 0
    @Published var onionSkinEnabled = false
    @Published var gridEnabled = true
    @Published var isPlaying = false
    @Published var showToolSettings = false
    @Published var lastSaved = Date()
    
    var currentFrame: AnimationFrame {
        guard currentFrameIndex < frames.count else { return frames[0] }
        return frames[currentFrameIndex]
    }
    
    func addFrame() {
        let frame = AnimationFrame(id: "f\(Date().timeIntervalSince1970)", index: frames.count)
        frames.append(frame)
        currentFrameIndex = frames.count - 1
    }
    
    func addLayer() {
        let layer = AnimationLayer(id: "l\(Date().timeIntervalSince1970)", name: "Layer \(layers.count + 1)")
        layers.append(layer)
        currentLayerIndex = layers.count - 1
    }
    
    func saveProject() {
        lastSaved = Date()
        // Device storage via DeviceStorageManager
        DeviceStorageManager.shared.saveProject(state: self)
    }
}

enum StudioTool: String, CaseIterable {
    case move, lasso, pencil, pen, brush, marker, crayon, line, rect, circle, fill, picker, eraser, smudge, text, hand, zoom
    
    var icon: String {
        switch self {
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
        case .lasso: return "lasso"
        case .pencil: return "pencil"
        case .pen: return "pencil.tip"
        case .brush: return "paintbrush"
        case .marker: return "highlighter"
        case .crayon: return "pencil.and.outline"
        case .line: return "line.diagonal"
        case .rect: return "rectangle"
        case .circle: return "circle"
        case .fill: return "drop.fill"
        case .picker: return "eyedropper"
        case .eraser: return "eraser"
        case .smudge: return "hand.point.up.left"
        case .text: return "textformat"
        case .hand: return "hand.raised"
        case .zoom: return "magnifyingglass"
        }
    }
    
    var selectionColor: Color {
        switch self {
        case .pencil, .pen, .brush, .marker, .line, .rect, .circle, .fill, .picker, .eraser, .text:
            return Color(hex: "DC2626") // Red
        case .crayon:
            return Color(hex: "F59E0B") // Amber/Golden
        case .smudge:
            return Color(hex: "A78BFA") // Purple
        default:
            return Color(hex: "DC2626")
        }
    }
    
    var hasSettings: Bool {
        switch self {
        case .pencil, .pen, .brush, .marker, .eraser, .smudge, .text, .fill, .crayon:
            return true
        default:
            return false
        }
    }
}

// MARK: - Header
struct StudioHeader: View {
    @ObservedObject var state: StudioState
    let onMenu: () -> Void
    let onExport: () -> Void
    
    var body: some View {
        HStack(spacing: 8) {
            // Back button
            Button(action: {}) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white.opacity(0.6))
            }
            
            // Title
            VStack(alignment: .leading, spacing: 1) {
                Text(state.projectName)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                Text("\(state.fps) FPS · \(state.frames.count) frames · \(state.layers.count) layers")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.4))
            }
            
            Spacer()
            
            // Hide button
            Button(action: {}) {
                VStack(spacing: 1) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 12))
                    Text("HIDE")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                }
                .foregroundColor(.white.opacity(0.5))
            }
            
            // Save indicator
            HStack(spacing: 4) {
                Image(systemName: "doc.on.doc.fill")
                    .font(.system(size: 10))
                Text(timeAgoString(from: state.lastSaved))
                    .font(.system(size: 9))
            }
            .foregroundColor(.white.opacity(0.4))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(hex: "1A1A24"))
            .cornerRadius(6)
            
            // Export
            Button(action: onExport) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.red)
            }
            
            // Menu
            Button(action: onMenu) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
    
    func timeAgoString(from date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s ago" }
        return "\(seconds / 60)m ago"
    }
}

// MARK: - Tool Strip
struct ToolStrip: View {
    @ObservedObject var state: StudioState
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                // Drag handle
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.3))
                    .padding(.horizontal, 4)
                
                // Color square
                RoundedRectangle(cornerRadius: 8)
                    .fill(state.currentColor)
                    .frame(width: 44, height: 44)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
                
                // Tools
                ForEach(StudioTool.allCases, id: \.self) { tool in
                    ToolButton(tool: tool, isSelected: state.selectedTool == tool) {
                        if state.selectedTool == tool && tool.hasSettings {
                            state.showToolSettings.toggle()
                        } else {
                            state.selectedTool = tool
                            state.showToolSettings = false
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(Color(hex: "12121A"))
    }
}

struct ToolButton: View {
    let tool: StudioTool
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: tool.icon)
                    .font(.system(size: 16))
                Text(tool.rawValue.capitalized)
                    .font(.system(size: 7, weight: isSelected ? .bold : .regular, design: .monospaced))
            }
            .foregroundColor(isSelected ? .white : .white.opacity(0.5))
            .frame(width: 52, height: 52)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? tool.selectionColor.opacity(0.8) : Color(hex: "1E1E2A"))
            )
        }
    }
}

// MARK: - Canvas
struct StudioCanvas: View {
    @ObservedObject var state: StudioState
    @State private var strokes: [[CGPoint]] = []
    @State private var currentStroke: [CGPoint] = []
    
    var body: some View {
        ZStack {
            // Background
            Color(hex: "0D0D12")
            
            // Canvas area with grid
            GeometryReader { geo in
                let canvasRect = CGRect(x: 20, y: 20, width: geo.size.width - 40, height: geo.size.height - 40)
                
                ZStack {
                    // White canvas
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: canvasRect.width, height: canvasRect.height)
                    
                    // Grid dots
                    if state.gridEnabled {
                        Canvas { context, size in
                            let spacing: CGFloat = 20
                            for x in stride(from: CGFloat(0), to: size.width, by: spacing) {
                                for y in stride(from: CGFloat(0), to: size.height, by: spacing) {
                                    context.fill(
                                        Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)),
                                        with: .color(.gray.opacity(0.2))
                                    )
                                }
                            }
                        }
                        .frame(width: canvasRect.width, height: canvasRect.height)
                    }
                    
                    // Drawn strokes
                    Canvas { context, size in
                        for stroke in strokes {
                            var path = Path()
                            guard let first = stroke.first else { continue }
                            path.move(to: first)
                            for point in stroke.dropFirst() {
                                path.addLine(to: point)
                            }
                            context.stroke(path, with: .color(.black), lineWidth: state.brushSize)
                        }
                        
                        // Current stroke
                        if !currentStroke.isEmpty {
                            var path = Path()
                            path.move(to: currentStroke[0])
                            for point in currentStroke.dropFirst() {
                                path.addLine(to: point)
                            }
                            context.stroke(path, with: .color(Color(state.currentColor)), lineWidth: state.brushSize)
                        }
                    }
                    .frame(width: canvasRect.width, height: canvasRect.height)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                currentStroke.append(value.location)
                            }
                            .onEnded { _ in
                                if !currentStroke.isEmpty {
                                    strokes.append(currentStroke)
                                    currentStroke = []
                                }
                            }
                    )
                }
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                
                // Zoom controls
                VStack(spacing: 8) {
                    Spacer()
                    ForEach(["+", "−", "FIT"], id: \.self) { label in
                        Button(action: {}) {
                            Text(label)
                                .font(.system(size: label == "FIT" ? 9 : 16, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                                .frame(width: 32, height: 32)
                                .background(Circle().fill(Color(hex: "1E1E2A")))
                                .overlay(Circle().stroke(Color.white.opacity(0.1), lineWidth: 1))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 8)
                .padding(.bottom, 8)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Frame Timeline
struct FrameTimeline: View {
    @ObservedObject var state: StudioState
    
    var body: some View {
        HStack(spacing: 6) {
            // Navigation
            Button(action: {
                if state.currentFrameIndex > 0 { state.currentFrameIndex -= 1 }
            }) {
                Text("‹")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white.opacity(0.5))
            }
            
            Button(action: { state.isPlaying.toggle() }) {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(Color(hex: "1E1E2A"))
                    .clipShape(Circle())
            }
            
            Button(action: {
                if state.currentFrameIndex < state.frames.count - 1 { state.currentFrameIndex += 1 }
            }) {
                Text("›")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white.opacity(0.5))
            }
            
            // Frame thumbnails
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(state.frames.indices, id: \.self) { index in
                        Button(action: { state.currentFrameIndex = index }) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(hex: "1E1E2A"))
                                    .frame(width: 36, height: 36)
                                
                                VStack(spacing: 1) {
                                    Text("\(index + 1)")
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    Text("\(index + 1)")
                                        .font(.system(size: 7))
                                }
                                .foregroundColor(state.currentFrameIndex == index ? .white : .white.opacity(0.4))
                            }
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(state.currentFrameIndex == index ? Color.red : Color.white.opacity(0.1), lineWidth: state.currentFrameIndex == index ? 2 : 1)
                            )
                        }
                    }
                }
            }
            
            // Add frame
            Button(action: { state.addFrame() }) {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(width: 32, height: 32)
                    .background(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))
            }
            
            // Onion skin toggle
            Button(action: { state.onionSkinEnabled.toggle() }) {
                Image(systemName: "circle.dashed")
                    .font(.system(size: 14))
                    .foregroundColor(state.onionSkinEnabled ? .red : .white.opacity(0.3))
            }
            
            Spacer()
            
            // Frame counter
            Text("\(state.currentFrameIndex + 1)/\(state.frames.count)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.4))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(hex: "0A0A10"))
    }
}

// MARK: - Bottom Toolbar
struct BottomToolbar: View {
    @ObservedObject var state: StudioState
    let onLayers: () -> Void
    
    let items: [(icon: String, label: String)] = [
        ("music.note", "AUDIO"),
        ("arrow.uturn.backward", "UNDO"),
        ("arrow.uturn.forward", "REDO"),
        ("doc.on.doc", "COPY"),
        ("doc.on.clipboard", "PASTE"),
        ("trash", "DEL"),
    ]
    
    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.label) { item in
                Button(action: {}) {
                    VStack(spacing: 2) {
                        Image(systemName: item.icon)
                            .font(.system(size: 14))
                        Text(item.label)
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                    }
                    .foregroundColor(.white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                }
            }
            
            // Layer button with badge
            Button(action: onLayers) {
                ZStack(alignment: .topTrailing) {
                    VStack(spacing: 2) {
                        Image(systemName: "square.3.layers.3d")
                            .font(.system(size: 14))
                        Text("LAYER")
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                    }
                    .foregroundColor(.white.opacity(0.5))
                    
                    if state.layers.count > 0 {
                        Text("\(state.layers.count)")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(.white)
                            .padding(2)
                            .background(Color.red)
                            .clipShape(Circle())
                            .offset(x: 8, y: -4)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 8)
        .background(Color(hex: "0A0A10"))
    }
}

// MARK: - Menu Sheet
struct StudioMenuSheet: View {
    @ObservedObject var state: StudioState
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
                
                // Project section
                Text("PROJECT")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                    .tracking(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 4)
                
                MenuRow(icon: "⚙️", label: "Project Settings") {}
                
                Divider().background(Color.white.opacity(0.06)).padding(.horizontal, 16)
                
                // Tools section
                Text("TOOLS")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                    .tracking(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                
                MenuRow(icon: "🎬", label: "Frames Viewer") {}
                MenuToggleRow(icon: "🧅", label: "Onion", isOn: $state.onionSkinEnabled)
                MenuToggleRow(icon: "📐", label: "Grid", isOn: $state.gridEnabled)
                MenuRow(icon: "✨", label: "Magic Cut") {}
                MenuRow(icon: "🖼️", label: "Background Library") {}
                MenuRow(icon: "🎬", label: "Rotoscope / Video") {}
                MenuRow(icon: "🖼️", label: "Add Picture") {}
                MenuRow(icon: "🗣️", label: "AI Voice Maker") {}
                MenuRow(icon: "🎨", label: "Spatter AI", accent: true) {}
                
                Spacer()
            }
        }
    }
}

struct MenuRow: View {
    let icon: String
    let label: String
    var accent: Bool = false
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(icon)
                    .font(.system(size: 18))
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

struct MenuToggleRow: View {
    let icon: String
    let label: String
    @Binding var isOn: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            Text(icon)
                .font(.system(size: 18))
            Text(label)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
            Spacer()
            Text("Edit")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.red)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(.red)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - Layer Sheet
struct LayerSheet: View {
    @ObservedObject var state: StudioState
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
                
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(state.layers.indices, id: \.self) { i in
                            LayerRow(layer: $state.layers[i], isSelected: state.currentLayerIndex == i) {
                                state.currentLayerIndex = i
                            }
                        }
                    }
                }
                
                // Add layer
                Button(action: { state.addLayer() }) {
                    Text("+")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            }
        }
    }
}

struct LayerRow: View {
    @Binding var layer: AnimationLayer
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    // Drag handle
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.3))
                    
                    // Visibility
                    Button(action: { layer.visible.toggle() }) {
                        Image(systemName: layer.visible ? "eye" : "eye.slash")
                            .font(.system(size: 12))
                            .foregroundColor(layer.visible ? .white.opacity(0.5) : .red)
                    }
                    
                    // Thumbnail
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(hex: "1E1E2A"))
                        .frame(width: 28, height: 28)
                    
                    // Name
                    Text(layer.name)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.red)
                    
                    Spacer()
                    
                    // Lock
                    Image(systemName: layer.locked ? "lock.fill" : "lock.open")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                    
                    // Opacity
                    Text("\(Int(layer.opacity))%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                    
                    // Expand
                    Image(systemName: layer.expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.3))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            
            if layer.expanded {
                LayerSettings(layer: $layer)
            }
            
            Divider().background(Color.white.opacity(0.04))
        }
    }
}

struct LayerSettings: View {
    @Binding var layer: AnimationLayer
    
    let lockModes = [("Free", "lock.open"), ("Full", "lock.fill"), ("Pos", "pin.fill"), ("Alpha", "paintpalette.fill")]
    let colorLabels: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .pink, .gray]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Opacity
            HStack {
                Text("Opacity")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
                Slider(value: $layer.opacity, in: 0...100)
                    .tint(.red)
                Text("\(Int(layer.opacity))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(width: 36, alignment: .trailing)
            }
            
            // Lock Mode
            Text("LOCK MODE")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.3))
                .tracking(2)
            
            HStack(spacing: 6) {
                ForEach(lockModes, id: \.0) { mode in
                    Button(action: {
                        layer.lockMode = mode.0
                        layer.locked = mode.0 != "Free"
                    }) {
                        VStack(spacing: 2) {
                            Image(systemName: mode.1)
                                .font(.system(size: 12))
                            Text(mode.0)
                                .font(.system(size: 8, weight: .medium, design: .monospaced))
                        }
                        .foregroundColor(layer.lockMode == mode.0 ? .red : .white.opacity(0.4))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(layer.lockMode == mode.0 ? Color.red.opacity(0.15) : Color(hex: "1E1E2A"))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(layer.lockMode == mode.0 ? Color.red.opacity(0.3) : Color.clear, lineWidth: 1)
                        )
                    }
                }
            }
            
            // Blend Mode
            Text("BLEND MODE")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.3))
                .tracking(2)
            
            Picker("Blend", selection: $layer.blendMode) {
                ForEach(["Normal", "Multiply", "Screen", "Overlay", "Darken", "Lighten", "Color Dodge", "Color Burn"], id: \.self) { mode in
                    Text(mode).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .tint(.white)
            .padding(.horizontal, 8)
            .background(Color(hex: "1E1E2A"))
            .cornerRadius(8)
            
            // Glow
            HStack {
                Text("GLOW")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                    .tracking(2)
                Toggle("", isOn: $layer.glowEnabled)
                    .labelsHidden()
                    .scaleEffect(0.7)
            }
            
            // Color labels
            HStack(spacing: 8) {
                Text("Color:")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.4))
                ForEach(colorLabels.indices, id: \.self) { i in
                    Circle()
                        .fill(colorLabels[i])
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle().stroke(Color.white, lineWidth: layer.colorLabelIndex == i ? 2 : 0)
                        )
                        .onTapGesture { layer.colorLabelIndex = i }
                }
            }
            
            // Actions
            HStack(spacing: 8) {
                Button(action: {}) {
                    Label("Editable", systemImage: "pencil")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(hex: "1E1E2A"))
                        .cornerRadius(6)
                }
                
                Button(action: {}) {
                    Label("Duplicate", systemImage: "doc.on.doc")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(hex: "1E1E2A"))
                        .cornerRadius(6)
                }
                
                Button(action: {}) {
                    Image(systemName: "arrow.up.square")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(6)
                        .background(Color(hex: "1E1E2A"))
                        .cornerRadius(6)
                }
                
                Button(action: {}) {
                    Image(systemName: "arrow.down.square")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(6)
                        .background(Color(hex: "1E1E2A"))
                        .cornerRadius(6)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(hex: "0A0A10").opacity(0.5))
    }
}

// MARK: - Export Sheet
struct ExportSheet: View {
    @ObservedObject var state: StudioState
    @State private var format = "mp4"
    @State private var isExporting = false
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            ZStack {
                Color(hex: "0A0A0F").ignoresSafeArea()
                
                VStack(spacing: 16) {
                    // Format selection
                    Text("FORMAT")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.3))
                        .tracking(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(["mp4", "gif", "png", "spritesheet"], id: \.self) { fmt in
                            Button(action: { format = fmt }) {
                                VStack(spacing: 4) {
                                    Text(fmt == "mp4" ? "🎬" : fmt == "gif" ? "🔄" : fmt == "png" ? "🖼️" : "📋")
                                        .font(.system(size: 24))
                                    Text(fmt.uppercased())
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                }
                                .foregroundColor(format == fmt ? .white : .white.opacity(0.4))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(format == fmt ? Color.red.opacity(0.15) : Color(hex: "1E1E2A"))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(format == fmt ? Color.red : Color.clear, lineWidth: 1)
                                )
                            }
                        }
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        isExporting = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            isExporting = false
                            dismiss()
                        }
                    }) {
                        if isExporting {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("Export \(format.uppercased())")
                                .font(.system(size: 16, weight: .bold, design: .monospaced))
                        }
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.red)
                    .cornerRadius(14)
                }
                .padding(20)
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Models
struct AnimationFrame: Identifiable {
    let id: String
    let index: Int
    var strokes: [[CGPoint]] = []
}

struct AnimationLayer: Identifiable {
    let id: String
    var name: String
    var visible = true
    var locked = false
    var expanded = false
    var opacity: Double = 100
    var lockMode = "Free"
    var blendMode = "Normal"
    var glowEnabled = false
    var colorLabelIndex = 0
}

// MARK: - Color Hex Extension
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

struct StudioView_Previews: PreviewProvider {
    static var previews: some View {
        StudioView()
    }
}
