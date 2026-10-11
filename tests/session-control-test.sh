#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SC="$ROOT/system_files/usr/libexec/armada/session-control"
export ARMADA_PLASMA_SESSION_LIB="$ROOT/system_files/usr/lib/armada/plasma-session-lib"
REAL_FLOCK="$(command -v flock)"
REAL_SLEEP="$(command -v sleep)"
export REAL_FLOCK REAL_SLEEP

T="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf -- "$T"' EXIT
export STATE="$T/state"
mkdir -p "$T/bin" "$T/sddm" "$T/run" "$T/wayland-sessions" "$T/sessions.d" "$T/empty.d" "$T/bad.d" "$STATE" \
    "$T/home/.local/share/Steam/steamrtarm64"
python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$T/run/bus"
: > "$T/home/.local/share/Steam/steamrtarm64/steam"
chmod 0755 "$T/home/.local/share/Steam/steamrtarm64/steam"

for name in x y good gamescope-session-steam armada-plasma armada-plasma-mobile; do
    : > "$T/wayland-sessions/$name.desktop"
done
printf 'DESKTOP=x.desktop\nUNIT=gamescope-session-plus@x.service\n' > "$T/sessions.d/x.conf"
printf 'UNIT=gamescope-session-plus@y.service\nDESKTOP=y.desktop' > "$T/sessions.d/y.conf"

printf 'DESKTOP=good.desktop\nUNIT=gamescope-session-plus@good.service\n' > "$T/bad.d/good.conf"
printf 'DESKTOP=x.desktop\n' > "$T/bad.d/nounit.conf"
printf 'UNIT=gamescope-session-plus@nodesk.service\n' > "$T/bad.d/nodesk.conf"
printf 'DESKTOP=absent.desktop\nUNIT=gamescope-session-plus@absent.service\n' > "$T/bad.d/absent.conf"
printf 'DESKTOP=../x.desktop\nUNIT=gamescope-session-plus@dots.service\n' > "$T/bad.d/dots.conf"
printf 'DESKTOP=x.desktop\nUNIT=sshd.service\n' > "$T/bad.d/notsession.conf"
printf 'DESKTOP=x.desktop\nUNIT=gamescope-session-plus@steam.service\n' > "$T/bad.d/steamunit.conf"
printf 'DESKTOP=gamescope-session-steam.desktop\nUNIT=gamescope-session-plus@steamdesk.service\n' > "$T/bad.d/steamdesk.conf"
printf 'DESKTOP=armada-plasma-mobile.desktop\nUNIT=gamescope-session-plus@plasmadesk.service\n' > "$T/bad.d/plasmadesk.conf"
printf 'DESKTOP=x.desktop\nUNIT=gamescope-session-plus@a;b.service\n' > "$T/bad.d/semi.conf"
for name in Upper -lead 'a b' 'a;b' gamemode desktop; do
    printf 'DESKTOP=x.desktop\nUNIT=gamescope-session-plus@x.service\n' > "$T/bad.d/$name.conf"
done
printf 'DESKTOP=x.desktop\nUNIT=gamescope-session-plus@x.service\n' > "$T/x.conf"
mkdir -p "$T/dup.d"
printf 'DESKTOP=x.desktop\nUNIT=gamescope-session-plus@x.service\n' > "$T/dup.d/a.conf"
printf 'DESKTOP=y.desktop\nUNIT=gamescope-session-plus@x.service\n' > "$T/dup.d/b.conf"

for entry in "101:session.slice/plasma-plasmashell.service" "102:app.slice/gamescope-session-plus@steam.service" \
    "103:app.slice/armada-bottom-screen.service" "104:app.slice/armada-plasma-nested-42.service"; do
    mkdir -p "$T/proc/${entry%%:*}"
    echo "0::/user.slice/user-1000.slice/user@1000.service/${entry#*:}" > "$T/proc/${entry%%:*}/cgroup"
done

