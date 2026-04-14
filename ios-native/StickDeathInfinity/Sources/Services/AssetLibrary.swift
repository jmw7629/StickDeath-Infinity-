// AssetLibrary.swift
// 1,000+ studio objects + 1,000+ sound effects — organized, searchable, paginated
// Assets load from Supabase Storage with local caching for offline + speed

import Foundation
import SwiftUI

// MARK: - Asset Types
struct StudioAsset: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let category: String
    let subcategory: String
    let tags: [String]
    let thumbnailURL: String
    let assetURL: String
    let isPro: Bool
    let type: AssetType

    enum AssetType: String, Codable, Hashable {
        case object   // SVG/vector prop
        case sound    // MP3/WAV sound effect
    }
}

struct AssetCategory: Identifiable {
    let id: String
    let name: String
    let icon: String
    let color: Color
    let count: Int
    let subcategories: [String]
}

// MARK: - Asset Library Manager
@MainActor
class AssetLibrary: ObservableObject {
    static let shared = AssetLibrary()

    @Published var objects: [StudioAsset] = []
    @Published var sounds: [StudioAsset] = []
    @Published var isLoading = false
    @Published var searchQuery = ""

    // Paging
    private var objectPage = 0
    private var soundPage = 0
    private let pageSize = 50
    private var hasMoreObjects = true
    private var hasMoreSounds = true

    // Cache
    private let cache = NSCache<NSString, NSData>()

    // MARK: - Object Categories (1,000+ items across all)
    static let objectCategories: [AssetCategory] = [
        AssetCategory(id: "weapons", name: "Weapons", icon: "shield.fill", color: .red, count: 150, subcategories: [
            "Swords", "Guns", "Bows", "Axes", "Hammers", "Knives", "Spears", "Shields", "Bombs", "Lasers", "Grenades", "Nunchucks", "Throwing Stars", "Staffs", "Chainsaws"
        ]),
        AssetCategory(id: "vehicles", name: "Vehicles", icon: "car.fill", color: .blue, count: 120, subcategories: [
            "Cars", "Motorcycles", "Bicycles", "Trucks", "Tanks", "Helicopters", "Jets", "Spaceships", "Boats", "Skateboards", "Rockets", "Trains"
        ]),
        AssetCategory(id: "environments", name: "Environments", icon: "mountain.2.fill", color: .green, count: 130, subcategories: [
            "Buildings", "Trees", "Rocks", "Platforms", "Bridges", "Walls", "Fences", "Doors", "Windows", "Stairs", "Rooftops", "Cliffs", "Caves"
        ]),
        AssetCategory(id: "effects", name: "Effects", icon: "sparkles", color: .yellow, count: 100, subcategories: [
            "Explosions", "Fire", "Smoke", "Lightning", "Rain", "Snow", "Wind", "Dust", "Blood Splatter", "Impact Stars", "Speed Lines", "Energy Beams"
        ]),
        AssetCategory(id: "furniture", name: "Furniture", icon: "sofa.fill", color: .red, count: 80, subcategories: [
            "Chairs", "Tables", "Desks", "Beds", "Shelves", "Couches", "Lamps", "Boxes", "Barrels", "Crates"
        ]),
        AssetCategory(id: "clothing", name: "Clothing", icon: "tshirt.fill", color: .purple, count: 90, subcategories: [
            "Hats", "Helmets", "Masks", "Capes", "Armor", "Crowns", "Glasses", "Bandanas", "Hoods", "Boots"
        ]),
        AssetCategory(id: "food", name: "Food & Items", icon: "fork.knife", color: .mint, count: 70, subcategories: [
            "Pizza", "Burgers", "Drinks", "Potions", "Keys", "Coins", "Gems", "Books", "Phones", "Tools"
        ]),
        AssetCategory(id: "sports", name: "Sports", icon: "sportscourt.fill", color: .cyan, count: 60, subcategories: [
            "Basketballs", "Footballs", "Soccer Balls", "Baseball Bats", "Tennis Rackets", "Hockey Sticks", "Golf Clubs", "Boxing Gloves"
        ]),
        AssetCategory(id: "animals", name: "Animals", icon: "hare.fill", color: .brown, count: 80, subcategories: [
            "Dogs", "Cats", "Horses", "Birds", "Fish", "Snakes", "Spiders", "Dragons", "Monsters", "Aliens"
        ]),
        AssetCategory(id: "tech", name: "Tech & Sci-Fi", icon: "cpu.fill", color: .indigo, count: 70, subcategories: [
            "Robots", "Drones", "Computers", "Portals", "Force Fields", "Jetpacks", "Laser Turrets", "Holograms"
        ]),
        AssetCategory(id: "text", name: "Text & UI", icon: "textformat", color: .white, count: 50, subcategories: [
            "Speech Bubbles", "Thought Clouds", "Action Words", "Arrows", "Labels", "Signs", "Emojis"
        ]),
    ]

