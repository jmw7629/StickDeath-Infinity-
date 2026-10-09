import SwiftUI
import UniformTypeIdentifiers

// ═══════════════════════════════════════════════════════════════════
// Layer Panel — Bottom sheet with drag handle
// Matches video frame-by-frame:
// ┌─────────────────────────────────────────────────┐
// │                  ─── drag handle ───             │
// │ ⋮⋮ 🚫 [thumb] Layer 1 (red)  🔒 100% ▼        │
// │ Opacity ████████████████████████████ 100%        │
// │ LOCK MODE                                        │
// │ [🔓 Free] [🔒 Full] [📌 Pos] [🎨 Alpha]        │
// │ BLEND MODE                                       │
// │ [ Normal                              ▼ ]        │
// │ GLOW  ○                                          │
// │ Color: ● ● ● ● ● ● ● ●                         │
// │ [📝 Editable] [📋 Duplicate] [⬆] [⬇]           │
// │                   + (red)                        │
// └─────────────────────────────────────────────────┘
// ═══════════════════════════════════════════════════════════════════

struct LayerPanel: View {
    @ObservedObject var vm: StudioViewModel
    @State private var expandedLayer: String? = nil
    @State private var drag: StudioLayerDrag?
    @State private var hoveredLayer: String?
    @State private var hoverAfter = false
    @EnvironmentObject private var authVM: AuthViewModel
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some View {
        VStack(spacing: 0) {
            // Tap to dismiss area
            Color.black.opacity(0.3)
                .onTapGesture { vm.activePanel = .none }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Close layers")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("studio.layers.close")
            
            // Panel
            VStack(spacing: 0) {
                // Drag handle
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.25))
                    .frame(width: 40, height: 4)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(vm.studioLayers) { layer in
                            LayerRow(vm: vm, layer: layer, isExpanded: expandedLayer == layer.id)
                                .overlay(alignment: hoverAfter ? .bottom : .top) {
                                    if hoveredLayer == layer.id { Rectangle().fill(Color.red).frame(height: 2) }
                                }
                                .onDrag {
                                    guard let capture = vm.prepareLayerReorder(layer.id), scenePhase == .active else {
                                        return NSItemProvider()
                                    }
                                    let item = StudioLayerDrag(capture: capture, accountID: authVM.userId)
                                    drag = item
                                    let provider = NSItemProvider()
                                    let payload = Data(item.token.uuidString.utf8)
                                    provider.registerDataRepresentation(forTypeIdentifier: StudioLayerDrag.contentType.identifier,
                                        visibility: .ownProcess) { completion in completion(payload, nil); return nil }
                                    provider.suggestedName = layer.name
                                    return provider
                                }
                                .onDrop(of: [StudioLayerDrag.contentType], delegate: StudioLayerDropDelegate(
                                    vm: vm, targetID: layer.id, drag: $drag, hoveredLayer: $hoveredLayer,
                                    hoverAfter: $hoverAfter, account: { authVM.userId }, isActive: { scenePhase == .active }))
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        vm.selectLayer(layer.id)
                                        expandedLayer = expandedLayer == layer.id ? nil : layer.id
                                    }
                                }
                            
                            if expandedLayer == layer.id {
                                LayerDetailView(vm: vm, layer: layer)
                                    .id(layer.id)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                            
                            Divider().background(Color.white.opacity(0.06))
                        }
                        
                        // Add layer button
                        Button(action: { vm.addLayer() }) {
                            Text("+")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(.red)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .accessibilityIdentifier("studio.add-layer")
                    }
                }
                .frame(maxHeight: 400)
                .accessibilityIdentifier("studio.layers.list")
            }
            .background(Color(hex: "1A1A24").opacity(0.98))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
            )
            .clipShape(RoundedCorner(radius: 16, corners: [.topLeft, .topRight]))
        }
        .ignoresSafeArea()
        .onChange(of: vm.document.id) { _ in clearDrag() }
        .onChange(of: vm.document.revision) { _ in clearDrag() }
        .onChange(of: vm.document.activeFrameID) { _ in clearDrag() }
        .onChange(of: authVM.userId) { _ in clearDrag() }
        .onChange(of: scenePhase) { if $0 != .active { clearDrag() } }
        .onDisappear { clearDrag() }
    }
    private func clearDrag() { drag = nil; hoveredLayer = nil; hoverAfter = false }
}

