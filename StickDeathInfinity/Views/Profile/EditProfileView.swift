// ═══════════════════════════════════════════════════════════════════
// EditProfileView — Edit user profile
// Matches: Profile edit modal in src/pages/ProfileScreen.tsx
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct EditProfileView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var authVM: AuthViewModel
    @State private var username = ""
    @State private var bio = ""
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.sdBackground.ignoresSafeArea()

                VStack(spacing: 24) {
                    // Avatar
                    ZStack {
                        Circle()
                            .fill(Color.sdSurface2)
                            .frame(width: 100, height: 100)

                        Image(systemName: "person.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.sdTextMuted)

                        // Camera overlay
                        Circle()
                            .fill(Color.sdRed)
                            .frame(width: 30, height: 30)
                            .overlay(
                                Image(systemName: "camera.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(.white)
                            )
                            .offset(x: 35, y: 35)
                    }

                    // Fields
                    VStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("USERNAME")
                                .font(.system(size: 12, weight: .bold))
                                .tracking(1)
                                .foregroundColor(.sdTextMuted)
                            SDTextField(
                                placeholder: "Your username",
                                text: $username
                            )
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("BIO")
                                .font(.system(size: 10, weight: .bold))
                                .tracking(1)
                                .foregroundColor(.sdTextMuted)

                            TextEditor(text: $bio)
                                .font(.system(size: 14))
                                .foregroundColor(.sdTextPrimary)
                                .frame(height: 100)
                                .padding(12)
                                .background(Color.sdSurface)
                                .cornerRadius(12)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.sdBorder, lineWidth: 1)
                                )
                        }
                    }
                    .padding(.horizontal, 20)

                    Spacer()

                    // Save
                    Button {
                        isSaving = true
                        Task {
                            // TODO: Update profile via Supabase
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            isSaving = false
                            dismiss()
                        }
                    } label: {
                        HStack {
                            if isSaving {
                                ProgressView().tint(.white)
                            }
                            Text("Save Profile")
                                .font(.specialElite(16))
                                .foregroundColor(.white)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            LinearGradient(
                                colors: [.sdRed, .sdRedDeep],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .cornerRadius(14)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.sdTextSecondary)
                }
            }
            .onAppear {
                username = authVM.user?.username ?? ""
                bio = authVM.user?.bio ?? ""
            }
        }
    }
}
