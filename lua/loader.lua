-- hyprcrt loader. Sourced by Hyprland's Lua config on every start and reload:
--   Omarchy: ~/.local/state/omarchy/toggles/hypr/hyprcrt.lua does pcall(dofile, "<data>/hyprcrt/loader.lua")
-- It decides between full mode (the plugin) and lite mode (the screen shader) from the files the
-- `hyprcrt` command maintains, and keeps a plugin that crashed the last session from loading again.
-- Installed copy of lua/loader.lua; `hyprcrt install` refreshes it. MIT (c) 2026 Dan Expo.

local home  = os.getenv("HOME") or ""
local data  = (os.getenv("XDG_DATA_HOME") or (home .. "/.local/share")) .. "/hyprcrt"
local state = (os.getenv("XDG_STATE_HOME") or (home .. "/.local/state")) .. "/hyprcrt"
local conf  = (os.getenv("XDG_CONFIG_HOME") or (home .. "/.config")) .. "/hyprcrt"
local cache = (os.getenv("XDG_CACHE_HOME") or (home .. "/.cache")) .. "/hyprland"

local function readfile(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end

local function exists(path)
  local f = io.open(path, "r")
  if f then f:close() return true end
  return false
end

-- state.conf: key=value lines written by the hyprcrt command for both modes (lite.conf in earlier builds)
local lite = {}
for line in (readfile(conf .. "/state.conf") or readfile(conf .. "/lite.conf") or ""):gmatch("[^\n]+") do
  local k, v = line:match("^([%w_]+)=(.*)$")
  if k then lite[k] = v end
end

local so = data .. "/hyprcrt.so"
if not exists(so) and exists("/usr/lib/hyprcrt/hyprcrt.so") then
  so = "/usr/lib/hyprcrt/hyprcrt.so" -- distribution package
end

-- crash-loop guard: the plugin writes plugin-loaded (the compositor's pid) while it is loaded and
-- removes it on a clean unload. If it is still there and Hyprland left a crash report for that pid,
-- the last session went down with the plugin in it: stay in lite mode until `hyprcrt plugin enable`.
local disabled = readfile(state .. "/plugin-disabled")
if not disabled and exists(so) then
  local marker = readfile(state .. "/plugin-loaded") or ""
  local pid = marker:match("^(%d+)")
  if pid and exists(cache .. "/hyprlandCrashReport" .. pid .. ".txt") then
    local f = io.open(state .. "/plugin-disabled", "w")
    if f then
      f:write("Hyprland crashed while the CRT plugin was loaded (crash report for pid " .. pid .. "); " ..
              "the plugin stays off until you run: hyprcrt plugin enable\n")
      f:close()
    end
    os.remove(state .. "/plugin-loaded")
    disabled = "crash"
  end
end

-- a library built for another Hyprland commit (an update whose hook found no prebuilt of it yet) is not offered:
-- Hyprland would refuse it after this file ran, and the screen would be left with no filter at all rather than
-- the lite shader. The running commit is the instance signature's first field; built-for is what the library was
-- built against. Unknown on either side counts as compatible (a distribution package carries no built-for).
local running  = (os.getenv("HYPRLAND_INSTANCE_SIGNATURE") or ""):match("^(%x+)_")
local builtfor = (readfile(data .. "/built-for") or ""):match("^(%x+)")
local compatible = not running or not builtfor or running == builtfor

local full = exists(so) and not disabled and compatible
if full then
  hl.plugin.load(so)
  -- never stack the lite shader on top of the plugin
  hl.config({ decoration = { screen_shader = "" }, debug = { damage_tracking = 2 } })
elseif lite.enabled == "1" and exists(conf .. "/current.frag") then
  -- Hyprland shades only the damaged rect, but the shader reads its neighbours (and curvature moves pixels), so a
  -- partial redraw leaves stale shading around what changed: redraw the whole monitor whenever anything changes
  -- (damage_tracking 1). Unlike 0, it draws nothing while the screen is still. tests/run-damage-test.sh
  hl.config({ decoration = { screen_shader = conf .. "/current.frag" }, debug = { damage_tracking = 1 } })
else
  hl.config({ decoration = { screen_shader = "" }, debug = { damage_tracking = 2 } })
end
