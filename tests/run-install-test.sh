#!/bin/bash
# run-install-test.sh - `hyprcrt install` from a checkout on a clean HOME, as a stranger would run it.
#   tests/run-install-test.sh [plugin.so]   (default plugin/out/hyprcrt.so, which `make plugin` builds)
# A local directory stands in for the GitHub "prebuilt" release: SHA256SUMS plus the library, named after the commit
# the installed Hyprland headers carry. So the prebuilt path runs end to end offline: crt-fetch --check finds that
# commit, the download is verified, nothing compiles, and the files the README promises are where it says, inside a
# time a person would wait. A second run against the same sources leaves the library alone; sources of a newer
# hyprcrt (an `omarchy plugin update`) take the prebuilt of that version, and a release that has none of that
# version is left alone so crt-build compiles. A release whose checksum does not match must be refused, and a network that hangs rather than
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
ver=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$root/manifest.json" | head -n1)
[ -n "$ver" ] || { echo "install: no version in manifest.json"; exit 1; }
cp "$lib" "$sb/release/hyprcrt-$hdr.so"
(cd "$sb/release" && sha256sum "hyprcrt-$hdr.so" > SHA256SUMS && echo "$ver  hyprcrt-$hdr.so" > VERSIONS)
cp "$lib" "$sb/badrelease/hyprcrt-$hdr.so" && printf 'garbage' >> "$sb/badrelease/hyprcrt-$hdr.so"
cp "$sb/release/SHA256SUMS" "$sb/release/VERSIONS" "$sb/badrelease/"
fails=0
ok()  { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fails=$((fails + 1)); }
run() { local rel=$1; shift; env -i PATH="$PATH" HOME="$h" XDG_RUNTIME_DIR="$sb/run" HYPRCRT_RELEASE_URL="file://$sb/$rel" "$@"; }

# a checkout: the tracked files as the working tree has them, so the test sees uncommitted changes
src=$h/.local/share/hyprcrt-src
mkdir -p "$src"
if files=$(git -C "$root" ls-files -z --cached --others --exclude-standard 2>/dev/null | tr '\0' '\n') && [ -n "$files" ]; then
    while IFS= read -r f; do [ -e "$root/$f" ] && printf '%s\0' "$f"; done <<< "$files" | tar -C "$root" --null -T - -cf - | tar -C "$src" -xf -
else
    cp -a "$root/." "$src/" && rm -rf "$src/tests/out" "$src/plugin/out"
fi

if out=$(run release "$src/tools/crt-fetch" --check --want "$ver" 2>&1) && [[ $out == *"exists for Hyprland ${hdr:0:12} (hyprcrt $ver)"* ]]; then
    ok "crt-fetch --check found a prebuilt of hyprcrt $ver for the installed commit ${hdr:0:12}"
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
if [ "$(readlink "$data/hyprcrt.so")" = "hyprcrt-$hdr.so" ] && cmp -s "$data/hyprcrt-$hdr.so" "$lib" && [ "$(cat "$data/built-for")" = "$hdr" ] && [ "$(cat "$data/built-version")" = "$ver" ]; then
    ok "hyprcrt.so -> hyprcrt-${hdr:0:12}….so, the verified library, built-for the installed commit, built-version $ver"
else
    bad "the installed plugin: $(ls -l "$data" 2>&1 | tr '\n' ' ')"
fi
missing=""
for p in loader.lua shaders/common.glsl presets/monitor.conf tools/crt-gen tools/crt-build tools/crt-fetch; do [ -e "$data/$p" ] || missing="$missing $p"; done
cmp -s "$data/loader.lua" "$src/lua/loader.lua" || missing="$missing loader.lua(differs)"
[ -z "$missing" ] && ok "loader, shaders, presets and tools are in place" || bad "missing:$missing"
[ ! -e "$h/.local/state/omarchy" ] && [ ! -e "$h/.config/omarchy" ] && ok "--no-autostart without Omarchy wrote nothing of Omarchy's" || bad "install wrote Omarchy files where there is no Omarchy"
st=$(run release "$h/.local/bin/hyprcrt" plugin status 2>&1 || true)
[[ $st == *"built: yes"*"for Hyprland ${hdr:0:12}, hyprcrt $ver"* && $st == *"loaded: no"* && $st != *stale* ]] && ok "hyprcrt plugin status: built for ${hdr:0:12}, hyprcrt $ver, not loaded, not stale" || bad "plugin status: $st"
[ "$(run release "$h/.local/bin/hyprcrt" mode 2>&1)" = lite ] && ok "with no compositor running, mode is lite" || bad "mode is not lite before any Hyprland start"

