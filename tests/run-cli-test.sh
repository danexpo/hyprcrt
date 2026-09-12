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
# every subcommand the dispatch accepts is in `hyprcrt --help` and the README's command block, and neither names
# one the dispatch does not know (C8: reload was accepted and listed nowhere). demo-restore is the demo timer's.
words() { sed -n 's/^\(#   \)\{0,1\}hyprcrt \([a-z][a-z-]*\( | [a-z][a-z-]*\)*\).*/\2/p' | tr -d ' ' | tr '|' '\n' | sort -u; }
dispatched=$(sed -n '/^cmd=\${1:-status}/,/^esac/s/^    \([a-z][a-z|-]*\)).*/\1/p' "$root/bin/hyprcrt" | tr '|' '\n' | grep -v '^-' | grep -vx 'help\|demo-restore' | sort -u)
helped=$(run --help | grep '^#   hyprcrt ' | words)
readme=$(awk '/^## Using it/{s=1} s&&/^```sh/{b=1; next} b&&/^```/{exit} b' "$root/README.md" | words)
[ -n "$dispatched" ] && [ "$dispatched" = "$helped" ] && ok "hyprcrt --help lists exactly the $(echo "$dispatched" | wc -l) subcommands the dispatch accepts" ||
    bad "hyprcrt --help and the dispatch disagree: $(diff <(echo "$dispatched") <(echo "$helped") | grep '^[<>]' | tr '\n' ' ')"
[ -n "$dispatched" ] && [ "$dispatched" = "$readme" ] && ok "the README's command block lists the same subcommands" ||
    bad "the README's command block and the dispatch disagree: $(diff <(echo "$dispatched") <(echo "$readme") | grep '^[<>]' | tr '\n' ' ')"
# the state file had its lite-only name before both modes shared it: an old one is moved, not lost
mkdir -p "$(dirname "$conf")"
printf 'enabled=1\npreset=television\n' > "${conf%/*}/lite.conf"
mkdir -p "$sb/home/.local/share/hyprcrt" && echo '-- a loader from before the rename' > "$sb/home/.local/share/hyprcrt/loader.lua"
run status >/dev/null
[ -f "$conf" ] && [ ! -f "${conf%/*}/lite.conf" ] && grep -qx preset=television "$conf" && ok "an old lite.conf becomes state.conf" || bad "lite.conf was not moved to state.conf"
cmp -s "$root/lua/loader.lua" "$sb/home/.local/share/hyprcrt/loader.lua" && ok "that move refreshes the installed loader" || bad "the installed loader still predates state.conf"
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
run status | python3 -c 'import json, sys; json.load(sys.stdin)' 2>/dev/null && ok "lite status is JSON with gain=.5 stored" ||
    bad "lite status is not JSON with gain=.5 stored: $(run status | grep -o '"gain":[^,]*')"
stored pitch=0 set pitch 0
stored mask_pitch=3 set mask_pitch 3
stored textsafe=0 set textsafe off
stored textsafe=1 set textsafe yes
# keys lite mode cannot use are refused, not stored without effect (DR-F7): it filters the whole screen in one pass
refused "scope needs the full-mode plugin" set scope all
refused "low_power needs the full-mode plugin" set low_power 1
refused "pitch_fullscreen needs the full-mode plugin" set pitch_fullscreen 2
refused "match needs the full-mode plugin" set match '^mpv$'
refused "media needs the full-mode plugin" set media '^mpv$'
refused "low_power needs the full-mode plugin" power on
refused "low_power needs the full-mode plugin" power auto
[ "$(run power)" = false ] && ok "hyprcrt power in lite mode answers false" || bad "hyprcrt power in lite mode said '$(run power 2>&1)'"
run status | python3 -c 'import json, sys; d = json.load(sys.stdin); sys.exit("scope" in d or "low_power" in d)' &&
    ok "lite status has no scope and no low_power" || bad "lite status still reports scope/low_power: $(run status)"
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

# install never writes the live HOME from inside an agent session (C11): CLAUDECODE set (as it is in
# every agent's own shell) refuses and writes nothing; env -i (as every `run` above already does, and
# as tests/run-install-test.sh does for real) clears it and installs normally.
ih=$sb/install-home
idata=$ih/.local/share/hyprcrt
mkdir -p "$ih/run"
if out=$(env -i PATH="$PATH" HOME="$ih" XDG_RUNTIME_DIR="$ih/run" CLAUDECODE=1 timeout 10 "$root/bin/hyprcrt" install --no-load --no-autostart 2>&1); then
    bad "hyprcrt install ran under CLAUDECODE=1: $out"
elif [[ $out != *"refusing to write the live"* ]]; then
    bad "hyprcrt install under CLAUDECODE=1 said '$out', expected the live-install refusal"
elif [ -e "$idata" ]; then
    bad "hyprcrt install under CLAUDECODE=1 wrote $idata anyway"
else
    ok "hyprcrt install refuses under CLAUDECODE=1: $out"
