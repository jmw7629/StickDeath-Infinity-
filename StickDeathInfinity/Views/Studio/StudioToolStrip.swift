import SwiftUI

// ═══════════════════════════════════════════════════════════════════
// Tool Strip — Floating white rail with red active-tool selection
// ⋮⋮ drag | [color] | Move Lasso Pencil Pen Brush Marker Crayon
//   Line Rect Circle Fill Picker Eraser Smudge Text Hand Zoom
// Each tool: unique topColor/bottomColor/glowColor
// ═══════════════════════════════════════════════════════════════════

struct ToolDef {
    let tool: DrawingTool
    let icon: String      // SF Symbol
    let emoji: String     // Fallback emoji (from React)
    let label: String
    let shortcut: String
    let topColor: String
    let bottomColor: String
    let glowColor: String
}

struct StudioToolStrip: View {
    @ObservedObject var vm: StudioViewModel
    var axis: Axis = .horizontal
    var handleGesture = AnyGesture(DragGesture(minimumDistance: 5))
    var onDock: (StudioToolbarLayout.Dock) -> Void = { _ in }
    
    static let tools: [ToolDef] = [
        ToolDef(tool: .move,      icon: "arrow.up.and.down.and.arrow.left.and.right", emoji: "☠⇕", label: "Move",   shortcut: "V", topColor: "555566", bottomColor: "333344", glowColor: "777788"),
        ToolDef(tool: .lasso,     icon: "lasso",            emoji: "☠◎", label: "Lasso",  shortcut: "L", topColor: "555566", bottomColor: "333344", glowColor: "777788"),
        ToolDef(tool: .pencil,    icon: "pencil",           emoji: "✏️",  label: "Pencil", shortcut: "N", topColor: "DC2626", bottomColor: "991B1B", glowColor: "EF4444"),
        ToolDef(tool: .pen,       icon: "pencil.tip",       emoji: "🖊️", label: "Pen",    shortcut: "P", topColor: "C53030", bottomColor: "7F1D1D", glowColor: "DC2626"),
        ToolDef(tool: .brush,     icon: "paintbrush",       emoji: "🖌️", label: "Brush",  shortcut: "B", topColor: "E03030", bottomColor: "B91C1C", glowColor: "F43F5E"),
        ToolDef(tool: .marker,    icon: "highlighter",      emoji: "🖍️", label: "Marker", shortcut: "K", topColor: "E83E8C", bottomColor: "A21CAF", glowColor: "D946EF"),
        ToolDef(tool: .crayon,    icon: "pencil.and.outline",emoji: "🖍", label: "Crayon", shortcut: "Y", topColor: "F59E0B", bottomColor: "B45309", glowColor: "FBBF24"),
        ToolDef(tool: .line,      icon: "line.diagonal",    emoji: "╱",  label: "Line",   shortcut: "U", topColor: "888899", bottomColor: "555566", glowColor: "999AAA"),
        ToolDef(tool: .rectangle, icon: "rectangle",        emoji: "▭",  label: "Rect",   shortcut: "U", topColor: "888899", bottomColor: "555566", glowColor: "999AAA"),
        ToolDef(tool: .circle,    icon: "circle",           emoji: "◯",  label: "Circle", shortcut: "U", topColor: "888899", bottomColor: "555566", glowColor: "999AAA"),
        ToolDef(tool: .fill,      icon: "drop.fill",        emoji: "🪣",  label: "Fill",   shortcut: "G", topColor: "22C55E", bottomColor: "15803D", glowColor: "4ADE80"),
        ToolDef(tool: .eyedropper,icon: "eyedropper",       emoji: "💧",  label: "Picker", shortcut: "I", topColor: "06B6D4", bottomColor: "0E7490", glowColor: "22D3EE"),
        ToolDef(tool: .eraser,    icon: "eraser",           emoji: "◻️",  label: "Eraser", shortcut: "E", topColor: "F97316", bottomColor: "C2410C", glowColor: "FB923C"),
        ToolDef(tool: .smudge,    icon: "hand.point.up.left",emoji: "👆", label: "Smudge", shortcut: "R", topColor: "A78BFA", bottomColor: "6D28D9", glowColor: "C4B5FD"),
        ToolDef(tool: .text,      icon: "textformat",       emoji: "T",  label: "Text",   shortcut: "T", topColor: "E879F9", bottomColor: "A21CAF", glowColor: "D946EF"),
        ToolDef(tool: .hand,      icon: "hand.raised",      emoji: "✋",  label: "Hand",   shortcut: "H", topColor: "78716C", bottomColor: "57534E", glowColor: "A8A29E"),
        ToolDef(tool: .zoom,      icon: "magnifyingglass",  emoji: "🔍",  label: "Zoom",   shortcut: "Z", topColor: "78716C", bottomColor: "57534E", glowColor: "A8A29E"),
    ]
    
