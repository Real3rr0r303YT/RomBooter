package org.rombooter

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isAltPressed
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.isMetaPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.pointer.PointerInputScope
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import kotlin.math.abs
import kotlin.math.max

/**
 * Touch-first desktop view (postmarketOS style): the desktop fills the screen, all controls live in
 * a bar at the bottom (nothing covers the windows' title bars), the Android keyboard forwards every
 * keystroke live, and fingers work either directly on the desktop or like a touchpad.
 */
@Composable
fun VncScreen(client: RfbClient, onStop: () -> Unit, onSupport: () -> Unit) {
    val mods = remember { StickyMods() }
    val viewport = remember { Viewport() }
    val focus = remember { FocusRequester() }
    val ime = LocalSoftwareKeyboardController.current
    var bar by rememberSaveable { mutableStateOf(true) }
    var touchpad by rememberSaveable { mutableStateOf(false) }
    Column(Modifier.fillMaxSize()) {
        Box(Modifier.weight(1f).fillMaxWidth()) {
            VncCanvas(client, viewport, touchpad)
            if (!bar) {
                SmallFloatingActionButton(onClick = { bar = true }, modifier = Modifier.align(Alignment.BottomEnd).padding(8.dp)) {
                    Text("⌨")
                }
            }
        }
        if (bar) {
            Row(
                Modifier.fillMaxWidth()
                    .background(MaterialTheme.colorScheme.surfaceVariant)
                    .horizontalScroll(rememberScrollState())
                    .padding(horizontal = 4.dp, vertical = 2.dp),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                BarButton("⌨") { focus.requestFocus(); ime?.show() }
                FilterChip(
                    selected = touchpad, onClick = { touchpad = !touchpad },
                    label = { Text(if (touchpad) "🖱 Pad" else "☝ Touch") }
                )
                if (viewport.zoom > 1.01f) BarButton("1:1") { viewport.reset() }
                FilterChip(selected = mods.ctrl, onClick = { mods.ctrl = !mods.ctrl }, label = { Text("Ctrl") })
                FilterChip(selected = mods.alt, onClick = { mods.alt = !mods.alt }, label = { Text("Alt") })
                FilterChip(selected = mods.meta, onClick = { mods.meta = !mods.meta }, label = { Text("Super") })
                BAR_KEYS.forEach { (label, sym) -> BarButton(label) { client.key(sym, mods.take()) } }
                BarButton("☕", onSupport)
                BarButton("Stop", onStop)
                BarButton("⌄") { bar = false }
            }
        }
        ImeInput(client, mods, focus)
    }
}

@Composable
private fun BarButton(label: String, onClick: () -> Unit) {
    FilledTonalButton(onClick = onClick, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 0.dp)) {
        Text(label)
    }
}

/** Ctrl/Alt/Super from the bar: tapped once, they apply to the next key, then release. */
class StickyMods {
    var ctrl by mutableStateOf(false)
    var alt by mutableStateOf(false)
    var meta by mutableStateOf(false)

    fun take(): List<Int> {
        val held = ArrayList<Int>(3)
        if (ctrl) held.add(RfbClient.KEY_CTRL)
        if (alt) held.add(RfbClient.KEY_ALT)
        if (meta) held.add(RfbClient.KEY_SUPER)
        ctrl = false; alt = false; meta = false
        return held
    }
}

private val BAR_KEYS = listOf(
    "Esc" to RfbClient.KEY_ESC, "Tab" to RfbClient.KEY_TAB,
    "←" to RfbClient.KEY_LEFT, "↑" to RfbClient.KEY_UP,
    "↓" to RfbClient.KEY_DOWN, "→" to RfbClient.KEY_RIGHT,
    "Home" to RfbClient.KEY_HOME, "End" to RfbClient.KEY_END,
    "PgUp" to RfbClient.KEY_PAGE_UP, "PgDn" to RfbClient.KEY_PAGE_DOWN,
    "Del" to RfbClient.KEY_DELETE, "⌫" to RfbClient.KEY_BACKSPACE, "⏎" to RfbClient.KEY_ENTER
)

/**
 * Zoom and pan of the desktop inside the view, and the mapping between finger positions (view
 * pixels) and desktop pixels. Zoom 1 = the whole desktop fits the view.
 */
