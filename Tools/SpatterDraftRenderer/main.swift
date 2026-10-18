import Foundation
import AVFoundation
import CryptoKit
import Darwin

// Headless macOS daily-draft renderer (#212).
//
//   SpatterDraftRenderer --job <job.json | -> --output-dir <existing private directory>
//
// Reads one job ({"brief", "fps", "width", "height", "seed", "job_id", "project_name"}),
// plans the brief with the production deterministic planner, exports the MP4 and
// manifest with the production `StudioMovieExportService`, decodes the movie
// again to measure frames and duration, and prints one JSON receipt on stdout.
//
// The output is a PRIVATE DRAFT for the owner's review queue. This command never
// uploads, publishes, schedules or contacts any provider; the owner must approve
// the exact render (its sha256) before any feed, channel or social release.
//
// Exit codes: 0 rendered (read `quality.passes`), 1 render/export failure,
// 2 invalid arguments or job. Every exit prints a receipt.
//
// Compiled with the same production sources as Tests/SpatterStickFigure; see the
// "Render one daily brief with the headless draft renderer" CI step.

@main @MainActor struct SpatterDraftRendererCommand {
    struct Usage: LocalizedError {
        let detail: String
        var errorDescription: String? {
            "\(detail) Usage: SpatterDraftRenderer --job <job.json|-> --output-dir <existing directory>"
        }
    }

    static func emit(_ object: [String: Any], code: Int32) -> Never {
        FileHandle.standardOutput.write(SpatterDraftReceipt.encode(object))
        FileHandle.standardOutput.write(Data("\n".utf8))
        exit(code)
    }