private struct StudioLayerDrag {
    static let contentType = UTType(exportedAs: "com.willisnmb.stickdeathinfinity.layer-reorder", conformingTo: .data)
    let token = UUID()
    let capture: StudioViewModel.LayerReorderCapture
    let accountID: String?
}

private struct StudioLayerDropDelegate: DropDelegate {
    let vm: StudioViewModel
    let targetID: String
    @Binding var drag: StudioLayerDrag?
    @Binding var hoveredLayer: String?
    @Binding var hoverAfter: Bool
    let account: () -> String?
    let isActive: () -> Bool
    func validateDrop(info: DropInfo) -> Bool {
        guard let drag, isActive(), account() == drag.accountID else { return false }
        return info.hasItemsConforming(to: [StudioLayerDrag.contentType])
            && vm.prepareLayerReorder(drag.capture.layerID) == drag.capture
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .cancel) }
        hoveredLayer = targetID; hoverAfter = info.location.y >= 26
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { if hoveredLayer == targetID { hoveredLayer = nil } }
    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info), let expected = drag else { return false }
        let providers = info.itemProviders(for: [StudioLayerDrag.contentType])
        guard providers.count == 1, let provider = providers.first else { return false }
        let after = info.location.y >= 26
        hoveredLayer = nil
        provider.loadDataRepresentation(forTypeIdentifier: StudioLayerDrag.contentType.identifier) { data, error in
            Task { @MainActor in
                guard drag?.token == expected.token else { return }
                defer { drag = nil; hoveredLayer = nil }
                guard error == nil, data == Data(expected.token.uuidString.utf8),
                      isActive(), account() == expected.accountID else { return }
                do { _ = try vm.reorderLayer(expected.capture, relativeTo: targetID, after: after) }
                catch { vm.message = error.localizedDescription }
            }
        }
        return true
    }
}

// MARK: - Layer Row (collapsed)
struct LayerRow: View {
    @ObservedObject var vm: StudioViewModel
    let layer: CanvasLayer
    let isExpanded: Bool
    
    var body: some View {
        HStack(spacing: 8) {
            // Drag dots (2×3 grid)
            VStack(spacing: 2) {
                ForEach(0..<3) { _ in
                    HStack(spacing: 2) {
                        Circle().fill(Color.white.opacity(0.2)).frame(width: 2.5, height: 2.5)
                        Circle().fill(Color.white.opacity(0.2)).frame(width: 2.5, height: 2.5)
                    }
                }
            }
            .frame(width: 12)
            
            // Visibility toggle (🚫 when hidden)
            Button(action: { vm.toggleLayerVisibility(layer.id) }) {
                Image(systemName: layer.visible ? "eye.fill" : "eye.slash.fill")
                    .font(.system(size: 14))
                    .foregroundColor(layer.visible ? .white.opacity(0.5) : .red.opacity(0.6))
            }
            .frame(width: 24)
            
            // Thumbnail
            StudioFrameThumbnail(vm: vm, frame: vm.currentFrame, isolatedLayerID: layer.id)
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )
            
            // Layer name (red text)
            Text(layer.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.specialElite(14))
                .foregroundColor(Color(hex: "DC2626"))
            
            Spacer()
            
            // Lock icon
            Image(systemName: lockIcon(for: layer.lockMode))
                .font(.system(size: 12))
                .foregroundColor(layer.lockMode == "full" ? Color.yellow : .white.opacity(0.4))
            
            // Opacity percentage
            Text("\(Int(layer.opacity * 100))%")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
            
            // Chevron
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.3))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(vm.activeLayerID == layer.id ? Color.red.opacity(0.1) : Color.clear)
        .contentShape(Rectangle())
    }
    
    func lockIcon(for mode: String) -> String {
        switch mode {
        case "free": return "lock.open"
        case "full": return "lock.fill"
        case "position": return "pin.fill"
        default: return "paintpalette.fill"
        }
    }
}

