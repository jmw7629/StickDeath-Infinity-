import SwiftUI

// ═══════════════════════════════════════════════════════════════════
// Tool Strip — Floating white rail with red active-tool selection
// ⋮⋮ drag | [color] | ArtCraft PhotoCraft sections: selection & sampling |
//   painting & retouching | type & shapes | navigation
// Each tool: unique topColor/bottomColor/glowColor
// ═══════════════════════════════════════════════════════════════════

struct ToolDef {
    let tool: DrawingTool
    let icon: String      // SF Symbol
    let emoji: String     // Fallback emoji (from React)
    let label: String
    let topColor: String
    let bottomColor: String
    let glowColor: String
}

struct StudioToolStrip: View {
    @ObservedObject var vm: StudioViewModel
    var axis: Axis = .horizontal
    var handleGesture = AnyGesture(DragGesture(minimumDistance: 5))
    var onDock: (StudioToolbarLayout.Dock) -> Void = { _ in }
    
    /// ArtCraft PhotoCraft toolbar order (crates/ui-egui/src/panels.rs
    /// TOOL_SECTIONS): selection & sampling, painting & retouching, type &
    /// shapes, then navigation. `label` uses PhotoCraft's tool names.
    static let sections: [[ToolDef]] = [
        [
            ToolDef(tool: .move,      icon: "arrow.up.and.down.and.arrow.left.and.right", emoji: "☠⇕", label: "Move",   topColor: "555566", bottomColor: "333344", glowColor: "777788"),
            ToolDef(tool: .lasso,     icon: "lasso",            emoji: "☠◎", label: "Lasso",  topColor: "555566", bottomColor: "333344", glowColor: "777788"),
            ToolDef(tool: .wand, icon: "wand.and.stars", emoji: "✦", label: "Magic Wand", topColor: "555566", bottomColor: "333344", glowColor: "777788"),
            ToolDef(tool: .eyedropper,icon: "eyedropper",       emoji: "💧",  label: "Eyedropper", topColor: "06B6D4", bottomColor: "0E7490", glowColor: "22D3EE"),
        ],
        [
            ToolDef(tool: .brush,     icon: "paintbrush",       emoji: "🖌️", label: "Brush",  topColor: "E03030", bottomColor: "B91C1C", glowColor: "F43F5E"),
            ToolDef(tool: .pencil,    icon: "pencil",           emoji: "✏️",  label: "Pencil", topColor: "DC2626", bottomColor: "991B1B", glowColor: "EF4444"),
            ToolDef(tool: .pen,       icon: "pencil.tip",       emoji: "🖊️", label: "Pen",    topColor: "C53030", bottomColor: "7F1D1D", glowColor: "DC2626"),
            ToolDef(tool: .marker,    icon: "highlighter",      emoji: "🖍️", label: "Marker", topColor: "E83E8C", bottomColor: "A21CAF", glowColor: "D946EF"),
            ToolDef(tool: .crayon,    icon: "pencil.and.outline",emoji: "🖍", label: "Crayon", topColor: "F59E0B", bottomColor: "B45309", glowColor: "FBBF24"),
            ToolDef(tool: .eraser,    icon: "eraser",           emoji: "◻️",  label: "Eraser", topColor: "F97316", bottomColor: "C2410C", glowColor: "FB923C"),
            ToolDef(tool: .fill,      icon: "drop.fill",        emoji: "🪣",  label: "Paint Bucket", topColor: "22C55E", bottomColor: "15803D", glowColor: "4ADE80"),
            ToolDef(tool: .blur,      icon: "drop.halffull", emoji: "◌", label: "Blur", topColor: "A78BFA", bottomColor: "6D28D9", glowColor: "C4B5FD"),
            ToolDef(tool: .sharpen,      icon: "triangle", emoji: "◌", label: "Sharpen", topColor: "A78BFA", bottomColor: "6D28D9", glowColor: "C4B5FD"),
            ToolDef(tool: .smudge,    icon: "hand.point.up.left",emoji: "👆", label: "Smudge", topColor: "A78BFA", bottomColor: "6D28D9", glowColor: "C4B5FD"),
            ToolDef(tool: .dodge,      icon: "sun.max", emoji: "◌", label: "Dodge", topColor: "A78BFA", bottomColor: "6D28D9", glowColor: "C4B5FD"),
            ToolDef(tool: .burn,      icon: "flame", emoji: "◌", label: "Burn", topColor: "A78BFA", bottomColor: "6D28D9", glowColor: "C4B5FD"),
        ],
        [
            ToolDef(tool: .text,      icon: "textformat",       emoji: "T",  label: "Type",   topColor: "E879F9", bottomColor: "A21CAF", glowColor: "D946EF"),
            ToolDef(tool: .line,      icon: "line.diagonal",    emoji: "╱",  label: "Line",   topColor: "888899", bottomColor: "555566", glowColor: "999AAA"),
            ToolDef(tool: .rectangle, icon: "rectangle",        emoji: "▭",  label: "Rectangle", topColor: "888899", bottomColor: "555566", glowColor: "999AAA"),
            ToolDef(tool: .circle,    icon: "circle",           emoji: "◯",  label: "Ellipse", topColor: "888899", bottomColor: "555566", glowColor: "999AAA"),
        ],
        [
            ToolDef(tool: .hand,      icon: "hand.raised",      emoji: "✋",  label: "Hand",   topColor: "78716C", bottomColor: "57534E", glowColor: "A8A29E"),
            ToolDef(tool: .zoom,      icon: "magnifyingglass",  emoji: "🔍",  label: "Zoom",   topColor: "78716C", bottomColor: "57534E", glowColor: "A8A29E"),
        ],
    ]
    static let tools: [ToolDef] = sections.flatMap { $0 }
    