cat > "$T/bin/pop" <<'EOF'
#!/usr/bin/env bash
f="$STATE/$1"
[[ -s "$f" ]] || { echo inactive; exit 0; }
first=$(head -n 1 "$f")
if [[ $(wc -l < "$f") -gt 1 ]]; then
    tail -n +2 "$f" > "$f.tmp"
    mv "$f.tmp" "$f"
fi
printf '%s\n' "$first"
EOF

cat > "$T/bin/sudo" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|-Eu) shift 2 ;;
        env) shift; break ;;
        *) shift ;;
    esac
done
vars=()
while [[ "${1:-}" == *=* ]]; do vars+=("$1"); shift; done
echo "sudo ${vars[*]} :: $*" >> "$STATE/calls"
at() { tail -n 1 "$ARMADA_SDDM_CONF_DIR/zz-holo-autologin.conf" > "$STATE/at_$1" 2>/dev/null || true; }
case "$*" in
    "systemctl --user is-active --quiet -- "*)
        [[ "$(pop "unit.$6")" == active ]] ;;
    "systemctl --user stop -- "*)
        at stop
        [[ -e "$STATE/stopfail" ]] && exit 1
        echo inactive > "$STATE/unit.$5" ;;
    "busctl --user status org.kde.Shutdown")
        [[ "$(cat "$STATE/plasma")" == 1 ]] ;;
    *"/steam -shutdown")
        at shutdown
        printf '%s\n' "${vars[@]}" > "$STATE/shutdown_env" ;;
    *qdbus*)
        at logout
        exit 0 ;;
    *)
        echo "unexpected sudo command: $*" >&2; exit 99 ;;
esac
EOF

cat > "$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$STATE/calls"
EOF

cat > "$T/bin/loginctl" <<'EOF'
#!/usr/bin/env bash
echo "loginctl $*" >> "$STATE/calls"
case "$1" in
    list-sessions)
        echo '[{"session":"1","uid":969,"user":"sddm","seat":"seat0","class":"user"},{"session":"16","uid":1000,"user":"armada","seat":"seat0","class":"user"},{"session":"7","uid":1000,"user":"armada","seat":null,"class":"user"}]' ;;
    show-session)
        [[ "$5" == 16 ]] || { echo "loginctl: unexpected $*" >&2; exit 99; }
        case "$(pop sessions)" in
            active)  echo active ;;
            closing) echo closing ;;
            *)       echo "Could not get properties: No session '16' known" >&2; exit 1 ;;
        esac ;;
esac
EOF

cat > "$T/bin/sleep" <<'EOF'
#!/usr/bin/env bash
echo "sleep $*" >> "$STATE/calls"
if [[ -e "$STATE/hold_sleep" ]]; then
    : > "$STATE/in_sleep"
    while [[ -e "$STATE/hold_sleep" ]]; do "$REAL_SLEEP" 0.02; done
fi
EOF

cat > "$T/bin/flock" <<'EOF'
#!/usr/bin/env bash
echo "flock $*" >> "$STATE/calls"
[[ "$1" == -w ]] && shift 2
exec "$REAL_FLOCK" -n "$@"
EOF

cat > "$T/bin/timeout" <<'EOF'
#!/usr/bin/env bash
echo "timeout $*" >> "$STATE/calls"
shift
exec "$@"
EOF

cat > "$T/bin/controller-type" <<'EOF'
#!/usr/bin/env bash
echo "controller-type $*" >> "$STATE/calls"
exit "$(cat "$STATE/ct_rc")"
EOF

cat > "$T/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
echo "pgrep $*" >> "$STATE/calls"
pids=$(pop plasmashell)
[[ "$pids" == inactive || "$pids" == - ]] && exit 1
tr ',' '\n' <<< "$pids"
EOF

cat > "$T/bin/logger" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STATE/logger"
EOF

cat > "$T/bin/getent" <<'EOF'
#!/usr/bin/env bash
echo "armada:x:1000:1000::$HOME_DIR:/bin/bash"
EOF

