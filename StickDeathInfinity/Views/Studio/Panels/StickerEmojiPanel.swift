import SwiftUI

struct StickerEmojiPanel: View {
    @ObservedObject var vm: StudioViewModel
    @EnvironmentObject private var authVM: AuthViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var insertionNotice: String?
    @FocusState private var searchFocused: Bool
    private func insert(_ glyph: String) {
        insertionNotice = vm.insertShelfGlyph(glyph, isForeground: scenePhase == .active) ? nil : vm.message
    }
    @State private var tab: String = "stickers"
    @State private var search: String = ""
    @State private var selectedCategoryIndex: Int = 0
    @State private var selectedEmojiCatIndex: Int = 0

    static let emojiSets: [(name: String, emojis: [String])] = [
        ("😀 Smileys", ["😀","😃","😄","😁","😆","😅","🤣","😂","🙂","😊","😇","🥰","😍","🤩","😘","😗","😚","😙","🥲","😋","😛","😜","🤪","😝","🤑","🤗","🤭","🤫","🤔","😐","😑","😶","😏","😒","🙄","😬","😌","😔","😪","😴","😷","🤒","🤕","🤢","🤮","🥵","🥶","🥴","😵","🤯","🤠","🥳","😎","🤓"]),
        ("👋 Hands", ["👋","🤚","🖐","✋","🖖","👌","🤌","🤏","✌️","🤞","🤟","🤘","🤙","👈","👉","👆","🖕","👇","☝️","👍","👎","✊","👊","🤛","🤜","👏","🙌","👐","🤲","🤝","🙏","✍️","💅","🤳","💪"]),
        ("💥 Actions", ["💥","💫","💦","💨","🕳","💣","💬","🗨","🗯","💭","💤","🫧","🌊","🔥","⚡","✨","🌟","💫","🎆","🎇","🧨","🎈","🎉","🎊","🎃"]),
        ("⚔️ Weapons", ["⚔️","🗡","🔪","🪓","🔨","⛏","🪚","🔧","🪛","🛡","🏹","🔫","🪃","💣","🧨"]),
        ("💀 Skulls", ["💀","☠️","🦴","🩻","🧟","🧛","👻","👽","👾","🤖","😈","👿","🎃","🕷","🕸","🦇"]),
    ]

    var filteredStickers: [Sticker] {
        let stickers = StickerLibrary.categories[safe: selectedCategoryIndex]?.stickers ?? []
        if search.isEmpty { return stickers }
        return stickers.filter { $0.name.lowercased().contains(search.lowercased()) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.2))
                .frame(width: 36, height: 4)
                .padding(.top, 8)

            PanelHeader(title: "Stickers & Emoji", icon: "😀", onClose: { vm.activePanel = .none })

            // Tab switcher
            HStack(spacing: 4) {
                StickerTabButton(label: "💀 STICKERS", isActive: tab == "stickers") { tab = "stickers" }
                StickerTabButton(label: "😀 EMOJI", isActive: tab == "emoji") { tab = "emoji" }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            if let insertionNotice {
                Text(insertionNotice).font(.caption).foregroundColor(.red)
                    .accessibilityIdentifier("studio.sticker.result")
                    .padding(.horizontal, 12)
            }

            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.25))
                TextField("Search...", text: $search)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .onSubmit { searchFocused = false }
                    .accessibilityIdentifier("studio.sticker.search")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(hex: "12121a"))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08)))
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            ScrollView {
                if tab == "stickers" {
                    // Category pills
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(Array(StickerLibrary.categories.enumerated()), id: \.offset) { index, cat in
                                Button(action: { selectedCategoryIndex = index }) {
                                    Text(cat.name)
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundColor(selectedCategoryIndex == index ? Color(hex: "DC2626") : .white.opacity(0.4))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(selectedCategoryIndex == index ? Color(hex: "DC2626").opacity(0.15) : Color.clear)
                                        )
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                    .padding(.bottom, 8)

                    // Sticker grid
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        ForEach(filteredStickers) { sticker in
                            Button(action: {
                                insert(sticker.emoji)
                            }) {
                                VStack(spacing: 4) {
                                    Text(sticker.emoji)
                                        .font(.system(size: 28))
                                    Text(sticker.name)
                                        .font(.system(size: 7, weight: .medium, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.5))
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(hex: "12121a"))
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.05)))
                                )
                            }
                            .accessibilityIdentifier("studio.sticker.item." + sticker.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 20)
                } else {
                    // Emoji tab
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(Array(Self.emojiSets.enumerated()), id: \.offset) { index, cat in
                                Button(action: { selectedEmojiCatIndex = index }) {
                                    Text(cat.name)
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundColor(selectedEmojiCatIndex == index ? Color(hex: "DC2626") : .white.opacity(0.4))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(selectedEmojiCatIndex == index ? Color(hex: "DC2626").opacity(0.15) : Color.clear)
                                        )
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                    .padding(.bottom, 8)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 8), spacing: 4) {
                        ForEach(Self.emojiSets[safe: selectedEmojiCatIndex]?.emojis ?? [], id: \.self) { emoji in
                            Button(action: {
                                insert(emoji)
                            }) {
                                Text(emoji)
                                    .font(.system(size: 24))
                                    .frame(width: 38, height: 38)
                            }
                            .accessibilityIdentifier("studio.emoji.item." + emoji)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 20)
                }
            }
        }
        .frame(maxHeight: UIScreen.main.bounds.height * 0.55)
        .background(Color(hex: "1a1a24"))
        .cornerRadius(16, corners: [.topLeft, .topRight])
        .onChange(of: authVM.userId) { _ in if vm.activePanel == .stickerEmoji { vm.activePanel = .none } }
        .onChange(of: scenePhase) { phase in
            if phase != .active, vm.activePanel == .stickerEmoji { vm.activePanel = .none }
        }
    }
}

// MARK: - Tab Button (renamed to avoid conflict)
struct StickerTabButton: View {
    let label: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.5)
                .foregroundColor(isActive ? Color(hex: "DC2626") : .white.opacity(0.4))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isActive ? Color(hex: "DC2626").opacity(0.15) : Color.white.opacity(0.03))
                )
        }
    }
}

// Safe subscript for tuples array
extension Array where Element == (name: String, emojis: [String]) {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