// MARK: - Layer Detail View (expanded)
struct LayerDetailView: View {
    @ObservedObject var vm: StudioViewModel
    let layer: CanvasLayer
    @State private var draftOpacity: Double?
    @State private var sliderCapture: StudioViewModel.LayerSliderCapture?
    @Environment(\.scenePhase) private var sliderScenePhase
    @State private var draftGlowRadius: Double?
    @State private var draftGlowStrength: Double?
    @State private var pendingDeletion: StudioViewModel.LayerDeleteCapture?
    @State private var pendingRename: StudioViewModel.LayerRenameCapture?
    @State private var proposedName = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                guard let capture = vm.prepareLayerRename(layer.id) else { return }
                proposedName = capture.originalName
                pendingRename = capture
            } label: {
                Label("Rename layer", systemImage: "pencil")
                    .font(.specialElite(12))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityIdentifier("studio.layer.rename." + layer.id)
            .disabled(!vm.canRenameLayer(layer.id))
            // Opacity slider (RED bar)
            HStack {
                Text("Opacity")
                    .font(.specialElite(11))
                    .foregroundColor(.white.opacity(0.4))
                
                Slider(value: Binding(get: { draftOpacity ?? layer.opacity }, set: { draftOpacity = $0 }), in: 0...1) { editing in
                    if editing { sliderCapture = vm.prepareLayerSlider(layer.id) }
                    else {
                        if sliderScenePhase == .active, let capture = sliderCapture, let value = draftOpacity {
                            _ = vm.applyLayerSlider(capture, opacity: value)
                        }
                        clearSliderDrafts()
                    }
                }.tint(.red)
                
                Text("\(Int((draftOpacity ?? layer.opacity) * 100))%")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
            }
            
            // LOCK MODE
            VStack(alignment: .leading, spacing: 6) {
                Text("LOCK MODE")
                    .font(.specialElite(9))
                    .foregroundColor(.white.opacity(0.3))
                    .tracking(2)
                
                HStack(spacing: 6) {
                    LockModeButton(emoji: "🔓", label: "Free", isSelected: layer.lockMode == "free", selectedColor: .clear) {
                        vm.setLayerLockMode(layer.id, mode: .free)
                    }
                    LockModeButton(emoji: "🔒", label: "Full", isSelected: layer.lockMode == "full", selectedColor: .yellow) {
                        vm.setLayerLockMode(layer.id, mode: .full)
                    }
                    LockModeButton(emoji: "📌", label: "Pos", isSelected: layer.lockMode == "position", selectedColor: .red) {
                        vm.setLayerLockMode(layer.id, mode: .position)
                    }
                    LockModeButton(emoji: "🎨", label: "Alpha", isSelected: layer.lockMode == "alpha", selectedColor: .orange) {
                        vm.setLayerLockMode(layer.id, mode: .alpha)
                    }
                }
            }
            
            // BLEND MODE
            VStack(alignment: .leading, spacing: 6) {
                Text("BLEND MODE")
                    .font(.specialElite(9))
                    .foregroundColor(.white.opacity(0.3))
                    .tracking(2)
                
                Menu {
                    ForEach(["normal", "multiply", "screen", "overlay", "darken", "lighten"], id: \.self) { mode in
                        Button(mode.capitalized) { vm.setLayerBlend(layer.id, mode: mode) }
                    }
                } label: {
                    HStack {
                        Text(layer.blendMode.capitalized)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                    }.font(.specialElite(12)).foregroundColor(.white)
                        .padding(12).background(Color.white.opacity(0.05)).cornerRadius(8)
                }.accessibilityIdentifier("studio.layer.blend." + layer.id)
            }
            
            // GLOW toggle
            HStack {
                Text("GLOW")
                    .font(.specialElite(9))
                    .foregroundColor(.white.opacity(0.3))
                    .tracking(2)
                
                Toggle("Glow", isOn: Binding(get: { layer.glowEnabled }, set: { vm.setLayerGlow(layer.id, enabled: $0) }))
                    .accessibilityIdentifier("studio.layer.glow." + layer.id)
                    .labelsHidden()
                    .scaleEffect(0.8)
                
                Spacer()
            }
            
            if layer.glowEnabled {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Glow color").font(.custom("SpecialElite-Regular", size: 12, relativeTo: .caption))
                    HStack(spacing: 8) {
                        ForEach(["#FF0000", "#FF8800", "#FFFF00", "#00FF00", "#0088FF", "#AA44FF", "#FFFFFF"], id: \.self) { hex in
                            Button {
                                vm.setLayerGlowStyle(layer.id, color: hex)
                            } label: {
                                Circle().fill(Color(hex: hex)).frame(width: 24, height: 24)
                                    .overlay(Circle().stroke(.white, lineWidth: (layer.glowColor ?? "#FF0000").uppercased() == hex ? 3 : 0))
                            }.frame(minWidth: 32, minHeight: 44).accessibilityLabel("Glow color " + hex)
                                .accessibilityIdentifier("studio.layer.glow-color." + hex)
                        }
                    }
                    Text("Strength \(Int((draftGlowStrength ?? layer.effectiveGlowStrength) * 100))%")
                    Slider(value: Binding(get: { draftGlowStrength ?? layer.effectiveGlowStrength }, set: { draftGlowStrength = $0 }), in: 0...1) { editing in
                        if editing { sliderCapture = vm.prepareLayerSlider(layer.id) }
                        else {
                            if sliderScenePhase == .active, let capture = sliderCapture, let value = draftGlowStrength {
                                _ = vm.applyLayerSlider(capture, glowStrength: value)
                            }
                            clearSliderDrafts()
                        }
                    }.accessibilityLabel("Glow strength").accessibilityIdentifier("studio.layer.glow-strength." + layer.id)
                    Text("Radius \(Int(draftGlowRadius ?? layer.effectiveGlowRadius)) canvas points")
                    Slider(value: Binding(get: { draftGlowRadius ?? layer.effectiveGlowRadius }, set: { draftGlowRadius = $0 }), in: 0...128, step: 1) { editing in
                        if editing { sliderCapture = vm.prepareLayerSlider(layer.id) }
                        else {
                            if sliderScenePhase == .active, let capture = sliderCapture, let value = draftGlowRadius {
                                _ = vm.applyLayerSlider(capture, glowRadius: value)
                            }
                            clearSliderDrafts()
                        }
                    }.accessibilityLabel("Glow radius").accessibilityIdentifier("studio.layer.glow-radius." + layer.id)
                }.font(.custom("SpecialElite-Regular", size: 12, relativeTo: .caption)).foregroundColor(.white.opacity(0.8)).tint(.red)
            }

            // Layer label color (independent of rendered glow).
            HStack(spacing: 6) {
                Text("Label:")
                    .font(.specialElite(11))
                    .foregroundColor(.white.opacity(0.4))
                
                ForEach([
                    Color.red, Color.orange, Color.yellow, Color.green,
                    Color(hex: "38BDF8"), Color.purple, Color.pink, Color.gray
                ], id: \.self) { color in
                    Circle()
                        .fill(color)
                        .frame(width: 20, height: 20)
                        .overlay(
                            Circle()
                                .stroke(Color(hex: layer.colorLabel ?? "#FF0000") == color ? Color.white : Color.white.opacity(0.1), lineWidth: Color(hex: layer.colorLabel ?? "#FF0000") == color ? 2 : 0.5)
                        )
                        .onTapGesture {
                            vm.setLayerColor(layer.id, color: color)
                        }
                }
            }
            
            // Action buttons
            HStack(spacing: 6) {
                LayerActionButton(emoji: "📝", label: "Select") { vm.selectLayer(layer.id); vm.activePanel = .none }
                LayerActionButton(emoji: "📋", label: "Duplicate") {
                    vm.duplicateLayer(layer.id)
                }
                
                // Move up
                Button(action: { vm.moveLayerUp(layer.id) }) {
                    Image(systemName: "arrow.up.square.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: 44, height: 36)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
                }
                
                // Move down
                Button(action: { vm.moveLayerDown(layer.id) }) {
                    Image(systemName: "arrow.down.square.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: 44, height: 36)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
                }
            }
            Button(role: .destructive) { pendingDeletion = vm.prepareLayerDeletion(layer.id) } label: {
                Label("Delete selected layer", systemImage: "trash")
                    .font(.specialElite(12))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityIdentifier("studio.layer.delete." + layer.id)
            .disabled(!vm.canDeleteLayer(layer.id))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(hex: "14141E"))
        .onChange(of: vm.document.id) { _, _ in clearSliderDrafts() }
        .onChange(of: vm.document.revision) { _, _ in clearSliderDrafts() }
        .onChange(of: sliderScenePhase) { _, phase in if phase != .active { clearSliderDrafts() } }
        .onDisappear { clearSliderDrafts() }
        .alert("Rename layer", isPresented: Binding(
            get: { pendingRename != nil }, set: { if !$0 { pendingRename = nil } }),
            presenting: pendingRename) { capture in
                TextField("Layer name", text: $proposedName)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("studio.layer.rename.input")
                Button("Save name") { _ = vm.renameLayer(capture, to: proposedName); pendingRename = nil }
                    .disabled(StudioViewModel.normalizedLayerName(proposedName) == nil)
                Button("Cancel", role: .cancel) { pendingRename = nil }
            } message: { _ in
                Text("Use 1–120 characters. Renaming changes the label only; artwork and layer order stay intact.")
            }
        .confirmationDialog("Delete selected layer?", isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible, presenting: pendingDeletion) { capture in
                Button("Delete layer", role: .destructive) { _ = vm.deleteLayer(capture); pendingDeletion = nil }
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            } message: { capture in
                Text("Delete \"\(capture.name)\" and its content in \(capture.frameCount) frame(s)? You can undo this edit.")
            }
    }
    private func clearSliderDrafts() {
        sliderCapture = nil; draftOpacity = nil; draftGlowRadius = nil; draftGlowStrength = nil
    }

}

// MARK: - Lock Mode Button
struct LockModeButton: View {
    let emoji: String
    let label: String
    let isSelected: Bool
    let selectedColor: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(emoji)
                    .font(.system(size: 16))
                Text(label)
                    .font(.specialElite(9))
                    .foregroundColor(isSelected ? selectedColor == .clear ? .white : selectedColor : .white.opacity(0.5))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? (selectedColor == .clear ? Color.white.opacity(0.1) : selectedColor.opacity(0.15)) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? (selectedColor == .clear ? Color.white.opacity(0.2) : selectedColor.opacity(0.4)) : Color.white.opacity(0.08), lineWidth: 1)
            )
        }
    }
}

// MARK: - Layer Action Button
struct LayerActionButton: View {
    let emoji: String
    let label: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(emoji).font(.system(size: 12))
                Text(label)
                    .font(.specialElite(10))
                    .foregroundColor(.white.opacity(0.6))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.05))
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
        }
    }
}

// Rounded corner helper
