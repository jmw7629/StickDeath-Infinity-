import Foundation

/// Attribution carried by one bundled library sound. The catalogue is the only
/// producer; exports and publish records copy it, never edit it (#191, #198).
struct StudioSoundAttribution: Codable, Equatable {
    let title: String
    let author: String
    let sourceURL: String
    let license: String
    let licenseURL: String
    /// SHA-256 of the shipped library file (also its catalogue identifier).
    let catalogueSoundID: String
    /// SHA-256 of the publisher's original file before transcoding.
    let originalSHA256: String
}

/// One project audio asset matched to its library attribution by digest.
struct StudioSoundCredit: Codable, Equatable {
    let assetID: UUID
    let title: String
    let author: String
    let sourceURL: String
    let license: String
    let licenseURL: String
    let catalogueSoundID: String
    let originalSHA256: String

    init(assetID: UUID, attribution: StudioSoundAttribution) {
        self.assetID = assetID
        title = attribution.title; author = attribution.author; sourceURL = attribution.sourceURL
        license = attribution.license; licenseURL = attribution.licenseURL
        catalogueSoundID = attribution.catalogueSoundID; originalSHA256 = attribution.originalSHA256
    }

    enum Failure: Error, Equatable, LocalizedError {
        case invalid
        var errorDescription: String? { "A sound attribution record is invalid. No export was published." }
    }

    static func isDigest(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    /// Same trust boundary as the sound catalogue loader: CC0 only, https
    /// sources from the two verified publishers, bounded labels, hex digests.
    func validate() throws {
        let digest = Self.isDigest
        func label(_ text: String) -> Bool { !text.isEmpty && text.count <= 120 && !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
        guard label(title), label(author), digest(catalogueSoundID), digest(originalSHA256),
              license == "CC0-1.0", licenseURL == "https://creativecommons.org/publicdomain/zero/1.0/",
              let source = URL(string: sourceURL), source.scheme == "https", source.user == nil, source.password == nil,
              let host = source.host, ["kenney.nl", "opengameart.org"].contains(host) else { throw Failure.invalid }
    }
    /// Human-readable line for manifests and the export panel.
    var summary: String { "\(title) — \(author) (\(license))" }
}

/// Resolves project assets to library credits by the digest of their bytes.
/// Sounds imported from Files have no library match and produce no credit;
/// that is a fact about provenance, not an error.
enum StudioSoundCreditResolver {
    struct Asset: Equatable {
        let id: UUID
        let sha256: String
    }
    static let maximumCredits = 128

    static func credits(for assets: [Asset], lookup: (String) -> StudioSoundAttribution?) throws -> [StudioSoundCredit] {
        guard assets.count <= maximumCredits, Set(assets.map(\.id)).count == assets.count else { throw StudioSoundCredit.Failure.invalid }
        var result: [StudioSoundCredit] = []
        for asset in assets.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            guard StudioSoundCredit.isDigest(asset.sha256), let attribution = lookup(asset.sha256) else { continue }
            guard attribution.catalogueSoundID == asset.sha256 else { throw StudioSoundCredit.Failure.invalid }
            let credit = StudioSoundCredit(assetID: asset.id, attribution: attribution)
            try credit.validate()
            result.append(credit)
        }
        return result
    }
}
