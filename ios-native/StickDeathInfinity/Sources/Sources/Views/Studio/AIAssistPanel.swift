// AIAssistPanel.swift
// Floating AI assistant panel (Pro only)

import SwiftUI

struct AIAssistPanel: View {
    @ObservedObject var vm: EditorViewModel
    @State private var prompt = ""
    @State private var loading = false

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "sparkles").foregroundStyle(.purple)
                        Text("AI Assist").font(.headline)
                        Spacer()
                        Button { vm.showAIPanel = false } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.gray)
                        }
                    }

                    if let suggestion = vm.aiSuggestion {
                        Text(suggestion)
                            .font(.subheadline)
                            .padding(10)
                            .background(ThemeManager.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    HStack {
                        TextField("Ask AI for help...", text: $prompt)
                            .textFieldStyle(.plain)
                            .padding(10)
                            .background(ThemeManager.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 10))

                        Button {
                            guard !prompt.isEmpty else { return }
                            loading = true
                            Task {
                                await vm.requestAIAssist(prompt: prompt)
                                prompt = ""
                                loading = false
                            }
                        } label: {
                            if loading {
                                ProgressView().tint(.purple)
                            } else {
                                Image(systemName: "paperplane.fill").foregroundStyle(.purple)
                            }
                        }
                        .disabled(prompt.isEmpty || loading)
                    }

                    // Suggested prompts
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            SuggestChip(text: "Make a walking animation") { prompt = "Make a walking animation" }
                            SuggestChip(text: "Add a fighting pose") { prompt = "Add a fighting pose" }
                            SuggestChip(text: "Smooth this motion") { prompt = "Smooth the motion between frames" }
                        }
                    }
                }
                .padding()
                .frame(width: 340)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding()
            }
        }
    }
}

struct SuggestChip: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.caption2)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.purple.opacity(0.15))
                .foregroundStyle(.purple)
                .clipShape(Capsule())
        }
    }
}
