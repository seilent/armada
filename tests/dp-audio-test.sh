#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/system_files/usr/libexec/armada/dp-audio"
[[ -x "$HOOK" ]]
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

bin="$tmp/bin"
mkdir -p "$bin"
for cmd in amixer logger sleep; do
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        "printf '%s\n' \"$cmd \$*\" >>\"\$CALLS\"" \
        >"$bin/$cmd"
done
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf '\''%s\n'\'' "aplay $*" >>"$CALLS"' \
    'n=$(cat "$APLAY_FAILS" 2>/dev/null || echo 0)' \
    'if (( n > 0 )); then echo $((n - 1)) >"$APLAY_FAILS"; exit 1; fi' \
    >"$bin/aplay"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "ARMADA_DP_AUDIO_CARD=%q\n" "$CARD"' \
    'printf "ARMADA_DP_AUDIO_DEVICE=%q\n" "${DEVICE-3}"' \
    'printf "ARMADA_DP_AUDIO_ROUTE=%q\n" "${ROUTE-DP Mixer MM4}"' \
    >"$tmp/device-env"
chmod +x "$bin"/* "$tmp/device-env"

run="$tmp/run"
asound="$tmp/asound"
drm="$tmp/drm"
calls="$tmp/calls"
flag="$run/armada-dp-audio.Card"
sleeping="$run/armada-dp-audio.sleeping"

reset() {
    rm -rf -- "$run" "$asound" "$drm" "$calls" "$tmp/fails"
    mkdir -p "$run" "$asound/Card/pcm3p/sub0" "$drm/card0-DP-1"
    echo closed >"$asound/Card/pcm3p/sub0/status"
    echo disconnected >"$drm/card0-DP-1/status"
    : >"$calls"
}

connect() {
    echo connected >"$drm/card0-DP-1/status"
}

run_hook() {
    env PATH="$bin:$PATH" CALLS="$calls" APLAY_FAILS="$tmp/fails" CARD="${CARD-Card}" \
        ARMADA_DEVICE_ENV="$tmp/device-env" ARMADA_DP_AUDIO_RUN_DIR="$run" \
        ARMADA_DP_AUDIO_ASOUND_DIR="$asound" ARMADA_DP_AUDIO_DRM_DIR="$drm" \
        bash "$HOOK" "$@"
}

called() {
    grep -qxF -- "$1" "$calls"
}

reset
connect
CARD= run_hook
[[ ! -s "$calls" && ! -e "$flag" ]]
if CARD= run_hook --supported; then exit 1; fi
run_hook --supported
[[ ! -s "$calls" ]]

reset
connect
rm -rf -- "$asound/Card"
run_hook
[[ ! -s "$calls" && ! -e "$flag" ]]

reset
connect
run_hook
[[ -e "$flag" ]]
called "amixer -q -D hw:Card cset name=DP Mixer MM4 1"
called "aplay -q -D hw:CARD=Card,DEV=3 -f S16_LE -r 48000 -c 2 -d 1 /dev/zero"
called "logger -t armada-dp-audio DP audio ready (try 1)"

: >"$calls"
run_hook
[[ -e "$flag" ]]
[[ "$(grep -c '^aplay' "$calls")" == 0 ]]

echo disconnected >"$drm/card0-DP-1/status"
: >"$calls"
run_hook
[[ ! -e "$flag" ]]
called "logger -t armada-dp-audio DP audio removed"
called "amixer -q -D hw:Card cset name=DP Mixer MM4 0"

reset
connect
echo 2 >"$tmp/fails"
run_hook
[[ -e "$flag" ]]
[[ "$(grep -c '^aplay' "$calls")" == 3 ]]
called "logger -t armada-dp-audio DP audio ready (try 3)"

reset
connect
echo 99 >"$tmp/fails"
run_hook
[[ ! -e "$flag" ]]
[[ "$(grep -c '^aplay' "$calls")" == 18 ]]
called "logger -t armada-dp-audio DP audio never became ready, giving up"
[[ "$(tail -n 2 "$calls" | head -n 1)" == "amixer -q -D hw:Card cset name=DP Mixer MM4 0" ]]

reset
connect
run_hook
[[ -e "$flag" ]]
echo "state: RUNNING" >"$asound/Card/pcm3p/sub0/status"
: >"$calls"
run_hook sleep
[[ -e "$sleeping" && ! -e "$flag" ]]
called "logger -t armada-dp-audio DP PCM still open, clearing the route anyway"
called "amixer -q -D hw:Card cset name=DP Mixer MM4 0"
echo closed >"$asound/Card/pcm3p/sub0/status"
: >"$calls"
run_hook
[[ ! -s "$calls" && ! -e "$flag" ]]
run_hook resume
[[ ! -e "$sleeping" && -e "$flag" ]]
called "logger -t armada-dp-audio DP audio ready (try 1)"

reset
connect
ROUTE= run_hook
[[ -e "$flag" ]]
[[ "$(grep -c '^amixer' "$calls")" == 0 ]]

echo "dp-audio test passed"
