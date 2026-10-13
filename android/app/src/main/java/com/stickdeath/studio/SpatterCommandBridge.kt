package com.stickdeath.studio

/** A deliberately limited local instruction grammar: the same complete sentences the iOS
 * `SpatterMotionRecipe.swift` instruction structs accept, parsed into typed Android document
 * commands. It is not an AI provider, chat responder or network client; nothing here contacts a
 * server, and a failed parse changes nothing. Imported text never executes: only the text the
 * creator types into the Spatter field reaches [parse]. */
sealed class SpatterCommand {
    data class SelectFrame(val number: Int) : SpatterCommand()
    data class SelectLayer(val number: Int) : SpatterCommand()
    data class AddLayer(val name: String) : SpatterCommand()
    object DeleteActiveLayer : SpatterCommand()
    object DuplicateActiveLayer : SpatterCommand()
    data class UpdateActiveLayer(val name: String? = null, val opacity: Float? = null, val visible: Boolean? = null,
                                 val blend: LayerBlend? = null, val lock: LayerLockMode? = null) : SpatterCommand()
    data class MoveActiveLayer(val up: Boolean) : SpatterCommand()
    data class AudioTrack(val track: Int, val volume: Float? = null, val muted: Boolean? = null,
                          val pan: Float? = null, val soloed: Boolean? = null) : SpatterCommand()
    data class FrameExposure(val ticks: Int, val first: Int? = null, val last: Int? = null) : SpatterCommand()
    data class DuplicateFrames(val first: Int, val last: Int) : SpatterCommand()
    data class ReverseFrames(val first: Int, val last: Int) : SpatterCommand()
    data class RenameProject(val name: String) : SpatterCommand()
    data class OnionSkin(val visible: Boolean? = null, val settings: OnionSettings? = null) : SpatterCommand()
    data class Grid(val visible: Boolean? = null, val settings: GridSettings? = null) : SpatterCommand()
}

class SpatterCommandException(message: String) : IllegalArgumentException(message)

object SpatterCommandBridge {
    const val MAXIMUM_INSTRUCTION_BYTES = 1024

    /** The example sentences shown in the Spatter panel, verbatim from the iOS instruction structs. */
    val examples: List<String> = listOf(
        "Select frame 1.", "Select layer 1.",
        "Add layer named \"Foreground\".", "Delete active layer.", "Duplicate active layer.",
        "Rename active layer to \"Foreground\".", "Hide active layer.", "Show active layer.",
        "Set active layer opacity to 50%.", "Set active layer blend to multiply.", "Set active layer lock to position.",
        "Move active layer up.", "Move active layer down.",
        "Set audio track 1 volume to 40%.", "Mute audio track 1.", "Unmute audio track 1.",
        "Pan audio track 2 to L40.", "Pan audio track 2 to center.", "Solo audio track 3.", "Unsolo audio track 3.",
        "Set selected frame exposure to 12 ticks.", "Set frames 1 through 12 exposure to 2 ticks.",
        "Duplicate frames 1 through 12.", "Reverse frames 1 through 12.",
        "Rename project to \"Sunset\".",
        "Show onion skin.", "Hide onion skin.", "Set onion skin to 2 previous frames, 1 next frame, 35% opacity, tinted.",
        "Show grid.", "Hide grid.", "Set grid to 32 canvas points spacing, 25% opacity, red tint.")

