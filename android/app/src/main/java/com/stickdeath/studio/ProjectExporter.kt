package com.stickdeath.studio

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import java.io.File
import java.io.OutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import org.json.JSONArray
import org.json.JSONObject

enum class ExportKind { PNG, SEQUENCE, SPRITESHEET, PROJECT, MP4, GIF, CREDITS }
data class ExportArtifact(val file: File, val kind: ExportKind, val name: String)

/** Encodes one bitmap at a time into a bounded, privately owned staging file. */
object ProjectExporter {
    private data class Sheet(val columns: Int, val rows: Int, val width: Int, val height: Int)
    private fun sheet(document: Document): Sheet {
        val count = document.frames.size
        return (1..minOf(count, 8192 / document.width)).map { columns ->
            val rows = (count + columns - 1) / columns
            Sheet(columns, rows, columns * document.width, rows * document.height)
        }.filter { it.height <= 8192 && it.width.toLong() * it.height <= 8_388_608 }
            .minWithOrNull(compareBy<Sheet> { maxOf(it.width, it.height) }.thenBy { it.width.toLong() * it.height })
            ?: throw IllegalArgumentException("Spritesheet exceeds 8 megapixels or an 8192-pixel edge. Use PNG sequence for this project; no frames were omitted or resized.")
    }
    suspend fun prepare(context: Context, document: Document, kind: ExportKind, progress: (Int, Int) -> Unit): ExportArtifact {
        val d = document.validated()
        if (kind == ExportKind.MP4) return MovieExporter.prepare(context,d,progress)
        if (kind == ExportKind.GIF) return GifExporter.prepare(context,d,progress)
        require(kind in setOf(ExportKind.PROJECT, ExportKind.CREDITS) || d.width.toLong() * d.height <= 4_194_304) { "PNG export currently supports canvases up to 4 megapixels. No resized export was created." }
        val layout = if (kind == ExportKind.SPRITESHEET) sheet(d) else null
        val coroutine = currentCoroutineContext()
        val check = { coroutine.ensureActive() }
        val file = File.createTempFile("studio-export-", ".partial", context.cacheDir)
        var complete = false
        try {
            file.outputStream().use { raw ->
                val bounded = object : OutputStream() {
                    var written = 0L
                    override fun write(value: Int) { check(); require(written < 256L * 1024 * 1024) { "Export exceeds 256 MiB." }; raw.write(value); written++ }
                    override fun write(bytes: ByteArray, offset: Int, length: Int) {
                        check(); require(written + length <= 256L * 1024 * 1024) { "Export exceeds 256 MiB." }
                        raw.write(bytes, offset, length); written += length
                    }
                    override fun flush() = raw.flush()
                }
                fun png(frame: Frame, output: OutputStream) {
                    check()
                    val bitmap = Bitmap.createBitmap(d.width, d.height, Bitmap.Config.ARGB_8888)
                    try {
                        FrameRenderer.draw(Canvas(bitmap), d, frame, checkCancellation = check)
                        check()
                        require(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)) { "PNG encoding failed." }
                        check()
                    } finally { bitmap.recycle() }
                }
                if (kind == ExportKind.CREDITS) { bounded.write(AssetCredits.manifest(d).toString(2).toByteArray(Charsets.UTF_8)); progress(1, 1) }
                else if (kind == ExportKind.PROJECT) { bounded.write(ProjectStore(context).encode(d)); progress(1, 1) }
                else if (kind == ExportKind.PNG) { png(d.frame, bounded); progress(1, 1) }
                else ZipOutputStream(bounded).use { zip ->
                    val entries = JSONArray()
                    var tick = 0L
                    if (layout != null) {
                        check()
                        val atlas = Bitmap.createBitmap(layout.width, layout.height, Bitmap.Config.ARGB_8888)
                        try {
                            val canvas = Canvas(atlas)
                            canvas.drawColor(d.backgroundColor)
                            d.frames.forEachIndexed { index, frame ->
                                check()
                                val x = (index % layout.columns) * d.width
                                val y = (index / layout.columns) * d.height
                                val checkpoint = canvas.save()
                                try {
                                    canvas.translate(x.toFloat(), y.toFloat())
                                    FrameRenderer.draw(canvas, d, frame, checkCancellation = check)
                                } finally { canvas.restoreToCount(checkpoint) }
                                entries.put(JSONObject().put("file", "spritesheet.png").put("frameID", frame.id)
                                    .put("x", x).put("y", y).put("width", d.width).put("height", d.height)
                                    .put("startTick", tick).put("holdTicks", frame.hold))
                                tick += frame.hold; progress(index + 1, d.frames.size)
                            }
                            check()
                            zip.putNextEntry(ZipEntry("spritesheet.png"))
                            require(atlas.compress(Bitmap.CompressFormat.PNG, 100, zip)) { "Spritesheet encoding failed." }
                            check(); zip.closeEntry()
                        } finally { atlas.recycle() }
                    } else d.frames.forEachIndexed { index, frame ->
                        check()
                        val filename = "frames/frame_${(index + 1).toString().padStart(4, '0')}.png"
                        zip.putNextEntry(ZipEntry(filename)); png(frame, zip); zip.closeEntry()
                        entries.put(JSONObject().put("file", filename).put("frameID", frame.id)
                            .put("startTick", tick).put("holdTicks", frame.hold))
                        tick += frame.hold; progress(index + 1, d.frames.size)
                    }
                    zip.putNextEntry(ZipEntry("asset-credits.json")); zip.write(AssetCredits.manifest(d).toString(2).toByteArray(Charsets.UTF_8)); zip.closeEntry()
                    val manifest = JSONObject().put("format", if (layout == null) "sdi-png-sequence" else "sdi-spritesheet").put("version", 1)
                        .put("projectID", d.id).put("projectName", d.name).put("revision", d.revision)
                        .put("width", d.width).put("height", d.height).put("fps", d.fps)
                        .put("background", String.format(java.util.Locale.ROOT, "#%06X", d.backgroundColor and 0x00ffffff)).put("totalTicks", tick)
                        .put("timing", "Each tick lasts exactly 1/fps seconds; each frame is stored once.")
                        .put("frames", entries)
                    if (layout != null) {
                        manifest.put("imageWidth", layout.width).put("imageHeight", layout.height)
                            .put("columns", layout.columns).put("rows", layout.rows).put("coordinateOrigin", "top-left")
                    }
                    zip.putNextEntry(ZipEntry("manifest.json")); zip.write(manifest.toString(2).toByteArray(Charsets.UTF_8)); zip.closeEntry()
                }
                check()
            }
            val stem = d.name.replace(Regex("[^A-Za-z0-9 _-]"), "_").take(80).ifBlank { "animation" }
            complete = true
            return ExportArtifact(file, kind, when (kind) {
                ExportKind.MP4 -> "$stem.mp4"
                ExportKind.GIF -> "$stem.gif"
                ExportKind.CREDITS -> "$stem-asset-credits.json"
                ExportKind.PROJECT -> "$stem.sdiandroid.json"
                ExportKind.PNG -> "$stem-frame.png"
                ExportKind.SEQUENCE -> "$stem-frames.zip"
                ExportKind.SPRITESHEET -> "$stem-spritesheet.zip"
            })
        } finally { if (!complete) file.delete() }
    }
}
