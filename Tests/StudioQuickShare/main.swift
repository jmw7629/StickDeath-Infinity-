import Foundation

// Foundation-only production logic for the Export panel's six configurable
// quick-share shortcuts (#242): slot validation and swapping, per-destination file
// choice, persistence round trips with corrupt-data fallback, and the plan a
// shortcut follows for the files that are actually rendered. No stand-in types.

struct TestFailure: Error { let message: String }
func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TestFailure(message: message) }
}

@main struct StudioQuickShareTests {
    static var groups = 0
    static func group(_ name: String, _ body: () throws -> Void) rethrows {
        try body(); groups += 1; print("PASS " + name)
    }

    static func main() {
        do {
            try run()
            print("STUDIO_QUICK_SHARE=PASS groups=\(groups)")
        } catch let failure as TestFailure {
            print("FAIL " + failure.message); exit(1)
        } catch {
            print("FAIL \(error)"); exit(1)
        }
    }

    static func run() throws {
        try group("defaults are the six proposed destinations") {
            let config = StudioQuickShareConfiguration()
            try require(config.slots == [.youtube, .instagram, .tiktok, .facebook, .x, .reddit], "default slots")
            try require(config.slots.count == StudioQuickShareConfiguration.slotCount, "six slots")
            try require(Set(config.slots).count == 6, "distinct slots")
            for destination in StudioQuickShareDestination.allCases {
                try require(!destination.acceptedFiles.isEmpty, "\(destination) accepts a file")
                try require(config.file(for: destination) == destination.acceptedFiles[0], "\(destination) default file")
            }
            try require(!StudioQuickShareDestination.allCases.map(\.title).contains { $0.lowercased().contains("message") }, "no messaging destination")
        }

        try group("assigning keeps six distinct shortcuts") {
            var config = StudioQuickShareConfiguration()
            config.assign(.files, toSlot: 2)
            try require(config.slots[2] == .files && !config.slots.contains(.tiktok), "new destination replaces the slot")
            config.assign(.youtube, toSlot: 2)
            try require(config.slots[0] == .files && config.slots[2] == .youtube, "pinned destination swaps places")
            try require(Set(config.slots).count == 6, "still distinct")
            let before = config
            config.assign(.photos, toSlot: 6)
            config.assign(.photos, toSlot: -1)
            try require(config == before, "out-of-range slot ignored")
        }

        try group("per-destination file choice respects what the destination accepts") {
            var config = StudioQuickShareConfiguration()
            config.setPreferredFile(.gif, for: .youtube)
            try require(config.file(for: .youtube) == .mp4, "YouTube refuses GIF")
            config.setPreferredFile(.gif, for: .x)
            try require(config.file(for: .x) == .gif, "X keeps GIF")
            config.reset()
            try require(config == StudioQuickShareConfiguration(), "reset restores defaults")
        }

        try group("persistence round trips and falls back on bad data") {
            var config = StudioQuickShareConfiguration()
            config.assign(.pinterest, toSlot: 5)
            config.setPreferredFile(.png, for: .instagram)
            try require(config.encoded() != nil, "encodes")
            let decoded = StudioQuickShareConfiguration.decode(config.encoded())
            try require(decoded == config, "round trip")
            try require(StudioQuickShareConfiguration.decode(nil) == StudioQuickShareConfiguration(), "missing data")
            try require(StudioQuickShareConfiguration.decode(Data("not json".utf8)) == StudioQuickShareConfiguration(), "corrupt data")
            let duplicate = Data(#"{"slots":["youtube","youtube","tiktok","facebook","x","reddit"],"preferredFiles":{}}"#.utf8)
            try require(StudioQuickShareConfiguration.decode(duplicate).slots == StudioQuickShareConfiguration.defaultSlots, "duplicate slots rejected")
            let short = Data(#"{"slots":["youtube"],"preferredFiles":{}}"#.utf8)
            try require(StudioQuickShareConfiguration.decode(short).slots == StudioQuickShareConfiguration.defaultSlots, "short slot list rejected")
            let badFile = Data(#"{"slots":["youtube","instagram","tiktok","facebook","x","reddit"],"preferredFiles":{"youtube":"gif","nowhere":"mp4","x":"gif"}}"#.utf8)
            let filtered = StudioQuickShareConfiguration.decode(badFile)
            try require(filtered.file(for: .youtube) == .mp4 && filtered.file(for: .x) == .gif, "unsupported stored choices dropped")
            let unknown = Data(#"{"slots":["youtube","instagram","tiktok","facebook","x","myspace"],"preferredFiles":{}}"#.utf8)
            try require(StudioQuickShareConfiguration.decode(unknown) == StudioQuickShareConfiguration(), "unknown destination falls back")

            let suite = "sdi.quickshare.tests.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suite) else { throw TestFailure(message: "defaults suite") }
            defer { defaults.removePersistentDomain(forName: suite) }
            try require(StudioQuickShareConfiguration.load(from: defaults) == StudioQuickShareConfiguration(), "empty store loads defaults")
            config.save(to: defaults)
            try require(StudioQuickShareConfiguration.load(from: defaults) == config, "saved choices survive reload")
        }

        try group("plans share only files that are rendered") {
            let config = StudioQuickShareConfiguration()
            let none = StudioQuickSharePlan.plan(for: .youtube, configuration: config, ready: [])
            try require(none == .exportFirst(.mp4, instruction: none.instruction), "nothing ready asks for an MP4 export")
            try require(none.instruction.contains("YouTube") && none.instruction.contains("not installed"), "missing-app explanation")
            let gifOnly = StudioQuickSharePlan.plan(for: .youtube, configuration: config, ready: [.gif])
            try require(gifOnly.file == .mp4, "GIF is never offered to YouTube")
            if case .share = gifOnly { throw TestFailure(message: "YouTube must not share a GIF") }
            let ready = StudioQuickSharePlan.plan(for: .youtube, configuration: config, ready: [.mp4, .gif])
            try require(ready == .share(.mp4, instruction: ready.instruction), "ready MP4 shared")
            try require(ready.instruction.contains("cannot confirm a post"), "no delivery claim")
            var gifFirst = config
            gifFirst.setPreferredFile(.gif, for: .reddit)
            try require(StudioQuickSharePlan.plan(for: .reddit, configuration: gifFirst, ready: [.mp4, .gif]).file == .gif, "preferred file wins")
            try require(StudioQuickSharePlan.plan(for: .reddit, configuration: gifFirst, ready: [.mp4]).file == .mp4, "falls back to another accepted ready file")
            let files = StudioQuickSharePlan.plan(for: .files, configuration: config, ready: [.png])
            try require(files.file == .png && files.instruction.contains("Save to Files") && !files.instruction.contains("not installed"), "Files uses the system entry")
        }
    }
}