    private val ci = setOf(RegexOption.IGNORE_CASE)
    private fun rx(pattern: String) = Regex("\\A\\s*$pattern\\s*\\z", ci)
    private val select = rx("""select\s+(frame|layer)\s+([1-9][0-9]{0,3})\.""")
    private val deleteLayer = rx("""delete\s+active\s+layer\.""")
    private val duplicateLayer = rx("""duplicate\s+active\s+layer\.""")
    private val addLayer = rx("""add\s+layer\s+named\s+"([^"\r\n]+)"\.""")
    private val lock = rx("""set\s+active\s+layer\s+lock\s+to\s+(free|full|position|alpha)\.""")
    private val blend = rx("""set\s+active\s+layer\s+blend\s+to\s+(normal|darken|multiply|color-burn|linear-burn|lighten|screen|color-dodge|linear-dodge|overlay|soft-light|hard-light|difference|exclusion|hue|saturation|color|luminosity)\.""")
    private val visibility = rx("""(hide|show)\s+active\s+layer\.""")
    private val renameLayer = rx("""rename\s+active\s+layer\s+to\s+"([^"\r\n]+)"\.""")
    private val opacity = rx("""set\s+active\s+layer\s+opacity\s+to\s+((?:0|[1-9][0-9]*)(?:\.[0-9]+)?)%\.""")
    private val moveLayer = rx("""move\s+active\s+layer\s+(up|down)\.""")
    private val trackVolume = rx("""set\s+audio\s+track\s+([1-4])\s+volume\s+to\s+([0-9]{1,3}(?:\.[0-9]{1,6})?)\s*%\.?""")
    private val trackMute = rx("""(mute|unmute)\s+audio\s+track\s+([1-4])\.?""")
    private val trackPan = rx("""pan\s+audio\s+track\s+([1-4])\s+to\s+(center|centre|[LR](?:100|[1-9]?[0-9]))\.?""")
    private val trackSolo = rx("""(solo|unsolo)\s+audio\s+track\s+([1-4])\.?""")
    private val exposureRange = rx("""set\s+frames\s+([1-9][0-9]{0,3})\s+through\s+([1-9][0-9]{0,3})\s+exposure\s+to\s+([1-9][0-9]{0,2})\s+ticks\.""")
    private val exposure = rx("""set\s+selected\s+frame\s+exposure\s+to\s+([1-9][0-9]{0,2})\s+ticks\.""")
    private val duplicateFrames = rx("""duplicate\s+frames\s+([1-9][0-9]{0,3})\s+through\s+([1-9][0-9]{0,3})\.""")
    private val reverseFrames = rx("""reverse\s+frames\s+([1-9][0-9]{0,3})\s+through\s+([1-9][0-9]{0,3})\.""")
    private val renameProject = rx("""rename\s+project\s+to\s+"([^"\r\n]*)"\.?""")
    private val onionVisibility = rx("""(show|hide)\s+onion\s+skin\.""")
    private val onionSettings = rx("""set\s+onion\s+skin\s+to\s+([0-2])\s+previous\s+frames?,\s+([0-2])\s+next\s+frames?,\s+([5-9]|[1-7][0-9]|80)%\s+opacity,\s+(tinted|untinted)\.""")
    private val gridVisibility = rx("""(show|hide)\s+grid\.""")
    private val gridSettings = rx("""set\s+grid\s+to\s+([8-9]|[1-9][0-9]|1[0-5][0-9]|160)\s+canvas\s+points\s+spacing,\s+([5-9]|[1-5][0-9]|60)%\s+opacity,\s+(blue|gray|red)\s+tint\.""")

    /** Grid tint colours offered by the iOS instruction, mapped to the Android grid palette. */
    val gridTints = mapOf("blue" to 0xff3399ff.toInt(), "gray" to 0xff777777.toInt(), "red" to 0xffe52b38.toInt())

    private fun fail(message: String): Nothing = throw SpatterCommandException("$message Nothing changed.")
    private fun validName(name: String, what: String): String {
        val trimmed = name.trim()
        if (trimmed.isEmpty() || trimmed.length > 80 || trimmed.any { it.isISOControl() }) fail("Use a $what of 1–80 characters.")
        return trimmed
    }

