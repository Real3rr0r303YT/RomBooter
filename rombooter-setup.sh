#!/data/data/com.termux/files/usr/bin/bash
# rombooter-setup.sh - RomBooter PRoot desktop provisioning (Termux, aarch64, no root)
# License: GPL-3.0-or-later | Offline at runtime | Zero telemetry
# Network use: Termux/distro package mirrors + rootfs download during SETUP only.
set -Eeuo pipefail

readonly VERSION="1.3.1"
: "${PREFIX:=/data/data/com.termux/files/usr}"
: "${HOME:=/data/data/com.termux/files/home}"
: "${TMPDIR:=$PREFIX/tmp}"
readonly PLUGIN_DIR="$PREFIX/etc/proot-distro"
readonly DLCACHE="$PREFIX/var/lib/proot-distro/dlcache"
readonly ALL_DISTROS="arch gentoo debian ubuntu alpine kali fedora"
# Sessions: name -> display backend. x11 = Xvnc, wayland = headless wlroots compositor + wayvnc.
readonly ALL_SESSIONS="xfce i3 sway phosh"

# ---------- ANSI output ----------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[34m'; C_C=$'\e[36m'; C_BD=$'\e[1m'; C_X=$'\e[0m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_C=""; C_BD=""; C_X=""
fi
info() { printf '%s[*]%s %s\n' "$C_B" "$C_X" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_G" "$C_X" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_X" "$*" >&2; }
err()  { printf '%s[-]%s %s\n' "$C_R" "$C_X" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---------- defaults ----------
DISTRO=""; DE="xfce"; RES="1280x608"; USER_NAME="rom"; ASSUME_YES=0; SKIP_UPDATE=0; REFRESH=0
KEY=""; ALIAS=""; FAMILY=""

usage() {
  cat <<EOF
${C_BD}rombooter-setup.sh ${VERSION}${C_X}
Usage: $0 [options]
  -d, --distro NAME   ${ALL_DISTROS// / | }
  -e, --de LIST       comma-separated sessions to install, first one is the default:
                        xfce (default), i3            X11 via Xvnc
                        phosh                         mobile shell (postmarketOS), Wayland via wayvnc
                        sway                          full-screen tabbed apps, Wayland via wayvnc
  -r, --res WxH       default VNC resolution (default: $RES)
  -u, --user NAME     unprivileged guest user (default: $USER_NAME)
  -y, --yes           no confirmation prompt
      --no-update     skip 'pkg update'
      --refresh       only update ~/start_<distro>.sh and rb-session of an installed distro
                      (keeps the rootfs, packages and settings; the app does this by itself)
      --list          list distro keys
  -V, --version       print version
  -h, --help          this help
Without --distro an interactive menu is shown.
EOF
}
list_distros() { tr ' ' '\n' <<<"$ALL_DISTROS"; }

# Validators shared by the setup and (as copies) the generated start script.
valid_res() { # WxH, both sides 240..4096
  [[ $1 =~ ^([0-9]{3,4})x([0-9]{3,4})$ ]] || return 1
  ((BASH_REMATCH[1] >= 240 && BASH_REMATCH[1] <= 4096 && BASH_REMATCH[2] >= 240 && BASH_REMATCH[2] <= 4096))
}
valid_de_list() { # comma list of known sessions, no duplicates
  local d seen=","
  [[ -n $1 ]] || return 1
  IFS=, read -ra _des <<<"$1"
  for d in "${_des[@]}"; do
    [[ " $ALL_SESSIONS " == *" $d "* ]] || return 1
    [[ $seen != *",$d,"* ]] || return 1
    seen+="$d,"
  done
  [[ $1 != *, ]]
}

parse_args() {
  local opt val
  while (($#)); do
    opt=$1; val=""
    # accept --opt=value as well as --opt value
    if [[ $opt == --*=* ]]; then val=${opt#*=}; opt=${opt%%=*}; set -- "$opt" "$val" "${@:2}"; fi
    case $opt in
      -d|--distro|-e|--de|-r|--res|-u|--user)
        (($# >= 2)) && [[ -n $2 && $2 != -* ]] || { usage >&2; die "$opt needs a value"; }
        case $opt in
          -d|--distro) DISTRO=$2 ;;
          -e|--de)     DE=${2,,} ;;
          -r|--res)    RES=$2 ;;
          -u|--user)   USER_NAME=$2 ;;
        esac
        shift 2 ;;
      -y|--yes)     ASSUME_YES=1; shift ;;
      --no-update)  SKIP_UPDATE=1; shift ;;
      --refresh)    REFRESH=1; shift ;;
      --list)       list_distros; exit 0 ;;
      -V|--version) echo "$VERSION"; exit 0 ;;
      -h|--help)    usage; exit 0 ;;
      *)            usage >&2; die "Unknown option: $1" ;;
    esac
  done
  valid_de_list "$DE"                          || die "--de must be a comma list of: ${ALL_SESSIONS// /, } (got '$DE')"
  valid_res "$RES"                             || die "--res must look like 1280x608 (240..4096 per side, got '$RES')"
  [[ $USER_NAME =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || die "invalid --user '$USER_NAME'"
  [[ $USER_NAME != root ]]                     || die "--user must not be root"
}

preflight() {
  [[ $PREFIX == *com.termux* ]] || die "Run this inside Termux."
  [[ $(id -u) -ne 0 ]]          || die "Do not run as root."
  case $(uname -m) in aarch64|arm64) ;; *) die "ARM64 only (found $(uname -m))." ;; esac
  mkdir -p "$TMPDIR"
}

menu() {
  [[ -t 0 ]] || die "No --distro given and no TTY for the menu."
  PS3=$'\n'"${C_C}Distro [1-7]: ${C_X}"
  local d
  # shellcheck disable=SC2086
  select d in $ALL_DISTROS; do
    [[ -n ${d:-} ]] && { DISTRO=$d; break; }
  done
}

resolve_distro() {
  case ${DISTRO,,} in
    arch|archlinux) KEY=arch;   ALIAS=archlinux; FAMILY=arch ;;
    gentoo)         KEY=gentoo; ALIAS=gentoo;    FAMILY=gentoo ;;
    debian)         KEY=debian; ALIAS=debian;    FAMILY=deb ;;
    ubuntu)         KEY=ubuntu; ALIAS=ubuntu;    FAMILY=deb ;;
    alpine)         KEY=alpine; ALIAS=alpine;    FAMILY=alpine ;;
    kali)           KEY=kali;   ALIAS=kali;      FAMILY=deb ;;
    fedora)         KEY=fedora; ALIAS=fedora;    FAMILY=fedora ;;
    *) die "Unknown distro '$DISTRO' (see --list)" ;;
  esac
  if [[ ,$DE, == *,phosh,* && $FAMILY == gentoo ]]; then
    die "phosh is not packaged in the Gentoo main tree; use --de sway for a Wayland session."
  fi
}

confirm() {
  if [[ $KEY == gentoo ]]; then
    warn "Gentoo: packages come from the binhost where possible; anything else compiles on-device (hours)."
  fi
  if [[ ,$DE, == *,sway,* || ,$DE, == *,phosh,* ]]; then
    warn "Wayland sessions need wayvnc 0.9+ for a VNC password; with older distro packages they are protected by loopback only."
  fi
  if ((ASSUME_YES)) || [[ ! -t 0 ]]; then return 0; fi
  local a
  read -r -p "Install ${C_BD}${KEY}${C_X} + ${DE} as user '${USER_NAME}'? [Y/n] " a
  [[ ${a:-y} =~ ^[Yy]$ ]] || die "Aborted."
}

