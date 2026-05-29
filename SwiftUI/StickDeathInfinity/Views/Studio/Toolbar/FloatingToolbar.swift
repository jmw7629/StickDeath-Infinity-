import SwiftUI

struct StudioBottomBar: View {
    @ObservedObject var vm: StudioViewModel
    
    var body: some View {
        HStack(spacing: 0) {
            BottomBarButton(icon: "🎵", label: "AUDIO") {
                vm.activePanel = vm.activePanel == .soundLibrary ? .none : .soundLibrary
            }
            
            BottomBarButton(icon: "↩", label: "UNDO") {
                vm.undo()
            }
            
            BottomBarButton(icon: "↪", label: "REDO") {
                vm.redo()
            }
            
            BottomBarButton(icon: "📋", label: "COPY") {
                vm.duplicateFrame()
            }
            
            BottomBarButton(icon: "📌", label: "PASTE") {
                // Paste functionality
            }
            
            BottomBarButton(icon: "🗑", label: "DEL") {
                vm.clearCanvas()
            }
            
            // Layer button with badge
            Button(action: {
                vm.activePanel = vm.activePanel == .layers ? .none : .layers
            }) {
                ZStack(alignment: .topTrailing) {
                    VStack(spacing: 2) {
                        Text("📄")
                            .font(.system(size: 16))
                        Text("LAYER")
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    
                    // Badge
                    Text("\(vm.layers.count)")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(Color(hex: "#DC2626")))
                        .offset(x: -8, y: 2)
                }
            }
        }
        .frame(height: 52)
        .background(Color(hex: "#0d0d14"))
        .overlay(
            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 0.5),
            alignment: .top
        )
    }
}

// MARK: - Bottom Bar Button
struct BottomBarButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(icon)
                    .font(.system(size: 16))
                Text(label)
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
        }
    }
}
