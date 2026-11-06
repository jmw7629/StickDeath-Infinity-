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
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import androidx.compose.ui.platform.LocalView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.findViewTreeLifecycleOwner

/** Browsing and previewing never mutate the project; Add uses the ordinary image import transaction. */
@Composable fun BundledImageControls(vm: StudioViewModel, doc: Document, enabled: Boolean) {
    val context = LocalContext.current.applicationContext
    var images by remember { mutableStateOf<List<BundledImage>>(emptyList()) }
    var error by remember { mutableStateOf<String?>(null) }
    var loaded by remember { mutableStateOf(false) }
    var query by remember { mutableStateOf("") }
    var category by remember { mutableStateOf<String?>(null) }
    val collections = rememberLibraryCollections("images")
    var page by remember(query, category, collections.collection) { mutableIntStateOf(0) }
    val scope = rememberCoroutineScope()
    val packOperation by OptionalImagePacks.operation.collectAsState()
    var packs by remember { mutableStateOf<List<OptionalImagePacks.Status>>(emptyList()) }
    var packError by remember { mutableStateOf<String?>(null) }
    var packProgress by remember { mutableStateOf<String?>(null) }
    var inspectionEpoch by remember { mutableIntStateOf(0) }
    var showPacks by remember { mutableStateOf(false) }
    var removePack by remember { mutableStateOf<OptionalImagePacks.Pack?>(null) }
    var packJob by remember { mutableStateOf<Job?>(null) }
    val lifecycleOwner = LocalView.current.findViewTreeLifecycleOwner()
    var foreground by remember { mutableStateOf(lifecycleOwner?.lifecycle?.currentState?.isAtLeast(Lifecycle.State.STARTED) == true) }
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_START) foreground = true
            if (event == Lifecycle.Event.ON_STOP) { foreground = false; packJob?.cancel(); removePack = null }
        }
        lifecycleOwner?.lifecycle?.addObserver(observer)
        onDispose { lifecycleOwner?.lifecycle?.removeObserver(observer); packJob?.cancel() }
    }
    LaunchedEffect(context, packOperation?.id, packOperation?.busy) {
        val epoch = ++inspectionEpoch
        try {
            val bundled = BundledImages.load(context)
            try {
                packs = OptionalImagePacks.inspect(context) { message ->
                    withContext(Dispatchers.Main.immediate) { if (inspectionEpoch == epoch) packProgress = message }
                }
                packError = null
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { packs = emptyList(); packError = "Optional packs could not be checked. The 243 bundled images remain available." }
            images = bundled + packs.flatMap { it.images }; loaded = true
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) { error = failure.message ?: "Image library could not open." }
        finally { if (inspectionEpoch == epoch) packProgress = null }
    }
    Text(if (loaded) "Image library · ${images.size} available images" else "Image library")
    Text("Kenney · CC0. 243 images are bundled offline. Includes cartoon weapon props. Optional packs download only when you choose Install. Add copies artwork into this project.")
    TextButton({ showPacks = !showPacks }) { Text(if (showPacks) "Hide optional packs" else "Optional image packs") }
    packProgress?.let { Text(it) }
    if (showPacks) {
        Text("Six packs · 1,818 optional images. Removing a pack never removes project copies.")
        if (!BuildConfig.SDI_NETWORK_DECLARED) Text("Downloads are unavailable in this offline build. Installed packs can still be used or removed.")
        packError?.let { Text(it) }
        packs.forEach { status ->
            Text("${status.pack.title} · ${status.pack.entries.size} images · CC0")
            Text(if (packProgress != null) "Verification in progress" else status.problem ?: if (status.installed) "Installed and verified" else "Not installed")
            Row {
                if (status.installed) {
                    TextButton({ removePack = status.pack }, enabled = foreground && packProgress == null && packOperation?.busy != true && !vm.importingImage) { Text("Remove local pack") }
                } else if (status.problem == null) {
                    TextButton({
                        if (foreground && packOperation?.busy != true && packJob?.isActive != true) {
                            val packID = status.pack.id
                            packJob = scope.launch { OptionalImagePacks.install(context, packID) }
                        }
                    }, enabled = foreground && packProgress == null && enabled && !vm.importingImage && packOperation?.busy != true && BuildConfig.SDI_NETWORK_DECLARED) { Text("Install pack") }
                }
            }
        }
    }
    packOperation?.let { operation ->
        Text(operation.message)
        if (operation.busy) TextButton({ OptionalImagePacks.cancel(operation.id) }) { Text("Cancel image pack operation") }
    }
    removePack?.let { pack ->
        AlertDialog(onDismissRequest = { removePack = null }, title = { Text("Remove ${pack.title}?") },
            text = { Text("Remove only this downloaded library pack. Editable projects and artwork already copied into them stay unchanged. Downloading it again requires network access.") },
            confirmButton = { TextButton({
                removePack = null
                if (foreground && packOperation?.busy != true && packJob?.isActive != true) {
                    packJob = scope.launch { OptionalImagePacks.remove(context, pack.id) }
                }
            }) { Text("Remove local pack") } }, dismissButton = { TextButton({ removePack = null }) { Text("Cancel") } })
    }
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
    Row(Modifier.horizontalScroll(rememberScrollState())) {
        listOf("All", "Favorites", "Recent imports").forEach { name ->
            FilterChip(collections.collection == name, { collections.collection = name }, { Text(name) }, enabled = name == "All" || collections.ready)
        }
    }
    collections.error?.let { Text(it) }
    if (collections.collection == "Recent imports") TextButton({ collections.clearRecent() }, enabled = collections.ready && !collections.busy) { Text("Clear recent imports") }
    val matches = remember(images, query, category, collections.collection, collections.snapshot) {
        val terms = query.trim().lowercase().split(Regex("\\s+")).filter { it.isNotEmpty() }
        val filtered = images.filter { image ->
            (category == null || category == image.category) && terms.all { term ->
                (image.title + " " + image.author + " " + image.tags.joinToString(" ")).lowercase().contains(term)
            }
        }
        when (collections.collection) {
            "Favorites" -> filtered.filter { it.id in collections.snapshot.favorites }
            "Recent imports" -> { val byID = filtered.associateBy { it.id }; collections.snapshot.recent.mapNotNull { byID[it] } }
            else -> filtered
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
        TextButton({ collections.toggle(image.id) }, enabled = collections.ready && !collections.busy) {
            Text(if (image.id in collections.snapshot.favorites) "Remove favorite" else "Favorite")
        }
        TextButton({ credits = !credits }) { Text(if (credits) "Hide source" else "Source and license") }
        if (credits) Text("Art by ${image.author}\n${image.sourceURL}\nCC0-1.0 · https://creativecommons.org/publicdomain/zero/1.0/")
    } }
    Row {
        TextButton({ page = actualPage - 1 }, enabled = actualPage > 0) { Text("Previous images") }
        TextButton({ page = actualPage + 1 }, enabled = actualPage + 1 < pages) { Text("Next images") }
    }
}
