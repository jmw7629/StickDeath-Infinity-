import Foundation
import Darwin

private struct Failure: Error { let message: String }
private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw Failure(message: message) }
}
private func rejects(_ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw Failure(message: "Expected actual production failure")
}

@main struct StudioStorageManagementTests {
    static func main() throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "hold-revision-lock" {
            let fd = open(CommandLine.arguments[2], O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { exit(2) }
            var ready: UInt8 = 1
            guard Darwin.write(STDOUT_FILENO, &ready, 1) == 1 else { exit(3) }
            _ = Darwin.read(STDIN_FILENO, &ready, 1)
            flock(fd, LOCK_UN); close(fd)
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-storage-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appendingPathComponent("Documents"), caches = root.appendingPathComponent("Caches")
        let store = DeviceStorageManager(documentsDirectory: docs, cachesDirectory: caches)
        var files: [URL: Data] = [:]
        func write(_ relative: String, count: Int, under parent: URL) throws {
            let url = parent.appendingPathComponent(relative), data = Data(repeating: 83, count: count)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url); files[url] = data
        }
        try write("Animations/source/revisions/original.bin", count: 17, under: docs)
        try write(".sdi-recently-deleted/old/original.bin", count: 23, under: docs)
        try write("Media/audio.wav", count: 31, under: docs)
        try write("Messages/historical.sqlite", count: 37, under: docs)
        try write("exports/final.mp4", count: 41, under: docs)
        try write("AI/historical.json", count: 43, under: caches)
        try write("Thumbnails/unknown.png", count: 47, under: caches)
        try write("outside/sentinel", count: 10_000, under: root)
        try FileManager.default.createSymbolicLink(at: docs.appendingPathComponent("Media/linked-directory"), withDestinationURL: root.appendingPathComponent("outside"))
        try FileManager.default.createSymbolicLink(at: caches.appendingPathComponent("linked-file"), withDestinationURL: root.appendingPathComponent("outside/sentinel"))
        let fifo = docs.appendingPathComponent("special")
        try require(mkfifo(fifo.path, 0o600) == 0, "FIFO fixture")
        let measured = try store.storageScanRequest.scan()
        try require(measured.projects.bytes == 17 && measured.projects.files == 1, "Projects include logical regular bytes only")
        try require(measured.recentlyDeleted.bytes == 23 && measured.recentlyDeleted.files == 1, "Recovery is retained and measured")
        try require(measured.media.bytes == 31 && measured.media.files == 1, "Symlink subtree must not be followed")
        try require(measured.otherDocuments.bytes == 78 && measured.otherDocuments.files == 2, "History and export accounted")
        try require(measured.preservedCaches.bytes == 90 && measured.preservedCaches.files == 2, "Unclassified disk cache accurately measured")
        try require(measured.totalFileBytes == 239 && measured.skippedLinksAndSpecialFiles == 3, "No directory bytes, outside target bytes, or special files counted")
        print("PASS real filesystem breakdown and no-follow traversal")

        var checkpoints = 0
        do {
            _ = try store.storageScanRequest.scan(checkCancellation: {
                checkpoints += 1; if checkpoints == 5 { throw CancellationError() }
            })
            throw Failure(message: "Mid-scan cancellation returned a partial total")
        } catch is CancellationError { }
        try require(checkpoints == 5, "Cancellation checked during traversal")
        try rejects { _ = try store.storageScanRequest.scan(maximumEntries: 2) }
        try rejects { _ = try store.storageScanRequest.scan(maximumDepth: 1) }
        print("PASS bounded scan and real mid-scan cancellation")

        let linkedRoot = root.appendingPathComponent("LinkedDocuments")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: docs)
        try rejects { _ = try StudioStorageScanRequest(documents: linkedRoot, caches: caches).scan() }
        try rejects { _ = try StudioStorageScanRequest(documents: docs, caches: docs.appendingPathComponent("nested")).scan() }
        try rejects { _ = try StudioStorageScanRequest(documents: root.appendingPathComponent("outside/sentinel"), caches: caches).scan() }
        let empty = try StudioStorageScanRequest(documents: root.appendingPathComponent("MissingDocs"), caches: root.appendingPathComponent("MissingCaches")).scan()
        try require(empty.totalFileBytes == 0, "Absent roots genuinely empty")
        print("PASS unreadable/unsafe roots fail rather than showing zero")

