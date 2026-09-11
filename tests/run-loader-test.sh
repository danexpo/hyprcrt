#!/bin/bash
# Nested Hyprland whose only hyprcrt wiring is the loader, for testing lua/loader.lua and the crash-loop
# guard. State/config/data/cache live under tests/out/loader so the live session is never touched.
#   tests/run-loader-test.sh   (background it; drive it with hyprctl -i "$(cat tests/out/loader.sig)"; killing
#                               the script stops the nested compositor, see tests/lib-nested.sh)
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
T=$root/tests/out/loader
mkdir -p "$T/data/hyprcrt" "$T/state/hyprcrt" "$T/config/hyprcrt" "$T/cache/hyprland"
ln -sfn "$root/plugin/out/hyprcrt.so" "$T/data/hyprcrt/hyprcrt.so"
cp "$root/lua/loader.lua" "$T/data/hyprcrt/loader.lua"
export XDG_DATA_HOME=$T/data XDG_STATE_HOME=$T/state XDG_CONFIG_HOME=$T/config XDG_CACHE_HOME=$T/cache
export HYPRCRT_SHADERS=$root/shaders
# shellcheck source=tests/lib-nested.sh
. "$root/tests/lib-nested.sh"
nested_run "$root/tests/loader-test.lua" "$T/hyprland.log" "$root/tests/out/loader.sig"