class Viewport {
    var zoom by mutableFloatStateOf(1f)
        private set
    var pan by mutableStateOf(Offset.Zero)
        private set

    fun scale(view: IntSize, fb: IntSize) =
        minOf(view.width.toFloat() / fb.width, view.height.toFloat() / fb.height) * zoom

    private fun centered(view: IntSize, fb: IntSize, s: Float) =
        Offset((view.width - fb.width * s) / 2f, (view.height - fb.height * s) / 2f)

    /** Top-left corner of the desktop in view pixels. */
    fun origin(view: IntSize, fb: IntSize): Offset = centered(view, fb, scale(view, fb)) + pan

    fun toDesktop(p: Offset, view: IntSize, fb: IntSize): Offset = (p - origin(view, fb)) / scale(view, fb)

    /** Zoom by [factor] around [focus] (view pixels): the desktop point under the fingers stays put. */
    fun zoomBy(factor: Float, focus: Offset, view: IntSize, fb: IntSize) {
        val anchor = toDesktop(focus, view, fb)
        zoom = (zoom * factor).coerceIn(1f, MAX_ZOOM)
        val s = scale(view, fb)
        pan = focus - anchor * s - centered(view, fb, s)
        clamp(view, fb)
    }

    fun panBy(delta: Offset, view: IntSize, fb: IntSize) { pan += delta; clamp(view, fb) }

    fun reset() { zoom = 1f; pan = Offset.Zero }

    /** The desktop may move only as far as its edges reach the view's edges. */
    private fun clamp(view: IntSize, fb: IntSize) {
        val s = scale(view, fb)
        val mx = max(0f, (fb.width * s - view.width) / 2f)
        val my = max(0f, (fb.height * s - view.height) / 2f)
        pan = Offset(pan.x.coerceIn(-mx, mx), pan.y.coerceIn(-my, my))
    }

    private companion object { const val MAX_ZOOM = 5f }
}

/** What the hidden text field holds, so a backspace on "empty" input is still visible to us. */
private const val SENTINEL = "  "

/**
 * Invisible text field that receives the Android keyboard: every character is forwarded to the
 * desktop immediately. Password type keeps the IME from composing words.
 */
@Composable
private fun ImeInput(client: RfbClient, mods: StickyMods, focus: FocusRequester) {
    var value by remember { mutableStateOf(TextFieldValue(SENTINEL, TextRange(SENTINEL.length))) }
    BasicTextField(
        value = value,
        onValueChange = { nv ->
            val t = nv.text
            when {
                t.length < SENTINEL.length && SENTINEL.startsWith(t) ->
                    repeat(SENTINEL.length - t.length) { client.key(RfbClient.KEY_BACKSPACE, mods.take()) }
                t.startsWith(SENTINEL) ->
                    t.substring(SENTINEL.length).codePoints().forEach { client.key(RfbClient.charSym(it), mods.take()) }
                else -> Unit // the IME rewrote the field (rare with a password keyboard): nothing to forward
            }
            value = TextFieldValue(SENTINEL, TextRange(SENTINEL.length))
        },
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.None),
        modifier = Modifier.size(1.dp).alpha(0f).focusRequester(focus)
            .onPreviewKeyEvent { hardwareKey(client, mods, it) }
    )
}

/** Hardware keyboards and IMEs that send key events: special keys and Ctrl/Alt/Meta shortcuts. */
private fun hardwareKey(client: RfbClient, mods: StickyMods, e: KeyEvent): Boolean {
    val special = specialSym(e.key)
    if (e.type != KeyEventType.KeyDown) return special != null   // swallow the matching key-up
    val held = ArrayList<Int>(3)
    if (e.isCtrlPressed) held.add(RfbClient.KEY_CTRL)
    if (e.isAltPressed) held.add(RfbClient.KEY_ALT)
    if (e.isMetaPressed) held.add(RfbClient.KEY_SUPER)
    if (special != null) {
        client.key(special, held + mods.take()); return true
    }
    if (held.isNotEmpty()) {
        // Ctrl+C & co. never reach onValueChange as text: send the key's base character
        val cp = e.nativeKeyEvent.getUnicodeChar(0)
        if (cp > 0) { client.key(RfbClient.charSym(cp), held + mods.take()); return true }
    }
    return false // plain characters arrive through onValueChange
}

