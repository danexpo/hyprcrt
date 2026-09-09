-- hyprcrt loader test session: a bare nested Hyprland that sources the installed loader exactly like a
-- user's config would. Run with tests/run-loader-test.sh; it checks the crash-loop guard end to end.
hl.monitor({ output = "", mode = "800x500@60", position = "auto", scale = 1 })
hl.config({
  animations = { enabled = false },
  misc = { disable_hyprland_logo = true, disable_splash_rendering = true },
  debug = { disable_scale_checks = true },
})
pcall(dofile, (os.getenv("XDG_DATA_HOME") or "") .. "/hyprcrt/loader.lua")
