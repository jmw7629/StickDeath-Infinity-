// SignUpView.swift
// Pixel-perfect to reference: skull 💀, "Create Account", Name/Username/Email/Password

import SwiftUI
import GoogleSignIn
import AuthenticationServices

struct SignUpView: View {
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var username = ""
    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color(hex: "#0a0a0f").ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Spacer(minLength: 60)

                    // ── Header ──
                    VStack(spacing: 8) {
                        Text("💀")
                            .font(.system(size: 40))

                        Text("Create Account")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.white)

                        Text("Join the StickDeath community")
                            .font(.system(size: 14))
                            .foregroundStyle(Color(hex: "#9090a8"))
                    }
                    .padding(.bottom, 32)

                    // ── Apple Sign Up ──
                    SignInWithAppleButton(.signUp) { request in
                        request.requestedScopes = [.email, .fullName]
                    } onCompletion: { result in
                        Task { await auth.handleAppleSignIn(result: result) }
                    }
                    .signInWithAppleButtonStyle(.white)
                    .frame(height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 40)
                    .padding(.bottom, 10)

                    // ── Google Sign Up ──
                    Button {
                        Task { await auth.signInWithGoogle() }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "g.circle.fill")
                                .font(.system(size: 20))
                            Text("Sign up with Google")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 16)

                    // ── Divider ──
                    HStack {
                        Rectangle().fill(Color(hex: "#2a2a3a")).frame(height: 1)
                        Text("or")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(hex: "#9090a8"))
                            .padding(.horizontal, 8)
                        Rectangle().fill(Color(hex: "#2a2a3a")).frame(height: 1)
                    }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 16)

                    // ── Form Fields ──
                    VStack(spacing: 12) {
                        StyledTextField(placeholder: "Name", text: $name, autocap: .words)
                        StyledTextField(placeholder: "Username", text: $username)
                        StyledTextField(placeholder: "Email", text: $email, keyboardType: .emailAddress)
                        StyledSecureField(placeholder: "Password", text: $password)
                    }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 20)

                    // ── Error ──
                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.bottom, 8)
                    }

                    // ── Create Account Button ──
                    Button {
                        Task { await createAccount() }
                    } label: {
                        Group {
                            if isLoading {
                                ProgressView().tint(.white)
                            } else {
                                Text("Create Account")
                                    .font(.system(size: 16, weight: .semibold))
                            }
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(ThemeManager.brand)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(isLoading)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 16)

                    // ── Switch to Sign In ──
                    HStack(spacing: 4) {
                        Text("Already have an account?")
                            .foregroundStyle(Color(hex: "#9090a8"))
                        Button("Sign In") {
                            dismiss()
                        }
                        .foregroundStyle(ThemeManager.brand)
                    }
                    .font(.system(size: 14))

                    Spacer(minLength: 40)
                }
            }
        }
    }

    private func createAccount() async {
        isLoading = true
        errorMessage = nil
        do {
            try await auth.signUp(email: email, password: password, name: name, username: username)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
