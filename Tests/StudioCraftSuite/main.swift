import Foundation

// Foundation-only checks of the ArtCraft ports (SoundCraft fade/pan/solo math,
// PhotoCraft layer catalogue and blend reference). Runs on Linux and macOS.
@main
struct StudioCraftSuiteTests {
    static var failures = 0
    static func check(_ condition: Bool, _ message: String) {
        if !condition { failures += 1; print("FAIL: \(message)") }
    }
    static func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool { abs(a - b) <= tolerance }

    static func main() {
        fadeShapes(); panning(); soloRules(); blendModes(); labels(); palette()
        if failures > 0 { print("STUDIO_CRAFT_SUITE=FAIL (\(failures))"); exit(1) }
        print("STUDIO_CRAFT_SUITE=PASS")
    }

    static func fadeShapes() {
        for shape in StudioFadeShape.allCases {
            check(near(shape.gain(0), 0), "\(shape) starts silent")
            check(near(shape.gain(1), 1), "\(shape) ends at unity")
            var previous = -1.0
            for step in 0...100 {
                let value = shape.gain(Double(step) / 100)
                check(value >= previous - 1e-12, "\(shape) is monotonic at \(step)")
                previous = value
            }
            check(shape.gain(.nan) == 0 && near(shape.gain(4), 1) && shape.gain(-1) == 0, "\(shape) clamps input")
        }
        // SoundCraft crates/model/src/clip.rs values at the midpoint.
        check(near(StudioFadeShape.linear.gain(0.5), 0.5), "linear midpoint")
        check(near(StudioFadeShape.equalPower.gain(0.5), sin(Double.pi / 4)), "equal-power midpoint")
        check(near(StudioFadeShape.sCurve.gain(0.5), 0.5), "s-curve midpoint")
        check(near(StudioFadeShape.exponential.gain(0.5), 0.125), "exponential midpoint")
        check(near(StudioFadeShape.logarithmic.gain(0.5), 0.875), "logarithmic midpoint")
        // Equal-power crossfade keeps constant power: in² + out² = 1.
        for step in 0...20 {
            let t = Double(step) / 20
            let a = StudioFadeShape.equalPower.gain(t), b = StudioFadeShape.equalPower.gain(1 - t)
            check(near(a * a + b * b, 1, 1e-12), "equal-power constant power at \(t)")
        }
        check(Set(StudioFadeShape.allCases.map(\.rawValue)) == ["linear", "equalPower", "sCurve", "exponential", "logarithmic"], "stable raw values")
    }

    static func panning() {
        let centre = StudioCraftAudio.balanceGains(pan: 0)
        check(centre.left == 1 && centre.right == 1, "centred balance is bit-exact unity (historical mixes unchanged)")
        let left = StudioCraftAudio.balanceGains(pan: -1), right = StudioCraftAudio.balanceGains(pan: 1)
        check(left == (1, 0) && right == (0, 1), "hard balance")
        let half = StudioCraftAudio.balanceGains(pan: 0.5)
        check(near(half.left, 0.5) && half.right == 1, "balance halfway right")
        check(StudioCraftAudio.balanceGains(pan: .nan) == (1, 1) && StudioCraftAudio.balanceGains(pan: 7) == (0, 1), "balance clamps")
        check(StudioCraftAudio.panLabel(0) == "C" && StudioCraftAudio.panLabel(-0.35) == "L35" && StudioCraftAudio.panLabel(1) == "R100", "pan labels")
    }

    static func soloRules() {
        check(StudioCraftAudio.isTrackAudible(1, muted: [], soloed: []), "default audible")
        check(!StudioCraftAudio.isTrackAudible(1, muted: [1], soloed: []), "mute silences")
        check(!StudioCraftAudio.isTrackAudible(2, muted: [], soloed: [1]), "other solo silences")
        check(StudioCraftAudio.isTrackAudible(1, muted: [], soloed: [1, 3]), "soloed audible")
        check(!StudioCraftAudio.isTrackAudible(1, muted: [1], soloed: [1]), "mute wins over solo")
    }

