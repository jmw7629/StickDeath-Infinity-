// EditProfileSheet.swift
// Layer 3 — ACTION SCREEN (sheet — closes, returns to Profile)

import SwiftUI

struct EditProfileSheet: View {
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) var dismiss
    @State private var username = ""
    @State private var bio = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Display Name") {
                    TextField("Username", text: $username)
                }
                Section("Bio") {
                    TextEditor(text: $bio)
                        .frame(minHeight: 80)
                }
                Section("Avatar") {
                    HStack {
                        Circle()
                            .fill(LinearGradient(colors: [.red.opacity(0.4), .red.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 60, height: 60)
                            .overlay(
                                Text(String(username.prefix(1)).uppercased())
                                    .font(.title2.bold()).foregroundStyle(.white)
                            )
                        Spacer()
                        Button("Change Photo") {}
                            .font(.subheadline).foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ThemeManager.background)
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(.gray)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(saving)
                    .foregroundStyle(.red)
                }
            }
            .onAppear {
                username = auth.currentUser?.username ?? ""
                bio = auth.currentUser?.bio ?? ""
            }
        }
    }

    func save() async {
        saving = true
        guard let userId = auth.session?.user.id else { return }
        _ = try? await supabase.from("users")
            .update(["username": username, "bio": bio])
            .eq("id", value: userId.uuidString)
            .execute()
        saving = false
        dismiss()
    }
}
