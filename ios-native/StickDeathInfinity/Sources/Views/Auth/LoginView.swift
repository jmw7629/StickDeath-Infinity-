// LoginView.swift
// v3: Apple Sign-In + Google Sign-In buttons

import SwiftUI
import AuthenticationServices

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
                                .foregroundStyle(.red)
                            Text("Welcome Back")
                                .font(.title.bold())
                        }
                        .padding(.top, 40)

                        // Social sign-in buttons
                        VStack(spacing: 12) {
                            // Sign In with Apple
                            SignInWithAppleButton(.signIn) { request in
                                let _ = auth.generateNonce()
                                request.requestedScopes = [.fullName, .email]
                                request.nonce = auth.sha256Nonce()
                            } onCompletion: { result in
                                handleAppleSignIn(result)
                            }
                            .signInWithAppleButtonStyle(.white)
                            .frame(height: 50)
                            .clipShape(RoundedRectangle(cornerRadius: 14))

                            // Sign In with Google
                            Button {
                                Task { await handleGoogleSignIn() }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "g.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.blue, .white)
                                    Text("Sign in with Google")
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

                        // Email / Password Form
                        VStack(spacing: 16) {
                            TextField("Email", text: $email)
                                .textFieldStyle(.plain)
                                .padding()
                                .background(ThemeManager.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .textContentType(.emailAddress)
                                .keyboardType(.emailAddress)
                                .autocapitalization(.none)

                            SecureField("Password", text: $password)
                                .textFieldStyle(.plain)
                                .padding()
                                .background(ThemeManager.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
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
                        .background(.red)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 24)
                        .disabled(loading || email.isEmpty || password.isEmpty)
                    }
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

    // MARK: - Email/Password Login
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