private fun specialSym(k: Key): Int? = when (k) {
    Key.DirectionLeft -> RfbClient.KEY_LEFT
    Key.DirectionRight -> RfbClient.KEY_RIGHT
    Key.DirectionUp -> RfbClient.KEY_UP
    Key.DirectionDown -> RfbClient.KEY_DOWN
    Key.MoveHome -> RfbClient.KEY_HOME
    Key.MoveEnd -> RfbClient.KEY_END
    Key.PageUp -> RfbClient.KEY_PAGE_UP
    Key.PageDown -> RfbClient.KEY_PAGE_DOWN
    Key.Escape -> RfbClient.KEY_ESC
    Key.Tab -> RfbClient.KEY_TAB
    Key.Backspace -> RfbClient.KEY_BACKSPACE
    Key.Delete -> RfbClient.KEY_DELETE
    Key.Enter, Key.NumPadEnter -> RfbClient.KEY_ENTER
    Key.Insert -> RfbClient.KEY_INSERT
    Key.F1 -> RfbClient.KEY_F1
    Key.F2 -> RfbClient.KEY_F1 + 1
    Key.F3 -> RfbClient.KEY_F1 + 2
    Key.F4 -> RfbClient.KEY_F1 + 3
    Key.F5 -> RfbClient.KEY_F1 + 4
    Key.F6 -> RfbClient.KEY_F1 + 5
    Key.F7 -> RfbClient.KEY_F1 + 6
    Key.F8 -> RfbClient.KEY_F1 + 7
    Key.F9 -> RfbClient.KEY_F1 + 8
    Key.F10 -> RfbClient.KEY_F1 + 9
    Key.F11 -> RfbClient.KEY_F1 + 10
    Key.F12 -> RfbClient.KEY_F1 + 11
    else -> null
}

@Composable
private fun VncCanvas(client: RfbClient, viewport: Viewport, touchpad: Boolean) {
    val tick by client.frames.collectAsState()
    var box by remember { mutableStateOf(IntSize.Zero) }
    val mode = rememberUpdatedState(touchpad)
    Canvas(
        Modifier.fillMaxSize()
            .onSizeChanged { box = it }
            .pointerInput(client) { desktopGestures(client, viewport) { mode.value } }
    ) {
        tick // subscribe to frame updates
        val bmp = client.bitmap ?: return@Canvas
        val fb = IntSize(bmp.width, bmp.height)
        val s = viewport.scale(box, fb)
        val o = viewport.origin(box, fb)
        drawImage(
            bmp.asImageBitmap(),
            dstOffset = IntOffset(o.x.toInt(), o.y.toInt()),
            dstSize = IntSize((bmp.width * s).toInt(), (bmp.height * s).toInt()),
            filterQuality = if (viewport.zoom > 1.01f) FilterQuality.Medium else FilterQuality.Low
        )
    }
}

private enum class Gesture { Tap, LongPress, Move, TwoFinger }

/**
 * Fingers on the desktop.
 *  Touch mode (default): tap = left click where the finger is, long press = right click there,
 *    drag = drag with the left button.
 *  Touchpad mode: drag moves the pointer relatively (precise on tiny widgets), tap = left click at
 *    the pointer, long press = right click, long press then drag = drag with the left button.
 *  Both: two-finger swipe = scroll wheel (pans instead while zoomed), pinch = zoom,
 *    two-finger tap = right click.
 */
