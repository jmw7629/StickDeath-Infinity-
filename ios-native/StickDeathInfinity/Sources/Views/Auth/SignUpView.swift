// SignUpView.swift
// v2: High-contrast fields, visible cursor, prominent back button, bold colors

import SwiftUI

struct SignUpView: View {
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) var dismiss

    @State private var username = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var error: String?
    @State private var loading = false
    @State private var agreedToTerms = false

    var isValid: Bool {
        !username.isEmpty && !email.isEmpty && password.count >= 8
        && password == confirmPassword && agreedToTerms
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ThemeManager.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        VStack(spacing: 8) {
                            Image(systemName: "figure.run")
                                .font(.system(size: 48))
                                .foregroundStyle(.orange)
                            Text("Create Account")
                                .font(ThemeManager.headline(size: 32))
                            Text("Join the StickDeath community")
                                .font(.subheadline)
                                .foregroundStyle(ThemeManager.textSecondary)
                        }
                        .padding(.top, 40)

                        VStack(spacing: 16) {
                            TextField("Username", text: $username)
                                .stickDeathTextField()
                                .autocapitalization(.none)

                            TextField("Email", text: $email)
                                .stickDeathTextField()
                                .textContentType(.emailAddress)
                                .keyboardType(.emailAddress)
                                .autocapitalization(.none)

                            SecureField("Password (8+ characters)", text: $password)
                                .stickDeathTextField()

                            SecureField("Confirm Password", text: $confirmPassword)
                                .stickDeathTextField()

                            if !password.isEmpty && !confirmPassword.isEmpty && password != confirmPassword {
                                Text("Passwords don't match")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                        .padding(.horizontal, 24)

                        // Terms
                        Toggle(isOn: $agreedToTerms) {
                            Text("I agree to the Terms of Service & Privacy Policy")
                                .font(.caption)
                                .foregroundStyle(ThemeManager.textSecondary)
                        }
                        .tint(.orange)
                        .toggleStyle(.automatic)
                        .padding(.horizontal, 24)

                        // Error
                        if let error {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(.horizontal, 24)
                        }

                        // Sign Up button
                        Button {
                            Task { await signUp() }
                        } label: {
                            if loading {
                                ProgressView().tint(.black)
                            } else {
                                Text("Create Account")
                                    .font(.headline)
                                    .foregroundStyle(.black)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(isValid ? Color.orange : Color.gray.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 24)
                        .disabled(!isValid || loading)

                        // Upload agreement
                        Text("By creating content, you agree to share animations on StickDeath channels to help build the community.")
                            .font(.caption2)
                            .foregroundStyle(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .padding(.bottom, 40)
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

    func signUp() async {
        loading = true
        error = nil
        do {
            try await auth.signUp(email: email, password: password, username: username)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}
