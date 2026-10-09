package com.stickdeath.studio

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

/** Browsing and previewing never mutate the project; Add uses the ordinary image import transaction. */
@Composable fun BundledImageControls(vm: StudioViewModel, doc: Document, enabled: Boolean) {
    val context = LocalContext.current.applicationContext
    var images by remember { mutableStateOf<List<BundledImage>>(emptyList()) }
    var error by remember { mutableStateOf<String?>(null) }
    var loaded by remember { mutableStateOf(false) }
    var query by remember { mutableStateOf("") }
    var category by remember { mutableStateOf<String?>(null) }
    var page by remember(query, category) { mutableIntStateOf(0) }
    LaunchedEffect(context) {
        try { images = BundledImages.load(context); loaded = true }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) { error = failure.message ?: "Image library could not open." }
    }
    Text(if (loaded) "Image library · ${images.size} bundled images" else "Image library")
    Text("Kenney · CC0 · offline. Includes cartoon weapon props. Add copies an image into this project.")
    if (vm.message.isNotEmpty()) Text(vm.message)
    if (vm.importingImage) {
        Text("Preparing image for this project…")
        TextButton({ vm.cancelImageImport() }) { Text("Cancel image import") }
    }
    error?.let { Text(it) }
    if (!loaded && error == null) Text("Loading image catalogue…")
    OutlinedTextField(query, { query = it.take(120) }, label = { Text("Search images, tags or creators") }, singleLine = true)
    Row(Modifier.horizontalScroll(rememberScrollState())) {
        FilterChip(category == null, { category = null }, { Text("All") })
        images.map { it.category }.distinct().sorted().forEach { name ->
            FilterChip(category == name, { category = name }, { Text(name) })
        }
    }
    val matches = remember(images, query, category) {
        val terms = query.trim().lowercase().split(Regex("\\s+")).filter { it.isNotEmpty() }
        images.filter { image ->
            (category == null || category == image.category) && terms.all { term ->
                (image.title + " " + image.author + " " + image.tags.joinToString(" ")).lowercase().contains(term)
            }
        }
    }
    val pages = maxOf(1, (matches.size + 11) / 12)
    val actualPage = page.coerceIn(0, pages - 1)
    if (loaded) Text("${matches.size} matching images · page ${actualPage + 1}/$pages")
    matches.drop(actualPage * 12).take(12).forEach { image -> key(image.id) {
        var preview by remember { mutableStateOf<ImageBitmap?>(null) }
        var previewError by remember { mutableStateOf<String?>(null) }
        var credits by remember { mutableStateOf(false) }
        LaunchedEffect(context, image.id) {
            try {
                preview = withContext(Dispatchers.IO) {
                    val coroutine = currentCoroutineContext()
                    BundledImages.thumbnail(context, image) { coroutine.ensureActive() }.asImageBitmap()
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) { previewError = failure.message ?: "Image preview unavailable." }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            val bitmap = preview
            if (bitmap != null) Image(bitmap, image.title, Modifier.size(72.dp).background(Color.White), contentScale = ContentScale.Fit)
            Column(Modifier.weight(1f)) {
                Text(image.title)
                Text("${image.category} · ${image.width} × ${image.height} · ${image.author} · CC0")
                if (bitmap == null) Text(previewError ?: "Loading preview…")
            }
        }
        TextButton({ vm.addBundledImage(doc, image) }, enabled = enabled && !vm.importingImage) { Text("Add to project") }
        TextButton({ credits = !credits }) { Text(if (credits) "Hide source" else "Source and license") }
        if (credits) Text("Art by ${image.author}\n${image.sourceURL}\nCC0-1.0 · https://creativecommons.org/publicdomain/zero/1.0/")
    } }
    Row {
        TextButton({ page = actualPage - 1 }, enabled = actualPage > 0) { Text("Previous images") }
        TextButton({ page = actualPage + 1 }, enabled = actualPage + 1 < pages) { Text("Next images") }
    }
}
