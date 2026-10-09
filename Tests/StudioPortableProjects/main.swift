import Foundation
import AppKit
import SwiftUI
import AVFoundation

typealias UIImage = NSImage
extension Image { init(uiImage: NSImage) { self.init(nsImage: uiImage) } }
private struct Failure: Error { let message: String }
private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw Failure(message: message) }
}
@main @MainActor struct PortableProjectTests {
    static func main() async {
        do { try await run() } catch { print("STUDIO_PORTABLE_PROJECT_TESTS=FAIL \(error)"); exit(1) }
    }
    static func run() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sdi-portable-journey-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let storage = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("documents"))
        let vm = StudioViewModel(storage: storage)
        let created = await vm.createProject(name: "Portable originals", width: 64, height: 64, fps: 8)
        try require(created, "Create failed")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 256, bitsPerPixel: 32)!
        for y in 0..<64 { for x in 0..<64 { bitmap.setColor(.red, atX: x, y: y) } }
        let imageURL = root.appendingPathComponent("original.png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: imageURL)
        let image = try await StudioImageImportService.shared.importImage(from: imageURL)
        _ = try vm.attachImportedImage(image, expectedProjectID: vm.document.id, expectedRevision: vm.document.revision,
            frameID: vm.document.activeFrameID, layerID: vm.document.activeLayerID)
        let audioURL = root.appendingPathComponent("original.wav")
        try autoreleasepool {
            let writer = try AVAudioFile(forWriting: audioURL, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
            let buffer = AVAudioPCMBuffer(pcmFormat: writer.processingFormat, frameCapacity: 6000)!
            buffer.frameLength = 6000
            for n in 0..<6000 { buffer.floatChannelData![0][n] = Float(sin(Double(n) * 2 * .pi * 440 / 48_000) * 0.25) }
            try writer.write(from: buffer)
        }
        let audio = try await StudioAudioImportService().importAudio(from: audioURL)
        _ = try vm.attachImportedAudio(audio.track, expectedProjectID: vm.document.id, expectedRevision: vm.document.revision,
            frameID: vm.document.activeFrameID, trackNumber: 1)
        let saved = await vm.save(); try require(saved, "Actual save failed")
        let originalID = vm.document.id
        let original = try storage.loadAnimation(id: originalID)!
        await vm.backToProjects()
        let backup = try await vm.preparePortableBackup(original.metadata)
        let file = root.appendingPathComponent("project.sdiproject"); try backup.write(to: file)
        let imported = try await vm.importPortableProject(from: file)
        let second = try await vm.importPortableProject(backup)
        try require(imported.id != originalID && second.id != imported.id && second.id != originalID, "Import overwrote identity")
        let afterOriginal = try storage.loadAnimation(id: originalID)!
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try require(try encoder.encode(afterOriginal) == encoder.encode(original), "Import changed original source project")
        let newProject = try storage.loadAnimation(id: imported.id)!
        let audioMatches = try encoder.encode(newProject.audioTracks) == encoder.encode(original.audioTracks)
        try require(newProject.frames == original.frames && audioMatches, "Portable import changed original asset bytes or provenance")
        let cold = StudioViewModel(storage: storage)
        let opened = await cold.openProject(imported)
        try require(opened && cold.document.id == imported.id && cold.rasterData(cold.currentFrame.rasterAssetID) == image.normalizedPNG,
            "Imported project cannot cold reopen/render its real image")
        try require(cold.audioTrack(forAssetID: audio.id)?.audioData == audio.originalData, "Imported managed soundtrack cannot reopen")
        await cold.backToProjects()
        var withHistorical = original
        let historical = AudioTrack(id: UUID(), name: "Unreferenced original", format: "wav",
            audioData: Data("opaque historical bytes".utf8), startTime: 0, duration: 0.125,
            legacySourceFilename: "old.wav")
        withHistorical.audioTracks.append(historical)
        let historicalBundle = try storage.portableBundle(for: withHistorical)
        let historicalCopy = try await vm.importPortableProject(historicalBundle)
        let restoredHistorical = try storage.loadAnimation(id: historicalCopy.id)!.audioTracks.first { $0.id == historical.id }
        try require(restoredHistorical?.audioData == historical.audioData && restoredHistorical?.legacySourceFilename == "old.wav",
            "Truly unreferenced historical source bytes/provenance changed")
        var totalCheckpoints = 0
        _ = try await vm.importPortableProject(backup, checkCancellation: { totalCheckpoints += 1 })
        let count = try storage.listAnimationsReportingFailures().animations.count
        do { _ = try await vm.importPortableProject(backup, newProjectID: originalID); throw Failure(message: "Collision accepted") }
        catch AnimationStorageError.storageCollision { }
        var damaged = backup; damaged[damaged.count - 1] ^= 1
        do { _ = try await vm.importPortableProject(damaged); throw Failure(message: "Corruption accepted") }
        catch is Failure { throw Failure(message: "Corruption accepted") } catch { }
        var checkpoints = 0
        do { _ = try await vm.importPortableProject(backup, checkCancellation: {
            checkpoints += 1
            if checkpoints == totalCheckpoints { throw CancellationError() }
        }); throw Failure(message: "Cancellation accepted") }
        catch is CancellationError { }
        try require(checkpoints == totalCheckpoints, "Cancellation did not reach final validation/commit boundary")
        var malformed = original; malformed.editableDocumentData = Data("not an editable archive".utf8)
        let malformedBundle = try storage.portableBundle(for: malformed)
        do { _ = try await vm.importPortableProject(malformedBundle); throw Failure(message: "Invalid editable archive accepted") }
        catch is Failure { throw Failure(message: "Invalid editable archive accepted") } catch { }
        for mismatch in [false, true] {
            var badAudio = original
            if mismatch { badAudio.audioTracks[0].duration += 0.025 }
            else { badAudio.audioTracks[0].audioData = Data("corrupt managed WAV with a valid portable checksum".utf8) }
            let checkedButInvalidAudio = try storage.portableBundle(for: badAudio)
            do { _ = try await vm.importPortableProject(checkedButInvalidAudio); throw Failure(message: "Undecodable or duration-mismatched managed audio accepted") }
            catch is Failure { throw Failure(message: "Undecodable or duration-mismatched managed audio accepted") } catch { }
        }
        var forgedLegacy = original
        forgedLegacy.audioTracks[0].legacySourceFilename = "old.wav"
        forgedLegacy.audioTracks[0].audioData = Data("corrupt referenced WAV disguised as legacy".utf8)
        let forgedLegacyBundle = try storage.portableBundle(for: forgedLegacy)
        do { _ = try await vm.importPortableProject(forgedLegacyBundle); throw Failure(message: "Referenced legacy marker bypassed validation") }
        catch is Failure { throw Failure(message: "Referenced legacy marker bypassed validation") } catch { }
        // All three per-asset records fit 16MiB, but the referenced aggregate
        // exceeds the normal editor's 32MiB. Reject before decoding any bytes.
        var oversized = original
        var archive = try StudioDocumentArchive.decode(original.editableDocumentData!)
        oversized.audioTracks = []; archive.document.audioClips = []
        for index in 0..<3 {
            let id = UUID()
            oversized.audioTracks.append(AudioTrack(id: id, name: "Budget fixture", format: "wav",
                audioData: Data(repeating: 0, count: 12 * 1024 * 1024), startTime: 0, duration: 0.125))
            archive.document.audioClips.append(AudioClip(id: UUID().uuidString, soundName: "Budget fixture",
                track: index + 1, startTime: 0, duration: 0.125, volume: 1, assetID: id))
        }
        oversized.editableDocumentData = try archive.encoded()
        let oversizedBundle = try storage.portableBundle(for: oversized)
        do { _ = try await vm.importPortableProject(oversizedBundle); throw Failure(message: "Managed audio aggregate limit bypassed") }
        catch let error as StudioDocumentError {
            try require(error.localizedDescription.contains("byte limits"), "Oversized audio was not rejected by aggregate preflight")
        }
        let link = root.appendingPathComponent("linked.sdiproject")
        try fm.createSymbolicLink(at: link, withDestinationURL: file)
        do { _ = try await vm.importPortableProject(from: link); throw Failure(message: "Symlink accepted") }
        catch is Failure { throw Failure(message: "Symlink accepted") } catch { }
        try require(try storage.listAnimationsReportingFailures().animations.count == count && !vm.isManagingProjects,
            "Rejected import altered project library or left busy state")
        try require(try Data(contentsOf: file) == backup && Data(contentsOf: imageURL) == image.originalData,
            "Provider or original image file changed")
        print("STUDIO_PORTABLE_PROJECT_TESTS=PASS real Files transport, managed image/audio bytes, two fresh identities, cold reopen, collision, checksum, cancel and symlink rejection")
    }
}
