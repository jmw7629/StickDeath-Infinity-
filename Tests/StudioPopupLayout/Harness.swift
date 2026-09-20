import AppKit
import SwiftUI

private final class ViewBox {
    var content: NSView?
    var viewport: NSView?
}
private struct LayoutProbe: NSViewRepresentable {
    let capture: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView(); capture(view); return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
@main struct PopupLayoutTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        for (name, rows, bound) in [("short controls", 0, CGFloat(360)),
                                     ("long library", 30, CGFloat(360)),
                                     ("compact landscape", 0, CGFloat(88))] {
            let box = ViewBox()
            let content = ToolSettingsContentLayout(maximumHeight: bound) {
                VStack {
                    Button("Brush Library: Round") {}
                    Slider(value: .constant(0.5))
                    TextField("X", text: .constant("270"))
                    Button("Reset this tool") {}
                    ForEach(0..<rows, id: \.self) { i in Text("Library item \(i)") }
                }.background(LayoutProbe { box.content = $0 })
            }.background(LayoutProbe { box.viewport = $0 })
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 236, height: 400),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: 236, height: 400)
            // Real SwiftUI preference delivery/layout, with a fixed bounded run loop.
            // No simulator, app activation, mock geometry or copied layout model.
            let deadline = Date().addingTimeInterval(1)
            while Date() < deadline {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            let measured = box.content?.frame.height ?? 0
            let viewport = box.viewport?.frame.height ?? 0
            let expected = min(measured, bound)
            guard measured > 0, viewport > 0, abs(viewport - expected) < 0.5,
                  abs(host.fittingSize.height - expected) < 0.5 else {
                print("FAIL \(name): content=\(measured), viewport=\(viewport), fitting=\(host.fittingSize.height), bound=\(bound)")
                exit(1)
            }
            print("PASS \(name): actual content=\(measured), viewport=\(viewport)")
            window.close()
        }
        print("STUDIO_POPUP_LAYOUT=PASS 3/3 actual hosted SwiftUI cases")
    }
}
