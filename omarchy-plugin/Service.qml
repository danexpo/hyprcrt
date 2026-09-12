import QtQuick
import Quickshell
import Quickshell.Io

// hyprcrt background service (optional; the bar widget works without it).
// Mounted when "danexpo.crt" is listed in shell.json's top-level plugins[]. It restores the lite-mode
// shader after a login when no bar widget is placed, tells the user when a Hyprland update left
// the full-mode plugin stale, and after `omarchy plugin update` fetches (or builds) the library of
// the new version, since Omarchy runs no hook of the plugin's on a plugin update. MIT (c) 2026 Dan Expo.
Item {
  id: root

  property var shell: null

  readonly property string cli: String(Qt.resolvedUrl("../bin/hyprcrt")).replace(/^file:\/\//, "")
  readonly property string checkout: String(Qt.resolvedUrl("..")).replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string dataHome: Quickshell.env("XDG_DATA_HOME") || (Quickshell.env("HOME") + "/.local/share")

  // `hyprcrt status` re-applies nothing; the toggle file Omarchy sources on every reload carries the
  // lite-mode state across restarts, so all the service does at start is make sure the state file
  // the widget watches exists.
  Process {
    id: statusProc
    command: [root.cli, "status"]
  }

  // the crash-loop guard: if the previous session went down with the plugin loaded, this writes the
  // "disabled" note the loader honours and tells the user; otherwise it is a no-op
  Process {
    id: guardProc
    command: [root.cli, "guard"]
  }

  // A pacman hook (optional) touches this when the hyprland package changed. The Omarchy post-update
  // hook rebuilds; this is the fallback notice for people who update with pacman directly.
  FileView {
    path: root.dataHome + "/hyprcrt/rebuild-needed"
    watchChanges: true
    printErrors: false
    onLoaded: root.notifyStale()
    onFileChanged: root.notifyStale()
  }

  function notifyStale() {
    notifyProc.running = true
  }

  Process {
    id: notifyProc
    command: ["bash", "-lc", "[ -f \"$1/hyprcrt/rebuild-needed\" ] && { omarchy-notification-send -u normal 'CRT filter: Hyprland was updated, run: hyprcrt build'; rm -f \"$1/hyprcrt/rebuild-needed\"; }; exit 0", "_", root.dataHome]
  }

  // `omarchy plugin update` fast-forwards the checkout and runs nothing of ours, so at the next shell start the
  // installed library may be of an older hyprcrt than the panel and CLI now are (built-version beside it, against
  // manifest.json). crt-build then takes the prebuilt of this version, or compiles; without loading, as the
  // post-update hook does: a plugin goes into the running compositor only when the user says so.
  Process {
    id: refreshProc
    command: ["bash", "-lc", "so=$1/hyprcrt/hyprcrt.so; [ -e \"$so\" ] || exit 0; want=$(sed -n 's/.*\"version\": *\"\\([^\"]*\\)\".*/\\1/p' \"$2/manifest.json\" | head -n1); [ -n \"$want\" ] || exit 0; [ \"$(cat \"$1/hyprcrt/built-version\" 2>/dev/null)\" = \"$want\" ] && exit 0; if \"$2/tools/crt-build\" --no-load --source \"$2\"; then omarchy-notification-send -u low \"CRT filter updated to $want; it loads after the next restart (or now: hyprcrt plugin unload && hyprcrt plugin load)\"; else omarchy-notification-send -u critical \"CRT filter: the update to $want did not build, still running the old plugin (see hyprcrt build)\"; fi; exit 0", "_", root.dataHome, root.checkout]
  }

  IpcHandler {
    target: "crt-service"
    function status(): string { return "hyprcrt service running" }
    function toggle(): void { toggleProc.running = true }
  }

  Process {
    id: toggleProc
    command: [root.cli, "toggle"]
  }

  Component.onCompleted: { guardProc.running = true; statusProc.running = true; refreshProc.running = true }
}
