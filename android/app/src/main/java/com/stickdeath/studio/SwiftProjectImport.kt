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
    private val magic = "SDIPROJECT000001\n".toByteArray(Charsets.US_ASCII)
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
    fun decode(bytes: ByteArray): Document {
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
            "audioClips", "mutedAudioTracks", "audioTrackVolumes", "gridEnabled", "gridSettings", "onionEnabled", "onionSettings", "createdAt", "modifiedAt", "revision")
        require(source.getInt("schemaVersion") in 1..33) { "Unsupported Swift document version." }
        source.emptyArray("audioClips"); source.emptyArray("mutedAudioTracks")
        if (!source.isNull("audioTrackVolumes")) {
            val levels = source.getJSONArray("audioTrackVolumes")
            if (levels.length() != 4 || (0 until 4).any { levels.getDouble(it) != 1.0 }) unsupported()
        }
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
            if (layer.optBoolean("glowEnabled") || layer.optString("blendMode", "normal") != "normal" ||
                layer.optString("lockMode", "free") !in listOf("free", "full") ||
                listOf("glowColor", "glowRadius", "glowStrength", "colorLabel").any { !layer.isNull(it) }) unsupported()
            Layer(layer.getString("id"), layer.getString("name"), layer.optBoolean("visible", true),
                layer.optBoolean("locked") || layer.optString("lockMode") == "full", layer.optDouble("opacity", 1.0).toFloat())
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
                element.only("id", "tool", "points", "color", "width", "opacity", "layerID", "fillColor")
                if (!element.isNull("fillColor")) unsupported()
                val tool = when (element.getString("tool")) {
                    "pen", "pencil", "brush" -> Tool.Pencil
                    else -> unsupported()
                }
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
                    opacity = element.getDouble("opacity").toFloat(), swiftLegacyPath = true).let { stroke ->
                    val multiplier = when (element.getString("tool")) { "pencil" -> 0.8f; "brush" -> 1.5f; else -> 1f }
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
            frames, layers, source.getString("activeFrameID"), source.getString("activeLayerID")).validated()
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
