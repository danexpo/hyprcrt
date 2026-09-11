#!/bin/bash
# lib-nested.sh - sourced by tests/run-nested.sh and tests/run-loader-test.sh.
#
# nested_run <config.lua> <log> <sigfile>
#   Starts a nested Hyprland, writes its instance signature to <sigfile> and its Wayland socket name to
#   <sigfile minus .sig>.wl, waits for it, and removes both when it exits (or when this script is killed,
#   which also stops the nested compositor). Everything is driven from the host:
#       hyprctl -i "$(cat tests/out/nested.sig)" crt status
#       WAYLAND_DISPLAY="$(cat tests/out/nested.wl)" imv docs/previews/source.png   # a client inside it
#   The harness never starts a shell or a terminal inside the nested session: one landed on the host's
#   active workspace on 2026-09-10 and a `start-hyprland` typed into it began a session inside the test.
#
# The nested window opens on the host's active workspace. To keep it off your screen, add this rule to
# your own Hyprland config (the harness never edits it):
#       hl.window_rule({ match = { class = "^aquamarine$" }, workspace = "special:crt-test silent" })
# MIT (c) 2026 Dan Expo.

nested_run() {
    local config=$1 log=$2 sig=$3
    local wl=${sig%.sig}.wl
    rm -f "$sig" "$wl"
    # a nested session must not inherit the parent's instance signature or it would talk to the wrong socket
    unset HYPRLAND_INSTANCE_SIGNATURE
    Hyprland -c "$config" > "$log" 2>&1 &
    NESTED_PID=$!
    trap 'kill "$NESTED_PID" 2>/dev/null; rm -f "$sig" "$wl"' EXIT
    trap 'exit 143' INT TERM
    local i inst=""
    for i in $(seq 150); do
        inst=$(hyprctl instances -j 2>/dev/null | jq -r --argjson p "$NESTED_PID" '.[] | select(.pid == $p) | "\(.instance) \(.wl_socket)"')
        [ -n "$inst" ] && break
        kill -0 "$NESTED_PID" 2>/dev/null || break
        [ "$i" -lt 150 ] && sleep 0.1
    done
    if [ -z "$inst" ]; then
        echo "nested: no Hyprland instance appeared for pid $NESTED_PID (see $log)" >&2
        return 1
    fi
    printf '%s\n' "${inst% *}" > "$sig"
    printf '%s\n' "${inst#* }" > "$wl"
    echo "nested: pid $NESTED_PID, hyprctl -i \"\$(cat $sig)\", WAYLAND_DISPLAY=\"\$(cat $wl)\""
    wait "$NESTED_PID"
}
