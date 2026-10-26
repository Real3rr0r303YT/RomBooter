package org.rombooter

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import androidx.core.content.ContextCompat
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.resume

enum class Distro(val key: String, val label: String) {
    ARCH("arch", "Arch"), GENTOO("gentoo", "Gentoo"), DEBIAN("debian", "Debian"),
    UBUNTU("ubuntu", "Ubuntu"), ALPINE("alpine", "Alpine"), KALI("kali", "Kali"), FEDORA("fedora", "Fedora")
}

/**
 * Desktop session inside the distro, as registered by rb-provision in /etc/rombooter/sessions.
 * Wayland sessions run a headless wlroots compositor with wayvnc; [portrait] sessions are mobile
 * shells (postmarketOS style) and get a portrait framebuffer.
 */
enum class Session(val key: String, val label: String, val wayland: Boolean, val portrait: Boolean) {
    XFCE("xfce", "Xfce (touch-tuned)", false, false),
    PHOSH("phosh", "Phosh (mobile)", true, true),
    SWAY("sway", "Sway (full-screen apps)", true, false),
    I3("i3", "i3", false, false)
}

/** Outcome of start_<distro>.sh as reported back by Termux. */
data class ScriptResult(val exitCode: Int?, val stdout: String, val stderr: String, val errmsg: String) {
    val ok get() = exitCode == 0

    /** The distro has no (or only a 1.0.x) start script: the fix is running the bundled setup. */
    val needsSetup get() = exitCode == EXIT_NOT_SET_UP || exitCode == EXIT_OUTDATED

    /** Human-readable reason, keyed on the start script's exit codes. */
    fun describe(d: Distro): String {
        val detail = stderr.lineSequence().map { it.trim() }.lastOrNull { it.startsWith("ERROR:") }
            ?.removePrefix("ERROR:")?.trim()
            ?: stderr.trim().lines().takeLast(3).joinToString("\n").ifBlank { errmsg.ifBlank { stdout.trim() } }
        val what = when (exitCode) {
            1 -> "The ${d.label} session exited during startup"
            2 -> "start_${d.key}.sh rejected its arguments"
            3 -> "The ${d.label} desktop did not come up in time"
            EXIT_NOT_SET_UP -> "${d.label} is not set up in Termux yet. Tap \"Set up ${d.label}\""
            5 -> "Port ${TermuxLauncher.PORT} is used by another program"
            EXIT_OUTDATED -> "${d.label} was set up by an older RomBooter whose VNC password handling is broken " +
                "(\"closed the connection during VNC authentication\"). Tap \"Set up ${d.label}\" to update it"
            null -> "Termux could not run the RomBooter launcher" +
                if (errmsg.isNotBlank()) "" else " (is Termux set up and allow-external-apps = true?)"
            else -> "start_${d.key}.sh failed (exit $exitCode)"
        }
        // For the setup cases the launcher's own message only repeats ours
        return if (detail.isBlank() || needsSetup) what else "$what:\n$detail"
    }

    companion object {
        const val EXIT_NOT_SET_UP = 4
        const val EXIT_OUTDATED = 6
    }
}

/**
 * Runs RomBooter's scripts inside Termux via RUN_COMMAND.
 *
 * The app cannot write into Termux's private home, so it never calls ~/start_<distro>.sh directly
 * (that gave Termux error 150, "file not found", for every distro that was not set up). Instead
 * Termux runs bash with a small launcher from the app's assets (rb-launch.sh), which checks the
 * start script first. Setting a distro up runs the setup script bundled in the assets, in a
 * visible Termux session (rb-setup.sh writes it to ~/rombooter-setup.sh, chmod 700, runs it).
 */
object TermuxLauncher {
    const val PORT = 5901
    private const val HOME = "/data/data/com.termux/files/home"
    private const val BASH = "/data/data/com.termux/files/usr/bin/bash"
    private const val ACTION_RESULT = "org.rombooter.TERMUX_RESULT"
    private const val EXTRA_ID = "org.rombooter.REQUEST_ID"
    private val ids = AtomicInteger(1)

    fun isInstalled(ctx: Context): Boolean =
        runCatching { ctx.packageManager.getPackageInfo("com.termux", 0); true }.getOrDefault(false)

    fun startArgs(res: String, pass: String, session: Session, dpi: Int, restart: Boolean = false) =
        arrayOf("--res", res, "--pass", pass, "--de", session.key, "--dpi", dpi.toString()) +
            (if (restart) arrayOf("--restart") else emptyArray())

    /**
     * Runs start_<distro>.sh and suspends until Termux reports its exit status, or returns null
     * after [timeoutMs] (older Termux builds never report back; callers then rely on the port).
     */
    suspend fun start(
        ctx: Context, d: Distro, res: String, pass: String, session: Session, dpi: Int, timeoutMs: Long,
        restart: Boolean = false
    ): ScriptResult? = runForResult(ctx, d, startArgs(res, pass, session, dpi, restart), timeoutMs)

