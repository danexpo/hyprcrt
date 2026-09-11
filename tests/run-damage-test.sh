#!/bin/bash
# run-damage-test.sh - lite mode must not leave stale shading around a rect that changes (ledger C1/C3).
#   tests/run-damage-test.sh          (about a minute; needs /dev/dri, a Wayland host, chromium, grim, magick, python3)
# Hyprland's screen shader pass shades only the damaged rects, and the lite shader reads its neighbours, so under
# partial damage the pixels just outside a hovered element keep stale shading: the faint boxes of the 2026-09-05
# report. This runs two nested Hyprlands: a plain outer one, and inside it an inner one whose only hyprcrt wiring is
# lua/loader.lua on a sandboxed state. Chromium in the inner one shows a tile switched from here, beside a square
# that animates so frames keep coming. `grim` on the outer holds the inner's shaded output. Each frame after a switch
# is compared, around the tile, with the frame after a config reload (whole-monitor damage). A differing pixel is
# stale shading. Television (curvature) is set before the start, so it comes through the loader. Monitor (flat) is
# then set with `hyprcrt preset` against the running inner session, so its first switch comes through the CLI and
# the later ones through the loader again after each reload.
# Nothing reaches the live session: every hyprctl is -i to an instance matched by pid, hyprcrt runs under env -i
# with that signature and stubbed notifications, and the only thing the host sees is the outer window.
# Exit 0: no stale pixel; 1: stale pixels; 2: the setup failed. MIT (c) 2026 Dan Expo.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
T=$root/tests/out/damage
CYCLES=${CYCLES:-3}
PORT=${PORT:-8731}
for c in Hyprland hyprctl chromium grim magick python3 jq; do
    command -v "$c" >/dev/null || { echo "damage: $c is not installed"; exit 2; }
done
[ -e /dev/dri ] || { echo "damage: no /dev/dri"; exit 2; }
[ -n "${WAYLAND_DISPLAY:-}" ] || { echo "damage: no Wayland host to open the outer window on"; exit 2; }

rm -rf "$T"
mkdir -p "$T/home" "$T/bin" "$T/frames" "$T/config/hyprcrt" "$T/state/hyprcrt" "$T/data/hyprcrt" "$T/cache" "$T/www"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/notify-send"
cp "$T/bin/notify-send" "$T/bin/omarchy-notification-send"
chmod +x "$T/bin/notify-send" "$T/bin/omarchy-notification-send"
cp "$root/lua/loader.lua" "$T/data/hyprcrt/loader.lua"
export XDG_CONFIG_HOME=$T/config XDG_STATE_HOME=$T/state XDG_DATA_HOME=$T/data XDG_CACHE_HOME=$T/cache
export DBUS_SESSION_BUS_ADDRESS=disabled:
unset HYPRLAND_INSTANCE_SIGNATURE

# hyprcrt as a user runs it, but sandboxed: sig "" = no compositor (writes state and the shader only)
crt() {
    local sig=$1; shift
    env -i PATH="$T/bin:$PATH" HOME="$T/home" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" DBUS_SESSION_BUS_ADDRESS=disabled: \
        XDG_CONFIG_HOME="$T/config" XDG_STATE_HOME="$T/state" XDG_DATA_HOME="$T/data" XDG_CACHE_HOME="$T/cache" \
        ${sig:+HYPRLAND_INSTANCE_SIGNATURE="$sig"} "$root/bin/hyprcrt" "$@"
}
[ "$(crt "" mode)" = lite ] || { echo "damage: the sandbox sees a compositor; refusing to go on"; exit 2; }
crt "" preset television >/dev/null
grep -qx enabled=1 "$T/config/hyprcrt/state.conf" && [ -s "$T/config/hyprcrt/current.frag" ] ||
    { echo "damage: hyprcrt preset did not write a lite state"; exit 2; }

cat > "$T/www/page.html" <<'EOF'
<!doctype html><html><head><meta charset="utf-8"><style>
html,body{margin:0;background:#101010;color:#c8c8c8;font:16px sans-serif;height:100%;overflow:hidden}
#spin{position:absolute;left:10px;top:10px;width:12px;height:12px;animation:b .5s infinite alternate}
@keyframes b{from{background:#404040}to{background:#a0a0a0}}
#tile{position:absolute;left:60px;top:220px;width:240px;height:120px;background:#303030;color:#888;
 display:flex;align-items:center;justify-content:center;font-size:22px}
#tile.on{background:#f0f0f0;color:#101010}
</style></head><body><div id="spin"></div><div id="tile">Play</div>
<script>
let last = "";
setInterval(async () => {
  try { const s = (await (await fetch("state.txt", {cache: "no-store"})).text()).trim();
        if (s !== last) { last = s; document.getElementById("tile").className = s === "1" ? "on" : ""; } } catch (e) {}
}, 100);
</script></body></html>
EOF
echo 0 > "$T/www/state.txt"
common='hl.config({
  general = { gaps_in = 0, gaps_out = 0, border_size = 0 },
  decoration = { rounding = 0, blur = { enabled = false }, dim_inactive = false },
  animations = { enabled = false },
  misc = { disable_hyprland_logo = true, disable_splash_rendering = true, disable_watchdog_warning = true },
  debug = { disable_scale_checks = true },
})'
printf 'hl.monitor({ output = "", mode = "1600x900@60", position = "auto", scale = 1 })\n%s\n' "$common" > "$T/outer.lua"
printf 'hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })\n%s\npcall(dofile, "%s")\n' \
    "$common" "$T/data/hyprcrt/loader.lua" > "$T/inner.lua"

