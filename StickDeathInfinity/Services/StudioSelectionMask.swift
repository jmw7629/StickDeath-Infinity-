import Foundation

/// Canvas-space selection coverage shared by Wand, Fill, Gradient and the
/// pixel effects (#149, #153). One byte per pixel, 0 = unselected, 255 = fully
/// selected, top-left origin. Pure and bounded: no document mutation.
enum StudioSelectionMask {
    static let maximumPixels = StudioFillRegion.maximumPixels
    static let maximumFeatherRadius = 64
    /// Upper bound on pixel probes for one element hit test.
    static let maximumElementProbes = 8_000_000

    enum Mode: String, Codable, CaseIterable, Sendable { case replace, add, subtract, intersect }

    enum Failure: LocalizedError, Equatable {
        case invalidMask, invalidSettings, transparentSeed, emptySelection, workLimit
        var errorDescription: String? {
            switch self {
            case .invalidMask: return "The selection does not match the canvas size. Nothing has changed."
            case .invalidSettings: return "These selection settings are outside the supported range."
            case .transparentSeed: return "This pixel is transparent on the sampled layer. Tap visible artwork, or sample the visible canvas."
            case .emptySelection: return "Nothing is selected."
            case .workLimit: return "This selection is too complex to process. Nothing has changed."
            }
        }
    }

    private static func checkSize(_ width: Int, _ height: Int) throws {
        guard width > 0, height > 0, width <= 4096, height <= 4096, width <= maximumPixels / height else {
            throw Failure.invalidMask
        }
    }

    /// Expands a sparse fill/wand span mask into dense per-pixel coverage.
    static func coverage(from mask: StudioFillRegion.Mask) throws -> [UInt8] {
        try checkSize(mask.width, mask.height)
        var result = [UInt8](repeating: 0, count: mask.width * mask.height)
        for span in mask.spans {
            guard span.row >= 0, span.row < mask.height, span.start >= 0, span.start < span.end,
                  span.end <= mask.width else { throw Failure.invalidMask }
            let base = span.row * mask.width
            for column in span.start..<span.end { result[base + column] = span.alpha }
        }
        return result
    }

    /// Sparse run-length encoding of dense coverage; bounded by `maximumSpans`.
    static func spans(of coverage: [UInt8], width: Int, height: Int) throws -> StudioFillRegion.Mask {
        try checkSize(width, height)
        guard coverage.count == width * height else { throw Failure.invalidMask }
        var spans: [StudioFillRegion.Span] = [], covered = 0
        for row in 0..<height {
            var column = 0
            while column < width {
                let alpha = coverage[row * width + column], start = column
                column += 1
                while column < width && coverage[row * width + column] == alpha { column += 1 }
                if alpha != 0 {
                    guard spans.count < StudioFillRegion.maximumSpans else { throw Failure.workLimit }
                    spans.append(.init(row: row, start: start, end: column, alpha: alpha))
                    covered += column - start
                }
            }
        }
        return .init(width: width, height: height, spans: spans, coveredPixels: covered)
    }

    /// New / Add / Subtract / Intersect, with fractional (feathered) weights.
    static func combine(_ previous: [UInt8]?, _ next: [UInt8], mode: Mode) throws -> [UInt8] {
        guard let previous, mode != .replace else { return mode == .subtract || mode == .intersect ? [UInt8](repeating: 0, count: next.count) : next }
        guard previous.count == next.count else { throw Failure.invalidMask }
        var result = [UInt8](repeating: 0, count: next.count)
        for index in next.indices {
            let a = Int(previous[index]), b = Int(next[index])
            switch mode {
            case .replace: result[index] = UInt8(b)
            case .add: result[index] = UInt8(max(a, b))
            case .subtract: result[index] = UInt8((a * (255 - b) + 127) / 255)
            case .intersect: result[index] = UInt8(min(a, b))
            }
        }
        return result
    }

