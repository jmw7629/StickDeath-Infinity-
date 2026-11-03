package com.stickdeath.studio.connect

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FeedPosterDecodePolicyTest {
    @Test fun malformedOrExcessiveDimensionsAreRejectedBeforePixelAllocation() {
        for ((width, height) in listOf(0 to 10, -1 to 100, 100 to 0,
            Int.MAX_VALUE to Int.MAX_VALUE, 65535 to 1, 4096 to 4096)) {
            assertNull("$width x $height", FeedPosterDecodePolicy.sampleSize(width, height))
        }
    }

    @Test fun portraitAndLandscapePostersHaveBoundedDecodedPixels() {
        assertEquals(1, FeedPosterDecodePolicy.sampleSize(320, 180))
        assertEquals(2, FeedPosterDecodePolicy.sampleSize(1080, 1920))
        assertEquals(4, FeedPosterDecodePolicy.sampleSize(4096, 1024))
        for ((width, height) in listOf(1 to 4096, 4096 to 1, 1080 to 1920,
            1920 to 1080, 2048 to 2048, 4096 to 1024)) {
            val sample = FeedPosterDecodePolicy.sampleSize(width, height)!!
            val decodedWidth = (width + sample - 1) / sample
            val decodedHeight = (height + sample - 1) / sample
            assertTrue(decodedWidth <= FeedPosterDecodePolicy.MAXIMUM_DECODED_EDGE)
            assertTrue(decodedHeight <= FeedPosterDecodePolicy.MAXIMUM_DECODED_EDGE)
            assertTrue(decodedWidth.toLong() * decodedHeight * 4 <= 4L * 1024 * 1024)
        }
    }
}
