#!/usr/bin/env bash
# Rootfs downloads without a container registry: official Gentoo stage3 (mirror fallback, official
# SHA-256), Arch Linux ARM fallback for Arch (official MD5). The network is simulated by a fake
# curl serving files from a directory, so no real mirror is contacted.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export FAKE_NET="$tmp/net" PATH="$ROOT/tests/fixtures/net:$PATH"
mkdir -p "$FAKE_NET" "$tmp/rootfs/etc" && echo rootfs >"$tmp/rootfs/etc/os-release"

run_setup() { # snippet -> runs in a subshell with the setup's functions and a fake Termux prefix
  ( source "$SETUP"; PREFIX="$tmp/prefix"; PLUGIN_DIR="$tmp/prefix/etc/proot-distro"
    DLCACHE="$tmp/prefix/var/lib/proot-distro/dlcache"; eval "$1" ) >"$tmp/out" 2>&1
}
# readonly in the setup; the fixture paths are passed by redefining them in a copy
sed -e 's|^readonly PLUGIN_DIR=.*|PLUGIN_DIR="$PREFIX/etc/proot-distro"|' \
    -e 's|^readonly DLCACHE=.*|DLCACHE="$PREFIX/var/lib/proot-distro/dlcache"|' "$SETUP" >"$tmp/setup.sh"
SETUP="$tmp/setup.sh"

echo "gentoo (official stage3)"
G=releases/arm64/autobuilds; ST=20261020T170324Z/stage3-arm64-openrc-20261020T170324Z.tar.xz
for h in distfiles.gentoo.org gentoo.osuosl.org; do mkdir -p "$FAKE_NET/$h/$G/${ST%/*}"; done
tar -C "$tmp/rootfs" -cJf "$FAKE_NET/gentoo.osuosl.org/$G/$ST" .
SUM=$(sha256sum "$FAKE_NET/gentoo.osuosl.org/$G/$ST" | cut -d' ' -f1)
cat >"$FAKE_NET/gentoo.osuosl.org/$G/latest-stage3-arm64-openrc.txt" <<TXT
-----BEGIN PGP SIGNED MESSAGE-----
Hash: SHA512

# Latest as of Mon, 20 Oct 2026 17:03:24 +0000
# ts=1792429404
$ST 271234567
-----BEGIN PGP SIGNATURE-----
iQIzBAEBCgAdFiEE
-----END PGP SIGNATURE-----
TXT
printf -- '-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA256\n\n# SHA256 HASH\n%s  %s\n' "$SUM" "${ST#*/}" \
  >"$FAKE_NET/gentoo.osuosl.org/$G/$ST.sha256"

FAKE_DOWN="distfiles.gentoo.org" run_setup 'register_gentoo'; rc=$?
check "primary mirror down -> falls back to the next official mirror" test $rc -eq 0
check "only Gentoo's own servers were contacted" bash -c '! grep -qv -e gentoo.org -e gentoo.osuosl.org -e leaseweb.com/gentoo "$1"' _ "$FAKE_NET/requests"
check "no container registry involved" bash -c '! grep -qi -e docker -e registry "$1"' _ "$FAKE_NET/requests"
check "verified against the official SHA-256" grep -q "official checksum verified" "$tmp/out"
check "plugin pins the official hash" grep -q "TARBALL_SHA256\['aarch64'\]=\"$SUM\"" "$tmp/prefix/etc/proot-distro/gentoo.sh"
check "plugin points at the official tarball" grep -q "TARBALL_URL\['aarch64'\]=\"https://distfiles.gentoo.org/$G/$ST\"" "$tmp/prefix/etc/proot-distro/gentoo.sh"
check "tarball in proot-distro's download cache" test -s "$tmp/prefix/var/lib/proot-distro/dlcache/${ST#*/}"

rm -rf "$tmp/prefix"
cp "$FAKE_NET/gentoo.osuosl.org/$G/$ST" "$tmp/good"; echo corrupt >>"$FAKE_NET/gentoo.osuosl.org/$G/$ST"
FAKE_DOWN="distfiles.gentoo.org" run_setup 'register_gentoo'; rc=$?
check "a tarball that does not match the official SHA-256 is refused" test $rc -ne 0
check "...and not registered" test ! -e "$tmp/prefix/etc/proot-distro/gentoo.sh"
cp "$tmp/good" "$FAKE_NET/gentoo.osuosl.org/$G/$ST"

echo "arch (Arch Linux ARM fallback)"
A=os/ArchLinuxARM-aarch64-latest.tar.gz
mkdir -p "$FAKE_NET/de.mirror.archlinuxarm.org/os" "$tmp/bin"
tar -C "$tmp/rootfs" -czf "$FAKE_NET/de.mirror.archlinuxarm.org/$A" .
md5sum "$FAKE_NET/de.mirror.archlinuxarm.org/$A" | sed 's|  .*|  ArchLinuxARM-aarch64-latest.tar.gz|' >"$FAKE_NET/de.mirror.archlinuxarm.org/$A.md5"
# proot-distro whose archlinux image cannot be installed; the fallback alias works once registered
cat >"$tmp/bin/proot-distro" <<PD
#!/usr/bin/env bash
case "\$1 \$2" in
  "login archlinux-alarm") [[ -f "$tmp/prefix/etc/proot-distro/archlinux-alarm.sh" && -f "$tmp/alarm-installed" ]] ;;
  "login "*) exit 1 ;;
  "install archlinux") echo "Error: no rootfs for aarch64" >&2; exit 1 ;;
  "install archlinux-alarm") touch "$tmp/alarm-installed" ;;
  "remove "*) exit 0 ;;
esac
PD
chmod +x "$tmp/bin/proot-distro"
: >"$FAKE_NET/requests"
PATH="$tmp/bin:$PATH" FAKE_DOWN="fl.us.mirror.archlinuxarm.org" run_setup \
  'DISTRO=arch; resolve_distro; install_distro; echo "ALIAS=$ALIAS"'; rc=$?
check "proot-distro's archlinux failing -> official Arch Linux ARM rootfs installed" test $rc -eq 0
check "container alias switches to archlinux-alarm" grep -q "^ALIAS=archlinux-alarm" "$tmp/out"
check "verified against the official MD5" grep -q "matches the official MD5" "$tmp/out"
check "only archlinuxarm.org mirrors were contacted" bash -c '! grep -qv archlinuxarm.org "$1"' _ "$FAKE_NET/requests"
PATH="$tmp/bin:$PATH" run_setup 'DISTRO=arch; resolve_distro; install_distro; echo "ALIAS=$ALIAS"'
check "second run reuses the fallback container" grep -q "^ALIAS=archlinux-alarm" "$tmp/out"
check "...without downloading again" grep -q "already installed" "$tmp/out"

rm -rf "$tmp/prefix" "$tmp/alarm-installed"
echo "0123456789abcdef0123456789abcdef  x" >"$FAKE_NET/de.mirror.archlinuxarm.org/$A.md5"
PATH="$tmp/bin:$PATH" run_setup 'DISTRO=arch; resolve_distro; install_distro'; rc=$?
check "an Arch Linux ARM tarball with the wrong MD5 is refused" test $rc -ne 0
check "...and its plugin removed" test ! -e "$tmp/prefix/etc/proot-distro/archlinux-alarm.sh"

finish
