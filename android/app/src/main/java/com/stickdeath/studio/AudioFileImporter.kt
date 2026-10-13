package com.stickdeath.studio

import android.content.Context
import android.net.Uri
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.ByteArrayOutputStream
import java.io.File

/** Files are normalized into project-owned PCM; no external URI survives import. */
object AudioFileImporter {
    private val imports = Mutex()
    suspend fun read(context: Context, uri: Uri, progress: suspend (String) -> Unit = {}): AudioSource = imports.withLock {
        require(uri.scheme == "content") { "Choose an audio file through Files." }
        val coroutine = currentCoroutineContext()
        val deadline = android.os.SystemClock.elapsedRealtime() + 30_000
        fun check() {
            coroutine.ensureActive()
            require(android.os.SystemClock.elapsedRealtime() <= deadline) { "Audio file read exceeded 30 seconds." }
        }
        progress("Reading selected audio file…")
        val bytes = ByteArrayOutputStream()
        context.contentResolver.openInputStream(uri)?.use { input ->
            val buffer = ByteArray(8192)
            while (true) {
                check()
                val count = input.read(buffer)
                if (count < 0) break
                require(count > 0 && bytes.size().toLong() + count <= AudioSource.MAX_BYTES) { "Choose an audio file up to 4 MiB." }
                bytes.write(buffer, 0, count)
            }
        } ?: error("Files could not open this audio file. Its permission may have expired.")
        check()
        val data = bytes.toByteArray()
        require(data.isNotEmpty()) { "The audio file is empty." }
        if (data.size >= 12 && String(data, 0, 4, Charsets.US_ASCII) == "RIFF" &&
            String(data, 8, 4, Charsets.US_ASCII) == "WAVE") {
            progress("Validating PCM audio…")
            return@withLock data.inputStream().use { AudioSource.read(it) }
        }
        val directory = File(context.cacheDir, "studio-audio-import").apply {
            require(isDirectory || mkdirs()) { "Audio staging storage is unavailable." }
        }
        directory.listFiles()?.filter { it.isFile && it.name.startsWith("source-") && it.name.endsWith(".partial") }?.forEach {
            check(); require(it.delete()) { "Previous audio staging could not be cleared." }
        }
        val file = File.createTempFile("source-", ".partial", directory)
        try {
            file.outputStream().use { it.write(data) }
            check()
            AudioDecoder.decode(setOf("audio/mp4a-latm", "audio/mpeg", "audio/flac", "audio/vorbis", "audio/opus"), progress) {
                it.setDataSource(file.absolutePath)
            }
        } finally { file.delete() }
    }
}
