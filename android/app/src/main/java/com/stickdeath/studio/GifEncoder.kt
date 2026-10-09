package com.stickdeath.studio

import java.io.OutputStream

/** Streaming GIF89a: opaque RGB332 palette, full frames, infinite loop, no dithering.
 * Literal LZW codes reset every 250 pixels, before the 9-bit dictionary can grow.
 * This intentionally trades compression for constant space and a small encoder.
 * Neither indexed frames nor the complete animation are buffered in memory.
 */
internal class GifEncoder(
    private val output: OutputStream,
    private val width: Int,
    private val height: Int,
    private val check: () -> Unit
) {
    private fun byte(value: Int) = output.write(value)
    private fun word(value: Int) { byte(value and 255); byte(value ushr 8 and 255) }
    private fun bytes(vararg values: Int) { values.forEach { byte(it) } }

    fun begin() {
        require(width in 1..65535 && height in 1..65535)
        check()
        output.write("GIF89a".toByteArray(Charsets.US_ASCII))
        word(width); word(height)
        bytes(0xf7, 0, 0) // Global 256-color table, 8-bit color resolution.
        for (index in 0..255) {
            byte(((index ushr 5) and 7) * 255 / 7)
            byte(((index ushr 2) and 7) * 255 / 7)
            byte((index and 3) * 255 / 3)
        }
        bytes(0x21, 0xff, 11)
        output.write("NETSCAPE2.0".toByteArray(Charsets.US_ASCII))
        bytes(3, 1, 0, 0, 0) // Repeat indefinitely.
    }

    fun frame(delayCentiseconds: Int, readRow: (Int, IntArray) -> Unit) {
        require(delayCentiseconds in 1..65535)
        check()
        bytes(0x21, 0xf9, 4, 4) // Disposal 1, no transparent palette index.
        word(delayCentiseconds); bytes(0, 0)
        byte(0x2c); word(0); word(0); word(width); word(height); byte(0)
        byte(8) // LZW minimum code size.
        val blocks = Blocks()
        var packed = 0
        var bits = 0
        fun code(value: Int) {
            packed = packed or (value shl bits)
            bits += 9
            while (bits >= 8) {
                blocks.add(packed and 255)
                packed = packed ushr 8
                bits -= 8
            }
        }
        code(256) // Clear; dictionary literals 0..255, clear 256, end 257.
        var literals = 0
        val row = IntArray(width)
        for (y in 0 until height) {
            check(); readRow(y, row)
            for (color in row) {
                if (literals == 250) { code(256); literals = 0 }
                // Nearest palette component; both black and white are exact.
                val r = (((color ushr 16) and 255) * 7 + 127) / 255
                val g = (((color ushr 8) and 255) * 7 + 127) / 255
                val b = ((color and 255) * 3 + 127) / 255
                code((r shl 5) or (g shl 2) or b)
                literals++
            }
        }
        code(257)
        if (bits > 0) blocks.add(packed and 255)
        blocks.flush(); byte(0) // Image-data terminator.
        check()
    }

    fun finish() { check(); byte(0x3b); output.flush(); check() }

    private inner class Blocks {
        private val buffer = ByteArray(255)
        private var size = 0
        fun add(value: Int) {
            buffer[size++] = value.toByte()
            if (size == buffer.size) flush()
        }
        fun flush() {
            if (size == 0) return
            check(); byte(size); output.write(buffer, 0, size); size = 0
        }
    }
}