# ---------- host (Termux) side ----------
install_host_deps() {
  info "Installing Termux packages"
  export DEBIAN_FRONTEND=noninteractive
  ((SKIP_UPDATE)) || pkg update -y
  # util-linux: setsid, so the start script can stop the whole session process group
  pkg install -y proot-distro pulseaudio procps curl coreutils tar xz-utils util-linux
  ok "Host packages ready"
}

enable_termux_external() {
  local f="$HOME/.termux/termux.properties"
  mkdir -p "$HOME/.termux"; touch "$f"
  if grep -q '^[#[:space:]]*allow-external-apps' "$f"; then
    sed -i 's/^[#[:space:]]*allow-external-apps.*/allow-external-apps = true/' "$f"
  else
    echo 'allow-external-apps = true' >>"$f"
  fi
  termux-reload-settings >/dev/null 2>&1 || true
  warn "allow-external-apps=true: apps holding the RUN_COMMAND permission (you grant it per app) can run commands in Termux."
}

# Download rootfs ourselves (resumable, mirror fallback) and pin its SHA-256 in a proot-distro
# plugin. With an official checksum the download is verified against it; otherwise the hash is
# trust-on-first-use over HTTPS.
register_plugin() { # name pretty strip expected_sha256|"" url [mirror-url...]
  local name=$1 pretty=$2 strip=$3 want=$4; shift 4
  local url=$1 file sum u
  file="${DLCACHE:?}/${url##*/}"
  mkdir -p "$DLCACHE" "$PLUGIN_DIR"
  usable() { # file -> verified by checksum when we have one, else by listing the archive
    if [[ -n $want ]]; then [[ $(sha256sum "$1" | cut -d' ' -f1) == "$want" ]]; else tar -tf "$1" >/dev/null 2>&1; fi
  }
  if [[ ! -s $file ]] || ! usable "$file"; then
    rm -f "${file:?}"
    for u in "$@"; do
      info "Downloading ${u##*/} from ${u#*://}"
      if curl -fL --retry 5 --retry-delay 2 --connect-timeout 20 -C - -o "$file.part" "$u"; then
        if usable "$file.part"; then mv "$file.part" "$file"; break; fi
        warn "${u##*/} is damaged or does not match the official checksum"
        rm -f "${file:?}.part"
      else
        warn "Download failed, trying the next mirror"
      fi
    done
    [[ -s $file ]] || die "Could not download ${url##*/} from any mirror; re-run the setup to resume."
  fi
  sum=$(sha256sum "$file" | cut -d' ' -f1)
  cat >"$PLUGIN_DIR/$name.sh" <<EOF
DISTRO_NAME="$pretty"
DISTRO_COMMENT="Registered by rombooter-setup $VERSION"
TARBALL_STRIP_OPT=$strip
TARBALL_URL['aarch64']="$url"
TARBALL_SHA256['aarch64']="$sum"
EOF
  ok "Plugin '$name' registered${want:+ (official checksum verified)}"
}

# Official Gentoo arm64 stage3 straight from Gentoo's own servers (no container registry involved).
readonly GENTOO_MIRRORS="https://distfiles.gentoo.org https://gentoo.osuosl.org https://mirror.leaseweb.com/gentoo"
gentoo_stage3_path() { # latest-stage3-*.txt on stdin -> relative tarball path
  awk '/^[0-9TZ]+\/stage3-[a-z0-9]+-openrc-[0-9TZ]+\.tar\.xz / {print $1; exit}'
}
register_gentoo() {
  local m base="" txt path="" sum="" urls=()
  info "Resolving the latest official Gentoo arm64 stage3"
  for m in $GENTOO_MIRRORS; do
    txt=$(curl -fsSL --retry 2 --connect-timeout 20 "$m/releases/arm64/autobuilds/latest-stage3-arm64-openrc.txt") || continue
    path=$(gentoo_stage3_path <<<"$txt")
    if [[ -n $path ]]; then base="$m/releases/arm64/autobuilds"; break; fi
  done
  [[ -n $path ]] || die "Could not resolve the Gentoo arm64 stage3 from $GENTOO_MIRRORS"
  # Gentoo publishes <tarball>.sha256 next to every stage3
  sum=$(curl -fsSL --retry 2 --connect-timeout 20 "$base/$path.sha256" | awk '/stage3-.*\.tar\.xz/ {print $1; exit}') || sum=""
  if [[ ! $sum =~ ^[0-9a-f]{64}$ ]]; then
    warn "No official SHA-256 for $path; pinning the downloaded file (trust on first use)"; sum=""
  fi
  for m in $GENTOO_MIRRORS; do urls+=("$m/releases/arm64/autobuilds/$path"); done
  register_plugin gentoo "Gentoo (official stage3 arm64 openrc)" 0 "$sum" "${urls[@]}"
}

# Official Arch Linux ARM aarch64 rootfs: fallback when proot-distro's own archlinux image is not
# available for this device or fails to install.
readonly ALARM_FILE="ArchLinuxARM-aarch64-latest.tar.gz"
readonly ALARM_MIRRORS="https://fl.us.mirror.archlinuxarm.org https://de.mirror.archlinuxarm.org https://dk.mirror.archlinuxarm.org http://os.archlinuxarm.org"
register_alarm() {
  local m md5="" urls=()
  for m in $ALARM_MIRRORS; do
    md5=$(curl -fsSL --retry 2 --connect-timeout 20 "$m/os/$ALARM_FILE.md5" | awk '{print $1; exit}') || md5=""
    [[ $md5 =~ ^[0-9a-f]{32}$ ]] && break
    md5=""
  done
  for m in $ALARM_MIRRORS; do urls+=("$m/os/$ALARM_FILE"); done
  register_plugin archlinux-alarm "Arch Linux ARM (official aarch64 rootfs)" 0 "" "${urls[@]}"
  if [[ -n $md5 ]]; then
    if [[ $(md5sum "$DLCACHE/$ALARM_FILE" | cut -d' ' -f1) != "$md5" ]]; then
      rm -f "${DLCACHE:?}/${ALARM_FILE:?}" "${PLUGIN_DIR:?}/archlinux-alarm.sh"
      die "$ALARM_FILE does not match the official MD5; re-run the setup."
    fi
    ok "$ALARM_FILE matches the official MD5"
  else
    warn "Could not fetch the official MD5 for $ALARM_FILE; pinning the downloaded file (trust on first use)"
  fi
}

prepare_distro() {
  case $KEY in
    kali)
      register_plugin kali "Kali Linux (minimal arm64)" 1 "" \
        "https://kali.download/nethunter-images/current/rootfs/kali-nethunter-rootfs-minimal-arm64.tar.xz" ;;
    gentoo) register_gentoo ;;
  esac
}

# proot-distro changed its on-disk layout between versions, so never assume a rootfs path:
# ask proot-distro itself whether the container is usable, and talk to it only via `login`.
guest_sh() { proot-distro login "$ALIAS" -- /bin/sh -c "$1"; }

