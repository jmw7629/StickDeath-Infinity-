import SwiftUI

// ═══════════════════════════════════════════════════════════════════════
// Project Settings / Tools Menu — Matches the ⋯ menu in the video
// ═══════════════════════════════════════════════════════════════════════

struct ProjectSettingsPanel: View {
    @ObservedObject var vm: StudioViewModel
    @State private var onionEnabled: Bool = false
    @State private var gridEnabled: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.2))
                .frame(width: 36, height: 4)
                .padding(.top, 8)
            
            // Header
            HStack {
                Text("⋯")
                    .font(.system(size: 20))
                Text("Project Menu")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                Spacer()
                Button(action: { vm.activePanel = .none }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 12)
            
            // Project Settings row
            SettingsRow(icon: "⚙️", label: "Project Settings") {
                // Navigate to project settings detail
            }
            
            Divider().background(Color.white.opacity(0.05)).padding(.horizontal, 14)
            
            // TOOLS section
            Text("TOOLS")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.3))
                .tracking(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 4)
            
            SettingsRow(icon: "🎞", label: "Frames Viewer") {
                vm.activePanel = .framesViewer
            }
            
            // Onion Skin (toggle + Edit)
            HStack(spacing: 10) {
                Text("🧅")
                    .font(.system(size: 16))
                Text("Onion")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
                Spacer()
                
                Button(action: {}) {
                    Text("Edit")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(0.05))
                        )
                }
                
                Toggle("", isOn: $onionEnabled)
                    .toggleStyle(SwitchToggleStyle(tint: Color(hex: "#DC2626")))
                    .labelsHidden()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            
            // Grid (toggle + Edit)
            HStack(spacing: 10) {
                Text("⊞")
                    .font(.system(size: 16))
                Text("Grid")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
                Spacer()
                
                Button(action: {}) {
                    Text("Edit")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(0.05))
                        )
                }
                
                Toggle("", isOn: $gridEnabled)
                    .toggleStyle(SwitchToggleStyle(tint: Color(hex: "#DC2626")))
                    .labelsHidden()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            
            SettingsRow(icon: "✨", label: "Magic Cut") {}
            SettingsRow(icon: "🖼", label: "Background Library") {}
            SettingsRow(icon: "🎬", label: "Rotoscope / Video") {}
            
            SettingsRow(icon: "📸", label: "Add Picture") {
                vm.activePanel = .addImage
            }
            
            SettingsRow(icon: "😀", label: "Stickers & Emoji") {
                vm.activePanel = .stickerEmoji
            }
            
            SettingsRow(icon: "📤", label: "Export") {
                vm.activePanel = .export
            }
            
            Spacer().frame(height: 20)
        }
        .background(Color(hex: "#1a1a24"))
        .cornerRadius(16, corners: [.topLeft, .topRight])
    }
}

// MARK: - Settings Row
struct SettingsRow: View {
    let icon: String
    let label: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(icon)
                    .font(.system(size: 16))
                Text(label)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.2))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Frames Viewer Panel
// ═══════════════════════════════════════════════════════════════════════

struct FramesViewerPanel: View {
    @ObservedObject var vm: StudioViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.2))
                .frame(width: 36, height: 4)
                .padding(.top, 8)
            
            HStack {
                Text("🎞")
                    .font(.system(size: 16))
                Text("Frames Viewer")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                
                Text("\(vm.frames.count) frames")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
                
                Spacer()
                
                Button(action: { vm.activePanel = .none }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 12)
            
            // Frame grid
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(Array(vm.frames.enumerated()), id: \.element.id) { index, frame in
                    Button(action: { vm.currentFrameIndex = index }) {
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white)
                                .frame(height: 60)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(
                                            index == vm.currentFrameIndex ? Color(hex: "#DC2626") : Color.white.opacity(0.15),
                                            lineWidth: index == vm.currentFrameIndex ? 2 : 1
                                        )
                                )
                            
                            Text("\(index + 1)")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(index == vm.currentFrameIndex ? Color(hex: "#DC2626") : .white.opacity(0.4))
                        }
                    }
                }
                
                // Add frame button
                Button(action: { vm.addFrame() }) {
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
                            .foregroundColor(.white.opacity(0.15))
                            .frame(height: 60)
                            .overlay(
                                Image(systemName: "plus")
                                    .font(.system(size: 16))
                                    .foregroundColor(.white.opacity(0.2))
                            )
                        
                        Text("Add Frame")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.3))
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 20)
        }
        .background(Color(hex: "#1a1a24"))
        .cornerRadius(16, corners: [.topLeft, .topRight])
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Add Image Panel
// ═══════════════════════════════════════════════════════════════════════

struct AddImagePanel: View {
    @ObservedObject var vm: StudioViewModel
    @State private var tab: String = "upload"
    @State private var urlText: String = ""
    
    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.2))
                .frame(width: 36, height: 4)
                .padding(.top, 8)
            
            PanelHeader(title: "Add Picture", icon: "📸", onClose: { vm.activePanel = .none })
            
            // Tab bar
            HStack(spacing: 4) {
                TabButton(label: "Upload", isActive: tab == "upload") { tab = "upload" }
                TabButton(label: "URL", isActive: tab == "url") { tab = "url" }
                TabButton(label: "Library", isActive: tab == "library") { tab = "library" }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            
            if tab == "upload" {
                VStack(spacing: 12) {
                    // Camera icon
                    Image(systemName: "camera")
                        .font(.system(size: 32))
                        .foregroundColor(.white.opacity(0.2))
                        .frame(width: 64, height: 64)
                        .background(
                            Circle()
                                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                                .foregroundColor(.white.opacity(0.15))
                        )
                    
                    Text("Upload an Image")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    
                    Text("From your phone camera, photo library, or any file on your device")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.35))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                    
                    Button(action: {
                        // Open photo picker
                    }) {
                        HStack {
                            Text("📁")
                            Text("Choose from Device")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(hex: "#DC2626"))
                        )
                    }
                    .padding(.horizontal, 20)
                    
                    Button(action: {
                        // Open camera
                    }) {
                        HStack {
                            Text("📷")
                            Text("Take Photo")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                    }
                    .padding(.horizontal, 20)
                    
                    Text("Upload any image · JPG, PNG, GIF, WebP supported")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.white.opacity(0.25))
                        .padding(.bottom, 16)
                }
            } else if tab == "url" {
                VStack(spacing: 12) {
                    TextField("Paste image URL...", text: $urlText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(hex: "#12121a"))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08)))
                        )
                        .padding(.horizontal, 20)
                    
                    Button(action: {
                        // Load image from URL
                    }) {
                        Text("Load Image")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color(hex: "#DC2626"))
                            )
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            } else {
                // Library tab
                Text("Image Library")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(height: 100)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 20)
            }
        }
        .background(Color(hex: "#1a1a24"))
        .cornerRadius(16, corners: [.topLeft, .topRight])
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Panel Header (reusable)
// ═══════════════════════════════════════════════════════════════════════

struct PanelHeader: View {
    let title: String
    let icon: String
    let onClose: () -> Void
    
    var body: some View {
        HStack {
            Text(icon)
                .font(.system(size: 16))
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
}
