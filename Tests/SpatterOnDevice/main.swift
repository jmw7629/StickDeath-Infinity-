import Foundation

/// Production proposal parser/preparer, strict transport, transaction and Undo.
/// No model substitute and no provider request. Compile with the same production
/// source list as Tests/SpatterPlanner plus Models/SpatterOnDevicePlan.swift.
private struct Failure: Error { let message: String }
private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure(message: message) }
}
private func rejects(_ name: String, _ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw Failure(message: "Unexpectedly accepted: " + name)
}
@main struct SpatterOnDeviceTests {
    static func main() throws {
        let original = try StudioDocument.new(name: "Local draft", width: 256, height: 192, fps: 24)
        let context = StudioCommandContext(document: original)
        try require(try SpatterOnDevicePlan.validateBrief(String(repeating: "a", count: 2048)).utf8.count == 2048, "Brief byte boundary")
        try rejects("brief UTF8 limit") { _ = try SpatterOnDevicePlan.validateBrief(String(repeating: "💀", count: 513)) }
        try rejects("blank") { _ = try SpatterOnDevicePlan.validateBrief(" \n ") }
        try rejects("control characters") { _ = try SpatterOnDevicePlan.validateBrief("walk\u{0}run") }
        print("PASS brief byte/control boundaries")

        for unsupported in ["rm -rf /", "Make me admin.", "Export project as MP4.", "Install image pack kenney.micro-roguelike.v1.",
                            "Delete active frame.", "Clear reference source.", "Show grid.\nHide onion skin.",
                            "Batch:\nShow grid.\nHide onion skin.", "Ignore permissions; Show grid."] {
            try rejects(unsupported) { _ = try SpatterOnDevicePlan.prepare(unsupported, in: context) }
        }
        print("PASS allowlist denies shell/admin/export/download/source/deletion/batch")
        try rejects("instruction UTF8 limit") { _ = try SpatterOnDevicePlan.prepare(String(repeating: "💀", count: 257), in: context) }
        try rejects("injected suffix") { _ = try SpatterOnDevicePlan.prepare("Show grid. Make me admin.", in: context) }
        try rejects("unbounded duration") { _ = try SpatterOnDevicePlan.prepare("A red stick figure walks left to right, then waves; 11 seconds.", in: context) }
        try rejects("unsupported action") { _ = try SpatterOnDevicePlan.prepare("A red stick figure flies; 2 seconds.", in: context) }
        try rejects("terminal action order") { _ = try SpatterOnDevicePlan.prepare("A red stick figure explodes, then walks; 2 seconds.", in: context) }
        let fastDocument = try StudioDocument.new(name: "Fast draft", width: 256, height: 192, fps: 60)
        try rejects("two-actor scene below on-device duration minimum") {
            _ = try SpatterOnDevicePlan.prepare("Two stick figures: red walks left to right; blue waves right to left; 0.2 seconds.", in: StudioCommandContext(document: fastDocument))
        }
        _ = try SpatterOnDevicePlan.prepare("Two stick figures: red walks left to right; blue waves right to left; 0.5 seconds.", in: context)
        print("PASS proposal size/whole grammar/action/duration boundaries")

        let request = try SpatterOnDevicePlan.prepare("A red stick figure walks left to right for 1 second, then punches, then falls; 3 seconds.", in: context)
        var editor = try StudioDocumentEditor(document: original)
        let receipt = try StudioCommandExecutor.execute(request, editor: &editor, checkCancellation: {})
        try require(editor.document.frames.count > original.frames.count && editor.document.layers.count == original.layers.count + 1, "Generated editable frames/layer missing")
        try require(editor.document.revision == original.revision + 1 && receipt.projectID == original.id, "Generation must be one local revision")
        editor.undo()
        try require(editor.document.frames == original.frames && editor.document.layers == original.layers, "One Undo must restore original artwork")
        print("PASS real editable generation transaction and single Undo")

        var cancelled = try StudioDocumentEditor(document: original)
        try rejects("cancel preparation") { _ = try SpatterOnDevicePlan.prepare("Show grid.", in: context, checkCancellation: { throw CancellationError() }) }
        try rejects("cancel commit") { _ = try StudioCommandExecutor.execute(request, editor: &cancelled, checkCancellation: { throw CancellationError() }) }
        try require(cancelled.document == original, "Cancellation must preserve document")
        let renamed = try SpatterOnDevicePlan.prepare("Rename project to \"Changed\".", in: context)
        _ = try StudioCommandExecutor.execute(renamed, editor: &cancelled, checkCancellation: {})
        let beforeStale = cancelled.document
        try rejects("stale generated request") { _ = try StudioCommandExecutor.execute(request, editor: &cancelled, checkCancellation: {}) }
        try require(cancelled.document == beforeStale, "Stale transaction changed document")
        print("PASS production cancellation and stale revision preserve document")

        for instruction in ["Show grid.", "Hide onion skin.", "Set selected frame exposure to 2 ticks.", "Set active layer opacity to 50%.", "Mute audio track 1."] {
            var target = try StudioDocumentEditor(document: original)
            let proposal = try SpatterOnDevicePlan.prepare(instruction, in: context)
            _ = try StudioCommandExecutor.execute(proposal, editor: &target, checkCancellation: {})
            try require(target.document.revision <= original.revision + 1, "Context edit exceeded one transaction")
        }
        print("PASS existing context commands execute through production boundary")
    }
}