install_distro() {
  command -v proot-distro >/dev/null 2>&1 || die "proot-distro not found (pkg install proot-distro)."
  # An Arch container installed earlier through the fallback below
  if [[ $KEY == arch ]] && ! guest_sh ':' >/dev/null 2>&1 &&
     proot-distro login archlinux-alarm -- /bin/sh -c ':' >/dev/null 2>&1; then
    ALIAS=archlinux-alarm
  fi
  if guest_sh ':' >/dev/null 2>&1; then
    ok "$ALIAS already installed - reusing"
    return 0
  fi
  info "Installing $ALIAS via proot-distro"
  if proot-distro install "$ALIAS" && guest_sh ':' >/dev/null 2>&1; then
    return 0
  fi
  if [[ $KEY == arch && $ALIAS == archlinux ]]; then
    warn "proot-distro's archlinux image is not usable here; switching to the official Arch Linux ARM aarch64 rootfs"
    proot-distro remove archlinux >/dev/null 2>&1 || true
    register_alarm
    ALIAS=archlinux-alarm
    proot-distro install "$ALIAS" || die "Installing the Arch Linux ARM rootfs failed; re-run the setup to retry."
    guest_sh ':' >/dev/null 2>&1 && return 0
  fi
  die "$ALIAS installed but 'proot-distro login $ALIAS' fails; run it manually to see why."
}

# ---------- guest side: provisioning (POSIX sh, run as root in the distro: rb-provision.sh USER DE_LIST) ----------
# Guest only needs PulseAudio CLIENT libs; the daemon runs in Termux and is reached via TCP.
write_provision() {
  cat <<'RB_COMMON'
# rb-provision.sh - generated by rombooter-setup (runs as root inside the container)
# shellcheck disable=SC2086,SC1090
set -eu
U="${1:-}"; DES="${2:-}"
[ -n "$U" ] && [ -n "$DES" ] || { echo "usage: rb-provision.sh USER DE[,DE...]" >&2; exit 2; }
case "$U" in root|*[!a-z0-9_-]*) echo "rb-provision: invalid user '$U'" >&2; exit 2 ;; esac
has_de() { case ",$DES," in *",$1,"*) return 0 ;; esac; return 1; }
wants_wayland() { has_de sway || has_de phosh; }
retry() { # retry CMD... : mirrors on phones drop out; try 3 times before giving up
  n=1
  until "$@"; do
    [ "$n" -ge 3 ] && return 1
    echo "rb-provision: '$1' failed, retrying ($n/3)" >&2; n=$((n + 1)); sleep 5
  done
}
RB_COMMON
  case $FAMILY in
    deb) cat <<'RB_DEB'
export DEBIAN_FRONTEND=noninteractive
echo 'APT::Sandbox::User "root";' >/etc/apt/apt.conf.d/99rb-nosandbox
AI="apt-get install -y --no-install-recommends"
# true if PKG has an install candidate (apt-cache show also succeeds for merely referenced names)
avail() { apt-cache policy "$1" 2>/dev/null | grep -q 'Candidate: [^(]'; }
retry apt-get update
retry $AI tigervnc-standalone-server tigervnc-common dbus dbus-x11 \
  pulseaudio-utils x11-xserver-utils xauth xfonts-base fonts-dejavu-core ca-certificates procps
# TigerVNC >= 1.13 (Debian 13, Ubuntu 24.04+) moved vncpasswd into tigervnc-tools. Without it the
# password file stays empty and Xvnc drops every client mid-handshake (EOFException in the app).
if avail tigervnc-tools; then retry $AI tigervnc-tools; fi
if has_de xfce;   then retry $AI xfce4 xfce4-terminal; if avail onboard; then retry $AI onboard; fi; fi
if has_de i3;     then retry $AI i3-wm i3status dmenu xterm; fi
if wants_wayland; then retry $AI wayvnc foot; fi
if has_de sway;   then retry $AI sway swaybg; fi
if has_de phosh;  then
  retry $AI phosh phoc gnome-settings-daemon-common   # phosh aborts without its GSettings schemas
  # on-screen keyboard is optional (not packaged everywhere, e.g. Ubuntu 24.04)
  if avail squeekboard; then retry $AI squeekboard; fi
fi
id "$U" >/dev/null 2>&1 || useradd -m -s /bin/bash "$U"
usermod -aG audio,video "$U" 2>/dev/null || true
RB_DEB
    ;;
    arch) cat <<'RB_ARCH'
sed -i 's/^CheckSpace/#CheckSpace/' /etc/pacman.conf
grep -q '^DisableSandbox' /etc/pacman.conf || sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
pacman-key --init >/dev/null 2>&1 || true
pacman-key --populate >/dev/null 2>&1 || true   # every installed keyring (archlinuxarm on aarch64)
P="pacman -S --noconfirm --needed"
retry pacman -Syu --noconfirm --needed tigervnc dbus xorg-xauth xorg-xset xorg-xsetroot ttf-dejavu libpulse procps-ng
if has_de xfce;   then retry $P xfce4 xfce4-terminal; $P onboard || echo "rb-provision: no onboard (optional)" >&2; fi
if has_de i3;     then retry $P i3-wm i3status dmenu xterm; fi
if wants_wayland; then retry $P wayvnc foot; fi
if has_de sway;   then retry $P sway swaybg; fi
if has_de phosh;  then retry $P phosh phoc gnome-settings-daemon; $P squeekboard || echo "rb-provision: no squeekboard (optional)" >&2; fi
id "$U" >/dev/null 2>&1 || useradd -m -s /bin/bash "$U"
RB_ARCH
    ;;
    alpine) cat <<'RB_ALPINE'
A="apk add --no-cache"
retry apk update
retry $A bash shadow procps tigervnc dbus dbus-x11 xauth xset xsetroot font-dejavu pulseaudio-utils
if has_de xfce;   then retry $A xfce4 xfce4-terminal adwaita-icon-theme; $A onboard || echo "rb-provision: no onboard (optional)" >&2; fi
if has_de i3;     then retry $A i3wm i3status dmenu xterm; fi
if wants_wayland; then retry $A wayvnc foot; fi
if has_de sway;   then retry $A sway swaybg; fi
if has_de phosh;  then retry $A phosh phoc gnome-settings-daemon; $A squeekboard || echo "rb-provision: no squeekboard (optional)" >&2; fi
id "$U" >/dev/null 2>&1 || adduser -D -s /bin/bash "$U"
addgroup "$U" audio 2>/dev/null || true
RB_ALPINE
    ;;
    fedora) cat <<'RB_FEDORA'
D="dnf -y --setopt=install_weak_deps=False install"
retry $D tigervnc-server dbus-x11 xorg-x11-xauth xset xsetroot \
  pulseaudio-utils dejavu-sans-fonts shadow-utils procps-ng
if has_de xfce;   then retry dnf -y install @xfce-desktop-environment; $D onboard || echo "rb-provision: no onboard (optional)" >&2; fi
if has_de i3;     then retry $D i3 i3status dmenu xterm; fi
if wants_wayland; then retry $D wayvnc foot; fi
if has_de sway;   then retry $D sway swaybg; fi
if has_de phosh;  then retry $D phosh phoc gnome-settings-daemon; $D squeekboard || echo "rb-provision: no squeekboard (optional)" >&2; fi
id "$U" >/dev/null 2>&1 || useradd -m -s /bin/bash "$U"
RB_FEDORA
    ;;
    gentoo) cat <<'RB_GENTOO'