        // Seed the actual production cache through a complete saved animation.
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAEUlEQVR4nGP8z4AATEhsPBwAM9EBBzDn4UwAAAAASUVORK5CYII=")!
        let id = UUID()
        let project = AnimationProject(id: id, metadata: AnimationMetadata(id: id, title: "Cache fixture", fps: 12,
            canvasWidth: 4, canvasHeight: 4, frameCount: 1, layerCount: 1, createdAt: Date(), modifiedAt: Date(), thumbnailData: png),
            frames: [StoredAnimationFrame(imageData: png, sourceImage: StoredImageSource(id: UUID(), name: "fixture.png", container: "png",
                originalData: png, originalWidth: 4, originalHeight: 4, originalOrientation: 1,
                normalizedWidth: 4, normalizedHeight: 4))], audioTracks: [])
        try store.saveAnimation(project)
        let seeded = DeviceStorageManager.snapshotEncodingCacheFootprint
        try require(seeded.entries > 0 && seeded.bytes > 0, "Real saved-frame encoder populated cache")
        do { try store.clearCache(checkCancellation: { throw CancellationError() }); throw Failure(message: "Clear ignored cancellation") }
        catch is CancellationError { }
        try require(DeviceStorageManager.snapshotEncodingCacheFootprint.bytes == seeded.bytes, "Cancelled clear changed live cache")
        let before = try store.storageScanRequest.scan()
        let receipt = try store.clearCache()
        try require(receipt.entries == seeded.entries && receipt.releasedMemoryBytes == seeded.bytes, "Receipt must match cache bytes actually released")
        try require(DeviceStorageManager.snapshotEncodingCacheFootprint.entries == 0 && DeviceStorageManager.snapshotEncodingCacheFootprint.bytes == 0, "Actual cache released")
        let after = try store.storageScanRequest.scan()
        try require(before.totalFileBytes == after.totalFileBytes, "Clear must not erase disk data")
        for (url, original) in files { try require(try Data(contentsOf: url) == original, "Original/historical/export bytes changed") }
        let coldStore = DeviceStorageManager(documentsDirectory: docs, cachesDirectory: caches)
        let reopened = try coldStore.loadAnimation(id: id)
        try require(reopened?.frames == project.frames && reopened?.metadata.thumbnailData == png, "Cache clear broke actual cold reopen")
        print("PASS real cache clear receipt, cancellation, preservation and cold reopen")