    var body: some View {
        railLayout {
            // A fixed, independently draggable grip never scrolls out of reach.
            Image(systemName: "circle.grid.2x3.fill")
                .font(.system(size: 13))
                .foregroundColor(.black.opacity(0.35))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .gesture(handleGesture)
                .accessibilityElement()
                .accessibilityLabel("Move Studio toolbar")
                .accessibilityHint("Drag to either canvas edge to dock vertically.")
                .accessibilityIdentifier("studio.toolbar.grip")
                .accessibilityAction(named: Text("Dock tools left")) { onDock(.leading) }
                .accessibilityAction(named: Text("Dock tools right")) { onDock(.trailing) }
                .accessibilityAction(named: Text("Float tools horizontally")) { onDock(.floating) }

            ScrollView(axis == .vertical ? .vertical : .horizontal, showsIndicators: false) {
            railLayout {
                // Color square — tap opens color picker
                Button(action: {
                    vm.activePanel = vm.activePanel == .colorPicker ? .none : .colorPicker
                }) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(vm.strokeColor)
                        .frame(width: 48, height: 48)
                        .shadow(color: vm.strokeColor.opacity(0.5), radius: 4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                        )
                }
                
                // Tools
                ForEach(Self.tools.indices, id: \.self) { i in
                    let def = Self.tools[i]
                    let isSelected = vm.selectedTool == def.tool
                    
                    Button(action: {
                        if isSelected && hasSettings(def.tool) {
                            vm.activePanel = vm.activePanel == .toolSettings ? .none : .toolSettings
                        } else {
                            vm.selectDrawingTool(def.tool)
                            if hasSettings(def.tool) {
                                vm.activePanel = .toolSettings
                            } else {
                                vm.activePanel = .none
                            }
                        }
                    }) {
                        VStack(spacing: 2) {
                            Image(systemName: def.icon)
                                .font(.system(size: 16))
                            Text(def.label)
                                .font(.system(size: 7, weight: isSelected ? .bold : .regular, design: .monospaced))
                        }
                        .foregroundColor(isSelected ? .white : .black.opacity(0.75))
                        .frame(width: 52, height: 52)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(
                                    isSelected
                                        ? LinearGradient(
                                            colors: [Color.red, Color(red: 0.72, green: 0.05, blue: 0.08)],
                                            startPoint: .top, endPoint: .bottom
                                          )
                                        : LinearGradient(
                                            colors: [Color.white, Color.white],
                                            startPoint: .top, endPoint: .bottom
                                          )
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(isSelected ? Color(hex: def.glowColor).opacity(0.4) : Color.white.opacity(0.08), lineWidth: isSelected ? 1 : 0.5)
                        )
                        .shadow(color: isSelected ? Color(hex: def.glowColor).opacity(0.3) : .clear, radius: 4)
                    }
                    .accessibilityLabel(def.label)
                    .accessibilityIdentifier("studio.tool.\(def.tool.rawValue)")
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
        }
        .padding(4)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("studio.toolbar")
        .accessibilityValue(axis == .vertical ? "Vertical" : "Horizontal")
    }
    
    private var railLayout: AnyLayout {
        axis == .vertical ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
    }

    func hasSettings(_ tool: DrawingTool) -> Bool {
        FloatingToolSettingsPanel.hasSettings(tool)
    }
}
