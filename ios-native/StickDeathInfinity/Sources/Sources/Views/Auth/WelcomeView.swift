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
                        .foregroundStyle(.orange)
                    Text("StickDeath")
                        .font(.system(size: 40, weight: .black))
                        .foregroundStyle(.white)
                    Text("INFINITY")
                        .font(.system(size: 18, weight: .medium))
                        .tracking(8)
                        .foregroundStyle(.orange)
                    Text("Create. Animate. Share.")
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
                            .background(.orange)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }

                    Button {
                        showLogin = true
                    } label: {
                        Text("I already have an account")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.orange.opacity(0.1))
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
