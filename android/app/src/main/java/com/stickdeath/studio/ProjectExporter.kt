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

/** `SDI` is the iOS portable envelope (supported subset only); `MANIFEST` saves the manifest of the
 * last MP4/GIF render, since single-file pickers cannot deliver a sidecar. */
enum class ExportKind { PNG, SEQUENCE, SPRITESHEET, PROJECT, MP4, GIF, CREDITS, SDI, MANIFEST }
/** [manifest] holds the iOS-layout manifest text for MP4/GIF renders; the caller offers it separately. */
data class ExportArtifact(val file: File, val kind: ExportKind, val name: String, val share: Boolean = false, val manifest: String? = null)
/** Render choices beyond the kind. [transparent] applies to PNG, sequence and spritesheet only. */
data class ExportOptions(val transparent: Boolean = false, val manifestText: String? = null, val manifestName: String? = null)

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
    suspend fun prepare(context: Context, document: Document, kind: ExportKind, progress: (Int, Int) -> Unit): ExportArtifact =
        prepare(context, document, kind, ExportOptions(), progress)
    suspend fun prepare(context: Context, document: Document, kind: ExportKind, options: ExportOptions, progress: (Int, Int) -> Unit): ExportArtifact {
        val d = document.validated()
        val base = ExportManifests.filenameBase(d)
        if (kind == ExportKind.MP4) {
            val movie = MovieExporter.prepare(context,d,progress)
            // The manifest describes the file that was actually written, including its byte count.
            return movie.copy(manifest = ExportManifests.movie(d, movie.file.length(), movie.name, d.audioClips.isNotEmpty()))
        }
        if (kind == ExportKind.GIF) {
            val gif = GifExporter.prepare(context,d,progress)
            return gif.copy(manifest = ExportManifests.gif(d, gif.file.length()))
        }
        require(kind in setOf(ExportKind.PROJECT, ExportKind.CREDITS, ExportKind.SDI, ExportKind.MANIFEST) || d.width.toLong() * d.height <= 4_194_304) { "PNG export currently supports canvases up to 4 megapixels. No resized export was created." }
        if (kind == ExportKind.MANIFEST) require(!options.manifestText.isNullOrEmpty() && !options.manifestName.isNullOrEmpty()) { "Render an MP4 or GIF first; its manifest is then available to save." }
        val transparent = options.transparent && kind in setOf(ExportKind.PNG, ExportKind.SEQUENCE, ExportKind.SPRITESHEET)
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
                    // A fresh ARGB bitmap is fully transparent; the renderer paints the project
                    // background only when the export is opaque.
                    val bitmap = Bitmap.createBitmap(d.width, d.height, Bitmap.Config.ARGB_8888)
                    try {
                        FrameRenderer.draw(Canvas(bitmap), d, frame, background = !transparent, checkCancellation = check)
                        check()
                        require(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)) { "PNG encoding failed." }
                        check()
                    } finally { bitmap.recycle() }
                }
                if (kind == ExportKind.CREDITS) { bounded.write(AssetCredits.manifest(d).toString(2).toByteArray(Charsets.UTF_8)); progress(1, 1) }
                else if (kind == ExportKind.PROJECT) { bounded.write(ProjectStore(context).encode(d)); progress(1, 1) }
                else if (kind == ExportKind.SDI) { bounded.write(SwiftProjectExport.encode(d)); progress(1, 1) }
                else if (kind == ExportKind.MANIFEST) { bounded.write(requireNotNull(options.manifestText).toByteArray(Charsets.UTF_8)); progress(1, 1) }
                else if (kind == ExportKind.PNG) { png(d.frame, bounded); progress(1, 1) }
                else ZipOutputStream(bounded).use { zip ->
                    // iOS layout: frame images named <base>_%06d.png / <base>_spritesheet.png beside manifest.json.
                    if (layout != null) {
                        check()
                        val atlas = Bitmap.createBitmap(layout.width, layout.height, Bitmap.Config.ARGB_8888)
                        try {
                            val canvas = Canvas(atlas)
                            if (!transparent) canvas.drawColor(d.backgroundColor)
                            d.frames.forEachIndexed { index, frame ->
                                check()
                                val x = (index % layout.columns) * d.width
                                val y = (index / layout.columns) * d.height
                                val checkpoint = canvas.save()
                                try {
                                    canvas.translate(x.toFloat(), y.toFloat())
                                    FrameRenderer.draw(canvas, d, frame, background = !transparent, checkCancellation = check)
                                } finally { canvas.restoreToCount(checkpoint) }
                                progress(index + 1, d.frames.size)
                            }
                            check()
                            zip.putNextEntry(ZipEntry(ExportManifests.sheetFilename(base)))
                            require(atlas.compress(Bitmap.CompressFormat.PNG, 100, zip)) { "Spritesheet encoding failed." }
                            check(); zip.closeEntry()
                        } finally { atlas.recycle() }
                    } else d.frames.forEachIndexed { index, frame ->
                        check()
                        zip.putNextEntry(ZipEntry(ExportManifests.frameFilename(base, index))); png(frame, zip); zip.closeEntry()
                        progress(index + 1, d.frames.size)
                    }
                    zip.putNextEntry(ZipEntry("asset-credits.json")); zip.write(AssetCredits.manifest(d).toString(2).toByteArray(Charsets.UTF_8)); zip.closeEntry()
                    val manifest = ExportManifests.image(d, if (layout == null) ExportManifests.ImageFormat.PngSequence else ExportManifests.ImageFormat.Spritesheet, transparent,
                        layout?.let { ExportManifests.SheetLayout(it.columns, it.rows, it.width, it.height) })
                    zip.putNextEntry(ZipEntry("manifest.json")); zip.write(manifest.toByteArray(Charsets.UTF_8)); zip.closeEntry()
                }
                check()
            }
            complete = true
            return ExportArtifact(file, kind, when (kind) {
                ExportKind.MP4 -> "$base.mp4"
                ExportKind.GIF -> "$base.gif"
                ExportKind.CREDITS -> "$base-asset-credits.json"
                ExportKind.PROJECT -> "$base.sdiandroid.json"
                ExportKind.SDI -> "$base.sdi"
                ExportKind.MANIFEST -> requireNotNull(options.manifestName)
                ExportKind.PNG -> "$base-frame.png"
                ExportKind.SEQUENCE -> "$base-frames.zip"
                ExportKind.SPRITESHEET -> "$base-spritesheet.zip"
            })
        } finally { if (!complete) file.delete() }
    }
}
