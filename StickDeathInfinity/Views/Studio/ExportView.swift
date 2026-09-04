// ═══════════════════════════════════════════════════════════════════
// ExportView — Placeholder stub
// Referenced in pbxproj. The actual export UI lives in ExportPanel.
// Kept as a minimal stub to satisfy the build system.
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct ExportView: View {
    @ObservedObject var vm: StudioViewModel

    var body: some View {
        ExportPanel(vm: vm)
    }
}
