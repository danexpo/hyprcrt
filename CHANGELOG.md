# Changelog

## 0.2.2 (2026-09-12)

### Fixed
- Updating the plugin (`omarchy plugin update`) left the old library running under the new panel and CLI for
  good: `tools/crt-build` judged the installed library by the Hyprland commit alone, so it said "already matches"
  (or, with the library missing, compiled the checkout) and never took the new version. The library now records
  the hyprcrt version it was built from (`built-version` beside `built-for`; CI publishes a `VERSIONS` file next to
  `SHA256SUMS`), `crt-build` refreshes on a version mismatch as it does on a Hyprland change, `crt-fetch --want`
  takes a prebuilt only of the sources' version and otherwise lets `crt-build` compile, the post-update hook no
  longer exits early on a matching Hyprland when the version changed, the shell service fetches or builds the
  new version at the next shell start (without loading it) and says so, and `hyprcrt plugin status` says `stale`
  when the sources are newer than the library. `tests/run-install-test.sh` covers the second run, the update and
  the refusals.

## 0.2.1 (2026-09-12)

### Fixed
- Full mode flickered under a moving pointer: the mask pulsed on Monitor and the vignette twitched on Television. A
  hardware cursor move (or shape change) makes Hyprland render a frame with no damage, in which it draws no scene
  and keeps whatever its work buffer held, a frame this chain had already filtered; the plugin forced full damage on
  it and filtered that frame a second time, one doubled frame per mouse move. Such a frame is now left alone
  (no damage, no pass, nothing copied to the output). `crt status` counts them per monitor as `idle_frames`.

## 0.2.0 (2026-09-12)

Broader-audience release: no build step for most people, a compositor that cannot be taken down twice,
defaults that tell text from pictures, and a verified prebuilt for the running Hyprland.

### Changed
- The bar button is the television glyph (󰟴), the one the Television preset already uses, instead of a monitor.

### Added
- Both modes' defaults are the default preset's six knobs, not a copy of them: `tools/crt-presets` writes
  `default_preset` into `bin/hyprcrt` and `DEFAULT_PRESET` into `plugin/src/Look.hpp`, `lite_read` calls
  `lite_preset_knobs` and the plugin registers `plugin:crt:curve`…`sharp` from `applyPreset(DEFAULT_PRESET)`.
  `tests/presetcheck` reads each mode's effective defaults back and fails when they are not
  `presets/monitor.conf` (C10).
- `tools/crt-build` and `hyprcrt install` refuse to write the live `$HOME` from inside an agent
  session (`CLAUDECODE` set) unless `HYPRCRT_LIVE=1`, so an agent's own `env`/`export` mistakes can
  no longer overwrite `~/.local/share/hyprcrt`; `tests/run-cli-test.sh` proves the refusal, the
  `HYPRCRT_LIVE=1` override, and that a sandboxed `env -i` run is unaffected (C11).
- `make bench`: the offscreen GPU cost table in `docs/perf.md`, re-measured 2026-09-11 (Omarchy 4.0.3, Mesa 26.2.2).
- `docs/perf.md`'s in-compositor GPU timer table, re-measured 2026-09-11 against a fresh nested session (was dated 2026-09-05); its resolution claim is now described as not pinned by the harness rather than a fixed 1600×900.
- Prebuilt plugin: CI publishes `hyprcrt-<hyprland commit>.so` to a rolling GitHub release;
  `hyprcrt install` / `tools/crt-fetch` download and verify the one matching the installed Hyprland,
  and compile only when none exists (`hyprcrt build --build` forces a local compile).
- Crash-loop guard: the plugin records the compositor pid while loaded; if Hyprland leaves a crash
  report for that pid, the loader keeps the plugin off, falls back to lite mode and says so
  (`hyprcrt plugin status`, `hyprcrt plugin enable` lifts it).
- One loader for both modes (`lua/loader.lua`): Omarchy's toggle file
  sources it; it never stacks the lite shader on top of the plugin.
- Scope `auto` (new default): fullscreen windows get the tube, windowed media players and emulators
  (the `media` regex) get it through their own transformer, the desktop stays text-safe.
