#!/bin/bash
# run-capture-test.sh - what a plain screenshot of a filtered output holds, in both modes (ledger C4).
#   tests/run-capture-test.sh          (about half a minute; needs /dev/dri, a Wayland host, grim, magick, the built plugin)
# A nested Hyprland whose only hyprcrt wiring is lua/loader.lua on a sandboxed state, with nothing on screen but
# Hyprland's flat background. A flat patch of a screenshot has no texture unless the filter's mask and scanlines are
# in it. `grim` connects to the nested session's socket, so the screenshot is taken by the nested compositor's own
# screencopy, the path every screenshot tool and screen share goes through. The README says what this finds:
# EXPECT=filtered (default) or EXPECT=unfiltered.
# Nothing reaches the live session: hyprctl is -i to the instance matched by pid, and hyprcrt runs under env -i with
# that signature and stubbed notifications. Exit 0: as expected; 1: not; 2: the setup failed. MIT (c) 2026 Dan Expo.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
T=$root/tests/out/capture
EXPECT=${EXPECT:-filtered}
for c in Hyprland hyprctl grim magick jq; do
    command -v "$c" >/dev/null || { echo "capture: $c is not installed"; exit 2; }
done
[ -e /dev/dri ] || { echo "capture: no /dev/dri"; exit 2; }
[ -n "${WAYLAND_DISPLAY:-}" ] || { echo "capture: no Wayland host to open the nested window on"; exit 2; }
[ -f "$root/plugin/out/hyprcrt.so" ] || { echo "capture: build the plugin first (make -C plugin all)"; exit 2; }

rm -rf "$T"
mkdir -p "$T/home" "$T/bin" "$T/config/hyprcrt" "$T/state/hyprcrt" "$T/data/hyprcrt" "$T/cache"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/notify-send"
cp "$T/bin/notify-send" "$T/bin/omarchy-notification-send"
chmod +x "$T/bin/notify-send" "$T/bin/omarchy-notification-send"
cp "$root/lua/loader.lua" "$T/data/hyprcrt/loader.lua"
cp -r "$root/shaders" "$root/presets" "$T/data/hyprcrt/" # what hyprcrt install puts beside the plugin
export XDG_CONFIG_HOME=$T/config XDG_STATE_HOME=$T/state XDG_DATA_HOME=$T/data XDG_CACHE_HOME=$T/cache
export DBUS_SESSION_BUS_ADDRESS=disabled:
unset HYPRLAND_INSTANCE_SIGNATURE

crt() { # hyprcrt as a user runs it, sandboxed: sig "" = no compositor
    local sig=$1; shift
    env -i PATH="$T/bin:$PATH" HOME="$T/home" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" DBUS_SESSION_BUS_ADDRESS=disabled: \
        XDG_CONFIG_HOME="$T/config" XDG_STATE_HOME="$T/state" XDG_DATA_HOME="$T/data" XDG_CACHE_HOME="$T/cache" \
        ${sig:+HYPRLAND_INSTANCE_SIGNATURE="$sig" WAYLAND_DISPLAY="$wl"} "$root/bin/hyprcrt" "$@"
}
[ "$(crt "" mode)" = lite ] || { echo "capture: the sandbox sees a compositor; refusing to go on"; exit 2; }
crt "" preset monitor >/dev/null
grep -qx enabled=1 "$T/config/hyprcrt/state.conf" || { echo "capture: hyprcrt preset did not write a lite state"; exit 2; }
printf 'hl.monitor({ output = "", mode = "1600x900@60", position = "auto", scale = 1 })
hl.config({
  animations = { enabled = false },
  misc = { disable_hyprland_logo = true, disable_splash_rendering = true, disable_watchdog_warning = true },
  ecosystem = { no_update_news = true, no_donation_nag = true },
  debug = { disable_scale_checks = true },
})
pcall(dofile, "%s")
' "$T/data/hyprcrt/loader.lua" > "$T/nested.lua"

