package org.rombooter

import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.compose.ui.geometry.Offset
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.EOFException
import java.io.IOException
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.math.BigInteger
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.SecretKeySpec

/**
 * RFB failure with a message meant for the user. [handshake] = the server never got to the desktop.
 * [rejected] = the server refused us (blacklist, wrong or unset password): reconnecting to the same
 * server cannot help, restarting the session can.
 */
class RfbException(
    message: String, val handshake: Boolean, cause: Throwable? = null, val rejected: Boolean = false
) : IOException(message, cause)

/**
 * Minimal RFB 3.3/3.8 client for the loopback VNC server (TigerVNC Xvnc or wayvnc):
 * VncAuth (or None), Raw + CopyRect, DesktopSize.
 * Raw over loopback is fine for a phone-sized desktop; add Tight/ZRLE later if CPU matters.
 */
class RfbClient(private val password: String, private val port: Int = 5901) {

    @Volatile var bitmap: Bitmap? = null; private set
    private val _frames = MutableStateFlow(0)
    val frames: StateFlow<Int> = _frames

    @Volatile private var sock: Socket? = null
    private val outbox = Channel<ByteArray>(Channel.UNLIMITED)
    private var px = 0
    private var py = 0
    private var stage = "connect"

    /** Blocks until the connection ends. [onReady] fires after the handshake (first frame follows). */
    suspend fun run(onReady: () -> Unit) = withContext(Dispatchers.IO) {
        val s = Socket().also { sock = it }
        try {
            s.tcpNoDelay = true
            s.connect(InetSocketAddress("127.0.0.1", port), 3000)
            s.soTimeout = 15_000 // a server that stops talking mid-handshake must not hang the UI
            val inp = DataInputStream(BufferedInputStream(s.getInputStream(), 1 shl 16))
            val os = BufferedOutputStream(s.getOutputStream())
            try {
                handshake(inp, os)
            } catch (e: RfbException) {
                throw e
            } catch (e: EOFException) {
                // The old "java.io.EOFException": server accepted the socket and hung up. During
                // authentication that means the server has no usable password (empty passwd file).
                throw RfbException("VNC server closed the connection during $stage", true, e,
                    rejected = stage == "VNC authentication")
            } catch (e: IOException) {
                throw RfbException("VNC handshake failed during $stage: ${e.message ?: e.javaClass.simpleName}", true, e)
            }
            s.soTimeout = 0
            onReady()
            coroutineScope {
                val writer = launch { for (m in outbox) { os.write(m); os.flush() } }
                try { readLoop(inp) } finally { writer.cancel() }
            }
        } finally {
            runCatching { s.close() }
        }
    }

    fun close() { runCatching { sock?.close() } }

    // ---------- handshake ----------
    private fun OutputStream.sendNow(b: ByteArray) { write(b); flush() }

