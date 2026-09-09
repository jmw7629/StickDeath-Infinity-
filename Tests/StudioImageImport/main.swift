import Foundation
import CoreGraphics
import ImageIO
import Darwin

private struct Failure: Error { let message: String }
private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure(message: message) }
}
private actor Pause {
    var reached = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !reached else { return }
        reached = true
        await withCheckedContinuation { continuation = $0 }
    }
    func resume() { continuation?.resume(); continuation = nil }
}
private actor EncodingObservation {
    var reached = false
    func mark() { reached = true }
}

private enum InjectedCleanupFailure: Error { case stop }
private actor ScratchInterference {
    enum Mode { case replaceDirectory, replaceWithSymlink, replaceFile, foreignEntry, replaceParent }
    let mode: Mode
    let parent: URL
    let moved: URL
    let target: URL
    private(set) var affected: URL?
    private var applied = false
    init(mode: Mode, parent: URL, root: URL) {
        self.mode = mode; self.parent = parent
        moved = root.appendingPathComponent("moved-owned")
        target = root.appendingPathComponent("foreign-target")
    }
    func apply(throwAfter: Bool = false) throws {
        guard !applied else { return }
        applied = true
        let fm = FileManager.default
        guard let directory = try fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            .first(where: { $0.lastPathComponent.hasPrefix(".sdi-image-import-") }) else {
            throw Failure(message: "Production staging directory was not created")
        }
        affected = directory
        let sentinel = Data("foreign bytes must survive".utf8)
        switch mode {
        case .replaceDirectory:
            try fm.moveItem(at: directory, to: moved)
            try fm.createDirectory(at: directory, withIntermediateDirectories: false)
            try sentinel.write(to: directory.appendingPathComponent("foreign.txt"), options: .withoutOverwriting)
        case .replaceWithSymlink:
            try fm.moveItem(at: directory, to: moved)
            try fm.createDirectory(at: target, withIntermediateDirectories: false)
            try sentinel.write(to: target.appendingPathComponent("source.image"), options: .withoutOverwriting)
            try fm.createSymbolicLink(at: directory, withDestinationURL: target)
        case .replaceFile:
            try fm.moveItem(at: directory.appendingPathComponent("source.image"), to: moved)
            try sentinel.write(to: directory.appendingPathComponent("source.image"), options: .withoutOverwriting)
        case .foreignEntry:
            try sentinel.write(to: directory.appendingPathComponent("foreign.txt"), options: .withoutOverwriting)
            let nested = directory.appendingPathComponent("foreign-folder")
            try fm.createDirectory(at: nested, withIntermediateDirectories: false)
            try sentinel.write(to: nested.appendingPathComponent("nested.txt"), options: .withoutOverwriting)
        case .replaceParent:
            try fm.moveItem(at: parent, to: moved)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try sentinel.write(to: directory.appendingPathComponent("source.image"), options: .withoutOverwriting)
        }
        if throwAfter { throw InjectedCleanupFailure.stop }
    }
}

