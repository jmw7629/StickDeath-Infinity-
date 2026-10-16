package com.stickdeath.studio

import com.stickdeath.studio.billing.ExportRendition
import java.util.Locale

/** Manifests with the same keys as the iOS export services (`StudioExportService.Manifest`,
 * `StudioMovieExportService.Manifest`, `StudioGIFEncoder.Receipt`) so tooling that reads an iOS
 * export reads an Android one. Pure Kotlin; every value is computed from the document and the
 * actual encoded output, never from a plan that did not run. */
object ExportManifests {
    enum class ImageFormat(val swiftName: String) { PngSequence("pngSequence"), Spritesheet("spritesheet") }
    data class SheetLayout(val columns: Int, val rows: Int, val imageWidth: Int, val imageHeight: Int)

    /** iOS `Background` is `white` or `transparent`; Android projects may use another opaque colour,
     * which is recorded as its `#RRGGBB` hex (an Android extension, never silently reported as white). */
    fun background(document: Document, transparent: Boolean): String = when {
        transparent -> "transparent"
        document.backgroundColor and 0x00ffffff == 0x00ffffff -> "white"
        else -> String.format(Locale.ROOT, "#%06X", document.backgroundColor and 0x00ffffff)
    }
    fun filenameBase(document: Document): String = StudioExportFilename.base(document.name)
    /** iOS frame image names: `<base>_%06d.png` (zero-based index) and `<base>_spritesheet.png`. */
    fun frameFilename(base: String, index: Int) = String.format(Locale.ROOT, "%s_%06d.png", base, index)
    fun sheetFilename(base: String) = "${base}_spritesheet.png"

    fun image(document: Document, format: ImageFormat, transparent: Boolean, layout: SheetLayout?): String {
        require((format == ImageFormat.Spritesheet) == (layout != null))
        val base = filenameBase(document)
        var tick = 0
        val frames = document.frames.mapIndexed { index, frame ->
            val x = if (layout == null) 0 else (index % layout.columns) * document.width
            val y = if (layout == null) 0 else (index / layout.columns) * document.height
            val record = linkedMapOf<String, Any?>(
                "index" to index, "id" to frame.id,
                "filename" to if (layout == null) frameFilename(base, index) else sheetFilename(base),
                "x" to x, "y" to y, "width" to document.width, "height" to document.height,
                "startTick" to tick, "durationTicks" to frame.hold)
            tick += frame.hold
            record
        }
        val manifest = linkedMapOf<String, Any?>(
            "version" to 1,
            "projectID" to document.id.uppercase(Locale.ROOT),
            "documentRevision" to document.revision,
            "format" to format.swiftName,
            "background" to background(document, transparent),
            "fps" to document.fps,
            "canvasWidth" to document.width, "canvasHeight" to document.height,
            "imageWidth" to (layout?.imageWidth ?: document.width),
            "imageHeight" to (layout?.imageHeight ?: document.height),
            "audioIncluded" to false,
            "editorGuidesIncluded" to false,
            "frames" to frames,
            "filenameBase" to base)
        if (layout != null) { manifest["sheetColumns"] = layout.columns; manifest["cellPadding"] = 0 }
        return SdiJson.encode(manifest)
    }

    /** MP4: Android encodes the canvas 1:1 (even dimensions required), so the render rule is the
     * identity rule in the iOS wording. */
    fun movie(document: Document, encodedBytes: Long, movieFilename: String, audioIncluded: Boolean,
              rendition: ExportRendition = ExportRendition(document.width, document.height, 1f, false)): String {
        val totalTicks = document.frames.sumOf { it.hold }
        val outW = rendition.width; val outH = rendition.height
        val scale = if (rendition.resized) String.format(Locale.ROOT, "%.6f (Plan limit)", outW.toDouble() / document.width) else "1.0 (Original)"
        val manifest = linkedMapOf<String, Any?>(
            "version" to 1,
            "projectID" to document.id.uppercase(Locale.ROOT),
            "documentRevision" to document.revision,
            "frameIDs" to document.frames.map { it.id },
            "fps" to document.fps,
            "width" to outW, "height" to outH,
            "durationNumerator" to totalTicks, "durationDenominator" to document.fps,
            "codec" to "h264",
            "background" to background(document, false),
            "audioIncluded" to audioIncluded,
            "editorGuidesIncluded" to false,
            "encodedBytes" to encodedBytes,
            "canvasWidth" to document.width, "canvasHeight" to document.height,
            "renderRule" to "scale=$scale; content ${outW}x${outH} at top-left; white padding right=0 bottom=0; output ${outW}x${outH}",
            "movieFilename" to movieFilename)
        // Android extension, present only when the Free plan burned in the SDI mark.
        if (rendition.watermark) manifest["watermark"] = "sdi-bottom-right"
        return SdiJson.encode(manifest)
    }

    fun gif(document: Document, encodedBytes: Long,
            rendition: ExportRendition = ExportRendition(document.width, document.height, 1f, false)): String {
        val manifest = linkedMapOf<String, Any?>(
            "version" to 1,
            "projectID" to document.id.uppercase(Locale.ROOT),
            "revision" to document.revision,
            "frameIDs" to document.frames.map { it.id },
            "width" to rendition.width, "height" to rendition.height,
            "sourceFPS" to document.fps,
            "delaysCentiseconds" to GifTiming.delaysCentiseconds(document.frames.map { it.hold }, document.fps),
            "encodedBytes" to encodedBytes,
            "background" to background(document, false),
            "audioIncluded" to false,
            "editorGuidesIncluded" to false)
        if (rendition.watermark) manifest["watermark"] = "sdi-bottom-right"
        return SdiJson.encode(manifest)
    }
}