    private fun handshake(inp: DataInputStream, os: OutputStream) {
        stage = "protocol version"
        val ver = String(ByteArray(12).also { inp.readFully(it) }, Charsets.US_ASCII)
        val m = Regex("""RFB (\d{3})\.(\d{3})\n""").matchEntire(ver)
            ?: throw RfbException("Not a VNC server on port $port", true)
        val v33 = m.groupValues[1].toInt() == 3 && m.groupValues[2].toInt() < 7
        os.sendNow((if (v33) "RFB 003.003\n" else "RFB 003.008\n").toByteArray(Charsets.US_ASCII))

        stage = "security negotiation"
        val type = if (v33) {
            inp.readInt().also { if (it == 0) throw refused(reason(inp)) }
        } else {
            val n = inp.readUnsignedByte()
            if (n == 0) throw refused(reason(inp))
            val types = ByteArray(n).also { inp.readFully(it) }
            when {
                types.contains(2.toByte()) -> 2                                           // Xvnc
                types.contains(SEC_APPLE_DH.toByte()) && password.isNotEmpty() -> SEC_APPLE_DH // wayvnc with a password
                types.contains(1.toByte()) -> 1
                else -> throw RfbException("No supported VNC security type (server offers ${types.joinToString()})", true)
            }.also { os.sendNow(byteArrayOf(it.toByte())) }
        }
        when (type) {
            2 -> {
                stage = "VNC authentication"
                if (password.isEmpty()) throw RfbException("Server requires a VNC password", true, rejected = true)
                os.sendNow(vncAuth(ByteArray(16).also { inp.readFully(it) }))
            }
            SEC_APPLE_DH -> {
                stage = "VNC authentication"
                appleDh(inp, os)
            }
            1 -> Unit
            else -> throw RfbException("Unsupported VNC security type $type", true)
        }
        if (type != 1 || !v33) {
            if (inp.readInt() != 0) {
                val why = if (v33) "" else runCatching { reason(inp) }.getOrDefault("")
                throw RfbException("VNC authentication failed" + if (why.isBlank()) "" else ": $why", true, rejected = true)
            }
        }

        stage = "server init"
        os.sendNow(byteArrayOf(1)) // ClientInit: shared
        val w = inp.readUnsignedShort(); val h = inp.readUnsignedShort()
        inp.readFully(ByteArray(16))                                   // server pixel format
        val nameLen = inp.readInt()
        if (nameLen !in 0..4096) throw RfbException("Bad server init (name length $nameLen)", true)
        inp.readFully(ByteArray(nameLen))                              // desktop name
        bitmap = newBitmap(w, h)

        // SetPixelFormat: 32bpp, depth 24, little-endian, true colour, R<<16 G<<8 B
        os.sendNow(ByteBuffer.allocate(20).apply {
            put(0); put(0); put(0); put(0)
            put(32); put(24); put(0); put(1)
            putShort(255); putShort(255); putShort(255)
            put(16); put(8); put(0); put(0); put(0); put(0)
        }.array())
        // SetEncodings: CopyRect(1), Raw(0), DesktopSize(-223)
        os.sendNow(ByteBuffer.allocate(16).apply {
            put(2); put(0); putShort(3); putInt(1); putInt(0); putInt(ENC_DESKTOP_SIZE)
        }.array())
        stage = "desktop"
    }

    /**
     * Zero security types. TigerVNC sends this with an EMPTY reason once it has blacklisted
     * 127.0.0.1 after repeated failed logins - the old bare "Server refused:" message.
     */
    private fun refused(reason: String) = RfbException(
        if (reason.isNotBlank()) "VNC server refused the connection: $reason"
        else "VNC server refused the connection (it blocks 127.0.0.1 for a while after repeated failed logins)",
        handshake = true, rejected = true
    )

    private fun reason(inp: DataInputStream): String {
        val n = inp.readInt()
        if (n !in 0..4096) return ""
        return String(ByteArray(n).also { inp.readFully(it) }, Charsets.UTF_8)
    }

    private fun newBitmap(w: Int, h: Int): Bitmap {
        if (w !in 1..8192 || h !in 1..8192) throw RfbException("Bad desktop size ${w}x$h", stage != "desktop")
        return Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
    }