# the same sources again: the library is left alone (no download, no compile)
ino=$(stat -c %i "$data/hyprcrt-$hdr.so")
if out=$(run release "$src/tools/crt-build" --no-load --no-autostart --source "$src" 2>&1) && [[ $out == *"is already hyprcrt $ver for Hyprland ${hdr:0:12}"* ]] && [ "$(stat -c %i "$data/hyprcrt-$hdr.so")" = "$ino" ]; then
    ok "crt-build again from the same sources leaves the installed library alone"
else
    bad "crt-build again: $out"
fi

# `omarchy plugin update` moved the sources on to a newer hyprcrt while the installed library stays the old one:
# crt-build must take the prebuilt of the new version (the stand-in release now carries it), and say so
new=$ver.99
sed -i "s/\"version\": *\"$ver\"/\"version\": \"$new\"/" "$src/manifest.json"
printf 'newer' >> "$sb/release/hyprcrt-$hdr.so"
(cd "$sb/release" && sha256sum "hyprcrt-$hdr.so" > SHA256SUMS && echo "$new  hyprcrt-$hdr.so" > VERSIONS)
st=$(run release "$h/.local/bin/hyprcrt" plugin status 2>&1 || true)
[[ $st == *"stale: the sources are hyprcrt $new"* ]] && ok "hyprcrt plugin status names the library stale against sources of $new" || bad "plugin status after a source update: $st"
if out=$(run release "$src/tools/crt-build" --no-load --no-autostart --source "$src" 2>&1) && [[ $out != *"building hyprcrt"* ]] && cmp -s "$data/hyprcrt-$hdr.so" "$sb/release/hyprcrt-$hdr.so" && [ "$(cat "$data/built-version")" = "$new" ]; then
    ok "sources of $new over an installed $ver: crt-build took the prebuilt of $new, compiled nothing"
else
    bad "crt-build after a source update: $out; built-version $(cat "$data/built-version" 2>/dev/null)"
fi
# and when the release has no library of the sources' version (or does not say which), the prebuilt is refused
# so crt-build compiles the sources rather than install a library of another version
(cd "$sb/release" && echo "$ver  hyprcrt-$hdr.so" > VERSIONS)
if out=$(run release "$src/tools/crt-fetch" --want "$new" 2>&1); then
    bad "crt-fetch --want $new installed a prebuilt of $ver"
elif [ $? = 3 ] || [[ $out == *"is hyprcrt $ver, the sources are $new"* ]]; then
    ok "a prebuilt of another version is refused (exit 3, so crt-build compiles): $out"
else
    bad "crt-fetch --want $new: $out"
fi
rm -f "$sb/release/VERSIONS"
if out=$(run release "$src/tools/crt-fetch" --want "$new" 2>&1); then
    bad "crt-fetch --want $new installed a prebuilt whose version the release does not state"
elif [[ $out == *"of an unstated version, the sources are $new"* ]]; then
    ok "a prebuilt of unstated version is refused as well"
else
    bad "crt-fetch --want $new with no VERSIONS: $out"
fi
(cd "$sb/release" && echo "$ver  hyprcrt-$hdr.so" > VERSIONS)
sed -i "s/\"version\": *\"$new\"/\"version\": \"$ver\"/" "$src/manifest.json"

