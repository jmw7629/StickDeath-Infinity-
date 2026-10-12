import Foundation

// Audio primitives ported from the ArtCraft SoundCraft engine
// (github.com/storytold/soundcraft, MIT OR Apache-2.0; see
// Resources/Licenses/ArtCraft-NOTICE.txt). Formulas follow
// crates/model/src/clip.rs, crates/dsp/src/pan.rs and crates/mix/src/lib.rs. Foundation-only so mixing math is testable anywhere.

/// SoundCraft clip fade curves. `gain(_:)` is the fade-in curve for t in 0...1;
/// a fade-out evaluates the same curve with the time remaining in the fade.
enum StudioFadeShape: String, Codable, CaseIterable, Sendable {
    case linear, equalPower, sCurve, exponential, logarithmic

    var title: String {
        switch self {
        case .linear: return "Linear"
        case .equalPower: return "Equal Power"
        case .sCurve: return "S-Curve"
        case .exponential: return "Exponential"
        case .logarithmic: return "Logarithmic"
        }
    }

    func gain(_ t: Double) -> Double {
        let t = t.isFinite ? min(1, max(0, t)) : 0
        switch self {
        case .linear: return t
        case .equalPower: return sin(t * .pi / 2)
        case .sCurve: return 0.5 - 0.5 * cos(t * .pi)
        case .exponential: return t * t * t
        case .logarithmic: let w = 1 - t; return 1 - w * w * w
        }
    }
}

enum StudioCraftAudio {
    /// Stereo sources use SoundCraft's `PanLaw::Zero` balance law so a centred
    /// track is bit-identical to the historical unpanned mix.
    static func balanceGains(pan: Double) -> (left: Double, right: Double) {
        let pan = pan.isFinite ? min(1, max(-1, pan)) : 0
        return (min(1, 1 - pan), min(1, 1 + pan))
    }

    /// SoundCraft mute/solo rule: a track is silenced by its own mute, or by any
    /// other track being soloed while it is not.
    static func isTrackAudible(_ track: Int, muted: Set<Int>, soloed: Set<Int>) -> Bool {
        if muted.contains(track) { return false }
        return soloed.isEmpty || soloed.contains(track)
    }

    /// Short readable pan label: "C", "L35", "R100".
    static func panLabel(_ pan: Double) -> String {
        let percent = Int((min(1, max(-1, pan.isFinite ? pan : 0)) * 100).rounded())
        if percent == 0 { return "C" }
        return percent < 0 ? "L\(-percent)" : "R\(percent)"
    }

    /// SoundCraft track colour palette (crates/model/src/track.rs TRACK_COLORS).
    static let trackColors = ["#5684D6", "#5EAAD6", "#50BEA8", "#68BA62", "#A8C44C", "#DEC448", "#E6983E", "#DE6848",
                              "#D6526E", "#C456A8", "#9662CE", "#6E68D6", "#8296AA", "#B28C6E", "#78AA8C", "#BE7896"]
    static func trackColor(_ track: Int) -> String { trackColors[(max(1, track) - 1) % trackColors.count] }
}
