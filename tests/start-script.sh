#!/usr/bin/env bash
# Behaviour tests for the generated start_<distro>.sh (argument handling, password transport,
# restart/stop logic, early-exit reporting) with a fake proot-distro and a fake VNC server.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
tmp=$(mktemp -d)
export FAKE_DIR="$tmp/fake" RB_VNC_PORT=$((20000 + RANDOM % 20000)) RB_START_TIMEOUT=8
export PATH="$ROOT/tests/fixtures:$PATH" HOME="$tmp/home"
mkdir -p "$FAKE_DIR" "$HOME"
gen debian xfce,i3 "$HOME" >/dev/null
S="$HOME/start_debian.sh"
cleanup() { bash "$S" --stop >/dev/null 2>&1; rm -rf "$tmp"; }
trap cleanup EXIT

run() { OUT=$(bash "$S" "$@" 2>"$tmp/err"); RC=$?; ERR=$(cat "$tmp/err"); }
expect_rc() { # rc description args...
  local want=$1 d=$2; shift 2
  run "$@"
  if [[ $RC == "$want" ]]; then pass "$d (exit $RC)"; else fail "$d: want exit $want, got $RC; stderr: $ERR"; fi
}

echo "argument validation"
expect_rc 2 "--pass without value"          --res 1280x576 --pass
expect_rc 2 "--pass followed by an option"  --pass --de xfce
expect_rc 2 "--pass too short"              --pass abc
expect_rc 2 "--pass with a space"           --pass "abc def12"
expect_rc 2 "--res malformed"               --res 1280
expect_rc 2 "--res out of range"            --res 99999x1
expect_rc 2 "--de with bad characters"      --de 'x;rm'
expect_rc 2 "--dpi out of range"            --dpi 500
expect_rc 2 "--dpi not a number"            --dpi big
expect_rc 0 "unknown option is ignored, not fatal" --bogus --status
check "...with a warning naming it" grep -q "ignoring unknown argument '--bogus'" <<<"$ERR"
expect_rc 0 "unknown option with a value is skipped as a pair" --future-scale 2 --status
check "...the value is not mistaken for anything else" bash -c '[[ $1 != *"stray"* ]]' _ "$ERR"

echo "not provisioned"
FAKE_UNPROVISIONED=1 expect_rc 4 "rb-session missing in the guest" --pass Abc12345

echo "start"
rm -f "$FAKE_DIR/conns"
expect_rc 0 "start with app-style arguments" --res 1280x576 --pass Abc12345 --de xfce
check "guest rb-session ignores unknown options too (exit 0, warning)" bash -c '
  out=$(sh "$1/rb-session" --future-opt x --list 2>&1) && [[ $out == *"ignoring unknown option '"'"'--future-opt'"'"'"* ]]' _ "$HOME"
check "prints READY" grep -qx "READY $RB_VNC_PORT" <<<"$OUT"
check "password reaches the guest via stdin" grep -qx Abc12345 "$FAKE_DIR/pass"
check "password is not on the guest command line" bash -c '! grep -q Abc12345 "$1"' _ "$FAKE_DIR/argv"
check "guest gets --res/--de/--port/--dpi" grep -q -- "--res 1280x576 --de xfce --port $RB_VNC_PORT --dpi 96 --pass-stdin" "$FAKE_DIR/argv"
check "at most one readiness probe (Xvnc blacklists unauthenticated connections)" \
  bash -c '(( $(wc -l <"$1") <= 1 ))' _ "$FAKE_DIR/conns"
check "session file records the process group" bash -c 'read -r k p f <"$1" && [[ $k == debian && $p =~ ^[0-9]+$ ]]' _ "$HOME/.rombooter/session"

expect_rc 0 "second start with same arguments" --res 1280x576 --pass Abc12345 --de xfce
check "reuses the running session" grep -q "already running" <<<"$OUT"

rm -f "$FAKE_DIR/pass"
expect_rc 0 "start with a different password" --res 1280x576 --pass Xyz98765 --de xfce
check "restarts instead of reusing (auth would fail)" grep -qx Xyz98765 "$FAKE_DIR/pass"

expect_rc 0 "--pass=value form and empty password" --res=1280x576 --pass= --de=i3
check "empty password reaches guest as empty line" bash -c '[[ ! -s $1 || $(cat "$1") == "" ]]' _ "$FAKE_DIR/pass"

expect_rc 0 "start with an app-chosen DPI" --res 1280x576 --pass Abc12345 --de xfce --dpi 134
check "DPI change restarts the session and reaches the guest" grep -q -- "--dpi 134" "$FAKE_DIR/argv"
expect_rc 0 "--status while running" --status
check "status reports RUNNING" grep -q "^RUNNING debian" <<<"$OUT"

echo "stop"
expect_rc 0 "--stop" --stop
check "port closed after stop" bash -c '! (exec 3<>/dev/tcp/127.0.0.1/$1) 2>/dev/null' _ "$RB_VNC_PORT"
check "session file removed" test ! -e "$HOME/.rombooter/session"
expect_rc 0 "--stop when nothing runs" --stop

echo "kill detection (Android phantom process killer)"
expect_rc 0 "start" --pass Abc12345
read -r _ pg _ <"$HOME/.rombooter/session"
kill -KILL -- "-$pg"; sleep 1
expect_rc 0 "--status after SIGKILL of the session" --status
check "reports KILLED" grep -qx KILLED <<<"$OUT"
expect_rc 0 "start again" --pass Abc12345
pkill -TERM -f "^python3 [^ ]*/fake_rfb[.]py$"; sleep 1
expect_rc 0 "--status after the session ended by itself" --status
check "reports EXITED with the exit code" grep -qx "EXITED 143" <<<"$OUT"
bash "$S" --stop >/dev/null 2>&1
expect_rc 0 "--status after --stop" --status
check "reports STOPPED" grep -qx STOPPED <<<"$OUT"
expect_rc 0 "start for the probe count" --pass Abc12345
n0=$(wc -l <"$FAKE_DIR/conns")
for _ in 1 2 3 4 5; do bash "$S" --status >/dev/null 2>&1; done
check "--status never connects to the VNC port (Xvnc would count it as a failed login)" \
  test "$(wc -l <"$FAKE_DIR/conns")" -eq "$n0"
bash "$S" --stop >/dev/null 2>&1

echo "failure reporting"
FAKE_MODE=die expect_rc 1 "session dies during startup" --pass Abc12345
check "stderr carries the guest log tail" grep -q "Xvnc exited during startup" <<<"$ERR"
FAKE_MODE=eof expect_rc 3 "server accepts but never speaks RFB (EOF case)" --pass Abc12345
check "no READY for a silent server" bash -c '! grep -q READY <<<"$1"' _ "$OUT"
bash "$S" --stop >/dev/null 2>&1

finish
