// hyprcrt shell plugin - pure helpers, no Qt. MIT (c) 2026 Dan Expo.
.pragma library

var PRESETS = [
  { value: "plain", label: "Plain", icon: "󰹑" },
  { value: "scanlines", label: "Scanlines", icon: "󰍹" },
  { value: "monitor", label: "Monitor", icon: "󰌢" },
  { value: "television", label: "Television", icon: "󰟴" }
]

var GAMMA_LABELS = ["2.0", "2.2", "2.4", "2.6", "2.8"]
var MASK_OPTIONS = [
  { value: "0", label: "None" },
  { value: "1", label: "Aperture grille" },
  { value: "2", label: "Slot mask" },
  { value: "3", label: "Shadow mask" }
]
var SCOPE_OPTIONS = [
  { value: "auto", label: "Fullscreen + media players" },
  { value: "fullscreen", label: "Fullscreen windows" },
  { value: "games", label: "Fullscreen games" },
  { value: "all", label: "Whole desktop" },
  { value: "window", label: "Matching windows" },
  { value: "off", label: "Nothing" }
]
var PITCH_FS_OPTIONS = [
  { value: "1", label: "1 px (sharpest, text readable)" },
  { value: "2", label: "2 px (720-line tube on 1440p)" },
  { value: "3", label: "3 px (480-line tube on 1440p)" },
  { value: "4", label: "4 px" }
]
var PITCH_OPTIONS = [
  { value: "0", label: "Auto" },
  { value: "1", label: "1 px" },
  { value: "2", label: "2 px" },
  { value: "3", label: "3 px" },
  { value: "4", label: "4 px" },
  { value: "5", label: "5 px" },
  { value: "6", label: "6 px" }
]

function parseStatus(text) {
  try {
    var s = JSON.parse(String(text || "").trim())
    return (s && typeof s === "object") ? s : {}
  } catch (e) {
    return {}
  }
}

function presetLabel(value) {
  for (var i = 0; i < PRESETS.length; i++) if (PRESETS[i].value === value) return PRESETS[i].label
  return value === "custom" ? "Custom" : String(value || "")
}

function gammaLabel(i) {
  i = Number(i)
  return (i >= 0 && i < GAMMA_LABELS.length) ? GAMMA_LABELS[i] : "2.2"
}

function knob(status, name, fallback) {
  var k = status && status.knobs ? status.knobs[name] : undefined
  return (k === undefined || k === null) ? fallback : Number(k)
}

// the loader kept the plugin off after a crash (or the user disabled it): the reason, or ""
function disabledReason(status) {
  return (status && typeof status.plugin_disabled === "string") ? status.plugin_disabled : ""
}

function modeLabel(status) {
  if (!status || !status.mode) return "Not running"
  if (status.mode === "plugin") return "Full mode (plugin)"
  return status.plugin_built ? "Lite mode (plugin built, loads on next Hyprland start)" : "Lite mode (screen shader)"
}

function gpuText(status) {
  if (!status || status.mode !== "plugin" || !status.monitors) return ""
  var parts = []
  for (var i = 0; i < status.monitors.length; i++) {
    var m = status.monitors[i]
    if (!m) continue
    parts.push(m.name + (m.active ? ": " + (Number(m.gpu_ms) > 0 ? Number(m.gpu_ms).toFixed(2) + " ms, pitch " + m.pitch : "pitch " + m.pitch) : ": idle"))
  }
  return parts.join(" · ")
}
