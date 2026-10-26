# RomBooter

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-support-FFDD00?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/3rr0r303YT)

Run full Linux desktops on your Android phone. **No root, no emulation overhead, no telemetry.**

RomBooter drives Termux + PRoot (`proot-distro`) to run Linux distributions natively on ARM64 and shows the desktop in an embedded VNC viewer. One tap on **Boot** starts the container and switches to the live desktop automatically.

## What's new in 1.3.1

- **Fixed: `start_<distro>.sh rejected its arguments: unknown argument '--dpi'`** on every distro set up before 1.3.0. Existing installs no longer need a new setup when the app gains an option:
  - **Automatic update on Boot:** the app's launcher (`rb-launch.sh`) compares the version of `~/start_<distro>.sh` with the setup script inside the app. If the start script is older, it runs the new `rombooter-setup.sh --refresh --distro <distro>` first. That rewrites the start script and copies the current `rb-session` into the container. It installs no packages and touches neither the rootfs nor your settings: the container alias, user, resolution and default session come from the old start script. The log goes to `~/.rombooter/refresh-<distro>.log`.
  - **Fallback:** if that update cannot run (for example, no storage left), the launcher leaves out options the old script does not know (`--dpi` for scripts older than 1.3) and starts anyway.
  - **Tolerant parsers from now on:** `start_<distro>.sh` and `rb-session` ignore unknown options with a warning instead of stopping. An option's value is skipped along with it. Exit code 2 is left for bad values of known options.
- You can also run it by hand: `bash ~/rombooter-setup.sh --refresh --distro debian`.

## What's new in 1.3.0

- **Mobile sessions as first-class options:**
  - **Phosh** (the postmarketOS phone shell) and **Sway** are protected by the app's VNC password now. The app logs in to `wayvnc` with Apple Diffie-Hellman (security type 30), which `wayvnc` 0.9+ offers without TLS.
  - Both scale to the phone: Phosh through `phoc`'s output scale, Sway through its output scale. Sway opens every app full screen in tabs, phone-like, and starts a terminal.
  - The app lists the sessions as Xfce (touch-tuned), Phosh (mobile), Sway (full-screen apps) and i3.
- **Xfce without a magnifier:** the app works out a desktop DPI from the phone's real screen size, so text comes out as big as Android's own (about 14 sp), and passes it as `--dpi`. Xvnc, the X resources and Xfce follow it:
  - Xft DPI and a bigger mouse pointer;
  - hi-DPI window decorations (`Default-xhdpi`), double-click on the title bar maximizes;
  - a 48 px panel at DPI 144;
  - single-click icons on the desktop and in Thunar.

  This is applied at every login and can be switched off with `touch ~/.config/rombooter/no-touch-tuning`.
- **Touch controls:**
  - **☝ Touch** (direct): taps land where the finger is.
  - **🖱 Pad** (touchpad): the finger moves the pointer relatively, precise for tiny widgets; tap = click at the pointer, long press + drag = drag.
  - In both modes: **pinch to zoom** into the desktop (up to 5x, **1:1** resets), two fingers move the zoomed view or scroll, a two-finger tap is a right click.
  - All controls moved into the bottom bar, so nothing covers the windows' title bars and close buttons. The bar can be folded away.
- VNC does not carry real touch events. "Direct touch" therefore means the click lands exactly under the finger, and touch-native apps behave best in Phosh.

## What's new in 1.2.0

- **Arch Linux on ARM64:** if `proot-distro`'s own Arch image is not available or cannot be installed on the device, the setup switches by itself to the official **Arch Linux ARM aarch64 rootfs** from archlinuxarm.org mirrors. It checks the official MD5, and the container is called `archlinux-alarm`. The Docker test harness uses the community image `menci/archlinuxarm` on ARM64 hosts, because Docker Hub's `archlinux` image is x86_64 only.
- **Gentoo without a registry:** the stage3 now comes only from Gentoo's own servers (`distfiles.gentoo.org`, then the official mirrors `gentoo.osuosl.org` and `mirror.leaseweb.com/gentoo`) and is checked against Gentoo's published `.sha256`. No Docker Hub or other registry is involved, so "unauthorized" errors are gone. The Docker test harness imports the same official stage3 with `docker import`.
- **Touch and keyboard, postmarketOS style:**
  - A key bar is visible by default: Ctrl, Alt and Super apply to the next key; also Esc, Tab, arrow keys, Home/End, PgUp/PgDn, Del, Backspace, Enter.
  - **⌨** opens the Android keyboard and sends every keystroke straight to the desktop. A hardware keyboard works too, including Ctrl shortcuts and F1 to F12.
  - Gestures: tap = left click, long press = right click, drag = drag, two-finger swipe = scroll.
  - Xfce installs the `onboard` on-screen keyboard where the distro packages it.
