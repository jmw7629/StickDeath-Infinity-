// WelcomeView.swift
// First screen users see — sign up or log in

import SwiftUI

struct WelcomeView: View {
    @State private var showLogin = false
    @State private var showSignUp = false

    var body: some View {
        ZStack {
            // Background
            LinearGradient(
                colors: [Color.black, Color(hex: "#1a0a00")],
                startPoint: .top, endPoint: .bottom
            ).ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                // Logo
                VStack(spacing: 12) {
                    Image(systemName: "figure.run")
                        .font(.system(size: 80))
                        .foregroundStyle(.red)
                    Text("STICKDEATH")
                        .font(.system(size: 40, weight: .black))
                        .foregroundStyle(.white)
                    Text("∞")
                        .font(.system(size: 48, weight: .ultraLight))
                        .foregroundStyle(.red)
                    Text("Create. Animate. Annihilate.")
                        .font(.subheadline)
                        .foregroundStyle(.gray)
                }

                Spacer()

                // Buttons
                VStack(spacing: 12) {
                    Button {
                        showSignUp = true
                    } label: {
                        Text("Get Started")
                            .font(.headline)
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(.red)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }

                    Button {
                        showLogin = true
                    } label: {
                        Text("I already have an account")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.red.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
        .sheet(isPresented: $showLogin) {
            LoginView()
        }
        .sheet(isPresented: $showSignUp) {
            SignUpView()
        }
    }
}
