// ═══════════════════════════════════════════════════════════════════
// SDTextField — Reusable dark-themed input field
// Matches: React input fields with dark bg, white text, icon prefix
// Dynamic Type: text and icon scale through sdScaledSystemFont (#264); the
// decorative prefix icon is hidden from VoiceOver, the field keeps its
// placeholder as its label.
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
                    .sdScaledSystemFont(16)
                    .foregroundColor(isFocused ? .sdRed : .sdTextMuted)
                    .sdScaledFrame(width: 20, height: 20)
                    .accessibilityHidden(true)
            }

            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .sdScaledSystemFont(16)
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
