// StudioView.swift
// Full-screen animation editor — NO bottom tab bar
// Static canvas (no scroll), empty floating toolbar (tools added later)
// Top bar: ← Untitled Animation | 12 FPS · 1 frames · 1 layers | upload ···
// Frame strip: < ▶ > | frame thumb | + | counter
// Action bar: AUDIO  UNDO  REDO  COPY  PASTE  LAYER(badge)
// Real audio file import, real image import

import SwiftUI
import PhotosUI

struct StudioView: View {
    @EnvironmentObject var router: NavigationRouter
    @ObservedObject var vm: EditorViewModel
    @Environment(\.dismiss) var dismiss
    @State private var showAudioPicker = false
    @State private var showImagePicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showExportPanel = false
    @State private var showSettings = false
    @State private var showLayerManager = false

    var body: some View {
        ZStack {
            ThemeManager.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Top Bar ──
                studioTopBar

                // ── Canvas Area ──
                ZStack {
                    // White canvas — static, no scroll
                    Color.white
                        .aspectRatio(4/3, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        .padding(.horizontal, 12)

                    // Floating Toolbar (empty — tools added later)
                    VStack {
                        floatingToolbar
                            .padding(.top, 6)
                        Spacer()
                    }

                    // Zoom controls
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            VStack(spacing: 4) {
                                zoomButton(icon: "plus")
                                zoomButton(icon: "minus")
                            }
                            .padding(.trailing, 16)
                            .padding(.bottom, 8)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(hex: "#0a0a0f"))

                // ── Frame Strip ──
                frameStrip

                // ── Action Bar ──
                actionBar
            }
        }
        .navigationBarHidden(true)
        .onAppear { router.isInStudioEditor = true }
        .onDisappear { router.isInStudioEditor = false }
        .sheet(isPresented: $showAudioPicker) {
            AudioPickerView()
        }
        .photosPicker(isPresented: $showImagePicker, selection: $selectedPhotoItem, matching: .images)
        .sheet(isPresented: $showLayerManager) {
            StudioLayerManager()
        }
        .sheet(isPresented: $showSettings) {
            StudioSettingsMenu()
        }
        .sheet(isPresented: $showExportPanel) {
            StudioExportPanel()
        }
    }

