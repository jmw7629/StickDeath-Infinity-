package com.stickdeath.studio

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.Base64
import java.util.Locale

/** Writes the iOS `DeviceStorageManager` portable envelope (`SDIPROJECT000001\n`, big-endian payload
 * length, SHA-256, Revision v1 JSON with a base64 `StudioDocumentArchive`) for the subset Android can
 * express faithfully. Anything outside that subset rejects the whole export with the first reason;
 * nothing is flattened, rasterised or silently dropped. Pure Kotlin so JVM tests cover it. */
object SwiftProjectExport {
    class Unsupported(message: String) : IllegalArgumentException(message)

    /** Reasons the export refuses, one per unsupported feature, so the UI can list them. */
    fun unsupportedReasons(document: Document): List<String> {
        val reasons = linkedSetOf<String>()
        if (document.audioClips.isNotEmpty()) reasons += "Audio clips are embedded WAV on Android; iOS stores managed audio assets. Remove clips or export the Android backup."
        document.frames.forEach { frame ->
            frame.strokes.forEach { stroke ->
                when {
                    stroke.tool == Tool.Pencil && stroke.brush != BrushFamily.Round -> reasons += "${stroke.brush.name} brush marks have no iOS brush descriptor."
                    stroke.tool == Tool.Pencil && stroke.preservesLayerAlpha -> reasons += "Alpha-locked paint needs an iOS brush descriptor Android does not record."
                    stroke.tool == Tool.Pencil && stroke.brushTransform != BrushTransform() -> reasons += "A resized or rotated iOS brush mark keeps an Android nib transform iOS elements cannot carry."
                    stroke.tool == Tool.Pencil || stroke.tool == Tool.Line -> Unit
                    stroke.tool.isEraser -> reasons += "Eraser marks use Android's layer-local clearing; the iOS eraser contract differs."
                    stroke.tool.isClosedShape -> reasons += "${stroke.tool.name} shapes are editable paths on Android and shape descriptors on iOS."
                    stroke.tool == Tool.Text -> reasons += "Text uses the Android system face and iOS text descriptors; not interchangeable yet."
                    stroke.tool == Tool.Image -> reasons += "Imported images need iOS managed image assets; not exported yet."
                    stroke.tool == Tool.Fill -> reasons += "Bucket fills use Android span geometry; iOS fill masks are canvas-sized."
                    else -> reasons += "${stroke.tool.name} artwork is not exportable yet."
                }
            }
        }
        return reasons.toList()
    }

    fun isExportable(document: Document) = unsupportedReasons(document).isEmpty()

    /** The complete portable bundle, or [Unsupported] naming the first blocking feature. */
    fun encode(document: Document, nowMillis: Long = System.currentTimeMillis()): ByteArray {
        val d = document.validated()
        unsupportedReasons(d).firstOrNull()?.let { throw Unsupported("$it The Android project is unchanged.") }
        val archive = SdiJson.encode(mapOf("document" to documentJson(d, nowMillis), "rasterFrameIndices" to emptyMap<String, Any>()), pretty = false)
        val encodedArchive = Base64.getEncoder().encodeToString(archive.toByteArray(Charsets.UTF_8))
        val created = SwiftDates.fromEpochMillis(nowMillis); val modified = SwiftDates.fromEpochMillis(d.modified)
        val project = linkedMapOf<String, Any?>(
            "id" to d.id.uppercase(Locale.ROOT),
            "metadata" to mapOf(
                "id" to d.id.uppercase(Locale.ROOT), "title" to d.name, "fps" to d.fps,
                "canvasWidth" to d.width, "canvasHeight" to d.height,
                "frameCount" to d.frames.size, "layerCount" to d.layers.size,
                "createdAt" to minOf(created, modified), "modifiedAt" to modified),
            "frames" to d.frames.map { emptyMap<String, Any>() },
            "audioTracks" to emptyList<Any>(),
            "editableDocumentData" to encodedArchive)
        val payload = SdiJson.encode(mapOf("version" to 1, "project" to project), pretty = false).toByteArray(Charsets.UTF_8)
        require(payload.size <= 24 * 1024 * 1024) { "Portable project exceeds 24 MiB." }
        val digest = MessageDigest.getInstance("SHA-256").digest(payload)
        return SwiftProjectImport.magic + ByteBuffer.allocate(8).order(ByteOrder.BIG_ENDIAN).putLong(payload.size.toLong()).array() + digest + payload
    }