- `pitch_fullscreen`: the virtual line pitch for fullscreen video and browsers (3 = a 480-line tube on
  1440p; 2 keeps small UI text readable). In the panel as "Fullscreen video pitch".
- Hold-to-compare: `hyprcrt bypass on|off|toggle`, the `crt:bypass` dispatcher, `SUPER+ALT+X` held.
- `hyprcrt demo [preset] [seconds]` and the panel's "Try it for 10 s".
- `hyprcrt shot [file.png]`: the filtered frame as an image, in both modes (screenshots are unfiltered).
- `hyprcrt power auto|on|off`: a low-power profile (half-resolution halation, short afterglow).
- `hyprcrt plugin status|enable|disable|load|unload`.
- `hyprcrt uninstall [--yes]`: unloads the plugin and clears the shader in the running session, then
  removes everything install, the loader and both modes wrote (data, state, `state.conf`, the toggle
  file, the post-update hook, the menu entries, its own `~/.local/bin` link), keeps the user's own menu
  entries, removes the Omarchy plugin when run from it, and prints what needs root or the user's config.
- Preset previews rendered from a test card (`docs/previews/`), issue template, script checks in CI.
- `tests/run-loader-test.sh`: a nested session that exercises the loader and the guard.

### Fixed
- The README's install note said the `github.com/danexpo/hyprcrt` repository does not exist yet. It now
  does, and CI publishes a prebuilt plugin to its rolling `prebuilt` release; the note says what is
  actually in the way, that the repository is private and so those URLs answer 404 to a stranger (DR-F5).
- Every image the README shows was a render of corrupted input. `tests/shadercheck` read a P6 header's
  maxval and then read the pixels as bytes regardless, so the 16-bit ppm `magick source.png out.ppm`
  writes for a 16-bit png was consumed as an 8-bit one — half the picture, high and low bytes
  interleaved. It now reads 16-bit ppm properly and refuses any other maxval. `docs/previews/*.png` are
  re-rendered from that fix; `text_source_vs_monitor.png`'s filtered half had been a colour checkerboard
  rather than text. `tools/crt-previews` (`make previews`) is now the one command that renders them all,
  byte-reproducibly, so a stale preview shows up as a `git diff` (C12).
- `hyprcrt install` no longer waits forever for the prebuilt download on a network that hangs instead of
  refusing (a captive portal, a firewall that drops packets): `tools/crt-fetch` gives up after 20 s without a
  byte and compiles instead, while a slow but working link still gets the library (`tests/run-install-test.sh`).
- Lite mode `hyprcrt shot` saved the screen filtered twice on Hyprland 0.56, since the screenshot it filtered was
  already filtered; it now saves that screenshot. The README said plain screenshots are unfiltered in both
  modes; on 0.56 they hold the filtered picture, and it now says so (`tests/run-capture-test.sh`).
- Lite mode no longer leaves faint boxes or cut-off glow around a hovered button or anything else that redraws
  on its own. With its shader on it asks Hyprland for whole-monitor redraws (`debug:damage_tracking 1`, only
  when something changed), and the curved presets no longer redraw a static desktop at every refresh
  (`tests/run-damage-test.sh`).
- The README says plainly that the GitHub repository and its prebuilt releases are not published yet, and
  what `hyprcrt install` needs meanwhile.
- jq is a hard dependency: the Omarchy menu's check marks call it.
- Lite mode no longer takes knobs it cannot use: `set scope`, `low_power`, `pitch_fullscreen`, `match`,
  `media` and `hyprcrt power on|off|auto` exit 1 with "needs the full-mode plugin" and leave the state file as it was;
  lite `status` carries no `scope` or `low_power`, and the panel hides those rows in lite mode instead of
  showing a value that does nothing. `hyprcrt set gain .5` no longer makes lite `status` invalid JSON.
- `hyprcrt gen television` generated the default shader instead of the preset; a preset name now works
  as `--help` says, and an unknown one is refused.
