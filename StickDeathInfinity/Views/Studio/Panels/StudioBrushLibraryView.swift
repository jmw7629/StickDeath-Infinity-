import SwiftUI

extension StudioBrushFamily {
    var title: String {
        switch self {
        case .round: return "Round"
        case .stipple: return "Stipple"
        case .grain: return "Grain"
        case .roughPen: return "Rough Pen"
        case .calligraphy: return "Calligraphy"
        case .dipPen: return "Dip Pen"
        case .halftone: return "Halftone"
        case .hatchRight: return "Hatch /"
        case .hatchLeft: return "Hatch \\"
        case .gradient: return "Gradient"
        }
    }
}

/// A contextual library inside the existing floating settings panel. Samples
/// are rendered by the same native brush engine as editable strokes.
struct StudioBrushLibraryView: View {
    @ObservedObject var vm: StudioViewModel
    let didSelect: () -> Void
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
            ForEach(StudioBrushFamily.allCases, id: \.self) { family in
                Button {
                    vm.brushFamily = family
                    didSelect()
                } label: {
                    VStack(spacing: 3) {
                        StudioBrushSwatch(family: family).frame(height: 25)
                        Text(family.title).font(.specialElite(10))
                            .foregroundColor(vm.brushFamily == family ? .red : .white.opacity(0.8))
                    }
                    .frame(maxWidth: .infinity).padding(6)
                    .background(Color.white.opacity(vm.brushFamily == family ? 0.12 : 0.04))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(vm.brushFamily == family ? Color.red : .white.opacity(0.12)))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(family.title + " brush")
                .accessibilityIdentifier("studio.brush-family." + family.rawValue)
            }
        }
    }
}

private struct StudioBrushSwatch: View {
    let family: StudioBrushFamily
    var body: some View {
        let result = Result {
            try StudioBrushRenderer.geometry(points: [StrokePoint(x: 8, y: 18, timestamp: 0),
                StrokePoint(x: 30, y: 8, timestamp: 0.08), StrokePoint(x: 65, y: 18, timestamp: 0.2),
                StrokePoint(x: 90, y: 8, timestamp: 0.24)],
                settings: StudioBrushSettings(family: family, size: 7, smoothing: 2,
                    gradientEndColor: family == .gradient ? StudioBrushColor(red: 1, green: 0, blue: 0) : nil),
                seed: 71, checkCancellation: {})
        }
        Canvas { context, size in
            switch result {
            case .success(let geometry):
                context.scaleBy(x: size.width / 100, y: size.height / 26)
                do { try StudioBrushRenderer.draw(geometry, color: StudioBrushColor(red: 1, green: 1, blue: 1), context: &context) }
                catch { StudioFrameRenderer.drawFailure(error, context: &context, size: size) }
            case .failure(let error): StudioFrameRenderer.drawFailure(error, context: &context, size: size)
            }
        }.accessibilityHidden(true)
    }
}
