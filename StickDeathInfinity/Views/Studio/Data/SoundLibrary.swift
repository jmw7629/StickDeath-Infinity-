import SwiftUI

struct SoundCategory: Identifiable {
    let id: String
    let name: String
    let icon: String
    let color: Color
    let sounds: [SoundEffect]
    
    init(id: String = UUID().uuidString, name: String, icon: String, color: Color, sounds: [SoundEffect]) {
        self.id = id; self.name = name; self.icon = icon; self.color = color; self.sounds = sounds
    }
}

struct SoundLibrary {
    static let categories: [SoundCategory] = [
        SoundCategory(name: "💥 Explosions", icon: "💥", color: Color(hex: "#FF4500"), sounds: [
            SoundEffect(name: "Big Boom", duration: "0.8s", tag: "Explosion"),
            SoundEffect(name: "Dynamite", duration: "1.2s", tag: "Explosion"),
            SoundEffect(name: "Grenade", duration: "0.6s", tag: "Explosion"),
            SoundEffect(name: "TNT Blast", duration: "1.5s", tag: "Explosion"),
            SoundEffect(name: "Nuke", duration: "3.2s", tag: "Explosion"),
            SoundEffect(name: "Fireball", duration: "0.9s", tag: "Explosion"),
            SoundEffect(name: "Mine Explode", duration: "0.4s", tag: "Explosion"),
            SoundEffect(name: "Cluster Bomb", duration: "2.1s", tag: "Explosion"),
        ]),
        SoundCategory(name: "⚔️ Combat", icon: "⚔️", color: Color(hex: "#DC2626"), sounds: [
            SoundEffect(name: "Sword Slash", duration: "0.3s", tag: "Melee"),
            SoundEffect(name: "Sword Clash", duration: "0.4s", tag: "Melee"),
            SoundEffect(name: "Punch", duration: "0.2s", tag: "Melee"),
            SoundEffect(name: "Kick", duration: "0.3s", tag: "Melee"),
            SoundEffect(name: "Arrow Fire", duration: "0.5s", tag: "Ranged"),
            SoundEffect(name: "Arrow Hit", duration: "0.2s", tag: "Ranged"),
            SoundEffect(name: "Gunshot", duration: "0.3s", tag: "Ranged"),
            SoundEffect(name: "Machine Gun", duration: "1.5s", tag: "Ranged"),
            SoundEffect(name: "Sniper", duration: "0.4s", tag: "Ranged"),
            SoundEffect(name: "Shotgun", duration: "0.5s", tag: "Ranged"),
            SoundEffect(name: "Bullet Whiz", duration: "0.3s", tag: "Ranged"),
            SoundEffect(name: "Shield Block", duration: "0.3s", tag: "Melee"),
        ]),
        SoundCategory(name: "💀 Death", icon: "💀", color: Color(hex: "#991B1B"), sounds: [
            SoundEffect(name: "Bone Crack", duration: "0.2s", tag: "Gore"),
            SoundEffect(name: "Splatter", duration: "0.4s", tag: "Gore"),
            SoundEffect(name: "Head Pop", duration: "0.3s", tag: "Gore"),
            SoundEffect(name: "Body Fall", duration: "0.6s", tag: "Death"),
            SoundEffect(name: "Scream Male", duration: "0.8s", tag: "Voice"),
            SoundEffect(name: "Scream Female", duration: "0.7s", tag: "Voice"),
            SoundEffect(name: "Death Groan", duration: "0.5s", tag: "Voice"),
            SoundEffect(name: "Neck Snap", duration: "0.2s", tag: "Gore"),
        ]),
        SoundCategory(name: "🔥 Elements", icon: "🔥", color: Color(hex: "#F97316"), sounds: [
            SoundEffect(name: "Fire Crackle", duration: "2.0s", tag: "Fire"),
            SoundEffect(name: "Fire Whoosh", duration: "0.5s", tag: "Fire"),
            SoundEffect(name: "Lightning Strike", duration: "0.4s", tag: "Elec"),
            SoundEffect(name: "Thunder Rumble", duration: "2.5s", tag: "Elec"),
            SoundEffect(name: "Ice Freeze", duration: "0.7s", tag: "Ice"),
            SoundEffect(name: "Water Splash", duration: "0.5s", tag: "Water"),
            SoundEffect(name: "Wind Gust", duration: "1.5s", tag: "Wind"),
            SoundEffect(name: "Earthquake", duration: "3.0s", tag: "Earth"),
        ]),
        SoundCategory(name: "🎵 Music", icon: "🎵", color: Color(hex: "#3B82F6"), sounds: [
            SoundEffect(name: "Epic Drums", duration: "4.0s", tag: "BGM"),
            SoundEffect(name: "Dark Ambient", duration: "5.0s", tag: "BGM"),
            SoundEffect(name: "Battle Loop", duration: "4.5s", tag: "BGM"),
            SoundEffect(name: "Victory Fanfare", duration: "3.0s", tag: "BGM"),
            SoundEffect(name: "Tension Build", duration: "3.5s", tag: "BGM"),
            SoundEffect(name: "Sad Piano", duration: "5.0s", tag: "BGM"),
        ]),
        SoundCategory(name: "🏃 Movement", icon: "🏃", color: Color(hex: "#22C55E"), sounds: [
            SoundEffect(name: "Footsteps Run", duration: "1.0s", tag: "Steps"),
            SoundEffect(name: "Jump", duration: "0.3s", tag: "Move"),
            SoundEffect(name: "Land Heavy", duration: "0.3s", tag: "Move"),
            SoundEffect(name: "Dash Woosh", duration: "0.2s", tag: "Move"),
            SoundEffect(name: "Roll", duration: "0.4s", tag: "Move"),
            SoundEffect(name: "Slide", duration: "0.5s", tag: "Move"),
            SoundEffect(name: "Wall Hit", duration: "0.2s", tag: "Impact"),
        ]),
        SoundCategory(name: "✨ Magic", icon: "✨", color: Color(hex: "#A855F7"), sounds: [
            SoundEffect(name: "Spell Cast", duration: "0.6s", tag: "Magic"),
            SoundEffect(name: "Power Up", duration: "1.0s", tag: "Magic"),
            SoundEffect(name: "Heal", duration: "0.8s", tag: "Magic"),
            SoundEffect(name: "Teleport", duration: "0.5s", tag: "Magic"),
            SoundEffect(name: "Shield Activate", duration: "0.4s", tag: "Magic"),
            SoundEffect(name: "Dark Magic", duration: "1.2s", tag: "Magic"),
        ]),
        SoundCategory(name: "🎤 Voices", icon: "🎤", color: Color(hex: "#EC4899"), sounds: [
            SoundEffect(name: "War Cry", duration: "0.8s", tag: "Voice"),
            SoundEffect(name: "Laugh Evil", duration: "1.2s", tag: "Voice"),
            SoundEffect(name: "Taunt", duration: "0.6s", tag: "Voice"),
            SoundEffect(name: "Grunt Attack", duration: "0.3s", tag: "Voice"),
            SoundEffect(name: "Ouch", duration: "0.3s", tag: "Voice"),
            SoundEffect(name: "Woohoo", duration: "0.5s", tag: "Voice"),
        ]),
        SoundCategory(name: "🔧 UI/Misc", icon: "🔧", color: Color(hex: "#64748B"), sounds: [
            SoundEffect(name: "Click", duration: "0.1s", tag: "UI"),
            SoundEffect(name: "Whoosh", duration: "0.3s", tag: "UI"),
            SoundEffect(name: "Pop", duration: "0.1s", tag: "UI"),
            SoundEffect(name: "Ding", duration: "0.2s", tag: "UI"),
            SoundEffect(name: "Error Buzz", duration: "0.3s", tag: "UI"),
            SoundEffect(name: "Coin", duration: "0.2s", tag: "Game"),
            SoundEffect(name: "Level Up", duration: "0.8s", tag: "Game"),
            SoundEffect(name: "Game Over", duration: "1.0s", tag: "Game"),
        ]),
    ]
}
