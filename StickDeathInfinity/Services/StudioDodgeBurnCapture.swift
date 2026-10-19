import Foundation

/// Reuse the validated active-layer compositor and stale-context identity.
/// A new effect must not develop a second interpretation of layer appearance.
@MainActor
enum StudioDodgeBurnCapture {
    typealias Capture = StudioBlurCapture.Capture

    static func capture(document: StudioDocument, selection: Set<String>, raster: Data?, rasterDataByID: [String: Data] = [:],
                        clipsToSelection: Bool = false) throws -> Capture {
        try Task.checkCancellation()
        guard selection.isEmpty || clipsToSelection else {
            throw StudioDocumentError.unavailable("Dodging or burning within a selection needs its selection mask. Deselect artwork or select again; nothing changed.")
        }
        return try StudioBlurCapture.capture(document: document, selection: selection, raster: raster, rasterDataByID: rasterDataByID,
                                             clipsToSelection: clipsToSelection)
    }
}
