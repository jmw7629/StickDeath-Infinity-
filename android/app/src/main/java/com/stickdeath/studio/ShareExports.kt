package com.stickdeath.studio

import android.content.ClipData
import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider
import java.io.File
import java.util.UUID

/** Only rendered artifacts enter the provider's narrow cache root. No project directory is exposed. */
object ShareExports {
    private const val CAPACITY = 256L * 1024 * 1024
    private const val LIFETIME = 24L * 60 * 60 * 1000
    @Synchronized fun stage(context: Context, artifact: ExportArtifact, check: () -> Unit): ExportArtifact {
        check()
        require(artifact.name == File(artifact.name).name && artifact.name.length in 1..120 && artifact.name !in listOf(".", ".."))
        require(artifact.file.isFile && artifact.file.length() in 1..CAPACITY) { "Export is unavailable or too large for sharing. Save it to Files instead." }
        val root = File(context.cacheDir, "studio-share").apply { require(isDirectory || mkdirs()) { "Share storage is unavailable." } }
        val now = System.currentTimeMillis()
        val owned = root.listFiles()?.filter { it.isDirectory && runCatching { UUID.fromString(it.name) }.isSuccess }.orEmpty()
        for (directory in owned) {
            check()
            if (now - directory.lastModified() >= LIFETIME) directory.deleteRecursively()
        }
        val remaining = root.listFiles()?.filter { it.isDirectory }.orEmpty()
        val bytes = remaining.sumOf { directory -> directory.listFiles()?.filter { it.isFile }?.sumOf { it.length() } ?: 0L }
        require(remaining.size < 8 && artifact.file.length() <= CAPACITY - bytes) { "Recent share copies fill the 256 MiB / eight-export limit. Save to Files; older copies expire on the next share after 24 hours." }
        val directory = File(root, UUID.randomUUID().toString())
        require(directory.mkdir()) { "Share staging could not be created." }
        var ready = false
        try {
            val file = File(directory, artifact.name)
            artifact.file.inputStream().use { input -> file.outputStream().use { output ->
                val buffer = ByteArray(64 * 1024)
                var copied = 0L
                while (true) {
                    check()
                    val count = input.read(buffer)
                    if (count < 0) break
                    require(count > 0 && copied + count <= CAPACITY - bytes) { "Shared export exceeds its limit." }
                    output.write(buffer, 0, count); copied += count
                }
                require(copied == artifact.file.length() && copied > 0) { "Export changed while preparing sharing." }
                output.flush()
            } }
            check(); ready = true
            return artifact.copy(file = file, share = true)
        } finally { if (!ready) directory.deleteRecursively() }
    }
    fun discard(artifact: ExportArtifact) {
        artifact.file.delete()
        if (artifact.share) artifact.file.parentFile?.delete() // only an empty owned directory
    }
    fun chooser(context: Context, artifact: ExportArtifact): Intent {
        require(artifact.share && artifact.file.isFile && artifact.file.length() > 0) { "Shared export is no longer available; render it again." }
        val uri = FileProvider.getUriForFile(context, context.packageName + ".exports", artifact.file)
        val mime = when (artifact.kind) {
            ExportKind.MP4 -> "video/mp4"
            ExportKind.GIF -> "image/gif"
            ExportKind.PNG -> "image/png"
            ExportKind.PROJECT, ExportKind.CREDITS -> "application/json"
            ExportKind.SEQUENCE, ExportKind.SPRITESHEET -> "application/zip"
        }
        val send = Intent(Intent.ACTION_SEND).apply {
            type = mime
            putExtra(Intent.EXTRA_STREAM, uri)
            clipData = ClipData.newUri(context.contentResolver, artifact.name, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        return Intent.createChooser(send, "Share rendered export").apply { addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION) }
    }
}
