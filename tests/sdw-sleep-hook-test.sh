#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/system_files/usr/lib/systemd/system-sleep/47-armada-sdw-sleep"
[[ -x "$HOOK" ]]
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

sdw="$tmp/sdw"
run_dir="$tmp/run"
state="$run_dir/sdw-sleep"
for dev in sdw:2:0:0217:010d:00:4 sdw:3:0:0217:010d:00:3 sdw:1:0:0217:2010:00:1; do
    mkdir -p "$sdw/$dev/power"
    echo on >"$sdw/$dev/power/control"
    echo suspended >"$sdw/$dev/power/runtime_status"
done
echo auto >"$sdw/sdw:1:0:0217:2010:00:1/power/control"

printf '%s\n' '#!/usr/bin/env bash' 'printf "ARMADA_SLEEP_SDW_SLAVES=%q\n" "$PATTERN"' >"$tmp/device-env"
chmod +x "$tmp/device-env"

run_hook() {
    env ARMADA_DEVICE_ENV="$tmp/device-env" ARMADA_SDW_ROOT="$sdw" ARMADA_RUN_DIR="$run_dir" \
        PATTERN="${PATTERN-sdw:*:0217:010d:*}" bash "$HOOK" "$@" 2>"$tmp/hook.log"
}
control() { printf "%s" "$(<"$sdw/$1/power/control")"; }

run_hook pre suspend
[[ "$(control sdw:2:0:0217:010d:00:4)" == auto ]]
[[ "$(control sdw:3:0:0217:010d:00:3)" == auto ]]
[[ "$(control sdw:1:0:0217:2010:00:1)" == auto ]]
[[ "$(wc -l <"$state")" == 2 ]]
run_hook post suspend
[[ "$(control sdw:2:0:0217:010d:00:4)" == on ]]
[[ "$(control sdw:3:0:0217:010d:00:3)" == on ]]
[[ "$(control sdw:1:0:0217:2010:00:1)" == auto ]]
[[ ! -e "$state" ]]

echo auto >"$sdw/sdw:3:0:0217:010d:00:3/power/control"
run_hook pre suspend
[[ "$(<"$state")" == "$sdw/sdw:2:0:0217:010d:00:4" ]]
run_hook post suspend
[[ "$(control sdw:2:0:0217:010d:00:4)" == on ]]
[[ "$(control sdw:3:0:0217:010d:00:3)" == auto ]]
echo on >"$sdw/sdw:3:0:0217:010d:00:3/power/control"

PATTERN= run_hook pre suspend
[[ ! -e "$state" ]]
[[ "$(control sdw:2:0:0217:010d:00:4)" == on ]]

run_hook pre hibernate
[[ ! -e "$state" ]]
[[ "$(control sdw:2:0:0217:010d:00:4)" == on ]]

run_hook post suspend
[[ "$(control sdw:2:0:0217:010d:00:4)" == on ]]

echo active >"$sdw/sdw:2:0:0217:010d:00:4/power/runtime_status"
start=$(date +%s%N)
run_hook pre suspend
elapsed=$(( ($(date +%s%N) - start) / 1000000 ))
(( elapsed < 3000 ))
run_hook post suspend

echo "sdw-sleep-hook-test: ok"
