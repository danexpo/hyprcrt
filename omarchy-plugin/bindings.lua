-- hyprcrt keybindings for Omarchy. Load from ~/.config/hypr/bindings.lua with:
--   pcall(dofile, os.getenv("HOME") .. "/.config/omarchy/plugins/danexpo.crt/omarchy-plugin/bindings.lua")
-- SUPER+SHIFT+C is Omarchy's calendar, so these use ALT.
-- All of them go through the hyprcrt CLI, so they work in lite and full mode alike.
local hyprcrt = (os.getenv("HOME") or "") .. "/.config/omarchy/plugins/danexpo.crt/bin/hyprcrt"

o.bind("SUPER + ALT + C", "CRT filter toggle", hyprcrt .. " toggle")
o.bind("SUPER + ALT + SHIFT + C", "CRT filter next preset", hyprcrt .. " cycle")
o.bind("SUPER + CTRL + ALT + C", "CRT filter panel", "omarchy-shell crt toggle")
-- hold to compare: the plain picture while the key is down, the filter back on release
o.bind("SUPER + ALT + X", "CRT filter compare (hold)", hyprcrt .. " bypass on")
o.bind("SUPER + ALT + X", "CRT filter compare (release)", hyprcrt .. " bypass off", { release = true })
