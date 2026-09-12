#!/bin/bash
# Launch a nested Hyprland with the freshly built plugin and shaders from this tree.
#   tests/run-nested.sh [scope] [preset] [pitch]      (HYPRCRT_KEEP_STATE=1 keeps tests/out/config/hyprcrt/state.conf)
# Its instance signature goes to tests/out/nested.sig and its Wayland socket to tests/out/nested.wl, so every
# check is driven from the host (tests/lib-nested.sh has the commands, and the window rule that keeps the
# nested window off your screen). No shell or terminal is ever started inside it.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tests/out"
# the tree's own build by default; set HYPRCRT_SO to load another one (a prebuilt release, say)
export HYPRCRT_SO="${HYPRCRT_SO:-$root/plugin/out/hyprcrt.so}"
export HYPRCRT_SHADERS="$root/shaders"
export HYPRCRT_SCOPE="${1:-all}"
export HYPRCRT_PRESET="${2:-monitor}"
export HYPRCRT_PITCH="${3:-2}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
# keep lite-mode toggle files away from the live Omarchy session while testing
export XDG_STATE_HOME="$root/tests/out/state"
mkdir -p "$XDG_STATE_HOME/omarchy/toggles/hypr" "$XDG_STATE_HOME/hyprcrt"
export XDG_CONFIG_HOME="$root/tests/out/config"
mkdir -p "$XDG_CONFIG_HOME"
# the state file wins over the arguments above, so a run starts without one; HYPRCRT_KEEP_STATE=1 keeps it,
# to prove what `hyprcrt` set survives a restart
[ "${HYPRCRT_KEEP_STATE:-0}" = 1 ] || rm -f "$XDG_CONFIG_HOME/hyprcrt/state.conf" "$XDG_CONFIG_HOME/hyprcrt/lite.conf"
# shellcheck source=tests/lib-nested.sh
. "$root/tests/lib-nested.sh"
nested_run "$root/tests/nested.lua" "$root/tests/out/nested.log" "$root/tests/out/nested.sig"
