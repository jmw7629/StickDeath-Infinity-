import SwiftUI

struct StickerCategory: Identifiable {
    let id: String
    let name: String
    let stickers: [Sticker]
    init(id: String = UUID().uuidString, name: String, stickers: [Sticker]) {
        self.id = id; self.name = name; self.stickers = stickers
    }
}

struct StickerLibrary {
    static let categories: [StickerCategory] = [
        StickerCategory(name: "⚔️ Fighters", stickers: [
            Sticker(id: "f1", name: "Swordsman", emoji: "🗡"),
            Sticker(id: "f2", name: "Archer", emoji: "🏹"),
            Sticker(id: "f3", name: "Ninja", emoji: "🥷"),
            Sticker(id: "f4", name: "Knight", emoji: "🛡"),
            Sticker(id: "f5", name: "Boxer", emoji: "🥊"),
            Sticker(id: "f6", name: "Karate", emoji: "🥋"),
            Sticker(id: "f7", name: "Fencer", emoji: "🤺"),
            Sticker(id: "f8", name: "Viking", emoji: "⚔️"),
            Sticker(id: "f9", name: "Samurai", emoji: "🗡"),
            Sticker(id: "f10", name: "Wizard", emoji: "🧙"),
        ]),
        StickerCategory(name: "🏃 Movement", stickers: [
            Sticker(id: "m1", name: "Running", emoji: "🏃"),
            Sticker(id: "m2", name: "Jumping", emoji: "🦘"),
            Sticker(id: "m3", name: "Climbing", emoji: "🧗"),
            Sticker(id: "m4", name: "Flying", emoji: "🦅"),
            Sticker(id: "m5", name: "Swimming", emoji: "🏊"),
            Sticker(id: "m6", name: "Rolling", emoji: "🛞"),
            Sticker(id: "m7", name: "Sliding", emoji: "⛷"),
            Sticker(id: "m8", name: "Diving", emoji: "🤿"),
        ]),
        StickerCategory(name: "💀 Deaths", stickers: [
            Sticker(id: "d1", name: "Skull", emoji: "💀"),
            Sticker(id: "d2", name: "Crossbones", emoji: "☠️"),
            Sticker(id: "d3", name: "Ghost", emoji: "👻"),
            Sticker(id: "d4", name: "Coffin", emoji: "⚰️"),
            Sticker(id: "d5", name: "Headstone", emoji: "🪦"),
            Sticker(id: "d6", name: "Blood Drop", emoji: "🩸"),
            Sticker(id: "d7", name: "Skeleton", emoji: "🦴"),
            Sticker(id: "d8", name: "Zombie", emoji: "🧟"),
        ]),
        StickerCategory(name: "🧍 Poses", stickers: [
            Sticker(id: "p1", name: "Standing", emoji: "🧍"),
            Sticker(id: "p2", name: "Arms Up", emoji: "🙌"),
            Sticker(id: "p3", name: "T-Pose", emoji: "🤸"),
            Sticker(id: "p4", name: "Sitting", emoji: "🧘"),
            Sticker(id: "p5", name: "Flexing", emoji: "💪"),
            Sticker(id: "p6", name: "Pointing", emoji: "👉"),
            Sticker(id: "p7", name: "Thinking", emoji: "🤔"),
            Sticker(id: "p8", name: "Dancing", emoji: "🕺"),
        ]),
        StickerCategory(name: "🔧 Props", stickers: [
            Sticker(id: "pr1", name: "Sword", emoji: "🗡"),
            Sticker(id: "pr2", name: "Shield", emoji: "🛡"),
            Sticker(id: "pr3", name: "Axe", emoji: "🪓"),
            Sticker(id: "pr4", name: "Bomb", emoji: "💣"),
            Sticker(id: "pr5", name: "Gun", emoji: "🔫"),
            Sticker(id: "pr6", name: "Bow", emoji: "🏹"),
            Sticker(id: "pr7", name: "Hammer", emoji: "🔨"),
            Sticker(id: "pr8", name: "Potion", emoji: "🧪"),
            Sticker(id: "pr9", name: "Wand", emoji: "🪄"),
            Sticker(id: "pr10", name: "Crown", emoji: "👑"),
        ]),
        StickerCategory(name: "💥 Effects", stickers: [
            Sticker(id: "e1", name: "Explosion", emoji: "💥"),
            Sticker(id: "e2", name: "Fire", emoji: "🔥"),
            Sticker(id: "e3", name: "Lightning", emoji: "⚡"),
            Sticker(id: "e4", name: "Sparkles", emoji: "✨"),
            Sticker(id: "e5", name: "Star", emoji: "⭐"),
            Sticker(id: "e6", name: "Smoke", emoji: "💨"),
            Sticker(id: "e7", name: "Sweat", emoji: "💦"),
            Sticker(id: "e8", name: "Dizzy", emoji: "💫"),
            Sticker(id: "e9", name: "Ice", emoji: "🧊"),
            Sticker(id: "e10", name: "Tornado", emoji: "🌪"),
        ]),
    ]
}