# Portage does not run make.conf through a shell, so expand nproc here (once).
if ! grep -q '^# rombooter$' /etc/portage/make.conf; then
  cat >>/etc/portage/make.conf <<MK
# rombooter
FEATURES="\${FEATURES} -sandbox -usersandbox -network-sandbox -ipc-sandbox -pid-sandbox"
MAKEOPTS="-j$(nproc)"
MK
fi
mkdir -p /etc/portage/package.use
echo 'net-misc/tigervnc server' >/etc/portage/package.use/rombooter
getuto >/dev/null 2>&1 || true
retry emerge-webrsync -q
EM="emerge -q --getbinpkg --binpkg-respect-use=y --noreplace"
retry $EM net-misc/tigervnc sys-apps/dbus x11-apps/xset x11-apps/xsetroot media-libs/libpulse media-fonts/dejavu
if has_de xfce;   then retry $EM xfce-base/xfce4-meta x11-terms/xfce4-terminal; fi
if has_de i3;     then retry $EM x11-wm/i3 x11-misc/i3status x11-misc/dmenu x11-terms/xterm; fi
if wants_wayland; then retry $EM gui-apps/wayvnc gui-apps/foot; fi
if has_de sway;   then retry $EM gui-wm/sway gui-apps/swaybg; fi
id "$U" >/dev/null 2>&1 || useradd -m -s /bin/bash "$U"
RB_GENTOO
    ;;
    *) die "write_provision: unknown family '$FAMILY'" ;;
  esac
  cat <<'RB_SESSIONS'
# Session registry (tinydm-style): one file per installed session, read by rb-session.
# Sessions from earlier runs stay registered (the app re-runs the setup for one session at a time).
mkdir -p /etc/rombooter/sessions
reg() { # name backend exec label
  printf 'RB_BACKEND=%s\nRB_EXEC=%s\nRB_LABEL="%s"\n' "$2" "$3" "$4" >"/etc/rombooter/sessions/$1.conf"
}
if has_de xfce;  then reg xfce  x11     startxfce4 "Xfce (X11)"; fi
if has_de i3;    then reg i3    x11     i3         "i3 (X11)"; fi
if has_de sway;  then reg sway  wayland sway       "Sway (Wayland, full-screen apps)"; fi
if has_de phosh; then reg phosh wayland phoc       "Phosh (Wayland, mobile shell)"; fi
echo "${DES%%,*}" >/etc/rombooter/default-session

# Fail here, not at boot time, if a backend is incomplete.
missing=""
if has_de xfce || has_de i3; then
  command -v Xvnc >/dev/null 2>&1 || command -v Xtigervnc >/dev/null 2>&1 || missing="$missing Xvnc"
  command -v vncpasswd >/dev/null 2>&1 || command -v tigervncpasswd >/dev/null 2>&1 || missing="$missing vncpasswd"
fi
if wants_wayland; then command -v wayvnc >/dev/null 2>&1 || missing="$missing wayvnc"; fi
for f in /etc/rombooter/sessions/*.conf; do
  [ -f "$f" ] || continue
  . "$f"; command -v "$RB_EXEC" >/dev/null 2>&1 && continue
  n=${f##*/}; n=${n%.conf}
  if has_de "$n"; then missing="$missing $RB_EXEC"; else rm -f "$f"; fi   # stale entry from an old run
done
[ -z "$missing" ] || { echo "rb-provision: missing after install:$missing" >&2; exit 1; }
echo "rb-provision: done ($DES for $U)"
RB_SESSIONS
}

# ---------- guest side: session launcher (installed to /usr/local/bin/rb-session) ----------
write_session() {
  cat <<'RB_SESSION'
#!/bin/sh
# rb-session - RomBooter session launcher (runs inside the distro as the unprivileged user)
#   rb-session [--res WxH] [--de NAME] [--port N] [--dpi N] [--pass-stdin]
#   rb-session --list
#   rb-session RES PASS DE            (legacy 1.0.x form)
# The VNC password is read from stdin (--pass-stdin) so it never shows up in `ps`.
REG=/etc/rombooter/sessions
RES=1280x608; DE=""; PORT=5901; PASS=""; PASS_STDIN=0; DPI=96

die() { echo "rb-session: $*" >&2; exit 1; }
need() { [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value"; }

case "${1:-}" in
  ""|-*) ;;
  *) RES="$1"; PASS="${2:-}"; DE="${3:-}"; set -- ;;   # legacy positional form
esac
while [ $# -gt 0 ]; do
  case "$1" in
    --res)        need "$@"; RES="$2"; shift 2 ;;
    --de)         need "$@"; DE="$2"; shift 2 ;;
    --port)       need "$@"; PORT="$2"; shift 2 ;;
    --dpi)        need "$@"; DPI="$2"; shift 2 ;;
    --pass-stdin) PASS_STDIN=1; shift ;;
    --list)
      for f in "$REG"/*.conf; do [ -f "$f" ] || continue; n=${f##*/}; echo "${n%.conf}"; done
      exit 0 ;;
    -*)
      echo "rb-session: ignoring unknown option '$1'" >&2
      if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then shift 2; else shift; fi ;;
    *) echo "rb-session: ignoring stray argument '$1'" >&2; shift ;;
  esac
done
if [ "$PASS_STDIN" = 1 ]; then IFS= read -r PASS || true; fi

[ -n "$DE" ] || DE=$(cat /etc/rombooter/default-session 2>/dev/null || echo xfce)
case "$RES" in *[!0-9x]*|x*|*x|*x*x*|"") die "bad resolution '$RES'" ;; *x*) ;; *) die "bad resolution '$RES'" ;; esac
case "$DE" in *[!a-z0-9_-]*|"") die "bad session name '$DE'" ;; esac
case "$PORT" in *[!0-9]*|"") die "bad port '$PORT'" ;; esac
case "$DPI" in *[!0-9]*|"") die "bad dpi '$DPI'" ;; esac
[ "$DPI" -ge 72 ] && [ "$DPI" -le 384 ] || die "dpi must be 72..384"
W=${RES%x*}; H=${RES#*x}
# Scale factor for touch: the app picks the DPI so text is as big as Android's own (96 = 1.0)
SCALE=$(awk -v d="$DPI" 'BEGIN { printf "%.2f", d / 96 }')
CFG="$HOME/.config/rombooter"

# Session definition (written by rb-provision); built-in fallback for 1.0.x installs.
RB_BACKEND=""; RB_EXEC=""
if [ -f "$REG/$DE.conf" ]; then
  # shellcheck disable=SC1090
  . "$REG/$DE.conf"
else
  case "$DE" in
    xfce) RB_BACKEND=x11; RB_EXEC=startxfce4 ;;
    i3)   RB_BACKEND=x11; RB_EXEC=i3 ;;
    *)    die "session '$DE' is not installed (have: $("$0" --list | tr '\n' ' ')) - re-run rombooter-setup.sh --de $DE" ;;
  esac
fi
command -v "$RB_EXEC" >/dev/null 2>&1 || die "'$RB_EXEC' for session '$DE' not found - re-run rombooter-setup.sh --de $DE"

