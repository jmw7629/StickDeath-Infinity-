package com.stickdeath.studio

import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale

/** Which committed Studio changes another creator's copy can replay, the entity each one targets
 * ("frame:<id>", "layer:<id>", "audio:track-<n>"), and the bounded wire form. A Kotlin port of
 * the iOS `StudioSharedEdit` (StudioCommands.swift). Pure value logic: the room coordinator owns
 * the transport, and a received edit replays only through [decode] and [apply], which refuse
 * anything malformed, unsupported or divergent instead of approximating it.
 *
 * Two kinds travel on the room stream:
 *  - [KIND] (`studio.apply`) uses the iOS typed-command vocabulary exactly (renameProject,
 *    updateLayer, setFrameHold, deleteElements, updateAudioTrack, draw with iOS pen/pencil/line
 *    strokes), so iOS and Android copies replay the same edit.
 *  - [ANDROID_KIND] (`studio.android.apply`) has the same envelope but carries Android-native
 *    stroke records for drawings iOS has no exact descriptor for (Android brushes, shapes, erasers,
 *    text). iOS Studio reports it as an edit it cannot replay; it is never claimed as shared there. */
object StudioSharedEdit {
    const val KIND = "studio.apply"
    const val ANDROID_KIND = "studio.android.apply"
    /** Below the room stream's 65,536-byte payload bound, leaving room for the envelope (as iOS). */
    const val MAXIMUM_PAYLOAD_BYTES = 60_000
    const val MAXIMUM_COMMANDS = 64
    const val MAXIMUM_STROKES = 256

    /** A received edit this copy cannot replay: malformed, unsupported, or written against a copy
     * that has diverged from this one. Nothing changes when it is thrown. */
    class Refused(message: String) : IllegalArgumentException(message)

    sealed class Command {
        data class RenameProject(val name: String) : Command()
        data class UpdateLayer(val layer: String, val name: String? = null, val visible: Boolean? = null, val opacity: Float? = null,
                               val lock: LayerLockMode? = null, val blend: LayerBlend? = null) : Command()
        data class SetFrameHold(val frame: String, val ticks: Int) : Command()
        data class DeleteElements(val frame: String, val ids: List<String>) : Command()
        /** Strokes are complete Android artwork; their [Stroke.layerID] equals [layer]. */
        data class Draw(val frame: String, val layer: String, val strokes: List<Stroke>) : Command()
        /** [track] is 1–4, as in the iOS command. */
        data class UpdateAudioTrack(val track: Int, val volume: Float? = null, val muted: Boolean? = null,
                                    val pan: Float? = null, val soloed: Boolean? = null) : Command()
    }

    sealed class Share {
        /** Only this device's view changed (selection, onion skin, grid). */
        object ViewOnly : Share()
        data class Replay(val commands: List<Command>) : Share()
        data class Unsupported(val reason: String) : Share()
    }

    data class Encoded(val kind: String, val payload: JSONObject)

    // MARK: Publishing

