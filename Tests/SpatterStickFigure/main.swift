import Foundation
import AppKit
import SwiftUI
import AVFoundation
import CryptoKit
import Darwin

typealias UIImage = NSImage
extension Image { init(uiImage: NSImage) { self.init(nsImage: uiImage) } }
private struct Failure: Error { let message: String }
private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw Failure(message: message) }
}
private func rejects(_ action: () throws -> Void) throws {
    do { try action() } catch { return }; throw Failure(message: "Unsupported request accepted")
}
@main @MainActor struct StickFigureTests {
    static func idle(_ session: SpatterStudioEditSession) async throws {
        for _ in 0..<400 {
            if !session.isWorking { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw Failure(message: "Session did not finish")
    }
    static func main() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-stick-recipe-\(UUID())")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            let scope = SpatterStudioEditSession.Scope(isStudioVisible: true, accountID: nil)
            var poseSignatures = Set<Data>()
            for (index, action) in SpatterStickFigureRecipe.Action.allCases.enumerated() {
                let count = [12, 16, 20, 20][index]
                let colors = ["black", "red", "blue", "green"]
                let instruction = action.example.replacingOccurrences(of: "20 frames", with: "\(count) frames")
                    .replacingOccurrences(of: "black", with: colors[index])
                let store = DeviceStorageManager(documentsDirectory: root.appendingPathComponent(action.rawValue))
                let vm = StudioViewModel(storage: store)
                let created = await vm.createProject(name: "Original procedural \(action.rawValue)", width: 256, height: 256, fps: 24)
                try require(created, "Create failed")
                vm.activePanel = .spatterAI
                let before = vm.document
                let recipe = try SpatterStickFigureRecipe.parse(instruction)
                let context = vm.commandScreenContext.document!
                var checks = 0
                _ = try recipe.prepare(in: context, checkCancellation: { checks += 1 })
                for boundary in 1...checks {
                    var at = 0
                    try rejects { _ = try recipe.prepare(in: context, checkCancellation: { at += 1; if at == boundary { throw CancellationError() } }) }
                }
                let session = SpatterStudioEditSession()
                try require(session.submit(instruction, in: vm, accountID: nil, currentScope: { scope }), "Session rejected supported action")
                try await idle(session)
                try require(session.status == .applied && session.appliedEdit?.addedFrameCount == count, "Session did not apply \(action.rawValue): \(session.status), \(session.notice ?? "no notice"), count=\(session.appliedEdit?.addedFrameCount ?? -1)")
                try require(vm.frames.count == count + before.frames.count && vm.frames[0] == before.frames[0], "Original frame changed")
                let generated = Array(vm.frames.suffix(count))
                try require(generated.allSatisfy { $0.elements.count == 10 && $0.elements.filter { $0.tool == .circle }.count == 1 }, "Figure is not editable limbs/head")
                try require(generated.allSatisfy { $0.elements.allSatisfy { $0.color == recipe.color && $0.width == 3 } }, "Prompt color/width ignored")
                // Limb lengths are invariant in every frame, not rubber-band interpolation.
                for frame in generated {
                    for part in [1, 2, 5, 6] {
                        let points = frame.elements[part].points
                        let length = hypot(Double(points[1].x - points[0].x), Double(points[1].y - points[0].y))
                        try require(abs(length - 256 * 0.35 * 0.25) < 0.00001, "Leg bone changed length")
                    }
                    for part in [3, 4, 7, 8] {
                        let points = frame.elements[part].points
                        let length = hypot(Double(points[1].x - points[0].x), Double(points[1].y - points[0].y))
                        try require(abs(length - 256 * 0.35 * 0.20) < 0.00001, "Arm bone changed length")
                    }
                }
                let poses = generated.map { $0.elements.flatMap { $0.points.map { [Double($0.x), Double($0.y)] } } }
                let encoded = try JSONEncoder().encode(poses)
                try require(Set(poses.map { String(describing: $0) }).count > count / 2, "Action used a repeated static pose")
                poseSignatures.insert(Data(SHA256.hash(data: encoded)))
                let generatedDocument = vm.document
                vm.undo(); try require(vm.frames == before.frames && vm.layers == before.layers, "Generated action not one Undo")
                vm.redo(); try require(vm.frames == generatedDocument.frames, "Redo changed generated frames")
                let id = vm.document.id
                await vm.backToProjects()
                let saved = try store.loadAnimation(id: id)!
                let reopened = StudioViewModel(storage: store)
                let opened = await reopened.openProject(saved.metadata)
                try require(opened && reopened.frames == generatedDocument.frames, "Cold reopen lost editable poses")
                if action == .jumping {
                    let output = try await StudioMovieExportService().export(snapshot: .init(document: reopened.document,
                        retainedAudioTracks: [], rasterDataByID: [:]), outputParent: root, background: .white)
                    let asset = AVURLAsset(url: output.movieURL)
                    let tracks = try await asset.loadTracks(withMediaType: .video)
                    try require(tracks.count == 1, "No actual video stream")
                    let duration = try await asset.load(.duration).seconds
                    try require(abs(duration - Double(count + 1) / 24) < 0.001, "Movie duration ignores recipe FPS")
                    let reader = try AVAssetReader(asset: asset)
                    let frames = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                    reader.add(frames); try require(reader.startReading(), "Movie decoder did not start")
                    var decoded = 0, distinct = Set<Data>()
                    while let sample = frames.copyNextSampleBuffer() {
                        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { throw Failure(message: "Missing decoded movie image") }
                        CVPixelBufferLockBaseAddress(buffer, .readOnly)
                        let data = Data(bytes: CVPixelBufferGetBaseAddress(buffer)!, count: CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
                        distinct.insert(Data(SHA256.hash(data: data))); decoded += 1
                        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
                    }
                    try require(reader.status == .completed && decoded == count + 1 && distinct.count > count / 2, "Movie contains missing/static/fabricated frames")
                    if let path = ProcessInfo.processInfo.environment["SDI_STICK_EVIDENCE_DIRECTORY"] {
                        let folder = URL(fileURLWithPath: path, isDirectory: true)
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: output.movieURL, to: folder.appendingPathComponent("procedural-jump.mp4"))
                        try JSONEncoder().encode(reopened.document).write(to: folder.appendingPathComponent("editable-jump-document.json"), options: .withoutOverwriting)
                    }
                    print("PASS actual H.264 generation/reopen: \(decoded) frames, \(duration) seconds, \(distinct.count) distinct decoded images")
                }
                await reopened.backToProjects()
                print("PASS \(action.rawValue): \(count) editable frames, prompt color, fixed bone lengths, every preparation cancellation checkpoint, one Undo/Redo and cold reopen")
            }
            try require(poseSignatures.count == 4, "Different actions produced the same motion")
            for text in [SpatterStickFigureRecipe.Action.walking.example + " upload to YouTube", SpatterStickFigureRecipe.Action.walking.example.replacingOccurrences(of: "20 frames", with: "100 frames"), SpatterStickFigureRecipe.Action.walking.example.replacingOccurrences(of: "walking", with: "flying"), SpatterStickFigureRecipe.Action.walking.example.replacingOccurrences(of: "35%", with: "nan%") ] {
                try rejects { _ = try SpatterStickFigureRecipe.parse(text) }
            }
            print("PASS unsupported suffix/action/limits/nonfinite input fail closed; no provider or publication path exists")
        } catch { print("FAIL \(error)"); exit(1) }
    }
}
