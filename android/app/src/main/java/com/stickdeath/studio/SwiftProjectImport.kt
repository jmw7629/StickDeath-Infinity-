package com.stickdeath.studio

import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID

/** Reads the existing iOS DeviceStorageManager portable envelope, never an invented ZIP dialect.
 * This first editable bridge accepts plain vector drawings only. Unsupported content rejects the
 * entire import before ProjectStore saves anything; it is never flattened or silently discarded.
 */
internal object SwiftProjectImport {
    /** Highest iOS `StudioDocument.supportedSchemaVersions` bound this importer understands. Schema 35
     * only adds the bundled text face, and text elements are still rejected as unsupported content. */
    const val SUPPORTED_SCHEMA = 35
    internal val magic = "SDIPROJECT000001\n".toByteArray(Charsets.US_ASCII)
    fun recognizes(bytes: ByteArray): Boolean = bytes.size >= magic.size && magic.indices.all { bytes[it] == magic[it] }
    private fun unsupported(): Nothing = throw IllegalArgumentException(
        "This Swift project uses artwork or settings not yet supported by Android project transfer. Open it in iOS; the original is unchanged.")
    private fun JSONObject.only(vararg keys: String) {
        val allowed = keys.toSet()
        require(keys().asSequence().all { it in allowed || isNull(it) }) { "Unsupported Swift project fields; original preserved." }
    }
    private fun JSONObject.emptyArray(name: String) {
        if (!isNull(name) && getJSONArray(name).length() != 0) unsupported()
    }
    private fun JSONObject.emptyObject(name: String) {
        if (!isNull(name) && getJSONObject(name).length() != 0) unsupported()
    }
    /** [sdkInt] is the device API level that decides which blends can be drawn (JVM tests pass one). */
    fun decode(bytes: ByteArray, sdkInt: Int = android.os.Build.VERSION.SDK_INT): Document {
        val header = magic.size + 8 + 32
        require(recognizes(bytes) && bytes.size >= header) { "Invalid Swift project header." }
        val count = ByteBuffer.wrap(bytes, magic.size, 8).order(ByteOrder.BIG_ENDIAN).long
        require(count == (bytes.size - header).toLong() && count in 1..(24L * 1024 * 1024)) { "Invalid Swift project payload size." }
        val digest = MessageDigest.getInstance("SHA-256").apply { update(bytes, header, bytes.size - header) }.digest()
        require(MessageDigest.isEqual(digest, bytes.copyOfRange(magic.size + 8, header))) { "Swift project integrity check failed. Original preserved." }
        val root = json(bytes.copyOfRange(header, bytes.size))
        root.only("version", "project")
        require(root.getInt("version") == 1) { "Unsupported Swift portable version." }
        val project = root.getJSONObject("project")
        project.only("id", "metadata", "frames", "audioTracks", "editableDocumentData", "additionalImageAssets")
        project.emptyArray("audioTracks"); project.emptyObject("additionalImageAssets")
        val encoded = project.getString("editableDocumentData")
        require(encoded.length <= 24 * 1024 * 1024) { "Swift editable document exceeds Android capacity." }
        val archive = json(Base64.getDecoder().decode(encoded))
        archive.only("document", "rasterFrameIndices"); archive.emptyObject("rasterFrameIndices")
        val source = archive.getJSONObject("document")
        source.only("schemaVersion", "id", "name", "width", "height", "fps", "frames", "layers", "activeFrameID", "activeLayerID",
            "audioClips", "mutedAudioTracks", "audioTrackVolumes", "audioTrackPans", "soloedAudioTracks",
            "gridEnabled", "gridSettings", "onionEnabled", "onionSettings", "createdAt", "modifiedAt", "revision")
        val schemaVersion = source.getInt("schemaVersion")
        require(schemaVersion in 1..SUPPORTED_SCHEMA) { "Unsupported Swift document version." }
        source.emptyArray("audioClips")
        val tracks = audioTracks(source, schemaVersion)
        // Guide settings have differing limits/defaults. Do not silently replace a configured guide.
        if (source.optBoolean("gridEnabled") || source.optBoolean("onionEnabled") ||
            !source.isNull("gridSettings") || !source.isNull("onionSettings")) unsupported()
        val id = UUID.fromString(source.getString("id")).toString()
        require(UUID.fromString(project.getString("id")).toString() == id)
        val layersJSON = source.getJSONArray("layers")
        val framesJSON = source.getJSONArray("frames")
        require(layersJSON.length() in 1..32 && framesJSON.length() in 1..500)
        val stored = project.getJSONArray("frames")
        require(stored.length() == framesJSON.length())
        for (index in 0 until stored.length()) {
            val record = stored.getJSONObject(index)
            if (record.keys().asSequence().any { !record.isNull(it) }) unsupported()
        }
        val layers = (0 until layersJSON.length()).map { index ->
            val layer = layersJSON.getJSONObject(index)
            layer.only("id", "name", "visible", "locked", "opacity", "lockMode", "blendMode", "glowEnabled", "glowColor", "glowRadius", "glowStrength", "colorLabel")
            if (layer.optBoolean("glowEnabled") ||
                listOf("glowColor", "glowRadius", "glowStrength").any { !layer.isNull(it) }) unsupported()
            // iOS: `locked` forces lockMode "full" (CanvasLayer.init(from:)); otherwise the raw value decides.
            val lockMode = if (layer.optBoolean("locked")) LayerLockMode.Full
                else LayerLockMode.fromSwift(layer.optString("lockMode", "free")) ?: unsupported()
            // Only the eleven PhotoCraft swatches are labels; any other populated hex rejects.
            val label = if (layer.isNull("colorLabel")) null else LayerLabel.fromHex(layer.getString("colorLabel")) ?: unsupported()
            // iOS draws unknown legacy blend strings as Normal; project transfer rejects them instead of guessing.
            val blend = LayerBlend.fromSwift(layer.optString("blendMode", "normal")) ?: unsupported()
            require(!blend.isExtended || schemaVersion >= 34) { "This layer blend mode needs Swift project version 34; original preserved." }
            require(FrameRenderer.supports(blend, sdkInt)) { FrameRenderer.unavailableReason(blend, sdkInt) ?: "Unsupported blend: ${blend.label}" }
            Layer(layer.getString("id"), layer.getString("name"), layer.optBoolean("visible", true),
                lockMode, layer.optDouble("opacity", 1.0).toFloat(), blend, label)
        }
        var pointCount = 0; var strokeCount = 0
        val allIDs = mutableSetOf<String>()
        val frames = (0 until framesJSON.length()).map { index ->
            val frame = framesJSON.getJSONObject(index)
            frame.only("id", "elements", "holdTicks")
            val elements = frame.getJSONArray("elements")
            strokeCount += elements.length(); require(strokeCount <= 10_000)
            Frame(frame.getString("id"), (0 until elements.length()).map { n ->
                val element = elements.getJSONObject(n)
                element.only("id", "tool", "points", "color", "width", "opacity", "layerID", "fillColor", "brush")
                if (!element.isNull("fillColor")) unsupported()
                val tool = when (element.getString("tool")) {
                    "pen", "pencil", "brush" -> Tool.Pencil
                    // Historical descriptor-free line: two endpoints, straight segment (the Android→iOS export writes these).
                    "line" -> Tool.Line
                    else -> unsupported()
                }
                val descriptor = if (element.isNull("brush")) null else element.getJSONObject("brush")
                if (tool == Tool.Line && (descriptor != null || element.getJSONArray("points").length() != 2)) unsupported()
                val strokeID = element.getString("id")
                require(allIDs.add(strokeID)) { "Duplicate Swift artwork identity." }
                val points = element.getJSONArray("points")
                pointCount += points.length(); require(points.length() in 1..10192 && pointCount <= 100_000)
                val hex = element.getString("color")
                require(Regex("#[0-9A-Fa-f]{6}").matches(hex)) { "Unsupported Swift artwork color." }
                Stroke(strokeID, element.getString("layerID"), (0 until points.length()).map { p ->
                    val point = points.getJSONObject(p)
                    point.only("x", "y", "pressure", "timestamp")
                    // Historical renderer uses constant width for descriptor-free strokes.
                    Point(point.getDouble("x").toFloat(), point.getDouble("y").toFloat())
                }, (0xff000000L or hex.substring(1).toLong(16)).toInt(), element.getDouble("width").toFloat(), tool,
                    opacity = element.getDouble("opacity").toFloat(), swiftLegacyPath = descriptor == null && tool == Tool.Pencil, swiftLegacyButtCap = descriptor == null && element.getString("tool") == "pencil",
                    swiftRoundBrush = descriptor?.let { SwiftRoundBrush(it.toString(), (0 until points.length()).map { p ->
                        val point = points.getJSONObject(p)
                        if (point.isNull("pressure")) 1.0 else point.getDouble("pressure")
                    }).also { it.validate(points.length()) } }).let { stroke ->
                    val multiplier = if (descriptor != null) 1f else when (element.getString("tool")) { "pencil" -> 0.8f; "brush" -> 1.5f; else -> 1f }
                    stroke.copy(width = stroke.width * multiplier)
                }
            }, if (frame.isNull("holdTicks")) 1 else frame.getInt("holdTicks"))
        }
        val meta = project.getJSONObject("metadata")
        require(UUID.fromString(meta.getString("id")).toString() == id && meta.getString("title") == source.getString("name") &&
            meta.getInt("fps") == source.getInt("fps") && meta.getInt("canvasWidth") == source.getInt("width") &&
            meta.getInt("canvasHeight") == source.getInt("height") && meta.getInt("frameCount") == frames.size && meta.getInt("layerCount") == layers.size) {
            "Swift backup metadata does not match its editable document."
        }
        return Document(id, source.getString("name"), source.getInt("width"), source.getInt("height"), source.getInt("fps"),
            frames, layers, source.getString("activeFrameID"), source.getString("activeLayerID"), audioTracks = tracks).validated()
    }
    /** Four numbered track settings validated exactly like StudioDocument.validate(): volumes are four
     * finite values in 0…1 (schema ≥ 13), pans four finite values in -1…1 (schema ≥ 34), mute/solo lists
     * are sorted unique track numbers 1…4 (schema ≥ 12 / ≥ 34). Absent means unity, centred, no mute/solo. */
    private fun audioTracks(source: JSONObject, schemaVersion: Int): List<AudioTrackMix> {
        val volumes = FloatArray(4) { 1f }; val pans = FloatArray(4)
        val muted = BooleanArray(4); val soloed = BooleanArray(4)
        fun levels(name: String, minimumSchema: Int, range: ClosedFloatingPointRange<Double>, into: FloatArray) {
            if (source.isNull(name)) return
            val values = source.getJSONArray(name)
            require(schemaVersion >= minimumSchema && values.length() == 4 && (0 until 4).all { values.getDouble(it).isFinite() && values.getDouble(it) in range }) {
                "Swift audio track settings ($name) are invalid or need a newer project version; original preserved."
            }
            for (index in 0 until 4) into[index] = values.getDouble(index).toFloat()
        }
        fun trackSet(name: String, minimumSchema: Int, into: BooleanArray) {
            if (source.isNull(name)) return
            val values = source.getJSONArray(name)
            val numbers = (0 until values.length()).map { index ->
                // Strict integer tokens only: iOS decodes [Int], so 1.5 must not truncate to 1.
                val value = values.get(index)
                require(value is Int) { "Swift audio track settings ($name) are invalid; original preserved." }
                require(value in 1..4) { "Swift audio track settings ($name) are invalid; original preserved." }
                value
            }
            require(schemaVersion >= minimumSchema && numbers.size <= 4 && numbers == numbers.toSet().sorted()) {
                "Swift audio track settings ($name) are invalid or need a newer project version; original preserved."
            }
            numbers.forEach { into[it - 1] = true }
        }
        levels("audioTrackVolumes", 13, 0.0..1.0, volumes)
        levels("audioTrackPans", 34, -1.0..1.0, pans)
        trackSet("mutedAudioTracks", 12, muted)
        trackSet("soloedAudioTracks", 34, soloed)
        return (0 until 4).map { AudioTrackMix(volumes[it], muted[it], pans[it], soloed[it]).also { mix -> mix.validate() } }
    }
    private fun json(bytes: ByteArray): JSONObject {
        val text = Charsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(bytes)).toString()
        var depth = 0; var quoted = false; var escaped = false
        text.forEach { c ->
            if (quoted) {
                if (escaped) escaped = false else if (c == '\\') escaped = true else if (c == '"') quoted = false
            } else when (c) {
                '"' -> quoted = true
                '{', '[' -> { depth++; require(depth <= 32) { "Swift project nesting exceeds capacity." } }
                '}', ']' -> { depth--; require(depth >= 0) }
            }
        }
        require(!quoted && depth == 0)
        return JSONObject(text)
    }
}
