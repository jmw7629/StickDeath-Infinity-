// TemplatesView.swift
// Starter animation templates — adaptive grid on iPad/Mac
// v3: Removed duplicate model (AnimationTemplate now in Models.swift), adaptive columns

import SwiftUI

struct TemplatesView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.deviceContext) var ctx
    @EnvironmentObject var auth: AuthManager
    let onSelect: (AnimationTemplate) -> Void

    @State private var selectedCategory = "All"

    private let categories = ["All", "Action", "Comedy", "Dance", "Effects", "Tutorial"]

    private let templates: [AnimationTemplate] = [
        // Free templates
        AnimationTemplate(id: "walk", name: "Walk Cycle", icon: "figure.walk", category: "Tutorial", description: "Basic 8-frame walking animation", figureCount: 1, frameCount: 8, isPro: false),
        AnimationTemplate(id: "idle", name: "Idle Stand", icon: "figure.stand", category: "Tutorial", description: "Subtle idle breathing animation", figureCount: 1, frameCount: 6, isPro: false),
        AnimationTemplate(id: "jump", name: "Jump", icon: "figure.jumprope", category: "Action", description: "Full jump arc with landing", figureCount: 1, frameCount: 10, isPro: false),
        AnimationTemplate(id: "wave", name: "Wave Hello", icon: "hand.wave.fill", category: "Comedy", description: "Friendly waving gesture", figureCount: 1, frameCount: 6, isPro: false),
        AnimationTemplate(id: "fight", name: "Simple Fight", icon: "figure.boxing", category: "Action", description: "Two figures, punch exchange", figureCount: 2, frameCount: 12, isPro: false),
        // Pro templates
        AnimationTemplate(id: "sword", name: "Epic Sword Fight", icon: "figure.fencing", category: "Action", description: "Dynamic 2-figure sword duel", figureCount: 2, frameCount: 24, isPro: true),
        AnimationTemplate(id: "dance", name: "Dance Party", icon: "figure.dance", category: "Dance", description: "3 figures dancing in sync", figureCount: 3, frameCount: 16, isPro: true),
        AnimationTemplate(id: "chase", name: "Running Chase", icon: "figure.run", category: "Action", description: "Fast-paced chase scene", figureCount: 2, frameCount: 20, isPro: true),
        AnimationTemplate(id: "flip", name: "Backflip", icon: "figure.gymnastics", category: "Effects", description: "Complete backflip rotation", figureCount: 1, frameCount: 14, isPro: true),
        AnimationTemplate(id: "skit", name: "Comedy Skit", icon: "theatermasks.fill", category: "Comedy", description: "Slap comedy with 2 characters", figureCount: 2, frameCount: 18, isPro: true),
        AnimationTemplate(id: "battle", name: "Group Battle", icon: "figure.martial.arts", category: "Action", description: "4-figure battle royale", figureCount: 4, frameCount: 30, isPro: true),
        AnimationTemplate(id: "break", name: "Breakdance", icon: "figure.cooldown", category: "Dance", description: "Floor spin and freeze combo", figureCount: 1, frameCount: 20, isPro: true),
    ]

    var filtered: [AnimationTemplate] {
        if selectedCategory == "All" { return templates }
        return templates.filter { $0.category == selectedCategory }
    }

    /// Adaptive columns: 2 on phone, 3 on iPad, 4 on Mac
    var columns: [GridItem] {
        let count: Int = {
            switch ctx.current {
            case .phoneCompact: return 2
            case .phoneRegular: return 2
            case .pad: return 3
            case .desktop: return 4
            }
        }()
        return Array(repeating: GridItem(.flexible(), spacing: 14), count: count)
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
                                            .padding(.horizontal, 14).padding(.vertical, 8)
                                            .background(selectedCategory == cat ? Color.orange : ThemeManager.surface)
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                        }

                        // Template grid (adaptive)
                        LazyVGrid(columns: columns, spacing: 14) {
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
                        .frame(maxWidth: ctx.maxContentWidth)
                    }
                    .padding(.vertical, 12)
                }
            }
            .navigationTitle("Templates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

struct TemplateCard: View {
    let template: AnimationTemplate
    let isPro: Bool
    let action: () -> Void

    private var templateColor: Color {
        switch template.category {
        case "Action": return .red
        case "Comedy": return .yellow
        case "Dance": return .purple
        case "Effects": return .cyan
        case "Tutorial": return .green
        default: return .orange
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(templateColor.opacity(0.1))
                        .frame(height: 80)

                    Image(systemName: template.icon)
                        .font(.system(size: 32))
                        .foregroundStyle(templateColor)

                    if template.isPro && !isPro {
                        VStack {
                            HStack {
                                Spacer()
                                Image(systemName: "lock.fill")
                                    .font(.caption2).foregroundStyle(.black)
                                    .padding(4).background(.orange).clipShape(Circle())
                                    .padding(6)
                            }
                            Spacer()
                        }
                    }
                }

                VStack(spacing: 2) {
                    Text(template.name).font(.caption.bold()).lineLimit(1)
                    Text("\(template.frameCount)f · \(template.figureCount) fig")
                        .font(.caption2).foregroundStyle(.gray)
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