export PULSE_SERVER=127.0.0.1 NO_AT_BRIDGE=1 LIBGL_ALWAYS_SOFTWARE=1
XDG_RUNTIME_DIR="/tmp/rb-runtime-$(id -u)"; export XDG_RUNTIME_DIR
mkdir -p "$XDG_RUNTIME_DIR" "$HOME/.vnc" "$HOME/.config" "$CFG"; chmod 700 "$XDG_RUNTIME_DIR"
CHILD=""
cleanup() { [ -n "$CHILD" ] && kill "$CHILD" 2>/dev/null; }
trap cleanup EXIT
trap 'exit 143' INT TERM HUP

with_dbus() {
  if command -v dbus-run-session >/dev/null 2>&1; then dbus-run-session -- "$@"
  elif command -v dbus-launch >/dev/null 2>&1; then dbus-launch --exit-with-session "$@"
  else "$@"; fi
}

# ---------- X11 backend: Xvnc on the first free display (:1..:9), VncAuth when a password is given ----------
# Remove a display's lock/socket only if the X server that owns it is gone.
clear_stale_display() {
  lpid=$(tr -dc 0-9 <"/tmp/.X$1-lock" 2>/dev/null)
  if [ -n "$lpid" ] && kill -0 "$lpid" 2>/dev/null; then return 1; fi
  rm -f "/tmp/.X$1-lock" "/tmp/.X11-unix/X$1" 2>/dev/null
  return 0
}
run_x11() {
  export GDK_BACKEND=x11 XDG_SESSION_TYPE=x11
  XV=$(command -v Xvnc || command -v Xtigervnc) || die "Xvnc not installed"
  if [ -n "$PASS" ]; then
    VP=$(command -v vncpasswd || command -v tigervncpasswd) || die "vncpasswd not installed (Debian/Ubuntu: apt install tigervnc-tools)"
    printf '%s\n' "$PASS" | "$VP" -f >"$HOME/.vnc/passwd.new" 2>/dev/null
    # A missing/empty password file makes Xvnc drop every client mid-handshake (EOF in the app).
    [ -s "$HOME/.vnc/passwd.new" ] || die "vncpasswd produced no password file"
    mv -f "$HOME/.vnc/passwd.new" "$HOME/.vnc/passwd"; chmod 600 "$HOME/.vnc/passwd"
    SEC="-SecurityTypes VncAuth -rfbauth $HOME/.vnc/passwd"
  else
    SEC="-SecurityTypes None"
  fi

  # Android 12+ kills app child processes beyond a device-wide limit (phantom process killer), so
  # keep the session lean: hide autostart entries that make no sense in PRoot (the user can re-enable
  # them in Settings > Session and Startup; existing user overrides are kept).
  AS="$HOME/.config/autostart"; mkdir -p "$AS"
  for a in xscreensaver light-locker xfce4-power-manager xfce4-screensaver pulseaudio \
           polkit-gnome-authentication-agent-1 xfce-polkit blueman nm-applet print-applet \
           geoclue-demo-agent gnome-keyring-pkcs11 gnome-keyring-secrets gnome-keyring-ssh \
           at-spi-dbus-bus update-notifier xiccd tracker-miner-fs-3 org.gnome.Evolution-alarm-notify; do
    [ -e "$AS/$a.desktop" ] || printf '[Desktop Entry]\nType=Application\nName=%s\nHidden=true\n' "$a" >"$AS/$a.desktop"
  done
  XC="$HOME/.config/xfce4/xfconf/xfce-perchannel-xml"
  if [ "$DE" = xfce ] && [ ! -f "$XC/xfwm4.xml" ]; then
    mkdir -p "$XC"
    cat >"$XC/xfwm4.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="use_compositing" type="bool" value="false"/>
  </property>
</channel>
XML
  fi
  if [ "$DE" = i3 ] && [ ! -f "$HOME/.config/i3/config" ]; then
    mkdir -p "$HOME/.config/i3"
    cp /etc/i3/config "$HOME/.config/i3/config" 2>/dev/null \
      || cp /etc/xdg/i3/config "$HOME/.config/i3/config" 2>/dev/null || true
  fi

  # Display :1 can be taken by another X server sharing the network namespace (Termux's own
  # vncserver, another distro): its abstract socket makes Xvnc fail with "server already running".
  # TigerVNC blacklists 127.0.0.1 after 5 "unauthenticated connections" (failed logins AND plain
  # probes that close before login) and then answers with an empty security type list - the app's
  # "Server refused:". A successful login clears the count. Keep a throttle against other apps
  # guessing the password, but with more headroom and a short initial block.
  XLOG="$XDG_RUNTIME_DIR/xvnc.log"
  D=1; started=0
  while [ "$D" -le 9 ]; do
    if ! clear_stale_display "$D"; then D=$((D + 1)); continue; fi
    # shellcheck disable=SC2086
    "$XV" ":$D" -geometry "$RES" -depth 24 -dpi "$DPI" -rfbport "$PORT" -localhost -AlwaysShared -ac \
      -BlacklistThreshold 20 -BlacklistTimeout 2 $SEC >"$XLOG" 2>&1 &
    CHILD=$!
    i=0
    while [ ! -S "/tmp/.X11-unix/X$D" ] && [ "$i" -lt 60 ] && kill -0 "$CHILD" 2>/dev/null; do
      sleep 0.5; i=$((i + 1))
    done
    if [ -S "/tmp/.X11-unix/X$D" ] && kill -0 "$CHILD" 2>/dev/null; then started=1; break; fi
    kill "$CHILD" 2>/dev/null; wait "$CHILD" 2>/dev/null; CHILD=""
    if grep -q -i -e "already running" -e "Cannot establish any listening sockets" "$XLOG" \
       && ! grep -q -i -e "Address already in use" -e "port $PORT" "$XLOG"; then
      echo "rb-session: display :$D is busy, trying :$((D + 1))" >&2
      D=$((D + 1)); continue
    fi
    cat "$XLOG" >&2
    die "Xvnc exited during startup (port $PORT busy or bad configuration, see above)"
  done
  [ "$started" = 1 ] || die "no free X display between :1 and :9"
  cat "$XLOG"; echo "rb-session: further Xvnc messages go to $XLOG (inside the container)"
  export DISPLAY=":$D"
  xsetroot -solid '#1b1b2f' 2>/dev/null || true
  echo "rb-session: x11 session '$DE' on display :$D, VNC 127.0.0.1:$PORT ($RES)"
  # Readiness marker for start_<distro>.sh: it must not poll the port, because Xvnc counts every
  # connection closed before authentication towards its blacklist.
  echo "RB_READY x11 $PORT"
  # Toolkits without a settings daemon (i3, plain X apps) read the DPI from the X resources
  if command -v xrdb >/dev/null 2>&1; then
    printf 'Xft.dpi: %s\nXcursor.size: %s\n' "$DPI" "$((24 * DPI / 96))" | xrdb -merge 2>/dev/null || true
  fi
  if [ "$DE" = xfce ] && [ ! -e "$CFG/no-touch-tuning" ]; then
    write_xfce_touch >"$CFG/xfce-touch.sh"
    # shellcheck disable=SC2016
    with_dbus sh -c '. "$1"; exec "$2"' sh "$CFG/xfce-touch.sh" "$RB_EXEC"
  else
    with_dbus "$RB_EXEC"
  fi
}