pids=()
sigs=()
cleanup() {
    local k s
    for ((k = ${#pids[@]} - 1; k >= 0; k--)); do kill "${pids[k]}" 2>/dev/null || true; done
    wait 2>/dev/null || true
    for s in "${sigs[@]}"; do [ -n "$s" ] && rm -rf "${XDG_RUNTIME_DIR:?}/hypr/$s"; done
}
trap cleanup EXIT
trap 'exit 143' INT TERM
instance_of() { # pid -> "signature wayland-socket"
    local r
    for _ in $(seq 150); do
        r=$(hyprctl instances -j 2>/dev/null | jq -r --argjson p "$1" '.[] | select(.pid == $p) | "\(.instance) \(.wl_socket)"')
        [ -n "$r" ] && { echo "$r"; return 0; }
        kill -0 "$1" 2>/dev/null || return 1
        sleep 0.1
    done
    return 1
}

Hyprland -c "$T/outer.lua" > "$T/outer.log" 2>&1 &
pids+=($!)
o=$(instance_of "${pids[-1]}") || { echo "damage: the outer Hyprland did not start (see $T/outer.log)"; exit 2; }
OSIG=${o% *} OWL=${o#* }
sigs+=("$OSIG")
WAYLAND_DISPLAY=$OWL Hyprland -c "$T/inner.lua" > "$T/inner.log" 2>&1 &
pids+=($!)
inner=$(instance_of "${pids[-1]}") || { echo "damage: the inner Hyprland did not start (see $T/inner.log)"; exit 2; }
ISIG=${inner% *} IWL=${inner#* }
sigs+=("$ISIG")
python3 -m http.server "$PORT" --bind 127.0.0.1 -d "$T/www" > "$T/http.log" 2>&1 &
pids+=($!)
WAYLAND_DISPLAY=$IWL chromium --ozone-platform=wayland --user-data-dir="$T/chromium" --no-first-run --disable-extensions \
    --noerrdialogs --disable-infobars --kiosk "http://127.0.0.1:$PORT/page.html" > "$T/chromium.log" 2>&1 &
pids+=($!)
for _ in $(seq 200); do grep -q 'GET /state.txt' "$T/http.log" 2>/dev/null && break; sleep 0.1; done
grep -q 'GET /state.txt' "$T/http.log" || { echo "damage: the page never loaded (see $T/chromium.log)"; exit 2; }
sleep 2

ih() { hyprctl -i "$ISIG" "$@"; }
shot() { WAYLAND_DISPLAY=$OWL grim "$T/frames/$1.png"; }
settle() { sleep 1.5; }
full() { ih reload >/dev/null; settle; }
CROP=320x200+20+180 # the tile (60,220 240x120) with 40 px around it, in the inner's pixels
stale() { magick "$1" "$2" -compose difference -composite -crop "$CROP" +repage -threshold 1% -format '%[fx:round(mean*w*h)]' info:; }
fails=0
measure() { # measure <preset> <cycles>: count stale pixels after each switch
    local p=$1 n=$2 c on off
    for c in $(seq "$n"); do
        echo 1 > "$T/www/state.txt"; settle; shot "$p-$c-lit"
        full; shot "$p-$c-lit-full"
        echo 0 > "$T/www/state.txt"; settle; shot "$p-$c-unlit"
        full; shot "$p-$c-unlit-full"
        on=$(stale "$T/frames/$p-$c-lit.png" "$T/frames/$p-$c-lit-full.png")
        off=$(stale "$T/frames/$p-$c-unlit.png" "$T/frames/$p-$c-unlit-full.png")
        if [ "$on" = 0 ] && [ "$off" = 0 ]; then echo "  ok   $p cycle $c: no stale pixel around the tile (dt $(dt))"
        else echo "  FAIL $p cycle $c: $on stale pixels after lighting, $off after dimming (dt $(dt))"; fails=$((fails + 1)); fi
    done
}
dt() { ih getoption debug:damage_tracking 2>/dev/null | sed -n 's/^int: //p' || true; }

echo "damage: lite mode, two nested Hyprlands (outer $OSIG, inner $ISIG)"
# the shader is on: a flat patch of the unlit tile (#303030) carries the mask and the scanlines, so it is not flat
full
shot sanity
sd=$(magick "$T/frames/sanity.png" -crop 60x30+70+230 +repage -format '%[fx:standard_deviation]' info:)
awk -v s="$sd" 'BEGIN { exit !(s > 0.005) }' || { echo "damage: the lite shader is not on in the inner session (a flat patch has deviation $sd)"; exit 2; }
echo "  ok   the lite shader is on (television, through the loader, deviation $sd)"
measure television "$CYCLES"
crt "$ISIG" preset monitor >/dev/null
settle
echo "  ok   hyprcrt preset monitor against the inner session"
measure monitor "$CYCLES"
if [ "$fails" = 0 ]; then echo "damage: no stale shading around a changed rect, $((CYCLES * 2)) cycles over two presets"; exit 0; fi
echo "damage: $fails cycles left stale shading (frames in $T/frames)"
exit 1