cat > "$T/bin/qdbus-qt6" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod 0755 "$T"/bin/*
export PATH="$T/bin:$PATH"
export HOME_DIR="$T/home"
export ARMADA_SDDM_CONF_DIR="$T/sddm"
export ARMADA_SESSION_RUNTIME_DIR="$T/run"
export ARMADA_WAYLAND_SESSIONS_DIR="$T/wayland-sessions"
export ARMADA_SWITCH_LOCK="$T/lock/session-switch.lock"
export ARMADA_CONTROLLER_TYPE="$T/bin/controller-type"
export ARMADA_SHORT_SESSION_TRACKER="$T/tracker"
export ARMADA_PROC_DIR="$T/proc"
LOCK="$ARMADA_SWITCH_LOCK"

failures=0
case_name=
sessions_dir="$T/sessions.d"

setup() {
    case_name=$1
    sessions_dir=${2:-$T/sessions.d}
    rm -rf "$STATE"
    mkdir -p "$STATE"
    : > "$STATE/calls"
    : > "$STATE/logger"
    echo 0 > "$STATE/plasma"
    echo 0 > "$STATE/ct_rc"
    echo gone > "$STATE/sessions"
    echo "steam failed" > "$T/tracker"
    rm -f "$T/sddm/zz-holo-autologin.conf"
    : > "$T/sddm/zz-steamos-autologin.conf"
}

unit() { tr ' ' '\n' <<< "$2" > "$STATE/unit.gamescope-session-plus@$1.service"; }
plasmashell() { tr ' ' '\n' <<< "$1" > "$STATE/plasmashell"; }
sessions() { tr ' ' '\n' <<< "$1" > "$STATE/sessions"; }

run() {
    rc=0
    ARMADA_SESSIONS_DIR="$sessions_dir" "$SC" "$@" 2> "$STATE/stderr" > "$STATE/stdout" || rc=$?
}

fail() {
    echo "FAIL $case_name: $*" >&2
    echo "--- calls" >&2
    cat "$STATE/calls" >&2
    echo "--- logger" >&2
    cat "$STATE/logger" >&2
    failures=$((failures + 1))
}

expect_rc() { [[ "$rc" == "$1" ]] || fail "exit $rc, expected $1"; }
expect_call() { grep -qF -- "$1" "$STATE/calls" || fail "missing call: $1"; }
expect_no_call() { if grep -qF -- "$1" "$STATE/calls"; then fail "unexpected call: $1"; fi; }
expect_log() { grep -qF -- "$1" "$STATE/logger" || fail "missing log: $1"; }
expect_session() {
    [[ -e "$T/sddm/zz-holo-autologin.conf" ]] || { fail "no autologin, expected $1"; return; }
    [[ "$(cat "$T/sddm/zz-holo-autologin.conf")" == "$(printf '[Autologin]\nSession=%s' "$1")" ]] \
        || fail "autologin is $(tr '\n' ' ' < "$T/sddm/zz-holo-autologin.conf"), expected $1"
    [[ -e "$T/sddm/zz-steamos-autologin.conf" ]] && fail "zz-steamos-autologin.conf kept"
    return 0
}
expect_no_session() {
    if [[ -e "$T/sddm/zz-holo-autologin.conf" ]]; then fail "autologin written"; fi
    [[ -e "$T/sddm/zz-steamos-autologin.conf" ]] || fail "zz-steamos-autologin.conf removed"
}
expect_calls() {
    local expected
    expected=$(printf '%s\n' "$@")
    [[ "$(sed -E 's/^sudo .* :: /sudo :: /' "$STATE/calls")" == "${expected%$'\n'}" ]] \
        || fail "call list differs, expected: $(tr '\n' '|' <<< "$expected")"
}
expect_at() {
    [[ "$(cat "$STATE/at_$1" 2>/dev/null)" == "Session=$2" ]] \
        || fail "autologin at $1 was $(cat "$STATE/at_$1" 2>/dev/null), expected $2"
}
expect_sleeps() {
    local n
    n=$(grep -c '^sleep ' "$STATE/calls" || true)
    [[ "$n" -ge "$1" && "$n" -le "$2" ]] || fail "$n sleeps, expected $1..$2"
}
expect_tracker() { [[ -e "$T/tracker" ]] || fail "tracker removed"; }
expect_no_tracker() { if [[ -e "$T/tracker" ]]; then fail "tracker kept"; fi; }

sddm_restart="systemctl --no-block restart sddm.service"
steam_shutdown="/steam -shutdown"
user_stop="systemctl --user stop"
apply="controller-type apply"
lock_call="flock -w 20 9"
reset_failed="systemctl reset-failed sddm.service"

for dir in "$T/missing.d" "$T/empty.d"; do
    label=$(basename "$dir")

    setup "switch-gamemode from Plasma, $label" "$dir"
    echo 1 > "$STATE/plasma"
    run switch-gamemode
    expect_rc 0
    expect_session gamescope-session-steam.desktop
    expect_calls "$lock_call" "$reset_failed" "sudo :: busctl --user status org.kde.Shutdown" \
        "sudo :: $T/bin/qdbus-qt6 org.kde.Shutdown /Shutdown org.kde.Shutdown.logout"
    expect_at logout gamescope-session-steam.desktop

    setup "switch-gamemode without Plasma, $label" "$dir"
    run switch-gamemode
    expect_rc 0
    expect_session gamescope-session-steam.desktop
    expect_calls "$lock_call" "$reset_failed" "sudo :: busctl --user status org.kde.Shutdown" "$sddm_restart"

    setup "switch-desktop, $label" "$dir"
    echo 1 > "$STATE/plasma"
    unit steam active
    run switch-desktop
    expect_rc 0
    expect_session armada-plasma.desktop
    expect_calls "$lock_call" "$reset_failed" "$sddm_restart"

    setup "default-gamemode, $label" "$dir"
    run default-gamemode
    expect_rc 0
    expect_session gamescope-session-steam.desktop
    expect_calls "$lock_call" "$reset_failed"

    setup "default-desktop, $label" "$dir"
    run default-desktop
    expect_rc 0
    expect_session armada-plasma.desktop
    expect_calls "$lock_call" "$reset_failed"

    setup "list-sessions, $label" "$dir"
    run list-sessions
    expect_rc 0
    [[ ! -s "$STATE/stdout" ]] || fail "sessions listed: $(cat "$STATE/stdout")"
    expect_calls
done

setup "switch-gamemode with Steam active, stale autologin"
printf '[Autologin]\nSession=armada-plasma.desktop\n' > "$T/sddm/zz-holo-autologin.conf"
unit steam active
run switch-gamemode
expect_rc 0
expect_session gamescope-session-steam.desktop
expect_calls "$lock_call" "$reset_failed" "sudo :: systemctl --user is-active --quiet -- gamescope-session-plus@steam.service"

setup "switch-x with its unit active"
unit x active
run switch-x
expect_rc 0
expect_session x.desktop
expect_calls "$lock_call" "$reset_failed" "sudo :: systemctl --user is-active --quiet -- gamescope-session-plus@x.service"

setup "switch-x from Steam"
unit steam "active inactive"
unit x "inactive active"
run switch-x
expect_rc 0
expect_session x.desktop
expect_call "timeout 15 sudo"
expect_call "$steam_shutdown"
expect_no_call "$sddm_restart"
expect_no_call "$apply"
expect_no_tracker
expect_at shutdown x.desktop
expect_call "$reset_failed"
grep -qxF "HOME=$T/home" "$STATE/shutdown_env" || fail "HOME not $T/home"
grep -qxF "XDG_RUNTIME_DIR=$T/run" "$STATE/shutdown_env" || fail "XDG_RUNTIME_DIR not $T/run"
grep -qxF "DBUS_SESSION_BUS_ADDRESS=unix:path=$T/run/bus" "$STATE/shutdown_env" || fail "DBUS_SESSION_BUS_ADDRESS wrong"
grep -qxF "LD_LIBRARY_PATH=$T/home/.local/share/Steam/steamrtarm64" "$STATE/shutdown_env" || fail "LD_LIBRARY_PATH wrong"
expect_log "-t session-control -- steam -shutdown HOME=$T/home XDG_RUNTIME_DIR=$T/run session=16"

setup "switch-x from Steam, seat session closing"
unit steam "active inactive"
unit x "inactive active"
sessions "active closing"
run switch-x
expect_rc 0
expect_call "$steam_shutdown"
expect_no_call "$sddm_restart"
expect_no_tracker

setup "switch-x from Steam, unit never stops"
unit steam active
unit x "inactive active"
run switch-x
expect_rc 0
expect_call "$steam_shutdown"
expect_call "$sddm_restart"
expect_sleeps 20 20
expect_tracker

setup "switch-x from Steam, seat session stays"
unit steam "active inactive"
unit x "inactive active"
sessions active
run switch-x
expect_rc 0
expect_call "$sddm_restart"
expect_sleeps 10 10
expect_tracker

setup "switch-x from Steam, unit back during seat wait"
unit steam "active inactive active"
unit x "inactive active"
sessions active
run switch-x
expect_rc 0
expect_call "$sddm_restart"
expect_sleeps 1 1
expect_tracker

setup "switch-x from Plasma"
echo 1 > "$STATE/plasma"
unit x "inactive active"
run switch-x
expect_rc 0
expect_session x.desktop
expect_call qdbus
expect_at logout x.desktop
expect_call "$reset_failed"
expect_no_call "$steam_shutdown"
expect_no_call "$sddm_restart"
expect_no_call "$apply"
expect_tracker

setup "switch-x from y"
unit y active
unit x "inactive active"
run switch-x
expect_rc 0
expect_session x.desktop
expect_call "$user_stop -- gamescope-session-plus@y.service"
expect_at stop x.desktop
expect_call "$reset_failed"
expect_no_call "$apply"
expect_no_call "$sddm_restart"
expect_no_call qdbus
expect_no_call "$steam_shutdown"

for verb in switch-gamemode switch-desktop; do
    setup "$verb from x"
    unit x active
    unit steam "inactive active"
    plasmashell 101
    run "$verb"
    expect_rc 0
    expect_call "$user_stop -- gamescope-session-plus@x.service"
    [[ "$verb" == switch-gamemode ]] && expect_at stop gamescope-session-steam.desktop
    [[ "$verb" == switch-desktop ]] && expect_at stop armada-plasma.desktop
    expect_call "$apply"
    expect_no_call "$sddm_restart"
    expect_no_call qdbus
done

setup "switch-gamemode, stop of x fails"
unit x active
unit steam "inactive active"
: > "$STATE/stopfail"
run switch-gamemode
expect_rc 0
expect_call "$user_stop -- gamescope-session-plus@x.service"
expect_call "$sddm_restart"
expect_call "$apply"
expect_log "stopping gamescope-session-plus@x.service failed"

setup "switch-desktop, apply fails"
echo 1 > "$STATE/ct_rc"
plasmashell "- 101"
run switch-desktop
expect_rc 0
expect_call "$apply"
expect_log "switch-desktop: controller-type apply failed"
expect_call "pgrep -u armada -x plasmashell"
expect_sleeps 1 1

setup "switch-desktop ignores nested and bottom shells"
plasmashell "102,103,104 102,103,104,105 103,101"
run switch-desktop
expect_rc 0
expect_sleeps 2 2

setup "switch-desktop with only nested and bottom shells"
plasmashell "102,103,104"
run switch-desktop
expect_rc 0
expect_sleeps 20 20
expect_log "switch-desktop: target not up after 20 s"

setup "switch-gamemode from x, apply fails"
echo 1 > "$STATE/ct_rc"
unit x active
unit steam "inactive inactive active"
run switch-gamemode
expect_rc 0
expect_log "controller-type apply failed"
expect_sleeps 1 1

setup "switch-gamemode, settle timeout"
echo 1 > "$STATE/plasma"
run switch-gamemode
expect_rc 0
expect_call qdbus
expect_call "timeout 20 $T/bin/$apply"
expect_sleeps 20 20
expect_log "switch-gamemode: target not up after 20 s"

setup "switch-gamemode with no session active"
unit steam "inactive inactive inactive active"
run switch-gamemode
expect_rc 0
expect_session gamescope-session-steam.desktop
expect_call "busctl --user status org.kde.Shutdown"
expect_no_call qdbus
expect_call "$sddm_restart"
expect_call "$apply"
expect_sleeps 2 2

setup "switch-x with no session active"
unit x "inactive inactive active"
run switch-x
expect_rc 0
expect_session x.desktop
expect_no_call "$steam_shutdown"
expect_call "$sddm_restart"
expect_sleeps 1 1

setup "lock held"
mkdir -p "$(dirname "$LOCK")"
exec 8> "$LOCK"
"$REAL_FLOCK" -n 8
run switch-x
exec 8>&-
expect_rc 75
expect_call "$lock_call"
expect_no_session
expect_no_call "systemctl reset-failed"
grep -qxF "switch in progress" "$STATE/stderr" || fail "stderr: $(cat "$STATE/stderr")"
expect_log "switch-x: switch in progress"

setup "lock kept until the target is up"
unit y active
unit x inactive
: > "$STATE/hold_sleep"
ARMADA_SESSIONS_DIR="$sessions_dir" "$SC" switch-x > /dev/null 2>&1 &
pid=$!
for _ in $(seq 250); do [[ -e "$STATE/in_sleep" ]] && break; "$REAL_SLEEP" 0.02; done
[[ -e "$STATE/in_sleep" ]] || fail "settle wait not reached"
"$REAL_FLOCK" -n "$LOCK" true && fail "lock free during the settle wait"
unit x active
rm -f "$STATE/hold_sleep"
rc=0
wait "$pid" || rc=$?
expect_rc 0
"$REAL_FLOCK" -n "$LOCK" true || fail "lock still held after exit"
expect_sleeps 1 1

setup "default-x"
unit steam active
run default-x
expect_rc 0
expect_session x.desktop
expect_call "$lock_call"
expect_no_call sudo
expect_no_call "$sddm_restart"
expect_no_call "$apply"

setup "list-sessions"
run list-sessions
expect_rc 0
[[ "$(cat "$STATE/stdout")" == $'x\ny' ]] || fail "listed $(tr '\n' ' ' < "$STATE/stdout")"
expect_no_call flock

setup "list-sessions with rejected drop-ins" "$T/bad.d"
run list-sessions
expect_rc 0
[[ "$(cat "$STATE/stdout")" == good ]] || fail "listed $(tr '\n' ' ' < "$STATE/stdout")"
expect_log "session nounit: invalid UNIT, ignored"
expect_log "session nodesk: invalid DESKTOP, ignored"
expect_log "session absent: absent.desktop not in"
expect_log "invalid name, ignored"

for verb in switch-nounit switch-nodesk switch-absent switch-dots switch-notsession switch-semi \
    switch-steamunit switch-steamdesk switch-plasmadesk switch-Upper switch--lead "switch-a b" "switch-a;b" switch-.. switch-../x switch-../bad.d/good \
    default-nounit default-Upper default-; do
    setup "rejected $verb" "$T/bad.d"
    run "$verb"
    expect_rc 1
    expect_no_session
    expect_no_call flock
done

setup "switch-good from rejected dir"
sessions_dir="$T/bad.d"
unit good active
run switch-good
expect_rc 0
expect_session good.desktop
expect_no_call "$user_stop"
expect_no_call "$sddm_restart"

setup "drop-ins sharing a unit" "$T/dup.d"
run list-sessions
expect_rc 0
[[ "$(cat "$STATE/stdout")" == a ]] || fail "listed $(tr '\n' ' ' < "$STATE/stdout")"
expect_log "session b: gamescope-session-plus@x.service already used, ignored"
run switch-b
expect_rc 1
expect_no_session

setup "unknown verb"
run bogus
expect_rc 1
expect_no_session

if (( failures )); then
    echo "session-control-test: $failures failure(s)" >&2
    exit 1
fi
echo "session-control-test: ok"