# Xfce for fingers: Android-sized text (DPI), big cursor, hi-DPI window decorations, single-click
# icons, a taller panel. Runs inside the session's D-Bus before Xfce starts; xfconf keeps the values.
# Opt out with: touch ~/.config/rombooter/no-touch-tuning
write_xfce_touch() {
  cat <<XFT
command -v xfconf-query >/dev/null 2>&1 || return 0
setp() { xfconf-query -c "\$1" -p "\$2" -s "\$4" 2>/dev/null || xfconf-query -c "\$1" -p "\$2" -n -t "\$3" -s "\$4" 2>/dev/null; }
setp xsettings /Xft/DPI int $DPI
setp xsettings /Gtk/CursorThemeSize int $((24 * DPI / 96))
if [ ! -e "$CFG/touch-defaults" ]; then
  for t in Default-xhdpi Default-hdpi; do
    if [ -d "/usr/share/themes/\$t/xfwm4" ]; then setp xfwm4 /general/theme string "\$t"; break; fi
  done
  setp xfwm4 /general/double_click_action string maximize
  setp xfce4-desktop /desktop-icons/single-click bool true
  setp thunar /misc-single-click bool true
  : >"$CFG/touch-defaults"
fi
# The panel writes its config on first start: never touch an empty channel (it would lose its plugins)
( i=0
  while [ \$i -lt 20 ]; do
    sleep 3; i=\$((i + 1))
    ids=\$(xfconf-query -c xfce4-panel -p /panels 2>/dev/null | grep -E '^[0-9]+\$') || continue
    for n in \$ids; do setp xfce4-panel "/panels/panel-\$n/size" uint $((32 * DPI / 96)); done
    break
  done ) &
XFT
}

# ---------- Wayland backend: headless wlroots compositor + wayvnc (mobile shell ready) ----------
run_wayland() {
  command -v wayvnc >/dev/null 2>&1 || die "wayvnc not installed"
  export XDG_SESSION_TYPE=wayland WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
         WLR_RENDERER=pixman WLR_RENDERER_ALLOW_SOFTWARE=1 MOZ_ENABLE_WAYLAND=1 GDK_BACKEND=wayland
  unset DISPLAY WAYLAND_DISPLAY
  echo "RB_BACKEND wayland"   # wayvnc has no blacklist: the start script may poll the port
  VNC="wayvnc --max-fps=30 127.0.0.1 $PORT"
  # wayvnc >= 0.9 can require a login without TLS (relax_encryption: Apple Diffie-Hellman, which the
  # app speaks). Older versions cannot, then the session is protected by loopback only.
  WV=$(wayvnc --version 2>/dev/null | sed -n 's/^wayvnc: *v\{0,1\}\([0-9]*\)\.\([0-9]*\).*/\1 \2/p' | head -n 1)
  if [ -n "$PASS" ]; then
    if [ -n "$WV" ] && { [ "${WV% *}" -gt 0 ] || [ "${WV#* }" -ge 9 ]; }; then
      umask 077
      printf 'enable_auth=true\nrelax_encryption=true\nusername=rombooter\npassword=%s\n' "$PASS" >"$CFG/wayvnc.conf"
      umask 022
      VNC="wayvnc -C $CFG/wayvnc.conf --max-fps=30 127.0.0.1 $PORT"
    else
      echo "rb-session: wayvnc ${WV:-?} cannot require a password; session is loopback-only without auth" >&2
    fi
  fi
  case "$DE" in
    sway)
      {
        [ -f /etc/sway/config ] && echo "include /etc/sway/config"
        echo "output HEADLESS-1 resolution ${W}x${H} scale $SCALE bg #1b1b2f solid_color"
        # Phone-like: every window fills the screen, tabs switch between them
        echo "workspace_layout tabbed"
        echo "default_border normal 2"
        echo "exec $VNC"
        if command -v foot >/dev/null 2>&1; then echo "exec foot"; fi
      } >"$CFG/sway.conf"
      echo "rb-session: wayland session 'sway' on 127.0.0.1:$PORT ($RES)"
      with_dbus sway --unsupported-gpu -c "$CFG/sway.conf" ;;
    phosh)
      PH=""
      for p in /usr/libexec/phosh /usr/lib/phosh/phosh /usr/lib/phosh /usr/bin/phosh; do
        [ -x "$p" ] && [ ! -d "$p" ] && { PH=$p; break; }
      done
      [ -n "$PH" ] || die "phosh binary not found"
      printf '[output:HEADLESS-1]\nmode = %sx%s\nscale = %s\n' "$W" "$H" "$SCALE" >"$CFG/phoc.ini"
      echo "rb-session: wayland session 'phosh' on 127.0.0.1:$PORT ($RES, scale $SCALE)"
      with_dbus phoc -C "$CFG/phoc.ini" -E "sh -c '$VNC & exec $PH'" ;;
    *)
      # Generic wlroots compositor: it must start wayvnc itself (e.g. via its autostart).
      echo "rb-session: wayland session '$DE' via $RB_EXEC (compositor must run: $VNC)"
      with_dbus "$RB_EXEC" ;;
  esac
}

case "$RB_BACKEND" in
  x11)     run_x11 ;;
  wayland) run_wayland ;;
  *)       die "session '$DE' has unknown backend '$RB_BACKEND'" ;;
esac
RB_SESSION
}

# Copy a file INSIDE the container through `proot-distro login` (works for every distro and every
# proot-distro layout). Writes to a temp name, renames atomically and verifies the checksum from the
# inside; retries because proot occasionally fails on the first login after an install.
guest_put() { # srcfile dest mode
  local src=$1 dest=$2 mode=$3 want got try
  want=$(cksum <"$src" | awk '{print $1, $2}')
  for try in 1 2 3; do
    if proot-distro login "$ALIAS" -- /bin/sh -c '
         set -e; d=$(dirname -- "$1"); mkdir -p "$d"
         cat >"$1.rbtmp"; chmod "$2" "$1.rbtmp"; mv -f "$1.rbtmp" "$1"' sh "$dest" "$mode" <"$src" &&
       got=$(proot-distro login "$ALIAS" -- /bin/sh -c 'cksum <"$1"' sh "$dest" 2>/dev/null | awk 'END {print $1, $2}') &&
       [[ $got == "$want" ]]; then
      return 0
    fi
    warn "Copy of $dest into $ALIAS failed (attempt $try/3)"
    sleep 1
  done
  return 1
}

readonly GUEST_PROV=/root/rb-provision.sh GUEST_SESS=/usr/local/bin/rb-session