    /** The document effect of one committed change, in replayable form, only when replaying it on
     * [before] reproduces [after] exactly (apart from this device's selection and guides). */
    fun share(before: Document, after: Document): Share {
        if (before.id != after.id) return Share.Unsupported("A different project is open.")
        if (before.width != after.width || before.height != after.height || before.fps != after.fps || before.backgroundColor != after.backgroundColor)
            return Share.Unsupported("Canvas size, frame rate and background changes are not shared with the room yet.")
        if (before.audioClips != after.audioClips) return Share.Unsupported("Audio clip edits are not shared with the room yet; Android stores clips as embedded audio.")
        if (before.frames.map { it.id } != after.frames.map { it.id })
            return Share.Unsupported("Adding, deleting, duplicating or reordering frames is not shared with the room yet.")
        if (before.layers.map { it.id } != after.layers.map { it.id })
            return Share.Unsupported("Adding, deleting, duplicating or reordering layers is not shared with the room yet.")
        val commands = mutableListOf<Command>()
        if (before.name != after.name) commands += Command.RenameProject(after.name)
        before.layers.zip(after.layers).forEach { (old, new) ->
            if (old == new) return@forEach
            if (old.label != new.label) return Share.Unsupported("Layer colour labels are not shared with the room yet.")
            commands += Command.UpdateLayer(new.id, new.name.takeIf { it != old.name }, new.visible.takeIf { it != old.visible },
                new.opacity.takeIf { it != old.opacity }, new.lockMode.takeIf { it != old.lockMode }, new.blend.takeIf { it != old.blend })
        }
        before.frames.zip(after.frames).forEach { (old, new) ->
            if (old == new) return@forEach
            if (old.hold != new.hold) commands += Command.SetFrameHold(new.id, new.hold)
            if (old.strokes == new.strokes) return@forEach
            val remaining = new.strokes.map { it.id }.toSet()
            val removed = old.strokes.filter { it.id !in remaining }.map { it.id }
            val kept = old.strokes.filter { it.id in remaining }
            if (new.strokes.take(kept.size) != kept)
                return Share.Unsupported("Moving, transforming, restyling or reordering existing drawings is not shared with the room yet.")
            val added = new.strokes.drop(kept.size)
            if (added.any { stroke -> old.strokes.any { it.id == stroke.id } })
                return Share.Unsupported("Moving, transforming, restyling or reordering existing drawings is not shared with the room yet.")
            if (added.any { it.tool == Tool.Image || it.tool == Tool.Fill })
                return Share.Unsupported("Imported images and bucket fills are not shared with the room yet.")
            if (removed.isNotEmpty()) commands += Command.DeleteElements(new.id, removed)
            var group = mutableListOf<Stroke>()
            fun flush() { if (group.isNotEmpty()) { commands += Command.Draw(new.id, group.first().layerID, group); group = mutableListOf() } }
            added.forEach { stroke -> if (group.isNotEmpty() && group.first().layerID != stroke.layerID) flush(); group += stroke }
            flush()
        }
        before.audioTracks.zip(after.audioTracks).forEachIndexed { index, (old, new) ->
            if (old == new) return@forEachIndexed
            commands += Command.UpdateAudioTrack(index + 1, new.volume.takeIf { it != old.volume }, new.muted.takeIf { it != old.muted },
                new.pan.takeIf { it != old.pan }, new.soloed.takeIf { it != old.soloed })
        }
        if (commands.isEmpty()) return if (content(before) == content(after)) Share.ViewOnly
            else Share.Unsupported("This change cannot be replayed exactly on another device yet.")
        if (commands.size > MAXIMUM_COMMANDS || commands.sumOf { (it as? Command.Draw)?.strokes?.size ?: 0 } > MAXIMUM_STROKES)
            return Share.Unsupported("This change is larger than one shared edit allows.")
        val replayed = try { apply(before, commands) } catch (e: IllegalArgumentException) { null }
        if (replayed == null || content(replayed) != content(after)) return Share.Unsupported("This change cannot be replayed exactly on another device yet.")
        return Share.Replay(commands)
    }

    /** Document content without this device's view state. */
    fun content(d: Document) = d.copy(activeFrameID = "", activeLayerID = "", revision = 0, modified = 0, onion = OnionSettings(), grid = GridSettings())

    /** One entity when every command edits the same frame, layer or sound; otherwise null, which the
     * server treats as overlapping every other edit. */
    fun target(commands: List<Command>): String? {
        val targets = commands.map { target(it) ?: return null }.toSet()
        return targets.singleOrNull()
    }
    fun target(command: Command): String? {
        fun bounded(prefix: String, id: String) = if (id.isEmpty() || id.length > 160) null else prefix + id
        return when (command) {
            is Command.Draw -> bounded("frame:", command.frame)
            is Command.DeleteElements -> bounded("frame:", command.frame)
            is Command.SetFrameHold -> bounded("frame:", command.frame)
            is Command.UpdateLayer -> bounded("layer:", command.layer)
            is Command.UpdateAudioTrack -> "audio:track-${command.track}"
            is Command.RenameProject -> null
        }
    }

