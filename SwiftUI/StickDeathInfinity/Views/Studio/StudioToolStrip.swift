import SwiftUI

// ═══════════════════════════════════════════════════════════════════
// StudioToolStrip — 18-tool horizontal scroll bar
// Matches the toolbar from StudioScreen.tsx TOOL_GROUPS exactly
// ═══════════════════════════════════════════════════════════════════

struct StudioToolStrip: View {
    @ObservedObject var vm: StudioViewModel

    // Exact tool order from React source
    static let tools: [(DrawingTool, String, String)] = [
        (.move,        "☠️⇕",  "Move"),
        (.lasso,       "☠️◎",  "Lasso"),
        (.pencil,      "✏️",   "Pencil"),
        (.pen,         "🖊️",   "Pen"),
        (.brush,       "🖌️",   "Brush"),
        (.marker,      "🖍️",   "Marker"),
        (.crayon,      "🖍",   "Crayon"),
        (.line,        "╱",    "Line"),
        (.rectangle,   "▭",    "Rect"),
        (.circle,      "◯",    "Circle"),
        (.fill,        "🪣",   "Fill"),
        (.eyedropper,  "💧",   "Picker"),
        (.eraser,      "◻️",   "Eraser"),
        (.smudge,      "👆",   "Smudge"),
        (.text,        "T",    "Text"),
        (.hand,        "✋",   "Hand"),
        (.zoom,        "🔍",   "Zoom"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            // Color picker button (left)
            Button(action: {
                withAnimation {
                    vm.activePanel = vm.activePanel == .colorPicker ? .none : .colorPicker
                }
            }) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(vm.strokeColor)
                    .frame(width: 28, height: 28)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.white.opacity(0.3), lineWidth: 1.5)
                    )
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)

            // Tool scroll
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Self.tools, id: \.0) { tool, icon, name in
                        ToolButton(
                            icon: icon,
                            name: name,
                            isSelected: vm.selectedTool == tool,
                            onTap: { vm.selectedTool = tool },
                            onLongPress: {
                                vm.selectedTool = tool
                                withAnimation { vm.activePanel = .toolSettings }
                            }
                        )
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .frame(height: 44)
        .background(Color(hex: "#14141e"))
        .overlay(
            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 0.5),
            alignment: .bottom
        )
    }
}

// MARK: - Tool Button
struct ToolButton: View {
    let icon: String
    let name: String
    let isSelected: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 1) {
                Text(icon)
                    .font(.system(size: 16))
                    .frame(height: 22)

                Text(name)
                    .font(.system(size: 6, weight: .bold, design: .monospaced))
                    .foregroundColor(isSelected ? Color(hex: "#DC2626") : .white.opacity(0.3))
            }
            .frame(width: 40, height: 36)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color(hex: "#DC2626").opacity(0.15) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color(hex: "#DC2626").opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in onLongPress() }
        )
    }
}
