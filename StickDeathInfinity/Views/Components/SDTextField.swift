// ═══════════════════════════════════════════════════════════════════
// SDTextField — Reusable dark-themed input field
// Matches: React input fields with dark bg, white text, icon prefix
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct SDTextField: View {
    let placeholder: String
    @Binding var text: String
    var icon: String? = nil
    var isSecure: Bool = false

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(isFocused ? .sdRed : .sdTextMuted)
                    .frame(width: 20)
            }

            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .font(.system(size: 16))
            .foregroundColor(.sdTextPrimary)
            .focused($isFocused)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isFocused ? Color.sdRed.opacity(0.5) : Color.sdBorderLight, lineWidth: 1)
        )
        .cornerRadius(12)
    }
}
