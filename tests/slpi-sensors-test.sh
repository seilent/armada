#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/system_files/usr/libexec/armada/slpi-sensors"
DEVICE_DIR="$ROOT/system_files/usr/lib/armada/devices"
DTS="$ROOT/packages/kernel/dts/sm8250-ayaneo-pocket-micro2.dts"
[[ -x "$SCRIPT" ]]
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    printf 'slpi-sensors test failed: %s\n' "$1" >&2
    exit 1
}

conf_dir=$(source "$DEVICE_DIR/defaults.conf"; source "$DEVICE_DIR/ayaneo-pocket-micro2.conf"; printf '%s' "$ARMADA_SLPI_FIRMWARE_DIR")
dts_name=$(awk '/^&slpi \{/ { inside = 1 } inside && /firmware-name/ { print; exit } inside && /^\};/ { inside = 0 }' "$DTS" |
    sed -n 's/.*firmware-name = "\(.*\)";.*/\1/p')
[[ -n "$dts_name" ]] || fail "no firmware-name in &slpi"
[[ "$conf_dir" == "$(dirname "$dts_name")" ]] || fail "ARMADA_SLPI_FIRMWARE_DIR $conf_dir does not match $dts_name"

bin=$tmp/bin
calls=$tmp/calls
mounts=$tmp/mounts
mkdir "$bin"
stub() {
    printf '%s\n' '#!/usr/bin/env bash' "$2" >"$bin/$1"
    chmod +x "$bin/$1"
}
stub udevadm 'printf '\''udevadm %s\n'\'' "$*" >>"$CALLS"; [[ -e "${!#}" ]]'
stub blkid 'cat "${!#}.type"'
stub blockdev 'printf '\''blockdev %s\n'\'' "$*" >>"$CALLS"'
stub mount 'printf '\''mount %s\n'\'' "$*" >>"$CALLS"; cp -a "$5/." "$6/"; printf '\''%s\n'\'' "$6" >>"$MOUNTS"'
stub mountpoint '[[ -e "$MOUNTS" ]] && grep -qxF -- "$2" "$MOUNTS"'
stub umount 'printf '\''umount %s\n'\'' "$*" >>"$CALLS"; grep -vxF -- "$1" "$MOUNTS" >"$MOUNTS.new" || true; mv "$MOUNTS.new" "$MOUNTS"; find "$1" -mindepth 1 -delete'
stub systemctl 'printf '\''systemctl %s\n'\'' "$*" >>"$CALLS"; [[ " $* " != *" is-active "* ]] || [[ "${UNIT_STATE:-inactive}" == active ]]'

dev=$tmp/dev
partlabel=$tmp/by-partlabel
mkdir -p "$dev" "$partlabel"
make_part() {
    mkdir -p "$dev/$1"
    printf '%s\n' "$2" >"$dev/$1.type"
    ln -s "$dev/$1" "$partlabel/$1"
}
for slot in a b; do
    make_part "modem_$slot" vfat
    mkdir -p "$dev/modem_$slot/image"
    printf 'mdt %s\n' "$slot" >"$dev/modem_$slot/image/slpi.mdt"
    printf 'b00 %s\n' "$slot" >"$dev/modem_$slot/image/slpi.b00"
    printf 'b01\n' >"$dev/modem_$slot/image/slpi.b01"
    printf 'jsn\n' >"$dev/modem_$slot/image/slpir.jsn"
    make_part "dsp_$slot" ext4
    mkdir -p "$dev/dsp_$slot/sdsp" "$dev/dsp_$slot/adsp" "$dev/dsp_$slot/lost+found"
    printf 'adsp\n' >"$dev/dsp_$slot/adsp/libadsp.so"
    printf 'shell %s\n' "$slot" >"$dev/dsp_$slot/sdsp/fastrpc_shell_2"
    printf 'wigig\n' >"$dev/dsp_$slot/sdsp/wigig_sensing.so"
    printf 'ear\n' >"$dev/dsp_$slot/sdsp/sns_bring_to_ear.so"
    ln -s /etc/hostname "$dev/dsp_$slot/sdsp/outside"
done
make_part persist ext4
mkdir -p "$dev/persist/sensors/registry/registry"
printf 'cal\n' >"$dev/persist/sensors/registry/registry/icm4x6xx_0_platform.config"

sysfs=$tmp/sys
mkdir -p "$sysfs/devices/soc0" "$sysfs/module/firmware_class/parameters" \
    "$sysfs/class/remoteproc/remoteproc0" "$sysfs/class/remoteproc/remoteproc1"