private suspend fun PointerInputScope.desktopGestures(client: RfbClient, vp: Viewport, touchpad: () -> Boolean) {
    val scrollStep = 24.dp.toPx()
    awaitEachGesture {
        val first = awaitFirstDown(requireUnconsumed = false)
        val start = first.position
        val t0 = first.uptimeMillis
        val pad = touchpad()
        var gesture = Gesture.LongPress
        withTimeoutOrNull(viewConfiguration.longPressTimeoutMillis) {
            while (true) {
                val pressed = awaitPointerEvent().changes.filter { it.pressed }
                if (pressed.isEmpty()) { gesture = Gesture.Tap; break }
                if (pressed.size > 1) { gesture = Gesture.TwoFinger; break }
                if ((pressed[0].position - start).getDistance() > viewConfiguration.touchSlop) {
                    gesture = Gesture.Move; break
                }
            }
        }
        val b = client.bitmap ?: return@awaitEachGesture
        val fb = IntSize(b.width, b.height)
        fun desk(p: Offset) = vp.toDesktop(p, size, fb)
        // Relative pointer movement for touchpad mode, in desktop pixels
        fun moveCursor(delta: Offset, mask: Int) = client.pointerAt(client.cursor + delta / vp.scale(size, fb), mask)

        when (gesture) {
            Gesture.Tap -> if (pad) client.clickAt(client.cursor, 1) else client.clickAt(desk(start), 1)
            Gesture.Move -> {
                // touch: drag with the left button; touchpad: move the pointer
                var last = start
                if (!pad) client.pointerAt(desk(start), 1)
                while (true) {
                    val ev = awaitPointerEvent()
                    val p = ev.changes.firstOrNull { it.pressed } ?: break
                    if (pad) moveCursor(p.position - last, 0) else client.pointerAt(desk(p.position), 1)
                    last = p.position
                    ev.changes.forEach { it.consume() }
                }
                if (!pad) client.release()
            }
            Gesture.LongPress -> {
                // Still finger: right click on release; moving after the long press drags (touchpad)
                var last = start
                var dragging = false
                while (true) {
                    val ev = awaitPointerEvent()
                    val p = ev.changes.firstOrNull { it.pressed } ?: break
                    if (!dragging && (p.position - start).getDistance() > viewConfiguration.touchSlop) {
                        dragging = true
                        if (pad) client.pointerAt(client.cursor, 1) else client.pointerAt(desk(start), 1)
                    }
                    if (dragging) {
                        if (pad) moveCursor(p.position - last, 1) else client.pointerAt(desk(p.position), 1)
                    }
                    last = p.position
                    ev.changes.forEach { it.consume() }
                }
                when {
                    dragging -> client.release()
                    pad -> client.clickAt(client.cursor, 4)
                    else -> client.clickAt(desk(start), 4)
                }
            }
            Gesture.TwoFinger -> {
                var acc = 0f
                var lastCentroid: Offset? = null
                var lastSpan = 0f
                var startSpan = 0f
                var zooming = false
                var used = false
                while (true) {
                    val ev = awaitPointerEvent()
                    val pressed = ev.changes.filter { it.pressed }
                    if (pressed.size < 2) {
                        if (pressed.isEmpty()) break else { ev.changes.forEach { it.consume() }; continue }
                    }
                    val c = Offset(pressed.map { it.position.x }.average().toFloat(), pressed.map { it.position.y }.average().toFloat())
                    val span = (pressed[0].position - pressed[1].position).getDistance()
                    val prev = lastCentroid
                    if (prev == null) {
                        startSpan = span; lastSpan = span
                    } else {
                        if (!zooming && abs(span - startSpan) > viewConfiguration.touchSlop * 2) zooming = true
                        if (zooming) {
                            if (lastSpan > 0f) vp.zoomBy(span / lastSpan, c, size, fb)
                            vp.panBy(c - prev, size, fb)
                            used = true
                        } else if (vp.zoom > 1.01f) {
                            vp.panBy(c - prev, size, fb)          // zoomed: two fingers move the view
                            used = true
                        } else {
                            acc += c.y - prev.y
                            // Fingers moving down pull the content down, like scrolling on the phone
                            while (acc >= scrollStep) { client.scrollAt(desk(c), up = true); acc -= scrollStep; used = true }
                            while (acc <= -scrollStep) { client.scrollAt(desk(c), up = false); acc += scrollStep; used = true }
                        }
                        lastSpan = span
                    }
                    lastCentroid = c
                    ev.changes.forEach { it.consume() }
                }
                // Two-finger tap = right click
                val c = lastCentroid
                if (!used && c != null && currentEvent.changes.firstOrNull()?.let { it.uptimeMillis - t0 < 400 } == true) {
                    if (pad) client.clickAt(client.cursor, 4) else client.clickAt(desk(c), 4)
                }
            }
        }
    }
}
