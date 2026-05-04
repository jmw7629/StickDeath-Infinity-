// SignUpView.swift
// v2: + Apple Sign-In + Google Sign-In buttons

import SwiftUI
import AuthenticationServices

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
                        // Header
                        VStack(spacing: 8) {
                            Image(systemName: "figure.run")
                                .font(.system(size: 48))
                                .foregroundStyle(.red)
                            Text("Create Account")
                                .font(.title.bold())
                            Text("Join the StickDeath community")
                                .font(.subheadline)
                                .foregroundStyle(.gray)
                        }
                        .padding(.top, 40)

                        // Social sign-up buttons
                        VStack(spacing: 12) {
                            // Sign Up with Apple
                            SignInWithAppleButton(.signUp) { request in
                                let _ = auth.generateNonce()
                                request.requestedScopes = [.fullName, .email]
                                request.nonce = auth.sha256Nonce()
                            } onCompletion: { result in
                                handleAppleSignIn(result)
                            }
                            .signInWithAppleButtonStyle(.white)
                            .frame(height: 50)
                            .clipShape(RoundedRectangle(cornerRadius: 14))

                            // Sign Up with Google
                            Button {
                                Task { await handleGoogleSignIn() }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "g.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.blue, .white)
                                    Text("Sign up with Google")
                                        .font(.headline)
                                        .foregroundStyle(.black)
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                        }
                        .padding(.horizontal, 24)

                        // Divider
                        HStack {
                            Rectangle().fill(Color.gray.opacity(0.3)).frame(height: 1)
                            Text("or").font(.caption).foregroundStyle(.gray)
                            Rectangle().fill(Color.gray.opacity(0.3)).frame(height: 1)
                        }
                        .padding(.horizontal, 32)

                        // Form fields
                        VStack(spacing: 16) {
                            TextField("Username", text: $username)
                                .textFieldStyle(.plain)
                                .padding()
                                .background(ThemeManager.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .autocapitalization(.none)

                            TextField("Email", text: $email)
                                .textFieldStyle(.plain)
                                .padding()
                                .background(ThemeManager.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .textContentType(.emailAddress)
                                .keyboardType(.emailAddress)
                                .autocapitalization(.none)

                            SecureField("Password (8+ characters)", text: $password)
                                .textFieldStyle(.plain)
                                .padding()
                                .background(ThemeManager.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 12))

                            SecureField("Confirm Password", text: $confirmPassword)
                                .textFieldStyle(.plain)
                                .padding()
                                .background(ThemeManager.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 12))

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
                                .foregroundStyle(.gray)
                        }
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
                        .background(isValid ? Color.red : Color.gray)
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
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: - Email/Password Sign Up
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

    // MARK: - Apple Sign In
    func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8),
                  let nonce = auth.rawNonce else {
                error = "Apple Sign-In failed — missing token"
                return
            }
            loading = true
            Task {
                do {
                    try await auth.signInWithApple(idToken: idToken, nonce: nonce)
                    dismiss()
                } catch {
                    self.error = error.localizedDescription
                }
                loading = false
            }
        case .failure(let err):
            if (err as NSError).code != ASAuthorizationError.canceled.rawValue {
                error = err.localizedDescription
            }
        }
    }

    // MARK: - Google Sign In
    func handleGoogleSignIn() async {
        loading = true
        error = nil
        do {
            try await auth.signInWithGoogle()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}
