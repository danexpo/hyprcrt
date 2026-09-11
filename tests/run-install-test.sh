#!/bin/bash
# run-install-test.sh - the README's plain-Hyprland install on a clean HOME, as a stranger would run it.
#   tests/run-install-test.sh [plugin.so]   (default plugin/out/hyprcrt.so, which `make plugin` builds)
# A local directory stands in for the GitHub "prebuilt" release: SHA256SUMS plus the library, named after the commit
# the installed Hyprland headers carry. So the prebuilt path runs end to end offline: crt-fetch --check finds that
# commit, the download is verified, nothing compiles, and the files the README promises are where it says, inside a
# time a person would wait. A release whose checksum does not match must be refused, and a network that hangs rather than
# refuses must be given up on within half a minute (loopback listeners that never answer). The real release URL is not
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

# a network that hangs instead of refusing (a captive portal, a firewall that drops packets) must fall through to a local
# compile as a refused one does, not stall the install: two loopback listeners stand in for it, one that takes the
# connection and never answers, one whose accept queue is full so the connect itself goes unanswered. crt-fetch against
# each, with curl and then with wget (curl off the PATH), says no release is reachable (exit 3); the outer timeout makes a
# lost timeout a FAIL here rather than a gate that never returns. The four run side by side: they only wait.
hang=30
if ! command -v python3 >/dev/null || ! command -v wget >/dev/null; then
    bad "the hung-network cases need python3 and wget on the PATH"
else
    listeners=""
    trap 'kill $listeners 2>/dev/null || true; rm -rf "$sb"' EXIT
    for mode in silent full; do
        python3 -c '
import socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(0 if sys.argv[1] == "full" else 8)
held = []
if sys.argv[1] == "full":  # connections nobody accepts fill the queue, so the kernel drops further SYNs
    for _ in range(2):
        c = socket.socket(); c.setblocking(False); c.connect_ex(s.getsockname()); held.append(c)
    time.sleep(0.2)
print(s.getsockname()[1], flush=True)
time.sleep(float(sys.argv[2]))' "$mode" $((hang + 10)) > "$sb/$mode.port" &
        listeners="$listeners $!"
    done
    nocurl=$sb/nocurl
    mkdir -p "$nocurl"
    IFS=: read -ra dirs <<< "$PATH"
    for d in "${dirs[@]}"; do [ -d "$d" ] && find "$d" -maxdepth 1 ! -type d ! -name curl -exec ln -s -t "$nocurl" {} + 2>/dev/null || true; done
    env -i PATH="$nocurl" bash -c 'command -v curl' >/dev/null && bad "curl is still on the wget cases' PATH"
    for _ in $(seq 50); do [ -s "$sb/silent.port" ] && [ -s "$sb/full.port" ] && break; sleep 0.1; done
    fetchhang() { # case listener PATH
        local rc=0 t0 out
        t0=$(date +%s%N)
        out=$(env -i PATH="$3" HOME="$h" XDG_RUNTIME_DIR="$sb/run" HYPRCRT_RELEASE_URL="http://127.0.0.1:$(cat "$sb/$2.port")" timeout "$hang" "$src/tools/crt-fetch" 2>&1) || rc=$?
        printf '%s %s %s\n' "$rc" "$(( ($(date +%s%N) - t0) / 1000000 ))" "$out" > "$sb/hang-$1"
    }
    runs=""
    for c in curl-silent curl-full wget-silent wget-full; do
        [ "${c%%-*}" = curl ] && p=$PATH || p=$nocurl
        fetchhang "$c" "${c#*-}" "$p" &
        runs="$runs $!"
    done
    wait $runs
    for c in curl-silent curl-full wget-silent wget-full; do
        rc="" ms="" out=""
        read -r rc ms out < "$sb/hang-$c" || true
        [ "${c#*-}" = silent ] && what="takes the connection and never answers" || what="never completes the connect"
        if [ "$rc" = 3 ] && [[ $out == *"no prebuilt release reachable"* ]]; then
            ok "${c%%-*}, a server that $what: crt-fetch gave up in ${ms} ms (exit 3, so crt-build compiles)"
        elif [ "$rc" = 124 ]; then
            bad "${c%%-*}, a server that $what: crt-fetch still waiting after ${hang} s"
        else
            bad "${c%%-*}, a server that $what: exit $rc after ${ms} ms: $out"
        fi
    done
    kill $listeners 2>/dev/null || true
fi

[ "$fails" -eq 0 ] || { echo "install: $fails failure(s)"; exit 1; }
echo "install: the README's install on a clean HOME took the verified prebuilt for ${hdr:0:12}, compiled nothing, refused a bad checksum, and gave up on a hung network"
