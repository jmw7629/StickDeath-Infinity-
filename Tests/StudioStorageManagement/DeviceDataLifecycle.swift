import Foundation
import Darwin

// Portable bundle format/inventory/restore verification, import ledger and
// conflicts, storage budgets, LRU eviction and leftover cleanup (#170, #171).
// Every disk case uses real files in a private temporary root.
private struct LifecycleFailure: Error { let message: String }
private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw LifecycleFailure(message: message) }
}

enum DeviceDataLifecycleTests {
    static func run(root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let store = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("Documents"),
                                         cachesDirectory: root.appendingPathComponent("Caches"))
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAEUlEQVR4nGP8z4AATEhsPBwAM9EBBzDn4UwAAAAASUVORK5CYII=")!
        func project(_ id: UUID = UUID(), title: String = "Lifecycle fixture", audio: Data? = Data("RIFF-fixture-audio".utf8)) -> AnimationProject {
            AnimationProject(id: id, metadata: AnimationMetadata(id: id, title: title, fps: 12, canvasWidth: 4, canvasHeight: 4,
                frameCount: 1, layerCount: 1, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                modifiedAt: Date(timeIntervalSince1970: 1_700_000_000), thumbnailData: png),
                frames: [StoredAnimationFrame(imageData: png, sourceImage: StoredImageSource(id: UUID(), name: "fixture.png", container: "png",
                    originalData: png, originalWidth: 4, originalHeight: 4, originalOrientation: 1, normalizedWidth: 4, normalizedHeight: 4))],
                audioTracks: [AudioTrack(id: UUID(), name: "Fixture sound", format: "wav", audioData: audio, startTime: 0, duration: 0.5)])
        }

