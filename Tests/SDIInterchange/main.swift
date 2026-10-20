import Foundation
import CryptoKit

// iOS half of the both-client `.sdi` interchange comparison (#286).
//
// Opens every shared fixture in Tests/SDIFixtures with the production decoders
// (DeviceStorageManager.projectFromPortableBundle + StudioDocumentArchive.decode,
// plus the metadata agreement StudioViewModel.openProject requires), re-exports
// with the production writers (StudioDocumentArchive.encoded +
// DeviceStorageManager.portableBundle) and compares the editable document read
// back from the exported bytes with `reexport.json`, using the same projection
// as make_fixtures.interchange_projection and the Android JVM test
// SdiReexportComparisonTest. It also opens Android's own committed re-export of
// the golden fixture, so each client is checked against the other's bytes.
// Usage: sdi-interchange-tests [Tests/SDIFixtures]

private struct HarnessFailure: Error, CustomStringConvertible { let description: String }
private func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw HarnessFailure(description: message()) }
}

/// Swift port of `make_fixtures.interchange_projection`; keep the three implementations identical.
enum SDIProjection {
    private static func dictionaries(_ value: Any?) -> [[String: Any]] { value as? [[String: Any]] ?? [] }
    private static func values(_ value: Any?) -> [Any] { value as? [Any] ?? [] }
    private static func present(_ value: Any?) -> Any? { value is NSNull ? nil : value }

    static func project(_ document: [String: Any]) throws -> [String: Any] {
        guard let id = document["id"] as? String else { throw HarnessFailure(description: "document has no id") }
        let layers: [[String: Any]] = dictionaries(document["layers"]).map { (layer: [String: Any]) -> [String: Any] in
            let locked = (layer["locked"] as? Bool) == true
            return ["id": layer["id"] ?? NSNull(), "name": layer["name"] ?? NSNull(),
                    "visible": present(layer["visible"]) ?? true, "locked": locked,
                    "opacity": present(layer["opacity"]) ?? 1,
                    "lockMode": locked ? ("full" as Any) : (present(layer["lockMode"]) ?? "free"),
                    "blendMode": ((present(layer["blendMode"]) as? String) ?? "normal").lowercased(),
                    "glowEnabled": present(layer["glowEnabled"]) ?? false,
                    "colorLabel": present(layer["colorLabel"]) ?? NSNull()]
        }
        let frames: [[String: Any]] = try dictionaries(document["frames"]).map { (frame: [String: Any]) throws -> [String: Any] in
            return ["id": frame["id"] ?? NSNull(), "holdTicks": present(frame["holdTicks"]) ?? 1,
             "elements": try dictionaries(frame["elements"]).map(element)]
        }
        func sortedTracks(_ key: String) -> [Int] { values(document[key]).compactMap { ($0 as? NSNumber)?.intValue }.sorted() }
        return ["id": id.lowercased(), "name": document["name"] ?? NSNull(),
                "width": document["width"] ?? NSNull(), "height": document["height"] ?? NSNull(), "fps": document["fps"] ?? NSNull(),
                "activeFrameID": document["activeFrameID"] ?? NSNull(), "activeLayerID": document["activeLayerID"] ?? NSNull(),
                "layers": layers, "frames": frames, "audioClips": values(document["audioClips"]).count,
                "audioTrackVolumes": present(document["audioTrackVolumes"]) ?? [1, 1, 1, 1],
                "mutedAudioTracks": sortedTracks("mutedAudioTracks"),
                "audioTrackPans": present(document["audioTrackPans"]) ?? [0, 0, 0, 0],
                "soloedAudioTracks": sortedTracks("soloedAudioTracks")]
    }

    private static func element(_ item: [String: Any]) throws -> [String: Any] {
        guard let color = item["color"] as? String else { throw HarnessFailure(description: "element has no color") }
        let points: [[Any]] = try dictionaries(item["points"]).map { (point: [String: Any]) throws -> [Any] in
            guard let x = point["x"], let y = point["y"] else { throw HarnessFailure(description: "point without coordinates") }
            var result: [Any] = [x, y]
            if let pressure = present(point["pressure"]) { result.append(pressure) }
            return result
        }
        var brush: Any = NSNull()
        if let descriptor = item["brush"] as? [String: Any] {
            brush = ["family": descriptor["family"] ?? NSNull(), "seed": descriptor["seed"] ?? NSNull()] as [String: Any]
        }
        return ["id": item["id"] ?? NSNull(), "tool": item["tool"] ?? NSNull(), "layerID": item["layerID"] ?? NSNull(),
                "color": color.uppercased(), "width": item["width"] ?? NSNull(), "opacity": present(item["opacity"]) ?? 1,
                "points": points, "brush": brush]
    }

    /// Sorted keys, numbers to four decimals; identical to the Kotlin `SdiProjection.canonical`.
    static func canonical(_ value: Any?) throws -> String {
        guard let value, !(value is NSNull) else { return "null" }
        if let text = value as? String {
            return "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        if let dictionary = value as? [String: Any] {
            return "{" + (try dictionary.keys.sorted().map { "\"\($0)\":" + (try canonical(dictionary[$0])) }.joined(separator: ",")) + "}"
        }
        if let list = value as? [Any] { return "[" + (try list.map { try canonical($0) }.joined(separator: ",")) + "]" }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            let text = String(format: "%.4f", number.doubleValue)
            return text == "-0.0000" ? "0.0000" : text
        }
        throw HarnessFailure(description: "unexpected JSON value \(type(of: value))")
    }
}

@main struct SDIInterchangeTests {
    static let header = "SDIPROJECT000001\n".utf8.count + 8 + 32