        // Every fixture uses the actual production save/selector/cleanup path.
        func revisionFixture(_ name: String, saves: Int = 5) throws -> (DeviceStorageManager, AnimationProject, URL) {
            let fixtureRoot = root.appendingPathComponent(name)
            let store = DeviceStorageManager(documentsDirectory: fixtureRoot)
            var value = project
            for index in 0..<saves {
                value.metadata.title = "Version \(index)"
                try store.saveAnimation(value)
            }
            return (store, value, store.animationsDir.appendingPathComponent(value.id.uuidString + "/.sdi"))
        }
        func payloads(_ storage: URL) throws -> [String: Data] {
            let revisions = storage.appendingPathComponent("revisions")
            return try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(atPath: revisions.path).map {
                ($0, try Data(contentsOf: revisions.appendingPathComponent($0)))
            })
        }
        let (clean, latest, cleanPath) = try revisionFixture("cleanup-success")
        let beforePayloads = try payloads(cleanPath)
        let plan = try clean.previewObsoleteRevisions(id: latest.id)
        try require(plan.candidates == 3 && plan.retainedRevisions == 2, "Exactly three obsolete selected saves eligible")
        let outcome = try clean.removeObsoleteRevisions(id: latest.id, expectedSelectedRevision: plan.selectedRevision, expectedConfirmationToken: plan.confirmationToken)
        let afterPayloads = try payloads(cleanPath)
        try require(outcome.removedRevisions == 3 && outcome.removedFileBytes == plan.removableFileBytes && outcome.stoppedReason == nil, "Accurate actual removed logical bytes")
        try require(afterPayloads.count == 2, "Current and previous survive")
        for (name, bytes) in afterPayloads { try require(beforePayloads[name] == bytes, "Retained revision changed") }
        try require(try clean.loadAnimation(id: latest.id)?.metadata.title == latest.metadata.title, "Cold production load after cleanup")
        try require(try clean.previewObsoleteRevisions(id: latest.id).candidates == 0, "Deleted ancestry journals permit repeat inspection")
        try clean.saveAnimation(latest)
        try require(try clean.previewObsoleteRevisions(id: latest.id).candidates == 1, "New save can reuse complete retained ancestry")
        print("PASS prospective lineage, exact cleanup bytes, retained recovery and new-save/retry")

        final class FailedCommitStore: DeviceStorageManager {
            var failing = false
            override func commitCurrentRevision(_ data: Data, to pointer: URL) throws {
                if failing { throw Failure(message: "Injected selector failure") }
                try super.commitCurrentRevision(data, to: pointer)
            }
        }
        let failed = FailedCommitStore(documentsDirectory: root.appendingPathComponent("failed-save"))
        try failed.saveAnimation(project)
        failed.failing = true
        try rejects { try failed.saveAnimation(project) }
        let failedPath = failed.animationsDir.appendingPathComponent(project.id.uuidString + "/.sdi")
        let originalTwo = try payloads(failedPath)
        failed.failing = false
        for _ in 0..<3 { try failed.saveAnimation(project) }
        let failedPlan = try failed.previewObsoleteRevisions(id: project.id)
        try require(failedPlan.candidates == 2, "Failed save must not join selected ancestry")
        _ = try failed.removeObsoleteRevisions(id: project.id, expectedSelectedRevision: failedPlan.selectedRevision, expectedConfirmationToken: failedPlan.confirmationToken)
        let failedAfter = try payloads(failedPath)
        try require(failedAfter.count == 3, "Two retained plus unique failed-save orphan")
        try require(originalTwo.filter { failedAfter[$0.key] == $0.value }.count == 1, "Original orphan bytes retained")
        print("PASS failed selector orphan preserved without timestamp inference")

        let (legacy, _, legacyPath) = try revisionFixture("legacy-boundary", saves: 2)
        let legacyPointer = legacyPath.appendingPathComponent("current.json")
        var selector = try JSONSerialization.jsonObject(with: Data(contentsOf: legacyPointer)) as! [String: Any]
        selector.removeValue(forKey: "lineageSHA256")
        try JSONSerialization.data(withJSONObject: selector).write(to: legacyPointer, options: .atomic)
        let historical = try payloads(legacyPath)
        for _ in 0..<4 { try legacy.saveAnimation(project) }
        let legacyPlan = try legacy.previewObsoleteRevisions(id: project.id)
        try require(legacyPlan.candidates == 2, "Only prospective descendants beyond legacy boundary eligible")
        _ = try legacy.removeObsoleteRevisions(id: project.id, expectedSelectedRevision: legacyPlan.selectedRevision, expectedConfirmationToken: legacyPlan.confirmationToken)
        let legacyAfter = try payloads(legacyPath)
        for (name, bytes) in historical { try require(legacyAfter[name] == bytes, "Pre-lineage snapshot deleted") }
        print("PASS backward-compatible selector and historical lineage boundary")

        for stage in ["journal-durable", "payload-staged", "payload-removed"] {
            let (interrupted, _, path) = try revisionFixture("interrupted-" + stage, saves: 3)
            let preview = try interrupted.previewObsoleteRevisions(id: project.id)
            var injected = false
            do {
                let receipt = try interrupted.removeObsoleteRevisions(id: project.id, expectedSelectedRevision: preview.selectedRevision, expectedConfirmationToken: preview.confirmationToken,
                    checkpoint: { point, _ in if point == stage { injected = true; throw Failure(message: "Injected interruption") } })
                try require(stage == "payload-removed" && receipt.removedRevisions == 1 && receipt.stoppedReason != nil, "Partial deletion falsely reported absent")
            } catch {
                try require(stage != "payload-removed", "Completed deletion must have truthful receipt")
            }
            try require(injected, "Failure checkpoint never reached")
            let reopened = DeviceStorageManager(documentsDirectory: path.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
            try require(try reopened.loadAnimation(id: project.id)?.metadata.title == "Version 2", "Interrupted cleanup damaged current")
            let again = try interrupted.previewObsoleteRevisions(id: project.id)
            let resumed = try interrupted.removeObsoleteRevisions(id: project.id, expectedSelectedRevision: again.selectedRevision, expectedConfirmationToken: again.confirmationToken)
            try require(resumed.removedRevisions == (stage == "payload-removed" ? 0 : 1), "Resume duplicated deletion accounting")
            try require(try payloads(path).count == 2, "Resume failed to preserve two complete snapshots")
        }
        print("PASS durable-journal/staged/unlinked interruption and actual cold-store retry")

        let (cancelled, _, cancelledPath) = try revisionFixture("cancelled")
        let cancelBefore = try payloads(cancelledPath)
        let cancelPreview = try cancelled.previewObsoleteRevisions(id: project.id)
        do {
            _ = try cancelled.removeObsoleteRevisions(id: project.id, expectedSelectedRevision: cancelPreview.selectedRevision, expectedConfirmationToken: cancelPreview.confirmationToken,
                checkCancellation: { throw CancellationError() })
            throw Failure(message: "Cancellation ignored")
        } catch is CancellationError { }
        try require(try payloads(cancelledPath) == cancelBefore, "Cancelled-before-commit cleanup removed data")
        var cancelNext = false
        let partial = try cancelled.removeObsoleteRevisions(id: project.id, expectedSelectedRevision: cancelPreview.selectedRevision, expectedConfirmationToken: cancelPreview.confirmationToken,
            checkCancellation: { if cancelNext { throw CancellationError() } },
            checkpoint: { point, _ in if point == "payload-removed" { cancelNext = true } })
        try require(partial.removedRevisions == 1 && partial.stoppedReason != nil, "Mid-batch cancellation must report completed work")
        try cancelled.saveAnimation(project)
        try rejects { _ = try cancelled.removeObsoleteRevisions(id: project.id, expectedSelectedRevision: cancelPreview.selectedRevision, expectedConfirmationToken: cancelPreview.confirmationToken) }
        print("PASS cancellation before/after commit and stale confirmation refusal")

        for fault in ["pointer", "receipt", "symlink", "fifo", "hardlink", "lock"] {
            let (unsafe, _, path) = try revisionFixture("unsafe-" + fault)
            let preview = try unsafe.previewObsoleteRevisions(id: project.id)
            let pointer = path.appendingPathComponent("current.json")
            let revisions = path.appendingPathComponent("revisions")
            let name = preview.selectedRevision.uuidString + ".json"
            let selected = revisions.appendingPathComponent(name)
            switch fault {
            case "pointer": try Data("invalid".utf8).write(to: pointer)
            case "receipt": try Data("invalid".utf8).write(to: path.appendingPathComponent("lineage-v1/" + name))
            case "symlink":
                try FileManager.default.removeItem(at: selected)
                try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: root.appendingPathComponent("outside/sentinel"))
            case "fifo":
                try FileManager.default.removeItem(at: selected)
                try require(mkfifo(selected.path, 0o600) == 0, "FIFO revision fixture")
            case "hardlink": try FileManager.default.linkItem(at: selected, to: root.appendingPathComponent("extra-link-" + fault))
            default: try Data("not ours".utf8).write(to: path.appendingPathComponent(".revision-mutation-lock-v1"))
            }
            let countBefore = try FileManager.default.contentsOfDirectory(atPath: revisions.path).count
            try rejects { _ = try unsafe.removeObsoleteRevisions(id: project.id, expectedSelectedRevision: preview.selectedRevision, expectedConfirmationToken: preview.confirmationToken) }
            try require(try FileManager.default.contentsOfDirectory(atPath: revisions.path).count == countBefore, "Unsafe storage was mutated")
        }
        print("PASS malformed ownership, symlink/FIFO/hardlink and lock-collision refusal")

        let (locked, _, lockedPath) = try revisionFixture("cross-process-lock")
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["hold-revision-lock", lockedPath.appendingPathComponent(".revision-mutation-lock-v1").path]
        child.standardInput = input; child.standardOutput = output
        try child.run()
        try output.fileHandleForWriting.close()
        try input.fileHandleForReading.close()
        do {
            defer { try? input.fileHandleForWriting.close(); child.waitUntilExit() }
            let ready = output.fileHandleForReading.readData(ofLength: 1)
            try require(ready == Data([1]), "Separate process failed to acquire real flock")
            let before = try payloads(lockedPath)
            try rejects { _ = try locked.previewObsoleteRevisions(id: project.id) }
            try rejects { try locked.saveAnimation(project) }
            try rejects { try locked.recoverableDeleteAnimation(id: project.id) }
            try require(try payloads(lockedPath) == before, "Contending operations wrote through another process owner")
        }
        try require(child.terminationStatus == 0, "Owner process failed to release lock")
        try require(try locked.previewObsoleteRevisions(id: project.id).candidates == 3, "Released cross-process owner left storage unavailable")
        print("PASS actual separate-process flock excludes preview/save/recoverable-delete")

        let (paged, _, pagedPath) = try revisionFixture("stale-batch-consent", saves: 20)
        let firstConsent = try paged.previewObsoleteRevisions(id: project.id)
        let otherConsent = try paged.previewObsoleteRevisions(id: project.id)
        try require(firstConsent.candidates == 8 && firstConsent.moreBatchesAvailable, "Cleanup must be bounded to reviewed batch")
        let firstRemoval = try paged.removeObsoleteRevisions(id: project.id, expectedSelectedRevision: firstConsent.selectedRevision,
            expectedConfirmationToken: firstConsent.confirmationToken)
        try require(firstRemoval.removedRevisions == 8, "First bounded cleanup")
        let remaining = try payloads(pagedPath)
        let nextConsent = try paged.previewObsoleteRevisions(id: project.id)
        try require(nextConsent.selectedRevision == otherConsent.selectedRevision && nextConsent.confirmationToken != otherConsent.confirmationToken,
            "Same current selector must not authorize a changed batch")
        try rejects { _ = try paged.removeObsoleteRevisions(id: project.id, expectedSelectedRevision: otherConsent.selectedRevision,
            expectedConfirmationToken: otherConsent.confirmationToken) }
        try require(try payloads(pagedPath) == remaining, "Stale confirmation deleted unreviewed next batch")
        print("PASS exact batch consent rejects changed candidates with unchanged current selector")

        for checkpoint in ["journal-durable", "payload-staged"] {
            let (mutating, _, path) = try revisionFixture("changed-selector-" + checkpoint, saves: 3)
            let preview = try mutating.previewObsoleteRevisions(id: project.id)
            let originals = try payloads(path)
            try rejects {
                _ = try mutating.removeObsoleteRevisions(id: project.id, expectedSelectedRevision: preview.selectedRevision,
                    expectedConfirmationToken: preview.confirmationToken, checkpoint: { stage, target in
                        if stage == checkpoint {
                            let pointer = ["version": 1, "revision": target.uuidString] as [String: Any]
                            try JSONSerialization.data(withJSONObject: pointer).write(to: path.appendingPathComponent("current.json"), options: .atomic)
                        }
                    })
            }
            try require(try payloads(path) == originals, "Changed selector lost or staged its newly selected payload")
            try require(try mutating.loadAnimation(id: project.id)?.metadata.title == "Version 0", "Changed selector no longer readable")
        }
        print("PASS selector mutation before/after staging preserves newly selected original")
    }
}
