// WatermarkService.swift
// Renders "StickDeath Infinity" watermark on exported videos
// Pro users can opt out; free users always have it

import SwiftUI
import AVFoundation
import CoreImage

class WatermarkService {
    static let shared = WatermarkService()

    /// Watermark position options
    enum Position: String, CaseIterable, Identifiable {
        case bottomRight = "Bottom Right"
        case bottomLeft = "Bottom Left"
        case topRight = "Top Right"
        case topLeft = "Top Left"
        case bottomCenter = "Bottom Center"

        var id: String { rawValue }
    }

    struct WatermarkConfig {
        var enabled: Bool = true
        var text: String = "StickDeath ∞"
        var position: Position = .bottomRight
        var opacity: Double = 0.6
        var fontSize: CGFloat = 14
        var showOnExport: Bool = true          // Always true for free users
        var includeAppStoreBadge: Bool = true   // "Made with StickDeath Infinity"
    }

    /// Render watermark overlay onto a UIImage frame
    func applyWatermark(to image: UIImage, config: WatermarkConfig, canvasSize: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: canvasSize)

        return renderer.image { context in
            // Draw original frame
            image.draw(in: CGRect(origin: .zero, size: canvasSize))

            // Watermark text
            let watermarkText = config.includeAppStoreBadge
                ? "Made with \(config.text)"
                : config.text

            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: config.fontSize, weight: .bold),
                .foregroundColor: UIColor.white.withAlphaComponent(config.opacity),
                .strokeColor: UIColor.black.withAlphaComponent(config.opacity * 0.5),
                .strokeWidth: -1.0
            ]

            let textSize = (watermarkText as NSString).size(withAttributes: attributes)
            let padding: CGFloat = 12

            var origin: CGPoint
            switch config.position {
            case .bottomRight:
                origin = CGPoint(x: canvasSize.width - textSize.width - padding,
                                 y: canvasSize.height - textSize.height - padding)
            case .bottomLeft:
                origin = CGPoint(x: padding,
                                 y: canvasSize.height - textSize.height - padding)
            case .topRight:
                origin = CGPoint(x: canvasSize.width - textSize.width - padding,
                                 y: padding)
            case .topLeft:
                origin = CGPoint(x: padding, y: padding)
            case .bottomCenter:
                origin = CGPoint(x: (canvasSize.width - textSize.width) / 2,
                                 y: canvasSize.height - textSize.height - padding)
            }

            // Draw subtle background pill behind text
            let pillRect = CGRect(
                x: origin.x - 6,
                y: origin.y - 3,
                width: textSize.width + 12,
                height: textSize.height + 6
            )
            let pillPath = UIBezierPath(roundedRect: pillRect, cornerRadius: 4)
            UIColor.black.withAlphaComponent(config.opacity * 0.35).setFill()
            pillPath.fill()

            // Draw watermark text
            (watermarkText as NSString).draw(at: origin, withAttributes: attributes)

            // Optional: tiny stick figure icon next to text
            drawMiniStickFigure(at: CGPoint(x: origin.x - 18, y: origin.y + 2),
                                size: textSize.height - 4,
                                opacity: config.opacity,
                                in: context.cgContext)
        }
    }

    /// Draw a tiny stick figure icon
    private func drawMiniStickFigure(at origin: CGPoint, size: CGFloat, opacity: Double, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(opacity).cgColor)
        ctx.setLineWidth(1.2)
        ctx.setLineCap(.round)

        let cx = origin.x + size / 2
        let top = origin.y

        // Head
        let headR = size * 0.18
        ctx.strokeEllipseIn(CGRect(x: cx - headR, y: top, width: headR * 2, height: headR * 2))

        // Body
        let neckY = top + headR * 2
        let hipY = neckY + size * 0.4
        ctx.move(to: CGPoint(x: cx, y: neckY))
        ctx.addLine(to: CGPoint(x: cx, y: hipY))
        ctx.strokePath()

        // Arms
        let armY = neckY + size * 0.1
        ctx.move(to: CGPoint(x: cx - size * 0.25, y: armY + size * 0.15))
        ctx.addLine(to: CGPoint(x: cx, y: armY))
        ctx.addLine(to: CGPoint(x: cx + size * 0.25, y: armY + size * 0.15))
        ctx.strokePath()

        // Legs
        ctx.move(to: CGPoint(x: cx - size * 0.2, y: hipY + size * 0.3))
        ctx.addLine(to: CGPoint(x: cx, y: hipY))
        ctx.addLine(to: CGPoint(x: cx + size * 0.2, y: hipY + size * 0.3))
        ctx.strokePath()

        ctx.restoreGState()
    }

    /// Generate watermark config based on user's Pro status
    func configForUser(isPro: Bool, userWantsWatermark: Bool = false) -> WatermarkConfig {
        var config = WatermarkConfig()
        if isPro && !userWantsWatermark {
            config.enabled = false
            config.showOnExport = false
        }
        return config
    }
}