/// Generated pixel patterns are test fixtures, not recovered artwork. Every
/// import runs the complete production service and Apple ImageIO/CoreGraphics.
@main struct StudioImageImportTests {
    static let fm = FileManager.default
    static let service = StudioImageImportService()
    static let colors: [[UInt8]] = [[255,0,0,255], [0,255,0,255], [0,0,255,255],
                                    [255,255,0,255], [255,0,255,255], [0,255,255,255]]
    static func makeImage(width: Int, height: Int, pattern: (Int, Int) -> [UInt8]) throws -> CGImage {
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { bytes in
            let pixels = bytes.bindMemory(to: UInt8.self)
            for y in 0..<height { for x in 0..<width {
                let color = pattern(x,y), index = (y * width + x) * 4
                for c in 0..<4 { pixels[index+c] = color[c] }
            } }
        }
        guard let provider = CGDataProvider(data: data as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: .init(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw Failure(message: "Fixture raster could not be created") }
        return image
    }
    static func encoded(_ image: CGImage, type: String = "public.png", orientation: Int = 1, count: Int = 1,
                        quality: Double = 0.8, alternateImage: CGImage? = nil) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, count, nil) else { throw Failure(message: "Apple fixture encoder unavailable: \(type)") }
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation,
                                          kCGImageDestinationLossyCompressionQuality: quality]
        if type == "com.compuserve.gif" { properties[kCGImagePropertyGIFDictionary] = [kCGImagePropertyGIFDelayTime:0.1] }
        for index in 0..<count {
            CGImageDestinationAddImage(destination, index > 0 ? alternateImage ?? image : image,
                                      properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw Failure(message: "Apple fixture encoding failed: \(type)") }
        return data as Data
    }
    static func largeFixture(width: Int, height: Int, noise: Bool) throws -> Data {
        guard let space = CGColorSpace(name:CGColorSpace.sRGB),
              let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,
                bytesPerRow:width*4,space:space,
                bitmapInfo:CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure(message:"Large fixture context unavailable") }
        if noise {
            guard let data = context.data else { throw Failure(message:"Large fixture pixels unavailable") }
            let bytes = data.assumingMemoryBound(to:UInt8.self)
            var value: UInt64 = 0x1234567812345678
            for index in 0..<(width*height) {
                value ^= value << 13; value ^= value >> 7; value ^= value << 17
                bytes[index*4]=UInt8(truncatingIfNeeded:value)
                bytes[index*4+1]=UInt8(truncatingIfNeeded:value >> 8)
                bytes[index*4+2]=UInt8(truncatingIfNeeded:value >> 16)
                bytes[index*4+3]=255
            }
        } else {
            context.setFillColor(CGColor(red:1,green:0,blue:0,alpha:1))
            context.fill(CGRect(x:0,y:0,width:width,height:height))
        }
        guard let image=context.makeImage() else { throw Failure(message:"Large fixture image unavailable") }
        return try encoded(image,type:noise ? "public.jpeg" : "public.png",quality:noise ? 0.5 : 0.8)
    }
    static func file(_ root: URL, _ name: String, _ data: Data) throws -> URL {
        let url = root.appendingPathComponent(name); try data.write(to: url, options: .withoutOverwriting); return url
    }
    static func raster(_ png: Data) throws -> (Int, Int, [UInt8]) {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil), CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) as String? == "public.png",
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure(message: "Actual normalized PNG did not reopen") }
        context.draw(image, in: CGRect(x:0,y:0,width:image.width,height:image.height))
        guard let bytes = context.data else { throw Failure(message:"Missing reopened pixels") }
        return (image.width, image.height, Array(UnsafeBufferPointer(start: bytes.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4)))
    }
    static func identifiers(_ raster: (Int,Int,[UInt8])) -> [Int] {
        (0..<(raster.0 * raster.1)).map { i in
            colors.indices.min { a,b in
                (0..<3).reduce(0) { $0 + abs(Int(colors[a][$1]) - Int(raster.2[i*4+$1])) }
                    < (0..<3).reduce(0) { $0 + abs(Int(colors[b][$1]) - Int(raster.2[i*4+$1])) }
            }!
        }
    }
    static func rejects(_ expected: StudioImageImportService.ImportError? = nil,
                        _ operation: () async throws -> Void) async throws {
        do { try await operation(); throw Failure(message: "Invalid image unexpectedly imported") }
        catch let error as StudioImageImportService.ImportError {
            if let expected { try require(String(describing:error) == String(describing:expected), "Wrong import error: \(error)") }
        }
    }
    static func cancelled(_ operation: () async throws -> Void) async throws {
        do { try await operation(); throw Failure(message:"Cancelled image unexpectedly returned") }
        catch is CancellationError { }
    }
    static func chunk(_ name: String, _ bytes: Data) -> Data {
        func word(_ value: UInt32) -> Data { var n = value.bigEndian; return withUnsafeBytes(of:&n) { Data($0) } }
        let body = Data(name.utf8) + bytes
        var crc = UInt32.max
        for b in body { crc ^= UInt32(b); for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 } }
        return word(UInt32(bytes.count)) + body + word(crc ^ UInt32.max)
    }

    static func main() async {
        do { try await run() }
        catch { print("STUDIO_IMAGE_IMPORT_TESTS=FAIL \(error)"); exit(1) }
    }
    static func run() async throws {
        let root = fm.temporaryDirectory.appendingPathComponent("sdi-image-import-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let scratch = root.appendingPathComponent("scratch")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
        _ = try file(scratch,"sentinel",Data("unrelated original".utf8))
        var passed = 0
        func test(_ name: String, _ body: () async throws -> Void) async throws {
            do {
                try await body()
                try require(try fm.contentsOfDirectory(atPath:scratch.path) == ["sentinel"], "Temporary file left behind or unrelated file removed")
                passed += 1; print("PASS \(name)")
            } catch { print("FAIL \(name): \(error)"); throw error }
        }
        let tiny = try makeImage(width:3,height:2) { x,y in colors[y*3+x] }
        let png = try encoded(tiny)
        let source = try file(root,"actual-png.wrong-extension",png)
        try await test("actual PNG reopens with original pixels, metadata, stable identity and untouched source") {
            let first = try await service.importImage(from:source,name:"Original",scratchParent:scratch)
            let second = try await service.importImage(from:source,scratchParent:scratch)
            try require(first.originalData == png && (try Data(contentsOf:source)) == png, "Source bytes changed")
            try require(first.id != second.id && first.name == "Original" && first.container == .png, "Identity or actual container incorrect")
            try require(first.width == 3 && first.height == 2 && first.originalWidth == 3 && first.originalHeight == 2 && first.originalOrientation == 1, "Dimensions incorrect")
            try require(identifiers(try raster(first.normalizedPNG)) == [0,1,2,3,4,5], "Normalized PNG changed actual colors")
        }
        try await test("all eight EXIF orientations produce exact full-resolution asymmetric pixel order") {
            let expected = [[0,1,2,3,4,5],[2,1,0,5,4,3],[5,4,3,2,1,0],[3,4,5,0,1,2],
                            [0,3,1,4,2,5],[3,0,4,1,5,2],[5,2,4,1,3,0],[2,5,1,4,0,3]]
            for orientation in 1...8 {
                let bytes = try encoded(tiny,orientation:orientation)
                let url = try file(root,"orientation-\(orientation).png",bytes)
                let result = try await service.importImage(from:url,scratchParent:scratch)
                try require(result.originalOrientation == orientation, "EXIF orientation was lost before normalization")
                let actual = try raster(result.normalizedPNG)
                try require(actual.0 == (orientation >= 5 ? 2 : 3) && actual.1 == (orientation >= 5 ? 3 : 2), "Oriented dimensions incorrect")
                try require(identifiers(actual) == expected[orientation-1], "Wrong pixels for orientation \(orientation): \(identifiers(actual))")
                let properties = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(result.normalizedPNG as CFData,nil)!,0,nil)! as NSDictionary
                try require((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1 == 1, "PNG retained a second rotation")
            }
        }
        try await test("transparency and premultiplied alpha survive real PNG normalization") {
            let image = try makeImage(width:3,height:1) { x,_ in [[0,0,0,0],[128,0,0,128],[0,255,0,255]][x] }
            let url = try file(root,"alpha.png",encoded(image))
            let result = try await service.importImage(from:url,scratchParent:scratch)
            try require(try raster(result.normalizedPNG).2 == [0,0,0,0,128,0,0,128,0,255,0,255], "Alpha was flattened or altered")
        }
        try await test("actual JPEG and HEIF decode with orientation and immutable encoded source bytes") {
            let image = try makeImage(width:96,height:64) { x,y in colors[(y/32)*3+x/32] }
            for type in ["public.jpeg","public.heic"] {
                let bytes = try encoded(image,type:type,orientation:6)
                let url = try file(root,"encoded-\(type).unknown",bytes)
                let result = try await service.importImage(from:url,scratchParent:scratch)
                try require(result.container == (type == "public.jpeg" ? .jpeg : .heif), "Wrong content-based image format")
                try require(result.originalData == bytes && result.width == 64 && result.height == 96, "Encoded orientation or original bytes wrong")
                let pixel = try raster(result.normalizedPNG)
                let ids = identifiers(pixel)
                let centers = [ids[16*64+16],ids[16*64+48],ids[48*64+16],ids[48*64+48],ids[80*64+16],ids[80*64+48]]
                try require(centers == [3,0,4,1,5,2], "Lossy oriented image colors misplaced: \(centers)")
            }
        }
        try await test("standard 4032 by 3024 iPhone photo is accepted without downscaling") {
            let data = try autoreleasepool { try encoded(makeImage(width:4032,height:3024) { x,y in x < 2016 ? colors[0] : colors[y < 1512 ? 1 : 2] },type:"public.jpeg") }
            let url = try file(root,"twelve-megapixels.jpg",data)
            let result = try await service.importImage(from:url,scratchParent:scratch)
            try require(result.width == 4032 && result.height == 3024 && result.originalData == data, "Common photo was resized or lost")
            try require(try raster(result.normalizedPNG).0 == 4032, "Normalized full-resolution PNG did not reopen")
        }
        try await test("encoded, dimension and 48-megapixel declarations reject before image normalization") {
            let large = root.appendingPathComponent("encoded-limit.jpg")
            fm.createFile(atPath:large.path,contents:nil)
            let handle = try FileHandle(forWritingTo:large); try handle.truncate(atOffset:UInt64(StudioImageImportService.maximumEncodedBytes+1)); try handle.close()
            try await rejects(.limitExceeded) { _ = try await service.importImage(from:large,scratchParent:scratch) }
            let narrow = try file(root,"too-wide.png",encoded(makeImage(width:8193,height:1) { _,_ in colors[0] }))
            try await rejects(.limitExceeded) { _ = try await service.importImage(from:narrow,scratchParent:scratch) }
            let oversized = try autoreleasepool { try largeFixture(width:8064,height:6048,noise:false) }
            let declared = try file(root,"actual-48-megapixels.png",oversized)
            try await rejects(.limitExceeded) { _ = try await service.importImage(from:declared,scratchParent:scratch) }
            try require(try fm.attributesOfItem(atPath:large.path)[.size] as? Int == StudioImageImportService.maximumEncodedBytes+1, "Encoded oversized original was altered")
        }
        try await test("bounded PNG consumer rejects actual noisy image output over 40 MiB") {
            let encoded = try autoreleasepool { try largeFixture(width:4096,height:4096,noise:true) }
            try require(encoded.count < StudioImageImportService.maximumEncodedBytes,"Output-limit fixture exceeded encoded input bound")
            let url = try file(root,"bounded-output.jpg",encoded)
            let observation = EncodingObservation()
            try await rejects(.limitExceeded) {
                _ = try await service.importImage(from:url,scratchParent:scratch) { progress in
                    if progress.phase == .encoding { await observation.mark() }
                }
            }
            let reachedEncoding = await observation.reached
            try require(reachedEncoding,"Expected a bounded output failure after the real image decoded")
            try require(try Data(contentsOf:url)==encoded,"Output limit changed original JPEG")
        }
        try await test("corrupt checksums, truncated PNG/JPEG/HEIF and nonimages fail without partial results") {
            var corrupt = png; corrupt[corrupt.count-5] ^= 1
            var fixtures = [Data(),Data("not an image".utf8),corrupt,Data(png.dropLast(8))]
            fixtures += [Data(try encoded(tiny,type:"public.jpeg").dropLast(2)),Data(try encoded(try makeImage(width:64,height:64) { _,_ in colors[0] },type:"public.heic").dropLast(12))]
            for (index,bytes) in fixtures.enumerated() {
                let url = try file(root,"damaged-\(index)",bytes)
                try await rejects { _ = try await service.importImage(from:url,scratchParent:scratch) }
                try require(try Data(contentsOf:url) == bytes, "Damaged original was modified")
            }
        }
        try await test("multi-image GIF and animated PNG are not silently flattened") {
            let second = try makeImage(width:3,height:2) { x,y in colors[5-y*3-x] }
            let animation = try encoded(tiny,type:"com.compuserve.gif",count:2,alternateImage:second)
            let source = CGImageSourceCreateWithData(animation as CFData,nil)!
            try require(CGImageSourceGetCount(source)==2,"Apple fixture encoder did not create two actual image frames")
            let gif = try file(root,"two-images.gif",animation)
            try await rejects(.multipleImages) { _ = try await service.importImage(from:gif,scratchParent:scratch) }
            let apng = Data(png.prefix(33)) + chunk("acTL",Data([0,0,0,1,0,0,0,0])) + png.dropFirst(33)
            let url = try file(root,"animated.png",apng)
            try await rejects(.multipleImages) { _ = try await service.importImage(from:url,scratchParent:scratch) }
            let stillGIF = try file(root,"one-image.gif",encoded(tiny,type:"com.compuserve.gif"))
            try await rejects(.unsupportedContainer) { _ = try await service.importImage(from:stillGIF,scratchParent:scratch) }
        }
        try await test("excessive PNG metadata is bounded before ImageIO enumeration") {
            var bytes = Data(png.prefix(33))
            let metadata = chunk("tEXt",Data("note\0value".utf8))
            for _ in 0..<StudioImageImportService.maximumContainerChunks { bytes.append(metadata) }
            bytes.append(png.dropFirst(33))
            let url = try file(root,"metadata-limit.png",bytes)
            try await rejects(.limitExceeded) { _ = try await service.importImage(from:url,scratchParent:scratch) }
            try require(try Data(contentsOf:url)==bytes,"Metadata limit changed original")
        }
        try await test("remote URLs, symlinks, directories and FIFOs fail without reading streams") {
            let link = root.appendingPathComponent("link.png"); try fm.createSymbolicLink(at:link,withDestinationURL:source)
            let fifo = root.appendingPathComponent("pipe"); try require(mkfifo(fifo.path,0o600)==0,"Fixture FIFO failed")
            for url in [URL(string:"https://example.invalid/image.png")!,link,root,fifo] {
                try await rejects(.unsafeSource) { _ = try await service.importImage(from:url,scratchParent:scratch) }
            }
            try require(try Data(contentsOf:source)==png,"Unsafe path test changed original")
        }
        try await test("invalid names and unsafe scratch parent preserve unrelated paths") {
            for name in ["", "\n", String(repeating:"a",count:121)] {
                try await rejects(.invalidName) { _ = try await service.importImage(from:source,name:name,scratchParent:scratch) }
            }
            let link = root.appendingPathComponent("scratch-link"); try fm.createSymbolicLink(at:link,withDestinationURL:scratch)
            try await rejects(.temporaryStorage) { _ = try await service.importImage(from:source,scratchParent:link) }
        }
        try await test("source mutation during bounded copy is rejected without altering the changed original") {
            let url = try file(root,"changing.png",png)
            try await rejects(.sourceChanged) {
                _ = try await service.importImage(from:url,scratchParent:scratch) { progress in
                    if progress.phase == .reading && progress.completed == progress.total {
                        let handle = try FileHandle(forWritingTo:url); try handle.seekToEnd(); try handle.write(contentsOf:Data([1])); try handle.close()
                    }
                }
            }
            try require(try Data(contentsOf:url)==png+Data([1]),"Importer overwrote concurrent source change")
        }
        try await test("actual task cancellation and process-wide decode lease preserve originals and permit retry") {
            let pause = Pause()
            let task = Task { try await service.importImage(from:source,scratchParent:scratch) { progress in
                if progress.phase == .decoding { await pause.wait() }
            } }
            while !(await pause.reached) { await Task.yield() }
            try await rejects(.busy) { _ = try await StudioImageImportService().importImage(from:source,scratchParent:scratch) }
            task.cancel(); await pause.resume()
            try await cancelled { _ = try await task.value }
            let result = try await service.importImage(from:source,scratchParent:scratch)
            try require(result.originalData==png,"Retry after cancel failed")
        }
        try await test("cancellation at copy and encoding boundaries leaves no receipt or temporary copy") {
            for phase in [StudioImageImportService.Progress.Phase.reading,.encoding] {
                try await cancelled {
                    _ = try await service.importImage(from:source,scratchParent:scratch) { progress in
                        if progress.phase == phase { throw CancellationError() }
                    }
                }
            }
            try require(try Data(contentsOf:source)==png,"Cancellation changed selected file")
        }
        try await test("replaced staging directories survive normal failure and cancellation at real copy/encoding callbacks") {
            for (index, phase) in [StudioImageImportService.Progress.Phase.reading, .encoding].enumerated() {
                let folder = root.appendingPathComponent("replaced-directory-\(index)")
                let ownScratch = folder.appendingPathComponent("scratch")
                try fm.createDirectory(at: ownScratch, withIntermediateDirectories: true)
                defer { try? fm.removeItem(at: folder) }
                let mutation = ScratchInterference(mode: .replaceDirectory, parent: ownScratch, root: folder)
                do {
                    _ = try await service.importImage(from: source, scratchParent: ownScratch) { progress in
                        if progress.phase == phase {
                            try await mutation.apply(throwAfter: index == 0)
                            if index == 1 { throw CancellationError() }
                        }
                    }
                    throw Failure(message: "Replaced staging returned an image receipt")
                } catch StudioImageImportService.ImportError.cleanupFailed { }
                let affected = await mutation.affected!
                try require(try Data(contentsOf: affected.appendingPathComponent("foreign.txt")) == Data("foreign bytes must survive".utf8), "Foreign replacement was deleted or changed")
                try require(try Data(contentsOf: mutation.moved.appendingPathComponent("source.image")) == png, "Renamed owned original was deleted or changed")
                try require(try Data(contentsOf: source) == png, "Selected original changed")
            }
        }
        try await test("a symlink replacing staging cannot redirect cleanup to its target") {
            let folder = root.appendingPathComponent("replaced-symlink"), ownScratch = folder.appendingPathComponent("scratch")
            try fm.createDirectory(at: ownScratch, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: folder) }
            let mutation = ScratchInterference(mode: .replaceWithSymlink, parent: ownScratch, root: folder)
            do {
                _ = try await service.importImage(from: source, scratchParent: ownScratch) { progress in
                    if progress.phase == .reading { try await mutation.apply() }
                }
                throw Failure(message: "Replaced staging symlink returned an image")
            } catch StudioImageImportService.ImportError.cleanupFailed { }
            let affected = await mutation.affected!
            try require(try fm.destinationOfSymbolicLink(atPath: affected.path) == mutation.target.path, "Replacement symlink was removed")
            try require(try Data(contentsOf: mutation.target.appendingPathComponent("source.image")) == Data("foreign bytes must survive".utf8), "Cleanup followed a symlink")
            try require(try Data(contentsOf: mutation.moved.appendingPathComponent("source.image")) == png, "Renamed staging bytes lost")
        }
        try await test("replaced source.image identity preserves both foreign file and moved owned bytes") {
            let folder = root.appendingPathComponent("replaced-file"), ownScratch = folder.appendingPathComponent("scratch")
            try fm.createDirectory(at: ownScratch, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: folder) }
            let mutation = ScratchInterference(mode: .replaceFile, parent: ownScratch, root: folder)
            do {
                _ = try await service.importImage(from: source, scratchParent: ownScratch) { progress in
                    if progress.phase == .reading { try await mutation.apply() }
                }
                throw Failure(message: "Replaced owned file returned an image")
            } catch StudioImageImportService.ImportError.cleanupFailed { }
            let affected = await mutation.affected!
            try require(try Data(contentsOf: affected.appendingPathComponent("source.image")) == Data("foreign bytes must survive".utf8), "Foreign source.image was removed")
            try require(try Data(contentsOf: mutation.moved) == png, "Moved actual copy was removed")
        }
        try await test("unrecognized files and nested directories in owned staging survive cleanup failure") {
            let folder = root.appendingPathComponent("foreign-entry"), ownScratch = folder.appendingPathComponent("scratch")
            try fm.createDirectory(at: ownScratch, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: folder) }
            let mutation = ScratchInterference(mode: .foreignEntry, parent: ownScratch, root: folder)
            do {
                _ = try await service.importImage(from: source, scratchParent: ownScratch) { progress in
                    if progress.phase == .encoding { try await mutation.apply() }
                }
                throw Failure(message: "Incomplete cleanup returned an image receipt")
            } catch StudioImageImportService.ImportError.cleanupFailed { }
            let affected = await mutation.affected!
            for path in ["foreign.txt", "foreign-folder/nested.txt"] {
                try require(try Data(contentsOf: affected.appendingPathComponent(path)) == Data("foreign bytes must survive".utf8), "Unknown staging content was removed")
            }
            try require(!fm.fileExists(atPath: affected.appendingPathComponent("source.image").path), "Owned copy was not cleaned before empty-directory failure")
            let retry = try await service.importImage(from: source, scratchParent: ownScratch)
            try require(retry.originalData == png, "Cleanup failure kept the global decode lease")
        }
        try await test("renamed scratch parent cannot redirect owned-file deletion to a replacement tree") {
            let folder = root.appendingPathComponent("replaced-parent"), ownScratch = folder.appendingPathComponent("scratch")
            try fm.createDirectory(at: ownScratch, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: folder) }
            let mutation = ScratchInterference(mode: .replaceParent, parent: ownScratch, root: folder)
            do {
                _ = try await service.importImage(from: source, scratchParent: ownScratch) { progress in
                    if progress.phase == .decoding { try await mutation.apply() }
                }
                throw Failure(message: "Replaced scratch parent returned an image")
            } catch StudioImageImportService.ImportError.cleanupFailed { }
            let affected = await mutation.affected!
            try require(try Data(contentsOf: affected.appendingPathComponent("source.image")) == Data("foreign bytes must survive".utf8), "Deletion followed the replacement parent URL")
            try require(try fm.contentsOfDirectory(atPath: mutation.moved.path).isEmpty, "Descriptor-scoped original copy was not safely cleaned")
            try require(try Data(contentsOf: source) == png, "Original input was changed")
        }
        print("STUDIO_IMAGE_IMPORT_TESTS=PASS \(passed) actual ImageIO production cases")
    }
}
