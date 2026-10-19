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
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back to Welcome")
                    .accessibilityIdentifier("auth.back")
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .overlay(
                    Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                        .allowsHitTesting(false),
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
                            VStack(spacing: 4) {
                                SocialAuthButton(
                                    icon: "apple.logo",
                                    title: "Continue with Apple",
                                    action: { showError = true; Task { if await authVM.signInWithApple() { onSuccess() } } }
                                )
                                .disabled(authVM.isLoading || authVM.appleSignInUnavailableReason != nil)
                                .accessibilityIdentifier("auth.provider.apple")
                                if let reason = authVM.appleSignInUnavailableReason {
                                    Text(reason).font(.caption).foregroundColor(.sdTextSecondary)
                                }
                            }
                            ForEach(AppConfig.OAuthProvider.allCases, id: \.self) { provider in
                                VStack(spacing: 4) {
                                    SocialAuthButton(
                                        icon: provider == .google ? "g.circle.fill" : provider == .github ? "chevron.left.forwardslash.chevron.right" : "square.grid.2x2.fill",
                                        title: "Continue with \(provider.title)",
                                        action: {
                                            showError = true
                                            Task { if await authVM.signIn(provider: provider) { onSuccess() } }
                                        }
                                    )
                                    .disabled(authVM.isLoading || authVM.providerUnavailableReason(provider) != nil)
                                    .accessibilityIdentifier("auth.provider.\(provider.rawValue)")
                                    if let reason = authVM.providerUnavailableReason(provider) {
                                        Text(reason).font(.caption).foregroundColor(.sdTextSecondary)
                                    } else if provider == .microsoft, let tenant = authVM.microsoftTenant {
                                        Text(ProviderHint.microsoft(tenant: tenant)).font(.caption).foregroundColor(.sdTextSecondary)
                                            .multilineTextAlignment(.center)
                                    }
                                }
                            }
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
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                                .padding(.top, 12)
                                .accessibilityIdentifier("auth.error")
                        }
                        // Confirmation pending is not an error: the account exists but
                        // has no session until the email address is confirmed.
                        if let notice = authVM.notice, showError {
                            Text(notice)
                                .font(.system(size: 13))
                                .foregroundColor(.sdTextSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                                .padding(.top, 12)
                                .accessibilityIdentifier("auth.signup.notice")
                        }

                        // Create Account button
                        Button {
                            showError = true
                            Task {
                                if await authVM.signUp(email: email, password: password, username: username) { onSuccess() }
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

                        // Policies (#273). Reading them here records nothing; the
                        // current versions are accepted after sign-up in the guide
                        // or Profile → Privacy and policies, recorded by the server.
                        VStack(spacing: 6) {
                            Text("Review the Terms of Service and Privacy Policy. After your account is created you can accept their current versions; Studio works without an account either way.")
                                .font(.system(size: 12))
                                .foregroundColor(.sdTextMuted)
                                .multilineTextAlignment(.center)
                                .lineSpacing(2)
                            HStack(spacing: 16) {
                                Link("Terms of Service", destination: PolicyLinks.terms)
                                    .frame(minHeight: 44)
                                    .accessibilityIdentifier("auth.signup.policy.terms")
                                Link("Privacy Policy", destination: PolicyLinks.privacy)
                                    .frame(minHeight: 44)
                                    .accessibilityIdentifier("auth.signup.policy.privacy")
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.sdRed)
                        }
                        .padding(.horizontal, 40)
                        .padding(.top, 16)
                        .padding(.bottom, 32)
                    }
                }
            }
            .frame(maxWidth: 400)
        }
    }
}
