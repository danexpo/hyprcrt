-- hyprcrt nested test session. Run with tests/run-nested.sh (never load an untested build into the live session).
-- Driven from the host only (hyprctl -i, WAYLAND_DISPLAY; see tests/lib-nested.sh): no terminal bind and no
-- start-up command, so no shell ever runs inside it.
hl.monitor({ output = "", mode = "1600x900@60", position = "auto", scale = 1 })

hl.config({
  general = { gaps_in = 4, gaps_out = 8, border_size = 2 },
  decoration = { rounding = 6, blur = { enabled = false } },
  animations = { enabled = false },
  misc = { disable_hyprland_logo = true, disable_splash_rendering = true },
  debug = { disable_scale_checks = true },
})

local so = os.getenv("HYPRCRT_SO")
if so and so ~= "" then
  hl.plugin.load(so)
end

hl.config({
  plugin = {
    crt = {
      scope = os.getenv("HYPRCRT_SCOPE") or "all",
      preset = os.getenv("HYPRCRT_PRESET") or "monitor",
      pitch = tonumber(os.getenv("HYPRCRT_PITCH") or "2"),
      stats = true,
      shader_dir = os.getenv("HYPRCRT_SHADERS") or "",
    },
  },
})

hl.bind("SUPER + C", hl.dsp.window.close())
hl.bind("SUPER + F", hl.dsp.window.fullscreen())
hl.bind("SUPER + T", hl.dsp.exec_cmd("hyprctl crt toggle"))