    /** The bounded payload: the iOS kind when every drawing round-trips exactly through the iOS stroke
     * vocabulary, else the Android kind. Null when the edit exceeds the payload bound. */
    fun encode(commands: List<Command>): Encoded? {
        require(commands.isNotEmpty() && commands.size <= MAXIMUM_COMMANDS)
        val portable = commands.all { command -> command !is Command.Draw || command.strokes.all { iosStroke(it)?.let { wire -> runCatching { decodeIosStroke(wire, it.id, it.layerID) }.getOrNull() == it } == true } }
        val array = JSONArray()
        commands.forEach { array.put(wire(it, portable)) }
        val created = commands.filterIsInstance<Command.Draw>().flatMap { draw -> draw.strokes.map { it.id } }
        val payload = JSONObject().put("schemaVersion", 1).put("commands", array.toString())
            .put("createdFrameIDs", JSONArray()).put("createdLayerIDs", JSONArray()).put("createdElementIDs", JSONArray(created))
        target(commands)?.let { payload.put("target", it) }
        if (payload.toString().toByteArray(Charsets.UTF_8).size > MAXIMUM_PAYLOAD_BYTES) return null
        return Encoded(if (portable) KIND else ANDROID_KIND, payload)
    }

    private fun ref(id: String) = JSONObject().put("id", id)
    private fun wire(command: Command, portable: Boolean): JSONObject = when (command) {
        is Command.RenameProject -> JSONObject().put("renameProject", JSONObject().put("name", command.name))
        is Command.UpdateLayer -> JSONObject().put("updateLayer", JSONObject().put("layer", ref(command.layer)).put("settings", JSONObject().apply {
            command.name?.let { put("name", it) }; command.visible?.let { put("visible", it) }
            command.opacity?.let { put("opacity", it.toDouble()) }; command.lock?.let { put("lock", it.swiftName) }
            command.blend?.let { put("blend", it.swiftName) }
        }))
        is Command.SetFrameHold -> JSONObject().put("setFrameHold", JSONObject().put("frame", ref(command.frame)).put("ticks", command.ticks))
        is Command.DeleteElements -> JSONObject().put("deleteElements", JSONObject().put("frame", ref(command.frame)).put("elementIDs", JSONArray(command.ids)))
        is Command.UpdateAudioTrack -> JSONObject().put("updateAudioTrack", JSONObject().put("track", command.track).apply {
            command.volume?.let { put("volume", it.toDouble()) }; command.muted?.let { put("muted", it) }
            command.pan?.let { put("pan", it.toDouble()) }; command.soloed?.let { put("soloed", it) }
        })
        is Command.Draw -> JSONObject().put("draw", JSONObject().put("frame", ref(command.frame)).put("layer", ref(command.layer))
            .put("strokes", JSONArray(command.strokes.map { if (portable) iosStroke(it)!! else androidStroke(it) })))
    }

    // MARK: Receiving