    fun parse(text: String): SpatterCommand {
        if (text.toByteArray(Charsets.UTF_8).size > MAXIMUM_INSTRUCTION_BYTES) fail("The instruction exceeds 1 KiB.")
        if (text.isBlank()) fail("Type one complete Spatter instruction.")
        if (text.any { it.isISOControl() && it != '\n' && it != '\r' && it != '\t' }) fail("The instruction contains unsupported control characters.")
        select.matchEntire(text)?.let { m ->
            val number = m.groupValues[2].toInt()
            return if (m.groupValues[1].lowercase() == "frame") SpatterCommand.SelectFrame(number) else SpatterCommand.SelectLayer(number)
        }
        if (deleteLayer.matches(text)) return SpatterCommand.DeleteActiveLayer
        if (duplicateLayer.matches(text)) return SpatterCommand.DuplicateActiveLayer
        addLayer.matchEntire(text)?.let { return SpatterCommand.AddLayer(validName(it.groupValues[1], "layer name")) }
        lock.matchEntire(text)?.let { return SpatterCommand.UpdateActiveLayer(lock = LayerLockMode.fromSwift(it.groupValues[1]) ?: fail("Unsupported lock mode.")) }
        blend.matchEntire(text)?.let { return SpatterCommand.UpdateActiveLayer(blend = LayerBlend.fromSwift(it.groupValues[1]) ?: fail("Unsupported blend mode.")) }
        visibility.matchEntire(text)?.let { return SpatterCommand.UpdateActiveLayer(visible = it.groupValues[1].lowercase() == "show") }
        renameLayer.matchEntire(text)?.let { return SpatterCommand.UpdateActiveLayer(name = validName(it.groupValues[1], "layer name")) }
        opacity.matchEntire(text)?.let {
            val percent = it.groupValues[1].toDoubleOrNull() ?: fail("Use an opacity of 0–100%.")
            if (!percent.isFinite() || percent !in 0.0..100.0) fail("Use an opacity of 0–100%.")
            return SpatterCommand.UpdateActiveLayer(opacity = (percent / 100).toFloat())
        }
        moveLayer.matchEntire(text)?.let { return SpatterCommand.MoveActiveLayer(up = it.groupValues[1].lowercase() == "up") }
        trackVolume.matchEntire(text)?.let {
            val percent = it.groupValues[2].toDoubleOrNull() ?: fail("Use a volume of 0–100%.")
            if (!percent.isFinite() || percent !in 0.0..100.0) fail("Use a volume of 0–100%.")
            return SpatterCommand.AudioTrack(it.groupValues[1].toInt(), volume = (percent / 100).toFloat())
        }
        trackMute.matchEntire(text)?.let { return SpatterCommand.AudioTrack(it.groupValues[2].toInt(), muted = it.groupValues[1].lowercase() == "mute") }
        trackPan.matchEntire(text)?.let {
            val position = it.groupValues[2].lowercase()
            val pan = if (position.startsWith("cent")) 0f else {
                val magnitude = position.drop(1).toDouble() / 100
                (if (position.startsWith("l")) -magnitude else magnitude).toFloat()
            }
            return SpatterCommand.AudioTrack(it.groupValues[1].toInt(), pan = pan)
        }
        trackSolo.matchEntire(text)?.let { return SpatterCommand.AudioTrack(it.groupValues[2].toInt(), soloed = it.groupValues[1].lowercase() == "solo") }
        exposureRange.matchEntire(text)?.let {
            val first = it.groupValues[1].toInt(); val last = it.groupValues[2].toInt(); val ticks = it.groupValues[3].toInt()
            if (first > last || last > 1000 || last - first >= 96 || ticks !in 1..600) fail("Use 1–600 ticks and at most 96 existing frames.")
            return SpatterCommand.FrameExposure(ticks, first, last)
        }
        exposure.matchEntire(text)?.let {
            val ticks = it.groupValues[1].toInt()
            if (ticks !in 1..600) fail("Use 1–600 ticks.")
            return SpatterCommand.FrameExposure(ticks)
        }
        duplicateFrames.matchEntire(text)?.let {
            val first = it.groupValues[1].toInt(); val last = it.groupValues[2].toInt()
            if (first > last || last - first >= 96) fail("Choose 1–96 existing consecutive frames.")
            return SpatterCommand.DuplicateFrames(first, last)
        }
        reverseFrames.matchEntire(text)?.let {
            val first = it.groupValues[1].toInt(); val last = it.groupValues[2].toInt()
            if (first >= last || last - first >= 96) fail("Choose 2–96 existing consecutive frames.")
            return SpatterCommand.ReverseFrames(first, last)
        }
        renameProject.matchEntire(text)?.let {
            val name = it.groupValues[1].trim()
            if (name.isEmpty() || name.length > 120 || name.any { c -> c.isISOControl() }) fail("Use a project name of 1–120 characters without control characters.")
            return SpatterCommand.RenameProject(name)
        }
        onionVisibility.matchEntire(text)?.let { return SpatterCommand.OnionSkin(visible = it.groupValues[1].lowercase() == "show") }
        onionSettings.matchEntire(text)?.let {
            return SpatterCommand.OnionSkin(settings = OnionSettings(enabled = true, previous = it.groupValues[1].toInt(), next = it.groupValues[2].toInt(),
                opacity = it.groupValues[3].toInt() / 100f, tinted = it.groupValues[4].lowercase() == "tinted"))
        }
        gridVisibility.matchEntire(text)?.let { return SpatterCommand.Grid(visible = it.groupValues[1].lowercase() == "show") }
        gridSettings.matchEntire(text)?.let {
            return SpatterCommand.Grid(settings = GridSettings(enabled = true, spacing = it.groupValues[1].toInt(),
                opacity = it.groupValues[2].toInt() / 100f, color = gridTints.getValue(it.groupValues[3].lowercase())))
        }
        fail("Use one complete instruction from the examples; partial sentences, extra clauses and other actions are unavailable.")
    }

