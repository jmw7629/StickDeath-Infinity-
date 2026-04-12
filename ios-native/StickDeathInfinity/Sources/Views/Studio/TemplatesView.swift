// TemplatesView.swift
// Starter animation templates to help new users get going fast

import SwiftUI

struct AnimationTemplate: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
    let description: String
    let frameCount: Int
    let figureCount: Int
    let category: String
    let isPro: Bool
    let color: Color
}

struct TemplatesView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var auth: AuthManager
    let onSelect: (AnimationTemplate) -> Void

    @State private var selectedCategory = "All"

    private let categories = ["All", "Action", "Comedy", "Dance", "Effects", "Tutorial"]

    private let templates: [AnimationTemplate] = [
        // Free templates
        AnimationTemplate(name: "Walk Cycle", icon: "figure.walk", description: "Basic 8-frame walking animation", frameCount: 8, figureCount: 1, category: "Tutorial", isPro: false, color: .cyan),
        AnimationTemplate(name: "Idle Stand", icon: "figure.stand", description: "Subtle idle breathing animation", frameCount: 6, figureCount: 1, category: "Tutorial", isPro: false, color: .green),
        AnimationTemplate(name: "Jump", icon: "figure.jumprope", description: "Full jump arc with landing", frameCount: 10, figureCount: 1, category: "Action", isPro: false, color: .orange),
        AnimationTemplate(name: "Wave Hello", icon: "hand.wave.fill", description: "Friendly waving gesture", frameCount: 6, figureCount: 1, category: "Comedy", isPro: false, color: .yellow),
        AnimationTemplate(name: "Simple Fight", icon: "figure.boxing", description: "Two figures, punch exchange", frameCount: 12, figureCount: 2, category: "Action", isPro: false, color: .red),

        // Pro templates
        AnimationTemplate(name: "Epic Sword Fight", icon: "figure.fencing", description: "Dynamic 2-figure sword duel", frameCount: 24, figureCount: 2, category: "Action", isPro: true, color: .red),
        AnimationTemplate(name: "Dance Party", icon: "figure.dance", description: "3 figures dancing in sync", frameCount: 16, figureCount: 3, category: "Dance", isPro: true, color: .purple),
        AnimationTemplate(name: "Running Chase", icon: "figure.run", description: "Fast-paced chase scene", frameCount: 20, figureCount: 2, category: "Action", isPro: true, color: .orange),
        AnimationTemplate(name: "Backflip", icon: "figure.gymnastics", description: "Complete backflip rotation", frameCount: 14, figureCount: 1, category: "Effects", isPro: true, color: .cyan),
        AnimationTemplate(name: "Comedy Skit", icon: "theatermasks.fill", description: "Slap comedy with 2 characters", frameCount: 18, figureCount: 2, category: "Comedy", isPro: true, color: .yellow),
        AnimationTemplate(name: "Group Battle", icon: "figure.martial.arts", description: "4-figure battle royale", frameCount: 30, figureCount: 4, category: "Action", isPro: true, color: .red),
        AnimationTemplate(name: "Breakdance", icon: "figure.cooldown", description: "Floor spin and freeze combo", frameCount: 20, figureCount: 1, category: "Dance", isPro: true, color: .purple),
    ]

    var filtered: [AnimationTemplate] {
        if selectedCategory == "All" { return templates }
        return templates.filter { $0.category == selectedCategory }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ThemeManager.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        // Categories
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(categories, id: \.self) { cat in
                                    Button {
                                        withAnimation { selectedCategory = cat }
                                    } label: {
                                        Text(cat)
                                            .font(.caption.bold())
                                            .foregroundStyle(selectedCategory == cat ? .black : .white)
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 8)
                                            .background(selectedCategory == cat ? Color.orange : ThemeManager.surface)
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                        }

                        // Template grid
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                            ForEach(filtered) { template in
                                TemplateCard(template: template, isPro: auth.isPro) {
                                    if !template.isPro || auth.isPro {
                                        onSelect(template)
                                        dismiss()
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.vertical, 12)
                }
            }
            .navigationTitle("Templates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct TemplateCard: View {
    let template: AnimationTemplate
    let isPro: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(template.color.opacity(0.1))
                        .frame(height: 80)

                    Image(systemName: template.icon)
                        .font(.system(size: 32))
                        .foregroundStyle(template.color)

                    // Pro badge
                    if template.isPro && !isPro {
                        VStack {
                            HStack {
                                Spacer()
                                Image(systemName: "lock.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.black)
                                    .padding(4)
                                    .background(.orange)
                                    .clipShape(Circle())
                                    .padding(6)
                            }
                            Spacer()
                        }
                    }
                }

                VStack(spacing: 2) {
                    Text(template.name)
                        .font(.caption.bold())
                        .lineLimit(1)
                    Text("\(template.frameCount)f · \(template.figureCount) fig")
                        .font(.caption2)
                        .foregroundStyle(.gray)
                }
            }
            .padding(10)
            .background(ThemeManager.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(template.isPro && !isPro ? Color.orange.opacity(0.3) : .clear, lineWidth: 1)
            )
        }
        .opacity(template.isPro && !isPro ? 0.7 : 1.0)
    }
}
