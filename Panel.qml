import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Services.Pipewire
import qs.Ui
import qs.Commons
import "Model.js" as Model

// External monitor controls over DDC/CI: brightness, contrast, speaker volume,
// input, picture mode, color preset and power, one section per monitor. Every
// control appears only if that monitor advertises its VCP code.
//
// All ddcutil calls go through one queue and run one at a time, because a
// monitor answers DDC/CI slowly (a read or a write takes about half a second)
// and two calls on the same i2c bus at once can corrupt each other.
Panel {
  id: root
  moduleName: "bunin.ddc"
  ipcTarget: "bunin.ddc"

  property var monitors: []
  // Keyed by i2c bus. Kept apart from `monitors` so that a value changing
  // does not rebuild the sections under a slider being dragged.
  property var caps: ({})
  property var values: ({})

  property var queue: []
  property var currentJob: null
  property bool awaitingOutput: false

  property var powerTarget: null
  readonly property bool confirmOpen: powerTarget !== null

  // Carry sub-notch touchpad deltas between wheel events.
  property real wheelAccumulator: 0

  readonly property string focusedConnector: Hyprland.focusedMonitor ? String(Hyprland.focusedMonitor.name) : ""
  readonly property var focusedMonitor: {
    for (var i = 0; i < monitors.length; i++)
      if (monitors[i].connector === focusedConnector) return monitors[i]
    return monitors.length > 0 ? monitors[0] : null
  }

  visible: monitors.length > 0
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: push({ kind: "detect" })
  onOpenedChanged: {
    if (opened) refresh()
    else powerTarget = null
  }

  // A monitor plugged in or out shows up as a screen change. The debounce
  // waits for the link to settle before asking which monitors answer DDC/CI.
  Connections {
    target: Quickshell
    function onScreensChanged() { detectDebounce.restart() }
  }

  Timer {
    id: detectDebounce
    interval: 2000
    onTriggered: root.push({ kind: "detect" })
  }

  function push(job) {
    root.queue = Model.enqueue(root.queue, job)
    pump()
  }

  function pump() {
    if (runner.running || root.awaitingOutput || root.queue.length === 0) return
    root.currentJob = root.queue[0]
    root.queue = root.queue.slice(1)
    root.awaitingOutput = true
    runner.command = Model.command(root.currentJob)
    runner.running = true
  }

  function finish(text) {
    var job = root.currentJob
    root.currentJob = null
    root.awaitingOutput = false
    if (job) {
      if (job.kind === "detect") applyDetect(text)
      else if (job.kind === "caps") applyCaps(job.bus, Model.parseCapabilities(text))
      else if (job.kind === "read") applyValues(job.bus, Model.parseValues(text))
    }
    pump()
  }

  // A monitor without capabilities yet (the first query failed) gets another
  // try, and its read follows from applyCaps.
  function refresh() {
    for (var i = 0; i < monitors.length; i++) {
      var bus = monitors[i].bus
      push(caps[bus] === undefined ? { kind: "caps", bus: bus } : readJob(bus))
    }
  }

  // A monitor whose capabilities string came back empty or garbled still
  // gets a read of the common levels, and shows whatever answers.
  function readJob(bus) {
    var advertised = caps[bus] || {}
    var codes = Model.READ_CODES.filter(function(c) { return advertised[c] !== undefined })
    if (codes.length === 0) codes = [Model.BRIGHTNESS, Model.CONTRAST, Model.VOLUME]
    return { kind: "read", bus: bus, codes: codes }
  }

  function applyDetect(text) {
    var list = Model.parseDetect(text)
    if (JSON.stringify(list) !== JSON.stringify(root.monitors)) root.monitors = list
    for (var i = 0; i < list.length; i++) {
      if (caps[list[i].bus] === undefined) push({ kind: "caps", bus: list[i].bus })
      else push(readJob(list[i].bus))
    }
  }

  // An empty answer is not cached: a monitor waking from standby or busy with
  // another DDC/CI client can fail one query and answer the next.
  function applyCaps(bus, parsed) {
    if (Object.keys(parsed).length > 0) {
      var next = Object.assign({}, root.caps)
      next[bus] = parsed
      root.caps = next
    }
    push(readJob(bus))
  }

  // A write still queued for a control is newer than what the monitor just
  // reported, so the read must not move that control back.
  function applyValues(bus, parsed) {
    var merged = Object.assign({}, root.values[bus] || {})
    for (var code in parsed)
      if (!Model.hasPendingWrite(root.queue, bus, code)) merged[code] = parsed[code]
    var next = Object.assign({}, root.values)
    next[bus] = merged
    root.values = next
  }

  function setValue(bus, code, entry) {
    var merged = Object.assign({}, root.values[bus] || {})
    merged[code] = entry
    var next = Object.assign({}, root.values)
    next[bus] = merged
    root.values = next
  }

  function supports(bus, code) {
    var c = caps[bus]
    var v = values[bus]
    return (c !== undefined && c[code] !== undefined) || (v !== undefined && v[code] !== undefined)
  }

  function levelPercent(bus, code) {
    return Model.percentOf((values[bus] || {})[code])
  }

  function choiceValue(bus, code) {
    var entry = (values[bus] || {})[code]
    return entry && entry.value !== undefined ? entry.value : ""
  }

  function setLevel(bus, code, percent) {
    var level = (values[bus] || {})[code]
    if (!level || !(level.max > 0)) return
    var raw = Model.rawFromPercent(percent, level.max)
    setValue(bus, code, { current: raw, max: level.max })
    push({ kind: "write", bus: bus, code: code, value: String(raw) })
  }

  function setChoice(bus, code, value) {
    setValue(bus, code, { value: value })
    push({ kind: "write", bus: bus, code: code, value: value })
  }

  function stepBrightness(steps) {
    var m = root.focusedMonitor
    if (!m) return
    var percent = levelPercent(m.bus, Model.BRIGHTNESS)
    if (percent < 0) return
    var next = Model.clampPercent(percent + steps * 5)
    setLevel(m.bus, Model.BRIGHTNESS, next)
    // The plugin API only summons the plugin's own panels, so the OSD goes
    // through the same command Omarchy's brightness keys use.
    Quickshell.execDetached(["omarchy-osd", "-i", "brightness", "-p", String(next)])
  }

  function confirmPowerOff() {
    var m = root.powerTarget
    root.powerTarget = null
    if (!m) return
    var value = Model.powerOffValue((caps[m.bus] || {})[Model.POWER])
    if (value === "") return
    root.close()
    push({ kind: "write", bus: m.bus, code: Model.POWER, value: value })
  }

  Process {
    id: runner
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.finish(String(text || ""))
    }
    // Exit and the end of stdout arrive in no fixed order. If ddcutil could
    // not start at all, stdout never ends, so the job is closed out here.
    onRunningChanged: if (!running) exitSettle.restart()
  }

  Timer {
    id: exitSettle
    interval: 250
    onTriggered: if (root.awaitingOutput && !runner.running) root.finish("")
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Not the plain monitor glyph: Omarchy's own Display widget already uses it.
    text: "󰨇"
    onPressed: function(b) { root.toggle() }
    onWheelMoved: function(delta) {
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps !== 0) root.stepBrightness(wheel.steps)
    }
  }

  component LevelRow: Column {
    id: levelRow
    required property var panel
    required property string bus
    required property string code
    required property string title
    readonly property int percent: panel.levelPercent(bus, code)

    visible: panel.supports(bus, code)
    width: parent ? parent.width : 0
    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(levelHeader.implicitHeight, levelPercent.implicitHeight)

      PanelSectionHeader {
        id: levelHeader
        text: levelRow.title
        foreground: levelRow.panel.bar.foreground
        fontFamily: levelRow.panel.bar.fontFamily
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: levelPercent
        textFormat: Text.PlainText
        text: levelRow.percent < 0 ? "–" : Math.round(levelSlider.dragging ? levelSlider.liveValue : levelRow.percent) + "%"
        color: Qt.darker(levelRow.panel.bar.foreground, 1.4)
        font.family: levelRow.panel.bar.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        anchors.right: parent.right
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    PanelSlider {
      id: levelSlider
      bar: levelRow.panel.bar
      width: parent.width - Style.space(12)
      x: Style.space(6)
      minimum: 0
      maximum: 100
      step: 5
      integer: true
      value: Math.max(0, levelRow.percent)
      enabled: levelRow.percent >= 0
      opacity: enabled ? 1.0 : 0.5
      onMoved: function(v) { levelRow.panel.setLevel(levelRow.bus, levelRow.code, v) }
    }
  }

  component ChoiceRow: Column {
    id: choiceRow
    required property var panel
    required property string bus
    required property string code
    required property string title
    readonly property var choices: Model.options(code, (panel.caps[bus] || {})[code])

    visible: choices.length > 1
    width: parent ? parent.width : 0
    spacing: Style.space(6)

    PanelSectionHeader {
      text: choiceRow.title
      foreground: choiceRow.panel.bar.foreground
      fontFamily: choiceRow.panel.bar.fontFamily
    }

    ButtonGroup {
      options: choiceRow.choices
      value: choiceRow.panel.choiceValue(choiceRow.bus, choiceRow.code)
      focusable: false
      foreground: choiceRow.panel.bar.foreground
      background: choiceRow.panel.bar.background
      fontFamily: choiceRow.panel.bar.fontFamily
      fontSize: Style.font.caption
      onChanged: function(v) { choiceRow.panel.setChoice(choiceRow.bus, choiceRow.code, v) }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // h/l step the focused monitor's brightness, as the wheel on the icon does.
      onMoveRequested: function(dx, dy) {
        if (root.confirmOpen) {
          if (dx !== 0) powerConfirm.selectedIndex = powerConfirm.selectedIndex === 0 ? 1 : 0
          return
        }
        if (dx !== 0) root.stepBrightness(dx)
      }
      onActivateRequested: {
        if (!root.confirmOpen) return
        if (powerConfirm.selectedIndex === 1) root.confirmPowerOff()
        else root.powerTarget = null
      }
      onCloseRequested: {
        if (root.confirmOpen) root.powerTarget = null
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          Repeater {
            model: root.monitors

            Column {
              id: section
              required property var modelData
              required property int index
              readonly property string bus: modelData.bus
              readonly property bool isAudioOutput: Model.isMonitorSink(Pipewire.defaultAudioSink, modelData.model)
              readonly property bool loaded: root.values[bus] !== undefined
              readonly property bool canPowerOff: Model.powerOffValue((root.caps[bus] || {})[Model.POWER]) !== ""

              width: panelColumn.width
              spacing: Style.space(14)

              PanelSeparator {
                visible: section.index > 0
                foreground: root.bar.foreground
              }

              // ---------- Hero: monitor icon · model/connector · power ----------
              Item {
                width: parent.width
                implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

                Text {
                  id: heroIcon
                  textFormat: Text.PlainText
                  text: "󰍹"
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.display
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                }

                PanelActionButton {
                  id: powerButton
                  visible: section.canPowerOff
                  iconText: "󰐥"
                  tooltipText: "Turn monitor off"
                  foreground: root.bar.foreground
                  hoverColor: root.bar.urgent
                  fontFamily: root.bar.fontFamily
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  onClicked: root.powerTarget = section.modelData
                }

                Column {
                  id: heroLabels
                  anchors.left: heroIcon.right
                  anchors.leftMargin: Style.space(14)
                  anchors.right: powerButton.visible ? powerButton.left : parent.right
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)

                  Text {
                    textFormat: Text.PlainText
                    text: section.modelData.model || "Monitor"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.title
                    font.bold: true
                    elide: Text.ElideRight
                    width: parent.width
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: (section.modelData.connector || ("i2c-" + section.bus))
                      + (section.isAudioOutput ? " · audio output" : "")
                      + (section.loaded ? "" : " · reading…")
                    color: Qt.darker(root.bar.foreground, 1.4)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    font.letterSpacing: 1.2
                    font.capitalization: Font.AllUppercase
                    elide: Text.ElideRight
                    width: parent.width
                  }
                }
              }

              LevelRow { panel: root; bus: section.bus; code: Model.BRIGHTNESS; title: "BRIGHTNESS" }
              LevelRow { panel: root; bus: section.bus; code: Model.CONTRAST; title: "CONTRAST" }
              LevelRow { panel: root; bus: section.bus; code: Model.VOLUME; title: "SPEAKERS" }
              ChoiceRow { panel: root; bus: section.bus; code: Model.INPUT; title: "INPUT" }
              ChoiceRow { panel: root; bus: section.bus; code: Model.PICTURE_MODE; title: "PICTURE MODE" }
              ChoiceRow { panel: root; bus: section.bus; code: Model.COLOR_PRESET; title: "COLOR PRESET" }
            }
          }
        }
      }

      ConfirmDialog {
        id: powerConfirm
        anchors.fill: parent
        z: 10
        opened: root.confirmOpen
        message: "Turn " + ((root.powerTarget && root.powerTarget.model) || "the monitor")
          + " off? Only its own power button turns it back on."
        confirmText: "Turn off"
        background: root.bar.background
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
        onCanceled: root.powerTarget = null
        onConfirmed: root.confirmPowerOff()
      }
    }
  }
}
