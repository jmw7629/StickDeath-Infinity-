import SwiftUI

struct ExportPanel: View {
    @ObservedObject var vm: StudioViewModel
    @State private var shareTargets: [ShareTarget] = [
        ShareTarget(id: "camera", name: "Camera Roll", icon: "📱", isPro: false, isEnabled: true),
        ShareTarget(id: "tiktok", name: "TikTok", icon: "🎵", isPro: true, isEnabled: false),
        ShareTarget(id: "youtube", name: "YouTube", icon: "▶️", isPro: true, isEnabled: false),
        ShareTarget(id: "instagram", name: "Instagram", icon: "📷", isPro: true, isEnabled: false),
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.2))
                .frame(width: 36, height: 4)
                .padding(.top, 8)
            
            PanelHeader(title: "Export", icon: "📤", onClose: { vm.activePanel = .none })
            
            ScrollView {
                VStack(spacing: 16) {
                    // Format grid (2x2)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(ExportFormat.allCases, id: \.rawValue) { format in
                            ExportFormatCard(
                                format: format,
                                isSelected: vm.exportFormat == format,
                                onTap: { vm.exportFormat = format }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    
                    // Quality
                    VStack(alignment: .leading, spacing: 8) {
                        Text("QUALITY")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                            .tracking(1)
                        
                        HStack(spacing: 8) {
                            ForEach(ExportQuality.allCases, id: \.rawValue) { quality in
                                Button(action: { vm.exportQuality = quality }) {
                                    VStack(spacing: 2) {
                                        Text(quality.rawValue)
                                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                                        Text(quality.resolution)
                                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                                            .foregroundColor(.white.opacity(0.4))
                                    }
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(Color(hex: "#12121a"))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 10)
                                                    .stroke(
                                                        vm.exportQuality == quality ? Color(hex: "#DC2626") : Color.white.opacity(0.08),
                                                        lineWidth: vm.exportQuality == quality ? 2 : 1
                                                    )
                                            )
                                    )
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    
                    // Watermark
                    HStack(spacing: 10) {
                        Text("💀")
                            .font(.system(size: 20))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("StickDeath ∞ watermark")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                            Text("Powered by StickDeath Infinity")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundColor(.white.opacity(0.35))
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(hex: "#12121a"))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            )
                    )
                    .padding(.horizontal, 16)
                    
                    // Share To
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SHARE TO")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                            .tracking(1)
                        
                        ForEach(shareTargets) { target in
                            ShareTargetRow(target: target)
                        }
                    }
                    .padding(.horizontal, 16)
                    
                    // Export button
                    Button(action: {}) {
                        Text("EXPORT \(vm.exportFormat.rawValue)")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color(hex: "#DC2626"))
                            )
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                }
            }
            .frame(maxHeight: UIScreen.main.bounds.height * 0.6)
        }
        .background(Color(hex: "#1a1a24"))
        .cornerRadius(16, corners: [.topLeft, .topRight])
    }
}

// MARK: - Export Format Card
struct ExportFormatCard: View {
    let format: ExportFormat
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                Text(format.icon)
                    .font(.system(size: 24))
                Text(format.rawValue)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                Text(format.subtitle)
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.35))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(hex: "#12121a"))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(isSelected ? Color(hex: "#DC2626") : Color.white.opacity(0.08), lineWidth: isSelected ? 2 : 1)
                    )
            )
        }
    }
}

// MARK: - Share Target Row
struct ShareTargetRow: View {
    let target: ShareTarget
    
    var body: some View {
        HStack(spacing: 10) {
            Text(target.icon)
                .font(.system(size: 18))
            
            Text(target.name)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(target.isPro ? .white.opacity(0.35) : .white)
            
            Spacer()
            
            if target.isPro {
                HStack(spacing: 3) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8))
                    Text("PRO")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                }
                .foregroundColor(Color(hex: "#B8860B"))
            } else if target.isEnabled {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.green)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(hex: "#12121a"))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }
}
