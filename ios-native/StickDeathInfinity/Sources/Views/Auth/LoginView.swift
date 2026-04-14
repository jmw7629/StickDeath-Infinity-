// LoginView.swift
// v3: Explicit back button (not relying on toolbar in sheet), high-contrast

import SwiftUI

struct LoginView: View {
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            ThemeManager.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    // Spacer for back button
                    Color.clear.frame(height: 20)

                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "figure.run")
                            .font(.system(size: 48))
                            .foregroundStyle(.orange)
                        Text("Welcome Back")
                            .font(ThemeManager.headline(size: 32))
                    }

                    // Form
                    VStack(spacing: 16) {
                        TextField("Email", text: $email)
                            .stickDeathTextField()
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .autocapitalization(.none)

                        SecureField("Password", text: $password)
                            .stickDeathTextField()
                            .textContentType(.password)
                    }
                    .padding(.horizontal, 24)

                    // Error
                    if let error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 24)
                    }

                    // Login button
                    Button {
                        Task { await login() }
                    } label: {
                        if loading {
                            ProgressView().tint(.black)
                        } else {
                            Text("Sign In")
                                .font(.headline)
                                .foregroundStyle(.black)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(email.isEmpty || password.isEmpty ? Color.gray.opacity(0.5) : .orange)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 24)
                    .disabled(loading || email.isEmpty || password.isEmpty)

                    Button("Forgot password?") {}
                        .font(.caption)
                        .foregroundStyle(.orange.opacity(0.7))
                }
            }

            // ── Explicit Back Button (always visible, high contrast) ──
            Button { dismiss() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.body.bold())
                    Text("Back")
                        .font(.subheadline.bold())
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.15))
                .clipShape(Capsule())
            }
            .padding(.top, 12)
            .padding(.leading, 16)
        }
    }

    func login() async {
        loading = true
        error = nil
        do {
            try await auth.login(email: email, password: password)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}
