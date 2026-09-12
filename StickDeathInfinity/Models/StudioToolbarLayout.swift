import Foundation
import CoreGraphics

/// Ephemeral workspace chrome. This never changes the drawing document/history.
struct StudioToolbarLayout: Equatable {
    enum Dock: String { case automatic, floating, leading, trailing }
    var dock: Dock = .automatic
    private(set) var normalizedCenter = CGPoint(x: 0.5, y: 0)
    static let margin: CGFloat = 8
    static let snapDistance: CGFloat = 44

    struct Placement: Equatable {
        let frame: CGRect
        let vertical: Bool
        let dock: Dock
    }

    func placement(in bounds: CGRect, compactHeight: Bool) -> Placement {
        let resolved: Dock = dock == .automatic ? (compactHeight ? .leading : .floating) : dock
        let vertical = resolved == .leading || resolved == .trailing
        let inner = Self.usable(bounds)
        let size = CGSize(width: min(inner.width, vertical ? 76 : 1000),
                          height: min(inner.height, vertical ? 640 : 72))
        var center = CGPoint(x: inner.minX + normalizedCenter.x * inner.width,
                             y: inner.minY + normalizedCenter.y * inner.height)
        if resolved == .leading { center.x = inner.minX + size.width / 2 }
        if resolved == .trailing { center.x = inner.maxX - size.width / 2 }
        center = Self.clamped(center, size: size, to: inner)
        // On short screens a centered horizontal rail can leave less than a
        // 44-point dismissal target on both sides. Shift only enough to keep it reachable.
        if !vertical && inner.height >= size.height + 44 + Self.margin {
            let above = center.y - size.height / 2 - inner.minY - Self.margin
            let below = inner.maxY - center.y - size.height / 2 - Self.margin
            if max(above, below) < 44 {
                center.y += above > below ? 44 - above : -(44 - below)
            }
        }
        return Placement(frame: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                       width: size.width, height: size.height), vertical: vertical, dock: resolved)
    }

    /// The release finger/grip location selects a side; a wide horizontal rail's
    /// clamped center cannot reach the edge, so using its center would never snap.
    mutating func finishDrag(release: CGPoint, proposedCenter: CGPoint, in bounds: CGRect) {
        guard Self.isFinite(release), Self.isFinite(proposedCenter), Self.valid(bounds) else { return }
        if release.x <= bounds.minX + Self.snapDistance { dock = .leading }
        else if release.x >= bounds.maxX - Self.snapDistance { dock = .trailing }
        else { dock = .floating }
        remember(proposedCenter, in: bounds)
    }

    mutating func choose(_ dock: Dock, in bounds: CGRect) {
        guard Self.valid(bounds) else { return }
        self.dock = dock
        if dock == .floating || dock == .automatic { normalizedCenter = CGPoint(x: 0.5, y: 0) }
    }

    func draggingFrame(from initialFrame: CGRect, translation: CGSize, in bounds: CGRect) -> CGRect {
        guard translation.width.isFinite, translation.height.isFinite else { return initialFrame }
        let inner = Self.usable(bounds)
        let size = CGSize(width: min(initialFrame.width, inner.width), height: min(initialFrame.height, inner.height))
        let center = Self.clamped(CGPoint(x: initialFrame.midX + translation.width,
                                        y: initialFrame.midY + translation.height), size: size, to: inner)
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// The sole tool popup opens below a horizontal rail, or beside an edge rail.
    /// Near the bottom edge it uses the larger space above and scrolls its content.
    static func settingsFrame(in bounds: CGRect, toolbar: Placement) -> CGRect {
        let inner = usable(bounds)
        var area = inner
        if toolbar.vertical {
            if toolbar.dock == .trailing { area.size.width = max(0, toolbar.frame.minX - margin - inner.minX) }
            else {
                area.origin.x = min(inner.maxX, toolbar.frame.maxX + margin)
                area.size.width = max(0, inner.maxX - area.minX)
            }
        } else {
            let below = max(0, inner.maxY - toolbar.frame.maxY - margin)
            let above = max(0, toolbar.frame.minY - margin - inner.minY)
            if below >= 132 || below >= above {
                area.origin.y = min(inner.maxY, toolbar.frame.maxY + margin)
                area.size.height = below
            } else { area.size.height = above }
        }
        let width = min(260, area.width), height = min(492, area.height)
        return CGRect(x: area.midX - width / 2, y: area.minY, width: width, height: height)
    }

    /// Preserve the original clear canvas beneath the default top rail and
    /// beside a snapped rail. Explicitly floating in the middle may cover artwork.
    static func canvasFrame(in bounds: CGRect, toolbar: Placement) -> CGRect {
        var area = bounds
        if toolbar.vertical {
            if toolbar.dock == .trailing { area.size.width = max(0, toolbar.frame.minX - margin - bounds.minX) }
            else {
                area.origin.x = min(bounds.maxX, toolbar.frame.maxX + margin)
                area.size.width = max(0, bounds.maxX - area.minX)
            }
        } else if toolbar.frame.minY <= bounds.minY + margin + 1 {
            area.origin.y = min(bounds.maxY, toolbar.frame.maxY + margin)
            area.size.height = max(0, bounds.maxY - area.minY)
        }
        return area
    }

    private mutating func remember(_ point: CGPoint, in bounds: CGRect) {
        let inner = Self.usable(bounds)
        normalizedCenter = CGPoint(x: min(1, max(0, (point.x - inner.minX) / max(1, inner.width))),
                                   y: min(1, max(0, (point.y - inner.minY) / max(1, inner.height))))
    }
    private static func valid(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite && rect.width >= 0 && rect.height >= 0
    }
    private static func usable(_ bounds: CGRect) -> CGRect {
        guard valid(bounds) else { return .zero }
        let insetX = min(margin, bounds.width / 2), insetY = min(margin, bounds.height / 2)
        return bounds.insetBy(dx: insetX, dy: insetY)
    }
    private static func isFinite(_ point: CGPoint) -> Bool { point.x.isFinite && point.y.isFinite }
    private static func clamped(_ point: CGPoint, size: CGSize, to bounds: CGRect) -> CGPoint {
        CGPoint(x: min(bounds.maxX - size.width / 2, max(bounds.minX + size.width / 2, point.x)),
                y: min(bounds.maxY - size.height / 2, max(bounds.minY + size.height / 2, point.y)))
    }
}
