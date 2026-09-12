import Foundation
import CryptoKit

/// One immutable full-document origin for both rendered media components.
/// Neither callers nor component constructors can manufacture this identity.
@MainActor final class StudioMuxCapture {
    struct Proof: Codable, Equatable {
        let purpose: String
        let projectID: UUID
        let revision: Int
        let snapshotSHA256: String
        let durationNumerator: Int
        let durationDenominator: Int
        let audioSampleFrames: Int
        let width: Int
        let height: Int
        let frameIDs: [String]
    }
    let snapshot: StudioMovieExportService.Snapshot
    let proof: Proof
    private init(snapshot: StudioMovieExportService.Snapshot, proof: Proof) { self.snapshot = snapshot; self.proof = proof }
    static func capture(_ snapshot: StudioMovieExportService.Snapshot) throws -> StudioMuxCapture {
        StudioMuxCapture(snapshot: snapshot, proof: try proofFor(snapshot))
    }
    private struct Asset: Codable {
        let id: UUID
        let name: String
        let format: String
        let startTime: Double
        let duration: Double
        let legacySourceFilename: String?
        let byteCount: Int
        let sha256: String
    }
    private struct Raster: Codable { let id: String; let byteCount: Int; let sha256: String }
    private struct Identity: Codable { let document: StudioDocument; let audio: [Asset]; let rasters: [Raster] }

    /// Deterministic content proof; only the private capture factory assigns an
    /// in-process origin. Equal IDs/revisions or even equal digests alone never
    /// authorize mixing two separately captured components.
    static func proofFor(_ snapshot: StudioMovieExportService.Snapshot) throws -> Proof {
        let doc = snapshot.document
        try doc.validate()
        guard !doc.frames.isEmpty, doc.frames.count <= 240, (1...60).contains(doc.fps),
              doc.width > 0, doc.height > 0, doc.width.isMultiple(of: 2), doc.height.isMultiple(of: 2),
              doc.width * doc.height <= 4_194_304, doc.width * doc.height * doc.frames.count <= 134_217_728,
              doc.frames.count * 48_000 % doc.fps == 0,
              doc.frames.count * 48_000 / doc.fps <= 5_760_000,
              !doc.audioClips.isEmpty, doc.audioClips.count <= 128,
              snapshot.retainedAudioTracks.count <= 16 else { throw CaptureError.unsupportedSnapshot }
        let sampleFrames = doc.frames.count * 48_000 / doc.fps
        var audio: [Asset] = [], totalBytes = 0, assetIDs = Set<UUID>()
        for asset in snapshot.retainedAudioTracks {
            guard assetIDs.insert(asset.id).inserted, asset.legacySourceFilename == nil, asset.startTime == 0,
                  asset.duration.isFinite, asset.duration > 0, asset.duration <= 300,
                  !asset.name.isEmpty, asset.name.count <= 120, asset.format.count <= 12,
                  let data = asset.audioData, !data.isEmpty, data.count <= 16 * 1024 * 1024,
                  data.count <= 64 * 1024 * 1024 - totalBytes else { throw CaptureError.unresolvedAudio }
            totalBytes += data.count
            audio.append(Asset(id: asset.id, name: asset.name, format: asset.format, startTime: asset.startTime,
                               duration: asset.duration, legacySourceFilename: asset.legacySourceFilename,
                               byteCount: data.count, sha256: hash(data)))
        }
        var used = Set<UUID>()
        for clip in doc.audioClips {
            guard let id = clip.assetID, assetIDs.contains(id), (1...4).contains(clip.track), clip.duration > 0,
                  clip.startTime + clip.duration <= Double(sampleFrames) / 48_000 + 0.000000001 else { throw CaptureError.unresolvedAudio }
            used.insert(id)
        }
        guard used == assetIDs else { throw CaptureError.unresolvedAudio }
        var rasters: [Raster] = []; totalBytes = 0
        guard snapshot.rasterDataByID.count <= 240 else { throw CaptureError.unsupportedSnapshot }
        for (id, data) in snapshot.rasterDataByID.sorted(by: { $0.key < $1.key }) {
            guard !id.isEmpty, id.utf8.count <= 128, !data.isEmpty, data.count <= 64 * 1024 * 1024 - totalBytes else { throw CaptureError.unsupportedSnapshot }
            totalBytes += data.count; rasters.append(Raster(id: id, byteCount: data.count, sha256: hash(data)))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let canonical = try encoder.encode(Identity(document: doc, audio: audio, rasters: rasters))
        guard canonical.count <= 8 * 1024 * 1024 else { throw CaptureError.unsupportedSnapshot }
        return Proof(purpose: "video-only-component-for-same-capture-mux", projectID: doc.id, revision: doc.revision,
                     snapshotSHA256: hash(canonical), durationNumerator: doc.frames.count, durationDenominator: doc.fps,
                     audioSampleFrames: sampleFrames, width: doc.width, height: doc.height, frameIDs: doc.frames.map(\.id))
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    enum CaptureError: Error { case unsupportedSnapshot, unresolvedAudio }
}
