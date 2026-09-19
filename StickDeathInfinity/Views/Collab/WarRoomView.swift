import SwiftUI

/// Contests remain unavailable until real uploads, moderation and voting exist.
struct WarRoomView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Back to Rooms")
                Text("War Room").font(.specialElite(22))
                Spacer()
            }
            .foregroundColor(.sdTextPrimary)
            .padding(.horizontal, 8)
            .background(Color.sdSurface)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "flag.checkered")
                        .font(.system(size: 36))
                        .foregroundColor(.sdRed)
                    Text("Let the animations compete")
                        .font(.specialElite(20))
                        .foregroundColor(.sdTextPrimary)
                    Text("Two creators submit videos. Viewers watch both and pick their favorite. Creators choose whether badges and win/loss records appear publicly.")
                        .foregroundColor(.sdTextSecondary)
                    Label("Video submissions and voting are not available yet", systemImage: "lock.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundColor(.sdRed)
                        .accessibilityIdentifier("warRoom.unavailable")
                    Text("No match is running and no votes or records are being counted in this build.")
                        .font(.callout)
                        .foregroundColor(.sdTextSecondary)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.sdBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}