fi
if out=$(env -i PATH="$PATH" HOME="$ih" XDG_RUNTIME_DIR="$ih/run" CLAUDECODE=1 HYPRCRT_LIVE=1 timeout 30 "$root/bin/hyprcrt" install --no-load --no-autostart 2>&1); then
    [ -d "$idata/shaders" ] && ok "HYPRCRT_LIVE=1 overrides the CLAUDECODE refusal" || bad "HYPRCRT_LIVE=1 exited ok but wrote nothing: $out"
else
    bad "hyprcrt install under CLAUDECODE=1 HYPRCRT_LIVE=1 failed: $out"
fi
rm -rf "$ih"; mkdir -p "$ih/run"
timeout 30 env -i PATH="$PATH" HOME="$ih" XDG_RUNTIME_DIR="$ih/run" "$root/bin/hyprcrt" install --no-load --no-autostart >/dev/null 2>&1
[ -d "$idata/shaders" ] && [ -d "$idata/presets" ] && [ -f "$idata/loader.lua" ] && ok "hyprcrt install (env -i, no CLAUDECODE) installs into the sandbox" \
    || bad "hyprcrt install (env -i, no CLAUDECODE) did not populate $idata"
rm -rf "$ih"

# uninstall leaves no trace of what install, the loader and both modes wrote, and keeps what is the user's
h=$sb/home
mkdir -p "$h/.local/state/omarchy/toggles/hypr" "$h/.config/omarchy/extensions" "$h/.config/omarchy/hooks/post-update.d" "$h/.local/bin"
printf '{\n  "user.mine": {"label":"mine"}\n}\n' > "$h/.config/omarchy/extensions/omarchy-menu.jsonc"
run menu >/dev/null && run plugin enable >/dev/null && run plugin disable >/dev/null && run preset monitor >/dev/null
ln -s "$root/bin/hyprcrt" "$h/.local/bin/hyprcrt"
cp "$root/omarchy-plugin/hooks/hyprcrt-rebuild" "$h/.config/omarchy/hooks/post-update.d/"
: > "$h/.local/state/hyprcrt/demo.json"
before=$(find "$h" -iname '*hyprcrt*' | wc -l)
grep -q '"style.crt' "$h/.config/omarchy/extensions/omarchy-menu.jsonc" || bad "the uninstall setup has no menu entries"
if out=$(run uninstall 2>&1); then
    left=$(find "$h" -iname '*hyprcrt*')
    [ -z "$left" ] && ok "uninstall removed all $before hyprcrt paths" || bad "uninstall left: $(echo "$left" | tr '\n' ' ')"
    m=$h/.config/omarchy/extensions/omarchy-menu.jsonc
    if grep -q 'style.crt' "$m"; then bad "uninstall left the menu entries"
    elif ! grep -q '"user.mine"' "$m"; then bad "uninstall dropped the user's own menu entry"
    elif ! python3 -c "import json,re,sys; json.loads(re.sub(r'^\s*//.*$','',open(sys.argv[1]).read(),flags=re.M))" "$m"; then bad "uninstall left the menu file unparseable"
    else ok "uninstall took out the menu entries and kept the user's"; fi
    run uninstall >/dev/null 2>&1 || bad "a second uninstall failed"
    [ -z "$(find "$h" -iname '*hyprcrt*')" ] && ok "a second uninstall is quiet and leaves nothing" || bad "a second uninstall recreated: $(find "$h" -iname '*hyprcrt*' | tr '\n' ' ')"
else
    bad "hyprcrt uninstall failed: $out"
fi

# run from the Omarchy plugin's own tree, uninstall removes that plugin too, but only when asked or confirmed
p=$sb/home/.config/omarchy/plugins/danexpo.crt
mkdir -p "$p/bin" "$sb/stub" && cp "$root/bin/hyprcrt" "$p/bin/"
printf '#!/bin/sh\necho "$*" >> "%s/omarchy.calls"\n' "$sb" > "$sb/stub/omarchy" && chmod +x "$sb/stub/omarchy"
orun() { env -i PATH="$sb/stub:$PATH" HOME="$sb/home" XDG_RUNTIME_DIR="$sb/run" "$p/bin/hyprcrt" "$@" </dev/null; }
out=$(orun uninstall 2>&1)
if [ -e "$sb/omarchy.calls" ]; then bad "uninstall without --yes and without a terminal ran: $(cat "$sb/omarchy.calls")"
elif [[ $out != *"omarchy plugin remove danexpo.crt"* ]]; then bad "uninstall from the plugin tree did not say how to remove the plugin: $out"
else ok "without --yes or a terminal, uninstall names omarchy plugin remove and does not run it"; fi
orun uninstall --yes >/dev/null 2>&1
[ "$(cat "$sb/omarchy.calls" 2>/dev/null)" = "plugin remove danexpo.crt --yes" ] && ok "uninstall --yes removes the Omarchy plugin it runs from" \
    || bad "uninstall --yes called: $(cat "$sb/omarchy.calls" 2>/dev/null)"

[ "$fails" -eq 0 ] || { echo "cli: $fails failure(s)"; exit 1; }
echo "cli: set refuses bad values in both modes' ranges, stores good ones, gain=0 cannot go black, uninstall leaves nothing"