    /** Rebuild another creator's edit with the same strict rules as any untrusted input. */
    fun decode(kind: String, payload: JSONObject): List<Command> {
        if (kind != KIND && kind != ANDROID_KIND) throw Refused("This shared edit (${kind.take(64)}) is not one Android Studio can replay.")
        val allowed = setOf("schemaVersion", "target", "commands", "createdFrameIDs", "createdLayerIDs", "createdElementIDs")
        if (payload.keys().asSequence().any { it !in allowed }) throw Refused("The shared edit is malformed.")
        if (payload.opt("schemaVersion") != 1) throw Refused("This shared edit uses a newer format than this app understands.")
        val text = payload.opt("commands") as? String ?: throw Refused("The shared edit is malformed.")
        if (text.toByteArray(Charsets.UTF_8).size > MAXIMUM_PAYLOAD_BYTES) throw Refused("The shared edit is too large.")
        fun ids(key: String): List<String> {
            if (!payload.has(key) || payload.isNull(key)) return emptyList()
            val array = payload.opt(key) as? JSONArray ?: throw Refused("The shared edit is malformed.")
            return (0 until array.length()).map { (array.opt(it) as? String)?.takeIf { id -> id.isNotEmpty() && id.length <= 160 } ?: throw Refused("The shared edit is malformed.") }
        }
        if (ids("createdFrameIDs").isNotEmpty() || ids("createdLayerIDs").isNotEmpty())
            throw Refused("Adding frames or layers from a shared edit is not supported on Android yet.")
        val createdElements = ids("createdElementIDs")
        val array = try { JSONArray(text) } catch (e: Exception) { throw Refused("The shared edit is malformed.") }
        if (array.length() !in 1..MAXIMUM_COMMANDS) throw Refused("The shared edit has too many commands.")
        val raw = (0 until array.length()).map { array.opt(it) as? JSONObject ?: throw Refused("The shared edit is malformed.") }
        // iOS replays keep the author's element identities; they arrive in creation order.
        val strokeCount = raw.sumOf { (it.opt("draw") as? JSONObject)?.optJSONArray("strokes")?.length() ?: 0 }
        if (strokeCount > MAXIMUM_STROKES) throw Refused("The shared edit has too many drawings.")
        if (createdElements.isNotEmpty() && createdElements.size != strokeCount) throw Refused("The shared edit's drawing identities do not match its drawings.")
        val identities = createdElements.iterator()
        val commands = raw.map { command(it, kind == ANDROID_KIND, identities) }
        val declared = if (payload.has("target") && !payload.isNull("target")) payload.opt("target") as? String ?: throw Refused("The shared edit is malformed.") else null
        if (declared != null && declared.length !in 1..200) throw Refused("The shared edit is malformed.")
        if (target(commands) != declared) throw Refused("The shared edit's target does not match its commands.")
        return commands
    }

    private fun JSONObject.only(vararg keys: String) {
        val allowed = keys.toSet()
        if (keys().asSequence().any { it !in allowed }) throw Refused("The shared edit is malformed.")
    }
    private fun JSONObject.text(key: String): String = opt(key) as? String ?: throw Refused("The shared edit is malformed.")
    private fun JSONObject.optText(key: String): String? = if (!has(key) || isNull(key)) null else text(key)
    private fun JSONObject.number(key: String): Double = (opt(key) as? Number)?.toDouble()?.takeIf { it.isFinite() } ?: throw Refused("The shared edit is malformed.")
    private fun JSONObject.optNumber(key: String): Double? = if (!has(key) || isNull(key)) null else number(key)
    private fun JSONObject.flag(key: String): Boolean = opt(key) as? Boolean ?: throw Refused("The shared edit is malformed.")
    private fun JSONObject.optFlag(key: String): Boolean? = if (!has(key) || isNull(key)) null else flag(key)
    private fun JSONObject.integer(key: String): Int {
        val value = opt(key)
        if (value !is Int && value !is Long) throw Refused("The shared edit is malformed.")
        return (value as Number).toLong().takeIf { it in Int.MIN_VALUE..Int.MAX_VALUE }?.toInt() ?: throw Refused("The shared edit is malformed.")
    }
    private fun JSONObject.obj(key: String): JSONObject = opt(key) as? JSONObject ?: throw Refused("The shared edit is malformed.")
    private fun JSONObject.list(key: String): JSONArray = opt(key) as? JSONArray ?: throw Refused("The shared edit is malformed.")
    private fun reference(o: JSONObject): String {
        if (o.length() != 1) throw Refused("The shared edit is malformed.")
        if (o.has("created")) throw Refused("Shared edits that create frames or layers are not supported on Android yet.")
        return o.text("id").takeIf { it.isNotEmpty() && it.length <= 160 } ?: throw Refused("The shared edit is malformed.")
    }