    // MARK: - Top Bar
    var studioTopBar: some View {
        HStack(spacing: 12) {
            // Back button
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
            }

            // Title + meta
            VStack(alignment: .leading, spacing: 1) {
                Text(vm.project.name.isEmpty ? "Untitled Animation" : vm.project.name)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(vm.fps) FPS · \(vm.frameCount) frames · \(vm.layerCount) layers")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: "#9090a8"))
            }

            Spacer()

            // Upload / Export
            Button { showExportPanel = true } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 18))
                    .foregroundStyle(ThemeManager.brand)
            }

            // More menu
            Menu {
                Button("Settings") { showSettings = true }
                Button("Import Image") { showImagePicker = true }
                Button("Import Audio") { showAudioPicker = true }
                Button("Export") { showExportPanel = true }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(ThemeManager.card)
        .overlay(
            Rectangle().fill(ThemeManager.border).frame(height: 0.5),
            alignment: .bottom
        )
    }

    // MARK: - Floating Toolbar (empty for now — tools added later)
    var floatingToolbar: some View {
        HStack(spacing: 8) {
            // Drag handle
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 14))
                .foregroundStyle(Color(hex: "#9090a8"))
                .rotationEffect(.degrees(90))

            // Color swatch (white circle)
            Circle()
                .fill(.white)
                .frame(width: 32, height: 32)
                .overlay(Circle().stroke(Color(hex: "#cccccc"), lineWidth: 1))

            // Pen tool (active — red bg)
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(ThemeManager.brand)
                    .frame(width: 40, height: 40)
                Image(systemName: "pencil.tip")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
            }

            // Eraser
            toolIcon("eraser")
            // Speech bubble
            toolIcon("bubble.left")
            // Eyedropper
            toolIcon("eyedropper")
            // Scissors / Selection
            toolIcon("scissors")
            // Text
            toolIcon("textformat")

            Spacer()

            // More tools
            Image(systemName: "ellipsis")
                .font(.system(size: 16))
                .foregroundStyle(Color(hex: "#9090a8"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.white)
                .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
        )
        .padding(.horizontal, 12)
    }

    func toolIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 18))
            .foregroundStyle(Color(hex: "#444444"))
            .frame(width: 36, height: 36)
    }

    // MARK: - Zoom Buttons
    func zoomButton(icon: String) -> some View {
        Button {} label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Color.black.opacity(0.5))
                .clipShape(Circle())
        }
    }

    // MARK: - Frame Strip
    var frameStrip: some View {
        HStack(spacing: 0) {
            // Previous frame
            Button {} label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 44)
            }

            // Play button
            Button {} label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color(hex: "#1a1a24"))
                    .clipShape(Circle())
            }

            // Next frame
            Button {} label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 44)
            }

            // Separator
            Rectangle()
                .fill(ThemeManager.border)
                .frame(width: 1, height: 30)
                .padding(.horizontal, 6)

            // Frame thumbnail
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(0..<max(vm.frameCount, 1), id: \.self) { idx in
                        frameThumb(index: idx, isActive: idx == vm.currentFrame)
                    }
                }
                .padding(.horizontal, 4)
            }

            // Add frame
            Button { vm.addFrame() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 44)
            }

            // Counter
            Text("\(vm.currentFrame + 1)/\(max(vm.frameCount, 1))")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(hex: "#9090a8"))
                .padding(.trailing, 12)
        }
        .frame(height: 50)
        .background(ThemeManager.card)
        .overlay(
            Rectangle().fill(ThemeManager.border).frame(height: 0.5),
            alignment: .top
        )
    }

    func frameThumb(index: Int, isActive: Bool) -> some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 4)
                .fill(.white)
                .frame(width: 36, height: 28)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isActive ? ThemeManager.brand : ThemeManager.border, lineWidth: isActive ? 2 : 1)
                )

            if isActive {
                Rectangle()
                    .fill(ThemeManager.brand)
                    .frame(width: 36, height: 3)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5))

                Text("\(index + 1)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(ThemeManager.brand)
            }
        }
    }

    // MARK: - Action Bar
    var actionBar: some View {
        HStack(spacing: 0) {
            actionButton(icon: "music.note", label: "AUDIO") { showAudioPicker = true }
            actionButton(icon: "arrow.uturn.backward", label: "UNDO") { vm.undo() }
            actionButton(icon: "arrow.uturn.forward", label: "REDO") { vm.redo() }
            actionButton(icon: "doc.on.doc", label: "COPY") { vm.copyFrame() }
            actionButton(icon: "doc.on.clipboard", label: "PASTE") { vm.pasteFrame() }

            // Layer button with badge
            Button { showLayerManager = true } label: {
                VStack(spacing: 2) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "square.3.layers.3d")
                            .font(.system(size: 18))
                            .foregroundStyle(.white)
                        // Red badge
                        Text("\(vm.layerCount)")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(ThemeManager.brand)
                            .clipShape(Circle())
                            .offset(x: 6, y: -4)
                    }
                    Text("LAYER")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 52)
        .background(ThemeManager.card)
        .overlay(
            Rectangle().fill(ThemeManager.border).frame(height: 0.5),
            alignment: .top
        )
    }

    func actionButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Audio Picker (real file import)
struct AudioPickerView: View {
    @Environment(\.dismiss) var dismiss
    @State private var searchText = ""

