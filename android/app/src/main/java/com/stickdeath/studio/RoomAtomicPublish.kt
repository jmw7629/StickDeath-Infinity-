package com.stickdeath.studio

import androidx.annotation.Keep
import java.io.File
import java.io.IOException
import java.nio.file.FileAlreadyExistsException

/** One atomic, no-replace namespace operation for a fully synced, journal-bound private inode.
 * Android apps cannot use hard links. Files.move(ATOMIC_MOVE) does not promise no replacement.
 * The tiny packaged libc-only adapter fails closed when the kernel/filesystem cannot do this. */
@Keep
internal object RoomAtomicPublish {
    private val library = runCatching { System.loadLibrary("sdi_storage") }

    fun commit(stage: File, target: File) {
        require(stage.isAbsolute && target.isAbsolute && stage != target &&
            '\u0000' !in stage.path && '\u0000' !in target.path) { "Invalid private import paths." }
        library.getOrElse { throw IOException("Atomic room import is unavailable on this device. The private stage is retained.", it) }
        when (val error = renameNoReplace(stage.path, target.path)) {
            0 -> return
            android.system.OsConstants.EEXIST -> throw FileAlreadyExistsException(target.path, null,
                "The project identity is occupied. Nothing was overwritten.")
            else -> throw IOException("Atomic room import could not commit (errno $error). The private stage is retained.")
        }
    }

    @JvmStatic private external fun renameNoReplace(source: String, destination: String): Int
}