    private fun command(o: JSONObject, android: Boolean, identities: Iterator<String>): Command {
        if (o.length() != 1) throw Refused("The shared edit is malformed.")
        val key = o.keys().next()
        val body = o.obj(key)
        return when (key) {
            "renameProject" -> { body.only("name"); Command.RenameProject(body.text("name")) }
            "updateLayer" -> {
                body.only("layer", "settings")
                val s = body.obj("settings")
                s.only("name", "visible", "opacity", "lock", "blend", "glowEnabled", "glowColor", "glowRadius", "glowStrength")
                if (listOf("glowEnabled", "glowColor", "glowRadius", "glowStrength").any { s.has(it) && !s.isNull(it) })
                    throw Refused("Layer glow is not available on Android yet.")
                val lock = s.optText("lock")?.let { LayerLockMode.fromSwift(it) ?: throw Refused("The shared edit is malformed.") }
                val blend = s.optText("blend")?.let { LayerBlend.fromSwift(it) ?: throw Refused("This layer blend is not available on Android.") }
                val update = Command.UpdateLayer(reference(body.obj("layer")), s.optText("name"), s.optFlag("visible"), s.optNumber("opacity")?.toFloat(), lock, blend)
                if (update.name == null && update.visible == null && update.opacity == null && update.lock == null && update.blend == null) throw Refused("The shared edit is malformed.")
                update
            }
            "setFrameHold" -> { body.only("frame", "ticks"); Command.SetFrameHold(reference(body.obj("frame")), body.integer("ticks")) }
            "deleteElements" -> {
                body.only("frame", "elementIDs")
                val ids = body.list("elementIDs").let { a -> (0 until a.length()).map { (a.opt(it) as? String)?.takeIf { id -> id.isNotEmpty() && id.length <= 128 } ?: throw Refused("The shared edit is malformed.") } }
                if (ids.isEmpty() || ids.toSet().size != ids.size) throw Refused("The shared edit is malformed.")
                Command.DeleteElements(reference(body.obj("frame")), ids)
            }
            "updateAudioTrack" -> {
                body.only("track", "volume", "muted", "pan", "soloed")
                val update = Command.UpdateAudioTrack(body.integer("track"), body.optNumber("volume")?.toFloat(), body.optFlag("muted"),
                    body.optNumber("pan")?.toFloat(), body.optFlag("soloed"))
                if (update.volume == null && update.muted == null && update.pan == null && update.soloed == null) throw Refused("The shared edit is malformed.")
                update
            }
            "draw" -> {
                body.only("frame", "layer", "strokes")
                val frame = reference(body.obj("frame")); val layer = reference(body.obj("layer"))
                val strokes = body.list("strokes")
                if (strokes.length() == 0) throw Refused("The shared edit is malformed.")
                Command.Draw(frame, layer, (0 until strokes.length()).map { index ->
                    val wire = strokes.opt(index) as? JSONObject ?: throw Refused("The shared edit is malformed.")
                    val authored = wire.text("id")
                    val id = if (identities.hasNext()) identities.next() else authored
                    if (android) decodeAndroidStroke(wire, id, layer) else decodeIosStroke(wire, id, layer)
                })
            }
            else -> throw Refused("This shared edit uses a Studio command ($key) that Android cannot replay yet.")
        }
    }

