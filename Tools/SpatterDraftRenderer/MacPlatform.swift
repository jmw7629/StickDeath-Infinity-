import AppKit
import SwiftUI

// The renderer runs headless on macOS. Only the platform image container is
// adapted, exactly as the StudioMovieExport tests do, so the production
// exporter and StudioFrameRenderer compile unchanged.
typealias UIImage = NSImage
extension Image { init(uiImage: NSImage) { self.init(nsImage: uiImage) } }