    var body: some View {
        railLayout {
            // A fixed, independently draggable grip never scrolls out of reach.
            // Explicit dots keep the drag affordance visible on every supported
            // OS; the former system symbol rendered as an empty 44-point area.
            VStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: 3) {
                        Circle().frame(width: 3, height: 3)
                        Circle().frame(width: 3, height: 3)
                    }
                }
            }
                .foregroundColor(.black.opacity(0.55))
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

            ScrollViewReader { reader in
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
                .accessibilityLabel("Drawing color")
                .accessibilityValue(vm.strokeColorHex.uppercased())
                .accessibilityIdentifier("studio.color.open")
                
                // Tools, with a PhotoCraft hairline between sections.
                ForEach(Self.tools.indices, id: \.self) { i in
                    let def = Self.tools[i]
                    let isSelected = vm.selectedTool == def.tool
                    if i > 0, Self.sectionStarts.contains(i) {
                        Rectangle().fill(Color.black.opacity(0.12))
                            .frame(width: axis == .vertical ? 36 : 1, height: axis == .vertical ? 1 : 36)
                            .accessibilityHidden(true)
                    }
                    
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
                                .font(.specialElite(7))
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .fontWeight(isSelected ? .bold : .regular)
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
                    .id(def.tool.rawValue)
                    .accessibilityLabel(def.label)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityIdentifier("studio.tool.\(def.tool.rawValue)")
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .task(id: VisibilityRequest(tool: vm.selectedTool.rawValue,
                                                vertical: axis == .vertical,
                                                viewport: geometry.size,
                                                position: geometry.frame(in: .named("studio.toolbar.stage")).origin)) {
                        // Run after the changed axis/viewport has participated in
                        // layout. Task identity excludes scroll offset, so browsing
                        // other tools never pulls the rail back to the selection.
                        await Task.yield()
                        guard !Task.isCancelled, geometry.size.width > 0,
                              geometry.size.height > 0 else { return }
                        reader.scrollTo(vm.selectedTool.rawValue, anchor: .center)
                    }
            }
        }
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
    
    /// Indices in `tools` where a new PhotoCraft section begins.
    static let sectionStarts: Set<Int> = {
        var starts = Set<Int>(), index = 0
        for section in sections { starts.insert(index); index += section.count }
        return starts
    }()

    private struct VisibilityRequest: Equatable {
        let tool: String
        let vertical: Bool
        let viewport: CGSize
        let position: CGPoint
    }

    private var railLayout: AnyLayout {
        axis == .vertical ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
    }

    func hasSettings(_ tool: DrawingTool) -> Bool {
        FloatingToolSettingsPanel.hasSettings(tool)
    }
}
