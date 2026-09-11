import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// hyprcrt - the bar button and its panel. Everything goes through bin/hyprcrt, which drives the
// Hyprland plugin when it is loaded (full mode) and Hyprland's screen shader otherwise (lite mode),
// so the panel works the same before and after the plugin is built. MIT (c) 2026 Dan Expo.
Panel {
  id: root
  moduleName: "danexpo.crt"
  ipcTarget: "crt"
  manageIpc: false

  // ---- state, straight from `hyprcrt status` ----
  property var status: ({})
  readonly property bool enabled: status.enabled === true
  readonly property string mode: status.mode || ""
  readonly property string preset: status.preset || "monitor"
  readonly property bool pluginMode: mode === "plugin"
  readonly property bool pluginBuilt: pluginMode || status.plugin_built === true
  property bool building: false
  property string buildOutput: ""
  property bool busy: false

  readonly property string cli: String(Qt.resolvedUrl("../bin/hyprcrt")).replace(/^file:\/\//, "")
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")
  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string ff: bar ? bar.fontFamily : Style.font.family

  // the bar sizes the slot from the widget's implicit size; without this the widget is 0 px wide
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  // one command at a time; the change stamp the CLI touches refreshes the state afterwards
  property var pending: []
  function run(args) {
    pending.push(args)
    pump()
  }
  function pump() {
    if (cmdProc.running || pending.length === 0) return
    var args = pending.shift()
    cmdProc.command = [root.cli].concat(args)
    root.busy = true
    cmdProc.running = true
  }

  function toggleEnabled() { run(["toggle"]) }
  function setPreset(p) { run(["preset", p]) }
  function setKnob(name, value) { run(["set", name, String(value)]) }
  function cycle() { run(["cycle"]) }
  function demo(p) { run(["demo", p, "10"]) }
  function setPower(on) { run(["power", on ? "on" : "off"]) }
  function enablePlugin() { run(["plugin", "enable"]) }

  function build() {
    if (building) return
    building = true
    buildOutput = ""
    buildProc.running = true
  }

  Process {
    id: statusProc
    command: [root.cli, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.status = Model.parseStatus(text)
    }
  }

  Process {
    id: cmdProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: function() {
      root.busy = false
      root.refresh()
      root.pump()
    }
  }

  Process {
    id: buildProc
    command: [root.cli, "install", "--no-load"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.buildOutput = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") root.buildOutput = root.buildOutput + "\n" + text
    }
    onExited: function(exitCode) {
      root.building = false
      root.refresh()
    }
  }

  // the CLI touches this after every change, from keybindings and the menu too
  FileView {
    path: root.stateHome + "/hyprcrt/changed"
    watchChanges: true
    onFileChanged: root.refresh()
  }

  Timer {
    interval: 2500
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: refresh()

  IpcHandler {
    target: "crt"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
    function toggleFilter(): void { root.toggleEnabled() }
    function cycle(): void { root.cycle() }
    function preset(name: string): void { root.setPreset(name) }
  }

  // ---- the bar button ----
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰍹"
    opacity: root.enabled ? 1.0 : 0.55
    tooltipText: root.enabled ? "CRT filter: " + Model.presetLabel(root.preset) : "CRT filter off"
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleEnabled()
      else if (b === Qt.MiddleButton) root.cycle()
      else root.toggle()
    }
  }

  // ---- the panel ----
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === " ") root.toggleEnabled()
        else if (t === "n") root.cycle()
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // header: title, mode line, on/off switch
        Item {
          width: parent.width
          implicitHeight: Math.max(headerLabels.implicitHeight, headerSwitch.implicitHeight)
          Column {
            id: headerLabels
            anchors.left: parent.left
            anchors.right: headerSwitch.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)
            Text {
              text: "CRT filter"
              color: root.fg
              font.family: root.ff
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Text {
              textFormat: Text.PlainText
              text: (root.enabled ? Model.presetLabel(root.preset).toUpperCase() : "OFF") + "  ·  " + Model.modeLabel(root.status).toUpperCase()
              color: Qt.darker(root.fg, 1.4)
              font.family: root.ff
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.1
              elide: Text.ElideRight
              width: parent.width
            }
          }
          ToggleSwitch {
            id: headerSwitch
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            checked: root.enabled
            busy: root.busy
            foreground: root.fg
            onToggled: root.toggleEnabled()
          }
        }

        PanelSeparator { foreground: root.fg }

        // presets
        Column {
          width: parent.width
          spacing: Style.space(8)
          PanelSectionHeader { text: "PRESET"; foreground: root.fg; fontFamily: root.ff }
          // 2x2, not 1x4: a single row of four cells is too narrow for "Scanlines"/"Television"
          // and the labels overflow their buttons. Two columns give each label room.
          Grid {
            id: presetGrid
            width: parent.width
            columns: 2
            columnSpacing: Style.space(6)
            rowSpacing: Style.space(6)
            readonly property real cellWidth: (width - columnSpacing * (columns - 1)) / columns
            Repeater {
              model: Model.PRESETS
              Button {
                required property var modelData
                width: presetGrid.cellWidth
                iconText: modelData.icon
                iconSize: Style.font.title
                text: modelData.label
                fontSize: Style.font.bodySmall
                foreground: root.fg
                fontFamily: root.ff
                bordered: true
                active: root.enabled && root.preset === modelData.value
                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                onClicked: root.setPreset(modelData.value)
              }
            }
          }
        }

        // try before you buy: ten seconds of a preset, then back to how it was
        Column {
          visible: !root.enabled
          width: parent.width
          spacing: Style.space(4)
          Button {
            text: "Try it for 10 s"
            iconText: "󰐊"
            bordered: true
            foreground: root.fg
            fontFamily: root.ff
            onClicked: root.demo(root.preset === "custom" ? "monitor" : root.preset)
          }
          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: "Shows " + Model.presetLabel(root.preset === "custom" ? "monitor" : root.preset).toLowerCase() + ", then puts everything back."
            color: Qt.darker(root.fg, 1.4)
            font.family: root.ff
            font.pixelSize: Style.font.caption
          }
        }

        PanelSeparator { foreground: root.fg }

        // the six knobs
        Column {
          width: parent.width
          spacing: Style.space(8)
          PanelSectionHeader {
            text: "LOOK" + (root.preset === "custom" ? "  ·  CUSTOM" : "")
            foreground: root.fg
            fontFamily: root.ff
          }
          KnobRow { label: "Scanlines"; knob: "lines"; maxValue: 4 }
          KnobRow { label: "Sharpness"; knob: "sharp"; maxValue: 4 }
          KnobRow { label: "Glow"; knob: "glow"; maxValue: 4 }
          KnobRow { label: "Gamma"; knob: "gamma"; maxValue: 4; valueLabel: function(v) { return Model.gammaLabel(v) } }
          Dropdown {
            width: parent.width
            label: "Mask"
            options: Model.MASK_OPTIONS
            value: String(Model.knob(root.status, "mask", 1))
            foreground: root.fg
            fontFamily: root.ff
            onChanged: function(v) { root.setKnob("mask", v) }
          }
          Toggle {
            width: parent.width
            label: "Curved glass"
            description: "Warp, vignette and rounded corners"
            checked: Model.knob(root.status, "curve", 0) === 1
            foreground: root.fg
            fontFamily: root.ff
            onClicked: root.setKnob("curve", checked ? 0 : 1)
          }
        }

        PanelSeparator { foreground: root.fg }

        // where and how it applies
        Column {
          width: parent.width
          spacing: Style.space(8)
          PanelSectionHeader { text: "DESKTOP"; foreground: root.fg; fontFamily: root.ff }
          Text {
            visible: !root.pluginMode
            textFormat: Text.PlainText
            text: "Lite mode filters the whole screen; scopes need the full-mode plugin."
            color: Qt.darker(root.fg, 1.4)
            font.family: root.ff
            font.pixelSize: Style.font.caption
            width: parent.width
            wrapMode: Text.WordWrap
          }
          // lite mode has no scope (its status carries none): the row is hidden rather than showing a made-up value
          Dropdown {
            visible: root.pluginMode && root.status.scope !== undefined
            width: parent.width
            label: "Apply to"
            options: Model.SCOPE_OPTIONS
            value: String(root.status.scope)
            foreground: root.fg
            fontFamily: root.ff
            onChanged: function(v) { root.setKnob("scope", v) }
          }
          Dropdown {
            width: parent.width
            label: "Line pitch"
            options: Model.PITCH_OPTIONS
            value: String(Model.knob(root.status, "pitch", 0))
            foreground: root.fg
            fontFamily: root.ff
            onChanged: function(v) { root.setKnob("pitch", v) }
          }
          // auto pitch for a fullscreen window that is not an integer-scaled game (video, a browser):
          // fewer virtual lines is more tube, more virtual lines keeps small UI text readable
          Dropdown {
            visible: root.pluginMode && Model.knob(root.status, "pitch", 0) === 0
            width: parent.width
            label: "Fullscreen video pitch"
            options: Model.PITCH_FS_OPTIONS
            value: String(Model.knob(root.status, "pitch_fullscreen", 3))
            foreground: root.fg
            fontFamily: root.ff
            onChanged: function(v) { root.setKnob("pitch_fullscreen", v) }
          }
          Toggle {
            visible: root.pluginMode && root.status.low_power !== undefined
            width: parent.width
            label: "Low power"
            description: "Half-resolution glow and a short afterglow, for laptops on battery"
            checked: root.status.low_power === true
            foreground: root.fg
            fontFamily: root.ff
            onClicked: root.setPower(!checked)
          }
        }

        PanelSeparator { foreground: root.fg }

        // mode and the build
        Column {
          width: parent.width
          spacing: Style.space(6)
          Text {
            textFormat: Text.PlainText
            text: Model.modeLabel(root.status)
            color: Qt.darker(root.fg, 1.3)
            font.family: root.ff
            font.pixelSize: Style.font.bodySmall
            width: parent.width
            wrapMode: Text.WordWrap
          }
          Text {
            visible: text !== ""
            textFormat: Text.PlainText
            text: Model.gpuText(root.status)
            color: Qt.darker(root.fg, 1.4)
            font.family: root.ff
            font.pixelSize: Style.font.caption
            width: parent.width
            wrapMode: Text.WordWrap
          }
          Text {
            visible: Model.disabledReason(root.status) !== ""
            textFormat: Text.PlainText
            text: Model.disabledReason(root.status)
            color: root.fg
            font.family: root.ff
            font.pixelSize: Style.font.caption
            width: parent.width
            wrapMode: Text.WordWrap
          }
          Button {
            visible: Model.disabledReason(root.status) !== ""
            text: "Allow the plugin again"
            iconText: "󰑓"
            bordered: true
            foreground: root.fg
            fontFamily: root.ff
            onClicked: root.enablePlugin()
          }
          Text {
            visible: !root.pluginMode && Model.disabledReason(root.status) === ""
            textFormat: Text.PlainText
            text: root.pluginBuilt
              ? "The full-mode plugin is built. It loads when Hyprland restarts, or now with: hyprcrt plugin load"
              : "Lite mode is a single screen-shader pass: no afterglow, whole screen, no per-window scope. Building the plugin (about a minute, needs base-devel) adds those; it loads on the next Hyprland start."
            color: Qt.darker(root.fg, 1.4)
            font.family: root.ff
            font.pixelSize: Style.font.caption
            width: parent.width
            wrapMode: Text.WordWrap
          }
          Button {
            visible: !root.pluginMode
            text: root.building ? "Building…" : (root.pluginBuilt ? "Rebuild plugin" : "Build the full-mode plugin")
            iconText: root.building ? "󰑮" : "󱁤"
            iconSpinning: root.building
            bordered: true
            foreground: root.fg
            fontFamily: root.ff
            onClicked: root.build()
          }
          Text {
            visible: root.buildOutput.trim() !== ""
            textFormat: Text.PlainText
            text: root.buildOutput.trim().split("\n").slice(-4).join("\n")
            color: Qt.darker(root.fg, 1.4)
            font.family: root.ff
            font.pixelSize: Style.font.caption
            width: parent.width
            wrapMode: Text.WrapAnywhere
          }
        }
      }
    }
  }

  // label + integer slider with tick marks, value shown at the right
  component KnobRow: Item {
    id: row
    property string label: ""
    property string knob: ""
    property int maxValue: 4
    property var valueLabel: null
    readonly property int current: Model.knob(root.status, knob, 0)
    width: parent.width
    implicitHeight: Math.max(slider.implicitHeight, rowLabel.implicitHeight)
    Text {
      id: rowLabel
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(88)
      text: row.label
      color: root.fg
      font.family: root.ff
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }
    PanelSlider {
      id: slider
      bar: root.bar
      anchors.left: rowLabel.right
      anchors.leftMargin: Style.space(10)
      anchors.right: rowValue.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      minimum: 0
      maximum: row.maxValue
      integer: true
      tickCount: row.maxValue + 1
      value: row.current
      onReleased: function(v) {
        var iv = Math.round(v)
        if (iv !== row.current) root.setKnob(row.knob, iv)
      }
    }
    Text {
      id: rowValue
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(30)
      horizontalAlignment: Text.AlignRight
      text: row.valueLabel ? row.valueLabel(Math.round(slider.liveValue)) : String(Math.round(slider.liveValue))
      color: Qt.darker(root.fg, 1.3)
      font.family: root.ff
      font.pixelSize: Style.font.bodySmall
    }
  }
}