pid="" sig="" wl=""
stop() {
    [ -n "$pid" ] && { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }
    [ -n "$sig" ] && rm -rf "${XDG_RUNTIME_DIR:?}/hypr/$sig"
    pid="" sig=""
}
trap stop EXIT
trap 'exit 143' INT TERM
start() { # start <log>: sets pid, sig and wl
    local r=""
    Hyprland -c "$T/nested.lua" > "$T/$1.log" 2>&1 &
    pid=$!
    for _ in $(seq 150); do
        r=$(hyprctl instances -j 2>/dev/null | jq -r --argjson p "$pid" '.[] | select(.pid == $p) | "\(.instance) \(.wl_socket)"')
        [ -n "$r" ] && break
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    [ -n "$r" ] || { echo "capture: the nested Hyprland did not start (see $T/$1.log)"; exit 2; }
    sig=${r% *} wl=${r#* }
    sleep 2
}
# the standard deviation of a flat 400x200 patch in the middle of a screenshot: 0 for Hyprland's background alone
texture() { WAYLAND_DISPLAY=$wl grim "$T/$1.png" && magick "$T/$1.png" -crop 400x200+600+350 +repage -format '%[fx:standard_deviation]' info:; }
flat() { awk -v s="$1" 'BEGIN { exit !(s < 0.002) }'; }
fails=0
check() { # check <what> <deviation>
    local got=unfiltered
    flat "$2" || got=filtered
    if [ "$got" = "$EXPECT" ]; then echo "  ok   $1: a screenshot is $got (patch deviation $2)"
    else echo "  FAIL $1: a screenshot is $got (patch deviation $2), the README says $EXPECT"; fails=$((fails + 1)); fi
}

shoot() { # shoot <what> <plain screenshot>: hyprcrt shot is the filtered screen, filtered once, so it matches the plain one
    local out d
    out=$(crt "$sig" shot "$T/shot-$3.png" 2>&1) || { echo "  FAIL $1: hyprcrt shot failed: $out"; fails=$((fails + 1)); return; }
    d=$(magick "$T/shot-$3.png" "$2" -compose difference -composite -crop 400x200+600+350 +repage -format '%[fx:mean]' info:)
    if awk -v d="$d" 'BEGIN { exit !(d < 0.001) }'; then echo "  ok   $1: hyprcrt shot is the screen as shown (mean difference $d)"
    else echo "  FAIL $1: hyprcrt shot differs from the screen as shown (mean difference $d)"; fails=$((fails + 1)); fi
}

echo "capture: plain screenshots of a nested Hyprland, lite then full mode"
start lite
[ "$(hyprctl -i "$sig" getoption decoration:screen_shader | sed -n 's/^str: //p')" = "$T/config/hyprcrt/current.frag" ] ||
    { echo "capture: the loader did not set the lite shader"; exit 2; }
crt "$sig" off >/dev/null
sleep 1
d=$(texture lite-off)
flat "$d" || { echo "capture: with the filter off the patch is not flat (deviation $d); the measure cannot tell"; exit 2; }
echo "  ok   filter off: the patch is flat (deviation $d)"
crt "$sig" on >/dev/null
sleep 1
check "lite mode, monitor preset" "$(texture lite-on)"
shoot "lite mode" "$T/lite-on.png" lite
stop

cp "$root/plugin/out/hyprcrt.so" "$T/data/hyprcrt/hyprcrt.so"
echo scope=all >> "$T/config/hyprcrt/state.conf"
start full
[ "$(crt "$sig" mode)" = plugin ] || { echo "capture: the loader did not load the plugin (hyprcrt mode says $(crt "$sig" mode))"; exit 2; }
err=$(crt "$sig" status | jq -r '.last_error // ""')
[ -z "$err" ] || { echo "capture: the plugin reports an error: $err"; exit 2; }
[ -z "$(hyprctl -i "$sig" getoption decoration:screen_shader | sed -n 's/^str: //p')" ] ||
    { echo "capture: the lite shader is still set under the plugin"; exit 2; }
sleep 1
check "full mode, monitor preset, scope all" "$(texture full-on)"
shoot "full mode" "$T/full-on.png" full
stop

[ "$fails" = 0 ] || { echo "capture: $fails check(s) disagree with the README (frames in $T)"; exit 1; }
echo "capture: plain screenshots are $EXPECT in both modes, as the README says"
