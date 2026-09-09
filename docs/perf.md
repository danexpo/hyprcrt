# Performance and latency notes

Machine: Omarchy 4.0.2, Hyprland 0.56.2, AMD Radeon RX 6900 XT (Navi 21, radeonsi, Mesa 26.2.1),
3440×1440 @ 60 Hz, scale 1.25. Date: 2026-09-05.

## GPU cost, offscreen (bench/bench.c)

Random-noise input, 300 frames after warm-up, wall time around `glFinish`.

| Pass configuration | 3440×1440 | 3840×2160 |
|---|---|---|
| Passthrough blit (Hyprland's own final pass) | 0.026 ms | 0.038 ms |
| Lite mode: single-pass Lottes-style (9 taps, warp, mask, gamma) | 0.167 ms | 0.262 ms |
| 3 passes (beam, scan+mask, glass), no glow/halation | 0.185 ms | 0.568 ms |
| Full mode: 6 passes with afterglow and halation at 1:1 | 0.707 ms | 1.478 ms |
| Single pass on a 25 % damage rect | 0.046 ms | 0.072 ms |

Frame budget: 16.7 ms at 60 Hz, 6.9 ms at 144 Hz.

## GPU cost, inside the compositor (plugin timer query, nested 1600×900 session)

`plugin:crt:stats = true` makes the plugin wrap its chain in a `GL_TIME_ELAPSED_EXT` query;
`hyprctl crt status` reports it per monitor.

| Preset, pitch 2 at 1600×900 | GPU ms per frame |
|---|---|
| Monitor (grille, lines 3, glow 2) | 0.09–0.23 |
| Television (slot, lines 2, glow 3, glass) | 0.12 |

At pitch 2 the glow/halation passes run at 800×450, so the chain is cheaper than the 1:1 benchmark.
Scaling by pixel count, the 3440×1440 desktop at pitch 1 with `halo_half` lands at about 0.5 ms.

## Latency

Nothing in either mode adds a frame: the lite shader is Hyprland's own final blit with more maths in
it, and the plugin's chain runs inside the same render pass before that blit. The composited path
itself costs about one refresh period between an app's commit and scanout; direct scanout (off by
default in Omarchy) would remove that period for a fullscreen game and would also remove the filter,
which is why full mode blocks it while enabled (`plugin:crt:block_scanout`).

## Idle behaviour

Full mode renders only when Hyprland renders: a frame that changes, plus `glow_frames` (default 12)
extra frames after the last change so the afterglow can decay. A static desktop costs nothing. Lite
mode is damage-tracked unless curvature is on, in which case `debug:damage_tracking` is set to 0
while the filter is enabled (a full 0.17 ms frame per redraw, still only when something redraws).

## How to re-measure

```sh
gcc -O2 bench/bench.c -o bench/bench $(pkg-config --cflags --libs egl glesv2 gbm) -lm && bench/bench 3440 1440
tests/run-nested.sh all television 2 &      # then: hyprctl -i <sig> crt status  (gpu_ms per monitor)
cat /sys/class/drm/card1/device/gpu_busy_percent   # idle check while the desktop is static
```
