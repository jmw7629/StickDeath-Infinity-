import SwiftUI

// ═══════════════════════════════════════════════════════════════════
// Tool Strip — Matches video exactly:
// ⋮⋮ drag | [color] | Move Lasso Pencil Pen Brush Marker Crayon
//   Line Rect Circle Fill Picker Eraser Smudge Text Hand Zoom
// Selection colors: Red 80% (most), Amber 80% (Crayon), Purple 80% (Smudge)
// ═══════════════════════════════════════════════════════════════════

struct StudioToolStrip: View {
    @ObservedObject var vm: StudioViewModel
    
    static let tools: [(DrawingTool, String, String)] = [
        (.move,         "arrow.up.and.down.and.arrow.left.and.right", "Move"),
        (.lasso,        "lasso",                                       "Lasso"),
        (.pencil,       "pencil",                                      "Pencil"),
        (.pen,          "pencil.tip",                                  "Pen"),
        (.brush,        "paintbrush",                                  "Brush"),
        (.marker,       "highlighter",                                 "Marker"),
        (.crayon,       "pencil.and.outline",                          "Crayon"),
        (.line,         "line.diagonal",                               "Line"),
        (.rectangle,    "rectangle",                                   "Rect"),
        (.circle,       "circle",                                      "Circle"),
        (.fill,         "drop.fill",                                   "Fill"),
        (.eyedropper,   "eyedropper",                                  "Picker"),
        (.eraser,       "eraser",                                      "Eraser"),
        (.smudge,       "hand.point.up.left",                          "Smudge"),
        (.text,         "textformat",                                  "Text"),
        (.hand,         "hand.raised",                                 "Hand"),
        (.zoom,         "magnifyingglass",                             "Zoom"),
    ]
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                // Drag handle
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.3))
                    .padding(.horizontal, 4)
                
                // Color square — tap opens color picker
                Button(action: {
                    vm.activePanel = vm.activePanel == .colorPicker ? .none : .colorPicker
                }) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(vm.strokeColor)
                        .frame(width: 44, height: 44)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        )
                }
                
                // Tools
                ForEach(Self.tools, id: \.0) { tool, icon, label in
                    let isSelected = vm.selectedTool == tool
                    
                    Button(action: {
                        if isSelected && hasSettings(tool) {
                            vm.activePanel = vm.activePanel == .toolSettings ? .none : .toolSettings
                        } else {
                            vm.selectedTool = tool
                            vm.activePanel = .none
                        }
                    }) {
                        VStack(spacing: 2) {
                            Image(systemName: icon)
                                .font(.system(size: 16))
                            Text(label)
                                .font(.system(size: 7, weight: isSelected ? .bold : .regular, design: .monospaced))
                        }
                        .foregroundColor(isSelected ? .white : .white.opacity(0.5))
                        .frame(width: 52, height: 52)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(isSelected ? selectionColor(for: tool).opacity(0.8) : Color(hex: "1E1E2A"))
                        )
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(Color(hex: "12121A"))
    }
    
    func selectionColor(for tool: DrawingTool) -> Color {
        switch tool {
        case .crayon:  return Color(hex: "F59E0B")  // Amber/Golden
        case .smudge:  return Color(hex: "A78BFA")  // Purple
        default:       return Color(hex: "DC2626")  // Red
        }
    }
    
    func hasSettings(_ tool: DrawingTool) -> Bool {
        switch tool {
        case .pencil, .pen, .brush, .marker, .crayon, .eraser, .smudge, .text, .fill:
            return true
        default:
            return false
        }
    }
}
