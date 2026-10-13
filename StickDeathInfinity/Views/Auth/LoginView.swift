// ═══════════════════════════════════════════════════════════════════
// LoginView — Email/password login
// Matches: src/pages/LoginView.tsx exactly
// - Back button top-left
// - Skull + "Welcome Back" + subtitle
// - Apple/Google SSO buttons first
// - "or sign in with email" divider
// - Email + Password fields
// - Red gradient Sign In button
// - Forgot Password link (neutral confirmation, 60 s cooldown)
// - New-password form after a recovery link opened on this device
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct LoginView: View {
    let onBack: () -> Void
    let onSuccess: () -> Void
    var backLabel = "Back to Welcome"

    @EnvironmentObject var authVM: AuthViewModel
    @State private var email = ""
    @State private var password = ""
    @State private var newPassword = ""
    @State private var showPassword = false
    @State private var showError = false
    /// Local clock tick so the cooldown label counts down without a timer object.
    @State private var now = Date()

    private var resetSecondsRemaining: Int {
        guard let availableAt = authVM.passwordResetAvailableAt else { return 0 }
        return max(0, Int(availableAt.timeIntervalSince(now).rounded(.up)))
    }

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
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(backLabel)
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
                            SDIBrandMark(size: 56)
                                .padding(.top, 16)

                            Text(authVM.passwordRecoveryPending ? "Set a New Password" : "Welcome Back")
                                .font(.specialElite(28))
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .padding(.top, 12)

                            Text(authVM.passwordRecoveryPending ? "Your recovery link was verified on this device" : "Sign in to StickDeath ∞")
                                .font(.system(size: 15))
                                .foregroundColor(.sdTextSecondary)
                        }
                        .padding(.bottom, 32)

                        if authVM.passwordRecoveryPending {
                            recoveryForm
                        } else {
                            signInForm
                        }
                    }
                }
            }
            .frame(maxWidth: 400)
        }
    }

    // MARK: - Recovery

    private var recoveryForm: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("New Password")
                    .font(.specialElite(13))
                    .fontWeight(.medium)
                    .foregroundColor(.sdTextSecondary)
                SDTextField(placeholder: "••••••••", text: $newPassword, icon: "lock", isSecure: !showPassword)
                    .textContentType(.newPassword)
                    .overlay(
                        Button { showPassword.toggle() } label: {
                            Text(showPassword ? "🙈" : "👁").font(.system(size: 16))
                        }.padding(.trailing, 12),
                        alignment: .trailing
                    )
            }
            if let error = authVM.error, showError {
                Text(error).font(.system(size: 13)).foregroundColor(.sdDestructive)
            }
            Button {
                showError = true
                Task { if await authVM.updatePassword(newPassword) { newPassword = ""; onSuccess() } }
            } label: {
                primaryLabel("Save Password")
            }
            .disabled(authVM.isLoading || newPassword.count < 6)
            .opacity(newPassword.count < 6 ? 0.6 : 1)
            .accessibilityIdentifier("auth.recovery.save")
            Text("Use at least 6 characters. Your local projects are not affected by this change.")
                .font(.system(size: 12)).foregroundColor(.sdTextMuted).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Sign in

    private var signInForm: some View {
        VStack(spacing: 0) {
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
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .accessibilityIdentifier("auth.error")
            }

            // Sign In button
            Button {
                showError = true
                Task {
                    if await authVM.signIn(email: email, password: password) {
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

            // Forgot Password: neutral confirmation arrives through the app notice.
            Button {
                showError = true
                Task { await authVM.requestPasswordReset(email: email) }
            } label: {
                Text(resetSecondsRemaining > 0 ? "Reset link requested · retry in \(resetSecondsRemaining) s" : "Forgot Password?")
                    .font(.specialElite(14))
                    .foregroundColor(Color(hex: "#CC1100"))
                    .padding(.vertical, 12)
            }
            .disabled(authVM.isLoading || email.isEmpty || resetSecondsRemaining > 0)
            .opacity(email.isEmpty ? 0.6 : 1)
            .accessibilityIdentifier("auth.forgot-password")
            .padding(.top, 8)
            .task(id: authVM.passwordResetAvailableAt) {
                // Ticks only while a cooldown is active; cancelled when the view leaves.
                while let availableAt = authVM.passwordResetAvailableAt, availableAt > Date(), !Task.isCancelled {
                    now = Date()
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                }
                now = Date()
            }
        }
    }

    private func primaryLabel(_ title: String) -> some View {
        HStack(spacing: 8) {
            if authVM.isLoading {
                ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white)).scaleEffect(0.8)
            } else {
                Text(title).font(.specialElite(16)).fontWeight(.semibold).tracking(1)
            }
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(LinearGradient(colors: [Color(hex: "#CC1100"), Color(hex: "#FF3322")],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
        .cornerRadius(14)
    }
}

/// Shared provider hint copy for Login and Sign Up.
enum ProviderHint {
    /// Public deployment value; the Supabase Azure provider must use the same tenant.
    static func microsoft(tenant: String) -> String {
        switch tenant {
        case "common": return "Microsoft tenant: any work, school or personal account."
        case "organizations": return "Microsoft tenant: work or school accounts only."
        case "consumers": return "Microsoft tenant: personal Microsoft accounts only."
        default: return "Microsoft tenant: \(tenant.prefix(8))… (organization directory)."
        }
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
