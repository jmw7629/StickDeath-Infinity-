// ═══════════════════════════════════════════════════════════════════
// PublishSheet — Metadata editing + confirmation for SDI YouTube publishing
// Shows before submission. User confirms before their animation is
// submitted to the official StickDeath Infinity YouTube channel.
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct PublishSheet: View {
    @ObservedObject var vm: StudioViewModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ZStack {
            Color(hex: "#0A0A0F").ignoresSafeArea()

            VStack(spacing: 0) {
                // Drag handle
                Capsule()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 36, height: 4)
                    .padding(.top, 8)

                // Header
                HStack {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundColor(Color(hex: "#DC2626"))
                    Text("Publish to SDI YouTube")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                ScrollView {
                    VStack(spacing: 16) {
                        // Info banner
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: "info.circle.fill")
                                    .foregroundColor(Color(hex: "#DC2626"))
                                Text("Official Channel Publishing")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white)
                            }
                            Text("Your animation will be submitted to the official StickDeath Infinity YouTube channel. A server will handle the upload — your YouTube credentials are never stored on your device.")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.5))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(hex: "#12121a"))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color(hex: "#DC2626").opacity(0.3), lineWidth: 1)
                                )
                        )

                        // Title
                        VStack(alignment: .leading, spacing: 6) {
                            Text("TITLE")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.4))
                                .tracking(1)
                            TextField("Animation title", text: $vm.publishTitle)
                                .font(.system(size: 14, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(12)
                                .background(Color(hex: "#12121a"))
                                .cornerRadius(10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                )
                        }

                        // Description
                        VStack(alignment: .leading, spacing: 6) {
                            Text("DESCRIPTION")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.4))
                                .tracking(1)
                            TextEditor(text: $vm.publishDescription)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.white)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 80, maxHeight: 140)
                                .padding(12)
                                .background(Color(hex: "#12121a"))
                                .cornerRadius(10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                )
                                .overlay(
                                    Group {
                                        if vm.publishDescription.isEmpty {
                                            Text("Describe your animation...")
                                                .font(.system(size: 13, design: .monospaced))
                                                .foregroundColor(.white.opacity(0.25))
                                                .padding(.leading, 28)
                                                .padding(.top, 20)
                                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                        }
                                    }
                                )
                        }

                        // Tags
                        VStack(alignment: .leading, spacing: 6) {
                            Text("TAGS")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.4))
                                .tracking(1)
                            TextField("Comma-separated tags", text: $vm.publishTagsInput)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(12)
                                .background(Color(hex: "#12121a"))
                                .cornerRadius(10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                )
                        }

                        // Visibility
                        VStack(alignment: .leading, spacing: 6) {
                            Text("VISIBILITY")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.4))
                                .tracking(1)
                            HStack(spacing: 8) {
                                ForEach(PublishVisibility.allCases, id: \.self) { vis in
                                    Button(action: { vm.publishVisibility = vis }) {
                                        VStack(spacing: 3) {
                                            Image(systemName: vis.icon)
                                                .font(.system(size: 12))
                                            Text(vis.displayName)
                                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        }
                                        .foregroundColor(vm.publishVisibility == vis ? .white : .white.opacity(0.35))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(Color(hex: "#12121a"))
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 8)
                                                        .stroke(
                                                            vm.publishVisibility == vis ? Color(hex: "#DC2626") : Color.white.opacity(0.08),
                                                            lineWidth: vm.publishVisibility == vis ? 2 : 1
                                                        )
                                                )
                                        )
                                    }
                                }
                            }
                        }

                        // Audience
                        VStack(alignment: .leading, spacing: 6) {
                            Text("AUDIENCE")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.4))
                                .tracking(1)
                            VStack(spacing: 4) {
                                ForEach(PublishAudience.allCases, id: \.self) { aud in
                                    Button(action: { vm.publishAudience = aud }) {
                                        HStack {
                                            Image(systemName: vm.publishAudience == aud ? "checkmark.circle.fill" : "circle")
                                                .foregroundColor(vm.publishAudience == aud ? Color(hex: "#DC2626") : .white.opacity(0.3))
                                            Text(aud.displayName)
                                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                                .foregroundColor(.white)
                                            Spacer()
                                        }
                                        .padding(12)
                                        .background(Color(hex: "#12121a"))
                                        .cornerRadius(8)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(
                                                    vm.publishAudience == aud ? Color(hex: "#DC2626") : Color.white.opacity(0.08),
                                                    lineWidth: vm.publishAudience == aud ? 2 : 1
                                                )
                                        )
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                }

                // Submit button
                VStack(spacing: 8) {
                    Divider().background(Color.white.opacity(0.06))

                    Button(action: {
                        Task {
                            await vm.submitPublish()
                            dismiss()
                        }
                    }) {
                        HStack(spacing: 8) {
                            if vm.isPublishing {
                                ProgressView()
                                    .tint(.white)
                            }
                            Image(systemName: "arrow.up.circle.fill")
                            Text(vm.isPublishing ? "SUBMITTING..." : "PUBLISH TO SDI YOUTUBE")
                        }
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(vm.publishTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                      ? Color.gray
                                      : Color(hex: "#DC2626"))
                        )
                    }
                    .disabled(vm.publishTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isPublishing)
                    .padding(.horizontal, 16)

                    Text("Publishing submits to the official SDI channel. Exported file remains available for your own sharing.")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.3))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
            }
        }
    }
}