    /// Softens the selection edge by `radius` pixels using three separable box
    /// passes (a close Gaussian approximation), O(width*height) for any radius.
    /// Outside-canvas pixels count as unselected.
    static func feather(_ coverage: [UInt8], width: Int, height: Int, radius: Int,
                        checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> [UInt8] {
        try checkSize(width, height)
        guard coverage.count == width * height else { throw Failure.invalidMask }
        guard (0...maximumFeatherRadius).contains(radius) else { throw Failure.invalidSettings }
        guard radius > 0 else { return coverage }
        // Three box passes of radius r/√3-ish sum to roughly the requested
        // spread; keep each box at least one pixel.
        let box = max(1, Int((Double(radius) / 1.7).rounded()))
        var values = coverage.map { Int($0) * 256 }
        var scratch = [Int](repeating: 0, count: values.count)
        let window = box * 2 + 1
        for _ in 0..<3 {
            for row in 0..<height {
                try checkCancellation()
                let base = row * width
                var sum = 0
                for column in 0..<min(width, box + 1) { sum += values[base + column] }
                for column in 0..<width {
                    scratch[base + column] = sum / window
                    let leaving = column - box, entering = column + box + 1
                    if leaving >= 0 { sum -= values[base + leaving] }
                    if entering < width { sum += values[base + entering] }
                }
            }
            for column in 0..<width {
                if column % 256 == 0 { try checkCancellation() }
                var sum = 0
                for row in 0..<min(height, box + 1) { sum += scratch[row * width + column] }
                for row in 0..<height {
                    values[row * width + column] = sum / window
                    let leaving = row - box, entering = row + box + 1
                    if leaving >= 0 { sum -= scratch[leaving * width + column] }
                    if entering < height { sum += scratch[entering * width + column] }
                }
            }
        }
        return values.map { UInt8(min(255, ($0 + 128) / 256)) }
    }

    /// Selection-limited effect: blends an effected copy of a premultiplied
    /// RGBA layer back into its original by coverage. Unselected pixels stay
    /// byte-identical to the original and fully selected pixels equal the
    /// effect, so the result never leaks outside the selection.
    static func clip(original: [UInt8], effected: [UInt8], coverage: [UInt8], width: Int, height: Int,
                     checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> [UInt8] {
        try checkSize(width, height)
        guard original.count == width * height * 4, effected.count == original.count,
              coverage.count == width * height else { throw Failure.invalidMask }
        var output = original
        for row in 0..<height {
            try checkCancellation()
            for column in 0..<width {
                let index = row * width + column
                let weight = Int(coverage[index])
                if weight == 0 { continue }
                let o = index * 4
                if weight == 255 {
                    output[o] = effected[o]; output[o + 1] = effected[o + 1]
                    output[o + 2] = effected[o + 2]; output[o + 3] = effected[o + 3]
                    continue
                }
                // Linear interpolation of premultiplied values keeps every
                // colour channel at or below its alpha.
                for channel in 0..<4 {
                    let a = Int(original[o + channel]), b = Int(effected[o + channel])
                    output[o + channel] = UInt8(a + ((b - a) * weight + (b >= a ? 127 : -127)) / 255)
                }
            }
        }
        return output
    }

    /// Bounds of selected pixels as (minX, minY, maxX, maxY), exclusive max.
    static func bounds(of coverage: [UInt8], width: Int, height: Int) throws -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        try checkSize(width, height)
        guard coverage.count == width * height else { throw Failure.invalidMask }
        var minX = width, minY = height, maxX = 0, maxY = 0
        for row in 0..<height {
            for column in 0..<width where coverage[row * width + column] > 0 {
                minX = min(minX, column); maxX = max(maxX, column + 1)
                minY = min(minY, row); maxY = max(maxY, row + 1)
            }
        }
        return maxX > minX ? (minX, minY, maxX, maxY) : nil
    }
}

/// Wand on any captured RGBA surface (#153): the active drawing layer or the
/// composited visible canvas, not only managed image layers. Tolerance and
/// contiguous/global sampling reuse StudioFillRegion; the result is a dense
/// canvas-space selection that can be feathered and combined.
enum StudioWandRegion {
    struct Settings: Equatable, Sendable {
        var tolerance = 32
        var contiguous = true
        var feather = 0
        var mode: StudioSelectionMask.Mode = .replace
        /// Active-layer sampling: a tap on an empty pixel selects nothing
        /// rather than the whole transparent background. Composited canvas
        /// sampling sets this to false because the canvas paper is opaque.
        var rejectTransparentSeed = true
    }

