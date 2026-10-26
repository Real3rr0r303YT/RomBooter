# Changelog

## 1.3.1

### Fixed
- `unknown argument '--dpi'` on distros set up before 1.3.0. On Boot, the app's launcher updates outdated start scripts from the setup bundled in the APK (`rombooter-setup.sh --refresh`). That rewrites the start script and copies the guest `rb-session` without packages or a new rootfs, keeping alias, user, resolution and session. If the update fails, options the old script does not know are dropped.
- `start_<distro>.sh` and `rb-session` ignore unknown options (with a warning) instead of exiting, so future app options cannot break installed scripts.

### Added
- `rombooter-setup.sh --refresh --distro NAME`.
- Tests: upgrade cases in `tests/launcher.sh`, built with the real 1.2.0 setup as a fixture, and `tests/e2e-upgrade.sh`, which boots a docker install of 1.2.0 with the current app launcher.

## 1.3.0

### Added
- Password protection for Wayland sessions: `rb-session` configures `wayvnc` (0.9+) with `enable_auth`/`relax_encryption`, and the app implements security type 30 (Apple Diffie-Hellman). Older `wayvnc` falls back to loopback-only and says so in the log.
- Screen-size-aware scaling: the app passes `--dpi` (desktop text about as big as Android's 14 sp). It sets Xvnc `-dpi`, `Xft.dpi` and the cursor size, the Sway and Phosh output scale, and touch tuning for Xfce: DPI, cursor, `Default-xhdpi`, panel size, single click (opt out with `no-touch-tuning`).
- Sway: phone-like tabbed full-screen windows, a terminal at start.
- App: touch/touchpad modes, pinch zoom with pan and 1:1, two-finger tap for right click, all controls in the bottom bar (foldable), and sessions listed mobile-first.
- E2E: Wayland password on `wayvnc` 0.10, Xfce touch tuning, and a fake `proot-distro` that ends a session's processes like proot does.

## 1.2.0

### Fixed
- Arch Linux on ARM64: falls back to the official Arch Linux ARM aarch64 rootfs (container `archlinux-alarm`, official MD5 checked) when proot-distro's archlinux image is unavailable or fails. On ARM64 hosts the test harness uses `menci/archlinuxarm` instead of the x86_64-only `archlinux` image.
- Gentoo: the stage3 comes only from Gentoo's own servers, with mirror fallback, and is checked against the official `.sha256`. No container registry, so no "unauthorized" errors.
- Downloads resume and fall back to the next mirror. A damaged tarball, or one that does not match its checksum, is refused.

### Added
- postmarketOS-style input: key bar shown by default (sticky Ctrl/Alt/Super, Esc, Tab, arrows, Home/End, PgUp/PgDn, Del, Backspace, Enter), live forwarding of the Android keyboard, hardware keyboard shortcuts, and touch gestures (tap, long-press right click, drag, two-finger scroll). Xfce gets the `onboard` on-screen keyboard where it is packaged.
- Phantom process killer (Android 12+): detection in the app, `--status` reports `KILLED`, and a fix without a PC (`rb-phantom.sh`: Wireless debugging + adb from Termux, with `--undo`). Shortcuts to the Android 14 developer switch and to Termux's battery settings. A leaner Xfce autostart keeps the process count down.
- Tests: `tests/fetch.sh`, phantom fix and kill detection in `tests/launcher.sh` and `tests/start-script.sh`, and Xfce extras plus kill and recovery checks in the Docker E2E.

## 1.1.1

### Fixed
- Termux error 150 (file not found) when booting a distro other than the one that was set up. The app now runs `bash` with a launcher from its assets (`rb-launch.sh`). It reports a missing start script with exit code 4 and a 1.0.x start script with exit code 6. In both cases the app offers "Set up <distro>", which writes the bundled `rombooter-setup.sh` to Termux's home, runs `chmod 700` and executes it in a visible Termux session.
- "VNC server closed the connection during VNC authentication" with start scripts from 1.0.x (empty VNC password file in the guest). They are detected and updated through the same button. A session that still cannot authenticate after a restart also offers the setup.
- Re-running the setup for one session no longer unregisters the others.

### Added
- `tests/launcher.sh`, which calls the app's Termux entry points exactly as the app does.

## 1.1.0

### Fixed
- `java.io.EOFException` when booting. On TigerVNC >= 1.13 (Debian 13, Ubuntu 24.04+, Kali) `vncpasswd` lives in `tigervnc-tools`, which was not installed. The VNC password file stayed empty and Xvnc dropped every client mid-handshake. Provisioning now installs it and checks all required binaries. `rb-session` refuses an empty password file.
- "Server refused:" with an empty reason. Failed logins against the empty password file got 127.0.0.1 blacklisted by TigerVNC. Plain port checks count as failed attempts too. Xvnc now uses `-BlacklistThreshold 20 -BlacklistTimeout 2`, and the start script waits for an `RB_READY` marker from `rb-session` instead of polling (at most 1 probe per boot). The app polls only as a fallback for Termux builds without a result report, every 10 s after 20 s. The app names the cause and restarts the session once with `--restart`.
- Xvnc no longer fails when display `:1` is taken by another X server: `rb-session` picks the first free display from `:1` to `:9`.
- Start script: strict validation of `--pass`, `--res` and `--de` with clear errors and documented exit codes (`2` = bad arguments). A flag is never taken as an option value. `--opt=value` is supported.
- Start script: a running session with another distro, session, resolution or password is restarted instead of being reused.
- Start script: `READY` only after the server sends an RFB banner and survives its first client.
- Start script: sessions run in their own process group, so `--stop` is reliable and no longer uses a broad `pkill -f rb-session`.
- Gentoo: `MAKEOPTS="-j$(nproc)"` was written to make.conf literally, and Portage does not expand it. It is now expanded once, and repeated runs no longer append the block again.
- Arch: `pacman-key --populate` now loads every installed keyring.
- Copy-in: atomic write plus checksum verification inside the container, with retries.

### Added
- Session registry `/etc/rombooter/sessions/*.conf` and backend dispatch in `rb-session` (`x11`, `wayland`).
- Experimental Wayland sessions: `sway` and `phosh` (mobile shell, portrait) through a headless wlroots compositor and `wayvnc`.
- `--de` takes a list (`xfce,i3,sway`). New start script options: `--status` and `--restart`.
- App: session picker, start script exit status and stderr from Termux, handshake retries with readable errors, RFB 3.3, DesktopSize, handshake timeout.
- Tests: `tests/static.sh`, `tests/start-script.sh`, `tests/e2e-copy.sh`, `tests/e2e-docker.sh`. CI runs the first three.

## 1.0.1
- Files are copied into the container through `proot-distro login` instead of a hard-coded rootfs path.
