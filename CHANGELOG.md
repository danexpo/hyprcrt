# Changelog

## 0.2.0 (unreleased)

Broader-audience release: no build step for most people, a compositor that cannot be taken down twice,
defaults that tell text from pictures, and install paths beyond Omarchy.

### Added
- Prebuilt plugin: CI publishes `hyprcrt-<hyprland commit>.so` to a rolling GitHub release;
  `hyprcrt install` / `tools/crt-fetch` download and verify the one matching the installed Hyprland,
  and compile only when none exists (`hyprcrt build --build` forces a local compile).
- Crash-loop guard: the plugin records the compositor pid while loaded; if Hyprland leaves a crash
  report for that pid, the loader keeps the plugin off, falls back to lite mode and says so
  (`hyprcrt plugin status`, `hyprcrt plugin enable` lifts it).
- One loader for both modes (`lua/loader.lua`): Omarchy's toggle file and plain Hyprland configs
  source it; it never stacks the lite shader on top of the plugin.
- Scope `auto` (new default): fullscreen windows get the tube, windowed media players and emulators
  (the `media` regex) get it through their own transformer, the desktop stays text-safe.
- `pitch_fullscreen`: the virtual line pitch for fullscreen video and browsers (3 = a 480-line tube on
  1440p; 2 keeps small UI text readable). In the panel as "Fullscreen video pitch".
- Hold-to-compare: `hyprcrt bypass on|off|toggle`, the `crt:bypass` dispatcher, `SUPER+ALT+X` held.
- `hyprcrt demo [preset] [seconds]` and the panel's "Try it for 10 s".
- `hyprcrt shot [file.png]`: the filtered frame as an image, in both modes (screenshots are unfiltered).
- `hyprcrt power auto|on|off`: a low-power profile (half-resolution halation, short afterglow).
- `hyprcrt plugin status|enable|disable|load|unload`.
- Plain Hyprland: `contrib/hyprland/hyprcrt.lua`; Waybar: `contrib/waybar/`; AUR: `packaging/aur/`.
- Preset previews rendered from a test card (`docs/previews/`), issue template, script checks in CI.
- `tests/run-loader-test.sh`: a nested session that exercises the loader and the guard.

### Fixed
- The gate compiles every shader (four presets, seven plugin passes) through glslangValidator and the
  GPU, and the QML lint can fail; the halation passes' `step` uniform, which shadowed a GLSL built-in
  that stricter compilers reject, is now `texelStep`.
- Preset buttons in the bar panel are a 2x2 grid, not a single row of four: "Scanlines" and
  "Television" no longer overflow their buttons (cells go from ~86 px to ~177 px wide).
- Building over a plugin the compositor had mapped could crash Hyprland during `plugin unload`:
  installs now write beside the file and rename (new inode), never in place.
- GL state desync with Hyprland's cached blend/scissor/stencil flags after the pass chain.
- GPU memory leak when a window with a transformer was destroyed (window mode).
- Transformers attached to unmapped windows; stale afterglow when an output re-entered scope;
  unescaped strings in `hyprctl crt status`; a runtime-loaded plugin waited for a config reload to
  block direct scanout.

## 0.1.0 (2026-09-05)

First working version: the tube model as a Hyprland screen shader (lite mode) and as a seven-pass
Hyprland plugin (full mode), four presets, six knobs, the Omarchy bar widget and panel, the CLI,
post-update rebuild hook.