printf 'Snapdragon\n' >"$sysfs/devices/soc0/family"
printf 'SM8250\n' >"$sysfs/devices/soc0/machine"
printf '2.1\n' >"$sysfs/devices/soc0/revision"
printf '356\n' >"$sysfs/devices/soc0/soc_id"
printf '1234\n' >"$sysfs/devices/soc0/serial_number"
printf 'adsp\n' >"$sysfs/class/remoteproc/remoteproc0/name"
printf 'running\n' >"$sysfs/class/remoteproc/remoteproc0/state"
printf 'slpi\n' >"$sysfs/class/remoteproc/remoteproc1/name"
debugfs=$tmp/debugfs
mkdir "$debugfs"
printf '11\n' >"$debugfs/hardware_platform"
printf '0\n' >"$debugfs/hardware_platform_subtype"
printf '65536\n' >"$debugfs/platform_version"
printf 'root=UUID=x quiet\n' >"$tmp/cmdline"

sensors=$tmp/var/sensors
firmware=$tmp/var/firmware
fwdir=$firmware/$conf_dir
mkdir -p "$tmp/run"

run_script() {
    rm -f -- "$calls" "$mounts"
    env PATH="$bin:$PATH" CALLS="$calls" MOUNTS="$mounts" \
        ARMADA_MODEL="${MODEL:-AYANEO Pocket MICRO 2}" \
        ARMADA_DEVICE_DIR="$DEVICE_DIR" \
        ARMADA_DEVICE_ENV="$ROOT/system_files/usr/libexec/armada/device-env" \
        ARMADA_SENSORS_ROOT="$sensors" ARMADA_FIRMWARE_PATH="$firmware" \
        ARMADA_SYSFS_ROOT="$sysfs" ARMADA_SOCINFO_DEBUGFS="$debugfs" \
        ARMADA_PARTLABEL_DIR="$partlabel" ARMADA_CMDLINE="$tmp/cmdline" \
        ARMADA_WORK_PARENT="$tmp/run" ARMADA_MEM_SLEEP_PATH="$tmp/none" \
        ARMADA_SLEEP_CONFIG="$tmp/none" \
        bash "$SCRIPT" >"$tmp/out" 2>&1
}

assert_clean() {
    compgen -G "$tmp/run/armada-slpi.*" >/dev/null && fail "work dir left behind"
    compgen -G "$sensors.*" >/dev/null && fail "root stage dir left behind"
    compgen -G "$fwdir.*" >/dev/null && fail "firmware stage dir left behind"
    [[ ! -s "$mounts" ]] || fail "partition left mounted"
}

printf 'offline\n' >"$sysfs/class/remoteproc/remoteproc1/state"
run_script || fail "first run: $(<"$tmp/out")"
assert_clean
grep -q 'using slot _a' "$tmp/out" || fail "slot _a not logged"
[[ "$(<"$fwdir/slpi.mdt")" == 'mdt a' ]] || fail "slpi.mdt not copied"
[[ -e "$fwdir/slpi.b00" && -e "$fwdir/slpi.b01" ]] || fail "slpi.b?? not copied"
[[ ! -e "$fwdir/slpir.jsn" ]] || fail "slpir.jsn copied"
[[ "$(<"$sensors/dsp/sdsp/fastrpc_shell_2")" == 'shell a' ]] || fail "sdsp not copied"
[[ ! -e "$sensors/dsp/sdsp/wigig_sensing.so" ]] || fail "wigig_sensing.so copied"
[[ ! -e "$sensors/dsp/sdsp/sns_bring_to_ear.so" ]] || fail "sns_bring_to_ear.so copied"
[[ ! -e "$sensors/dsp/adsp" && ! -e "$sensors/dsp/lost+found" ]] || fail "dsp copied beyond sdsp"
[[ -L "$sensors/dsp/sdsp/outside" && "$(readlink "$sensors/dsp/sdsp/outside")" == /etc/hostname ]] ||
    fail "partition symlink dereferenced"
[[ -e "$sensors/sensors/registry/icm4x6xx_0_platform.config" ]] || fail "registry not copied"
[[ "$(head -n 1 "$sensors/sensors/sns_reg.conf")" == version=1 ]] || fail "sns_reg.conf missing"
[[ "$(<"$sensors/socinfo/hw_platform")" == QRD ]] || fail "hw_platform"
[[ "$(<"$sensors/socinfo/platform_subtype")" == QRD ]] || fail "platform_subtype"
[[ "$(<"$sensors/socinfo/platform_subtype_id")" == 0 ]] || fail "platform_subtype_id"
[[ "$(<"$sensors/socinfo/platform_version")" == 65536 ]] || fail "platform_version"
[[ "$(<"$sensors/socinfo/soc_id")" == 356 ]] || fail "soc_id"
[[ ! -e "$sensors/sensors/config" ]] || fail "sensors/config created"
[[ -s "$sensors/.armada-source" && -s "$fwdir/.armada-source" ]] || fail "stamp missing"
[[ "$(<"$sysfs/module/firmware_class/parameters/path")" == "$firmware" ]] || fail "firmware path"
[[ "$(<"$sysfs/class/remoteproc/remoteproc1/state")" == start ]] || fail "slpi not started"
[[ "$(<"$sysfs/class/remoteproc/remoteproc0/state")" == running ]] || fail "adsp touched"
for part in modem_a dsp_a persist; do
    grep -qxF "blockdev --setro $dev/$part" "$calls" || fail "setro $part"
    grep -qxF "udevadm wait --timeout=30 $partlabel/$part" "$calls" || fail "udevadm wait $part"
