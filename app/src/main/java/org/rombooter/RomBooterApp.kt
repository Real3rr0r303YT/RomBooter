package org.rombooter

import android.app.Activity
import android.content.pm.ActivityInfo
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel

private const val BMC_URL = "https://buymeacoffee.com/3rr0r303YT"
private const val RUN_COMMAND_PERMISSION = "com.termux.permission.RUN_COMMAND"

@Composable
fun RomBooterApp(vm: BootViewModel = viewModel()) {
    val state by vm.state.collectAsState()
    val ctx = LocalContext.current
    var distro by rememberSaveable { mutableStateOf(Distro.DEBIAN) }
    var session by rememberSaveable { mutableStateOf(Session.XFCE) }
    var showSupport by remember { mutableStateOf(false) }
    var showPhantom by remember { mutableStateOf(false) }

    val dm = ctx.resources.displayMetrics
    val boot = { vm.boot(distro, session, dm.widthPixels, dm.heightPixels, if (dm.xdpi > 100f) maxOf(dm.xdpi, dm.ydpi) else dm.densityDpi.toFloat()) }
    val askPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) boot()
    }

    val connected = state is BootState.Connected
    LaunchedEffect(connected, session) {
        (ctx as? Activity)?.requestedOrientation = when {
            !connected -> ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
            session.portrait -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT   // mobile shell
            else -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        }
    }

    MaterialTheme {
        Surface(Modifier.fillMaxSize()) {
            val c = vm.client
            if (connected && c != null) {
                VncScreen(c, onStop = { vm.stop(distro) }, onSupport = { showSupport = true })
            } else {
                BootScreen(
                    state = state, distro = distro, onPick = { distro = it },
                    session = session, onPickSession = { session = it },
                    onBoot = { askPermission.launch(RUN_COMMAND_PERMISSION) },
                    onSetup = { d -> vm.setup(d, session) },
                    onPhantom = { showPhantom = true },
                    onSupport = { showSupport = true }
                )
            }
        }
        if (showSupport) SupportDialog { showSupport = false }
        if (showPhantom) PhantomDialog { showPhantom = false }
    }
}

@Composable
private fun BootScreen(
    state: BootState, distro: Distro, onPick: (Distro) -> Unit,
    session: Session, onPickSession: (Session) -> Unit,
    onBoot: () -> Unit, onSetup: (Distro) -> Unit, onPhantom: () -> Unit, onSupport: () -> Unit
) {
    val ctx = LocalContext.current
    val busy = state is BootState.Launching || state is BootState.WaitingForPort || state is BootState.Connecting
    Column(
        Modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text("RomBooter", style = MaterialTheme.typography.headlineLarge)
        Spacer(Modifier.height(16.dp))
        LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            items(Distro.entries) { d ->
                FilterChip(selected = d == distro, enabled = !busy, onClick = { onPick(d) }, label = { Text(d.label) })
            }
        }
        Spacer(Modifier.height(8.dp))
        LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            items(Session.entries) { s ->
                FilterChip(selected = s == session, enabled = !busy, onClick = { onPickSession(s) }, label = { Text(s.label) })
            }
        }
        if (session.wayland) {
            Text(
                "Wayland session, scales to the screen. Tap Boot, then \"Set up\" if it is not installed yet. " +
                    "Password-protected with wayvnc 0.9+ (older distros: loopback only).",
                style = MaterialTheme.typography.bodySmall
            )
        }
        Spacer(Modifier.height(24.dp))
        Button(onClick = onBoot, enabled = !busy) { Text(if (state is BootState.Failed) "Retry" else "Boot") }
        Spacer(Modifier.height(16.dp))
        when (state) {
            BootState.Launching -> Status("Starting ${distro.label} in Termux...")
            BootState.WaitingForPort -> Status("Waiting for desktop on 127.0.0.1:${TermuxLauncher.PORT}...")
            BootState.Connecting -> Status("Connecting to the desktop...")
            is BootState.Failed -> {
                Text(state.message, color = MaterialTheme.colorScheme.error)
                state.setup?.let { d ->
                    Spacer(Modifier.height(8.dp))
                    OutlinedButton(onClick = { onSetup(d) }) { Text("Set up ${d.label}") }
                }
                if (state.phantom) {
                    Spacer(Modifier.height(8.dp))
                    OutlinedButton(onClick = onPhantom) { Text("Prevent this") }
                }
            }
            is BootState.SetupRunning -> Text(
                "Setting up ${state.distro.label} in Termux. Follow the progress there, then come back and tap Boot."
            )
            else -> Unit
        }
        // Android 12+: hint until the phantom process killer is off (or the user dismissed it)
        if (state !is BootState.Failed && remember(state) { PhantomGuard.shouldWarn(ctx) }) {
            Spacer(Modifier.height(16.dp))
            OutlinedButton(onClick = onPhantom) {
                Text(
                    "Android ${android.os.Build.VERSION.RELEASE} can kill the Linux desktop in the background " +
                        "(phantom process killer). Tap to prevent it.",
                    style = MaterialTheme.typography.bodySmall
                )
            }
        }
        Spacer(Modifier.height(24.dp))
        TextButton(onClick = onSupport) { Text("Support RomBooter") }
    }
}

@Composable
private fun Status(text: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
        Spacer(Modifier.width(12.dp))
        Text(text)
    }
}

@Composable
fun SupportDialog(onDismiss: () -> Unit) {
    val uri = LocalUriHandler.current
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Support RomBooter") },
        text = { Text("Free, open source (GPL-3.0), no ads, no telemetry. If it's useful to you, you can buy me a coffee.") },
        confirmButton = {
            // Opens the system browser only on this tap. The app itself makes no outbound calls.
            Button(onClick = { uri.openUri(BMC_URL); onDismiss() }) { Text("\u2615 Buy Me a Coffee") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Not now") } }
    )
}
