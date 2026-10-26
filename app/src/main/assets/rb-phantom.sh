# rb-phantom.sh - run by the RomBooter app in a visible Termux session as
#   bash -c "<this file>" rb-phantom
# Switches off Android 12+'s "phantom process killer" without a PC: Android's own Wireless
# debugging plus the adb client from Termux (pkg android-tools) talking to this phone itself.
# It changes two settings, survives reboots and can be undone with: bash -c "<this file>" rb-phantom --undo
set -u
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ask() { local a; read -r -p "$1: " a; printf '%s' "$a"; }
APPLY='/system/bin/device_config set_sync_disabled_for_tests persistent; /system/bin/device_config put activity_manager max_phantom_processes 2147483647; settings put global settings_enable_monitor_phantom_procs false'
UNDO='/system/bin/device_config set_sync_disabled_for_tests none; /system/bin/device_config delete activity_manager max_phantom_processes; settings put global settings_enable_monitor_phantom_procs true'
CMD=$APPLY; [ "${1:-}" = --undo ] && CMD=$UNDO

say "RomBooter: stop Android from killing Linux sessions (phantom process killer)"
sdk=$(getprop ro.build.version.sdk 2>/dev/null || echo 0)
if [ "${sdk:-0}" -lt 31 ]; then echo "Android $(getprop ro.build.version.release) has no phantom process killer. Nothing to do."; exit 0; fi
if [ "$sdk" -ge 34 ]; then
  echo "Android 14+: the quickest way is Settings > Developer options > \"Disable child process restrictions\"."
  echo "Continue here only if your phone does not have that switch."
  [ "$(ask 'Continue with Wireless debugging? [y/N]')" = y ] || exit 0
fi
if ! command -v adb >/dev/null 2>&1; then
  say "Installing adb (pkg install android-tools)"
  pkg install -y android-tools || { echo "Could not install android-tools." >&2; exit 1; }
fi
cat <<'TXT'

1. Settings > Developer options > Wireless debugging: switch it ON (needs Wi-Fi, no internet).
   (Developer options: Settings > About phone > tap "Build number" 7 times.)
2. Open "Pair device with pairing code". Keep that dialog visible: use split screen
   with Termux, or the pairing notification, because the code disappears when the dialog closes.
TXT
pport=$(ask "Pairing port (the number after ':' under 'IP address & Port' in the pairing dialog)")
pcode=$(ask "Wi-Fi pairing code (6 digits)")
adb pair "127.0.0.1:$pport" "$pcode" || { echo "Pairing failed. Check port and code and run this again." >&2; exit 1; }
echo
echo "3. Back on the Wireless debugging screen: note the port under 'IP address & Port' (a different one)."
cport=$(ask "Port")
S="127.0.0.1:$cport"
adb connect "$S" >/dev/null 2>&1
adb -s "$S" get-state >/dev/null 2>&1 || { echo "Could not connect to $S." >&2; exit 1; }
adb -s "$S" shell "$CMD" || { echo "Changing the settings failed." >&2; adb disconnect "$S" >/dev/null 2>&1; exit 1; }
val=$(adb -s "$S" shell /system/bin/device_config get activity_manager max_phantom_processes | tr -d '\r')
flag=$(adb -s "$S" shell settings get global settings_enable_monitor_phantom_procs | tr -d '\r')
adb disconnect "$S" >/dev/null 2>&1
if [ "$CMD" = "$UNDO" ]; then say "Restored Android's defaults."; exit 0; fi
if [ "$val" = 2147483647 ] && [ "$flag" = false ]; then
  say "Done: the phantom process killer is off (max_phantom_processes=$val, monitor=$flag)."
  echo "You can switch Wireless debugging off again. The setting stays after a reboot."
  echo "Some Android 12 builds reset it after a system update: then just run this again."
else
  echo "The settings could not be verified (max_phantom_processes=$val, monitor=$flag)." >&2; exit 1
fi
