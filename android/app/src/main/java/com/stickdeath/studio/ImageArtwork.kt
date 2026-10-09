package com.stickdeath.studio

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.ColorSpace
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.graphics.Paint
import android.os.Build
import android.util.Base64
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.nio.ByteBuffer
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.sqrt

/** Immutable project-owned normalized PNG and its bounded, shared rendering bitmap.
 * Never recycle a retained bitmap: documents, clipboard and export snapshots share it. */
class ImageArtwork private constructor(val encoded: String, val byteCount: Int, private val bitmap: Bitmap) {
    val width get() = bitmap.width
    val height get() = bitmap.height
    val pixels get() = width.toLong() * height
    fun corners(document: Document): List<Point> {
        val scale = minOf(1f, document.width * .8f / width, document.height * .8f / height)
        val w = width * scale; val h = height * scale
        val x = (document.width-w)/2; val y = (document.height-h)/2
        return listOf(Point(x,y), Point(x+w,y), Point(x+w,y+h), Point(x,y+h))
    }
    fun validateGeometry(stroke: Stroke) {
        val p = stroke.points
        require(p.size == 4 && stroke.color ushr 24 == 255)
        val a = (p[1].x-p[0].x)/width; val b = (p[1].y-p[0].y)/width
        val c = (p[3].x-p[0].x)/height; val d = (p[3].y-p[0].y)/height
        require(listOf(a,b,c,d).all { it.isFinite() && abs(it) <= 256f } && abs(a*d-b*c) in 0.000001f..65536f) { "Image transform is outside supported limits." }
        require(hypot(p[2].x-p[1].x-p[3].x+p[0].x,p[2].y-p[1].y-p[3].y+p[0].y) < .05f) { "Invalid image geometry." }
    }
    fun draw(canvas: Canvas, stroke: Stroke, appearance: Paint) {
        val p = stroke.points; val transform = Matrix()
        check(transform.setPolyToPoly(floatArrayOf(0f,0f,width.toFloat(),0f,0f,height.toFloat()),0,
            floatArrayOf(p[0].x,p[0].y,p[1].x,p[1].y,p[3].x,p[3].y),0,3))
        canvas.drawBitmap(bitmap,transform,Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG).apply { alpha = appearance.alpha })
    }
    companion object {
        const val MAX_BYTES = 1024 * 1024
        const val MAX_PIXELS = 1_048_576
        const val MAX_BASE64 = ((MAX_BYTES + 2) / 3) * 4
        private class BoundedOutput(private val limit: Int, private val check: () -> Unit) : ByteArrayOutputStream() {
            override fun write(b: ByteArray, off: Int, len: Int) { check(); require(count.toLong()+len <= limit) { "Image exceeds its encoded size limit." }; super.write(b,off,len) }
            override fun write(b: Int) { check(); require(count < limit) { "Image exceeds its encoded size limit." }; super.write(b) }
        }
        fun importImage(input: InputStream, check: () -> Unit): ImageArtwork {
            require(Build.VERSION.SDK_INT >= 28) { "Image import requires Android 9 or later." }
            val bytes = BoundedOutput(8 * 1024 * 1024,check)
            val buffer = ByteArray(8192)
            while (true) { check(); val n = input.read(buffer); if (n < 0) break; bytes.write(buffer,0,n) }
            check()
            // Platform ImageDecoder applies encoded EXIF orientation before returning pixels.
            val source = bytes.toByteArray()
            if (source.size >= 8 && source[0] == 137.toByte()) validatePNG(source)
            val decoded = ImageDecoder.decodeBitmap(ImageDecoder.createSource(ByteBuffer.wrap(source))) { decoder, info, _ ->
                check()
                require(info.mimeType in listOf("image/png", "image/jpeg")) { "Choose a still PNG or JPEG image. Other formats are not supported yet." }
                val w = info.size.width; val h = info.size.height
                require(w in 1..16384 && h in 1..16384 && w.toLong()*h <= 32_000_000L) { "Source image exceeds 32 megapixels or a 16,384-pixel edge." }
                val scale = minOf(1.0, 2048.0 / maxOf(w,h), sqrt(MAX_PIXELS.toDouble()/(w.toLong()*h)))
                decoder.setTargetSize(maxOf(1,(w*scale).toInt()),maxOf(1,(h*scale).toInt()))
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                decoder.setTargetColorSpace(ColorSpace.get(ColorSpace.Named.SRGB))
                decoder.setOnPartialImageListener { false }
            }
            try {
                check()
                require(decoded.width.toLong()*decoded.height <= MAX_PIXELS)
                val png = BoundedOutput(MAX_BYTES,check)
                require(decoded.compress(Bitmap.CompressFormat.PNG,100,png)) { "Image could not be normalized." }
                check()
                // Re-decode our PNG so imports and reopened backups use identical pixel data.
                return restore(Base64.encodeToString(png.toByteArray(),Base64.NO_WRAP)).also { check() }
            } finally { decoded.recycle() }
        }
        private fun validatePNG(bytes: ByteArray) {
            require(bytes.size >= 33 && bytes.take(8) == listOf(137,80,78,71,13,10,26,10).map { it.toByte() }) { "Invalid PNG signature." }
            fun number(offset: Int): Long = (0..3).fold(0L) { n, i -> (n shl 8) or (bytes[offset+i].toLong() and 255L) }
            var offset = 8; var hasPixels = false; var ended = false
            while (offset < bytes.size) {
                require(bytes.size-offset >= 12) { "Truncated PNG chunk." }
                val length = number(offset)
                require(length <= bytes.size-offset-12) { "Truncated PNG payload." }
                val count = length.toInt()
                val type = String(bytes,offset+4,4,Charsets.US_ASCII)
                require(type != "acTL") { "Animated PNG is not supported; choose a still PNG or JPEG." }
                if (offset == 8) require(type == "IHDR" && count == 13) { "Missing PNG header." }
                val crc = java.util.zip.CRC32().apply { update(bytes,offset+4,count+4) }.value
                require(crc == number(offset+8+count)) { "Damaged PNG data; no image was added." }
                if (type == "IDAT") hasPixels = true
                offset += count+12
                if (type == "IEND") { require(count == 0 && offset == bytes.size); ended = true; break }
            }
            require(ended && hasPixels) { "Incomplete PNG image." }
        }
        fun restore(encoded: String, remainingBytes: Long = MAX_BYTES.toLong(), remainingPixels: Long = MAX_PIXELS.toLong()): ImageArtwork {
            try {
            require(encoded.length in 1..MAX_BASE64) { "Stored image exceeds 1 MiB." }
            val bytes = Base64.decode(encoded,Base64.NO_WRAP)
            require(bytes.size <= remainingBytes && bytes.size in 24..MAX_BYTES && bytes.take(8) == listOf(137,80,78,71,13,10,26,10).map { it.toByte() }) { "Stored image must be a normalized PNG." }
            validatePNG(bytes)
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes,0,bytes.size,bounds)
            require(bounds.outWidth in 1..2048 && bounds.outHeight in 1..2048 && bounds.outWidth.toLong()*bounds.outHeight <= minOf(MAX_PIXELS.toLong(),remainingPixels)) { "Stored image exceeds the pixel limit." }
            val bitmap = BitmapFactory.decodeByteArray(bytes,0,bytes.size,BitmapFactory.Options().apply { inPreferredConfig = Bitmap.Config.ARGB_8888; inPreferredColorSpace = ColorSpace.get(ColorSpace.Named.SRGB) })
                ?: error("Stored image could not be decoded; original preserved.")
            return ImageArtwork(encoded,bytes.size,bitmap)
            } catch (_: OutOfMemoryError) { throw IllegalArgumentException("Not enough memory to decode this image; original preserved.") }
        }
    }
}
