#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/system_files/usr/libexec/armada/dp-audio-sleep"
[[ -x "$SCRIPT" ]]
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/py/gi"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf '\''%s\n'\'' "hook $*" >>"$CALLS"' \
    >"$tmp/hook"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf '\''%s\n'\'' "systemd-run $*" >>"$CALLS"' \
    >"$tmp/bin/systemd-run"
chmod +x "$tmp/hook" "$tmp/bin/systemd-run"

cat >"$tmp/py/gi/__init__.py" <<'EOF'
def require_version(*_args):
    pass
EOF
cat >"$tmp/py/gi/repository.py" <<'EOF'
class _Any:
    def __getattr__(self, _name):
        return _Any()

    def __call__(self, *_args, **_kwargs):
        return _Any()


class _GLibError(Exception):
    @property
    def message(self):
        return str(self)


Gio = _Any()
GLib = _Any()
GLib.Error = _GLibError
EOF

cat >"$tmp/check.py" <<'EOF'
import os
import runpy
import sys

mod = runpy.run_path(sys.argv[1], run_name="dp_audio_sleep")
calls = os.environ["CALLS"]
hook = os.environ["ARMADA_DP_AUDIO_HOOK"]


class Params:
    def __init__(self, value):
        self.value = value

    def unpack(self):
        return (self.value,)


class Sleeper(mod["DpAudioSleep"]):
    def __init__(self):
        super().__init__(None)
        self.events = []

    def inhibit(self):
        self.events.append("inhibit")

    def release(self):
        self.events.append("release")


def read():
    with open(calls) as f:
        return f.read().splitlines()


sleeper = Sleeper()
sleeper.prepare_for_sleep(None, None, None, None, None, Params(True))
assert read() == ["hook sleep"], read()
assert sleeper.events == ["release"], sleeper.events

open(calls, "w").close()
sleeper.prepare_for_sleep(None, None, None, None, None, Params(False))
assert read() == [f"systemd-run --no-block --collect {hook} resume"], read()
assert sleeper.events == ["release", "inhibit"], sleeper.events


class Loop:
    quit_called = False

    def quit(self):
        self.quit_called = True


class FailingSleeper(mod["DpAudioSleep"]):
    def inhibit(self):
        raise mod["GLib"].Error("no logind")


loop = Loop()
failing = FailingSleeper(None, loop)
failing.prepare_for_sleep(None, None, None, None, None, Params(False))
assert failing.failed and loop.quit_called
EOF

: >"$tmp/calls"
env PATH="$tmp/bin:$PATH" PYTHONPATH="$tmp/py" CALLS="$tmp/calls" ARMADA_DP_AUDIO_HOOK="$tmp/hook" \
    python3 "$tmp/check.py" "$SCRIPT" 2>"$tmp/err"
grep -qxF "dp-audio-sleep: inhibit failed: no logind" "$tmp/err"

echo "dp-audio-sleep test passed"
