package com.stickdeath.studio.connect

import android.graphics.Bitmap
import android.graphics.Color
import java.io.ByteArrayOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Exercises the actual Android decoder; requires an emulator/device. */
class FeedPosterDecodeTest {
    @Test fun actualJpegIsSampledWithoutChangingAspectRatio() {
        val original = Bitmap.createBitmap(2048, 1024, Bitmap.Config.ARGB_8888)
        val bytes = try {
            original.eraseColor(Color.RED)
            ByteArrayOutputStream().use { output ->
                assertTrue(original.compress(Bitmap.CompressFormat.JPEG, 80, output))
                output.toByteArray()
            }
        } finally { original.recycle() }
        assertTrue(bytes.size <= FeedPosterLoader.MAXIMUM_POSTER_BYTES)
        val thumbnail = decodeFeedPoster(bytes)
        assertNotNull(thumbnail)
        try {
            assertEquals(1024, thumbnail!!.width)
            assertEquals(512, thumbnail.height)
            assertTrue(thumbnail.allocationByteCount <= 4 * 1024 * 1024)
        } finally { thumbnail?.recycle() }
    }

    @Test fun invalidAndOverBudgetSourcesDoNotProduceBitmaps() {
        assertNull(decodeFeedPoster(byteArrayOf()))
        assertNull(decodeFeedPoster(byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xD9.toByte())))
        assertNull(decodeFeedPoster(ByteArray(FeedPosterLoader.MAXIMUM_POSTER_BYTES + 1)))
    }
}
