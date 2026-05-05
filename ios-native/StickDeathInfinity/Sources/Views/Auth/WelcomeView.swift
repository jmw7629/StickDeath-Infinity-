// WelcomeView.swift
// Pixel-perfect match to reference: skull 💀, STICKDEATH ∞, Sign In + Create Account
// Background: #0a0a0f, brand red: #dc2626

import SwiftUI

struct WelcomeView: View {
    @State private var showLogin = false
    @State private var showSignUp = false
    @State private var opacity: Double = 0

    var body: some View {
        ZStack {
            Color(hex: "#0a0a0f").ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // ── Branding ──
                VStack(spacing: 8) {
                    Text("💀")
                        .font(.system(size: 48))

                    HStack(spacing: 0) {
                        Text("STICK")
                            .foregroundStyle(ThemeManager.brand)
                        Text("DEATH")
                            .foregroundStyle(.white)
                        Text(" ∞")
                            .foregroundStyle(.white)
                    }
                    .font(.custom("SpecialElite-Regular", size: 28, relativeTo: .title))
                    .fontWeight(.black)
                    .tracking(2)

                    Text("Create. Animate. Annihilate.")
                        .font(.custom("SpecialElite-Regular", size: 14, relativeTo: .caption))
                        .foregroundStyle(Color(hex: "#9090a8"))
                        .tracking(1)
                }
                .padding(.bottom, 48)

                // ── Buttons ──
                VStack(spacing: 14) {
                    Button {
                        showLogin = true
                    } label: {
                        Text("Sign In")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 280, height: 48)
                            .background(ThemeManager.brand)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    Button {
                        showSignUp = true
                    } label: {
                        Text("Create Account")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 280, height: 48)
                            .background(Color.clear)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color(hex: "#2a2a3a"), lineWidth: 1)
                            )
                    }
                }

                Spacer()
                    .frame(height: 120)
            }
            .opacity(opacity)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.4)) {
                opacity = 1.0
            }
        }
        .fullScreenCover(isPresented: $showLogin) {
            LoginView()
        }
        .fullScreenCover(isPresented: $showSignUp) {
            SignUpView()
        }
    }
}