    /// Production open path: portable envelope, editable archive, then the metadata agreement
    /// StudioViewModel.openProject checks before it shows a project.
    static func openBundle(_ data: Data, store: DeviceStorageManager) throws -> (AnimationProject, StudioDocumentArchive) {
        let project = try store.projectFromPortableBundle(data)
        guard let editable = project.editableDocumentData else { throw HarnessFailure(description: "no editable document") }
        let archive = try StudioDocumentArchive.decode(editable)
        let document = archive.document
        try require(document.id == project.id && document.frames.count == project.metadata.frameCount &&
                    document.layers.count == project.metadata.layerCount && document.width == project.metadata.canvasWidth &&
                    document.height == project.metadata.canvasHeight && document.fps == project.metadata.fps,
                    "editable metadata disagrees with the portable bundle")
        return (project, archive)
    }

    /// Production export path used by the Studio save/share flow.
    static func reexport(_ project: AnimationProject, _ archive: StudioDocumentArchive, store: DeviceStorageManager) throws -> Data {
        var copy = project
        copy.editableDocumentData = try StudioDocumentArchive(document: archive.document, rasterFrameIndices: archive.rasterFrameIndices).encoded()
        return try store.portableBundle(for: copy)
    }

    static func editableDocument(_ bundle: Data) throws -> [String: Any] {
        let data = Data(bundle)
        try require(data.count > header, "exported bundle is truncated")
        guard let root = try JSONSerialization.jsonObject(with: data.subdata(in: header..<data.count)) as? [String: Any],
              let project = root["project"] as? [String: Any],
              let encoded = project["editableDocumentData"] as? String,
              let archiveData = Data(base64Encoded: encoded),
              let archive = try JSONSerialization.jsonObject(with: archiveData) as? [String: Any],
              let document = archive["document"] as? [String: Any] else {
            throw HarnessFailure(description: "exported bundle has no editable document")
        }
        return document
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tests/SDIFixtures", isDirectory: true)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-interchange-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = DeviceStorageManager(documentsDirectory: scratch, cachesDirectory: scratch.appendingPathComponent("Caches", isDirectory: true))
        guard let shared = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("reexport.json"))) as? [String: Any],
              let goldenName = shared["fixture"] as? String,
              let expectations = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("expectations.json"))) as? [String: [String: Any]] else {
            throw HarnessFailure(description: "reexport.json or expectations.json is unreadable")
        }
        let expected = try SDIProjection.canonical(shared["projection"])

        var passed = 0, failed = 0
        func test(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }

        test("golden fixture opens with the production decoders and its re-export matches reexport.json") {
            let url = root.appendingPathComponent("assets").appendingPathComponent(goldenName)
            let original = try Data(contentsOf: url)
            let (project, archive) = try openBundle(original, store: store)
            try require(try SDIProjection.canonical(SDIProjection.project(editableDocument(original))) == expected,
                        "reexport.json does not describe the committed golden fixture")
            let exported = try reexport(project, archive, store: store)
            let projected = try SDIProjection.canonical(SDIProjection.project(editableDocument(exported)))
            try require(projected == expected, "iOS re-export differs from the shared expectation:\n\(projected)\n!=\n\(expected)")
            let (_, reopened) = try openBundle(exported, store: store)
            try require(reopened.document == archive.document, "the iOS re-export does not reopen to the same document")
            try require(try Data(contentsOf: url) == original, "opening modified the fixture")
        }

        test("Android's committed re-export of the golden fixture opens on iOS with the same content") {
            let url = root.appendingPathComponent("android-reexport").appendingPathComponent(goldenName.replacingOccurrences(of: ".sdi", with: ".android.sdi"))
            let android = try Data(contentsOf: url)
            let (project, archive) = try openBundle(android, store: store)
            let golden = try openBundle(Data(contentsOf: root.appendingPathComponent("assets").appendingPathComponent(goldenName)), store: store).1.document
            try require(project.id == golden.id, "Android re-export changed the project identity")
            let projected = try SDIProjection.canonical(SDIProjection.project(editableDocument(android)))
            try require(projected == expected, "Android re-export differs from the shared expectation:\n\(projected)\n!=\n\(expected)")
            // iOS can write Android's bytes back out and reopen them unchanged.
            let exported = try reexport(project, archive, store: store)
            try require(try SDIProjection.canonical(SDIProjection.project(editableDocument(exported))) == expected, "iOS re-export of Android bytes drifted")
            try require(try openBundle(exported, store: store).1.document == archive.document, "Android bytes do not survive an iOS round trip")
        }

        for name in expectations.keys.sorted() {
            test("\(name): opening never modifies the original; an accepted fixture round-trips") {
                let url = root.appendingPathComponent("assets").appendingPathComponent(name)
                let original = try Data(contentsOf: url)
                try require(sha256(original) == (expectations[name]?["sha256"] as? String), "fixture bytes differ from expectations.json")
                let opened: (AnimationProject, StudioDocumentArchive)?
                do { opened = try openBundle(original, store: store) }
                catch { opened = nil; print("  iOS rejects \(name): \(error)") }
                let outcome = opened == nil ? "reject" : "accept"
                if let opened {
                    let exported = try reexport(opened.0, opened.1, store: store)
                    try require(try openBundle(exported, store: store).1.document == opened.1.document, "re-export does not reopen identically")
                }
                if let required = expectations[name]?["ios"] as? String {
                    try require(outcome == required, "iOS outcome \(outcome) != expected \(required)")
                } else {
                    print("  iOS outcome for \(name): \(outcome) (recorded, not asserted)")
                }
                try require(try Data(contentsOf: url) == original, "opening modified the fixture")
            }
        }

        print("SDI interchange: \(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