    fun stop(ctx: Context, d: Distro) = send(ctx, launchArgs(ctx, d, arrayOf("--stop")), background = true, result = null)

    /** Opens a Termux session that installs/updates [d] with the setup script bundled in the app. */
    fun setup(ctx: Context, d: Distro, session: Session) {
        val args = arrayOf("-c", asset(ctx, "rb-setup.sh"), "rb-setup", asset(ctx, "rombooter-setup.sh"), d.key, session.key)
        send(ctx, args, background = false, result = null)
    }

    /** Opens a Termux session that switches off the phantom process killer via Wireless debugging. */
    fun phantomFix(ctx: Context) = send(ctx, arrayOf("-c", asset(ctx, "rb-phantom.sh"), "rb-phantom"), background = false, result = null)

    /** start_<distro>.sh --status: RUNNING / STOPPED / EXITED <code> / KILLED, or null if unknown. */
    suspend fun status(ctx: Context, d: Distro): String? =
        runForResult(ctx, d, arrayOf("--status"), 20_000)?.takeIf { it.ok }?.stdout?.trim()?.lineSequence()?.lastOrNull()

    private fun asset(ctx: Context, name: String) = ctx.assets.open(name).use { it.readBytes().toString(Charsets.UTF_8) }

    /**
     * bash -c <rb-launch.sh> rb-launch <distro> <bundled setup> <start script args>. The launcher
     * updates start scripts from older setups with the bundled one before running them.
     */
    private fun launchArgs(ctx: Context, d: Distro, args: Array<String>) =
        arrayOf("-c", asset(ctx, "rb-launch.sh"), "rb-launch", d.key, asset(ctx, "rombooter-setup.sh")) + args

    private suspend fun runForResult(ctx: Context, d: Distro, args: Array<String>, timeoutMs: Long): ScriptResult? {
        val app = ctx.applicationContext
        val id = ids.getAndIncrement()
        return withTimeoutOrNull(timeoutMs) {
            suspendCancellableCoroutine { cont ->
                val receiver = object : BroadcastReceiver() {
                    override fun onReceive(c: Context, i: Intent) {
                        if (i.getIntExtra(EXTRA_ID, -1) != id) return
                        runCatching { app.unregisterReceiver(this) }
                        if (cont.isActive) cont.resume(parse(i))
                    }
                }
                ContextCompat.registerReceiver(app, receiver, IntentFilter(ACTION_RESULT), ContextCompat.RECEIVER_NOT_EXPORTED)
                cont.invokeOnCancellation { runCatching { app.unregisterReceiver(receiver) } }

                // Explicit (package-bound) and mutable: Termux fills in the "result" bundle.
                val callback = Intent(ACTION_RESULT).setPackage(app.packageName).putExtra(EXTRA_ID, id)
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                    (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
                try {
                    send(app, launchArgs(app, d, args), background = true, result = PendingIntent.getBroadcast(app, id, callback, flags))
                } catch (e: Exception) {
                    runCatching { app.unregisterReceiver(receiver) }
                    if (cont.isActive) cont.resume(ScriptResult(null, "", "", "Termux refused the command: ${e.message}"))
                }
            }
        }
    }

    private fun parse(i: Intent): ScriptResult {
        val b = i.getBundleExtra("result") ?: return ScriptResult(null, "", "", "Termux sent no result")
        val err = b.getInt("err", -1)
        val exit = if (b.containsKey("exitCode")) b.getInt("exitCode") else null
        return ScriptResult(
            // err != RESULT_OK(-1) means Termux itself failed (e.g. allow-external-apps is off)
            exitCode = if (err == -1) exit else null,
            stdout = b.getString("stdout").orEmpty(),
            stderr = b.getString("stderr").orEmpty(),
            errmsg = b.getString("errmsg").orEmpty()
        )
    }

    /** Distro keys come from the enum and scripts from the app's own assets, never from user text. */
    private fun send(ctx: Context, args: Array<String>, background: Boolean, result: PendingIntent?) {
        val i = Intent("com.termux.RUN_COMMAND").apply {
            setClassName("com.termux", "com.termux.app.RunCommandService")
            putExtra("com.termux.RUN_COMMAND_PATH", BASH)
            putExtra("com.termux.RUN_COMMAND_ARGUMENTS", args)
            putExtra("com.termux.RUN_COMMAND_WORKDIR", HOME)
            putExtra("com.termux.RUN_COMMAND_BACKGROUND", background)
            if (!background) putExtra("com.termux.RUN_COMMAND_SESSION_ACTION", "0") // open + switch to it
            if (result != null) putExtra("com.termux.RUN_COMMAND_PENDING_INTENT", result)
        }
        ContextCompat.startForegroundService(ctx, i)
    }
}
