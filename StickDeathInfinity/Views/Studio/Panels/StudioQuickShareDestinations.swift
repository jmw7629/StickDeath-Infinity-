import Foundation

/// Six configurable quick-share shortcuts for the Export panel (#242).
///
/// iOS gives an app no supported way to hand a file to one chosen third-party app
/// without that app's own SDK and developer registration. Every shortcut therefore
/// prepares the right rendered file and opens the system share sheet, where the
/// creator picks the app. Nothing here posts, uploads or reports delivery: the share
/// sheet only says whether a share action finished, never whether a post went live.
/// Direct provider integrations stay unavailable until the owner supplies the
/// provider's developer credentials and accepts its platform terms.
enum StudioQuickShareDestination: String, CaseIterable, Codable, Identifiable {
    case youtube, instagram, tiktok, facebook, x, reddit, threads, pinterest, files, photos

    var id: String { rawValue }

    var title: String {
        switch self {
        case .youtube: return "YouTube"
        case .instagram: return "Instagram"
        case .tiktok: return "TikTok"
        case .facebook: return "Facebook"
        case .x: return "X"
        case .reddit: return "Reddit"
        case .threads: return "Threads"
        case .pinterest: return "Pinterest"
        case .files: return "Files"
        case .photos: return "Photos"
        }
    }

    /// Generic SF Symbols only; no third-party logos are bundled.
    var symbol: String {
        switch self {
        case .youtube: return "play.rectangle"
        case .instagram: return "camera"
        case .tiktok: return "music.note"
        case .facebook: return "person.2"
        case .x: return "square.and.pencil"
        case .reddit: return "person.3"
        case .threads: return "at"
        case .pinterest: return "pin"
        case .files: return "folder"
        case .photos: return "photo.on.rectangle"
        }
    }

    /// Rendered files the destination's own share extension accepts, most suitable first.
    var acceptedFiles: [StudioQuickShareFile] {
        switch self {
        case .youtube, .tiktok: return [.mp4]
        case .instagram, .facebook, .threads: return [.mp4, .png]
        case .x, .reddit: return [.mp4, .gif, .png]
        case .pinterest: return [.png, .mp4]
        case .files: return [.mp4, .gif, .png]
        case .photos: return [.mp4, .gif, .png]
        }
    }

    /// The entry the creator taps in the iOS share sheet.
    var shareSheetChoice: String {
        switch self {
        case .files: return "Save to Files"
        case .photos: return "Save Video or Save Image"
        default: return title
        }
    }

    /// Whether the target is an installed app the creator may not have.
    var isThirdPartyApp: Bool { self != .files && self != .photos }
}

enum StudioQuickShareFile: String, CaseIterable, Codable {
    case mp4, gif, png

    var label: String { rawValue.uppercased() }
}

struct StudioQuickShareConfiguration: Codable, Equatable {
    static let slotCount = 6
    static let defaultSlots: [StudioQuickShareDestination] = [.youtube, .instagram, .tiktok, .facebook, .x, .reddit]
    static let storageKey = "studio.quickShare.v1"

    private(set) var slots: [StudioQuickShareDestination]
    /// Per-destination file choice, keyed by raw value so the stored JSON stays a
    /// plain object across Swift versions.
    private(set) var preferredFiles: [String: StudioQuickShareFile]

    init() {
        slots = Self.defaultSlots
        preferredFiles = [:]
    }

    /// Validates stored or decoded values; anything malformed falls back to the default set.
    init(slots: [StudioQuickShareDestination], preferredFiles: [String: StudioQuickShareFile]) {
        if slots.count == Self.slotCount, Set(slots).count == Self.slotCount {
            self.slots = slots
        } else {
            self.slots = Self.defaultSlots
        }
        var kept: [String: StudioQuickShareFile] = [:]
        for (key, file) in preferredFiles {
            if let destination = StudioQuickShareDestination(rawValue: key), destination.acceptedFiles.contains(file) {
                kept[key] = file
            }
        }
        self.preferredFiles = kept
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(slots: try container.decode([StudioQuickShareDestination].self, forKey: .slots),
                  preferredFiles: try container.decodeIfPresent([String: StudioQuickShareFile].self, forKey: .preferredFiles) ?? [:])
    }

    /// Puts `destination` in `slot`. A destination already pinned elsewhere swaps
    /// places, so the six shortcuts always stay distinct.
    mutating func assign(_ destination: StudioQuickShareDestination, toSlot slot: Int) {
        guard slots.indices.contains(slot), slots[slot] != destination else { return }
        if let existing = slots.firstIndex(of: destination) {
            slots.swapAt(existing, slot)
        } else {
            slots[slot] = destination
        }
    }

    /// Ignores a file kind the destination does not accept.
    mutating func setPreferredFile(_ file: StudioQuickShareFile, for destination: StudioQuickShareDestination) {
        guard destination.acceptedFiles.contains(file) else { return }
        preferredFiles[destination.rawValue] = file
    }

    func file(for destination: StudioQuickShareDestination) -> StudioQuickShareFile {
        preferredFiles[destination.rawValue] ?? destination.acceptedFiles[0]
    }

    mutating func reset() { self = Self() }

    static func decode(_ data: Data?) -> StudioQuickShareConfiguration {
        guard let data, let value = try? JSONDecoder().decode(StudioQuickShareConfiguration.self, from: data) else {
            return StudioQuickShareConfiguration()
        }
        return value
    }

    func encoded() -> Data? { try? JSONEncoder().encode(self) }

    static func load(from defaults: UserDefaults = .standard) -> StudioQuickShareConfiguration {
        decode(defaults.data(forKey: storageKey))
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = encoded() { defaults.set(data, forKey: Self.storageKey) }
    }
}

/// What a shortcut does with the files that are ready on this device right now.
enum StudioQuickSharePlan: Equatable {
    /// A rendered file of this kind is ready; open the share sheet with it.
    case share(StudioQuickShareFile, instruction: String)
    /// Nothing suitable is rendered yet; switch the panel to this format.
    case exportFirst(StudioQuickShareFile, instruction: String)

    var file: StudioQuickShareFile {
        switch self {
        case .share(let file, _), .exportFirst(let file, _): return file
        }
    }

    var instruction: String {
        switch self {
        case .share(_, let text), .exportFirst(_, let text): return text
        }
    }

    static func plan(for destination: StudioQuickShareDestination, configuration: StudioQuickShareConfiguration,
                     ready: Set<StudioQuickShareFile>) -> StudioQuickSharePlan {
        let preferred = configuration.file(for: destination)
        let order = [preferred] + destination.acceptedFiles.filter { $0 != preferred }
        let missing = destination.isThirdPartyApp
            ? " If \(destination.title) is not installed or does not accept this file, it is not listed there."
            : ""
        if let file = order.first(where: ready.contains) {
            return .share(file, instruction: "Share your rendered \(file.label) through the iOS share sheet and choose \(destination.shareSheetChoice) there.\(missing) Studio does not post for you and cannot confirm a post.")
        }
        return .exportFirst(preferred, instruction: "Export the \(preferred.label) below, then use \(destination.title) again or tap Share and choose \(destination.shareSheetChoice).\(missing)")
    }
}