- **Protection against the Android phantom process killer (Android 12+):**
  - **Detection:** the app reads whether the killer is switched off and shows a hint until it is. When the desktop disappears, the start script tells a normal end apart from Android killing the session (`--status` reports `KILLED`), and the app says so and offers **Prevent this**.
  - **Fix without a PC:** on Android 14+, a shortcut to Developer options > "Disable child process restrictions". On all versions, a guided Termux session (`rb-phantom.sh`) that uses Android's **Wireless debugging** with `adb` from Termux on the phone itself to set `max_phantom_processes` and switch the monitor off. It can be undone with `--undo`. A shortcut opens Termux's battery settings so you can set it to "Unrestricted".
  - **Fewer processes:** the Xfce session no longer autostarts programs that are useless in PRoot, such as the screensaver, power manager, a PulseAudio daemon inside the guest, and Bluetooth/network applets. Fewer processes stay under Android's limit, and Termux keeps its wake lock.
  - There is no "keep-alive ping": it would not stop the killer, and Xvnc counts every probe connection as a failed login.

## What's new in 1.1.1

- **Fixed: Termux error 150 for Arch, Gentoo, Ubuntu, Alpine, Kali and Fedora.** The app called `~/start_<distro>.sh` directly, and the setup creates that script only for the distro it was run for. Android does not let an app write into Termux's home directory, so the app now ships the setup script in its assets. Boot and Stop run a small launcher (`rb-launch.sh`) through Termux's `bash`. If the start script is missing, the app shows **Set up <distro>**. That button opens a Termux session which writes the bundled `rombooter-setup.sh` to `~`, runs `chmod 700` and executes it for the chosen distro and session.
- **Fixed: "VNC server closed the connection during VNC authentication" (Debian).** The server-side scripts on the device were still from 1.0.x, so the VNC password file inside the distro stayed empty and TigerVNC dropped the app during the password check. The launcher now detects start scripts from older setups (exit code 6) and the app offers **Set up <distro>** to update them. If a freshly restarted session still cannot authenticate, the app offers the same fix instead of failing again. The app's VNC client itself was correct: it sends the per-install 8-character password as standard VNC authentication.
- Running the setup for another session keeps the sessions that are already registered.

## What's new in 1.1.0

- **Fixed:** `java.io.EOFException` when pressing **Boot**, caused by an empty VNC password file on Debian 13, Ubuntu 24.04+, Kali and Arch.
- **Fixed:** "Server refused:" with an empty message, caused by TigerVNC blacklisting 127.0.0.1 after failed logins and port checks.
- **Fixed:** start script parameters (`--pass`, `--res`, `--de`) are validated, with clear errors and exit codes.
- **Fixed:** sessions left over from another distro or password are replaced, `--stop` is reliable, and a busy X display `:1` is handled.
- **Fixed:** copying files into the container is verified with a checksum on all 7 distros. Gentoo `MAKEOPTS` and the Arch keyring are corrected.
- **New:** experimental Wayland sessions (Sway, Phosh mobile shell) with a session registry inside the container.
- **New:** the app shows the start script's real error, retries the connection, and restarts a blocked session by itself.
- **New:** tests for all scripts, plus Docker end-to-end tests.

