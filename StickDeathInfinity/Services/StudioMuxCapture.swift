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
        let frameStartTicks: [Int]
        let frameDurationTicks: [Int]
        /// Output codec and the exact scale/padding rule behind `width` × `height`.
        var codec: String? = nil
        var renderPlan: StudioMovieExportService.RenderPlan? = nil
        /// Ticks added to the last frame so audio ending after the animation fits (#181).
        var heldLastFrameTicks: Int? = nil
    }
    let snapshot: StudioMovieExportService.Snapshot
    let proof: Proof
    private init(snapshot: StudioMovieExportService.Snapshot, proof: Proof) { self.snapshot = snapshot; self.proof = proof }
    static func capture(_ snapshot: StudioMovieExportService.Snapshot) throws -> StudioMuxCapture {
        let prepared = try holdingLastFrameForAudio(snapshot)
        return StudioMuxCapture(snapshot: prepared, proof: try proofFor(prepared))
    }

    /// Audio that ends after the animation no longer fails capture (#181). The
    /// captured copy of the document extends the last frame's exposure by the
    /// whole ticks needed to reach the latest clip end (plus the fewest extra
    /// ticks that keep the duration a whole number of 48 kHz samples). The
    /// editable project is not changed; the manifest records the held ticks.
    static func holdingLastFrameForAudio(_ snapshot: StudioMovieExportService.Snapshot) throws -> StudioMovieExportService.Snapshot {
        var document = snapshot.document
        guard let last = document.frames.indices.last, (1...60).contains(document.fps),
              let audioEnd = document.audioClips.map({ $0.startTime + $0.duration }).max(), audioEnd.isFinite else { return snapshot }
        let animationEnd = Double(document.totalTimelineTicks) / Double(document.fps)
        guard audioEnd > animationEnd + 0.000000001 else { return snapshot }
        var requiredTicks = Int((audioEnd * Double(document.fps) - 0.000000001).rounded(.up))
        guard requiredTicks > document.totalTimelineTicks, requiredTicks - document.totalTimelineTicks <= 600 else {
            throw CaptureError.unresolvedAudio
        }
        while requiredTicks * 48_000 % document.fps != 0 { requiredTicks += 1 }
        let extra = requiredTicks - document.totalTimelineTicks
        let hold = document.frames[last].durationTicks + extra
        guard (2...600).contains(hold) else { throw CaptureError.unresolvedAudio }
        document.frames[last].holdTicks = hold
        document.schemaVersion = max(document.schemaVersion, 21)
        try document.validate()
        var prepared = StudioMovieExportService.Snapshot(document: document, retainedAudioTracks: snapshot.retainedAudioTracks,
            rasterDataByID: snapshot.rasterDataByID, imageCredits: snapshot.imageCredits, render: snapshot.render)
        prepared.heldLastFrameTicks = snapshot.heldLastFrameTicks + extra
        return prepared
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
    private struct CreditedRaster: Codable { let id: String; let credit: StudioExportService.ImageCredit }
    private struct Identity: Codable {
        let document: StudioDocument; let audio: [Asset]; let rasters: [Raster]
        var imageCredits: [CreditedRaster]? = nil
        var render: StudioMovieExportService.RenderOptions? = nil
        var heldLastFrameTicks: Int? = nil
    }

    /// Deterministic content proof; only the private capture factory assigns an
    /// in-process origin. Equal IDs/revisions or even equal digests alone never
    /// authorize mixing two separately captured components.
    static func proofFor(_ snapshot: StudioMovieExportService.Snapshot) throws -> Proof {
        let doc = snapshot.document
        try doc.validate()
        // The encoded size comes from the render plan (preset scale plus even
        // padding), so odd canvases are captured instead of rejected (#182).
        let plan: StudioMovieExportService.RenderPlan
        do { plan = try StudioMovieExportService.RenderPlan.make(canvasWidth: doc.width, canvasHeight: doc.height, preset: snapshot.render.preset) }
        catch { throw CaptureError.unsupportedSnapshot }
        guard !doc.frames.isEmpty, doc.frames.count <= 240, (1...60).contains(doc.fps),
              doc.width > 0, doc.height > 0, plan.outputWidth.isMultiple(of: 2), plan.outputHeight.isMultiple(of: 2),
              plan.outputWidth * plan.outputHeight <= 4_194_304, plan.outputWidth * plan.outputHeight * doc.frames.count <= 134_217_728,
              snapshot.heldLastFrameTicks >= 0, snapshot.heldLastFrameTicks <= 600,
              doc.totalTimelineTicks * 48_000 % doc.fps == 0,
              doc.totalTimelineTicks * 48_000 / doc.fps <= 5_760_000,
              !doc.audioClips.isEmpty, doc.audioClips.count <= 128,
              snapshot.retainedAudioTracks.count <= 16 else { throw CaptureError.unsupportedSnapshot }
        let sampleFrames = doc.totalTimelineTicks * 48_000 / doc.fps
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
        _ = try StudioExportService.renderedImageCredits(document: doc, creditsByRasterID: snapshot.imageCredits)
        let visibleIDs = StudioExportService.visibleRasterAssetIDs(document: doc)
        let credits = visibleIDs.sorted().compactMap { id in
            snapshot.imageCredits[id].map { CreditedRaster(id: id, credit: $0) }
        }
        guard try encoder.encode(credits).count <= 128 * 1024 else { throw CaptureError.unsupportedSnapshot }
        let canonical = try encoder.encode(Identity(document: doc, audio: audio, rasters: rasters,
            imageCredits: credits.isEmpty ? nil : credits,
            render: snapshot.render == .init() ? nil : snapshot.render,
            heldLastFrameTicks: snapshot.heldLastFrameTicks > 0 ? snapshot.heldLastFrameTicks : nil))
        guard canonical.count <= 8 * 1024 * 1024 else { throw CaptureError.unsupportedSnapshot }
        var proof = Proof(purpose: "video-only-component-for-same-capture-mux", projectID: doc.id, revision: doc.revision,
                     snapshotSHA256: hash(canonical), durationNumerator: doc.totalTimelineTicks, durationDenominator: doc.fps,
                     audioSampleFrames: sampleFrames, width: plan.outputWidth, height: plan.outputHeight, frameIDs: doc.frames.map(\.id),
                     frameStartTicks: doc.frames.indices.map { doc.startTick(ofFrame: $0) },
                     frameDurationTicks: doc.frames.map(\.durationTicks))
        proof.codec = snapshot.render.codec.rawValue
        proof.renderPlan = plan
        proof.heldLastFrameTicks = snapshot.heldLastFrameTicks > 0 ? snapshot.heldLastFrameTicks : nil
        return proof
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    enum CaptureError: Error { case unsupportedSnapshot, unresolvedAudio }
}
