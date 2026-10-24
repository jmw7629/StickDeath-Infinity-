import Foundation

/// Framing chosen in the video import panel (#201): a clockwise right-angle
/// rotation applied after the track's own orientation, then a centered crop of
/// the turned frame. Foundation-only so the persisted document mapping
/// (`StudioVideoSourceMapping`) and the AVFoundation frame decoder share it.
enum StudioVideoFraming {
    static let rotations = [0, 90, 180, 270]

    /// Size after turning `width`×`height` clockwise by `rotationDegrees`.
    static func turnedSize(width: Int, height: Int, rotationDegrees: Int) -> (width: Int, height: Int) {
        rotationDegrees == 90 || rotationDegrees == 270 ? (height, width) : (width, height)
    }
    /// Size of the decoded reference frame after rotation and crop.
    static func outputSize(width: Int, height: Int, rotationDegrees: Int,
                           aspect: StudioVideoFrameAspect) -> (width: Int, height: Int) {
        let turned = turnedSize(width: width, height: height, rotationDegrees: rotationDegrees)
        let crop = aspect.cropRect(width: turned.width, height: turned.height)
        return (crop.width, crop.height)
    }
}

/// Aspect of the centered crop. `original` keeps every pixel of the frame.
enum StudioVideoFrameAspect: String, Codable, CaseIterable, Sendable {
    case original, square, landscape16x9, portrait9x16, landscape4x3, portrait3x4

    var title: String {
        switch self {
        case .original: return "Original"
        case .square: return "1:1"
        case .landscape16x9: return "16:9"
        case .portrait9x16: return "9:16"
        case .landscape4x3: return "4:3"
        case .portrait3x4: return "3:4"
        }
    }
    /// Width and height terms of the ratio; nil keeps the source frame.
    var ratio: (width: Int, height: Int)? {
        switch self {
        case .original: return nil
        case .square: return (1, 1)
        case .landscape16x9: return (16, 9)
        case .portrait9x16: return (9, 16)
        case .landscape4x3: return (4, 3)
        case .portrait3x4: return (3, 4)
        }
    }
    /// The largest centered rectangle of this aspect inside a `width`×`height`
    /// frame, in whole pixels with a top-left origin. Never larger than the frame.
    func cropRect(width: Int, height: Int) -> (x: Int, y: Int, width: Int, height: Int) {
        guard width > 0, height > 0, let ratio else { return (0, 0, max(width, 0), max(height, 0)) }
        var cropWidth = width, cropHeight = height
        if width * ratio.height > height * ratio.width {
            cropWidth = max(1, (height * ratio.width) / ratio.height)
        } else {
            cropHeight = max(1, (width * ratio.height) / ratio.width)
        }
        return ((width - cropWidth) / 2, (height - cropHeight) / 2, cropWidth, cropHeight)
    }
}
