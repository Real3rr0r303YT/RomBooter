package org.rombooter

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp

/**
 * Android 12+ "phantom process killer": the system kills child processes of apps (PRoot, Xvnc and
 * the whole desktop inside Termux) beyond a device-wide limit of 32, or when they use a lot of CPU
 * in the background. Only the user can switch it off; this finds out whether that happened and
 * leads to the ways that need no PC.
 */
object PhantomGuard {
    private const val FLAG = "settings_enable_monitor_phantom_procs"
    private const val PREFS = "rb"
    private const val KEY_DISMISSED = "phantom_dismissed"

    /** Android 12 (API 31) introduced the killer. */
    val applies get() = Build.VERSION.SDK_INT >= 31

    /** Android 14 has a switch for it: Developer options > "Disable child process restrictions". */
    val hasDeveloperSwitch get() = Build.VERSION.SDK_INT >= 34

    /** true = switched off, false = active, null = cannot tell (Android 12 without the flag). */
    fun disabled(ctx: Context): Boolean? {
        if (!applies) return true
        val v = runCatching { Settings.Global.getString(ctx.contentResolver, FLAG) }.getOrNull()
        return when (v?.trim()?.lowercase()) {
            "false" -> true
            "true" -> false
            else -> null
        }
    }

    /** Show the hint on the boot screen unless it is off or the user said they took care of it. */
    fun shouldWarn(ctx: Context) = applies && disabled(ctx) != true &&
        !ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_DISMISSED, false)

    fun dismiss(ctx: Context) =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(KEY_DISMISSED, true).apply()

    fun openDeveloperOptions(ctx: Context) = open(ctx, Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS))

    /** Termux must be "Unrestricted" in battery settings, or Android also stops it in the background. */
    fun openTermuxBatterySettings(ctx: Context) =
        open(ctx, Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:com.termux"))) ||
            open(ctx, Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))

    private fun open(ctx: Context, i: Intent) =
        runCatching { ctx.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }.isSuccess
}

@Composable
fun PhantomDialog(onDismiss: () -> Unit) {
    val ctx = LocalContext.current
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Keep Android from killing the desktop") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    "Android 12 and newer stop child processes of apps (PRoot and everything in the Linux " +
                        "desktop) when there are too many or they use a lot of CPU in the background. The desktop " +
                        "then disappears and the app shows that Android stopped it."
                )
                if (PhantomGuard.hasDeveloperSwitch) {
                    Text("Android 14+: Settings > Developer options > \"Disable child process restrictions\" switches it off.")
                    OutlinedButton(onClick = { PhantomGuard.openDeveloperOptions(ctx) }) { Text("Open developer options") }
                }
                Text(
                    "Without a PC: RomBooter can switch it off through Android's Wireless debugging and adb in " +
                        "Termux. A Termux window guides you through pairing (Wi-Fi needed, no internet)."
                )
                OutlinedButton(onClick = { runCatching { TermuxLauncher.phantomFix(ctx) } }) {
                    Text("Fix with Wireless debugging")
                }
                Text("Also set Termux's battery usage to \"Unrestricted\".")
                OutlinedButton(onClick = { PhantomGuard.openTermuxBatterySettings(ctx) }) { Text("Termux battery settings") }
                Text(
                    "RomBooter already keeps the desktop lean (fewer background programs) and holds a Termux " +
                        "wake lock while a session runs.",
                    style = MaterialTheme.typography.bodySmall
                )
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Close") } },
        dismissButton = {
            TextButton(onClick = { PhantomGuard.dismiss(ctx); onDismiss() }) { Text("Done, don't show again") }
        }
    )
}
