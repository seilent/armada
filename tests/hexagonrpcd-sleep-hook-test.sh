#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/system_files/usr/lib/systemd/system-sleep/46-armada-hexagonrpcd"
[[ -x "$HOOK" ]]
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

mkdir "$tmp/bin"
calls="$tmp/calls"
run_dir="$tmp/run"
marker="$run_dir/hexagonrpcd-suspended"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf '\''%s\n'\'' "$*" >>"$CALLS"' \
    'if [[ "$1" == is-active ]]; then' \
    '    printf '\''%s\n'\'' "$UNIT_STATE"' \
    '    [[ "$UNIT_STATE" == active ]]' \
    '    exit' \
    'fi' \
    'exit "${SYSTEMCTL_STATUS:-0}"' \
    >"$tmp/bin/systemctl"
chmod +x "$tmp/bin/systemctl"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf '\''busctl %s\n'\'' "${@: -1}" >>"$CALLS"' \
    'exit "${BUSCTL_STATUS:-0}"' \
    >"$tmp/bin/busctl"
chmod +x "$tmp/bin/busctl"

run_hook() {
    rm -f -- "$calls"
    env PATH="$tmp/bin:$PATH" CALLS="$calls" ARMADA_RUN_DIR="$run_dir" \
        UNIT_STATE="${UNIT_STATE:-active}" bash "$HOOK" "$@" 2>"$tmp/hook.log"
}

for verb in suspend suspend-then-hibernate hybrid-sleep; do
    rm -rf -- "$run_dir"
    UNIT_STATE=active run_hook pre "$verb"
    [[ "$(<"$calls")" == $'is-active armada-hexagonrpcd.service\nbusctl HookSleep\nstop armada-hexagonrpcd.service' ]]
    [[ -e "$marker" ]]
    run_hook post "$verb"
    [[ "$(<"$calls")" == $'--no-block start armada-hexagonrpcd.service\nbusctl HookWake' ]]
    [[ ! -e "$marker" ]]
done

rm -rf -- "$run_dir"
UNIT_STATE=activating run_hook pre suspend
grep -qx 'stop armada-hexagonrpcd.service' "$calls"
[[ -e "$marker" ]]

rm -rf -- "$run_dir"
UNIT_STATE=inactive run_hook pre suspend
[[ "$(<"$calls")" == 'is-active armada-hexagonrpcd.service' ]]
[[ ! -e "$marker" ]]
run_hook post suspend
[[ ! -e "$calls" ]]

run_hook pre hibernate
[[ ! -e "$calls" ]]
mkdir -p "$run_dir"
: >"$marker"
run_hook post hibernate
[[ ! -e "$calls" ]]
[[ -e "$marker" ]]

rm -rf -- "$run_dir"
SYSTEMCTL_STATUS=1 UNIT_STATE=active run_hook pre suspend
grep -q 'stopping armada-hexagonrpcd.service failed' "$tmp/hook.log"
SYSTEMCTL_STATUS=1 run_hook post suspend
grep -q 'starting armada-hexagonrpcd.service failed' "$tmp/hook.log"
[[ ! -e "$marker" ]]

rm -rf -- "$run_dir"
BUSCTL_STATUS=1 UNIT_STATE=active run_hook pre suspend
grep -q 'InputPlumber HookSleep failed' "$tmp/hook.log"
grep -qx 'stop armada-hexagonrpcd.service' "$calls"
BUSCTL_STATUS=1 run_hook post suspend
grep -q 'InputPlumber HookWake failed' "$tmp/hook.log"
grep -qx -- '--no-block start armada-hexagonrpcd.service' "$calls"

bash -n "$HOOK"
printf 'hexagonrpcd sleep hook test passed\n'
