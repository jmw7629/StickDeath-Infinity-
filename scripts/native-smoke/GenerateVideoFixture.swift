import Foundation
import CoreGraphics

@main struct GenerateVideoFixture {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw CocoaError(.fileWriteInvalidFileName) }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        guard !FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteFileExists) }
        try await VideoFrameFixture.makeMovie(url, rotate: true)
        // Verify the generated fixture using actual frame decoding before the
        // real system Photos library receives it. Never seed historical media.
        let importer = StudioVideoFrameImportService()
        let first = try await importer.extract(from: url, projectFrameIndex: 0, fps: 12)
        let middle = try await importer.extract(from: url, projectFrameIndex: 6, fps: 12)
        guard first.image.width == 64, first.image.height == 96,
              middle.image.width == 64, middle.image.height == 96,
              first.image.normalizedPNG != middle.image.normalizedPNG else { throw CocoaError(.fileReadCorruptFile) }
        print("Original oriented video fixture verified at 0.000 and 0.500 seconds; 64x96.")
    }
}
