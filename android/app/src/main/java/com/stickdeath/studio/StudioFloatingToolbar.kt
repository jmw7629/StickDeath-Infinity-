package com.stickdeath.studio

import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import kotlin.math.roundToInt

/** A single canvas overlay. Only its handle moves the rail; tools retain their ordinary gestures. */
@Composable fun StudioFloatingToolbar(content: @Composable () -> Unit) {
    var dock by rememberSaveable { mutableStateOf("floating") }
    var centerX by rememberSaveable { mutableFloatStateOf(.5f) }
    var centerY by rememberSaveable { mutableFloatStateOf(.05f) }
    var collapsed by rememberSaveable { mutableStateOf(false) }
    var measured by remember { mutableStateOf(IntSize.Zero) }
    var dragging by remember { mutableStateOf(false) }
    var draft by remember { mutableStateOf(Offset.Zero) }
    var menu by remember { mutableStateOf(false) }
    val density = LocalDensity.current
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val viewportWidth = with(density) { maxWidth.toPx() }
        val viewportHeight = with(density) { maxHeight.toPx() }
        val edge = with(density) { 40.dp.toPx() }
        val vertical = dock != "floating"
        val width = measured.width.toFloat()
        val height = measured.height.toFloat()
        fun clamp(position: Offset) = Offset(position.x.coerceIn(0f, (viewportWidth-width).coerceAtLeast(0f)),
            position.y.coerceIn(0f, (viewportHeight-height).coerceAtLeast(0f)))
        val resting = clamp(Offset(when (dock) {
            "left" -> 0f
            "right" -> viewportWidth-width
            else -> centerX*viewportWidth-width/2
        }, centerY*viewportHeight-height/2))
        val location = if (dragging) clamp(draft) else resting
        fun place(next: String) { dock = next; dragging = false; menu = false }
        fun reset() { dock = "floating"; centerX = .5f; centerY = .05f; collapsed = false; dragging = false; menu = false }
        // Viewport changes invalidate only a transient drag; saved normalized position remains usable.
        LaunchedEffect(viewportWidth, viewportHeight) { dragging = false }
        MaterialTheme(colorScheme = lightColorScheme(primary = Color(0xffdc2626), surface = Color.White,
            onSurface = Color(0xff17171b)), typography = MaterialTheme.typography) {
            Surface(Modifier.offset { IntOffset(location.x.roundToInt(), location.y.roundToInt()) }
                .width(minOf(if (collapsed) 132.dp else if (vertical) 148.dp else 480.dp, maxWidth))
                .heightIn(max = minOf(if (vertical) 400.dp else if (collapsed) 48.dp else 104.dp, maxHeight))
                .onSizeChanged { measured = it }, shape = RoundedCornerShape(18.dp), shadowElevation = 8.dp,
                color = Color.White, contentColor = Color(0xff17171b)) {
                Column {
                    Box {
                        TextButton({ menu = true }, modifier = Modifier.fillMaxWidth().height(44.dp)
                            .semantics {
                                contentDescription = "Move Studio toolbar. Drag to reposition or open docking options."
                                customActions = listOf(
                                    CustomAccessibilityAction("Dock left") { place("left"); true },
                                    CustomAccessibilityAction("Dock right") { place("right"); true },
                                    CustomAccessibilityAction("Reset floating toolbar") { reset(); true },
                                    CustomAccessibilityAction(if (collapsed) "Expand toolbar" else "Collapse toolbar") { collapsed = !collapsed; true })
                            }
                            .pointerInput(viewportWidth, viewportHeight, width, height, dock) {
                                detectDragGestures(
                                    onDragStart = { menu = false; draft = resting; dragging = true },
                                    onDrag = { change, delta -> change.consume(); draft += delta },
                                    onDragCancel = { dragging = false },
                                    onDragEnd = {
                                        if (viewportWidth > 0 && viewportHeight > 0) {
                                            centerX = ((draft.x + width/2)/viewportWidth).coerceIn(0f, 1f)
                                            centerY = ((draft.y + height/2)/viewportHeight).coerceIn(0f, 1f)
                                            dock = when {
                                                (if (vertical) draft.x else draft.x + width/2) <= minOf(edge, viewportWidth/4) -> "left"
                                                (if (vertical) draft.x + width else draft.x + width/2) >= viewportWidth-minOf(edge, viewportWidth/4) -> "right"
                                                else -> "floating"
                                            }
                                        }
                                        dragging = false
                                    })
                            }) { Text(if (collapsed) "Tools ▾" else "⋮⋮ Move tools") }
                        DropdownMenu(menu, { menu = false }) {
                            DropdownMenuItem({ Text("Dock left") }, { place("left") })
                            DropdownMenuItem({ Text("Dock right") }, { place("right") })
                            DropdownMenuItem({ Text("Float horizontally") }, { place("floating") })
                            DropdownMenuItem({ Text(if (collapsed) "Expand" else "Collapse") }, { collapsed = !collapsed; menu = false })
                            DropdownMenuItem({ Text("Reset position") }, { reset() })
                        }
                    }
                    if (!collapsed) {
                        if (vertical) Column(Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState()).padding(horizontal = 4.dp)) { content() }
                        else Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 4.dp), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) { content() }
                    }
                }
            }
        }
    }
}
