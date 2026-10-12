package com.stickdeath.studio

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin

// Audio primitives mirroring the native StudioCraftAudio.swift port of the
// ArtCraft SoundCraft engine (github.com/storytold/soundcraft, MIT OR Apache-2.0).
// Pure Kotlin with no Android imports so the mixing math runs in plain JVM tests.

/** SoundCraft clip fade curves. [gain] is the fade-in curve for t in 0..1; a fade-out
 * evaluates the same curve with the time remaining in the fade. [swiftName] is the
 * iOS `StudioFadeShape` raw value and the value persisted by the Android v25 envelope. */
enum class FadeShape(val label: String, val swiftName: String) {
    Linear("Linear", "linear"),
    EqualPower("Equal Power", "equalPower"),
    SCurve("S-Curve", "sCurve"),
    Exponential("Exponential", "exponential"),
    Logarithmic("Logarithmic", "logarithmic");

    fun gain(t: Double): Double {
        val clamped = if (t.isFinite()) t.coerceIn(0.0, 1.0) else 0.0
        return when (this) {
            Linear -> clamped
            EqualPower -> sin(clamped * PI / 2)
            SCurve -> 0.5 - 0.5 * cos(clamped * PI)
            Exponential -> clamped * clamped * clamped
            Logarithmic -> { val w = 1.0 - clamped; 1.0 - w * w * w }
        }
    }

    companion object {
        /** Case-insensitive iOS raw-value lookup; unknown strings stay unrecognised (null). */
        fun fromSwift(stored: String): FadeShape? = entries.firstOrNull { it.swiftName.equals(stored, ignoreCase = true) }
        /** Accepts the iOS raw value or an Android enum name; rejects anything else honestly. */
        fun fromStored(stored: String): FadeShape = fromSwift(stored) ?: entries.firstOrNull { it.name == stored }
            ?: throw IllegalArgumentException("Unsupported audio fade shape \"$stored\"; original preserved.")
    }
}

object StudioCraftAudio {
    data class Balance(val left: Double, val right: Double)

    /** SoundCraft `PanLaw::Zero` balance law: a centred track is bit-identical to the
     * historical unpanned mix because both gains are exactly 1.0. */
    fun balanceGains(pan: Double): Balance {
        val clamped = if (pan.isFinite()) pan.coerceIn(-1.0, 1.0) else 0.0
        return Balance(minOf(1.0, 1.0 - clamped), minOf(1.0, 1.0 + clamped))
    }

    /** SoundCraft mute/solo rule: a track is silenced by its own mute, or by any other
     * track being soloed while it is not. Per-clip mute is applied separately. */
    fun isTrackAudible(track: Int, muted: Set<Int>, soloed: Set<Int>): Boolean =
        track !in muted && (soloed.isEmpty() || track in soloed)

    /** Same rule over the project's four numbered track settings (track is 1-based). */
    fun isTrackAudible(track: Int, tracks: List<AudioTrackMix>): Boolean {
        val mix = tracks.getOrNull(track - 1) ?: return false
        return !mix.muted && (tracks.none { it.soloed } || mix.soloed)
    }

    /** Short readable pan label: "C", "L35", "R100". */
    fun panLabel(pan: Double): String {
        val percent = ((if (pan.isFinite()) pan.coerceIn(-1.0, 1.0) else 0.0) * 100).roundToInt()
        if (percent == 0) return "C"
        return if (percent < 0) "L${-percent}" else "R$percent"
    }
}