    /** Short, honest description of what a parsed command will do, for the panel preview. */
    fun describe(command: SpatterCommand): String = when (command) {
        is SpatterCommand.SelectFrame -> "Select frame ${command.number}."
        is SpatterCommand.SelectLayer -> "Select layer ${command.number} (top = 1)."
        is SpatterCommand.AddLayer -> "Add a layer named \"${command.name}\" above the stack."
        SpatterCommand.DeleteActiveLayer -> "Delete the active layer and its artwork in every frame."
        SpatterCommand.DuplicateActiveLayer -> "Duplicate the active layer through every frame."
        is SpatterCommand.UpdateActiveLayer -> buildString {
            command.name?.let { append("Rename the active layer to \"$it\". ") }
            command.opacity?.let { append("Set its opacity to ${it.percentLabel()}. ") }
            command.visible?.let { append(if (it) "Show it. " else "Hide it. ") }
            command.blend?.let { append("Blend: ${it.label}. ") }
            command.lock?.let { append("Lock: ${it.label}. ") }
        }.trim()
        is SpatterCommand.MoveActiveLayer -> if (command.up) "Move the active layer up." else "Move the active layer down."
        is SpatterCommand.AudioTrack -> buildString {
            append("Audio track ${command.track}: ")
            command.volume?.let { append("volume ${it.percentLabel()} ") }
            command.muted?.let { append(if (it) "mute " else "unmute ") }
            command.pan?.let { append("pan ${StudioCraftAudio.panLabel(it.toDouble())} ") }
            command.soloed?.let { append(if (it) "solo " else "unsolo ") }
        }.trim()
        is SpatterCommand.FrameExposure -> if (command.first == null) "Set the selected frame to ${command.ticks} ticks."
            else "Set frames ${command.first} through ${command.last} to ${command.ticks} ticks each."
        is SpatterCommand.DuplicateFrames -> "Duplicate frames ${command.first} through ${command.last} after the range."
        is SpatterCommand.ReverseFrames -> "Reverse frames ${command.first} through ${command.last}."
        is SpatterCommand.RenameProject -> "Rename the project to \"${command.name}\"."
        is SpatterCommand.OnionSkin -> command.visible?.let { if (it) "Show onion skin." else "Hide onion skin." }
            ?: "Configure onion skin (${command.settings?.previous} previous, ${command.settings?.next} next, ${command.settings?.opacity?.percentLabel()}); visibility is unchanged."
        is SpatterCommand.Grid -> command.visible?.let { if (it) "Show the grid." else "Hide the grid." }
            ?: "Configure the grid (${command.settings?.spacing} px, ${command.settings?.opacity?.percentLabel()}); visibility is unchanged."
    }
}
