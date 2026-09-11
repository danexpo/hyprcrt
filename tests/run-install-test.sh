#!/bin/bash
# run-install-test.sh - the README's plain-Hyprland install on a clean HOME, as a stranger would run it.
#   tests/run-install-test.sh [plugin.so]   (default plugin/out/hyprcrt.so, which `make plugin` builds)
# A local directory stands in for the GitHub "prebuilt" release: SHA256SUMS plus the library, named after the commit
# the installed Hyprland headers carry. So the prebuilt path runs end to end offline: crt-fetch --check finds that
# commit, the download is verified, nothing compiles, and the files the README promises are where it says, inside a
# time a person would wait. A release whose checksum does not match must be refused. The real release URL is not
# reached (that half waits on the GitHub remote). Nothing touches the live session: `env -i`, no instance signature.
# MIT (c) 2026 Dan Expo.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
lib=${1:-$root/plugin/out/hyprcrt.so}
limit=20 # seconds: the prebuilt install is a download and a few copies
[ -f "$lib" ] || { echo "install: $lib is missing (make plugin)"; exit 1; }
hdr=$(grep -m1 'GIT_COMMIT_HASH' "$(pkg-config --variable=includedir hyprland 2>/dev/null || echo /usr/include)/hyprland/src/version.h" 2>/dev/null | cut -d'"' -f2 || true)
[ -n "$hdr" ] || hdr=$(grep -m1 'GIT_COMMIT_HASH' /usr/include/hyprland/src/version.h 2>/dev/null | cut -d'"' -f2 || true) # as crt-fetch reads it
[ -n "$hdr" ] || { echo "install: no Hyprland headers to read the commit from"; exit 1; }

sb=$(mktemp -d "${TMPDIR:-/tmp}/hyprcrt-install.XXXXXX")
trap 'rm -rf "$sb"' EXIT
h=$sb/home
mkdir -p "$h" "$sb/run" "$sb/release" "$sb/badrelease"
cp "$lib" "$sb/release/hyprcrt-$hdr.so"
(cd "$sb/release" && sha256sum "hyprcrt-$hdr.so" > SHA256SUMS)
cp "$lib" "$sb/badrelease/hyprcrt-$hdr.so" && printf 'garbage' >> "$sb/badrelease/hyprcrt-$hdr.so"
cp "$sb/release/SHA256SUMS" "$sb/badrelease/"
fails=0
ok()  { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fails=$((fails + 1)); }
run() { local rel=$1; shift; env -i PATH="$PATH" HOME="$h" XDG_RUNTIME_DIR="$sb/run" HYPRCRT_RELEASE_URL="file://$sb/$rel" "$@"; }

# the README's `git clone`: the tracked files as the working tree has them, so the test sees uncommitted changes
src=$h/.local/share/hyprcrt-src
mkdir -p "$src"
if files=$(git -C "$root" ls-files -z --cached --others --exclude-standard 2>/dev/null | tr '\0' '\n') && [ -n "$files" ]; then
    while IFS= read -r f; do [ -e "$root/$f" ] && printf '%s\0' "$f"; done <<< "$files" | tar -C "$root" --null -T - -cf - | tar -C "$src" -xf -
else
    cp -a "$root/." "$src/" && rm -rf "$src/tests/out" "$src/plugin/out"
fi

if out=$(run release "$src/tools/crt-fetch" --check 2>&1) && [[ $out == *"exists for Hyprland ${hdr:0:12}"* ]]; then
    ok "crt-fetch --check found a prebuilt for the installed commit ${hdr:0:12}"
else
    bad "crt-fetch --check: $out"
fi

t0=$(date +%s%N)
if log=$(run release "$src/bin/hyprcrt" install --no-load --no-autostart 2>&1); then
    ms=$(( ($(date +%s%N) - t0) / 1000000 ))
    [ "$ms" -le $((limit * 1000)) ] && ok "install took ${ms} ms (limit ${limit} s)" || bad "install took ${ms} ms, over ${limit} s"
else
    bad "install failed: $log"
fi
data=$h/.local/share/hyprcrt
[[ $log != *"building for Hyprland"* ]] && [ ! -d "$src/plugin/out" ] && ok "nothing was compiled" || bad "install compiled the plugin instead of taking the prebuilt"
[ "$(readlink "$h/.local/bin/hyprcrt")" = "$src/bin/hyprcrt" ] && ok "the hyprcrt link in .local/bin points at the clone" || bad ".local/bin/hyprcrt: $(readlink "$h/.local/bin/hyprcrt" || echo missing)"
if [ "$(readlink "$data/hyprcrt.so")" = "hyprcrt-$hdr.so" ] && cmp -s "$data/hyprcrt-$hdr.so" "$lib" && [ "$(cat "$data/built-for")" = "$hdr" ]; then
    ok "hyprcrt.so -> hyprcrt-${hdr:0:12}….so, the verified library, built-for the installed commit"
else
    bad "the installed plugin: $(ls -l "$data" 2>&1 | tr '\n' ' ')"
fi
missing=""
for p in loader.lua shaders/common.glsl presets/monitor.conf tools/crt-gen tools/crt-build tools/crt-fetch; do [ -e "$data/$p" ] || missing="$missing $p"; done
cmp -s "$data/loader.lua" "$src/lua/loader.lua" || missing="$missing loader.lua(differs)"
[ -e "$src/contrib/hyprland/hyprcrt.lua" ] || missing="$missing contrib/hyprland/hyprcrt.lua"
[ -z "$missing" ] && ok "loader, shaders, presets, tools and the README's contrib file are in place" || bad "missing:$missing"
[ ! -e "$h/.local/state/omarchy" ] && [ ! -e "$h/.config/omarchy" ] && ok "--no-autostart on plain Hyprland wrote nothing of Omarchy's" || bad "install wrote Omarchy files on plain Hyprland"
st=$(run release "$h/.local/bin/hyprcrt" plugin status 2>&1 || true)
[[ $st == *"built: yes"*"for Hyprland ${hdr:0:12}"* && $st == *"loaded: no"* ]] && ok "hyprcrt plugin status: built for ${hdr:0:12}, not loaded" || bad "plugin status: $st"
[ "$(run release "$h/.local/bin/hyprcrt" mode 2>&1)" = lite ] && ok "with no compositor running, mode is lite" || bad "mode is not lite before any Hyprland start"

# a download that does not match SHA256SUMS never becomes the installed library
rm -rf "$data"
if out=$(run badrelease "$src/tools/crt-fetch" 2>&1); then
    bad "crt-fetch installed a library whose checksum does not match"
elif [[ $out == *"checksum mismatch"* ]] && [ -z "$(find "$data" -name '*.so*' 2>/dev/null)" ]; then
    ok "a checksum mismatch is refused and installs nothing"
else
    bad "the checksum mismatch: $out; $(find "$data" 2>/dev/null | tr '\n' ' ')"
fi

[ "$fails" -eq 0 ] || { echo "install: $fails failure(s)"; exit 1; }
echo "install: the README's install on a clean HOME took the verified prebuilt for ${hdr:0:12}, compiled nothing, refused a bad checksum"
