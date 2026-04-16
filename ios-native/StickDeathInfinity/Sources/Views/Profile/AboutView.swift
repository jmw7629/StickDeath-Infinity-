// AboutView.swift
// About page — version, open source credits, help center links
// Ref: FlipaClip About page, adapted to StickDeath ∞ dark theme

import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.openURL) var openURL

    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    private let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

    var body: some View {
        NavigationStack {
            ZStack {
                ThemeManager.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // App header
                        appHeader

                        // App info
                        infoSection

                        // Help Center
                        helpCenterSection

                        // Open Source
                        openSourceSection

                        // Social links
                        socialSection

                        // Footer
                        Text("© 2026 Willis NMB Designs\nNorth Myrtle Beach, SC")
                            .font(.system(size: 10))
                            .foregroundStyle(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.top, 8)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .foregroundStyle(.white)
                    }
                }
            }
        }
    }

    // MARK: - App Header

    private var appHeader: some View {
        VStack(spacing: 8) {
            // Skull icon
            Image(systemName: "skull.fill")
                .font(.system(size: 44))
                .foregroundStyle(.red)

            Text("STICKDEATH ∞")
                .font(.custom("SpecialElite-Regular", size: 22))
                .foregroundStyle(.white)

            Text("Create. Animate. Annihilate.")
                .font(.custom("SpecialElite-Regular", size: 12))
                .foregroundStyle(.gray)
        }
        .padding(.vertical, 12)
    }

    // MARK: - Info Section

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("App")

            VStack(spacing: 0) {
                linkRow("Privacy Policy", icon: "hand.raised", url: "https://stickdeath.app/privacy")
                Divider().opacity(0.15)
                linkRow("Terms of Use", icon: "doc.text", url: "https://stickdeath.app/terms")
                Divider().opacity(0.15)
                infoRow("Version", value: "\(version) (\(build))")
            }
            .background(ThemeManager.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Help Center

    private var helpCenterSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Help Center")

            HStack(spacing: 10) {
                helpCard("Support", icon: "questionmark.circle.fill", color: .red) {
                    openURL(URL(string: "mailto:joseph@willisnmb.com?subject=StickDeath%20Support")!)
                }
                helpCard("Community", icon: "person.3.fill", color: .orange) {
                    openURL(URL(string: "https://stickdeath.app/community")!)
                }
                helpCard("Bugs", icon: "ladybug.fill", color: .purple) {
                    openURL(URL(string: "mailto:joseph@willisnmb.com?subject=StickDeath%20Bug%20Report")!)
                }
            }
        }
    }

    // MARK: - Open Source

    private var openSourceSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Open Source")

            VStack(spacing: 0) {
                openSourceRow("FFmpeg", license: "LGPL 2.1", url: "https://ffmpeg.org")
                Divider().opacity(0.15)
                openSourceRow("Skia", license: "BSD 3-Clause", url: "https://skia.org")
                Divider().opacity(0.15)
                openSourceRow("SDL", license: "zlib License", url: "https://libsdl.org")
                Divider().opacity(0.15)
                openSourceRow("Zstandard", license: "BSD + GPLv2", url: "https://facebook.github.io/zstd")
                Divider().opacity(0.15)
                openSourceRow("Supabase Swift", license: "MIT", url: "https://github.com/supabase/supabase-swift")
                Divider().opacity(0.15)
                openSourceRow("Stripe iOS SDK", license: "MIT", url: "https://github.com/stripe/stripe-ios")
            }
            .background(ThemeManager.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Social

    private var socialSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Follow Us")

            HStack(spacing: 16) {
                Spacer()
                socialButton("Instagram", icon: "camera.fill") {
                    openURL(URL(string: "https://instagram.com/stickdeath")!)
                }
                socialButton("YouTube", icon: "play.rectangle.fill") {
                    openURL(URL(string: "https://youtube.com/@stickdeath")!)
                }
                socialButton("TikTok", icon: "music.note") {
                    openURL(URL(string: "https://tiktok.com/@stickdeath")!)
                }
                socialButton("X", icon: "bubble.left.fill") {
                    openURL(URL(string: "https://x.com/stickdeath")!)
                }
                Spacer()
            }
        }
    }

    // MARK: - Components

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.custom("SpecialElite-Regular", size: 12))
            .foregroundStyle(.red)
            .textCase(.uppercase)
            .padding(.bottom, 8)
    }

    private func linkRow(_ title: String, icon: String, url: String) -> some View {
        Button {
            if let u = URL(string: url) { openURL(u) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(.red)
                    .frame(width: 28)
                Text(title)
                    .font(.custom("SpecialElite-Regular", size: 14))
                    .foregroundStyle(.white)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption2)
                    .foregroundStyle(.gray)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private func infoRow(_ title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle")
                .font(.system(size: 14))
                .foregroundStyle(.red)
                .frame(width: 28)
            Text(title)
                .font(.custom("SpecialElite-Regular", size: 14))
                .foregroundStyle(.white)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.red)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func helpCard(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(color)
                Text(title)
                    .font(.custom("SpecialElite-Regular", size: 11))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(ThemeManager.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func openSourceRow(_ name: String, license: String, url: String) -> some View {
        Button {
            if let u = URL(string: url) { openURL(u) }
        } label: {
            HStack {
                Text(name)
                    .font(.custom("SpecialElite-Regular", size: 13))
                    .foregroundStyle(.white)
                Spacer()
                Text(license)
                    .font(.system(size: 10))
                    .foregroundStyle(.gray)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.gray)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func socialButton(_ name: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(ThemeManager.surface)
                .clipShape(Circle())
        }
    }
}
