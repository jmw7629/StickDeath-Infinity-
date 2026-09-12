import Foundation

/// Bounded pixel-region computation only. The native integration must supply
/// captured canonical artwork, recheck editor ownership and commit the result
/// transactionally. This service performs no file or document mutations.
enum StudioFillRegion {
    static let maximumPixels = 4_194_304
    static let maximumSpans = 262_144

    struct Settings: Equatable, Sendable {
        var tolerance = 32
        var contiguous = true
        var expand = 0
        var gapClose = 0
        var antiAlias = true
    }
    struct Span: Equatable, Sendable {
        let row: Int
        let start: Int
        let end: Int // exclusive
        let alpha: UInt8
    }
    struct Mask: Equatable, Sendable {
        let width: Int
        let height: Int
        let spans: [Span]
        let coveredPixels: Int
    }
    enum Failure: LocalizedError, Equatable {
        case invalidImage, invalidSettings, outsideCanvas, emptyRegion, spanLimit
        var errorDescription: String? {
            switch self {
            case .invalidImage: return "Fill needs a complete image within the supported canvas pixel limit."
            case .invalidSettings: return "These fill settings are outside the supported range."
            case .outsideCanvas: return "Tap inside the canvas to fill a region."
            case .emptyRegion: return "These settings leave no fillable pixels at this point."
            case .spanLimit: return "This fill region is too complex. Nothing has been changed."
            }
        }
    }

    /// RGBA rows have a top-left origin and four bytes per pixel. Tolerance is
    /// the maximum difference in any of the four supplied channels, 0...128.
    /// Matching does not chase a gradually changing color across the image.
    static func compute(rgba: Data, width: Int, height: Int, x: Int, y: Int,
                        settings: Settings, checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> Mask {
        try checkCancellation()
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              width <= maximumPixels / height, rgba.count == width * height * 4 else { throw Failure.invalidImage }
        guard (0...128).contains(settings.tolerance), (-5...5).contains(settings.expand),
              (0...5).contains(settings.gapClose) else { throw Failure.invalidSettings }
        guard x >= 0, y >= 0, x < width, y < height else { throw Failure.outsideCanvas }
        let count = width * height, seed = y * width + x, bytes = [UInt8](rgba)
        var matches = [UInt8](repeating: 0, count: count)
        for row in 0..<height {
            try checkCancellation()
            for column in 0..<width {
                let index = row * width + column
                var accepts = true
                for channel in 0..<4 {
                    if abs(Int(bytes[index * 4 + channel]) - Int(bytes[seed * 4 + channel])) > settings.tolerance {
                        accepts = false; break
                    }
                }
                if accepts { matches[index] = 255 }
            }
        }
        // Closing the nonmatching barrier seals small gaps without changing
        // original artwork. Retain every original barrier pixel at image edges.
        if settings.contiguous && settings.gapClose > 0 {
            let barriers = matches.map { 255 - $0 }
            let dilated = try morphology(barriers, width, height, settings.gapClose, erode: false, checkCancellation)
            let closed = try morphology(dilated, width, height, settings.gapClose, erode: true, checkCancellation)
            for index in matches.indices {
                if index % 4096 == 0 { try checkCancellation() }
                if barriers[index] > 0 || closed[index] > 0 { matches[index] = 0 }
            }
        }
        guard matches[seed] > 0 else { throw Failure.emptyRegion }
        var selected = matches
        if settings.contiguous {
            selected = [UInt8](repeating: 0, count: count)
            var queue: [Int32] = [Int32(seed)]
            selected[seed] = 255
            var cursor = 0
            while cursor < queue.count {
                if cursor % 4096 == 0 { try checkCancellation() }
                let index = Int(queue[cursor]); cursor += 1
                func include(_ neighbour: Int) {
                    if matches[neighbour] > 0 && selected[neighbour] == 0 {
                        selected[neighbour] = 255; queue.append(Int32(neighbour))
                    }
                }
                let column = index % width
                if column > 0 { include(index - 1) }
                if column + 1 < width { include(index + 1) }
                if index >= width { include(index - width) }
                if index < count - width { include(index + width) }
            }
        }
        if settings.expand != 0 {
            selected = try morphology(selected, width, height, abs(settings.expand), erode: settings.expand < 0, checkCancellation)
        }
        if settings.antiAlias {
            let hard = selected
            for row in 0..<height {
                try checkCancellation()
                for column in 0..<width {
                    var total = 0, samples = 0
                    for yy in max(0,row-1)...min(height-1,row+1) {
                        for xx in max(0,column-1)...min(width-1,column+1) {
                            total += Int(hard[yy * width + xx]); samples += 1
                        }
                    }
                    selected[row * width + column] = UInt8((total + samples / 2) / samples)
                }
            }
        }
        var spans: [Span] = [], covered = 0
        for row in 0..<height {
            try checkCancellation()
            var column = 0
            while column < width {
                let alpha = selected[row * width + column], start = column
                column += 1
                while column < width && selected[row * width + column] == alpha { column += 1 }
                if alpha != 0 {
                    guard spans.count < maximumSpans else { throw Failure.spanLimit }
                    spans.append(.init(row: row, start: start, end: column, alpha: alpha))
                    covered += column - start
                }
            }
        }
        try checkCancellation()
        guard covered > 0 else { throw Failure.emptyRegion }
        return .init(width: width, height: height, spans: spans, coveredPixels: covered)
    }

    /// Separable square morphology in O(width*height), independent of radius.
    /// Outside-canvas pixels are empty: shrinking retreats from canvas edges.
    private static func morphology(_ input: [UInt8], _ width: Int, _ height: Int,
                                   _ radius: Int, erode: Bool, _ check: () throws -> Void) throws -> [UInt8] {
        var horizontal = [UInt8](repeating: 0, count: input.count)
        let window = radius * 2 + 1
        for row in 0..<height {
            try check()
            var active = 0
            for column in 0..<min(width,radius+1) { if input[row * width + column] > 0 { active += 1 } }
            for column in 0..<width {
                horizontal[row * width + column] = (erode ? active == window : active > 0) ? 255 : 0
                let leaving = column - radius, entering = column + radius + 1
                if leaving >= 0 && input[row * width + leaving] > 0 { active -= 1 }
                if entering < width && input[row * width + entering] > 0 { active += 1 }
            }
        }
        var output = [UInt8](repeating: 0, count: input.count)
        var counts = [Int](repeating: 0, count: width)
        for row in 0..<min(height,radius+1) {
            try check()
            for column in 0..<width { if horizontal[row * width + column] > 0 { counts[column] += 1 } }
        }
        for row in 0..<height {
            try check()
            let leaving = row - radius, entering = row + radius + 1
            for column in 0..<width {
                output[row * width + column] = (erode ? counts[column] == window : counts[column] > 0) ? 255 : 0
                if leaving >= 0 && horizontal[leaving * width + column] > 0 { counts[column] -= 1 }
                if entering < height && horizontal[entering * width + column] > 0 { counts[column] += 1 }
            }
        }
        return output
    }
}