    /** Lowest iOS schema that validates this content: 34 for PhotoCraft blends, pan or solo, else 21 (holds). */
    fun schemaVersion(document: Document): Int {
        val needs34 = document.layers.any { it.blend.isExtended } ||
            document.audioTracks.any { it.pan != 0f || it.soloed }
        return if (needs34) 34 else 21
    }

    internal fun documentJson(d: Document, nowMillis: Long): Map<String, Any?> {
        val created = SwiftDates.fromEpochMillis(nowMillis); val modified = SwiftDates.fromEpochMillis(d.modified)
        val json = linkedMapOf<String, Any?>(
            "schemaVersion" to schemaVersion(d),
            "id" to d.id.uppercase(Locale.ROOT),
            "name" to d.name, "width" to d.width, "height" to d.height, "fps" to d.fps,
            "frames" to d.frames.map { frame ->
                val record = linkedMapOf<String, Any?>("id" to frame.id, "elements" to frame.strokes.map { element(it) })
                if (frame.hold > 1) record["holdTicks"] = frame.hold
                record
            },
            "layers" to d.layers.map { layer ->
                val record = linkedMapOf<String, Any?>(
                    "id" to layer.id, "name" to layer.name, "visible" to layer.visible,
                    "locked" to layer.locked, "opacity" to layer.opacity.toDouble(),
                    "lockMode" to layer.lockMode.swiftName, "blendMode" to layer.blend.swiftName,
                    "glowEnabled" to false)
                layer.label?.let { record["colorLabel"] = it.hex }
                record
            },
            "activeFrameID" to d.activeFrameID, "activeLayerID" to d.activeLayerID,
            "audioClips" to emptyList<Any>(),
            "gridEnabled" to false, "onionEnabled" to false,
            "createdAt" to minOf(created, modified), "modifiedAt" to modified,
            "revision" to d.revision)
        val volumes = d.audioTracks.map { it.volume.toDouble() }
        if (volumes.any { it != 1.0 }) json["audioTrackVolumes"] = volumes
        val muted = d.audioTracks.mapIndexedNotNull { index, mix -> if (mix.muted) index + 1 else null }
        if (muted.isNotEmpty()) json["mutedAudioTracks"] = muted
        val pans = d.audioTracks.map { it.pan.toDouble() }
        if (pans.any { it != 0.0 }) json["audioTrackPans"] = pans
        val soloed = d.audioTracks.mapIndexedNotNull { index, mix -> if (mix.soloed) index + 1 else null }
        if (soloed.isNotEmpty()) json["soloedAudioTracks"] = soloed
        return json
    }

    private fun hex(color: Int) = String.format(Locale.ROOT, "#%06X", color and 0x00ffffff)

    /** One iOS `DrawnElement`. Historical Android round strokes become descriptor-free `pen` elements
     * (iOS smooths them with its quadratic path, so curves differ slightly from Android's polyline). */
    internal fun element(stroke: Stroke): Map<String, Any?> {
        val swift = stroke.swiftRoundBrush
        val tool: String; val width: Double
        when {
            stroke.tool == Tool.Line -> { tool = "line"; width = stroke.width.toDouble() }
            swift != null -> { tool = "pen"; width = stroke.width.toDouble() }
            stroke.swiftLegacyPath && stroke.swiftLegacyButtCap -> { tool = "pencil"; width = stroke.width / 0.8 }
            else -> { tool = "pen"; width = stroke.width.toDouble() }
        }
        val points = stroke.points.mapIndexed { index, point ->
            val record = linkedMapOf<String, Any?>("x" to point.x.toDouble(), "y" to point.y.toDouble())
            swift?.let { record["pressure"] = it.pressures[index] }
            record
        }
        val record = linkedMapOf<String, Any?>(
            "id" to stroke.id, "tool" to tool, "points" to points, "color" to hex(stroke.color),
            "width" to width, "opacity" to stroke.opacity.toDouble(), "layerID" to stroke.layerID)
        swift?.let { record["brush"] = SdiJson.Raw(it.descriptor) }
        return record
    }
}