    /** Replays [commands] on [document]. Every reference must exist and every new drawing identity
     * must be new, otherwise the copies have diverged and nothing changes. The view (active frame,
     * active layer) is this device's and is never moved by a replay. */
    fun apply(document: Document, commands: List<Command>): Document {
        var d = document
        fun frame(id: String) { if (d.frames.none { it.id == id }) throw Refused("Frame $id is not in your copy of the project; it has diverged from the room.") }
        fun layer(id: String) { if (d.layers.none { it.id == id }) throw Refused("Layer $id is not in your copy of the project; it has diverged from the room.") }
        commands.forEach { command ->
            d = when (command) {
                is Command.RenameProject -> {
                    val name = command.name.trim()
                    if (name.isEmpty() || name.length > 120 || name.any { it.isISOControl() }) throw Refused("The shared project name is invalid.")
                    d.copy(name = name)
                }
                is Command.UpdateLayer -> {
                    layer(command.layer)
                    command.name?.let { if (it.isBlank() || it.length > 80 || it.any { c -> c.isISOControl() }) throw Refused("The shared layer name is invalid.") }
                    command.opacity?.let { if (!it.isFinite() || it !in 0f..1f) throw Refused("The shared layer opacity is invalid.") }
                    d.copy(layers = d.layers.map { if (it.id != command.layer) it else it.copy(name = command.name ?: it.name,
                        visible = command.visible ?: it.visible, opacity = command.opacity ?: it.opacity,
                        lockMode = command.lock ?: it.lockMode, blend = command.blend ?: it.blend) })
                }
                is Command.SetFrameHold -> {
                    frame(command.frame)
                    if (command.ticks !in 1..600) throw Refused("The shared frame timing is invalid.")
                    d.copy(frames = d.frames.map { if (it.id == command.frame) it.copy(hold = command.ticks) else it })
                }
                is Command.DeleteElements -> {
                    frame(command.frame)
                    val target = d.frames.first { it.id == command.frame }
                    if (!command.ids.all { id -> target.strokes.any { it.id == id } })
                        throw Refused("The drawings this edit deletes are not in your copy of the project; it has diverged from the room.")
                    val ids = command.ids.toSet()
                    d.copy(frames = d.frames.map { if (it.id == command.frame) it.copy(strokes = it.strokes.filter { s -> s.id !in ids }) else it })
                }
                is Command.Draw -> {
                    frame(command.frame); layer(command.layer)
                    val existing = d.frames.flatMap { f -> f.strokes.map { it.id } }.toSet()
                    if (command.strokes.any { it.id in existing } || command.strokes.map { it.id }.toSet().size != command.strokes.size)
                        throw Refused("A drawing in this edit is already in your copy of the project; it has diverged from the room.")
                    if (command.strokes.any { it.layerID != command.layer }) throw Refused("The shared edit is malformed.")
                    d.copy(frames = d.frames.map { if (it.id == command.frame) it.copy(strokes = it.strokes + command.strokes) else it })
                }
                is Command.UpdateAudioTrack -> {
                    if (command.track !in 1..4) throw Refused("The shared audio track is invalid.")
                    val index = command.track - 1
                    val mix = d.audioTracks[index]
                    val next = mix.copy(volume = command.volume ?: mix.volume, muted = command.muted ?: mix.muted, pan = command.pan ?: mix.pan, soloed = command.soloed ?: mix.soloed)
                    try { next.validate() } catch (e: IllegalArgumentException) { throw Refused("The shared audio track settings are invalid.") }
                    d.copy(audioTracks = d.audioTracks.mapIndexed { i, it -> if (i == index) next else it })
                }
            }
        }
        return try { d.validated() } catch (e: Refused) { throw e } catch (e: IllegalArgumentException) {
            throw Refused("The shared edit would make your copy invalid (${e.message ?: "validation failed"}).")
        } catch (e: IllegalStateException) { throw Refused("The shared edit would make your copy invalid.") }
    }

    // MARK: Stroke wire forms

    private fun hex(color: Int) = String.format(Locale.ROOT, "#%06X", color and 0x00ffffff)

