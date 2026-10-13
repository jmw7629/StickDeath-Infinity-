import Foundation
import SwiftUI
import AppKit
import Darwin
private struct Failure: Error { let message: String }
private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw Failure(message: message) }
}
private func rejects(_ action: () throws -> Void) throws {
    do { try action() } catch { return }; throw Failure(message: "Stale/cancelled reorder succeeded")
}
@main @MainActor struct LayerReorderTests {
    static func render(frame: AnimationFrame, layers: [CanvasLayer]) throws -> [UInt8] {
        let prepared = try StudioFrameRenderer.prepare(frame: frame)
        var failure: Error?
        let canvas = Canvas { context, size in
            failure = StudioFrameRenderer.draw(context: &context, frame: frame, layers: layers,
                canvasSize: CGSize(width: 64, height: 64), size: size, preparedBrushes: prepared)
        }.frame(width: 64, height: 64)
        let renderer = ImageRenderer(content: canvas); renderer.scale = 1
        guard let image = renderer.cgImage else { throw Failure(message: "SwiftUI rasterization failed") }
        if let failure { throw failure }
        var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
        bytes.withUnsafeMutableBytes { memory in
            let ctx = CGContext(data: memory.baseAddress, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        return bytes
    }
    static func main() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-layer-drag-\(UUID())")
        do {
            defer { try? FileManager.default.removeItem(at: root) }
            let storage = DeviceStorageManager(documentsDirectory: root)
            let vm = StudioViewModel(storage: storage)
            let created = await vm.createProject(name: "Layer drag", width: 64, height: 64, fps: 12)
            try require(created, "Create failed")
            vm.addLayer(); vm.addLayer(); vm.addLayer()
            let first = vm.layers.first!.id, last = vm.layers.last!.id
            let strokes: [StudioCommand] = [(first, "#FF0000"), (last, "#0000FF")].map { layer, color in
                .draw(.init(frame: .id(vm.document.activeFrameID), layer: .id(layer), strokes: [
                    .init(id: UUID().uuidString, tool: .line, points: [.init(x: 10, y: 32), .init(x: 54, y: 32)], color: color, width: 12, opacity: 1)
                ]))
            }
            _ = try vm.applyStudioCommands(.init(requestID: UUID(), projectID: vm.document.id,
                expectedRevision: vm.document.revision, action: .apply(strokes)))
            let before = vm.document, order = vm.layers.map(\.id)
            let originalPixels = try render(frame: vm.currentFrame, layers: vm.layers)
            let capture = vm.prepareLayerReorder(first)!
            try require(try !vm.reorderLayer(capture, relativeTo: first, after: true), "Self drop created a change")
            try require(vm.document == before, "No-op changed history/document")
            var checkpoint = 0
            try rejects { _ = try vm.reorderLayer(capture, relativeTo: last, after: true, checkCancellation: {
                checkpoint += 1; if checkpoint == 3 { throw CancellationError() }
            }) }
            try require(vm.document == before, "Cancelled reorder changed source")
            try require(try vm.reorderLayer(capture, relativeTo: last, after: true), "Multi-row move refused")
            let expected = Array(order.dropFirst()) + [first]
            try require(vm.layers.map(\.id) == expected && vm.frames == before.frames && vm.activeLayerID == before.activeLayerID, "Reorder changed identities/content/active layer")
            let movedPixels = try render(frame: vm.currentFrame, layers: vm.layers)
            try require(movedPixels != originalPixels, "Layer order did not affect actual composite pixels")
            vm.undo(); try require(vm.layers.map(\.id) == order, "Multi-row drag not one Undo")
            vm.redo(); try require(vm.layers.map(\.id) == expected, "Redo order")
            try rejects { _ = try vm.reorderLayer(capture, relativeTo: last, after: false) }
            let backward = vm.prepareLayerReorder(first)!
            try require(try vm.reorderLayer(backward, relativeTo: expected.first!, after: false), "Reverse drag failed")
            try require(vm.layers.map(\.id) == order, "Before-target insertion off by one")
            print("PASS real multi-row reorder, both directions, no-op/cancel/stale rejection, stable ownership, rendered compositing and single Undo/Redo")

            vm.toggleLayerVisibility(first); vm.setLayerOpacity(first, opacity: 0.1); vm.setLayerBlend(first, mode: "multiply")
            let unchanged = vm.document
            let content = StudioFrameRenderer.thumbnailContent(frame: vm.currentFrame, layers: vm.layers, isolatedLayerID: first)
            try require(content.layers.count == 1 && content.layers[0].visible && content.layers[0].opacity == 1 && content.layers[0].blendMode == "normal", "Thumbnail normalization wrong")
            try require(content.frame.elements.allSatisfy { $0.layerID == first }, "Thumbnail contains another layer")
            let thumbnail = try render(frame: content.frame, layers: content.layers)
            try require(stride(from: 0, to: thumbnail.count, by: 4).contains(where: { thumbnail[$0] > 200 && thumbnail[$0 + 2] < 20 && thumbnail[$0 + 3] > 200 }), "Hidden red layer thumbnail did not render actual contents")
            try require(vm.document == unchanged, "Thumbnail mutated real layer settings")
            var imageFrame = vm.currentFrame
            imageFrame.rasterAssetID = "image-fixture"; imageFrame.rasterLayerID = last
            imageFrame.rasterPlacement = .init(x: 0, y: 0, width: 64, height: 64)
            let isolated = StudioFrameRenderer.thumbnailContent(frame: imageFrame, layers: vm.layers, isolatedLayerID: first)
            try require(isolated.frame.rasterAssetID == nil && isolated.frame.rasterPlacement == nil, "Foreign raster leaked into thumbnail")
            let ownImage = StudioFrameRenderer.thumbnailContent(frame: imageFrame, layers: vm.layers, isolatedLayerID: last)
            try require(ownImage.frame.rasterAssetID == imageFrame.rasterAssetID && ownImage.frame.rasterPlacement == imageFrame.rasterPlacement, "Own raster placement lost")
            let projectID = vm.document.id
            await vm.backToProjects()
            let saved = try storage.loadAnimation(id: projectID)!
            let reopened = StudioViewModel(storage: storage)
            let opened = await reopened.openProject(saved.metadata)
            try require(opened && reopened.layers.map(\.id) == order && reopened.frames == before.frames, "Reopen lost reordered IDs/content")
            await reopened.backToProjects()
            print("PASS actual isolated hidden-layer pixels, no source mutation, correct raster ownership, save and cold reopen")
        } catch { print("FAIL \(error)"); exit(1) }
    }
}
