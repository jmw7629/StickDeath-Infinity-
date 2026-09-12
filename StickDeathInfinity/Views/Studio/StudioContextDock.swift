import SwiftUI

/// Secondary controls for the current tool. All actions use the existing VM;
/// this does not imply unfinished fill/selection/effect operations are complete.
struct StudioContextDock: View {
    @ObservedObject var vm: StudioViewModel
    var onDismiss: () -> Void

    static func hasSettings(_ tool: DrawingTool) -> Bool {
        switch tool {
        case .pencil, .pen, .brush, .marker, .crayon, .eraser, .smudge, .text,
             .fill, .line, .rectangle, .circle, .move, .lasso: return true
        default: return false
        }
    }
    static func hasColor(_ tool: DrawingTool) -> Bool {
        switch tool {
        case .pencil, .pen, .brush, .marker, .crayon, .text, .fill, .line, .rectangle, .circle: return true
        default: return false
        }
    }
    static func hasZoom(_ tool: DrawingTool) -> Bool { tool == .hand || tool == .zoom }
    static func applies(to tool: DrawingTool) -> Bool { hasSettings(tool) || hasColor(tool) || hasZoom(tool) }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.7)).frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Dismiss tool controls")
            .accessibilityIdentifier("studio.context.close")
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    if Self.hasSettings(vm.selectedTool) {
                        dockButton("slider.horizontal.3", "Settings", "studio.context.settings") {
                            vm.activePanel = vm.activePanel == .toolSettings ? .none : .toolSettings
                        }
                    }
                    if Self.hasColor(vm.selectedTool) {
                        Button { vm.activePanel = .colorPicker } label: {
                            VStack(spacing: 2) {
                                RoundedRectangle(cornerRadius: 3).fill(vm.strokeColor).frame(width: 16, height: 16)
                                Text("Color").font(.system(size: 8, design: .monospaced))
                            }.frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Tool color").accessibilityIdentifier("studio.context.color")
                    }
                    if Self.hasZoom(vm.selectedTool) {
                        dockButton("plus", "Zoom in", "studio.context.zoom-in") { vm.zoomIn() }
                        dockButton("minus", "Zoom out", "studio.context.zoom-out") { vm.zoomOut() }
                        dockButton("arrow.up.left.and.arrow.down.right", "FIT", "studio.context.fit") { vm.zoomFit() }
                    }
                }
            }
            .frame(maxHeight: Self.hasZoom(vm.selectedTool) ? 136 : Self.hasColor(vm.selectedTool) ? 90 : 44)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
        .foregroundColor(.white)
        .background(Color(hex: "1A1A24").opacity(0.97), in: RoundedRectangle(cornerRadius: 12))
    }

    private func dockButton(_ icon: String, _ label: String, _ identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 14))
                Text(label).font(.system(size: 8, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.7)
            }.frame(width: 44, height: 44)
        }.accessibilityLabel(label).accessibilityIdentifier(identifier)
    }
}