    /** The iOS `StudioCommandStroke` for a stroke the iOS vocabulary can express (same mapping as the
     * portable project export), or null. Exactness is checked separately by decoding it back. */
    fun iosStroke(stroke: Stroke): JSONObject? {
        val swift = stroke.swiftRoundBrush
        val tool: String; val width: Double
        when {
            stroke.preservesLayerAlpha || stroke.brush != BrushFamily.Round || stroke.text != null || stroke.image != null || stroke.fill != null -> return null
            stroke.tool == Tool.Line && swift == null && !stroke.swiftLegacyPath -> { tool = "line"; width = stroke.width.toDouble() }
            stroke.tool != Tool.Pencil -> return null
            swift != null -> { tool = "pen"; width = stroke.width.toDouble() }
            stroke.swiftLegacyPath && stroke.swiftLegacyButtCap -> { tool = "pencil"; width = stroke.width / 0.8 }
            stroke.swiftLegacyPath -> { tool = "pen"; width = stroke.width.toDouble() }
            else -> return null
        }
        val points = JSONArray(stroke.points.mapIndexed { index, point ->
            JSONObject().put("x", point.x.toDouble()).put("y", point.y.toDouble()).apply { swift?.let { put("pressure", it.pressures[index]) } }
        })
        return JSONObject().put("id", stroke.id).put("tool", tool).put("points", points).put("color", hex(stroke.color))
            .put("width", width).put("opacity", stroke.opacity.toDouble()).apply { swift?.let { put("brush", JSONObject(it.descriptor)) } }
    }

    /** An iOS `StudioCommandStroke` as Android artwork, read exactly like the portable project import:
     * pen/pencil/brush paths and two-point lines. Shapes, erasers, text and other tools are refused. */
    fun decodeIosStroke(o: JSONObject, id: String, layer: String): Stroke {
        o.only("id", "tool", "points", "color", "width", "opacity", "shape", "eraser", "text", "brush")
        if (listOf("shape", "eraser", "text").any { o.has(it) && !o.isNull(it) })
            throw Refused("Shapes, erasers and text drawn in iOS Studio cannot be replayed on Android yet.")
        val name = o.text("tool")
        val tool = when (name) { "pen", "pencil", "brush" -> Tool.Pencil; "line" -> Tool.Line
            else -> throw Refused("The iOS $name tool cannot be replayed on Android yet.") }
        val descriptor = if (o.has("brush") && !o.isNull("brush")) o.obj("brush") else null
        val points = o.list("points")
        if (points.length() !in 1..8192) throw Refused("The shared drawing is malformed.")
        if (tool == Tool.Line && (descriptor != null || points.length() != 2)) throw Refused("The shared line is malformed.")
        val color = o.text("color")
        if (!Regex("#[0-9A-Fa-f]{6}").matches(color)) throw Refused("The shared drawing colour is malformed.")
        val parsed = (0 until points.length()).map { index ->
            val p = points.opt(index) as? JSONObject ?: throw Refused("The shared drawing is malformed.")
            p.only("x", "y", "pressure", "timestamp", "tilt")
            if (p.has("tilt") && !p.isNull("tilt")) throw Refused("Pencil tilt from iOS cannot be replayed on Android yet.")
            Point(p.number("x").toFloat(), p.number("y").toFloat()) to (p.optNumber("pressure") ?: 1.0)
        }
        val swift = descriptor?.let { d ->
            SwiftRoundBrush(d.toString(), parsed.map { it.second }).also {
                try { it.validate(parsed.size) } catch (e: Exception) { throw Refused("This iOS brush cannot be replayed on Android yet.") }
            }
        }
        val multiplier = if (descriptor != null) 1f else when (name) { "pencil" -> 0.8f; "brush" -> 1.5f; else -> 1f }
        return Stroke(id, layer, parsed.map { it.first }, (0xff000000L or color.substring(1).toLong(16)).toInt(), (o.number("width") * multiplier).toFloat(), tool,
            opacity = o.number("opacity").toFloat(), swiftLegacyPath = descriptor == null && tool == Tool.Pencil,
            swiftLegacyButtCap = descriptor == null && name == "pencil", swiftRoundBrush = swift)
    }