        // Header version: current, newer, malformed and truncated.
        let source = project()
        let bundle = try store.portableBundle(for: source)
        try check(StudioPortableBundleFormat.inspect(bundle) == .version(1), "Production bundle header is version 1")
        try StudioPortableBundleFormat.requireSupported(bundle)
        try check(try StudioPortableBundleFormat.migratedToCurrent(bundle) == bundle, "Current bundle passes through unchanged")
        var newer = bundle; newer.replaceSubrange(10..<16, with: Data("000002".utf8))
        do { try StudioPortableBundleFormat.requireSupported(newer); throw LifecycleFailure(message: "Newer format accepted") }
        catch let failure as StudioPortableBundleFormat.Failure { try check(failure == .newerVersion(2), "Newer version reported") }
        for bad in [Data(), Data("SDIPROJECT".utf8), Data("SDIPROJECT00000a\n".utf8) + bundle.dropFirst(17),
                    Data("SDIPROJECT000000\n".utf8) + bundle.dropFirst(17), Data("NOTAPROJECT00001\n".utf8)] {
            try check(StudioPortableBundleFormat.inspect(bad) == .notABundle, "Malformed header rejected")
            do { try StudioPortableBundleFormat.requireSupported(bad); throw LifecycleFailure(message: "Malformed header accepted") }
            catch let failure as StudioPortableBundleFormat.Failure { try check(failure == .notABundle, "Malformed reported as not a bundle") }
        }
        try check(StudioPortableBundleFormat.Failure.newerVersion(2).errorDescription?.contains("/") == false, "Messages are path-free")
        try check(StudioPortableBundleFormat.sha256Hex(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 hex")
        print("PASS portable header version, newer-version refusal and malformed headers")

        // Inventory measures every embedded asset; bytes-less audio is listed by name.
        let inventory = StudioPortableBundleInventory(project: source)
        try check(inventory.count(.frameImage) == 1 && inventory.count(.sourceImageOriginal) == 1 && inventory.count(.audio) == 1,
                  "Frame, original image and audio inventoried")
        try check(inventory.originals.count == 2 && inventory.totalBytes == png.count * 2 + source.audioTracks[0].audioData!.count,
                  "Originals and total bytes measured from actual data")
        try check(StudioPortableBundleInventory(project: project(audio: nil)).audioTracksWithoutBytes == ["Fixture sound"], "Silent track named")
        try check(!inventory.summary.contains("/"), "Summary is path-free")

        // Restore verification against a copy written and cold-read through production storage.
        let decoded = try store.projectFromPortableBundle(bundle)
        let newID = UUID()
        let copy = AnimationProject(id: newID, metadata: AnimationMetadata(id: newID, title: decoded.metadata.title, fps: decoded.metadata.fps,
            canvasWidth: decoded.metadata.canvasWidth, canvasHeight: decoded.metadata.canvasHeight, frameCount: decoded.metadata.frameCount,
            layerCount: decoded.metadata.layerCount, createdAt: decoded.metadata.createdAt, modifiedAt: Date(), thumbnailData: decoded.metadata.thumbnailData),
            frames: decoded.frames, audioTracks: decoded.audioTracks, editableDocumentData: decoded.editableDocumentData,
            additionalImageAssets: decoded.additionalImageAssets)
        try store.saveNewAnimation(copy)
        let reread = try DeviceStorageManager(documentsDirectory: root.appendingPathComponent("Documents")).loadAnimation(id: newID)
        let verified = StudioPortableRestoreVerifier.verify(source: decoded, restored: reread)
        try check(verified.isVerified && verified.verifiedOriginals == 2, "Cold-read copy verifies both originals: \(verified.problems)")
        var damaged = reread!; damaged.audioTracks[0].audioData = Data("different".utf8)
        try check(StudioPortableRestoreVerifier.verify(source: decoded, restored: damaged).problems == [.changed(.audio, "audio-" + decoded.audioTracks[0].id.uuidString)],
                  "Changed audio bytes detected")
        var lost = reread!; lost.frames[0].sourceImage = nil
        try check(StudioPortableRestoreVerifier.verify(source: decoded, restored: lost).problems == [.missing(.sourceImageOriginal, "frame-0")],
                  "Missing original image detected")
        var resized = reread!; resized.metadata.fps = 24
        try check(StudioPortableRestoreVerifier.verify(source: decoded, restored: resized).problems == [.structureChanged("frame rate")], "Frame rate change detected")
        var silent = reread!; silent.audioTracks.removeAll()
        let chosen = StudioPortableRestoreVerifier.verify(source: decoded, restored: silent, droppedAudio: [decoded.audioTracks[0].id])
        try check(chosen.isVerified && chosen.droppedAudio == 1 && chosen.verifiedOriginals == 1, "Creator-chosen dropped audio is not a failure")
        try check(!StudioPortableRestoreVerifier.verify(source: decoded, restored: silent).isVerified, "Unexpectedly missing audio fails")
        try check(StudioPortableRestoreVerifier.verify(source: decoded, restored: nil).problems == [.notReopened], "Unreadable copy reported")
        print("PASS inventory and byte-exact restore verification after a production cold read")

        // Ledger: bounded, tolerant of damage and links, never content.
        let ledgerURL = root.appendingPathComponent("Support/ledger.json")
        let ledger = StudioPortableImportLedger(fileURL: ledgerURL)
        try check(ledger.entries().isEmpty, "Absent ledger is empty")
        let digest = StudioPortableBundleFormat.sha256Hex(bundle)
        try ledger.record(bundleSHA256: digest, projectID: newID)
        try check(ledger.entries(forBundleSHA256: digest).map(\.projectID) == [newID], "Import recorded")
        let ledgerText = try String(contentsOf: ledgerURL, encoding: .utf8)
        try check(!ledgerText.contains(source.metadata.title) && !ledgerText.contains(root.path), "Ledger holds no title or path")
        do { try ledger.record(bundleSHA256: "not-a-digest", projectID: UUID()); throw LifecycleFailure(message: "Invalid digest recorded") }
        catch is LifecycleFailure { throw LifecycleFailure(message: "Invalid digest recorded") } catch { }
        for index in 0..<(StudioPortableImportLedger.maximumEntries + 4) {
            try ledger.record(bundleSHA256: StudioPortableBundleFormat.sha256Hex(Data("bundle-\(index)".utf8)), projectID: UUID())
        }
        try check(ledger.entries().count == StudioPortableImportLedger.maximumEntries, "Ledger bounded")
        try check(ledger.entries(forBundleSHA256: digest).isEmpty, "Oldest entries trimmed first")
        try Data("{damaged".utf8).write(to: ledgerURL)
        try check(ledger.entries().isEmpty, "Damaged ledger reads as empty")
        let target = root.appendingPathComponent("ledger-target.json")
        try StudioPortableImportLedger(fileURL: target).record(bundleSHA256: digest, projectID: newID)
        try check(StudioPortableImportLedger(fileURL: target).entries().count == 1, "Valid link target fixture")
        try fm.removeItem(at: ledgerURL)
        try fm.createSymbolicLink(at: ledgerURL, withDestinationURL: target)
        try check(ledger.entries().isEmpty, "Linked ledger is not followed")
        try fm.removeItem(at: ledgerURL)

        // Conflicts: same file imported before, original still here, stale entries.
        let live = AnimationMetadata(id: newID, title: "Imported copy", fps: 12, canvasWidth: 4, canvasHeight: 4, frameCount: 1,
                                     layerCount: 1, createdAt: Date(), modifiedAt: Date(), thumbnailData: nil)
        let original = AnimationMetadata(id: source.id, title: "Original", fps: 12, canvasWidth: 4, canvasHeight: 4,
                                                          frameCount: 1, layerCount: 1, createdAt: Date(), modifiedAt: Date(), thumbnailData: nil)
        let entry = StudioPortableImportLedger.Entry(bundleSHA256: digest, projectID: newID, importedAt: Date())
        let stale = StudioPortableImportLedger.Entry(bundleSHA256: digest, projectID: UUID(), importedAt: Date())
        try check(StudioPortableImportConflict.detect(bundleSHA256: digest, sourceProjectID: source.id, ledger: [entry, stale],
                  library: [live], recentlyDeleted: []) == .alreadyImported(title: "Imported copy", inRecentlyDeleted: false), "Repeat import detected past stale entry")
        try check(StudioPortableImportConflict.detect(bundleSHA256: digest, sourceProjectID: source.id, ledger: [entry],
                  library: [], recentlyDeleted: [live]) == .alreadyImported(title: "Imported copy", inRecentlyDeleted: true), "Repeat into Recently Deleted detected")
        try check(StudioPortableImportConflict.detect(bundleSHA256: digest, sourceProjectID: source.id, ledger: [stale],
                  library: [original], recentlyDeleted: []) == .originalOnDevice(title: "Original", inRecentlyDeleted: false), "Original on device detected")
        try check(StudioPortableImportConflict.detect(bundleSHA256: digest, sourceProjectID: source.id, ledger: [stale],
                  library: [], recentlyDeleted: []) == .none, "Stale entries are not conflicts")
        try check(StudioPortableImportConflict.alreadyImported(title: "X", inRecentlyDeleted: false).message.contains("nothing is replaced"), "Conflict text promises no replacement")
        print("PASS bounded import ledger and conflict detection without replacing anything")

        // Budgets and admission.
        let budget = StudioStorageBudget(reservedHeadroomBytes: 100, lowSpaceWarningBytes: 1_000, regenerableCacheBytes: 50, scratchMinimumAge: 60)
        try check(budget.status(availableBytes: nil) == .unknown && budget.status(availableBytes: 99) == .critical(availableBytes: 99)
                  && budget.status(availableBytes: 999) == .low(availableBytes: 999) && budget.status(availableBytes: 1_000) == .healthy(availableBytes: 1_000),
                  "Free-space status thresholds")
        try check(budget.admit(estimatedWriteBytes: 50, availableBytes: 200) == .allowed, "Room for staging, copy and headroom")
        try check(budget.admit(estimatedWriteBytes: 51, availableBytes: 200) == .refused(neededBytes: 202, availableBytes: 200), "Refused with exact need")
        try check(budget.admit(estimatedWriteBytes: 50, availableBytes: nil) == .unmeasured, "Unknown free space never invents a refusal")
        try check(budget.admit(estimatedWriteBytes: .max, availableBytes: 10) == .refused(neededBytes: .max, availableBytes: 10), "Overflow refused")
        try check(StudioStorageBudget.Admission.refused(neededBytes: 2, availableBytes: 1).message?.contains("Nothing was changed") == true, "Refusal text")

        // Planner invariant over many random inventories: essential or pinned data is never selected.
        var generator = SystemRandomNumberGenerator()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for _ in 0..<500 {
            let items = (0..<Int.random(in: 0...30, using: &generator)).map { index in
                StudioStorageItem(id: "item-\(index)", role: StudioStorageRole.allCases.randomElement(using: &generator)!,
                                  bytes: Int64.random(in: 0...100, using: &generator),
                                  lastUsed: now.addingTimeInterval(-Double.random(in: 0...200, using: &generator)),
                                  pinned: Bool.random(using: &generator))
            }
            let limit = Int64.random(in: 0...500, using: &generator)
            let plan = StudioEvictionPlanner.plan(items, regenerableBudgetBytes: limit, scratchMinimumAge: 60, now: now)
            try check(plan.evict.allSatisfy { !$0.role.isEssential && !$0.pinned }, "Essential or pinned item selected for eviction")
            try check(plan.evict.filter { $0.role == .scratch }.allSatisfy { now.timeIntervalSince($0.lastUsed) >= 60 }, "Young scratch selected")
            let pinnedRegenerable = items.filter { $0.role == .regenerableCache && $0.pinned }.reduce(Int64(0)) { $0 + $1.bytes }
            try check(plan.remainingRegenerableBytes <= max(limit, pinnedRegenerable), "Unpinned regenerable data left above budget")
            try check(plan.shortfallBytes == max(0, plan.remainingRegenerableBytes - limit), "Shortfall reported truthfully")
        }
        let ordered = StudioEvictionPlanner.plan([
            StudioStorageItem(id: "new", role: .regenerableCache, bytes: 40, lastUsed: now),
            StudioStorageItem(id: "old", role: .regenerableCache, bytes: 40, lastUsed: now.addingTimeInterval(-100)),
            StudioStorageItem(id: "only-original", role: .projectOriginal, bytes: 10_000, lastUsed: .distantPast),
        ], regenerableBudgetBytes: 50, scratchMinimumAge: 60, now: now)
        try check(ordered.evict.map(\.id) == ["old"] && ordered.protectedBytes == 10_000 && ordered.shortfallBytes == 0,
                  "Least recently used first; only original protected even when it is the largest and oldest")
        print("PASS budgets, admission and LRU planner invariant over 500 random inventories")

        // Disk: regenerable cache trimmed LRU, unknown files and link targets untouched.
        let cache = root.appendingPathComponent("Waveforms"), outside = root.appendingPathComponent("outside.json")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 30).write(to: outside)
        var names: [String] = []
        for index in 0..<5 {
            let name = StudioPortableBundleFormat.sha256Hex(Data("wave-\(index)".utf8)) + ".json"
            names.append(name)
            let url = cache.appendingPathComponent(name)
            try Data(repeating: UInt8(index), count: 10).write(to: url)
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(Double(index) * 10)], ofItemAtPath: url.path)
        }
        try Data("not ours".utf8).write(to: cache.appendingPathComponent("notes.txt"))
        try fm.createSymbolicLink(at: cache.appendingPathComponent(StudioPortableBundleFormat.sha256Hex(Data("link".utf8)) + ".json"),
                                  withDestinationURL: outside)
        let trimmer = StudioRegenerableCacheTrimmer(directory: cache) { name in
            name.hasSuffix(".json") && StudioPortableImportLedger.isDigest(String(name.dropLast(5)))
        }
        let measured = try trimmer.measure()
        try check(measured.entries.count == 5 && measured.ownedBytes == 50 && measured.unclassifiedFiles == 2, "Owned, unknown and link entries measured")
        let trimmed = try trimmer.trim(toBudget: 20)
        try check(trimmed.removedEntries == 3 && trimmed.removedBytes == 30, "Trimmed to budget")
        try check(try fm.contentsOfDirectory(atPath: cache.path).filter { names.contains($0) }.sorted() == Array(names.suffix(2)).sorted(),
                  "Least recently used records removed first")
        try check(fm.fileExists(atPath: cache.appendingPathComponent("notes.txt").path) && (try Data(contentsOf: outside)).count == 30,
                  "Unknown file and link target preserved")
        let cleared = try trimmer.trim(toBudget: 0)
        try check(cleared.removedEntries == 2 && (try trimmer.measure()).entries.isEmpty, "Explicit clear removes only owned records")

        // Disk: temporary leftovers, re-verified before removal.
        let temp = root.appendingPathComponent("tmp")
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        let oldScratch = temp.appendingPathComponent("sdi-project-validation-" + UUID().uuidString)
        try fm.createDirectory(at: oldScratch, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 70).write(to: oldScratch.appendingPathComponent("validate.wav"))
        let youngScratch = temp.appendingPathComponent("sdi-voice-" + UUID().uuidString)
        try fm.createDirectory(at: youngScratch, withIntermediateDirectories: true)
        let export = temp.appendingPathComponent("SDI-Movie-" + UUID().uuidString)
        try fm.createDirectory(at: export, withIntermediateDirectories: true)
        try Data(repeating: 9, count: 90).write(to: export.appendingPathComponent("movie.mp4"))
        let unrelated = temp.appendingPathComponent("someone-else.bin")
        try Data(repeating: 5, count: 5).write(to: unrelated)
        try fm.createSymbolicLink(at: temp.appendingPathComponent("sdi-voice-link"), withDestinationURL: outside)
        let changing = temp.appendingPathComponent("sdi-project-validation-changing")
        try Data(repeating: 1, count: 3).write(to: changing)
        let reviewTime = Date()
        for url in [oldScratch, export, unrelated, changing] {
            try fm.setAttributes([.modificationDate: reviewTime.addingTimeInterval(-7_200)], ofItemAtPath: url.path)
        }
        let sweeper = StudioScratchSweeper(directory: temp, minimumAge: 3_600)
        let review = try sweeper.review(now: reviewTime)
        try check(review.scratch.count == 2 && review.exports.count == 1 && review.recent == 1, "Leftovers classified by producer and age")
        try check(review.scratchBytes == 73 && review.exportBytes == 90, "Leftover bytes measured without following links")
        try Data(repeating: 2, count: 4).write(to: changing)   // replaced after review
        let scratchOnly = sweeper.remove(review, includeExports: false)
        try check(scratchOnly.removedEntries == 1 && scratchOnly.removedBytes == 70 && scratchOnly.skippedChanged == 1, "Changed item kept")
        try check(!fm.fileExists(atPath: oldScratch.path) && fm.fileExists(atPath: changing.path) && fm.fileExists(atPath: export.path)
                  && fm.fileExists(atPath: youngScratch.path) && fm.fileExists(atPath: unrelated.path), "Exports, young and unrelated items kept")
        let withExports = sweeper.remove(StudioScratchSweeper.Review(exports: review.exports), includeExports: true)
        try check(withExports.removedEntries == 1 && withExports.removedBytes == 90 && !fm.fileExists(atPath: export.path),
                  "Export copies removed only on explicit request")
        try check((try Data(contentsOf: outside)).count == 30, "Link target outside the folder untouched")
        print("PASS LRU disk cache trim, leftover review/removal with change detection, links never followed")
    }
}