    static func arguments() throws -> (job: String, output: URL) {
        var job: String?, output: String?
        var iterator = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--job": guard job == nil, let value = iterator.next() else { throw Usage(detail: "--job needs one value.") }; job = value
            case "--output-dir": guard output == nil, let value = iterator.next() else { throw Usage(detail: "--output-dir needs one value.") }; output = value
            default: throw Usage(detail: "Unknown argument.")
            }
        }
        guard let job, let output else { throw Usage(detail: "Both --job and --output-dir are required.") }
        let url = URL(fileURLWithPath: output, isDirectory: true).standardizedFileURL
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else { throw Usage(detail: "--output-dir must be an existing directory, not a symbolic link.") }
        return (job, url)
    }

    static func readJob(_ path: String) throws -> Data {
        let limit = SpatterDraftRenderJob.maximumJobBytes + 1
        if path == "-" { return FileHandle.standardInput.readData(ofLength: limit) }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        return handle.readData(ofLength: limit)
    }

    static func sha256(_ url: URL) throws -> (digest: String, bytes: Int) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256(), total = 0
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk); total += chunk.count
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), total)
    }

    static func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Decodes every picture of the exported movie independently of the export
    /// service's own verification, so the receipt reports what a player sees.
    static func measure(_ movie: URL) async throws -> (frames: Int, duration: Double, width: Int, height: Int) {
        let asset = AVURLAsset(url: movie)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1 else { throw StudioMovieExportService.ExportError.verificationFailed }
        let duration = try await asset.load(.duration).seconds
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw StudioMovieExportService.ExportError.verificationFailed }
        reader.add(output)
        guard reader.startReading() else { throw StudioMovieExportService.ExportError.verificationFailed }
        var frames = 0, width = 0, height = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            width = CVPixelBufferGetWidth(buffer); height = CVPixelBufferGetHeight(buffer)
            frames += 1
        }
        guard reader.status == .completed else { throw StudioMovieExportService.ExportError.verificationFailed }
        return (frames, duration, width, height)
    }

    static func writePrivate(_ data: Data, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    static func main() async {
        var jobID: String?
        let job: SpatterDraftRenderJob, outputRoot: URL
        do {
            let parsed = try arguments()
            outputRoot = parsed.output
            job = try SpatterDraftRenderJob.decode(try readJob(parsed.job))
            jobID = job.jobID
        } catch {
            emit(SpatterDraftReceipt.failure(error.localizedDescription, jobID: jobID), code: 2)
        }
        let planned: SpatterDraftPlannedDocument
        do { planned = try SpatterDraftPlannedDocument.make(job: job) }
        catch { emit(SpatterDraftReceipt.failure("The brief could not be planned: \(error.localizedDescription)", jobID: jobID), code: 2) }

        // One private working directory per run; the export service publishes
        // its verified movie directory inside it.
        let work = outputRoot.appendingPathComponent("spatter-draft-" + (jobID.map { $0.replacingOccurrences(of: ":", with: "-") + "-" } ?? "") + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let projectData = try SpatterProjectDigest.canonicalData(planned.document)
            let storyboardData = try planned.storyboard.json()
            let projectURL = work.appendingPathComponent("project.json"), storyboardURL = work.appendingPathComponent("storyboard.json")
            try writePrivate(projectData, to: projectURL)
            try writePrivate(storyboardData, to: storyboardURL)

            let output = try await StudioMovieExportService().export(
                snapshot: .init(document: planned.document, retainedAudioTracks: [], rasterDataByID: [:]),
                outputParent: work, background: .white, filenameBase: "spatter-draft")
            let manifest = output.manifest
            let expectedFrames = manifest.frameIDs.count
            let expectedDuration = Double(manifest.durationNumerator) / Double(max(1, manifest.durationDenominator))
            let measured = try await measure(output.movieURL)
            let movieMeasurement = SpatterQualityReport.MovieMeasurement(decodedFrameCount: measured.frames, decodedDurationSeconds: measured.duration,
                                                                         audioOffsetSeconds: nil, expectedFrameCount: expectedFrames,
                                                                         expectedDurationSeconds: expectedDuration)
            let report = planned.quality(movie: movieMeasurement)
            // The exporter's manifest binds the movie to the canonical project bytes
            // and records its own decode; both must agree with this run.
            let projectDigest = hex(projectData)
            guard manifest.projectDigest == projectDigest else { throw StudioMovieExportService.ExportError.verificationFailed }
            guard manifest.decodedFrameCount == measured.frames else { throw StudioMovieExportService.ExportError.verificationFailed }
            let movie = try sha256(output.movieURL), manifestFile = try sha256(output.manifestURL)
            let storyboardObject = try JSONSerialization.jsonObject(with: storyboardData)
            let receipt: [String: Any] = [
                "schema": SpatterDraftReceipt.schema, "version": SpatterDraftReceipt.version, "status": "rendered",
                "job_id": jobID.map { $0 as Any } ?? NSNull(),
                "private_draft": true, "published": false, "owner_approval_required": true,
                "brief": job.brief, "normalized_brief": planned.brief.normalized, "seed": String(planned.brief.seed),
                "fps": job.fps, "width": job.width, "height": job.height,
                "work_directory": work.path,
                "movie": ["path": output.movieURL.path, "sha256": movie.digest, "bytes": movie.bytes,
                          "codec": manifest.codec, "width": measured.width, "height": measured.height],
                "manifest": ["path": output.manifestURL.path, "sha256": manifestFile.digest],
                "project": ["path": projectURL.path, "sha256": projectDigest, "revision": planned.document.revision,
                            "frame_count": planned.document.frames.count, "schema_version": planned.document.schemaVersion],
                "project_digest": projectDigest,
                "storyboard_path": storyboardURL.path,
                "storyboard_sha256": hex(storyboardData),
                "storyboard": storyboardObject,
                "decoded_frame_count": measured.frames, "decoded_duration_seconds": measured.duration,
                "expected_frame_count": expectedFrames, "expected_duration_seconds": expectedDuration,
                "quality": try SpatterDraftReceipt.quality(report, movie: movieMeasurement),
            ]
            emit(receipt, code: 0)
        } catch {
            try? FileManager.default.removeItem(at: work)
            emit(SpatterDraftReceipt.failure("Render failed: \(error.localizedDescription)", jobID: jobID), code: 1)
        }
    }
}
