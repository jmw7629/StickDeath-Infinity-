package com.stickdeath.studio.connect

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Shared, credential-free poster loader for the video wall (#217). */
internal val feedPosterLoader by lazy { FeedPosterLoader(UrlConnectionTransport()) }

/**
 * The poster frame the publishing worker recorded for this post, or a plain placeholder while it
 * loads, when none was recorded, or when it cannot be fetched or decoded. Nothing is generated.
 */
@Composable fun FeedPosterImage(post: FeedPost, loader: FeedPosterLoader = feedPosterLoader) {
    val poster by produceState<ImageBitmap?>(null, post.safePosterUrl, loader) {
        // A reused card must not display the previous URL while its new poster loads.
        value = null
        value = withContext(Dispatchers.IO) {
            loader.load(post)?.let { bytes -> decodeFeedPoster(bytes)?.asImageBitmap() }
        }
    }
    val modifier = Modifier.fillMaxWidth().height(180.dp)
    val image = poster
    if (image != null) {
        Image(image, contentDescription = "Poster for ${post.title.ifBlank { "Untitled" }}", modifier = modifier, contentScale = ContentScale.Crop)
    } else {
        Box(modifier.background(MaterialTheme.colorScheme.surfaceVariant), contentAlignment = Alignment.Center) {
            Text(if (post.safePosterUrl == null) "▶ No poster frame" else "▶")
        }
    }
}

/** Read dimensions without allocating pixels, then decode a bounded thumbnail. */
internal fun decodeFeedPoster(bytes: ByteArray): Bitmap? {
    if (!FeedPosterLoader.isCompleteJpeg(bytes)) return null
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    if (bounds.outMimeType != "image/jpeg") return null
    val sample = FeedPosterDecodePolicy.sampleSize(bounds.outWidth, bounds.outHeight) ?: return null
    val options = BitmapFactory.Options().apply {
        inSampleSize = sample
        inPreferredConfig = Bitmap.Config.ARGB_8888
        inScaled = false
    }
    return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
}