    // MARK: - Sound Categories (1,000+ items across all)
    static let soundCategories: [AssetCategory] = [
        AssetCategory(id: "combat", name: "Combat", icon: "bolt.fill", color: .red, count: 200, subcategories: [
            "Punches", "Kicks", "Sword Slashes", "Gunshots", "Explosions", "Impacts", "Blocks", "Arrow Shots", "Laser Blasts", "Bone Cracks", "Body Falls", "Shield Hits"
        ]),
        AssetCategory(id: "movement", name: "Movement", icon: "figure.walk", color: .cyan, count: 120, subcategories: [
            "Footsteps", "Running", "Jumping", "Landing", "Sliding", "Rolling", "Climbing", "Swimming", "Flying", "Whoosh"
        ]),
        AssetCategory(id: "voices", name: "Voices", icon: "waveform", color: .red, count: 150, subcategories: [
            "Grunts", "Screams", "Laughs", "Battle Cries", "Pain", "Death", "Surprise", "Cheering", "Booing", "Whispers", "Countdown"
        ]),
        AssetCategory(id: "environment_sfx", name: "Environment", icon: "leaf.fill", color: .green, count: 100, subcategories: [
            "Wind", "Rain", "Thunder", "Fire Crackling", "Water", "Birds", "City Ambience", "Forest", "Cave Echo", "Space"
        ]),
        AssetCategory(id: "music_stings", name: "Music Stings", icon: "music.note", color: .purple, count: 80, subcategories: [
            "Victory", "Defeat", "Suspense", "Comedy", "Horror", "Epic Build", "Sad", "Chase", "Reveal", "Countdown"
        ]),
        AssetCategory(id: "ui_sounds", name: "UI / App", icon: "hand.tap.fill", color: .blue, count: 60, subcategories: [
            "Button Tap", "Swipe", "Notification", "Error", "Success", "Coin Collect", "Level Up", "Power Up", "Menu Open", "Menu Close"
        ]),
        AssetCategory(id: "vehicles_sfx", name: "Vehicles", icon: "car.fill", color: .yellow, count: 80, subcategories: [
            "Car Engine", "Motorcycle", "Helicopter", "Jet Flyby", "Rocket Launch", "Crash", "Tire Screech", "Horn", "Train", "Boat"
        ]),
        AssetCategory(id: "comedy", name: "Comedy", icon: "face.smiling.fill", color: .pink, count: 80, subcategories: [
            "Cartoon Boing", "Slip", "Whistle", "Bonk", "Fart", "Record Scratch", "Trombone Fail", "Rim Shot", "Pop", "Squeak"
        ]),
        AssetCategory(id: "scifi_sfx", name: "Sci-Fi", icon: "antenna.radiowaves.left.and.right", color: .indigo, count: 70, subcategories: [
            "Portal", "Teleport", "Force Field", "Robot Voice", "Computer Beep", "Alien", "Warp Drive", "Energy Charge"
        ]),
        AssetCategory(id: "transitions", name: "Transitions", icon: "arrow.left.arrow.right", color: .mint, count: 60, subcategories: [
            "Swoosh", "Whomp", "Flash", "Glitch", "Static", "Rewind", "Fast Forward", "Slow Mo", "Scene Change"
        ]),
    ]

    static var totalObjectCount: Int { objectCategories.reduce(0) { $0 + $1.count } }
    static var totalSoundCount: Int { soundCategories.reduce(0) { $0 + $1.count } }

    // MARK: - Fetch from Supabase (paginated)
    // v4.3 FIX: All .eq()/.ilike() filters MUST come before .range()/.order()
    // because .range()/.order() return PostgrestTransformBuilder which has no filter methods
    func fetchObjects(category: String? = nil, reset: Bool = false) async {
        if reset { objectPage = 0; objects = []; hasMoreObjects = true }
        guard hasMoreObjects, !isLoading else { return }
        isLoading = true

        do {
            // Build filter chain first (returns PostgrestFilterBuilder)
            var query = supabase.from("studio_assets")
                .select()
                .eq("type", value: "object")

            if let cat = category { query = query.eq("category", value: cat) }
            if !searchQuery.isEmpty { query = query.ilike("name", pattern: "%\(searchQuery)%") }

            // Then apply transforms last (returns PostgrestTransformBuilder)
            let results: [StudioAsset] = try await query
                .order("name")
                .range(from: objectPage * pageSize, to: (objectPage + 1) * pageSize - 1)
                .execute()
                .value

            objects.append(contentsOf: results)
            hasMoreObjects = results.count == pageSize
            objectPage += 1
        } catch {
            // Fallback to built-in catalog if offline
            if objects.isEmpty { objects = Self.builtInObjects(category: category) }
        }
        isLoading = false
    }