Details: [Fixes in 1.1.0](#fixes-in-110-javaioeofexception-on-boot) and [CHANGELOG.md](CHANGELOG.md). **Updating from 1.0.x:** run `bash rombooter-setup.sh --distro <distro>` once more in Termux.

## Features

- **No-root PRoot execution**: native ARM64 speed through Termux + PRoot, no QEMU x86 emulation, no root.
- **Multi-distro**: Arch, Gentoo, Debian, Ubuntu, Alpine, Kali, Fedora.
- **Sessions**: XFCE or i3 on X11 (Xvnc), plus experimental Wayland sessions (Sway, Phosh) through a headless wlroots compositor and `wayvnc`. See [Sessions and display backends](#sessions-and-display-backends).
- **Embedded VNC client**: minimal RFB 3.3/3.8 viewer written in Kotlin (VncAuth or None, Raw + CopyRect + DesktopSize), touch to mouse, on-screen Esc/Tab/text input.
- **Zero-click boot**: the app launches the start script in Termux, gets its exit status back from Termux, and opens the desktop once the VNC server answers on `127.0.0.1:5901`. If something fails, the app shows the script's error message instead of a bare exception.
- **Zero telemetry**: no analytics, no phone-home. The app only talks to loopback. Network is used only during setup for distro package mirrors and rootfs downloads.
- **Audio**: PulseAudio on the Termux side, loopback-only TCP.

## Quick start (Termux)

Install Termux from F-Droid or GitHub, then:

```bash
bash rombooter-setup.sh --distro debian --de xfce --yes
bash rombooter-setup.sh                 # interactive menu
~/start_debian.sh --res 1280x608        # start
~/start_debian.sh --stop                # stop
```

Options: `--distro arch|gentoo|debian|ubuntu|alpine|kali|fedora`, `--de LIST` (comma-separated, e.g. `xfce,i3,sway`; the first one is the default), `--res WxH`, `--user NAME`, `--yes`, `--no-update`, `--list`, `--version`. `--opt=value` works too.

The VNC server listens on `127.0.0.1:5901` only. The app generates a per-install 8-character password and passes it to the start script, which hands it to the container through stdin, so it never appears in a process list.

Notes:
- The setup script sets `allow-external-apps = true` in `~/.termux/termux.properties` so the app can call Termux. Only apps you grant the `com.termux.permission.RUN_COMMAND` permission can use it.
- Gentoo uses binary packages where available; anything else compiles on the device and can take hours.
- Kali and Gentoo rootfs hashes are pinned from your own download (trust on first use).
- On Android 12+ the phantom process killer can stop PRoot sessions. The app detects it and offers a fix without a PC (Wireless debugging + adb in Termux, or on Android 14+ Developer options > "Disable child process restrictions"). With a PC: `adb shell device_config put activity_manager max_phantom_processes 2147483647`.

## How the setup works (universal distro support)

`rombooter-setup.sh` never assumes where `proot-distro` keeps a container on disk. That layout changed between `proot-distro` versions and is the reason for the 1.0.0 failure below. Instead it talks to every distro the same way, through `proot-distro login`:

1. **Detect**: `proot-distro login <distro> -- true` decides whether the container is already installed. If not, it runs `proot-distro install`.
2. **Copy in**: the provisioning script (`/root/rb-provision.sh`) and the session launcher (`/usr/local/bin/rb-session`) are streamed into the container through stdin, so they land in the container's own root regardless of host paths.
3. **Verify**: before running anything, the script checks from inside the container that both files exist and are non-empty. If not, it stops with a clear error instead of a cryptic `/bin/sh` message.
4. **Provision**: a per-family package script runs inside the container: `apt` (Debian, Ubuntu, Kali), `pacman` (Arch), `apk` (Alpine), `dnf` (Fedora), `emerge` (Gentoo). Kali and Gentoo are not in `proot-distro` itself, so a small plugin is registered for them first.

Re-running the script is safe: an installed container is reused, users and packages are only added when missing.

Copying files in (step 2) writes to a temporary name, renames it atomically and compares the `cksum` from inside the container with the host copy. Failed copies are retried 3 times. This is tested against the container images of all 7 distros (`tests/e2e-copy.sh`).

## Sessions and display backends

The app works like a small display manager, similar to postmarketOS's `tinydm`. Each session is registered inside the container as `/etc/rombooter/sessions/<name>.conf` (`RB_BACKEND`, `RB_EXEC`, `RB_LABEL`). `rb-session` picks the backend from that file:

| Session | Backend | How it is shown | Status |
|---------|---------|-----------------|--------|
| `xfce`  | `x11`     | TigerVNC `Xvnc`, VNC password, tuned for touch (DPI, big decorations and panel, single click) | default |
| `phosh` | `wayland` | `phoc` (headless) + `phosh` mobile shell + `wayvnc`, portrait, scaled to the screen | recommended for phones, not on Gentoo |
| `sway`  | `wayland` | `sway` on the wlroots headless backend + `wayvnc`, every app full screen (tabbed), scaled | full-screen apps |
| `i3`    | `x11`     | TigerVNC `Xvnc`, VNC password | for keyboard users |

Install several sessions with `--de xfce,sway` and pick one in the app or with `~/start_<distro>.sh --de sway`. `rb-session --list` shows what is installed. Wayland sessions require the app's password through `wayvnc`'s login (Apple Diffie-Hellman with `relax_encryption`, which the app speaks) when the distro ships `wayvnc` 0.9 or newer, for example Debian 13, Ubuntu 25.04+, Arch, Alpine and Fedora. With an older `wayvnc`, such as Ubuntu 24.04's 0.8, the session falls back to loopback-only without a password and says so in its log. They use software rendering (pixman).

Adding a backend means adding a `run_<backend>` function to `rb-session`, so for example a future native Wayland viewer would not need changes to the provisioning or the app's boot flow.

### Fixes in 1.1.0: `java.io.EOFException` on Boot

The app could fail with a bare `java.io.EOFException`: the VNC server accepted the connection and then hung up during the handshake. Causes and fixes:

- **Root cause on Debian 13 / Ubuntu 24.04+ / current Kali:** TigerVNC 1.13 moved `vncpasswd` from `tigervnc-common` into the new `tigervnc-tools` package. `vncpasswd -f` failed silently, the password file stayed empty, and Xvnc dropped every client that tried VNC authentication. Provisioning now installs `tigervnc-tools` when the distro has it, checks that `Xvnc`, `vncpasswd` and every session binary exist, and `rb-session` refuses to start with an empty password file instead of starting a broken server.
- **"Server refused:" with an empty message:** this follows from the empty password file above. TigerVNC counts every connection that closes before login as a failed attempt, including plain port checks. After 5 of them it puts 127.0.0.1 on its blacklist and answers every client with an empty list of security types and no reason. The app showed that as "Server refused:". Xvnc now blacklists only after 20 attempts and for 2 seconds at first (the block still doubles while attempts continue). The start script waits for a ready marker from `rb-session` instead of polling the port, so a boot costs at most 1 or 2 probes, and a successful login resets the count. The app explains a refusal and, after a refusal or a failed login, restarts the session once (`--restart`) and connects again.
- **Busy display `:1`:** another X server in the same network namespace, such as Termux's own `vncserver` or a second distro, made Xvnc fail with "server already running". `rb-session` now uses the first free display from `:1` to `:9`. It removes stale lock files only when the server that owned them is gone.
- **Start script arguments:** `--pass`, `--res` and `--de` are validated with clear messages and exit code 2. `--pass` followed by another option is no longer swallowed as the password, `--opt=value` works, and the password may be 6 to 64 printable characters (VNC only uses the first 8).
- **Stale or foreign sessions:** a session that was started for another distro, session, resolution or password is restarted instead of being reported as "already running". Before, a different password led to an authentication failure, and a dead server led to the EOF.
- **READY means usable:** the start script reports `READY` only after `rb-session` has signalled that Xvnc is up and the server has answered one check with an RFB banner. Before, an open port was enough.
- **Stopping:** each session runs in its own process group (`setsid`), so `--stop` stops proot and everything inside it. The old `pkill -f rb-session` could match unrelated processes.
- **App:** gets the start script's exit status and stderr from Termux (`RUN_COMMAND_PENDING_INTENT`) and shows the real reason. It also retries the VNC handshake up to 3 times while a session is still settling, maps EOF and timeouts to readable messages, reads the server's failure reason, supports RFB 3.3 and DesktopSize, and has a 15 s handshake timeout.

Start script exit codes: `0` ready or stopped, `1` session exited during startup (the log tail is printed), `2` bad arguments, `3` timeout, `4` distro not set up, `5` port 5901 used by another program.

### Fixes in 1.0.1

- **Fixed:** `/bin/sh: 0: cannot open /root/rb-provision.sh: No such file` during provisioning. 1.0.0 wrote the file to a hard-coded host path (`.../installed-rootfs/<distro>/root/`), which does not match the container's real root on newer `proot-distro` layouts. The file is now copied in through `proot-distro login`.
- **Fixed:** the "already installed" check no longer looks for a host directory, so a leftover empty folder can no longer make an uninstalled distro look installed.
- **Added:** explicit existence checks inside the container before and after provisioning.

## Running the setup properly

Use Termux from F-Droid or GitHub (not the Play Store build), then in Termux:

```bash
pkg install -y curl
curl -fsSLO https://raw.githubusercontent.com/Real3rr0r303YT/RomBooter/main/rombooter-setup.sh
bash rombooter-setup.sh --distro debian --de xfce --yes
```

Then start and stop the desktop:

```bash
~/start_debian.sh --res 1272x576 --pass <6-64 chars, no spaces> --de xfce
~/start_debian.sh --status
~/start_debian.sh --stop
```

The app runs this script through its launcher. If `~/start_<distro>.sh` is missing or comes from an old setup, the app offers **Set up <distro>** and runs the setup script it ships with in Termux. You can still run the setup by hand.

Troubleshooting:
- Setup failed halfway: just run the same command again.
- Updating from 1.0.x: run the setup again with the same `--distro`. This regenerates `start_<distro>.sh` and `rb-session` and installs `tigervnc-tools` where it is needed.
- Desktop does not come up: `cat ~/.rombooter/<distro>.log`.
- Test the container by hand: `proot-distro login debian`.

## Tests

```bash
bash tests/static.sh          # shellcheck + dash/busybox syntax of every generated script, all 7 distros
bash tests/start-script.sh    # start script: argument validation, password via stdin, restart/stop, exit codes
bash tests/launcher.sh        # the app's Termux entry points: missing/outdated start scripts, setup copy
bash tests/fetch.sh           # official Gentoo stage3 / Arch Linux ARM downloads (simulated mirrors)
bash tests/e2e-upgrade.sh     # docker: a 1.2.0 install booted by the current app (auto-update, --dpi)
bash tests/e2e-copy.sh        # docker: real copy-in into all 7 distro images, guest-side checks
bash tests/e2e-docker.sh ubuntu:xfce,i3,sway   # docker: full provision + boot + VNC handshake (needs package mirrors),
                                               # plus blacklist/"Server refused" recovery, 1.0.x server replacement, busy :1
```

The Docker tests replace `proot-distro` with a small wrapper around `docker` (`tests/e2e/proot-distro`). The VNC check (`tests/e2e/RfbProbe.java`) uses the same handshake as the app.

## Repository layout

```
rombooter-setup.sh                      setup + start-script generator (run in Termux)
tests/                                  shell, docker and VNC handshake tests
app/src/main/AndroidManifest.xml
app/src/main/assets/rb-launch.sh        Termux entry point for Boot/Stop (checks ~/start_<distro>.sh)
app/src/main/assets/rb-setup.sh         runs the bundled rombooter-setup.sh in a Termux session
app/src/main/assets/rb-phantom.sh       switches off the phantom process killer via Wireless debugging
                                        (rombooter-setup.sh is copied into the assets at build time)
app/src/main/java/org/rombooter/
  MainActivity.kt                       entry point
  RomBooterApp.kt                       Compose UI: boot screen, support dialog
  DesktopScreen.kt                      desktop view: key bar, live keyboard, touch gestures
  PhantomGuard.kt                       phantom process killer detection and fixes
  BootViewModel.kt                      launch -> wait for :5901 -> connect state machine
  TermuxLauncher.kt                     Termux RUN_COMMAND intents
  RfbClient.kt                          minimal RFB/VNC client
```

## Status

Early development. CI builds a debug APK on every push. The setup and start scripts are tested in CI and with Docker, but the app has not been tested on a real device yet. Issues and pull requests are welcome.

Dependencies for the app module: Compose Material 3, `androidx.lifecycle:lifecycle-viewmodel-compose`, `kotlinx-coroutines-android`.

## Support

If RomBooter is useful to you, you can support development:

[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-support-FFDD00?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/3rr0r303YT)

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
