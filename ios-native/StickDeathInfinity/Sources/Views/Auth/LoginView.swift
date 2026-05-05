// LoginView.swift
// Pixel-perfect to reference: skull 💀, "Welcome Back", dark input fields, red Sign In

import SwiftUI
import GoogleSignIn
import AuthenticationServices

struct LoginView: View {
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color(hex: "#0a0a0f").ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // ── Header ──
                VStack(spacing: 8) {
                    Text("💀")
                        .font(.system(size: 40))

                    Text("Welcome Back")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)

                    Text("Sign in to continue")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(hex: "#9090a8"))
                }
                .padding(.bottom, 40)

                // ── Apple Sign In ──
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.email, .fullName]
                } onCompletion: { result in
                    Task { await auth.handleAppleSignIn(result: result) }
                }
                .signInWithAppleButtonStyle(.white)
                .frame(height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 40)
                .padding(.bottom, 10)

                // ── Google Sign In ──
                Button {
                    Task { await auth.signInWithGoogle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "g.circle.fill")
                            .font(.system(size: 20))
                        Text("Sign in with Google")
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

                // ── Sign In Button ──
                Button {
                    Task { await signIn() }
                } label: {
                    Group {
                        if isLoading {
                            ProgressView().tint(.white)
                        } else {
                            Text("Sign In")
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

                // ── Switch to Sign Up ──
                HStack(spacing: 4) {
                    Text("Don't have an account?")
                        .foregroundStyle(Color(hex: "#9090a8"))
                    Button("Sign Up") {
                        dismiss()
                    }
                    .foregroundStyle(ThemeManager.brand)
                }
                .font(.system(size: 14))

                Spacer()
                    .frame(height: 80)
            }
        }
    }

    private func signIn() async {
        isLoading = true
        errorMessage = nil
        do {
            try await auth.signIn(email: email, password: password)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - Styled Input Fields (dark theme, matching reference)

struct StyledTextField: View {
    let placeholder: String
    @Binding var text: String
    var keyboardType: UIKeyboardType = .default
    var autocap: TextInputAutocapitalization = .never

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Color(hex: "#5a5a6e")))
            .keyboardType(keyboardType)
            .textInputAutocapitalization(autocap)
            .autocorrectionDisabled()
            .font(.system(size: 16))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(Color(hex: "#111118"))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(hex: "#2a2a3a"), lineWidth: 1)
            )
    }
}

struct StyledSecureField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        SecureField("", text: $text, prompt: Text(placeholder).foregroundStyle(Color(hex: "#5a5a6e")))
            .font(.system(size: 16))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(Color(hex: "#111118"))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(hex: "#2a2a3a"), lineWidth: 1)
            )
    }
}