    func fetchSounds(category: String? = nil, reset: Bool = false) async {
        if reset { soundPage = 0; sounds = []; hasMoreSounds = true }
        guard hasMoreSounds, !isLoading else { return }
        isLoading = true

        do {
            // Build filter chain first (PostgrestFilterBuilder)
            var query = supabase.from("studio_assets")
                .select()
                .eq("type", value: "sound")

            if let cat = category { query = query.eq("category", value: cat) }
            if !searchQuery.isEmpty { query = query.ilike("name", pattern: "%\(searchQuery)%") }

            // Then apply transforms last (PostgrestTransformBuilder)
            let results: [StudioAsset] = try await query
                .order("name")
                .range(from: soundPage * pageSize, to: (soundPage + 1) * pageSize - 1)
                .execute()
                .value

            sounds.append(contentsOf: results)
            hasMoreSounds = results.count == pageSize
            soundPage += 1
        } catch {
            if sounds.isEmpty { sounds = Self.builtInSounds(category: category) }
        }
        isLoading = false
    }

    // MARK: - Thumbnail Caching (memory + disk)
    func loadThumbnail(url: String) async -> Data? {
        let key = url as NSString
        if let cached = cache.object(forKey: key) { return cached as Data }

        // Disk cache
        let diskURL = diskCachePath(for: url)
        if let diskData = try? Data(contentsOf: diskURL) {
            cache.setObject(diskData as NSData, forKey: key)
            return diskData
        }

        // Network
        guard let reqURL = URL(string: url) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: reqURL)
            cache.setObject(data as NSData, forKey: key)
            try? data.write(to: diskURL)
            return data
        } catch { return nil }
    }

    private func diskCachePath(for url: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("AssetThumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let hash = url.data(using: .utf8)?.base64EncodedString().prefix(32) ?? "unknown"
        return dir.appendingPathComponent("\(hash).dat")
    }

    // MARK: - Built-in Catalog (works offline, no network needed)
    // These are the base objects + sounds available even without server
    static func builtInObjects(category: String? = nil) -> [StudioAsset] {
        var all: [StudioAsset] = []
        for cat in objectCategories {
            if let filter = category, filter != cat.id { continue }
            for (i, sub) in cat.subcategories.enumerated() {
                // Generate multiple variants per subcategory
                let variants = max(cat.count / cat.subcategories.count, 3)
                for v in 1...variants {
                    all.append(StudioAsset(
                        id: "\(cat.id)_\(i)_\(v)",
                        name: v == 1 ? sub : "\(sub) \(v)",
                        category: cat.id,
                        subcategory: sub,
                        tags: [cat.name.lowercased(), sub.lowercased()],
                        thumbnailURL: "",  // Uses SF Symbol fallback
                        assetURL: "builtin://\(cat.id)/\(sub.lowercased().replacingOccurrences(of: " ", with: "_"))_\(v)",
                        isPro: v > 3,
                        type: .object
                    ))
                }
            }
        }
        return all
    }

    static func builtInSounds(category: String? = nil) -> [StudioAsset] {
        var all: [StudioAsset] = []
        for cat in soundCategories {
            if let filter = category, filter != cat.id { continue }
            for (i, sub) in cat.subcategories.enumerated() {
                let variants = max(cat.count / cat.subcategories.count, 3)
                for v in 1...variants {
                    all.append(StudioAsset(
                        id: "sfx_\(cat.id)_\(i)_\(v)",
                        name: v == 1 ? sub : "\(sub) \(v)",
                        category: cat.id,
                        subcategory: sub,
                        tags: [cat.name.lowercased(), sub.lowercased()],
                        thumbnailURL: "",
                        assetURL: "builtin://sfx/\(cat.id)/\(sub.lowercased().replacingOccurrences(of: " ", with: "_"))_\(v)",
                        isPro: v > 3,
                        type: .sound
                    ))
                }
            }
        }
        return all
    }
}
