#!/bin/bash
# Launch a nested Hyprland with the freshly built plugin and shaders from this tree.
#   tests/run-nested.sh [scope] [preset] [pitch]
# The nested instance's signature is written to tests/out/nested.sig so hyprctl -i can talk to it.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tests/out"
export HYPRCRT_SO="$root/plugin/out/hyprcrt.so"
export HYPRCRT_SHADERS="$root/shaders"
export HYPRCRT_SCOPE="${1:-all}"
export HYPRCRT_PRESET="${2:-monitor}"
export HYPRCRT_PITCH="${3:-2}"
export HYPRCRT_EXEC="${HYPRCRT_EXEC:-}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
# keep lite-mode toggle files away from the live Omarchy session while testing
export XDG_STATE_HOME="$root/tests/out/state"
mkdir -p "$XDG_STATE_HOME/omarchy/toggles/hypr" "$XDG_STATE_HOME/hyprcrt"
export XDG_CONFIG_HOME="$root/tests/out/config"
mkdir -p "$XDG_CONFIG_HOME"
# a nested session must not inherit the parent's instance signature or it would talk to the wrong socket
unset HYPRLAND_INSTANCE_SIGNATURE
exec Hyprland -c "$root/tests/nested.lua" > "$root/tests/out/nested.log" 2>&1