    /** Android-native stroke record for [ANDROID_KIND]; images and fills are never shared. */
    fun androidStroke(s: Stroke): JSONObject {
        require(s.image == null && s.fill == null && s.tool != Tool.Image && s.tool != Tool.Fill)
        return JSONObject().put("id", s.id).put("tool", s.tool.name).put("color", s.color).put("width", s.width.toDouble())
            .put("opacity", s.opacity.toDouble()).put("filled", s.filled).put("brush", s.brush.name).put("brushSeed", s.brushSeed)
            .put("nibAngle", s.nibAngle.toDouble()).put("swiftLegacyPath", s.swiftLegacyPath).put("swiftLegacyButtCap", s.swiftLegacyButtCap)
            .put("preservesLayerAlpha", s.preservesLayerAlpha)
            .put("brushTransform", JSONArray(listOf(s.brushTransform.a, s.brushTransform.b, s.brushTransform.c, s.brushTransform.d).map { it.toDouble() }))
            .put("points", JSONArray(s.points.map { JSONArray(listOf(it.x.toDouble(), it.y.toDouble())) }))
            .apply {
                s.swiftRoundBrush?.let { put("swiftRoundBrush", it.json()) }
                s.text?.let { put("text", JSONObject().put("content", it.content).put("fontSize", it.fontSize.toDouble())) }
            }
    }

    fun decodeAndroidStroke(o: JSONObject, id: String, layer: String): Stroke {
        o.only("id", "tool", "color", "width", "opacity", "filled", "brush", "brushSeed", "nibAngle", "swiftLegacyPath", "swiftLegacyButtCap",
            "preservesLayerAlpha", "brushTransform", "points", "swiftRoundBrush", "text")
        val tool = Tool.entries.firstOrNull { it.name == o.text("tool") }?.takeIf { it.isDrawing || it == Tool.Text }
            ?: throw Refused("This shared drawing uses a tool Android Studio cannot replay.")
        val brush = BrushFamily.entries.firstOrNull { it.name == o.text("brush") } ?: throw Refused("This shared drawing uses an unknown brush.")
        val points = o.list("points")
        if (points.length() !in 1..8192) throw Refused("The shared drawing is malformed.")
        val transform = o.list("brushTransform")
        if (transform.length() != 4) throw Refused("The shared drawing is malformed.")
        fun element(a: JSONArray, i: Int) = (a.opt(i) as? Number)?.toDouble()?.takeIf { it.isFinite() }?.toFloat() ?: throw Refused("The shared drawing is malformed.")
        val text = if (o.has("text")) o.obj("text").let { t -> t.only("content", "fontSize"); EditableText(t.text("content"), t.number("fontSize").toFloat()) } else null
        val swift = if (o.has("swiftRoundBrush")) try { SwiftRoundBrush.decode(o.obj("swiftRoundBrush")) } catch (e: Refused) { throw e } catch (e: Exception) { throw Refused("The shared brush is malformed.") } else null
        return Stroke(id, layer, (0 until points.length()).map { index ->
            val p = points.opt(index) as? JSONArray ?: throw Refused("The shared drawing is malformed.")
            if (p.length() != 2) throw Refused("The shared drawing is malformed.")
            Point(element(p, 0), element(p, 1))
        }, o.integer("color"), o.number("width").toFloat(), tool, o.flag("filled"), o.number("opacity").toFloat(), brush, o.integer("brushSeed"),
            BrushTransform(element(transform, 0), element(transform, 1), element(transform, 2), element(transform, 3)),
            o.number("nibAngle").toFloat(), text, swiftLegacyPath = o.flag("swiftLegacyPath"), swiftLegacyButtCap = o.flag("swiftLegacyButtCap"),
            swiftRoundBrush = swift, preservesLayerAlpha = o.flag("preservesLayerAlpha"))
    }
}