done
grep -qxF "mount -t vfat -o ro $dev/modem_a $(sed -n 's/^mount .* \(.*modem_a\)$/\1/p' "$calls")" "$calls" ||
    fail "modem mount options"
grep -q "^mount -t ext4 -o ro,noload $dev/dsp_a " "$calls" || fail "dsp mount options"
grep -q "^mount -t ext4 -o ro,noload $dev/persist " "$calls" || fail "persist mount options"
[[ "$(grep -c '^umount ' "$calls")" == 3 ]] || fail "umount count"
grep -q "systemctl stop" "$calls" && fail "inactive unit stopped"

: >"$sysfs/module/firmware_class/parameters/path"
run_script || fail "second run: $(<"$tmp/out")"
assert_clean
[[ "$(grep -c 'up to date' "$tmp/out")" == 2 ]] || fail "second run not up to date"
grep -q 'remoteproc1 is start' "$tmp/out" || fail "running slpi restarted"
[[ "$(<"$sysfs/module/firmware_class/parameters/path")" == "$firmware" ]] || fail "firmware path not rewritten"
grep -q "systemctl" "$calls" && fail "systemctl called without a change"

printf 'cal2\n' >"$dev/persist/sensors/registry/registry/icm4x6xx_0_platform.config"
: >"$sensors/marker"
UNIT_STATE=active run_script || fail "changed run: $(<"$tmp/out")"
assert_clean
grep -q "installed $sensors" "$tmp/out" || fail "changed registry not installed"
grep -q "$fwdir up to date" "$tmp/out" || fail "firmware recopied"
[[ "$(<"$sensors/sensors/registry/icm4x6xx_0_platform.config")" == cal2 ]] || fail "registry not updated"
[[ ! -e "$sensors/marker" ]] || fail "old root not swapped"
[[ "$(grep '^systemctl' "$calls")" == $'systemctl -q is-active armada-hexagonrpcd.service\nsystemctl stop armada-hexagonrpcd.service\nsystemctl --no-block start armada-hexagonrpcd.service' ]] ||
    fail "hexagonrpcd not bounced around the swap"

printf 'root=UUID=x androidboot.slot_suffix=_b quiet\n' >"$tmp/cmdline"
run_script || fail "slot b run: $(<"$tmp/out")"
assert_clean
grep -q 'using slot _b' "$tmp/out" || fail "slot _b not logged"
[[ "$(<"$fwdir/slpi.mdt")" == 'mdt b' ]] || fail "slot b firmware"
[[ "$(<"$sensors/dsp/sdsp/fastrpc_shell_2")" == 'shell b' ]] || fail "slot b dsp"
grep -qxF "blockdev --setro $dev/modem_b" "$calls" || fail "setro modem_b"
printf 'root=UUID=x quiet\n' >"$tmp/cmdline"

mv "$dev/modem_a/image/slpi.mdt" "$tmp/slpi.mdt"
if run_script; then
    fail "missing slpi.mdt succeeded"
fi
assert_clean
grep -q 'slpi.mdt not found on modem_a' "$tmp/out" || fail "missing slpi.mdt not reported"
mv "$tmp/slpi.mdt" "$dev/modem_a/image/slpi.mdt"

rm "$partlabel/persist"
if run_script; then
    fail "missing persist succeeded"
fi
assert_clean
grep -q 'partition persist not found' "$tmp/out" || fail "missing persist not reported"
[[ "$(grep -c '^umount ' "$calls")" == 2 ]] || fail "mounted partitions not unmounted on failure"
ln -s "$dev/persist" "$partlabel/persist"

printf 'ext4\n' >"$dev/modem_a.type"
if run_script; then
    fail "wrong fs type succeeded"
fi
assert_clean
grep -q 'partition modem_a is not vfat' "$tmp/out" || fail "wrong fs type not reported"
grep -q '^mount ' "$calls" && fail "wrong fs type mounted"
printf 'vfat\n' >"$dev/modem_a.type"

rm -rf -- "$sensors" "$firmware"
MODEL=none run_script || fail "non PM2 run failed"
[[ ! -e "$calls" && ! -e "$sensors" && ! -e "$firmware" ]] || fail "non PM2 touched something"
compgen -G "$tmp/run/armada-slpi.*" >/dev/null && fail "non PM2 created a work dir"

bash -n "$SCRIPT"
printf 'slpi-sensors test passed\n'
