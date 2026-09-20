import Foundation
import CryptoKit
import ImageIO
import Darwin

/// Bundled, curated artwork only. Loading or searching this catalogue never
/// changes a project or fetches a URL. Additions must use the Studio importer.
struct StudioImageCatalogue: Sendable {
    enum Category: String, Codable, CaseIterable, Sendable { case props, scenery, effects }
    enum ContentAdvisory: String, Codable, Sendable { case none, cartoonWeapons }
    struct License: Codable, Equatable, Sendable {
        let id: String
        let author: String
        let sourceURL: String
        let license: String
        let licenseURL: String
        let attribution: String
        let licenseFilename: String
        let licenseSHA256: String
        let licenseByteCount: Int
        let sourceArchiveSHA256: String
    }
    struct Image: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let title: String
        let category: Category
        let tags: [String]
        let contentAdvisory: ContentAdvisory
        let licenseID: String
        let originalSHA256: String
        let sha256: String
        let pixelSHA256: String
        let filename: String
        let byteCount: Int
        let width: Int
        let height: Int
    }
    private struct Manifest: Decodable {
        let schemaVersion: Int
        let licenses: [License]
        let images: [Image]
    }
    static let maximumManifestBytes = 16 * 1024 * 1024
    static let maximumImageBytes = 16 * 1024 * 1024
    let images: [Image]
    let licenses: [License]
    private let directory: URL

    init(directory: URL) throws {
        guard directory.isFileURL else { throw CatalogueError.unavailable }
        self.directory = directory.standardizedFileURL
        let data = try Self.readFile(directory.appendingPathComponent("catalogue.json"), limit:Self.maximumManifestBytes)
        let manifest = try JSONDecoder().decode(Manifest.self,from:data)
        guard manifest.schemaVersion == 1, (1...5000).contains(manifest.images.count),
              (1...100).contains(manifest.licenses.count),
              Set(manifest.licenses.map(\.id)).count == manifest.licenses.count,
              Set(manifest.images.map(\.id)).count == manifest.images.count,
              Set(manifest.images.map(\.sha256)).count == manifest.images.count,
              Set(manifest.images.map { "\($0.width):\($0.height):\($0.pixelSHA256)" }).count == manifest.images.count
        else { throw CatalogueError.invalid }
        for item in manifest.licenses {
            try Task.checkCancellation()
            guard Self.identifier(item.id), Self.label(item.author), Self.label(item.attribution,limit:500),
                  item.license == "CC0-1.0", item.licenseURL == "https://creativecommons.org/publicdomain/zero/1.0/",
                  Self.hash(item.licenseSHA256), Self.hash(item.sourceArchiveSHA256),
                  item.licenseFilename == item.licenseSHA256+".txt", (1...65536).contains(item.licenseByteCount),
                  let url=URL(string:item.sourceURL),url.scheme=="https",url.host=="kenney.nl",
                  url.user==nil,url.password==nil,url.port==nil,url.query==nil,url.fragment==nil,
                  url.path.hasPrefix("/assets/"),url.path.count>8
            else { throw CatalogueError.invalid }
            let text=try Self.readFile(directory.appendingPathComponent(item.licenseFilename),limit:65536)
            guard text.count==item.licenseByteCount,Self.digest(text)==item.licenseSHA256,
                  let license=String(data:text,encoding:.utf8),license.contains("CC0"),license.contains("Kenney")
            else { throw CatalogueError.invalid }
        }
        let licenses=Set(manifest.licenses.map(\.id))
        for item in manifest.images {
            try Task.checkCancellation()
            guard Self.identifier(item.id), Self.label(item.title),licenses.contains(item.licenseID),
                  item.tags.count<=20,Set(item.tags).count==item.tags.count,item.tags.allSatisfy({Self.label($0,limit:60)}),
                  Self.hash(item.sha256),Self.hash(item.originalSHA256),Self.hash(item.pixelSHA256),
                  item.filename==item.sha256+".png",(1...Self.maximumImageBytes).contains(item.byteCount),
                  (1...4096).contains(item.width),(1...4096).contains(item.height),item.width*item.height<=16_777_216
            else { throw CatalogueError.invalid }
        }
        images=manifest.images;self.licenses=manifest.licenses
    }
    static func bundled(in bundle: Bundle = .main) throws -> Self {
        guard let url=bundle.url(forResource:"StudioImages",withExtension:nil) else { throw CatalogueError.unavailable }
        return try Self(directory:url)
    }
    static func loadBundled(in bundle: Bundle = .main) async throws -> Self {
        guard let directory = bundle.url(forResource: "StudioImages", withExtension: nil) else {
            throw CatalogueError.unavailable
        }
        return try await load(directory: directory)
    }
    /// This URL is only an input to the existing importer. The import session
    /// compares its copied original bytes with checkedPNG before showing preview.
    func sourceURL(for image: Image) throws -> URL {
        guard images.contains(image) else { throw CatalogueError.invalid }
        return directory.appendingPathComponent(image.filename)
    }
    func attribution(for image: Image) throws -> [String: String] {
        guard images.contains(image), let license = licenses.first(where: { $0.id == image.licenseID }) else {
            throw CatalogueError.invalid
        }
        return ["assetID": image.id, "author": license.author, "sourceURL": license.sourceURL,
                "license": license.license, "licenseURL": license.licenseURL,
                "attribution": license.attribution, "originalSHA256": image.sha256,
                "sourceArchiveSHA256": license.sourceArchiveSHA256]
    }
    static func load(directory: URL) async throws -> Self {
        try Task.checkCancellation()
        let task=Task.detached(priority:.userInitiated) {
            try Task.checkCancellation();let result=try Self(directory:directory)
            try Task.checkCancellation();return result
        }
        return try await withTaskCancellationHandler {
            let result=try await task.value;try Task.checkCancellation();return result
        } onCancel: { task.cancel() }
    }
    func search(_ query: String,category: Category? = nil,includeCartoonWeapons: Bool = true) -> [Image] {
        let terms=query.split(whereSeparator:\.isWhitespace).map(String.init)
        return images.filter { item in
            (category==nil || item.category==category) && (includeCartoonWeapons || item.contentAdvisory == .none) &&
            terms.allSatisfy { (item.title+" "+item.category.rawValue+" "+item.tags.joined(separator:" ")).localizedCaseInsensitiveContains($0) }
        }
    }
    /// Pin, hash and decode the actual immutable bytes before any Studio import.
    /// Reject symlinks/FIFOs, mismatched metadata and aliases outside this list.
    func checkedPNG(_ item: Image) throws -> Data {
        try Task.checkCancellation()
        guard images.contains(item) else { throw CatalogueError.invalid }
        let data=try Self.readFile(directory.appendingPathComponent(item.filename),limit:Self.maximumImageBytes)
        guard data.count==item.byteCount,Self.digest(data)==item.sha256,
              let source=CGImageSourceCreateWithData(data as CFData,nil),CGImageSourceGetType(source) as String? == "public.png",
              CGImageSourceGetCount(source)==1,
              let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue==item.width,
              (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue==item.height,
              let image=CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary),
              image.width==item.width,image.height==item.height,
              let bitmap=CGContext(data:nil,width:item.width,height:item.height,bitsPerComponent:8,bytesPerRow:item.width*4,
                  space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { throw CatalogueError.invalid }
        bitmap.draw(image,in:CGRect(x:0,y:0,width:item.width,height:item.height))
        guard let bytes=bitmap.data else { throw CatalogueError.invalid }
        let rgba=Data(bytes:bytes,count:item.width*item.height*4)
        guard Self.digest(rgba)==item.pixelSHA256 else { throw CatalogueError.invalid }
        try Task.checkCancellation()
        return data
    }
    private static func readFile(_ url: URL,limit: Int) throws -> Data {
        let fd=Darwin.open(url.path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        guard fd>=0 else { throw CatalogueError.invalid };defer { _=Darwin.close(fd) }
        var s=stat()
        guard fstat(fd,&s)==0,s.st_mode & mode_t(S_IFMT)==mode_t(S_IFREG),s.st_size>0,s.st_size<=limit else { throw CatalogueError.invalid }
        let file=FileHandle(fileDescriptor:fd,closeOnDealloc:false)
        let data=try file.read(upToCount:Int(s.st_size)+1) ?? Data()
        guard data.count==Int(s.st_size) else { throw CatalogueError.invalid };return data
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    private static func hash(_ text: String) -> Bool { text.utf8.count==64 && text.utf8.allSatisfy { (48...57).contains($0)||(97...102).contains($0) } }
    private static func identifier(_ text: String) -> Bool {
        (1...180).contains(text.utf8.count) && text.utf8.allSatisfy { (48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)||[45,46,95].contains($0) }
    }
    private static func label(_ text: String,limit: Int = 120) -> Bool {
        !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && text.count<=limit && !text.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains)
    }
    enum CatalogueError: LocalizedError {
        case unavailable,invalid
        var errorDescription: String? {
            switch self {
            case .unavailable:return "The image library is not installed in this build. You can still import your own pictures."
            case .invalid:return "The image library could not be verified. No artwork was added."
            }
        }
    }
}
