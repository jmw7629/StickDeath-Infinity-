// PanelHeader.swift
// Reusable panel header for studio side panels
// Used by SpatterStudioPanel, TimelinePanel, LayersPanel, etc.

import SwiftUI

@ViewBuilder
func panelHeader<Trailing: View>(
    _ title: String,
    icon: String,
    onClose: @escaping () -> Void,
    @ViewBuilder trailing: () -> Trailing = { EmptyView() }
) -> some View {
    HStack(spacing: 8) {
        Image(systemName: icon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(ThemeManager.brand)

        Text(title)
            .font(ThemeManager.headlineBold(size: 14))
            .foregroundStyle(.white)

        trailing()

        Spacer()

        Button(action: onClose) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.gray)
        }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(ThemeManager.surface)
}
