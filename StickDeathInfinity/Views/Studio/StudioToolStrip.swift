import SwiftUI

// ═══════════════════════════════════════════════════════════════════
// Tool Strip — Floating white rail from the SD∞ reference design
// ⋮⋮ drag | [color] | selection | drawing | shapes | colour | retouch | text | navigation
// Each tool: unique topColor/bottomColor/glowColor; the selected tile wears
// its own gradient and glow, unselected tiles are light grey with a tinted glyph.
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
    
    /// Sections separated by a hairline, as in the reference toolbar.
    static let sections: [[ToolDef]] = [
        // Order, labels and tile colours follow the SD∞ reference design
        // (React Studio toolbar: selection · drawing · shapes · colour ·
        // retouch · text · navigation). Tools the native Studio does not have
        // (Marquee, Arrow, Clone, Heal, Crop) are not shown; native
        // extras (Marker, Crayon, Smudge, Sharpen) sit inside their groups.
        // Gradient (#149) sits with Fill in the colour group.
        [
            ToolDef(tool: .move,      icon: "arrow.up.and.down.and.arrow.left.and.right", emoji: "⇕", label: "Move",   topColor: "67D4FF", bottomColor: "2EA0D4", glowColor: "38BDF8"),
            ToolDef(tool: .lasso,     icon: "lasso",            emoji: "◎", label: "Lasso",  topColor: "60A5FA", bottomColor: "2563EB", glowColor: "3B82F6"),
            ToolDef(tool: .wand,      icon: "wand.and.stars",   emoji: "✦", label: "Wand",   topColor: "C084FC", bottomColor: "7C3AED", glowColor: "A855F7"),
        ],
        [
            ToolDef(tool: .brush,     icon: "paintbrush",       emoji: "🖌", label: "Brush",  topColor: "FF5555", bottomColor: "B51A1A", glowColor: "FF3333"),
            ToolDef(tool: .pencil,    icon: "pencil",           emoji: "✏",  label: "Pencil", topColor: "FF7070", bottomColor: "CC3333", glowColor: "EF4444"),
            ToolDef(tool: .pen,       icon: "pencil.tip",       emoji: "🖊", label: "Pen",    topColor: "F97316", bottomColor: "C2410C", glowColor: "EA580C"),
            ToolDef(tool: .marker,    icon: "highlighter",      emoji: "🖍️", label: "Marker", topColor: "E879F9", bottomColor: "A21CAF", glowColor: "D946EF"),
            ToolDef(tool: .crayon,    icon: "pencil.and.outline",emoji: "🖍", label: "Crayon", topColor: "FBBF24", bottomColor: "B45309", glowColor: "F59E0B"),
        ],
        [
            ToolDef(tool: .line,      icon: "line.diagonal",    emoji: "╱",  label: "Line",   topColor: "FB923C", bottomColor: "C2410C", glowColor: "F97316"),
            ToolDef(tool: .rectangle, icon: "rectangle",        emoji: "▭",  label: "Rect",   topColor: "FBBF24", bottomColor: "B45309", glowColor: "F59E0B"),
            ToolDef(tool: .circle,    icon: "circle",           emoji: "◯",  label: "Circle", topColor: "FCD34D", bottomColor: "CA8A04", glowColor: "EAB308"),
        ],
        [
            ToolDef(tool: .fill,      icon: "drop.fill",        emoji: "🪣", label: "Fill",   topColor: "4ADE80", bottomColor: "1A8F48", glowColor: "34C77B"),
            ToolDef(tool: .gradient,  icon: "square.bottomhalf.filled", emoji: "▤", label: "Gradient", topColor: "86EFAC", bottomColor: "15803D", glowColor: "22C55E"),
            ToolDef(tool: .eyedropper,icon: "eyedropper",       emoji: "💧", label: "Dropper", topColor: "5EEAD4", bottomColor: "0F766E", glowColor: "2DD4BF"),
        ],
        [
            ToolDef(tool: .eraser,    icon: "eraser",           emoji: "◻",  label: "Eraser", topColor: "FFAD42", bottomColor: "CC7A10", glowColor: "FF9500"),
            ToolDef(tool: .smudge,    icon: "hand.point.up.left",emoji: "👆", label: "Smudge", topColor: "A78BFA", bottomColor: "6D3FCF", glowColor: "8B5CF6"),
            ToolDef(tool: .sharpen,   icon: "triangle",         emoji: "◌",  label: "Sharpen", topColor: "F472B6", bottomColor: "BE185D", glowColor: "EC4899"),
            ToolDef(tool: .dodge,     icon: "sun.max",          emoji: "☀",  label: "Dodge",  topColor: "FEF08A", bottomColor: "CA8A04", glowColor: "FACC15"),
            ToolDef(tool: .burn,      icon: "flame",            emoji: "🔥", label: "Burn",   topColor: "FB923C", bottomColor: "9A3412", glowColor: "EA580C"),
            ToolDef(tool: .blur,      icon: "drop.halffull",    emoji: "◌",  label: "Blur",   topColor: "93C5FD", bottomColor: "3B82F6", glowColor: "60A5FA"),
        ],
        [
            ToolDef(tool: .text,      icon: "textformat",       emoji: "T",  label: "Text",   topColor: "E879F9", bottomColor: "A21CAF", glowColor: "D946EF"),
        ],
        [
            ToolDef(tool: .hand,      icon: "hand.raised",      emoji: "✋", label: "Hand",   topColor: "D4D4D8", bottomColor: "A1A1AA", glowColor: "D4D4D8"),
            ToolDef(tool: .zoom,      icon: "magnifyingglass",  emoji: "🔍", label: "Zoom",   topColor: "E4E4E7", bottomColor: "A1A1AA", glowColor: "D4D4D8"),
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
                            // A plan-locked tool shows the upgrade note instead.
                            guard vm.selectDrawingTool(def.tool) else { return }
                            if hasSettings(def.tool) && FloatingToolSettingsPanel.opensOnSelect(def.tool) {
                                vm.activePanel = .toolSettings
                            } else {
                                vm.activePanel = .none
                            }
                        }
                    }) {
                        VStack(spacing: 2) {
                            Image(systemName: def.icon)
                                .font(.system(size: 16))
                                .foregroundColor(isSelected ? .white : Color(hex: def.bottomColor))
                            Text(def.label)
                                .font(.specialElite(7))
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .fontWeight(.bold)
                                .foregroundColor(isSelected ? .white.opacity(0.85) : Color(hex: "888888"))
                        }
                        .frame(width: 52, height: 52)
                        .overlay(alignment: .topTrailing) {
                            if !vm.planAllowsTool(def.tool) {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(Color(hex: "888888"))
                                    .padding(4)
                                    .accessibilityHidden(true)
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(
                                    isSelected
                                        ? LinearGradient(
                                            colors: [Color(hex: def.topColor), Color(hex: def.bottomColor)],
                                            startPoint: .top, endPoint: .bottom
                                          )
                                        : LinearGradient(
                                            colors: [Color(hex: "F0F0F0"), Color(hex: "DCDCDC")],
                                            startPoint: .top, endPoint: .bottom
                                          )
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.white.opacity(isSelected ? 0.4 : 0.6), lineWidth: 0.5)
                        )
                        .shadow(color: isSelected ? Color(hex: def.glowColor).opacity(0.47) : .black.opacity(0.08),
                                radius: isSelected ? 5 : 1.5, y: isSelected ? 3 : 1)
                    }
                    .id(def.tool.rawValue)
                    .background {
                        if isSelected {
                            // The sole options popup opens beside this button.
                            GeometryReader { geometry in
                                Color.clear.preference(key: StudioSelectedToolFrameKey.self,
                                                       value: geometry.frame(in: .named("studio.toolbar.stage")))
                            }
                        }
                    }
                    .accessibilityLabel(def.label)
                    .accessibilityHint(vm.planAllowsTool(def.tool) ? "" : "Locked. " + vm.planLimits.upgradeNote)
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

/// Stage-space frame of the selected tool button, or nil while it is scrolled
/// out of the rail; `StudioToolbarLayout.settingsFrame(in:toolbar:anchor:)`
/// then falls back to the historical popup placement.
struct StudioSelectedToolFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        if let next = nextValue() { value = next }
    }
}
