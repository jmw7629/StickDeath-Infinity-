// LoginView.swift
// v2: High-contrast fields, visible cursor, prominent back button

import SwiftUI

struct LoginView: View {
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        NavigationStack {
            ZStack {
                ThemeManager.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        // Header
                        VStack(spacing: 8) {
                            Image(systemName: "figure.run")
                                .font(.system(size: 48))
                                .foregroundStyle(.orange)
                            Text("Welcome Back")
                                .font(ThemeManager.headline(size: 32))
                        }
                        .padding(.top, 40)

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
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.body.weight(.semibold))
                            Text("Back")
                                .font(.body.weight(.medium))
                        }
                        .foregroundStyle(.orange)
                    }
                }
            }
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
