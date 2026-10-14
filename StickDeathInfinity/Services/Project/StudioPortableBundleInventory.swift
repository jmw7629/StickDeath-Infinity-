import Foundation
import CryptoKit

/// What a portable project carries, measured from the decoded record (#170).
///
/// A `.sdiproject` embeds the whole stored record: normalized frame images,
/// the original bytes of every imported image (with its catalogue
/// attribution), every audio track's original bytes and the editable document
/// archive. Imported video is stored the same way the editor keeps it: grabbed
/// frames become image sources and extracted sound becomes an audio track. The
/// source movie file itself is not kept by a project, so it is never in a
/// backup; the inventory says so instead of listing a reference it cannot honor.
struct StudioPortableAssetRecord: Equatable, Sendable {
    enum Kind: String, Sendable {
        case frameImage, sourceImageOriginal, additionalImage, additionalSourceOriginal, audio, editableDocument
        /// Originals are the creator's bytes; they must survive a restore unchanged.
        var isOriginal: Bool { self == .sourceImageOriginal || self == .additionalSourceOriginal || self == .audio }
    }
    let kind: Kind
    /// Stable inside one project: `frame-<index>`, `asset-<key>` or `audio-<uuid>`.
    let key: String
    let byteCount: Int
    let sha256: String
    let attribution: [String: String]?
}

struct StudioPortableBundleInventory: Sendable {
    let title: String
    let fps: Int
    let canvasWidth: Int
    let canvasHeight: Int
    let frameCount: Int
    let assets: [StudioPortableAssetRecord]
    /// Names of audio tracks recorded without bytes (historical records only).
    let audioTracksWithoutBytes: [String]

    static let videoNote = "Imported video is kept as its frames and extracted sound; the source movie file is not part of a project or its backup."

    init(project: AnimationProject) {
        title = project.metadata.title
        fps = project.metadata.fps
        canvasWidth = project.metadata.canvasWidth
        canvasHeight = project.metadata.canvasHeight
        frameCount = project.frames.count
        var records: [StudioPortableAssetRecord] = []
        func add(_ kind: StudioPortableAssetRecord.Kind, _ key: String, _ data: Data?, _ attribution: [String: String]? = nil) {
            guard let data, !data.isEmpty else { return }
            records.append(StudioPortableAssetRecord(kind: kind, key: key, byteCount: data.count,
                                                     sha256: Self.digest(data), attribution: attribution))
        }
        for (index, frame) in project.frames.enumerated() {
            add(.frameImage, "frame-\(index)", frame.imageData)
            if let source = frame.sourceImage {
                add(.sourceImageOriginal, "frame-\(index)", source.originalData, source.catalogueAttribution)
            }
        }
        for key in (project.additionalImageAssets ?? [:]).keys.sorted() {
            guard let frame = project.additionalImageAssets?[key] else { continue }
            add(.additionalImage, "asset-" + key, frame.imageData)
            if let source = frame.sourceImage {
                add(.additionalSourceOriginal, "asset-" + key, source.originalData, source.catalogueAttribution)
            }
        }
        var silent: [String] = []
        for track in project.audioTracks.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            if let data = track.audioData, !data.isEmpty { add(.audio, "audio-" + track.id.uuidString, data) }
            else { silent.append(track.name) }
        }
        add(.editableDocument, "document", project.editableDocumentData)
        assets = records
        audioTracksWithoutBytes = silent
    }

    var totalBytes: Int { assets.reduce(0) { $0 + $1.byteCount } }
    var originals: [StudioPortableAssetRecord] { assets.filter { $0.kind.isOriginal } }
    func count(_ kind: StudioPortableAssetRecord.Kind) -> Int { assets.filter { $0.kind == kind }.count }

    /// One plain-language line for a confirmation or receipt; no paths or identifiers.
    var summary: String {
        let images = count(.sourceImageOriginal) + count(.additionalSourceOriginal)
        let sounds = count(.audio)
        let size = ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
        return "\(frameCount) frame\(frameCount == 1 ? "" : "s"), \(images) original image\(images == 1 ? "" : "s"), \(sounds) sound\(sounds == 1 ? "" : "s"), \(size) of project data."
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Result of comparing an imported project, reloaded from device storage, with
/// the backup it came from. A restore is "verified" only when every original
/// image and sound came back byte-identical with its attribution and the
/// canvas, frame rate and frame count are unchanged.
struct StudioPortableRestoreReport: Equatable, Sendable {
    enum Problem: Equatable, Sendable {
        case notReopened
        case structureChanged(String)
        case missing(StudioPortableAssetRecord.Kind, String)
        case changed(StudioPortableAssetRecord.Kind, String)
        case attributionChanged(String)
    }
    let verifiedOriginals: Int
    let droppedAudio: Int
    let problems: [Problem]
    var isVerified: Bool { problems.isEmpty }

    var summary: String {
        if isVerified {
            let dropped = droppedAudio > 0 ? " \(droppedAudio) missing sound\(droppedAudio == 1 ? " was" : "s were") left out as you chose." : ""
            return "Reopened from this device and checked \(verifiedOriginals) original image and sound file\(verifiedOriginals == 1 ? "" : "s"): all identical.\(dropped)"
        }
        if problems.contains(.notReopened) {
            return "The imported copy could not be reopened for checking. The backup file and your other projects are unchanged."
        }
        return "Import check found \(problems.count) difference\(problems.count == 1 ? "" : "s") from the backup. Keep the backup file; the imported copy may be incomplete."
    }
}

enum StudioPortableRestoreVerifier {
    /// `restored` must be read back from storage, not the in-memory value that
    /// was saved. `droppedAudio` names tracks the creator chose to leave out.
    static func verify(source: AnimationProject, restored: AnimationProject?,
                       droppedAudio: Set<UUID> = []) -> StudioPortableRestoreReport {
        guard let restored else { return StudioPortableRestoreReport(verifiedOriginals: 0, droppedAudio: 0, problems: [.notReopened]) }
        var problems: [StudioPortableRestoreReport.Problem] = []
        let a = source.metadata, b = restored.metadata
        if a.canvasWidth != b.canvasWidth || a.canvasHeight != b.canvasHeight { problems.append(.structureChanged("canvas")) }
        if a.fps != b.fps { problems.append(.structureChanged("frame rate")) }
        if source.frames.count != restored.frames.count || b.frameCount != restored.frames.count {
            problems.append(.structureChanged("frame count"))
        }
        let expected = StudioPortableBundleInventory(project: source).originals
        let actual = Dictionary(StudioPortableBundleInventory(project: restored).originals.map { ("\($0.kind.rawValue):\($0.key)", $0) },
                                uniquingKeysWith: { first, _ in first })
        var verified = 0, dropped = 0
        for record in expected {
            if record.kind == .audio, let id = UUID(uuidString: String(record.key.dropFirst("audio-".count))), droppedAudio.contains(id) {
                dropped += 1; continue
            }
            guard let match = actual["\(record.kind.rawValue):\(record.key)"] else {
                problems.append(.missing(record.kind, record.key)); continue
            }
            guard match.sha256 == record.sha256, match.byteCount == record.byteCount else {
                problems.append(.changed(record.kind, record.key)); continue
            }
            guard match.attribution == record.attribution else { problems.append(.attributionChanged(record.key)); continue }
            verified += 1
        }
        return StudioPortableRestoreReport(verifiedOriginals: verified, droppedAudio: dropped, problems: problems)
    }
}