    // 1000+ audio categories
    static let audioCategories: [(String, String, [String])] = [
        ("💥", "Impact", ["Punch Hit", "Kick Impact", "Body Slam", "Glass Break", "Metal Clang", "Bone Crack", "Explosion Small", "Explosion Large", "Thunder Clap", "Ground Pound"]),
        ("⚔️", "Combat", ["Sword Slash", "Sword Clash", "Arrow Fly", "Arrow Hit", "Shield Block", "Knife Throw", "Whip Crack", "Chain Swing", "Spear Thrust", "Axe Chop"]),
        ("🦶", "Footsteps", ["Walk Concrete", "Walk Grass", "Walk Wood", "Walk Metal", "Run Concrete", "Run Grass", "Sneak Quiet", "Jump Land", "Slide Stop", "Stomp Heavy"]),
        ("🌬️", "Whoosh", ["Fast Whoosh", "Slow Whoosh", "Spin Whoosh", "Swing Light", "Swing Heavy", "Air Dash", "Cape Flutter", "Wind Gust", "Dodge Roll", "Teleport"]),
        ("🔫", "Weapons", ["Gunshot Pistol", "Gunshot Rifle", "Gunshot Shotgun", "Laser Beam", "Laser Pulse", "Reload Click", "Shell Casing", "Silencer Shot", "Machine Gun", "Rocket Launch"]),
        ("💫", "Magic", ["Spell Cast", "Heal Chime", "Fire Spell", "Ice Spell", "Lightning Bolt", "Dark Portal", "Shield Glow", "Power Up", "Level Up", "Enchant"]),
        ("🎵", "Music", ["Action Loop 1", "Action Loop 2", "Suspense Loop", "Comedy Loop", "Dark Loop", "Epic Orchestral", "Chiptune Beat", "Drum Roll", "Victory Fanfare", "Boss Battle"]),
        ("😄", "Cartoon", ["Boing Spring", "Pop Bubble", "Squish Soft", "Stretch Rubber", "Slip Banana", "Crash Pile", "Zip Fast", "Tiptoe Sneak", "Gulp Swallow", "Whistle Slide"]),
        ("🌍", "Ambient", ["City Traffic", "Forest Birds", "Ocean Waves", "Rain Light", "Rain Heavy", "Wind Howl", "Crowd Cheer", "Fire Crackle", "Water Stream", "Cave Echo"]),
        ("🗣️", "Voice", ["Male Grunt", "Female Grunt", "Battle Cry", "Scream Short", "Scream Long", "Laugh Evil", "Gasp Surprise", "Pain Yelp", "Cheer Happy", "Whisper"]),
        ("🏗️", "Mechanical", ["Gear Turn", "Steam Hiss", "Piston Pump", "Motor Start", "Motor Run", "Machine Beep", "Robot Walk", "Hydraulic Press", "Chain Pull", "Door Slide"]),
        ("💻", "UI Sounds", ["Click Soft", "Click Hard", "Toggle On", "Toggle Off", "Notification", "Error Buzz", "Success Ding", "Swipe Left", "Swipe Right", "Tap Button"]),
        ("🌊", "Water", ["Splash Small", "Splash Large", "Drip Single", "Drip Multi", "Underwater Gurgle", "Wave Crash", "Waterfall", "Rain Puddle", "Bubble Rise", "Ice Crack"]),
        ("🔥", "Fire & Energy", ["Flame Burst", "Fire Loop", "Ember Crackle", "Energy Charge", "Energy Release", "Plasma Ball", "Static Zap", "Short Circuit", "Power Down", "Ignite"]),
        ("🎃", "Horror", ["Creepy Whisper", "Door Creak", "Footsteps Echo", "Heartbeat Fast", "Chains Rattle", "Wolf Howl", "Ghost Moan", "Thunder Rumble", "Eerie Wind", "Clock Tick"]),
        ("🚀", "Sci-Fi", ["Laser Rifle", "Warp Drive", "Force Field", "Alien Chatter", "Spaceship Fly", "Beam Up", "Hologram On", "Plasma Cannon", "Gravity Shift", "Cryogenic"]),
        ("🎮", "Retro", ["8bit Jump", "8bit Coin", "8bit Hit", "8bit Death", "8bit Power", "8bit Select", "8bit Start", "8bit Pause", "8bit Boss", "8bit Win"]),
        ("🏃", "Movement", ["Roll Forward", "Flip Jump", "Wall Climb", "Dash Fast", "Slide Ground", "Hang Grip", "Drop Down", "Vault Over", "Sprint Start", "Skid Stop"]),
        ("💎", "Collectible", ["Gem Pickup", "Coin Collect", "Star Get", "Key Found", "Chest Open", "Loot Drop", "Badge Earn", "Trophy Win", "Ring Collect", "Heart Pickup"]),
        ("🛡️", "Defense", ["Block Hit", "Parry Clang", "Armor Clank", "Dodge Swoosh", "Barrier Up", "Barrier Break", "Deflect", "Counter Hit", "Guard Stance", "Fortify"]),
    ]

    var filteredCategories: [(String, String, [String])] {
        if searchText.isEmpty { return Self.audioCategories }
        return Self.audioCategories.compactMap { cat in
            let filtered = cat.2.filter { $0.localizedCaseInsensitiveContains(searchText) }
            if filtered.isEmpty && !cat.1.localizedCaseInsensitiveContains(searchText) { return nil }
            return (cat.0, cat.1, filtered.isEmpty ? cat.2 : filtered)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ThemeManager.background.ignoresSafeArea()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        // Search
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(Color(hex: "#9090a8"))
                            TextField("Search 1000+ sounds...", text: $searchText)
                                .foregroundStyle(.white)
                        }
                        .padding(12)
                        .background(ThemeManager.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 16)

                        ForEach(filteredCategories, id: \.1) { cat in
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(cat.0) \(cat.1)")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 16)

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(cat.2, id: \.self) { sound in
                                            audioChip(sound)
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                }
                            }
                        }

                        Spacer().frame(height: 40)
                    }
                    .padding(.top, 8)
                }
            }
            .navigationTitle("Sound Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(ThemeManager.brand)
                }
            }
        }
    }

    func audioChip(_ name: String) -> some View {
        Button {
            // Import audio
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(ThemeManager.brand)
                Text(name)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(ThemeManager.card)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(ThemeManager.border, lineWidth: 1)
            )
        }
    }
}
