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
            for (briefIndex, text) in [SpatterSceneBrief.example,
                "A blue stick figure waves right to left, then runs; 3 seconds.",
                "A #00FFFF stick figure jumps left to right, then walks; 1.25 seconds."].enumerated() {
                let store = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("brief-\(briefIndex)"))
                let vm = StudioViewModel(storage: store)
                let created = await vm.createProject(name: "Two-action brief", width: 256, height: 256, fps: 24)
                try require(created, "Brief create")
                vm.activePanel = .spatterAI
                let before = vm.document, brief = try SpatterSceneBrief.parse(text)
                let context = vm.commandScreenContext.document!
                var checks = 0
                let prepared = try brief.prepare(in: context, checkCancellation: { checks += 1 })
                for boundary in 1...checks {
                    var at = 0
                    try rejects { _ = try brief.prepare(in: context, checkCancellation: { at += 1; if at == boundary { throw CancellationError() } }) }
                }
                let session = SpatterStudioEditSession()
                try require(session.submit(text, in: vm, accountID: nil, currentScope: { scope }), "Brief session submission")
                try await idle(session)
                try require(session.status == .applied, "Brief session rejected: \(session.notice ?? "nil")")
                let frames = Array(vm.frames.suffix(prepared.framesToAdd)), result = vm.document
                try require(frames.allSatisfy { $0.elements.count == 10 && $0.elements.allSatisfy { $0.color == brief.color } }, "Brief lost editable/color-specific pose")
                let ticks = frames.reduce(0) { $0 + $1.durationTicks }
                try require(ticks == Int((brief.seconds * 24).rounded()) && session.appliedEdit?.addedDurationSeconds == Double(ticks) / 24,
                    "Brief ignored duration or reported frame count as duration")
                let boundary = frames.count / 2
                for (first, next) in zip(frames[boundary - 1].elements, frames[boundary].elements) {
                    for (a, b) in zip(first.points, next.points) {
                        try require(hypot(Double(a.x - b.x), Double(a.y - b.y)) < 0.000001, "Action boundary jumps position/pose")
                    }
                }
                let firstX = frames.first!.elements[0].points[0].x, lastX = frames.last!.elements[0].points[0].x
                try require(brief.movesRight ? lastX > firstX : lastX < firstX, "Brief direction ignored")
                let firstActionTravel = abs(frames[boundary - 1].elements[0].points[0].x - firstX)
                try require(brief.actions[0] == .waving ? firstActionTravel < 0.001 : firstActionTravel > 20,
                    "Brief action order ignored")
                vm.undo(); try require(vm.frames == before.frames && vm.layers == before.layers, "Brief is not one Undo")
                vm.redo(); try require(vm.frames == result.frames, "Brief Redo changed poses")
                let saved = await vm.save(); try require(saved, "Brief save")
                let stored = try store.loadAnimation(id: result.id)!, reopened = StudioViewModel(storage: store)
                let opened = await reopened.openProject(stored.metadata)
                try require(opened && reopened.frames == result.frames, "Brief cold reopen lost timing/poses")
                if briefIndex == 0 {
                    let output = try await StudioMovieExportService().export(snapshot: .init(document: reopened.document,
                        retainedAudioTracks: [], rasterDataByID: [:]), outputParent: root, background: .white)
                    let duration = try await AVURLAsset(url: output.movieURL).load(.duration).seconds
                    try require(abs(duration - Double(ticks + 1) / 24) < 0.001, "Brief MP4 duration ignores frame holds")
                }
                await reopened.backToProjects(); await vm.backToProjects()
                print("PASS composite brief: color/direction/action order, neutral continuity, timed receipt, cancellation, one Undo, reopen and export")
            }
            for text in [SpatterTwoActorBrief.example,
                         "Two stick figures: green runs right to left; purple jumps left to right; 2 seconds."] {
                let store = DeviceStorageManager(documentsDirectory: root.appendingPathComponent(UUID().uuidString))
                let vm = StudioViewModel(storage: store)
                let created = await vm.createProject(name: "Two independently editable actors", width: 256, height: 256, fps: 12)
                try require(created, "Two-actor create failed"); vm.activePanel = .spatterAI
                let before = vm.document, brief = try SpatterTwoActorBrief.parse(text)
                let context = vm.commandScreenContext.document!
                var checks = 0
                let plan = try brief.prepare(in: context, checkCancellation: { checks += 1 })
                try require(plan.framesToAdd == 24 && plan.durationSeconds == 2, "Two-actor timing changed")
                for boundary in 1...checks {
                    var at = 0
                    try rejects { _ = try brief.prepare(in: context, checkCancellation: { at += 1; if at == boundary { throw CancellationError() } }) }
                }
                let session = SpatterStudioEditSession()
                try require(session.submit(text, in: vm, accountID: nil, currentScope: { scope }), "Two-actor submit failed")
                try await idle(session)
                try require(session.status == .applied, "Two-actor actual VM failed: \(session.notice ?? "nil")")
                let result = vm.document, frames = Array(vm.frames.suffix(24))
                try require(frames.count == 24 && frames.allSatisfy { $0.elements.count == 20 && $0.durationTicks == 1 }, "Poses flattened, omitted or stretched")
                try require(vm.layers.count == before.layers.count + 2 && vm.frames[0] == before.frames[0], "Actor layers/original changed")
                for actor in 0..<2 {
                    let poses = frames.map { $0.elements.filter { $0.color == brief.actors[actor].color } }
                    try require(poses.allSatisfy { $0.count == 10 }, "Actor color/count ignored")
                    try require(Set(poses.flatMap { $0.compactMap(\.layerID) }).count == 1, "Actor has no independent layer")
                    try require(Set(poses.map { String(describing: $0.map(\.points)) }).count >= 20, "Two-actor poses repeated instead of per-tick motion")
                    let firstX = poses.first![0].points[0].x, lastX = poses.last![0].points[0].x
                    if brief.actors[actor].action == .waving { try require(abs(firstX-lastX) < 0.001, "Stationary actor moved") }
                    else { try require(brief.actors[actor].movesRight ? lastX > firstX : lastX < firstX, "Actor direction ignored") }
                }
                // Compare real raster output with the old repeated commit path,
                // using exactly the same actor identities and drawing metadata.
                var blank = result
                let comparedIndex = blank.frames.count - 12
                let expectedElements = blank.frames[comparedIndex].elements
                blank.frames[comparedIndex].elements = []
                var repeated = try StudioDocumentEditor(document: blank)
                for element in expectedElements { try repeated.commit(element, frameID: blank.frames[comparedIndex].id) }
                let rasterizer = StudioExportService()
                let actualPixels = try rasterizer.render(result.frames[comparedIndex], document: result, background: .white, raster: nil)
                let repeatedPixels = try rasterizer.render(repeated.document.frames[comparedIndex], document: repeated.document, background: .white, raster: nil)
                guard let actualBytes = actualPixels.dataProvider?.data, let repeatedBytes = repeatedPixels.dataProvider?.data else {
                    throw Failure(message: "Primitive equivalence pixels unavailable")
                }
                try require(actualBytes as Data == repeatedBytes as Data, "Batched primitives changed actual rendered pixels")
                vm.undo(); try require(vm.frames == before.frames && vm.layers == before.layers, "Scene not one Undo")
                vm.redo(); try require(vm.frames == result.frames && vm.layers == result.layers, "Scene Redo changed")
                let id = vm.document.id
                await vm.backToProjects()
                let saved = try store.loadAnimation(id: id)!, reopened = StudioViewModel(storage: store)
                let opened = await reopened.openProject(saved.metadata)
                try require(opened && reopened.frames == result.frames && reopened.layers == result.layers, "Two-actor reopen lost edits")
                let output = try await StudioMovieExportService().export(snapshot: .init(document: reopened.document,
                    retainedAudioTracks: [], rasterDataByID: [:]), outputParent: root, background: .white)
                let asset = AVURLAsset(url: output.movieURL), duration = try await asset.load(.duration).seconds
                try require(abs(duration - 25.0 / 12) < 0.001, "Two-actor real MP4 duration wrong")
                let track = try await asset.loadTracks(withMediaType: .video)[0]
                let reader = try AVAssetReader(asset: asset)
                let decoded = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                reader.add(decoded); try require(reader.startReading(), "Two-actor decode start")
                var count = 0, distinct = Set<Data>()
                while let sample = decoded.copyNextSampleBuffer() {
                    guard let buffer = CMSampleBufferGetImageBuffer(sample) else { throw Failure(message: "Missing duo pixels") }
                    CVPixelBufferLockBaseAddress(buffer, .readOnly)
                    let data = Data(bytes: CVPixelBufferGetBaseAddress(buffer)!, count: CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
                    distinct.insert(Data(SHA256.hash(data: data))); count += 1
                    CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
                }
                try require(reader.status == .completed && count == 25 && distinct.count >= 21, "Two-actor movie has missing/static frames")
                await reopened.backToProjects()
                print("PASS two actors: 24 per-tick editable poses, independent layers/actions/directions, 480 strokes, guarded VM, one Undo, actual reopen and decoded MP4")
            }
            for text in [SpatterTwoActorBrief.example + " publish it", SpatterTwoActorBrief.example.replacingOccurrences(of: "walks", with: "flies"),
                         SpatterTwoActorBrief.example.replacingOccurrences(of: "2 seconds", with: "10 seconds")] {
                try rejects { _ = try SpatterTwoActorBrief.parse(text) }
            }
            do {
                let store = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("duo-timing-reject")), vm = StudioViewModel(storage: store)
                let created = await vm.createProject(name: "No stretched duo", width: 256, height: 256, fps: 24)
                try require(created, "Timing fixture create")
                try rejects { _ = try SpatterTwoActorBrief.parse(SpatterTwoActorBrief.example).prepare(in: vm.commandScreenContext.document!) }
                await vm.backToProjects()
            }
            for text in [SpatterSceneBrief.example + " Upload it", "A red stick figure flies left to right, then waves; 2 seconds.",
                         "A red stick figure waves left to right, then waves; 2 seconds.",
                         "A red stick figure walks left to right, then waves; 500 seconds."] {
                try rejects { _ = try SpatterSceneBrief.parse(text) }
            }
            try require(poseSignatures.count == 4, "Different actions produced the same motion")
            for text in [SpatterStickFigureRecipe.Action.walking.example + " upload to YouTube", SpatterStickFigureRecipe.Action.walking.example.replacingOccurrences(of: "20 frames", with: "100 frames"), SpatterStickFigureRecipe.Action.walking.example.replacingOccurrences(of: "walking", with: "flying"), SpatterStickFigureRecipe.Action.walking.example.replacingOccurrences(of: "35%", with: "nan%") ] {
                try rejects { _ = try SpatterStickFigureRecipe.parse(text) }
            }
            print("PASS unsupported suffix/action/limits/nonfinite input fail closed; no provider or publication path exists")
        } catch { print("FAIL \(error)"); exit(1) }
    }
}
