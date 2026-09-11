#!/bin/bash
# run-cli-test.sh - bin/hyprcrt's lite path in a sandbox, asserting what `set` accepts, refuses and stores.
#   tests/run-cli-test.sh
# Nothing reaches the live session: the command runs under `env -i` with a throwaway HOME and runtime dir,
# so there is no instance signature, no Wayland display and no session bus; hyprctl finds no Hyprland and
# notifications have nowhere to go. Where /dev/dri exists the stored state is also rendered through
# tests/shadercheck, which must not come out black. MIT (c) 2026 Dan Expo.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
sb=$(mktemp -d "${TMPDIR:-/tmp}/hyprcrt-cli.XXXXXX")
trap 'rm -rf "$sb"' EXIT
mkdir -p "$sb/home" "$sb/run"
conf=$sb/home/.config/hyprcrt/state.conf
fails=0

run() { env -i PATH="$PATH" HOME="$sb/home" XDG_RUNTIME_DIR="$sb/run" "$root/bin/hyprcrt" "$@"; }
ok()  { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fails=$((fails + 1)); }
refused() { # refused <expected message> <args...>: exits non-zero, says why, leaves state.conf as it was
    local msg=$1; shift
    local before after out
    before=$(cat "$conf")
    if out=$(run "$@" 2>&1); then bad "hyprcrt $* was accepted"; return; fi
    after=$(cat "$conf")
    [[ $out == *"$msg"* ]] || { bad "hyprcrt $* said '$out', expected '$msg'"; return; }
    [ "$before" = "$after" ] || { bad "hyprcrt $* changed state.conf"; return; }
    ok "hyprcrt $* refused: $msg"
}
stored() { # stored <key=value> <args...>: exits zero and state.conf holds the value
    local want=$1; shift
    run "$@" >/dev/null 2>&1 || { bad "hyprcrt $* failed"; return; }
    grep -qx "$want" "$conf" && ok "hyprcrt $* stored $want" || bad "hyprcrt $* did not store $want"
}

echo "cli: bin/hyprcrt set, lite mode, sandboxed HOME"
[ "$(run mode)" = lite ] || { echo "cli: the sandbox sees a compositor; refusing to go on"; exit 1; }
# the state file had its lite-only name before both modes shared it: an old one is moved, not lost
mkdir -p "$(dirname "$conf")"
printf 'enabled=1\npreset=television\n' > "${conf%/*}/lite.conf"
run status >/dev/null
[ -f "$conf" ] && [ ! -f "${conf%/*}/lite.conf" ] && grep -qx preset=television "$conf" && ok "an old lite.conf becomes state.conf" || bad "lite.conf was not moved to state.conf"
run preset monitor >/dev/null
[ -f "$conf" ] || { echo "cli: preset did not write $conf"; exit 1; }

refused "gain must be a number 0.25-4" set gain 0
refused "gain must be a number 0.25-4" set gain abc
refused "gain must be a number 0.25-4" set gain 4.5
refused "gain must be a number 0.25-4" set gain 1.2.3
refused "pitch must be an integer 0-8" set pitch 9
refused "pitch must be an integer 0-8" set pitch two
refused "mask_pitch must be an integer 1-3" set mask_pitch 0
refused "pitch_fullscreen must be an integer 1-8" set pitch_fullscreen 0
refused "textsafe must be 0 or 1" set textsafe maybe
stored gain=1.5 set gain 1.5
stored gain=.5 set gain .5
stored pitch=0 set pitch 0
stored mask_pitch=3 set mask_pitch 3
stored textsafe=0 set textsafe off
stored textsafe=1 set textsafe yes
# keys only the plugin uses, written there by full mode, survive a lite-mode write
printf 'pitch_fullscreen=2\nmedia=^(mpv|my player)$\n' >> "$conf"
run set lines 2 >/dev/null
grep -qx 'pitch_fullscreen=2' "$conf" && grep -Fqx 'media=^(mpv|my player)$' "$conf" && ok "full-mode keys survive a lite write" || bad "a lite write dropped pitch_fullscreen/media: $(tr '\n' ' ' < "$conf")"

# gen takes a preset by name, as its help says, and refuses one it does not know
run gen television | grep -qx '#define CURVE 1' && ok "hyprcrt gen television is the television shader" || bad "hyprcrt gen television did not generate the television preset"
if run gen nosuch >/dev/null 2>&1; then bad "hyprcrt gen nosuch was accepted"; else ok "hyprcrt gen nosuch refused"; fi

# a state file written before the check (or by hand) with gain=0 must still not render black
sed -i 's/^gain=.*/gain=0/' "$conf"
run reload >/dev/null 2>&1 || bad "hyprcrt reload failed on a gain=0 state.conf"
frag=$sb/home/.config/hyprcrt/current.frag
grep -q '^#define GAIN 0.2500$' "$frag" && ok "gain=0 in state.conf generates GAIN 0.2500" || bad "gain=0 in state.conf reached the shader: $(grep 'define GAIN' "$frag")"

if [ -e /dev/dri/renderD128 ]; then
    make -s -C "$root" shadercheck >/dev/null
    python3 -c "import sys; sys.stdout.buffer.write(b'P6 480 270 255\n' + bytes([128]) * (480 * 270 * 3))" > "$sb/grey.ppm"
    "$root/tests/shadercheck" "$frag" "$sb/grey.ppm" "$sb/out.ppm" >/dev/null
    mean=$(python3 -c "
import sys; d = open(sys.argv[1], 'rb').read(); parts = d.split(maxsplit=4); px = parts[4]
print(f'{sum(px) / len(px) / 255:.3f}')" "$sb/out.ppm")
    awk -v m="$mean" 'BEGIN { exit !(m > 0.05) }' && ok "that shader renders mid-grey to mean $mean, not black" || bad "that shader renders black (mean $mean)"
else
    echo "  skip render check (no /dev/dri/renderD128)"
fi

[ "$fails" -eq 0 ] || { echo "cli: $fails failure(s)"; exit 1; }
echo "cli: set refuses bad values in both modes' ranges, stores good ones, and gain=0 cannot go black"