- Full mode no longer forgets: a preset, a knob or `hyprcrt off` used to be lost at the next `hyprctl reload`
  or restart. Both modes now share `~/.config/hyprcrt/state.conf` (the old `lite.conf` is moved), which the
  plugin applies at load and after every config reload; its values win over `plugin:crt:*`.
- The nested test harness no longer opens a terminal or runs a start-up command inside the test session;
  it writes `tests/out/nested.sig` / `.wl` so every check is driven from the host, and killing the script
  stops the nested compositor. The signature files are also removed when the nested compositor dies on its own
  (a crash, the guard test's kill), instead of pointing the next `hyprctl -i` at a dead instance.
- `hyprcrt set gain 0` (or any value outside the plugin's ranges) no longer stores a black screen: `set`
  refuses bad `pitch`, `pitch_fullscreen`, `mask_pitch`, `gain`, `textsafe` and `low_power` values in both
  modes with the same message, lite mode clamps gain as the plugin does, and `set textsafe off` in lite
  mode now turns text-safe off.
- The gate compiles every shader (four presets, seven plugin passes) through glslangValidator and the
  GPU, and the QML lint can fail; the halation passes' `step` uniform, which shadowed a GLSL built-in
  that stricter compilers reject, is now `texelStep`.
- Presets have one source: `tools/crt-presets` writes the preset tables in `bin/hyprcrt` and the plugin's
  `Look.hpp` from `presets/*.conf`, and the gate (and CI) fails when either table is not what the data files
  generate (`tests/presetcheck`), so a preset edited in one place cannot look different per mode.
- The gate (and CI's build job) runs the README's plain-Hyprland install on a clean `HOME` against a local
  stand-in for the prebuilt release (`tests/run-install-test.sh`): the verified library and every file
  the README names land where it says, in well under 20 s, nothing compiles, and a checksum mismatch
  installs nothing.
- Preset buttons in the bar panel are a 2x2 grid, not a single row of four: "Scanlines" and
  "Television" no longer overflow their buttons (cells go from ~86 px to ~177 px wide).
- Building over a plugin the compositor had mapped could crash Hyprland during `plugin unload`:
  installs now write beside the file and rename (new inode), never in place.
- GL state desync with Hyprland's cached blend/scissor/stencil flags after the pass chain.
- GPU memory leak when a window with a transformer was destroyed (window mode).
- Transformers attached to unmapped windows; stale afterglow when an output re-entered scope;
  unescaped strings in `hyprctl crt status`; a runtime-loaded plugin waited for a config reload to
  block direct scanout.
- The gate could not see a uniform name go stale on one side of a rename: `glUniform*` on the -1
  `glGetUniformLocation` returns for an undeclared name is a silent no-op, so `Chain.cpp` and a pass's
  `.frag` could disagree with no error (as happened with the `texelStep` rename). `tests/uniformcheck`
  checks every `loc("name")` call against its pass's own `uniform` declarations, in `make gate` and CI.
- `crt dump` (full mode) no longer queues silently when no monitor is being filtered (`scope window`
  with no match, `scope off`, a bypass held): it refuses with an error naming why, and never writes a
  stray file later when a monitor next gets the chain. The frame it does write is written beside the
  path and renamed into place, so `hyprcrt shot` (which starts reading as soon as the file is
  non-empty) can no longer see a partial frame.
- `crt dump` (full mode) serves one request at a time: a second one while a frame is pending is refused
  instead of silently replacing the first, and a request no frame serves within 3 s is dropped rather than
  written late. `hyprcrt shot` says why the plugin refused a dump instead of "dump failed".
- `hyprcrt reload` (recompile the shaders: full mode's passes from disk, lite's from `state.conf`) was accepted
  but listed in neither `hyprcrt --help` nor the README; both list it, and `tests/run-cli-test.sh` checks that
  the help and the README name exactly the subcommands the CLI accepts.

## 0.1.0 (2026-09-05)

First working version: the tube model as a Hyprland screen shader (lite mode) and as a seven-pass
Hyprland plugin (full mode), four presets, six knobs, the Omarchy bar widget and panel, the CLI,
post-update rebuild hook.