    static func blendModes() {
        let modes = StudioLayerBlendMode.allCases
        check(modes.count == 18, "18 native PhotoCraft modes")
        check(modes.map(\.title) == ["Normal", "Darken", "Multiply", "Color Burn", "Linear Burn", "Lighten", "Screen",
            "Color Dodge", "Linear Dodge (Add)", "Overlay", "Soft Light", "Hard Light", "Difference", "Exclusion",
            "Hue", "Saturation", "Color", "Luminosity"], "PhotoCraft menu order")
        check(modes.map(\.group) == modes.map(\.group).sorted(), "groups are contiguous")
        check(Set(modes.filter { !$0.isExtended }.map(\.rawValue)) == ["normal", "multiply", "screen", "overlay", "darken", "lighten"], "historical raw values unchanged")
        check(StudioLayerBlendMode(stored: "Multiply") == .multiply && StudioLayerBlendMode(stored: "COLOR-BURN") == .colorBurn, "case-insensitive lookup")
        check(StudioLayerBlendMode(stored: "etc.") == nil && StudioLayerBlendMode.title(forStored: "etc.") == "Normal", "unknown legacy strings stay Normal")
        check(modes.allSatisfy { $0.rawValue == $0.rawValue.lowercased() }, "raw values are lowercase for case-insensitive export checks")
        // PhotoCraft crates/color/src/blend.rs reference values.
        let grid = stride(from: 0.0, through: 1.0, by: 0.125).map { $0 }
        for cb in grid { for cs in grid {
            check(StudioLayerBlendMode.normal.separable(backdrop: cb, source: cs) == cs, "normal")
            check(near(StudioLayerBlendMode.screen.separable(backdrop: cb, source: cs)!, 1 - (1 - cb) * (1 - cs)), "screen")
            check(StudioLayerBlendMode.linearBurn.separable(backdrop: cb, source: cs) == max(0, cb + cs - 1), "linear burn")
            check(StudioLayerBlendMode.linearDodge.separable(backdrop: cb, source: cs) == min(1, cb + cs), "linear dodge")
            check(near(StudioLayerBlendMode.overlay.separable(backdrop: cb, source: cs)!,
                       StudioLayerBlendMode.hardLight.separable(backdrop: cs, source: cb)!), "overlay is commuted hard light")
            check(near(StudioLayerBlendMode.exclusion.separable(backdrop: cb, source: cs)!, StudioLayerBlendMode.exclusion.separable(backdrop: cs, source: cb)!), "exclusion commutes")
            for mode in modes where mode.group != 5 {
                let value = mode.separable(backdrop: cb, source: cs)!
                check(value.isFinite && (-1e-12...1 + 1e-12).contains(value), "\(mode) stays in range")
            }
        } }
        check(StudioLayerBlendMode.colorBurn.separable(backdrop: 1, source: 0) == 1 && StudioLayerBlendMode.colorBurn.separable(backdrop: 0.5, source: 0) == 0, "color burn edges")
        check(StudioLayerBlendMode.colorDodge.separable(backdrop: 0, source: 1) == 0 && StudioLayerBlendMode.colorDodge.separable(backdrop: 0.5, source: 1) == 1, "color dodge edges")
        check(near(StudioLayerBlendMode.softLight.separable(backdrop: 0.25, source: 0.75)!, 0.34375), "Pegtop soft light: -0.5 * 0.0625 + 1.5 * 0.25")
        // Measured native pixel: backdrop #804020 under source #4080C0 decodes to [96, 64, 46].
        check(zip([128.0, 64, 32], [64.0, 128, 192]).map { Int((StudioLayerBlendMode.softLight.separable(backdrop: $0 / 255, source: $1 / 255)! * 255).rounded()) } == [96, 64, 46], "soft light matches the measured native pixel")
        check(StudioLayerBlendMode.hue.separable(backdrop: 0.5, source: 0.5) == nil, "hue is non-separable")
    }

    static func palette() {
        check(StudioCraftAudio.trackColor(1) == "#5684D6" && StudioCraftAudio.trackColor(4) == "#68BA62" && StudioCraftAudio.trackColor(17) == "#5684D6", "SoundCraft track palette")
    }

    static func labels() {
        check(StudioLayerLabelColor.allCases.map(\.title) == ["Red", "Orange", "Yellow", "Green", "Seafoam", "Blue", "Indigo", "Magenta", "Fuchsia", "Violet", "Gray"], "PhotoCraft label order")
        check(StudioLayerLabelColor(hex: "#fc5d5b") == .red && StudioLayerLabelColor(hex: "#FF0000") == nil && StudioLayerLabelColor(hex: nil) == nil, "label lookup")
        check(Set(StudioLayerLabelColor.allCases.map(\.hex)).count == 11, "unique label swatches")
    }
}