    /**
     * Security type 30 (Apple Remote Desktop Diffie-Hellman): what wayvnc offers for user/password
     * logins without TLS. Shared secret -> MD5 -> AES-128-ECB over 64-byte user + 64-byte password.
     */
    private fun appleDh(inp: DataInputStream, os: OutputStream) {
        val g = inp.readUnsignedShort()
        val len = inp.readUnsignedShort()
        if (len !in 16..1024) throw RfbException("Bad Diffie-Hellman key length $len", true)
        val p = BigInteger(1, ByteArray(len).also { inp.readFully(it) })
        val serverKey = BigInteger(1, ByteArray(len).also { inp.readFully(it) })
        val rnd = SecureRandom()
        val priv = BigInteger(len * 8 - 1, rnd)
        val pub = fixedBytes(BigInteger.valueOf(g.toLong()).modPow(priv, p), len)
        val shared = fixedBytes(serverKey.modPow(priv, p), len)
        val key = MessageDigest.getInstance("MD5").digest(shared)
        val cred = ByteArray(128).also { rnd.nextBytes(it) }
        fun put(text: String, at: Int) {
            val b = text.toByteArray(Charsets.UTF_8).copyOf(minOf(text.toByteArray(Charsets.UTF_8).size, 63))
            b.copyInto(cred, at); cred[at + b.size] = 0
        }
        put(ARD_USER, 0); put(password, 64)
        val c = Cipher.getInstance("AES/ECB/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"))
        os.sendNow(c.doFinal(cred) + pub)
    }

    private fun fixedBytes(v: BigInteger, len: Int): ByteArray {
        val b = v.toByteArray()
        val n = minOf(b.size, len)
        return ByteArray(len).also { b.copyInto(it, len - n, b.size - n, b.size) }
    }

    private fun vncAuth(challenge: ByteArray): ByteArray {
        val pw = password.toByteArray(Charsets.ISO_8859_1)
        val key = ByteArray(8) { if (it < pw.size) reverseBits(pw[it]) else 0 }
        val c = Cipher.getInstance("DES/ECB/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "DES"))
        return c.doFinal(challenge)
    }

    private fun reverseBits(b: Byte): Byte {
        var x = b.toInt() and 0xFF; var r = 0
        repeat(8) { r = (r shl 1) or (x and 1); x = x shr 1 }
        return r.toByte()
    }

    // ---------- main loop ----------
    private fun readLoop(inp: DataInputStream) {
        var bmp = bitmap!!
        var canvas = Canvas(bmp)
        var buf = ByteArray(0)
        post(updateReq(false, bmp.width, bmp.height))
        while (true) {
            when (val t = inp.readUnsignedByte()) {
                0 -> {
                    inp.readUnsignedByte()
                    var resized = false
                    repeat(inp.readUnsignedShort()) {
                        val x = inp.readUnsignedShort(); val y = inp.readUnsignedShort()
                        val w = inp.readUnsignedShort(); val h = inp.readUnsignedShort()
                        val enc = inp.readInt()
                        if (enc == ENC_DESKTOP_SIZE) {
                            bmp = newBitmap(w, h); canvas = Canvas(bmp); bitmap = bmp; resized = true
                            return@repeat
                        }
                        if (x + w > bmp.width || y + h > bmp.height) {
                            throw RfbException("Server sent a rectangle outside the desktop", false)
                        }
                        when (enc) {
                            0 -> {
                                val n = w * h * 4
                                if (buf.size < n) buf = ByteArray(n)
                                inp.readFully(buf, 0, n)
                                val pix = IntArray(w * h)
                                ByteBuffer.wrap(buf, 0, n).order(ByteOrder.LITTLE_ENDIAN).asIntBuffer().get(pix)
                                for (i in pix.indices) pix[i] = pix[i] or -0x1000000
                                if (w > 0 && h > 0) bmp.setPixels(pix, 0, w, x, y, w, h)
                            }
                            1 -> {
                                val sx = inp.readUnsignedShort(); val sy = inp.readUnsignedShort()
                                if (w > 0 && h > 0 && sx + w <= bmp.width && sy + h <= bmp.height) {
                                    val tmp = Bitmap.createBitmap(bmp, sx, sy, w, h)
                                    canvas.drawBitmap(tmp, x.toFloat(), y.toFloat(), null)
                                    tmp.recycle()
                                }
                            }
                            else -> throw RfbException("Unsupported VNC encoding $enc", false)
                        }
                    }
                    _frames.update { it + 1 }
                    post(updateReq(!resized, bmp.width, bmp.height))
                }
                1 -> {    // SetColourMapEntries: not used with true colour, skip it
                    inp.readUnsignedByte(); inp.readUnsignedShort()
                    inp.readFully(ByteArray(inp.readUnsignedShort() * 6))
                }
                2 -> Unit // Bell
                3 -> {    // ServerCutText
                    inp.readFully(ByteArray(3))
                    val len = inp.readInt()
                    if (len !in 0..1_000_000) throw RfbException("Bad clipboard message", false)
                    inp.readFully(ByteArray(len))
                }
                else -> throw RfbException("Unexpected VNC server message $t", false)
            }
        }
    }

    // ---------- input (non-blocking, safe from the main thread) ----------
    private fun post(m: ByteArray) { outbox.trySend(m) }

    private fun updateReq(inc: Boolean, w: Int, h: Int) = ByteBuffer.allocate(10).apply {
        put(3); put((if (inc) 1 else 0).toByte()); putShort(0); putShort(0); putShort(w.toShort()); putShort(h.toShort())
    }.array()

    private fun pointerMsg(x: Int, y: Int, mask: Int) = ByteBuffer.allocate(6).apply {
        put(5); put(mask.toByte()); putShort(x.toShort()); putShort(y.toShort())
    }.array()

    private fun keyMsg(sym: Int, down: Boolean) = ByteBuffer.allocate(8).apply {
        put(4); put((if (down) 1 else 0).toByte()); putShort(0); putInt(sym)
    }.array()

    /** Where the remote mouse pointer is, in desktop pixels. */
    val cursor: Offset get() = Offset(px.toFloat(), py.toFloat())

    /** Pointer at desktop pixel [p]. mask: 1 = left, 2 = middle, 4 = right, 8/16 = wheel, 0 = none. */
    fun pointerAt(p: Offset, mask: Int) {
        val b = bitmap ?: return
        px = p.x.toInt().coerceIn(0, b.width - 1)
        py = p.y.toInt().coerceIn(0, b.height - 1)
        post(pointerMsg(px, py, mask))
    }

    fun clickAt(p: Offset, mask: Int) { pointerAt(p, mask); release() }
    fun release() = post(pointerMsg(px, py, 0))

    fun key(sym: Int) { post(keyMsg(sym, true)); post(keyMsg(sym, false)) }

    /** [sym] pressed while the modifier keysyms [mods] are held (Ctrl, Alt, Super). */
    fun key(sym: Int, mods: List<Int>) {
        mods.forEach { post(keyMsg(it, true)) }
        key(sym)
        mods.asReversed().forEach { post(keyMsg(it, false)) }
    }

    fun type(s: String) = s.codePoints().forEach { key(charSym(it)) }

    /** One scroll-wheel notch (buttons 4/5) at desktop pixel [p]. */
    fun scrollAt(p: Offset, up: Boolean) { pointerAt(p, if (up) 8 else 16); release() }

    companion object {
        private const val ENC_DESKTOP_SIZE = -223
        private const val SEC_APPLE_DH = 30
        /** wayvnc user name; rb-session writes the same into wayvnc's config. */
        const val ARD_USER = "rombooter"
        const val KEY_ESC = 0xFF1B
        const val KEY_TAB = 0xFF09
        const val KEY_ENTER = 0xFF0D
        const val KEY_BACKSPACE = 0xFF08
        const val KEY_DELETE = 0xFFFF
        const val KEY_INSERT = 0xFF63
        const val KEY_HOME = 0xFF50
        const val KEY_LEFT = 0xFF51
        const val KEY_UP = 0xFF52
        const val KEY_RIGHT = 0xFF53
        const val KEY_DOWN = 0xFF54
        const val KEY_PAGE_UP = 0xFF55
        const val KEY_PAGE_DOWN = 0xFF56
        const val KEY_END = 0xFF57
        const val KEY_F1 = 0xFFBE
        const val KEY_CTRL = 0xFFE3
        const val KEY_ALT = 0xFFE9
        const val KEY_SUPER = 0xFFEB

        /** X keysym for a Unicode code point (Latin-1 directly, everything else as 0x01000000 + cp). */
        fun charSym(cp: Int): Int = when {
            cp == '\n'.code || cp == '\r'.code -> KEY_ENTER
            cp == '\t'.code -> KEY_TAB
            cp == 0x08 -> KEY_BACKSPACE
            cp < 0x100 -> cp
            else -> 0x01000000 or cp
        }
    }
}
