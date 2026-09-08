import AVFoundation
import Foundation

@main
struct VerifyRecording {
    static func main() async {
        do { try await validate() }
        catch {
            FileHandle.standardError.write(Data("RECORDING_VALIDATION=FAIL: no decodable video recording\n".utf8))
            exit(1)
        }
    }
    static func validate() async throws {
        guard CommandLine.arguments.count == 2 else { throw Failure.invalid }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue > 0 else { throw Failure.invalid }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard duration.isFinite, duration > 0, let track = tracks.first else { throw Failure.invalid }
        let dimensions = try await track.load(.naturalSize)
        guard dimensions.width > 0, dimensions.height > 0 else { throw Failure.invalid }
        // Decode a real frame as well as inspecting metadata.
        let generator = AVAssetImageGenerator(asset: asset)
        let frame = try await generator.image(at: CMTime(seconds: duration / 2, preferredTimescale: 600))
        guard frame.image.width > 0, frame.image.height > 0 else { throw Failure.invalid }
        let report: [String: Any] = ["format": "MP4", "bytes": size.intValue,
            "durationSeconds": duration, "videoWidth": dimensions.width,
            "videoHeight": dimensions.height, "decodedFrame": true]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
    enum Failure: Error { case invalid }
}