    /// `rgba` is straight RGBA8 from the canonical renderer, top-left origin.
    static func select(rgba: Data, width: Int, height: Int, x: Int, y: Int, settings: Settings,
                       previous: [UInt8]?,
                       checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> [UInt8] {
        guard (0...StudioSelectionMask.maximumFeatherRadius).contains(settings.feather) else {
            throw StudioSelectionMask.Failure.invalidSettings
        }
        if let previous, previous.count != width * height { throw StudioSelectionMask.Failure.invalidMask }
        if settings.rejectTransparentSeed, x >= 0, y >= 0, x < width, y < height,
           rgba.count == width * height * 4, rgba[rgba.startIndex + (y * width + x) * 4 + 3] == 0 {
            throw StudioSelectionMask.Failure.transparentSeed
        }
        var fill = StudioFillRegion.Settings()
        fill.tolerance = settings.tolerance; fill.contiguous = settings.contiguous
        fill.antiAlias = false
        let mask = try StudioFillRegion.compute(rgba: rgba, width: width, height: height, x: x, y: y,
                                                settings: fill, checkCancellation: checkCancellation)
        var region = try StudioSelectionMask.coverage(from: mask)
        region = try StudioSelectionMask.feather(region, width: width, height: height, radius: settings.feather,
                                                 checkCancellation: checkCancellation)
        let result = try StudioSelectionMask.combine(previous, region, mode: settings.mode)
        try checkCancellation()
        return result
    }
}

/// Maps a canvas selection to the drawn elements it touches, so Wand can
/// select editable vector artwork without flattening it (#153).
enum StudioSelectionElementHitTest {
    struct Candidate: Equatable, Sendable {
        let id: String
        /// Canvas-space centreline samples after the element's transform.
        let points: [(x: Double, y: Double)]
        /// Half the rendered stroke width in canvas pixels.
        let radius: Double
        static func == (lhs: Candidate, rhs: Candidate) -> Bool {
            lhs.id == rhs.id && lhs.radius == rhs.radius && lhs.points.count == rhs.points.count &&
                zip(lhs.points, rhs.points).allSatisfy { $0.x == $1.x && $0.y == $1.y }
        }
    }

    /// IDs, in input order, of candidates with at least `minimumCoveredProbes`
    /// stroke pixels whose selection weight is at least `threshold`.
    static func elements(intersecting coverage: [UInt8], width: Int, height: Int, candidates: [Candidate],
                         threshold: UInt8 = 128, minimumCoveredProbes: Int = 1,
                         checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> [String] {
        guard width > 0, height > 0, coverage.count == width * height, threshold > 0, minimumCoveredProbes > 0 else {
            throw StudioSelectionMask.Failure.invalidMask
        }
        var probes = 0, selected: [String] = []
        for candidate in candidates {
            try checkCancellation()
            guard candidate.radius.isFinite, candidate.radius >= 0, candidate.radius <= 512, !candidate.points.isEmpty,
                  candidate.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 1_000_000 && abs($0.y) <= 1_000_000 }) else {
                throw StudioSelectionMask.Failure.invalidSettings
            }
            var visited = Set<Int>(), covered = 0
            let reach = max(0.5, candidate.radius)
            func probe(_ cx: Double, _ cy: Double) throws {
                let minX = max(0, Int(floor(cx - reach))), maxX = min(width - 1, Int(floor(cx + reach)))
                let minY = max(0, Int(floor(cy - reach))), maxY = min(height - 1, Int(floor(cy + reach)))
                guard minX <= maxX, minY <= maxY else { return }
                for py in minY...maxY {
                    for px in minX...maxX {
                        let dx = Double(px) + 0.5 - cx, dy = Double(py) + 0.5 - cy
                        guard dx * dx + dy * dy <= reach * reach else { continue }
                        probes += 1
                        guard probes <= maximumElementProbes else { throw StudioSelectionMask.Failure.workLimit }
                        let index = py * width + px
                        if coverage[index] >= threshold && visited.insert(index).inserted { covered += 1 }
                    }
                }
            }
            // Walk each segment at sub-radius spacing so thin strokes that
            // cross a selection between samples are still found.
            let step = max(0.5, reach)
            try probe(candidate.points[0].x, candidate.points[0].y)
            for index in 1..<max(1, candidate.points.count) where covered < minimumCoveredProbes {
                let a = candidate.points[index - 1], b = candidate.points[index]
                let length = hypot(b.x - a.x, b.y - a.y)
                let count = max(1, Int(ceil(length / step)))
                for k in 1...count where covered < minimumCoveredProbes {
                    let t = Double(k) / Double(count)
                    try probe(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
                }
            }
            if covered >= minimumCoveredProbes { selected.append(candidate.id) }
        }
        return selected
    }
}