# the post-update hook runs unattended, so it executes nothing from the checkout and nothing found on the PATH, takes
# only a verified prebuilt of the checkout's version, and replaces a symlink planted where its state lives instead of
# following it; a release without that version, a checksum mismatch or a state directory others can write leave
# everything untouched
co=$h/.config/omarchy/plugins/danexpo.crt
mkdir -p "$co/tools" "$sb/shadow"
sed "s/\"version\": *\"$ver\"/\"version\": \"$new\"/" "$src/manifest.json" > "$co/manifest.json"
printf '#!/bin/sh\necho crt-build >> "%s/checkout.calls"\n' "$sb" > "$co/tools/crt-build" && chmod +x "$co/tools/crt-build"
for t in sha256sum curl wget mv ln stat mkdir chmod rm cat sed grep; do printf '#!/bin/sh\necho %s >> "%s/shadow.calls"\nexit 1\n' "$t" "$sb" > "$sb/shadow/$t"; chmod +x "$sb/shadow/$t"; done
printf 'newest' >> "$sb/release/hyprcrt-$hdr.so"
(cd "$sb/release" && sha256sum "hyprcrt-$hdr.so" > SHA256SUMS && echo "$new  hyprcrt-$hdr.so" > VERSIONS)
cp "$sb/release/SHA256SUMS" "$sb/badrelease/"; (cd "$sb/badrelease" && echo "$new  hyprcrt-$hdr.so" > VERSIONS)
echo canary > "$sb/canary"; ln -sfn "$sb/canary" "$data/built-version"
hook() { env -i PATH="$sb/shadow:$PATH" HOME=/nonexistent XDG_DATA_HOME=/nonexistent bash "$src/omarchy-plugin/hooks/hyprcrt-rebuild" --home "$h" "$@" </dev/null; }
ino=$(stat -c %i "$data/hyprcrt-$hdr.so")
if out=$(hook --release "file://$sb/badrelease" 2>&1) && [ "$(stat -c %i "$data/hyprcrt-$hdr.so")" = "$ino" ] && [ -L "$data/built-version" ]; then
    ok "the hook refuses a prebuilt whose checksum does not match and changes nothing"
else
    bad "the hook against a bad checksum: $out; $(ls -l "$data" | tr '\n' ' ')"
fi
(cd "$sb/release" && echo "$ver  hyprcrt-$hdr.so" > VERSIONS)
if out=$(hook --release "file://$sb/release" 2>&1) && [ "$(stat -c %i "$data/hyprcrt-$hdr.so")" = "$ino" ] && [ -L "$data/built-version" ]; then
    ok "the hook leaves a prebuilt of another version alone (the user is told to run hyprcrt build)"
else
    bad "the hook against a release of $ver for sources of $new: $out; $(ls -l "$data" | tr '\n' ' ')"
fi
(cd "$sb/release" && echo "$new  hyprcrt-$hdr.so" > VERSIONS)
chmod g+w "$data"
if out=$(hook --release "file://$sb/release" 2>&1) && [ "$(stat -c %i "$data/hyprcrt-$hdr.so")" = "$ino" ] && [ -L "$data/built-version" ]; then
    ok "the hook does nothing while others can write its state directory"
else
    bad "the hook with a group-writable state directory: $out; $(ls -l "$data" | tr '\n' ' ')"
fi
chmod g-w "$data"
if out=$(hook --release "file://$sb/release" 2>&1) && cmp -s "$data/hyprcrt-$hdr.so" "$sb/release/hyprcrt-$hdr.so" && [ "$(readlink "$data/hyprcrt.so")" = "hyprcrt-$hdr.so" ] \
    && [ ! -L "$data/built-version" ] && [ "$(cat "$data/built-version")" = "$new" ] && [ "$(cat "$data/built-for")" = "$hdr" ] && [ "$(cat "$sb/canary")" = canary ]; then
    ok "the hook installed the verified prebuilt of $new for ${hdr:0:12} and replaced the planted symlink rather than write through it"
else
    bad "the hook: $out; $(ls -l "$data" | tr '\n' ' '); canary: $(cat "$sb/canary")"
fi
[ ! -e "$sb/checkout.calls" ] && [ ! -e "$sb/shadow.calls" ] && ok "the hook ran nothing from the checkout and nothing from the PATH" \
    || bad "the hook ran: $(cat "$sb/checkout.calls" "$sb/shadow.calls" 2>/dev/null | tr '\n' ' ')"
[ -z "$(find "$data" -maxdepth 1 -name '.post-update.*')" ] && ok "the hook removed its temporary directory" || bad "the hook left: $(ls -a "$data" | tr '\n' ' ')"
ino=$(stat -c %i "$data/hyprcrt-$hdr.so")
if out=$(hook --release "file://$sb/release" 2>&1) && [ "$(cat "$data/built-version")" = "$new" ] && [ "$(stat -c %i "$data/hyprcrt-$hdr.so")" = "$ino" ]; then
    ok "the hook again, with the library current, leaves it alone"
else
    bad "the hook a second time: $out"
fi
rm -rf "$co" "$sb/shadow"
(cd "$sb/release" && echo "$ver  hyprcrt-$hdr.so" > VERSIONS)

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
echo "install: the README's install on a clean HOME took the verified prebuilt for ${hdr:0:12}, compiled nothing, took the prebuilt of a newer version after a source update and only that, refused a bad checksum, and gave up on a hung network"
