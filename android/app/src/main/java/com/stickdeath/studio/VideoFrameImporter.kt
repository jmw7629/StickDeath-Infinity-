package com.stickdeath.studio

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import java.io.ByteArrayOutputStream
import java.io.File

/** Copies only a user-selected file, extracts a bounded still, then removes its owned staging file.
 * The normalized image is embedded in the project, independent of the original provider URI. */
object VideoFrameImporter {
    private const val MAX_SOURCE_BYTES = 32L * 1024 * 1024
    @Synchronized fun extract(context: Context, uri: Uri, seconds: Double, check: () -> Unit): ImageArtwork {
        require(seconds.isFinite() && seconds >= 0.0) { "Invalid video source time." }
        require(uri.scheme == "content") { "Select a video through Files." }
        check()
        val directory = File(context.cacheDir, "studio-video-import").apply {
            require(isDirectory || mkdirs()) { "Video import storage is unavailable." }
        }
        // This process has one serialized importer; remove only its abandoned
        // staging files from a prior interrupted extraction, never user originals.
        directory.listFiles()?.filter { it.isFile && it.name.startsWith("frame-") && it.name.endsWith(".partial") }?.forEach {
            check(); require(it.delete()) { "Previous video import staging could not be cleared." }
        }
        val source = File.createTempFile("frame-", ".partial", directory)
        try {
            context.contentResolver.openInputStream(uri)?.use { input ->
                source.outputStream().use { output ->
                    var size = 0L
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        check()
                        val count = input.read(buffer)
                        if (count < 0) break
                        require(count > 0 && size + count <= MAX_SOURCE_BYTES) { "Choose a video no larger than 32 MiB." }
                        output.write(buffer, 0, count); size += count
                    }
                    require(size > 0) { "The selected video is empty." }
                }
            } ?: error("Files could not open this video. Its permission may have expired.")
            check()
            val reader = MediaMetadataRetriever()
            try {
                reader.setDataSource(source.absolutePath)
                check()
                require(reader.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_VIDEO) == "yes") { "This file has no readable video track." }
                val duration = reader.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()
                    ?: error("Video duration is unavailable.")
                val width = reader.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
                val height = reader.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
                require(duration in 1..120_000 && seconds * 1000 < duration) { "Use a video up to two minutes long and place the animation playhead inside its duration." }
                require(width in 1..8192 && height in 1..8192 && width.toLong() * height <= 33_554_432) { "Video dimensions exceed the supported limit." }
                // A timestamp can lie between source frames; ask for the nearest actual
                // decoded frame rather than an arbitrary representative/key frame.
                val bitmap = reader.getScaledFrameAtTime((seconds * 1_000_000).toLong(), MediaMetadataRetriever.OPTION_CLOSEST, 1024, 1024)
                    ?: error("The device could not decode a video frame at the playhead.")
                try {
                    check()
                    require(bitmap.width in 1..1024 && bitmap.height in 1..1024) { "Decoded video frame exceeded the image limit." }
                    val png = object : ByteArrayOutputStream() {
                        override fun write(bytes: ByteArray, offset: Int, length: Int) {
                            check(); require(count.toLong() + length <= ImageArtwork.MAX_BYTES) { "Video frame exceeds 1 MiB; no artwork was added." }
                            super.write(bytes, offset, length)
                        }
                        override fun write(value: Int) {
                            check(); require(count < ImageArtwork.MAX_BYTES) { "Video frame exceeds 1 MiB; no artwork was added." }
                            super.write(value)
                        }
                    }
                    require(bitmap.compress(Bitmap.CompressFormat.PNG, 100, png)) { "Video frame could not be encoded." }
                    check()
                    return png.toByteArray().inputStream().use { ImageArtwork.importImage(it, check) }
                } finally { bitmap.recycle() }
            } finally { reader.release() }
        } finally { source.delete() }
    }
}
