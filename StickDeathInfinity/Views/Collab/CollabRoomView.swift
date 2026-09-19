import SwiftUI

/// Project collaboration is separate from the retired messenger.
/// Never mint local invite codes or claim membership before server verification.
struct CollabRoomView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Label("Rooms", systemImage: "person.2.fill")
                        .font(.specialElite(24))
                        .foregroundColor(.sdTextPrimary)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Create together")
                            .font(.specialElite(18))
                            .foregroundColor(.sdTextPrimary)
                        Text("Invite another creator to work on a Studio project. You both choose to collaborate and share only the project you agree on.")
                            .foregroundColor(.sdTextSecondary)
                        Label("No chat, voice calls or video calls", systemImage: "paintbrush.pointed")
                            .font(.callout)
                            .foregroundColor(.sdTextSecondary)
                        Divider().overlay(Color.sdBorder)
                        Label("Collaboration is not connected yet", systemImage: "lock.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundColor(.sdRed)
                            .accessibilityIdentifier("rooms.unavailable")
                        Text("Creating rooms, redeeming invitation codes and sharing projects are unavailable in this build. Your Studio projects stay on this device.")
                            .font(.callout)
                            .foregroundColor(.sdTextSecondary)
                    }
                    .padding(18)
                    .background(Color.sdSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    NavigationLink {
                        WarRoomView()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "flag.checkered").foregroundColor(.sdRed)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("War Room").font(.specialElite(18))
                                Text("Video matchups · coming next").font(.callout)
                                    .foregroundColor(.sdTextSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .foregroundColor(.sdTextPrimary)
                        .padding(18)
                        .background(Color.sdSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .accessibilityIdentifier("rooms.warRoom")
                }
                .padding(16)
                .padding(.bottom, 60)
            }
            .background(Color.sdBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}