copy_in() {
  local tmp
  tmp=$(mktemp -d "$TMPDIR/rombooter.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'; trap - RETURN" RETURN
  write_provision >"$tmp/prov"
  write_session   >"$tmp/sess"
  info "Copying provisioning files into the $ALIAS container"
  guest_put "$tmp/prov" "$GUEST_PROV" 755 || die "Could not place $GUEST_PROV inside the $ALIAS container."
  guest_put "$tmp/sess" "$GUEST_SESS" 755 || die "Could not place $GUEST_SESS inside the $ALIAS container."
  ok "Files present and verified inside the container"
}

provision() {
  copy_in
  info "Provisioning $KEY with '$DE' (this takes a while)"
  proot-distro login "$ALIAS" -- /bin/sh "$GUEST_PROV" "$USER_NAME" "$DE" </dev/null \
    || die "Provisioning failed inside $ALIAS (see output above); re-running the setup is safe."
  proot-distro login "$ALIAS" -- /bin/sh -c 'rm -f "$1"' sh "$GUEST_PROV" || true
  proot-distro login "$ALIAS" --user "$USER_NAME" -- /bin/sh "$GUEST_SESS" --list >/dev/null \
    || die "$GUEST_SESS is not runnable as '$USER_NAME' inside $ALIAS."
  ok "Guest provisioned"
}

# ---------- host side: start_<distro>.sh ----------
write_start_script() {
  local out="$HOME/start_${KEY}.sh"
  {
    printf '#!%s/bin/bash\n' "$PREFIX"
    printf '# start_%s.sh - generated by rombooter-setup %s\n' "$KEY" "$VERSION"
    printf 'ALIAS=%q; KEY=%q; DE=%q; RES=%q; GUEST_USER=%q\n' "$ALIAS" "$KEY" "${DE%%,*}" "$RES" "$USER_NAME"
    declare -f valid_res
    cat <<'RB_START'
set -Eeuo pipefail
# Exit codes: 0 ready/stopped, 1 session failed, 2 bad arguments, 3 timeout, 4 not set up, 5 port busy
PORT=${RB_VNC_PORT:-5901}
PASS=""; STOP=0; RESTART=0; STATUS=0; ready_seen=0; DPI=96
STATE="$HOME/.rombooter"; LOG="$STATE/$KEY.log"; SESSION_FILE="$STATE/session"
mkdir -p "$STATE"; chmod 700 "$STATE"

usage() { echo "usage: ${0##*/} [--res WxH] [--pass P] [--de NAME] [--dpi N] [--stop] [--restart] [--status]" >&2; }
bad()   { echo "ERROR: $*" >&2; usage; exit 2; }

while (($#)); do
  opt=$1
  if [[ $opt == --*=* ]]; then set -- "${opt%%=*}" "${opt#*=}" "${@:2}"; opt=$1; fi
  case $opt in
    --res|--pass|--de|--dpi)
      # An empty value is allowed only for --pass (= no password); a following --flag is never a value.
      (($# >= 2)) || bad "$opt needs a value"
      [[ $2 != --* ]] || bad "$opt needs a value (got option '$2')"
      case $opt in --res) RES=$2 ;; --pass) PASS=$2 ;; --de) DE=${2,,} ;; --dpi) DPI=$2 ;; esac
      shift 2 ;;
    --stop)    STOP=1; shift ;;
    --restart) RESTART=1; shift ;;
    --status)  STATUS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)
      # Newer apps may pass options this script does not know: ignore them (and their value)
      echo "WARN: ignoring unknown argument '$opt'" >&2
      if (($# >= 2)) && [[ $2 != -* ]]; then shift 2; else shift; fi ;;
    *) echo "WARN: ignoring stray argument '$opt'" >&2; shift ;;
  esac
done
valid_res "$RES"                 || bad "--res must be WxH, 240..4096 per side (got '$RES')"
[[ $DE =~ ^[a-z0-9_-]{1,32}$ ]]  || bad "--de must be a session name like xfce, i3, sway, phosh (got '$DE')"
if [[ ! $DPI =~ ^[0-9]{2,3}$ ]] || ((DPI < 72 || DPI > 384)); then bad "--dpi must be 72..384 (got '$DPI')"; fi
if [[ -n $PASS ]]; then
  [[ $PASS =~ ^[[:graph:]]{6,64}$ ]] || bad "--pass must be 6-64 printable characters without spaces"
  ((${#PASS} <= 8)) || echo "WARN: VNC authentication only uses the first 8 characters of --pass" >&2
fi

port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; }
# A listening socket is not enough: the app hits EOF if the server accepts and then drops the client.
rfb_ready() {
  local banner
  banner=$( (exec 3<>"/dev/tcp/127.0.0.1/$PORT" && IFS= read -r -t 5 -N 12 b <&3; printf '%s' "${b:-}") 2>/dev/null ) || true
  [[ $banner == "RFB "* ]]
}
fingerprint() { printf '%s|%s|%s|%s|%s' "$KEY" "$DE" "$RES" "$DPI" "$PASS" | sha256sum | cut -c1-32; }

read_session() { # -> S_KEY S_PGID S_FP (empty if none)
  S_KEY=""; S_PGID=""; S_FP=""
  [[ -f $SESSION_FILE ]] && read -r S_KEY S_PGID S_FP <"$SESSION_FILE" || true
}
# A process group is alive if it has a member that is not a zombie (killed processes stay zombies
# until reaped, and kill -0 still "finds" them).
alive() {
  [[ $1 =~ ^[0-9]+$ ]] && kill -0 -- "-$1" 2>/dev/null || return 1
  local f st rest state pgrp
  for f in /proc/[0-9]*/stat; do
    IFS= read -r st <"$f" 2>/dev/null || continue
    rest=${st##*) }                       # "<state> <ppid> <pgrp> ..."; comm may contain spaces
    read -r state _ pgrp _ <<<"$rest"
    [[ $pgrp == "$1" && $state != Z && $state != X ]] && return 0
  done
  [[ -r /proc/self/stat ]] || return 0    # /proc not readable: trust kill -0
  return 1
}

stop_session() {
  read_session
  if [[ $S_PGID =~ ^[0-9]+$ ]]; then
    kill -TERM -- "-$S_PGID" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do alive "$S_PGID" || break; sleep 0.5; done
    kill -KILL -- "-$S_PGID" 2>/dev/null || true
  fi
  # Fallback only for sessions without a known process group (1.0.x scripts, no setsid)
  if [[ ! $S_PGID =~ ^[0-9]+$ ]] || port_open; then
    pkill -f "^[^ ]*Xvnc :[1-9] .*-rfbport $PORT " 2>/dev/null || true
    pkill -f "^[^ ]*Xtigervnc :[1-9] .*-rfbport $PORT " 2>/dev/null || true
    pkill -f "^[^ ]*Xvnc :1 " 2>/dev/null || true   # 1.0.x sessions
    pkill -f "^wayvnc .*127\.0\.0\.1 $PORT\$" 2>/dev/null || true
    pkill -f "^/bin/sh /usr/local/bin/rb-session " 2>/dev/null || true
  fi
  rm -f "$SESSION_FILE"
  for _ in 1 2 3 4 5 6 7 8 9 10; do port_open || return 0; sleep 0.5; done
  return 1
}

if ((STOP)); then
  if stop_session; then echo "STOPPED"; exit 0; fi
  echo "ERROR: port $PORT still in use after stop" >&2; exit 5
fi
# RUNNING KEY | STOPPED | EXITED CODE | KILLED (by Android: SIGKILL or vanished without a trace).
# No connection to the VNC port here: Xvnc counts those towards its blacklist.
if ((STATUS)); then
  read_session
  if [[ $S_PGID =~ ^[0-9]+$ ]] && alive "$S_PGID"; then echo "RUNNING $S_KEY $PORT"; exit 0; fi
  if [[ -z $S_KEY || $S_KEY != "$KEY" ]] || ! grep -q '^RB_READY ' "$LOG" 2>/dev/null; then echo "STOPPED"; exit 0; fi
  code=$(sed -n 's/^RB_EXIT \([0-9]*\)$/\1/p' "$LOG" | tail -n 1)
  if [[ -z $code || $code == 137 || $code == 9 ]]; then echo "KILLED"; else echo "EXITED $code"; fi
  exit 0
fi

command -v proot-distro >/dev/null 2>&1 || { echo "ERROR: proot-distro missing - run rombooter-setup.sh" >&2; exit 4; }

if port_open; then
  read_session
  if ((!RESTART)) && [[ $S_KEY == "$KEY" && $S_FP == "$(fingerprint)" ]] && rfb_ready; then
    echo "READY $PORT (already running)"; exit 0
  fi
  # Different distro, session, size or password (or a dead/foreign server): replace it, otherwise
  # the app would connect to the wrong desktop or fail VNC authentication.
  echo "restarting session (${S_KEY:-unknown} -> $KEY)" >&2
  stop_session || { echo "ERROR: port $PORT is used by another program" >&2; exit 5; }
elif [[ -f $SESSION_FILE ]]; then
  stop_session || true   # stale processes without a listening port
fi

if ! proot-distro login "$ALIAS" --user "$GUEST_USER" -- /bin/sh -c 'test -x /usr/local/bin/rb-session' </dev/null >/dev/null 2>&1; then
  echo "ERROR: $ALIAS is not provisioned for '$GUEST_USER' - run: bash rombooter-setup.sh --distro $KEY" >&2
  exit 4
fi

if command -v termux-wake-lock >/dev/null 2>&1; then termux-wake-lock >/dev/null 2>&1 || true; fi

# Audio: PulseAudio on Termux side, loopback-only TCP; guest uses PULSE_SERVER=127.0.0.1
if command -v pulseaudio >/dev/null 2>&1 && ! pulseaudio --check 2>/dev/null; then
  pulseaudio --start --exit-idle-time=-1 \
    --load="module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1" >/dev/null 2>&1 || true
  { pactl list short sinks 2>/dev/null | grep -q .; } || pactl load-module module-sles-sink >/dev/null 2>&1 || true
fi

# Own session (setsid) so --stop can kill proot and everything below it at once.
# The password goes through stdin, never through argv.
SETSID=(); command -v setsid >/dev/null 2>&1 && SETSID=(setsid)
: >"$LOG"; chmod 600 "$LOG"
# The wrapper records how the session ended (RB_EXIT): --status uses it to tell a normal logout
# from Android killing the session (phantom process killer: SIGKILL, often without any exit record).
printf '%s\n' "$PASS" | "${SETSID[@]}" nohup bash -c 'proot-distro login "$@"; echo "RB_EXIT $?"' rb-session-wrap "$ALIAS" --user "$GUEST_USER" -- \
  /usr/local/bin/rb-session --res "$RES" --de "$DE" --port "$PORT" --dpi "$DPI" --pass-stdin >>"$LOG" 2>&1 &
GPID=$!
if ((${#SETSID[@]})); then
  printf '%s %s %s\n' "$KEY" "$GPID" "$(fingerprint)" >"$SESSION_FILE"
else
  printf '%s - %s\n' "$KEY" "$(fingerprint)" >"$SESSION_FILE"
fi

# Xvnc counts every connection that closes before authentication as a failed login and blacklists
# 127.0.0.1 after a few (the app then sees "Server refused:"). So wait for rb-session's RB_READY
# marker and probe the port only once it is up (and rarely after that).
for i in $(seq 1 "${RB_START_TIMEOUT:-180}"); do
  probe=0
  if grep -q '^RB_READY ' "$LOG"; then
    ((i % 5 == 1 || ready_seen++ == 0)) && probe=1
  elif grep -q '^RB_BACKEND wayland' "$LOG"; then
    probe=1                                   # wayvnc: polling is harmless
  elif ((i >= 30 && i % 10 == 0)); then
    probe=1                                   # rb-session without markers (1.0.x)
  fi
  if ((probe)) && rfb_ready; then echo "READY $PORT"; exit 0; fi
  if ! kill -0 "$GPID" 2>/dev/null; then
    rm -f "$SESSION_FILE"
    echo "ERROR: session exited early, log: $LOG" >&2; tail -n 20 "$LOG" >&2; exit 1
  fi
  sleep 1
done
echo "ERROR: timeout waiting for 127.0.0.1:$PORT, log: $LOG" >&2
tail -n 20 "$LOG" >&2
exit 3
RB_START
  } >"$out"
  chmod 700 "$out"
  ok "Created $out"
}

summary() {
  printf '\n%s%s ready.%s\n' "$C_G" "$KEY" "$C_X"
  printf '  Start : %s~/start_%s.sh --res %s --de %s%s\n' "$C_C" "$KEY" "$RES" "${DE%%,*}" "$C_X"
  printf '  Stop  : %s~/start_%s.sh --stop%s\n' "$C_C" "$KEY" "$C_X"
  printf '  VNC   : 127.0.0.1:5901 (loopback only; --pass sets a VNC password, first 8 chars count)\n'
  printf '  Log   : ~/.rombooter/%s.log\n' "$KEY"
}

# Update the scripts of an installed distro to this version: ~/start_<distro>.sh and the guest's
# rb-session. No packages, no provisioning, no new rootfs; container alias, user, resolution and
# default session are taken over from the existing start script.
refresh_scripts() {
  local s="$HOME/start_${KEY}.sh" line tmp
  [[ -f $s ]] || die "$s not found - run a full setup for $KEY first."
  line=$(grep -m1 '^ALIAS=' "$s") || die "$s has no settings line; run a full setup."
  [[ $line =~ ^ALIAS=([a-z0-9_-]+)\;\ KEY=([a-z]+)\;\ DE=([a-z0-9_-]+)\;\ RES=([0-9]+x[0-9]+)\;\ GUEST_USER=([a-z_][a-z0-9_-]*)$ ]] \
    || die "Unexpected settings line in $s; run a full setup."
  [[ ${BASH_REMATCH[2]} == "$KEY" ]] || die "$s belongs to ${BASH_REMATCH[2]}, not $KEY."
  ALIAS=${BASH_REMATCH[1]}; DE=${BASH_REMATCH[3]}; RES=${BASH_REMATCH[4]}; USER_NAME=${BASH_REMATCH[5]}
  command -v proot-distro >/dev/null 2>&1 || die "proot-distro not found."
  guest_sh ':' >/dev/null 2>&1 || die "Container $ALIAS does not start; run a full setup."
  tmp=$(mktemp -d "$TMPDIR/rombooter.XXXXXX")
  write_session >"$tmp/sess"
  guest_put "$tmp/sess" "$GUEST_SESS" 755 || { rm -rf "${tmp:?}"; die "Could not update $GUEST_SESS in $ALIAS."; }
  rm -rf "${tmp:?}"
  write_start_script
  ok "$KEY scripts updated to $VERSION (rootfs and packages unchanged)"
}

main() {
  # shellcheck disable=SC2154
  trap 'rc=$?; err "Failed (exit $rc) at line $LINENO: $BASH_COMMAND"; exit $rc' ERR
  trap 'err "Interrupted"; exit 130' INT TERM
  parse_args "$@"
  if ((REFRESH)); then
    [[ -n $DISTRO ]] || die "--refresh needs --distro"
    mkdir -p "$TMPDIR"
    resolve_distro
    refresh_scripts
    return
  fi
  preflight
  [[ -n $DISTRO ]] || menu
  resolve_distro
  confirm
  install_host_deps
  enable_termux_external
  prepare_distro
  install_distro
  provision
  write_start_script
  summary
}

# Sourcing the file (tests) only defines the functions.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
