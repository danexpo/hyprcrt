import QtQuick
import Quickshell
import Quickshell.Io

// hyprcrt background service (optional; the bar widget works without it).
// Mounted when "danexpo.crt" is listed in shell.json's top-level plugins[]. It restores the lite-mode
// shader after a login when no bar widget is placed, and tells the user when a Hyprland update left
// the full-mode plugin stale. MIT (c) 2026 Dan Expo.
Item {
  id: root

  property var shell: null

  readonly property string cli: String(Qt.resolvedUrl("../bin/hyprcrt")).replace(/^file:\/\//, "")
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

  IpcHandler {
    target: "crt-service"
    function status(): string { return "hyprcrt service running" }
    function toggle(): void { toggleProc.running = true }
  }

  Process {
    id: toggleProc
    command: [root.cli, "toggle"]
  }

  Component.onCompleted: { guardProc.running = true; statusProc.running = true }
}
