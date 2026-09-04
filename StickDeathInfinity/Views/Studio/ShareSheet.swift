// ═══════════════════════════════════════════════════════════════════
// ShareSheet — Native iOS Share Sheet wrapper for SwiftUI
// Exports the rendered animation to any installed sharing destination.
// ═══════════════════════════════════════════════════════════════════

import SwiftUI
import UIKit

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    var activities: [UIActivity]? = nil
    var completion: ((Bool) -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: items,
            applicationActivities: activities
        )
        controller.completionWithItemsHandler = { _, completed, _, _ in
            completion?(completed)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Share Sheet Trigger Modifier
struct ShareSheetModifier: ViewModifier {
    @Binding var isPresented: Bool
    let items: () -> [Any]
    var completion: ((Bool) -> Void)? = nil

    func body(content: Content) -> content {
        content
            .sheet(isPresented: $isPresented) {
                ShareSheet(items: items(), completion: completion)
                    .presentationDetents([.medium, .large])
            }
    }
}

extension View {
    func shareSheet(
        isPresented: Binding<Bool>,
        items: @escaping () -> [Any],
        completion: ((Bool) -> Void)? = nil
    ) -> some View {
        modifier(ShareSheetModifier(
            isPresented: isPresented,
            items: items,
            completion: completion
        ))
    }
}
