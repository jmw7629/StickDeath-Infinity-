// ═══════════════════════════════════════════════════════════════════
// LoginView — Email/password login
// Matches: src/pages/LoginView.tsx exactly
// - Back button top-left
// - Skull + "Welcome Back" + subtitle
// - Apple/Google SSO buttons first
// - "or sign in with email" divider
// - Email + Password fields
// - Red gradient Sign In button
// - Forgot Password link
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct LoginView: View {
    let onBack: () -> Void
    let onSuccess: () -> Void

    @EnvironmentObject var authVM: AuthViewModel
    @State private var email = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var showError = false
    @State private var visible = false

    var body: some View {
        ZStack {
            Color.sdBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top bar with back button
                HStack {
                    Button(action: onBack) {
                        Text("‹")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .overlay(
                    Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1),
                    alignment: .bottom
                )

                ScrollView {
                    VStack(spacing: 0) {
                        // Header
                        VStack(spacing: 6) {
                            Text("☠️")
                                .font(.system(size: 56))
                                .padding(.top, 16)

                            Text("Welcome Back")
                                .font(.specialElite(28))
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .padding(.top, 12)

                            Text("Sign in to StickDeath ∞")
                                .font(.system(size: 15))
                                .foregroundColor(.sdTextSecondary)
                        }
                        .padding(.bottom, 32)

                        // SSO Buttons (first, matching React order)
                        VStack(spacing: 12) {
                            SocialAuthButton(
                                icon: "apple.logo",
                                title: "Continue with Apple",
                                action: { Task { await authVM.signInWithApple() } }
                            )
                            SocialAuthButton(
                                icon: "g.circle.fill",
                                title: "Continue with Google",
                                action: { Task { await authVM.signInWithGoogle() } }
                            )
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)

                        // Divider
                        HStack(spacing: 12) {
                            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
                            Text("or sign in with email")
                                .font(.specialElite(12))
                                .foregroundColor(.sdTextMuted)
                            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)

                        // Email / Password fields
                        VStack(spacing: 16) {
                            // Email
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Email")
                                    .font(.specialElite(13))
                                    .fontWeight(.medium)
                                    .foregroundColor(.sdTextSecondary)

                                SDTextField(
                                    placeholder: "user@stickdeath.com",
                                    text: $email,
                                    icon: "envelope"
                                )
                                .textContentType(.emailAddress)
                                .autocapitalization(.none)
                            }

                            // Password
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Password")
                                    .font(.specialElite(13))
                                    .fontWeight(.medium)
                                    .foregroundColor(.sdTextSecondary)

                                SDTextField(
                                    placeholder: "••••••••",
                                    text: $password,
                                    icon: "lock",
                                    isSecure: !showPassword
                                )
                                .textContentType(.password)
                                .overlay(
                                    Button {
                                        showPassword.toggle()
                                    } label: {
                                        Text(showPassword ? "🙈" : "👁")
                                            .font(.system(size: 16))
                                    }
                                    .padding(.trailing, 12),
                                    alignment: .trailing
                                )
                            }
                        }
                        .padding(.horizontal, 24)

                        // Error
                        if let error = authVM.error, showError {
                            Text(error)
                                .font(.system(size: 13))
                                .foregroundColor(.sdDestructive)
                                .padding(.top, 12)
                        }

                        // Sign In button
                        Button {
                            showError = true
                            Task {
                                await authVM.signIn(email: email, password: password)
                                if authVM.isAuthenticated {
                                    onSuccess()
                                }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                if authVM.isLoading {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        .scaleEffect(0.8)
                                } else {
                                    Text("Sign In")
                                        .font(.specialElite(16))
                                        .fontWeight(.semibold)
                                        .tracking(1)
                                    Text("→")
                                        .font(.system(size: 18))
                                }
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                LinearGradient(
                                    colors: [Color(hex: "#CC1100"), Color(hex: "#FF3322")],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .cornerRadius(14)
                        }
                        .disabled(authVM.isLoading || email.isEmpty || password.isEmpty)
                        .opacity(email.isEmpty || password.isEmpty ? 0.6 : 1)
                        .padding(.horizontal, 24)
                        .padding(.top, 24)

                        // Forgot Password
                        Button {
                            if !email.isEmpty {
                                Task { try? await AuthService.shared.resetPassword(email: email) }
                            }
                        } label: {
                            Text("Forgot Password?")
                                .font(.specialElite(14))
                                .foregroundColor(Color(hex: "#CC1100"))
                                .padding(.vertical, 12)
                        }
                        .padding(.top, 8)
                    }
                }
            }
            .frame(maxWidth: 400)
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 20)
            .animation(.easeOut(duration: 0.4), value: visible)
        }
        .onAppear { visible = true }
    }
}

// MARK: - Social Auth Button
struct SocialAuthButton: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                Text(title)
                    .font(.specialElite(15))
                    .fontWeight(.semibold)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.white.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .cornerRadius(10)
        }
    }
}
