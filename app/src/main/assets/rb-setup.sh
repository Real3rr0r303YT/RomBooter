# rb-setup.sh - run by the RomBooter app inside Termux, in a visible terminal session, as
#   bash -c "<this file>" rb-setup SETUP_SCRIPT DISTRO SESSIONS
# SETUP_SCRIPT is the rombooter-setup.sh bundled with the app (its assets). It is written to
# ~/rombooter-setup.sh, made executable and run; it creates ~/start_DISTRO.sh.
set -e
umask 077
f="$HOME/rombooter-setup.sh"
printf '%s\n' "$1" >"$f.new"
bash -n "$f.new" || { echo "RomBooter: the bundled setup script is damaged" >&2; exit 1; }
mv -f "$f.new" "$f"
chmod 700 "$f"
echo "RomBooter: setting up $2 ($3). This downloads packages and can take a while."
exec bash "$f" --distro "$2" --de "$3" --yes
