// ═══════════════════════════════════════════════════════════════════
// SignUpView — Account creation
// Matches: src/pages/SignUpView.tsx exactly
// - Back button top-left
// - Skull + "Join the Carnage" + "Create your StickDeath ∞ account"
// - Apple/Google SSO first
// - "or create with email" divider
// - Username, Email, Password, Confirm Password fields
// - Red gradient "Create Account 👤+" button
// - Terms text at bottom
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct SignUpView: View {
    let onBack: () -> Void
    let onSuccess: () -> Void

    @EnvironmentObject var authVM: AuthViewModel
    @State private var username = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var showPw = false
    @State private var showCpw = false
    @State private var showError = false
    @State private var visible = false

    private var passwordsMatch: Bool { password == confirmPassword && !password.isEmpty }
    private var canSubmit: Bool {
        !username.isEmpty && !email.isEmpty && passwordsMatch && password.count >= 6 && !authVM.isLoading
    }

    var body: some View {
        ZStack {
            Color.sdBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top bar
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

                            Text("Join the Carnage")
                                .font(.specialElite(28))
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .padding(.top, 12)

                            Text("Create your StickDeath ∞ account")
                                .font(.system(size: 15))
                                .foregroundColor(.sdTextSecondary)
                        }
                        .padding(.bottom, 24)

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
                        .padding(.bottom, 20)

                        // Divider
                        HStack(spacing: 12) {
                            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
                            Text("or create with email")
                                .font(.specialElite(12))
                                .foregroundColor(.sdTextMuted)
                            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 20)

                        // Form fields
                        VStack(spacing: 16) {
                            // Username
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Username")
                                    .font(.specialElite(13))
                                    .fontWeight(.medium)
                                    .foregroundColor(.sdTextSecondary)

                                SDTextField(placeholder: "Choose a username", text: $username, icon: "person")
                                    .autocapitalization(.none)
                            }

                            // Email
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Email")
                                    .font(.specialElite(13))
                                    .fontWeight(.medium)
                                    .foregroundColor(.sdTextSecondary)

                                SDTextField(placeholder: "your@email.com", text: $email, icon: "envelope")
                                    .textContentType(.emailAddress)
                                    .autocapitalization(.none)
                            }

                            // Password
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Password")
                                    .font(.specialElite(13))
                                    .fontWeight(.medium)
                                    .foregroundColor(.sdTextSecondary)

                                SDTextField(placeholder: "••••••••", text: $password, icon: "lock", isSecure: !showPw)
                                    .textContentType(.newPassword)
                                    .overlay(
                                        Button { showPw.toggle() } label: {
                                            Text(showPw ? "🙈" : "👁").font(.system(size: 16))
                                        }.padding(.trailing, 12),
                                        alignment: .trailing
                                    )
                            }

                            // Confirm Password
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Confirm Password")
                                    .font(.specialElite(13))
                                    .fontWeight(.medium)
                                    .foregroundColor(.sdTextSecondary)

                                SDTextField(placeholder: "••••••••", text: $confirmPassword, icon: "lock.fill", isSecure: !showCpw)
                                    .textContentType(.newPassword)
                                    .overlay(
                                        Button { showCpw.toggle() } label: {
                                            Text(showCpw ? "🙈" : "👁").font(.system(size: 16))
                                        }.padding(.trailing, 12),
                                        alignment: .trailing
                                    )
                            }

                            if !confirmPassword.isEmpty && !passwordsMatch {
                                Text("Passwords don't match")
                                    .font(.system(size: 12))
                                    .foregroundColor(.sdDestructive)
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

                        // Create Account button
                        Button {
                            showError = true
                            Task {
                                await authVM.signUp(email: email, password: password, username: username)
                                if authVM.isAuthenticated { onSuccess() }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                if authVM.isLoading {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        .scaleEffect(0.8)
                                } else {
                                    Text("Create Account 👤+")
                                        .font(.specialElite(16))
                                        .fontWeight(.semibold)
                                        .tracking(1)
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
                        .disabled(!canSubmit)
                        .opacity(canSubmit ? 1 : 0.5)
                        .padding(.horizontal, 24)
                        .padding(.top, 24)

                        // Terms
                        Text("By creating an account, you agree to our Terms of Service")
                            .font(.system(size: 12))
                            .foregroundColor(.sdTextMuted)
                            .multilineTextAlignment(.center)
                            .lineSpacing(2)
                            .padding(.horizontal, 40)
                            .padding(.top, 16)
                            .padding(.bottom, 32)
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
