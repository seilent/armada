#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/system_files/usr/libexec/armada/dp-audio"
[[ -x "$HOOK" ]]
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

bin="$tmp/bin"
mkdir -p "$bin"
for cmd in amixer logger systemctl; do
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        "printf '%s\n' \"$cmd \$*\" >>\"\$CALLS\"" \
        >"$bin/$cmd"
done
cat >"$bin/advance" <<'EOF2'
#!/usr/bin/env bash
[[ -z ${FROZEN:-} ]] || exit 0
read -r up _ <"$UPTIME"
printf '%d.00 0.00\n' $(( ${up%.*} + $1 )) >"$UPTIME"
EOF2
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf '\''%s\n'\'' "sleep $*" >>"$CALLS"' \
    '[[ $1 == *.* ]] || advance "$1"' \
    '[[ -z ${UNPLUG_ON_RETRY:-} || $1 != 7 ]] || echo disconnected >"$UNPLUG_ON_RETRY"' \
    >"$bin/sleep"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf '\''%s\n'\'' "aplay $*" >>"$CALLS"' \
    'n=$(cat "$APLAY_FAILS" 2>/dev/null || echo 0)' \
    'if (( n > 0 )); then echo $((n - 1)) >"$APLAY_FAILS"; advance 5; echo "aplay: busy" >&2; exit 1; fi' \
    '[[ -z ${APLAY_UNPLUG:-} ]] || echo disconnected >"$APLAY_UNPLUG"' \
    '[[ -z ${APLAY_SLEEP:-} ]] || touch "$APLAY_SLEEP"' \
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
    echo "100.00 0.00" >"$tmp/uptime"
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
        UPTIME="$tmp/uptime" ARMADA_DP_AUDIO_UPTIME="$tmp/uptime" \
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
called "logger -t armada-dp-audio DP audio try 1 failed (rc 1): aplay: busy"
called "logger -t armada-dp-audio DP audio ready (try 3)"

reset
connect
echo 99 >"$tmp/fails"
run_hook
[[ ! -e "$flag" ]]
[[ "$(grep -c '^aplay' "$calls")" == 17 ]]
called "logger -t armada-dp-audio DP audio not ready 200 s after the run started, giving up"
[[ "$(tail -n 1 "$calls")" == "amixer -q -D hw:Card cset name=DP Mixer MM4 0" ]]

reset
connect
echo 99 >"$tmp/fails"
FROZEN=1 run_hook
[[ ! -e "$flag" ]]
[[ "$(grep -c '^aplay' "$calls")" == 18 ]]
[[ "$(grep -c '^sleep 7' "$calls")" == 17 ]]
called "logger -t armada-dp-audio DP audio never became ready, giving up"
[[ "$(tail -n 2 "$calls" | head -n 1)" == "amixer -q -D hw:Card cset name=DP Mixer MM4 0" ]]

reset
connect
APLAY_UNPLUG="$drm/card0-DP-1/status" run_hook
[[ ! -e "$flag" ]]
called "logger -t armada-dp-audio DP audio ready (try 1)"
called "logger -t armada-dp-audio DP changed during the run, rechecking"
called "logger -t armada-dp-audio DP audio removed"
[[ "$(tail -n 1 "$calls")" == "amixer -q -D hw:Card cset name=DP Mixer MM4 0" ]]

reset
connect
echo 99 >"$tmp/fails"
UNPLUG_ON_RETRY="$drm/card0-DP-1/status" run_hook
[[ ! -e "$flag" ]]
[[ "$(grep -c '^aplay' "$calls")" == 1 ]]
[[ "$(tail -n 1 "$calls")" == "amixer -q -D hw:Card cset name=DP Mixer MM4 0" ]]

reset
connect
APLAY_SLEEP="$sleeping" run_hook
[[ -e "$sleeping" && ! -e "$flag" ]]
[[ "$(tail -n 1 "$calls")" == "amixer -q -D hw:Card cset name=DP Mixer MM4 0" ]]

reset
connect
exec 8>"$run/armada-dp-audio.lock"
flock 8
ARMADA_DP_AUDIO_LOCK_WAIT=0 run_hook
exec 8>&-
[[ ! -e "$flag" ]]
[[ "$(grep -c '^aplay' "$calls")" == 0 ]]
called "logger -t armada-dp-audio lock held for 0 s, the holder covers this event"

reset
connect
run_hook
[[ -e "$flag" ]]
echo "state: RUNNING" >"$asound/Card/pcm3p/sub0/status"
: >"$calls"
run_hook sleep
[[ -e "$sleeping" && ! -e "$flag" ]]
called "systemctl stop armada-dp-audio-hotplug-*.service"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$bin/systemctl"
rm -f "$sleeping"
: >"$calls"
run_hook sleep
called "logger -t armada-dp-audio stopping armada-dp-audio-hotplug-*.service failed"
[[ -e "$sleeping" ]]
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
