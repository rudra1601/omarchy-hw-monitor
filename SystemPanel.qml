import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// First-class Omarchy system popup panel displaying visual telemetry for CPU,
// GPU, Memory, and live CPU load history, with an interactive settings drawer.
KeyboardPanel {
  id: root

  required property QtObject hw
  property bool fahrenheit: false
  property int warnPercent: 70
  property int criticalPercent: 90
  property int warnTempC: 75
  property int criticalTempC: 90
  property int diskWarnPercent: 80
  property int diskCriticalPercent: 95

  property string mode: "icons"
  property bool showGpu: true
  property bool showCpu: true
  property bool showCpuTemp: true
  property bool showGpuTemp: false
  property bool showRam: true
  property bool showTopProcs: true
  property bool showDisks: true
  property var barOrder: Model.BAR_ITEMS
  property var sectionOrder: Model.PANEL_SECTIONS
  property var sectionsHidden: []
  property var sectionsCollapsed: []
  property var dialOrder: Model.PANEL_DIALS
  property var dialsHidden: []
  property var diskHideMounts: Model.DISK_HIDE_DEFAULT
  property bool showClocks: false
  property bool showGauges: false
  property string ramFormat: "used/total"
  property string tempFormat: "degree-unit"
  property bool settingsOpen: false

  signal fahrenheitToggled()

  function persistSetting(key, value) {
    if (root.owner && typeof root.owner.persistSetting === "function") {
      root.owner.persistSetting(key, value)
    }
  }

  function persistSettings(changes) {
    if (root.owner && typeof root.owner.persistSettings === "function") {
      root.owner.persistSettings(changes)
    }
  }

  // ------------------------------------------------------------ ordering
  //
  // Bar items, dials and panel sections are each reordered and shown/hidden
  // from the settings drawer. Model.normalizeOrder has already filled in any
  // key the stored list leaves out.

  readonly property var barLabels: ({ "gpu": "GPU", "cpu": "CPU", "cpu-temp": "CPU temp", "gpu-temp": "GPU temp", "ram": "RAM" })
  readonly property var dialLabels: ({ "cpu": "CPU", "ram": "RAM", "gpu": "GPU" })
  readonly property var sectionLabels: ({
    "dials": "Dials", "history": "CPU history", "processor": "Processor", "memory": "Memory & Swap",
    "storage": "Storage", "procs": "Top processes", "gpu": "Graphics"
  })

  // Bar items keep their original per-item switches as the visibility store.
  readonly property var barShowKeys: ({ "gpu": "showGpu", "cpu": "showCpu", "cpu-temp": "showCpuTemp", "gpu-temp": "showGpuTemp", "ram": "showRam" })

  function barItemShown(key) {
    if (key === "gpu") return showGpu
    if (key === "cpu") return showCpu
    if (key === "cpu-temp") return showCpuTemp
    if (key === "gpu-temp") return showGpuTemp
    if (key === "ram") return showRam
    return false
  }

  function toggleBarItem(key) {
    if (barShowKeys[key]) persistSetting(barShowKeys[key], !barItemShown(key))
  }

  function moveBarItem(key, delta) {
    persistSetting("itemsOrder", Model.moveKey(barOrder, key, delta))
  }

  readonly property var visibleDials: dialOrder.filter(function(k) { return dialsHidden.indexOf(k) === -1 })

  function toggleDial(key) {
    persistSetting("panelDialsHidden", Model.setHidden(dialsHidden, key, dialsHidden.indexOf(key) === -1))
  }

  function moveDial(key, delta) {
    persistSetting("panelDials", Model.moveKey(dialOrder, key, delta))
  }

  // What the user asked for, before what this machine can show.
  function sectionWanted(key) {
    if (sectionsHidden.indexOf(key) !== -1) return false
    if (key === "procs") return showTopProcs
    if (key === "storage") return showDisks
    return true
  }

  function sectionShown(key) {
    if (!sectionWanted(key)) return false
    if (key === "gpu") return hw.hasGpu
    if (key === "dials") return visibleDials.length > 0
    return true
  }

  function toggleSection(key) {
    var wanted = sectionWanted(key)
    var changes = { panelSectionsHidden: Model.setHidden(sectionsHidden, key, wanted) }
    // The older per-section switches would otherwise keep it hidden.
    if (!wanted && key === "procs" && !showTopProcs) changes.showTopProcs = true
    if (!wanted && key === "storage" && !showDisks) changes.showDisks = true
    persistSettings(changes)
  }

  // A click on a card's header folds it down to the header; remembered in
  // panelSectionsCollapsed. Folded cards skip their helper sampling.
  function sectionCollapsed(key) {
    return sectionsCollapsed.indexOf(key) !== -1
  }

  function toggleCollapsed(key) {
    var collapse = !sectionCollapsed(key)
    persistSetting("panelSectionsCollapsed", Model.setHidden(sectionsCollapsed, key, collapse))
    if (!collapse) Qt.callLater(function() { root.refreshWorkers(true) })
  }

  function moveSection(key, delta) {
    persistSetting("panelSections", Model.moveKey(sectionOrder, key, delta))
  }

  // Helpers sample only for sections that are on screen.
  function refreshWorkers(force) {
    if (sectionShown("memory") && !sectionCollapsed("memory")) hw.sampleZram()
    if (sectionShown("procs") && !sectionCollapsed("procs")) hw.refreshProcTop()
    if (sectionShown("storage") && !sectionCollapsed("storage")) hw.refreshDisks(force)
  }

  function dialData(key) {
    if (key === "ram") return {
      title: "RAM",
      valueText: hw.memPercent >= 0 ? Math.round(hw.memPercent) + "%" : "–",
      subText: hw.memory ? (Model.formatGib(Model.gibFromKib(hw.memory.usedKib)) + "/" + Model.formatGib(Model.gibFromKib(hw.memory.totalKib)) + "G") : "",
      subTextColor: root.dimColor,
      ratio: hw.memPercent >= 0 ? hw.memPercent / 100 : 0,
      severity: Model.severity(hw.memPercent, root.warnPercent, root.criticalPercent)
    }
    if (key === "gpu") return {
      title: "GPU",
      valueText: hw.hasGpu ? (hw.gpuPercent >= 0 ? Math.round(hw.gpuPercent) + "%" : (hw.gpuVramPercent >= 0 ? Math.round(hw.gpuVramPercent) + "%" : "–")) : "N/A",
      subText: hw.hasGpu && hw.gpuTempC > 0 ? Model.formatTemp(hw.gpuTempC, root.fahrenheit) : (hw.hasGpu && hw.gpuWatts >= 0 ? Model.formatWatts(hw.gpuWatts) : ""),
      subTextColor: root.tempColor(hw.gpuTempC),
      ratio: hw.hasGpu ? (hw.gpuPercent >= 0 ? hw.gpuPercent / 100 : (hw.gpuVramPercent >= 0 ? hw.gpuVramPercent / 100 : 0)) : 0,
      severity: hw.hasGpu ? Model.severity(hw.gpuPercent >= 0 ? hw.gpuPercent : hw.gpuVramPercent, root.warnPercent, root.criticalPercent) : 0
    }
    return {
      title: "CPU",
      valueText: hw.cpuPercent >= 0 ? Math.round(hw.cpuPercent) + "%" : "–",
      subText: hw.cpuTempC > 0 ? Model.formatTemp(hw.cpuTempC, root.fahrenheit) : "",
      subTextColor: root.tempColor(hw.cpuTempC),
      ratio: hw.cpuPercent >= 0 ? hw.cpuPercent / 100 : 0,
      severity: Model.severity(hw.cpuPercent, root.warnPercent, root.criticalPercent)
    }
  }

  function toggleFahrenheit() {
    if (root.owner && typeof root.owner.toggleFahrenheit === "function") {
      root.owner.toggleFahrenheit()
    } else {
      root.fahrenheit = !root.fahrenheit
    }
  }

  readonly property color baseColor: root.bar ? root.bar.foreground : Color.foreground
  readonly property color hotColor: root.bar ? root.bar.urgent : Color.urgent
  readonly property color dimColor: Qt.darker(baseColor, 1.45)
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  function warm(from, amount) {
    if (!(amount > 0)) return from
    var t = Math.min(1, amount)
    return Qt.rgba(from.r + (hotColor.r - from.r) * t,
                   from.g + (hotColor.g - from.g) * t,
                   from.b + (hotColor.b - from.b) * t,
                   from.a)
  }

  // Gradiente della sezione Top processi: base verso l'accent del tema
  // (blu chiaro), mai verso urgent — la severità resta leggibile senza urlare.
  function accentMix(amount) {
    if (!(amount > 0)) return baseColor
    var t = Math.min(1, amount)
    return Qt.rgba(baseColor.r + (Color.accent.r - baseColor.r) * t,
                   baseColor.g + (Color.accent.g - baseColor.g) * t,
                   baseColor.b + (Color.accent.b - baseColor.b) * t,
                   baseColor.a)
  }

  function tempColor(tempC) {
    if (!isFinite(tempC) || tempC <= 0) return dimColor
    if (tempC < 50) return dimColor
    var t = Math.min(1, Math.max(0, (tempC - 50) / Math.max(1, criticalTempC - 50)))
    return Qt.rgba(baseColor.r + (hotColor.r - baseColor.r) * t,
                   baseColor.g + (hotColor.g - baseColor.g) * t,
                   baseColor.b + (hotColor.b - baseColor.b) * t,
                   baseColor.a)
  }

  // Ring buffer for the last 60 seconds of CPU samples.
  // Sampled while the panel is open; cleared when closed to avoid background overhead.
  property var cpuHistory: []

  readonly property var sparklinePoints: {
    var list = []
    var n = cpuHistory ? cpuHistory.length : 0
    if (n < 2) return list
    var w = sparklineBox.width - Style.space(8)
    var h = sparklineBox.height - Style.space(8)
    for (var i = 0; i < n; i++) {
      var px = Style.space(4) + (i / (n - 1)) * w
      var v = Math.max(0, Math.min(100, Number(cpuHistory[i]) || 0))
      var py = Style.space(4) + h - (v / 100) * h
      list.push(Qt.point(px, py))
    }
    return list
  }

  readonly property point sparklineFirst: sparklinePoints.length > 0 ? sparklinePoints[0] : Qt.point(0, sparklineBox.height)

  readonly property var sparklineFillPoints: {
    if (sparklinePoints.length < 2) return []
    var list = sparklinePoints.slice()
    var w = sparklineBox.width - Style.space(4)
    var h = sparklineBox.height - Style.space(4)
    list.push(Qt.point(w, h))
    list.push(Qt.point(Style.space(4), h))
    return list
  }

  onOpenChanged: {
    if (open) {
      hw.sample()
      hw.procPanelOpen = true
      root.refreshWorkers(true)
      var initial = hw.cpuPercent >= 0 ? hw.cpuPercent : 0
      root.cpuHistory = [initial, initial]
    } else {
      root.cpuHistory = []
      root.settingsOpen = false
      hw.procPanelOpen = false
    }
  }

  focusTarget: keyCatcher
  contentWidth: fittedContentWidth(Style.space(500))
  contentHeight: fittedContentHeight(panelColumn.implicitHeight + Style.space(16), Style.space(1100))

  PanelKeyCatcher {
    id: keyCatcher
    anchors.fill: parent
    onCloseRequested: root.close()
    // root.owner is the Panel widget root (Widget.qml sets owner: root),
    // which is what Bar.switchPanelFrom expects.
    onTabRequested: function(direction) {
      if (root.owner && typeof root.owner.switchPanel === "function") {
        root.owner.switchPanel(direction)
      }
    }
    onTextKey: function(t) {
      if (t === "r" || t === "R") {
        hw.sample()
        root.refreshWorkers(true)
      } else if (t === "c" || t === "C" || t === "f" || t === "F") {
        root.toggleFahrenheit()
      } else if (t === "s" || t === "S") {
        root.settingsOpen = !root.settingsOpen
      }
    }

    Timer {
      id: historyTimer
      interval: 1000
      repeat: true
      running: root.open
      onTriggered: {
        hw.sample()
        root.refreshWorkers(false)
        var cur = hw.cpuPercent >= 0 ? hw.cpuPercent : 0
        var arr = root.cpuHistory.slice()
        arr.push(cur)
        if (arr.length > 60) arr.shift()
        root.cpuHistory = arr
      }
    }

    Component.onDestruction: historyTimer.stop()

    Controls.ScrollView {
      id: scrollArea
      anchors.fill: parent
      clip: true
      Controls.ScrollBar.horizontal.policy: Controls.ScrollBar.AlwaysOff
      Controls.ScrollBar.vertical.policy: panelColumn.implicitHeight > scrollArea.height ? Controls.ScrollBar.AsNeeded : Controls.ScrollBar.AlwaysOff

      Binding {
        target: scrollArea.contentItem
        property: "interactive"
        value: panelColumn.implicitHeight > scrollArea.height
      }

      Column {
        id: panelColumn
        width: scrollArea.availableWidth
        spacing: Style.space(12)

        // 1. Header with Processor Name and Settings Gear
        Item {
          width: parent.width
          implicitHeight: Math.max(headerLeft.implicitHeight, settingsButton.implicitHeight)

          Row {
            id: headerLeft
            anchors.left: parent.left
            anchors.right: settingsButton.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(10)

            Text {
              textFormat: Text.PlainText
              text: ""
              color: Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              width: parent.width - Style.font.display - Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                width: parent.width
                wrapMode: Text.Wrap
                text: hw.cpuInfo && hw.cpuInfo.model ? hw.cpuInfo.model : "System Telemetry"
                color: root.baseColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }

              // Host · OS · uptime
              Text {
                textFormat: Text.PlainText
                width: parent.width
                wrapMode: Text.Wrap
                visible: text !== ""
                text: [hw.hostName, hw.osName, Model.formatUptime(hw.uptimeSec)]
                  .filter(function (part) { return part !== "" }).join("  \u00b7  ")
                color: root.dimColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }
          }

          // Gear Icon for In-Panel Settings
          ModeChip {
            id: settingsButton
            label: "\uF013"
            selected: root.settingsOpen
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            onPicked: root.settingsOpen = !root.settingsOpen
          }
        }

        // Animated Settings Drawer
        Rectangle {
          width: parent.width
          visible: root.settingsOpen || height > 0
          height: root.settingsOpen ? settingsCol.implicitHeight + Style.space(20) : 0
          clip: true
          color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.05)
          border.color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.14)
          border.width: 1
          radius: Style.cornerRadius

          Behavior on height {
            NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
          }
          opacity: root.settingsOpen ? 1 : 0
          Behavior on opacity {
            NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
          }

          Column {
            id: settingsCol
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: Style.space(10)
            spacing: Style.space(10)

            // Settings Header
            Row {
              width: parent.width
              spacing: Style.space(6)

              Text {
                textFormat: Text.PlainText
                text: ""
                color: Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                textFormat: Text.PlainText
                text: "Top Bar Display Settings"
                color: root.baseColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            // Readout Mode
            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
                width: Style.space(48)
                anchors.verticalCenter: parent.verticalCenter
                text: "Mode"
                color: Qt.darker(root.baseColor, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Flow {
                width: parent.width - Style.space(56)
                spacing: Style.space(4)

                ModeChip {
                  label: "Icons"
                  selected: root.mode === "icons"
                  onPicked: root.persistSetting("mode", "icons")
                }
                ModeChip {
                  label: "Compact"
                  selected: root.mode === "compact"
                  onPicked: root.persistSetting("mode", "compact")
                }
                ModeChip {
                  label: "Full"
                  selected: root.mode === "full"
                  onPicked: root.persistSetting("mode", "full")
                }
                ModeChip {
                  label: "Labels"
                  selected: root.mode === "labels"
                  onPicked: root.persistSetting("mode", "labels")
                }
              }
            }

            // Bar items: ‹ › moves one, the name shows or hides it
            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
                width: Style.space(48)
                topPadding: Style.space(4)
                text: "Items"
                color: Qt.darker(root.baseColor, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Flow {
                width: parent.width - Style.space(56)
                spacing: Style.space(6)

                Repeater {
                  model: root.barOrder
                  delegate: OrderPill {
                    required property string modelData
                    required property int index
                    label: root.barLabels[modelData] || modelData
                    shown: root.barItemShown(modelData)
                    first: index === 0
                    last: index === root.barOrder.length - 1
                    onToggled: root.toggleBarItem(modelData)
                    onMoved: function(delta) { root.moveBarItem(modelData, delta) }
                  }
                }
              }
            }

            // Show Components
            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
                width: Style.space(48)
                anchors.verticalCenter: parent.verticalCenter
                text: "Show"
                color: Qt.darker(root.baseColor, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Flow {
                width: parent.width - Style.space(56)
                spacing: Style.space(4)

                ModeChip {
                  label: "󰓅 Clocks"
                  selected: root.showClocks
                  onPicked: root.persistSetting("showClocks", !root.showClocks)
                }
                ModeChip {
                  label: "󰁹 Gauges"
                  selected: root.showGauges
                  onPicked: root.persistSetting("showGauges", !root.showGauges)
                }
              }
            }

            // RAM Format
            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
                width: Style.space(48)
                anchors.verticalCenter: parent.verticalCenter
                text: "RAM"
                color: Qt.darker(root.baseColor, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Flow {
                width: parent.width - Style.space(56)
                spacing: Style.space(4)

                ModeChip {
                  label: "Used/Total"
                  selected: root.ramFormat === "used/total"
                  onPicked: root.persistSetting("ramFormat", "used/total")
                }
                ModeChip {
                  label: "Used"
                  selected: root.ramFormat === "used"
                  onPicked: root.persistSetting("ramFormat", "used")
                }
                ModeChip {
                  label: "Percent"
                  selected: root.ramFormat === "percent"
                  onPicked: root.persistSetting("ramFormat", "percent")
                }
                ModeChip {
                  label: "Free"
                  selected: root.ramFormat === "free"
                  onPicked: root.persistSetting("ramFormat", "free")
                }
              }
            }

            // Temperature Unit
            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
                width: Style.space(48)
                anchors.verticalCenter: parent.verticalCenter
                text: "Unit"
                color: Qt.darker(root.baseColor, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Flow {
                width: parent.width - Style.space(56)
                spacing: Style.space(4)

                ModeChip {
                  label: "°C  Celsius"
                  selected: !root.fahrenheit
                  onPicked: root.persistSetting("fahrenheit", false)
                }
                ModeChip {
                  label: "°F  Fahrenheit"
                  selected: root.fahrenheit
                  onPicked: root.persistSetting("fahrenheit", true)
                }
              }
            }

            // Temp Format
            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
                width: Style.space(48)
                anchors.verticalCenter: parent.verticalCenter
                text: "Temp"
                color: Qt.darker(root.baseColor, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Flow {
                width: parent.width - Style.space(56)
                spacing: Style.space(4)

                ModeChip {
                  label: root.fahrenheit ? "45°F" : "45°C"
                  selected: root.tempFormat === "degree-unit"
                  onPicked: root.persistSetting("tempFormat", "degree-unit")
                }
                ModeChip {
                  label: "45°"
                  selected: root.tempFormat === "degree"
                  onPicked: root.persistSetting("tempFormat", "degree")
                }
                ModeChip {
                  label: root.fahrenheit ? "45F" : "45C"
                  selected: root.tempFormat === "unit"
                  onPicked: root.persistSetting("tempFormat", "unit")
                }
                ModeChip {
                  label: "45"
                  selected: root.tempFormat === "bare"
                  onPicked: root.persistSetting("tempFormat", "bare")
                }
              }
            }

            // Panel layout
            Row {
              width: parent.width
              spacing: Style.space(6)

              Text {
                textFormat: Text.PlainText
                text: ""
                color: Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                textFormat: Text.PlainText
                text: "Panel Layout"
                color: root.baseColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
                width: Style.space(48)
                topPadding: Style.space(4)
                text: "Dials"
                color: Qt.darker(root.baseColor, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Flow {
                width: parent.width - Style.space(56)
                spacing: Style.space(6)

                Repeater {
                  model: root.dialOrder
                  delegate: OrderPill {
                    required property string modelData
                    required property int index
                    label: root.dialLabels[modelData] || modelData
                    shown: root.dialsHidden.indexOf(modelData) === -1
                    first: index === 0
                    last: index === root.dialOrder.length - 1
                    onToggled: root.toggleDial(modelData)
                    onMoved: function(delta) { root.moveDial(modelData, delta) }
                  }
                }
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
                width: Style.space(48)
                topPadding: Style.space(4)
                text: "Sections"
                color: Qt.darker(root.baseColor, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Column {
                width: parent.width - Style.space(56)
                spacing: Style.space(4)

                Repeater {
                  model: root.sectionOrder
                  delegate: OrderRow {
                    required property string modelData
                    required property int index
                    width: parent.width
                    label: root.sectionLabels[modelData] || modelData
                    shown: root.sectionWanted(modelData)
                    note: modelData === "gpu" && !hw.hasGpu ? "no GPU found" : ""
                    first: index === 0
                    last: index === root.sectionOrder.length - 1
                    onToggled: root.toggleSection(modelData)
                    onMoved: function(delta) { root.moveSection(modelData, delta) }
                  }
                }
              }
            }
          }
        }

        // Sections 2–6, stacked in the order chosen in the settings drawer.
        // Each section takes its y from offsetOf(), so reordering is a
        // settings change rather than a re-parent, and hidden ones take no space.
        Item {
          id: sectionStack
          width: parent.width

          readonly property real gap: Style.space(12)

          function sectionItem(key) {
            switch (key) {
            case "dials": return dialsSection
            case "history": return historySection
            case "processor": return processorSection
            case "memory": return memorySection
            case "storage": return storageCard
            case "procs": return procsSection
            case "gpu": return gpuSection
            }
            return null
          }

          function offsetOf(key) {
            var y = 0
            for (var i = 0; i < root.sectionOrder.length; i++) {
              var k = root.sectionOrder[i]
              if (k === key) return y
              var item = sectionItem(k)
              if (item && root.sectionShown(k)) y += item.height + gap
            }
            return y
          }

          implicitHeight: {
            var h = 0
            var n = 0
            for (var i = 0; i < root.sectionOrder.length; i++) {
              var k = root.sectionOrder[i]
              var item = sectionItem(k)
              if (!item || !root.sectionShown(k)) continue
              h += item.height
              n++
            }
            return n > 0 ? h + gap * (n - 1) : 0
          }

          // 2. Primary Telemetry Dials, in the order and selection from the drawer
          Row {
            id: dialsSection
            y: sectionStack.offsetOf("dials")
            visible: root.sectionShown("dials")
            width: parent.width
            spacing: Style.space(8)
            Behavior on y { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

            Repeater {
              model: root.visibleDials
              delegate: Dial {
                required property string modelData
                readonly property var dialInfo: root.dialData(modelData)
                width: (dialsSection.width - dialsSection.spacing * (root.visibleDials.length - 1)) / Math.max(1, root.visibleDials.length)
                title: dialInfo.title
                valueText: dialInfo.valueText
                subText: dialInfo.subText
                subTextColor: dialInfo.subTextColor
                ratio: dialInfo.ratio
                baseColor: root.baseColor
                hotColor: root.hotColor
                accentColor: Color.accent
                severity: dialInfo.severity
                fontFamily: root.fontFamily
              }
            }
          }

          // 3. CPU Load History Sparkline (60s)
          Rectangle {
            id: historySection
            y: sectionStack.offsetOf("history")
            visible: root.sectionShown("history")
            Behavior on y { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
            width: parent.width
            implicitHeight: (root.sectionCollapsed("history") ? sparklineCol.children[0].implicitHeight : sparklineCol.implicitHeight) + Style.space(24)
            clip: true
            Behavior on implicitHeight { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
            color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.04)
            border.color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.10)
            border.width: 1
            radius: Style.cornerRadius

            // Header click folds/unfolds the card; declared first so the
            // chips in the header (drawn above it) keep their own clicks.
            MouseArea {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              height: sparklineCol.children[0].implicitHeight + Style.space(18)
              cursorShape: Qt.PointingHandCursor
              onClicked: root.toggleCollapsed("history")
            }

            Column {
              id: sparklineCol
              anchors.fill: parent
              anchors.margins: Style.space(12)
              clip: true  // a folded card shows only the header row
              spacing: Style.space(8)

              Row {
                width: parent.width

                Text {
                  textFormat: Text.PlainText
                  text: "CPU Load History (60s)"
                  color: root.baseColor
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                Item {
                  width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth)
                  height: 1
                }

                Text {
                  textFormat: Text.PlainText
                  text: hw.cpuPercent >= 0 ? (Math.round(hw.cpuPercent) + "% current") : "–"
                  color: root.warm(root.baseColor, Model.severity(hw.cpuPercent, root.warnPercent, root.criticalPercent))
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }

              Item {
                id: sparklineBox
                width: parent.width
                height: Style.space(55)

                // Background grid lines
                Rectangle {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  y: parent.height * 0.25
                  height: 1
                  color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.08)
                }
                Rectangle {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  y: parent.height * 0.50
                  height: 1
                  color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.08)
                }
                Rectangle {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  y: parent.height * 0.75
                  height: 1
                  color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.08)
                }

                // Sparkline fill area
                Shape {
                  anchors.fill: parent
                  visible: root.sparklinePoints.length >= 2
                  layer.enabled: true
                  layer.samples: 4

                  ShapePath {
                    strokeWidth: 0
                    strokeColor: "transparent"
                    fillColor: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18)

                    startX: root.sparklineFirst.x
                    startY: root.sparklineFirst.y

                    PathPolyline {
                      path: root.sparklineFillPoints
                    }
                  }
                }

                // Sparkline stroke line
                Shape {
                  anchors.fill: parent
                  visible: root.sparklinePoints.length >= 2
                  layer.enabled: true
                  layer.samples: 4

                  ShapePath {
                    strokeWidth: Style.space(2)
                    strokeColor: Color.accent
                    fillColor: "transparent"
                    capStyle: ShapePath.RoundCap
                    joinStyle: ShapePath.RoundJoin

                    startX: root.sparklineFirst.x
                    startY: root.sparklineFirst.y

                    PathPolyline {
                      path: root.sparklinePoints
                    }
                  }
                }
              }
            }
          }

          // 4. Processor Topology & Load Average
          Rectangle {
            id: processorSection
            y: sectionStack.offsetOf("processor")
            visible: root.sectionShown("processor")
            Behavior on y { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
            width: parent.width
            implicitHeight: (root.sectionCollapsed("processor") ? procCol.children[0].implicitHeight : procCol.implicitHeight) + Style.space(24)
            clip: true
            Behavior on implicitHeight { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
            color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.04)
            border.color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.10)
            border.width: 1
            radius: Style.cornerRadius

            // Header click folds/unfolds the card; declared first so the
            // chips in the header (drawn above it) keep their own clicks.
            MouseArea {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              height: procCol.children[0].implicitHeight + Style.space(18)
              cursorShape: Qt.PointingHandCursor
              onClicked: root.toggleCollapsed("processor")
            }

            Column {
              id: procCol
              anchors.fill: parent
              anchors.margins: Style.space(12)
              clip: true  // a folded card shows only the header row
              spacing: Style.space(10)

              Row {
                width: parent.width
                spacing: Style.space(6)

                Text {
                  textFormat: Text.PlainText
                  text: ""
                  color: Color.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  textFormat: Text.PlainText
                  text: "Processor"
                  color: root.baseColor
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              // Specs
              Row {
                width: parent.width
                spacing: Style.space(16)

                Column {
                  width: (parent.width - parent.spacing) / 2
                  spacing: Style.spacing.labelGap

                  InfoPair {
                    label: "Cores"
                    value: hw.cpuInfo ? (hw.cpuInfo.cores + "C / " + hw.cpuInfo.threads + "T") : "–"
                  }
                  InfoPair {
                    label: "Avg Clock"
                    value: hw.cpuMhz > 0 ? Model.formatGhz(hw.cpuMhz) : "–"
                  }
                }

                Column {
                  width: (parent.width - parent.spacing) / 2
                  spacing: Style.spacing.labelGap

                  InfoPair {
                    label: "Temperature"
                    value: hw.cpuTempC > 0 ? Model.formatTemp(hw.cpuTempC, root.fahrenheit) : "–"
                    valueColor: root.tempColor(hw.cpuTempC)
                  }
                  InfoPair {
                    label: "Cur Load"
                    value: hw.cpuPercent >= 0 ? Model.formatPercent(hw.cpuPercent) : "–"
                    valueColor: root.warm(root.baseColor, Model.severity(hw.cpuPercent, root.warnPercent, root.criticalPercent))
                  }
                }
              }

              // Load average 1m, 5m, 15m: the period in each meter's title, no heading row
              Column {
                width: parent.width
                spacing: Style.space(6)

                Row {
                  width: parent.width
                  spacing: Style.space(8)

                  readonly property real maxCores: hw.cpuInfo && hw.cpuInfo.threads ? hw.cpuInfo.threads : 8

                  LoadMeter {
                    id: lm1
                    width: (parent.width - parent.spacing * 2) / 3
                    period: "Load 1m"
                    value: hw.load ? hw.load.one : 0
                    maxVal: parent.maxCores
                    baseColor: root.baseColor
                    hotColor: root.hotColor
                    fontFamily: root.fontFamily
                  }

                  LoadMeter {
                    id: lm5
                    width: (parent.width - parent.spacing * 2) / 3
                    period: "Load 5m"
                    value: hw.load ? hw.load.five : 0
                    maxVal: parent.maxCores
                    baseColor: root.baseColor
                    hotColor: root.hotColor
                    fontFamily: root.fontFamily
                  }

                  LoadMeter {
                    id: lm15
                    width: (parent.width - parent.spacing * 2) / 3
                    period: "Load 15m"
                    value: hw.load ? hw.load.fifteen : 0
                    maxVal: parent.maxCores
                    baseColor: root.baseColor
                    hotColor: root.hotColor
                    fontFamily: root.fontFamily
                  }
                }
              }
            }
          }

          // 5. Memory & Swap Breakdown
          Rectangle {
            id: memorySection
            y: sectionStack.offsetOf("memory")
            visible: root.sectionShown("memory")
            Behavior on y { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
            width: parent.width
            implicitHeight: (root.sectionCollapsed("memory") ? memCol.children[0].implicitHeight : memCol.implicitHeight) + Style.space(24)
            clip: true
            Behavior on implicitHeight { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
            color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.04)
            border.color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.10)
            border.width: 1
            radius: Style.cornerRadius

            // Header click folds/unfolds the card; declared first so the
            // chips in the header (drawn above it) keep their own clicks.
            MouseArea {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              height: memCol.children[0].implicitHeight + Style.space(18)
              cursorShape: Qt.PointingHandCursor
              onClicked: root.toggleCollapsed("memory")
            }

            Column {
              id: memCol
              anchors.fill: parent
              anchors.margins: Style.space(12)
              clip: true  // a folded card shows only the header row
              spacing: Style.space(10)

              Row {
                width: parent.width
                spacing: Style.space(6)

                Text {
                  textFormat: Text.PlainText
                  text: ""
                  color: Color.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  textFormat: Text.PlainText
                  text: "Memory & Swap"
                  color: root.baseColor
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              // RAM horizontal split progress
              Column {
                width: parent.width
                spacing: Style.space(4)

                Row {
                  width: parent.width

                  Text {
                    textFormat: Text.PlainText
                    text: "RAM Usage"
                    color: Qt.darker(root.baseColor, 1.4)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }

                  Item {
                    width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth)
                    height: 1
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: hw.memory ? (Model.formatGib(Model.gibFromKib(hw.memory.usedKib)) + " / " + Model.formatGib(Model.gibFromKib(hw.memory.totalKib)) + " GiB (" + Math.round(hw.memPercent) + "%)") : "–"
                    color: root.warm(root.baseColor, Model.severity(hw.memPercent, root.warnPercent, root.criticalPercent))
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }

                Rectangle {
                  width: parent.width
                  height: Style.space(6)
                  radius: height / 2
                  color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.12)

                  Rectangle {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    radius: parent.radius
                    color: root.warm(root.baseColor, Model.severity(hw.memPercent, root.warnPercent, root.criticalPercent))
                    width: hw.memPercent >= 0 ? Math.max(parent.height, Math.min(parent.width, parent.width * (hw.memPercent / 100))) : 0
                    Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
                  }
                }
              }

              // Details
              Row {
                width: parent.width
                spacing: Style.space(16)

                Column {
                  width: (parent.width - parent.spacing) / 2
                  spacing: Style.spacing.labelGap

                  InfoPair {
                    label: "Available"
                    value: hw.memory ? (Model.formatGib(Model.gibFromKib(hw.memory.availableKib)) + " GiB") : "–"
                  }
                  InfoPair {
                    label: "Page Cache"
                    value: hw.memory ? (Model.formatGib(Model.gibFromKib(hw.memory.cachedKib)) + " GiB") : "–"
                  }
                }

                Column {
                  width: (parent.width - parent.spacing) / 2
                  spacing: Style.spacing.labelGap

                  InfoPair {
                    label: "Swap Used"
                    value: hw.memory && hw.memory.swapTotalKib > 0 ? (Model.formatGib(Model.gibFromKib(hw.memory.swapUsedKib)) + " GiB") : "0 GiB"
                  }
                  InfoPair {
                    label: "Swap Total"
                    value: hw.memory && hw.memory.swapTotalKib > 0 ? (Model.formatGib(Model.gibFromKib(hw.memory.swapTotalKib)) + " GiB") : "None"
                  }
                }
              }

              // RAM compression: zram swap devices, sampled while the panel is open
              Column {
                width: parent.width
                spacing: Style.space(4)
                id: zramBlock
                visible: hw.zram !== null

                readonly property real fill: hw.zram && hw.zram.sizeBytes > 0
                  ? Model.clamp(100 * hw.zram.origBytes / hw.zram.sizeBytes, 0, 100) : -1

                Row {
                  width: parent.width

                  Text {
                    textFormat: Text.PlainText
                    text: "RAM Compression"
                    color: Qt.darker(root.baseColor, 1.4)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }

                  Item {
                    width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth)
                    height: 1
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: hw.zram ? (hw.zram.label + (hw.zram.algorithm ? " \u00b7 " + hw.zram.algorithm : "")
                      + " \u00b7 " + Model.formatBytes(hw.zram.origBytes) + " / " + Model.formatBytes(hw.zram.sizeBytes)) : "–"
                    color: root.baseColor
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }

                Rectangle {
                  width: parent.width
                  height: Style.space(6)
                  radius: height / 2
                  color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.12)

                  Rectangle {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    radius: parent.radius
                    color: root.warm(root.baseColor, Model.severity(zramBlock.fill, root.warnPercent, root.criticalPercent))
                    width: zramBlock.fill > 0 ? Math.max(parent.height, Math.min(parent.width, parent.width * (zramBlock.fill / 100))) : 0
                    Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
                  }
                }
              }

              Row {
                width: parent.width
                spacing: Style.space(16)
                visible: hw.zram !== null

                Column {
                  width: (parent.width - parent.spacing) / 2
                  spacing: Style.spacing.labelGap

                  InfoPair {
                    label: "Stored"
                    value: hw.zram ? Model.formatBytes(hw.zram.origBytes) : "–"
                  }
                  InfoPair {
                    label: "Compressed"
                    value: hw.zram ? Model.formatBytes(hw.zram.comprBytes) : "–"
                  }
                }

                Column {
                  width: (parent.width - parent.spacing) / 2
                  spacing: Style.spacing.labelGap

                  InfoPair {
                    label: "RAM Used"
                    value: hw.zram ? Model.formatBytes(hw.zram.memUsedBytes) : "–"
                  }
                  InfoPair {
                    label: "Ratio"
                    value: hw.zram ? Model.formatRatio(hw.zram.origBytes, hw.zram.memUsedBytes) : "–"
                  }
                }
              }

              // zswap: compressed cache in front of disk swap, from /proc/meminfo
              Row {
                width: parent.width
                spacing: Style.space(16)
                visible: !!hw.memory && hw.memory.zswappedKib > 0

                InfoPair {
                  width: (parent.width - parent.spacing) / 2
                  label: "Zswap Stored"
                  value: hw.memory ? Model.formatBytes(hw.memory.zswappedKib * 1024) : "–"
                }
                InfoPair {
                  width: (parent.width - parent.spacing) / 2
                  label: "Zswap Ratio"
                  value: hw.memory ? Model.formatRatio(hw.memory.zswappedKib * 1024, hw.memory.zswapKib * 1024) : "–"
                }
              }
            }
          }

          // 5a. Storage: every mounted disk, removable drive and network share
          // (only while the panel is open)
          Rectangle {
            width: parent.width
            implicitHeight: (root.sectionCollapsed("storage") ? diskCol.children[0].implicitHeight : diskCol.implicitHeight) + Style.space(24)
            clip: true
            Behavior on implicitHeight { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
            color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.04)
            border.color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.10)
            border.width: 1
            radius: Style.cornerRadius
            id: storageCard
            y: sectionStack.offsetOf("storage")
            visible: root.sectionShown("storage")
            Behavior on y { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

            readonly property var diskList: Model.visibleDisks(hw.disks, root.diskHideMounts)

            // Header click folds/unfolds the card; declared first so the
            // chips in the header (drawn above it) keep their own clicks.
            MouseArea {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              height: diskCol.children[0].implicitHeight + Style.space(18)
              cursorShape: Qt.PointingHandCursor
              onClicked: root.toggleCollapsed("storage")
            }

            Column {
              id: diskCol
              anchors.fill: parent
              anchors.margins: Style.space(12)
              clip: true  // a folded card shows only the header row
              spacing: Style.space(10)

              Row {
                width: parent.width
                spacing: Style.space(6)

                Text {
                  id: diskHeadIcon
                  textFormat: Text.PlainText
                  text: "󰋊"
                  color: Color.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  id: diskHeadTitle
                  textFormat: Text.PlainText
                  text: "Storage"
                  color: root.baseColor
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  anchors.verticalCenter: parent.verticalCenter
                }

                Item {
                  width: Math.max(0, parent.width - diskHeadIcon.implicitWidth - diskHeadTitle.implicitWidth - diskHeadCount.implicitWidth - parent.spacing * 3)
                  height: 1
                }

                Text {
                  id: diskHeadCount
                  textFormat: Text.PlainText
                  text: storageCard.diskList.length > 0 ? storageCard.diskList.length + " mounted" : ""
                  color: Qt.darker(root.baseColor, 1.4)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              Repeater {
                model: storageCard.diskList
                delegate: Column {
                  required property var modelData

                  width: parent.width
                  spacing: Style.space(4)

                  readonly property color fillColor: root.warm(root.baseColor,
                    Model.severity(modelData.percent, root.diskWarnPercent, root.diskCriticalPercent))

                  Row {
                    width: parent.width
                    spacing: Style.space(6)

                    Text {
                      id: diskKind
                      textFormat: Text.PlainText
                      text: modelData.kind === "network" ? "󰒍" : (modelData.kind === "removable" ? "󰕓" : "󰋊")
                      color: Qt.darker(root.baseColor, 1.4)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                      textFormat: Text.PlainText
                      width: Math.max(40, parent.width - diskKind.implicitWidth - diskFigs.implicitWidth - parent.spacing * 2)
                      elide: Text.ElideMiddle
                      text: modelData.title
                      color: root.baseColor
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                      id: diskFigs
                      textFormat: Text.PlainText
                      text: Model.formatBytes(modelData.availBytes) + " free of " + Model.formatBytes(modelData.sizeBytes)
                      color: fillColor
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }

                  Rectangle {
                    width: parent.width
                    height: Style.space(6)
                    radius: height / 2
                    color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.12)

                    Rectangle {
                      anchors.left: parent.left
                      anchors.top: parent.top
                      anchors.bottom: parent.bottom
                      radius: parent.radius
                      color: fillColor
                      width: modelData.percent >= 0 ? Math.max(parent.height, Math.min(parent.width, parent.width * (modelData.percent / 100))) : 0
                      Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
                    }
                  }

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    elide: Text.ElideRight
                    text: {
                      var parts = [modelData.model || modelData.device, modelData.fstype]
                      if (modelData.readOnly) parts.push("read-only")
                      if (modelData.extraMounts > 0) parts.push("+" + modelData.extraMounts + (modelData.extraMounts === 1 ? " mount" : " mounts"))
                      if (modelData.percent >= 0) parts.push(Math.round(modelData.percent) + "% used")
                      return parts.join(" · ")
                    }
                    color: Qt.darker(root.baseColor, 1.4)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }

              Text {
                textFormat: Text.PlainText
                visible: hw.disksNetworkTimedOut
                width: parent.width
                wrapMode: Text.Wrap
                text: "A network share did not answer within 3 s and is left out."
                color: Qt.darker(root.baseColor, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                textFormat: Text.PlainText
                visible: storageCard.diskList.length === 0
                width: parent.width
                wrapMode: Text.Wrap
                text: hw.disksFailed ? "Storage data unavailable (findmnt failed)." : (hw.disks === null ? "Reading mounted filesystems…" : "No mounted storage.")
                color: Qt.darker(root.baseColor, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // 5b. Top Processes by RAM (only while the panel is open)
          Rectangle {
            id: procsSection
            y: sectionStack.offsetOf("procs")
            Behavior on y { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
            width: parent.width
            implicitHeight: (root.sectionCollapsed("procs") ? topProcCol.children[0].implicitHeight : topProcCol.implicitHeight) + Style.space(24)
            clip: true
            Behavior on implicitHeight { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
            color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.04)
            border.color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.10)
            border.width: 1
            radius: Style.cornerRadius
            visible: root.sectionShown("procs")
            opacity: hw.procTopFailed && hw.topProcs.length === 0 ? 0.7 : 1

            // Header click folds/unfolds the card; declared first so the
            // chips in the header (drawn above it) keep their own clicks.
            MouseArea {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              height: topProcCol.children[0].implicitHeight + Style.space(18)
              cursorShape: Qt.PointingHandCursor
              onClicked: root.toggleCollapsed("procs")
            }

            Column {
              id: topProcCol
              anchors.fill: parent
              anchors.margins: Style.space(12)
              clip: true  // a folded card shows only the header row
              spacing: Style.space(8)

              Row {
                width: parent.width
                spacing: Style.space(6)

                Text {
                  id: procTopIcon
                  textFormat: Text.PlainText
                  text: "\uf03a"
                  color: Color.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  textFormat: Text.PlainText
                  text: "Top processes"
                  color: root.baseColor
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  anchors.verticalCenter: parent.verticalCenter
                }

                ModeChip {
                  id: sortCpuChip
                  label: "CPU"
                  selected: hw.topProcSort === "cpu"
                  anchors.verticalCenter: parent.verticalCenter
                  onPicked: root.persistSetting("topProcSort", "cpu")
                }

                ModeChip {
                  id: sortRamChip
                  label: "RAM"
                  selected: hw.topProcSort === "ram"
                  anchors.verticalCenter: parent.verticalCenter
                  onPicked: root.persistSetting("topProcSort", "ram")
                }

                ModeChip {
                  id: groupChip
                  label: "Group"
                  selected: hw.topProcGroup
                  anchors.verticalCenter: parent.verticalCenter
                  onPicked: root.persistSetting("topProcGroup", !hw.topProcGroup)
                }

                Item {
                  width: Math.max(0, parent.width - procTopIcon.implicitWidth - parent.children[1].implicitWidth - sortRamChip.implicitWidth - sortCpuChip.implicitWidth - groupChip.implicitWidth - procTopStamp.implicitWidth - parent.spacing * 6)
                  height: 1
                }

                Text {
                  id: procTopStamp
                  textFormat: Text.PlainText
                  text: {
                    var metric = hw.topProcSort === "cpu" ? "by CPU" : "by RAM"
                    if (hw.procTopTime === "") return metric
                    return metric + " \u00b7 " + hw.procTopTime
                  }
                  color: Qt.darker(root.baseColor, 1.4)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              Column {
                width: parent.width
                spacing: Style.space(6)
                visible: hw.topProcs.length > 0

                Repeater {
                  model: hw.topProcs
                  delegate: Column {
                    required property var modelData
                    required property int index

                    width: parent.width
                    spacing: Style.space(3)

                    readonly property int total: hw.topProcs.length
                    readonly property bool sortCpu: hw.topProcSort === "cpu"
                    readonly property real topRss: total > 0 ? Math.max(1, hw.topProcs[0].rssKib) : 1
                    readonly property real topCpu: total > 0 ? Math.max(0, hw.topProcs[0].cpu) : 0
                    readonly property bool useCpuBars: sortCpu && topCpu > 0
                    readonly property real metricVal: sortCpu ? modelData.cpu : modelData.memPct
                    readonly property real shareD: useCpuBars ? modelData.cpu / Math.max(1, topCpu) : modelData.rssKib / topRss
                    readonly property real rankSev: total > 1 ? (1 - index / (total - 1)) : 1
                    readonly property real combinedSev: Math.max(0.35 + 0.65 * rankSev,
                      Model.severity(metricVal, root.warnPercent, root.criticalPercent))
                    readonly property color sevColor: root.accentMix(combinedSev)

                    Row {
                      width: parent.width
                      spacing: Style.space(6)

                      Text {
                        id: procRank
                        textFormat: Text.PlainText
                        text: (index + 1) + "."
                        color: sevColor
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        font.bold: true
                        anchors.verticalCenter: parent.verticalCenter
                      }

                      Text {
                        textFormat: Text.PlainText
                        width: Math.max(40, parent.width - procRank.implicitWidth - procFigs.implicitWidth - parent.spacing * 2)
                        elide: Text.ElideRight
                        text: modelData.count > 1 ? (modelData.name + "  \u00b7 " + modelData.count + " processes") : (modelData.name + "  (" + modelData.pid + ")")
                        color: root.baseColor
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        anchors.verticalCenter: parent.verticalCenter
                      }

                      Text {
                        id: procFigs
                        textFormat: Text.PlainText
                        anchors.verticalCenter: parent.verticalCenter
                        text: Model.formatGib(Model.gibFromKib(modelData.rssKib)) + " GiB \u00b7 CPU " + Math.round(modelData.cpu) + "%"
                        color: sevColor
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }
                    }

                    Rectangle {
                      width: parent.width
                      height: Style.space(5)
                      radius: height / 2
                      color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.12)

                      Rectangle {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        radius: parent.radius
                        color: sevColor
                        width: Math.max(parent.height, Math.min(parent.width, parent.width * shareD))
                        Behavior on width { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                      }
                    }
                  }
                }
              }

              Text {
                textFormat: Text.PlainText
                visible: hw.topProcs.length === 0
                width: parent.width
                wrapMode: Text.Wrap
                text: hw.procTopFailed ? "Process data unavailable (python3 missing or read failed)." : "Collecting process data\u2026"
                color: Qt.darker(root.baseColor, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // 6. Graphics Telemetry Section (if GPU present)
          Rectangle {
            id: gpuSection
            y: sectionStack.offsetOf("gpu")
            Behavior on y { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
            width: parent.width
            implicitHeight: (root.sectionCollapsed("gpu") ? gpuCol.children[0].implicitHeight : gpuCol.implicitHeight) + Style.space(24)
            clip: true
            Behavior on implicitHeight { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
            color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.04)
            border.color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.10)
            border.width: 1
            radius: Style.cornerRadius
            visible: root.sectionShown("gpu")

            // Header click folds/unfolds the card; declared first so the
            // chips in the header (drawn above it) keep their own clicks.
            MouseArea {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              height: gpuCol.children[0].implicitHeight + Style.space(18)
              cursorShape: Qt.PointingHandCursor
              onClicked: root.toggleCollapsed("gpu")
            }

            Column {
              id: gpuCol
              anchors.fill: parent
              anchors.margins: Style.space(12)
              clip: true  // a folded card shows only the header row
              spacing: Style.space(10)

              Row {
                width: parent.width
                spacing: Style.space(6)

                Text {
                  textFormat: Text.PlainText
                  text: "󰾲"
                  color: Color.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  textFormat: Text.PlainText
                  text: hw.gpuInfo && hw.gpuInfo.name ? hw.gpuInfo.name : "Graphics Adapter"
                  color: root.baseColor
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  wrapMode: Text.Wrap
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              // VRAM Meter
              Column {
                width: parent.width
                spacing: Style.space(4)
                visible: hw.gpuVramTotalBytes > 0

                Row {
                  width: parent.width

                  Text {
                    textFormat: Text.PlainText
                    text: "VRAM"
                    color: Qt.darker(root.baseColor, 1.4)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }

                  Item {
                    width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth)
                    height: 1
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: hw.gpuVramTotalBytes > 0 ? (Model.formatGib(Model.gibFromBytes(hw.gpuVramUsedBytes)) + " / " + Model.formatGib(Model.gibFromBytes(hw.gpuVramTotalBytes)) + " GiB (" + Math.round(hw.gpuVramPercent) + "%)") : "–"
                    color: root.warm(root.baseColor, Model.severity(hw.gpuVramPercent, root.warnPercent, root.criticalPercent))
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }

                Rectangle {
                  width: parent.width
                  height: Style.space(6)
                  radius: height / 2
                  color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.12)

                  Rectangle {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    radius: parent.radius
                    color: root.warm(root.baseColor, Model.severity(hw.gpuVramPercent, root.warnPercent, root.criticalPercent))
                    width: hw.gpuVramPercent >= 0 ? Math.max(parent.height, Math.min(parent.width, parent.width * (hw.gpuVramPercent / 100))) : 0
                    Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
                  }
                }
              }

              Row {
                width: parent.width
                spacing: Style.space(16)

                Column {
                  width: (parent.width - parent.spacing) / 2
                  spacing: Style.spacing.labelGap

                  InfoPair { label: "Load"; value: hw.gpuPercent >= 0 ? Model.formatPercent(hw.gpuPercent) : "–" }
                  InfoPair {
                    label: "Temperature"
                    value: hw.gpuTempC > 0 ? Model.formatTemp(hw.gpuTempC, root.fahrenheit) : "–"
                    valueColor: root.tempColor(hw.gpuTempC)
                  }
                  InfoPair { label: "Power"; value: hw.gpuWatts >= 0 ? Model.formatWatts(hw.gpuWatts) : "–" }
                }

                Column {
                  width: (parent.width - parent.spacing) / 2
                  spacing: Style.spacing.labelGap

                  InfoPair { label: "Clock"; value: hw.gpuMhz > 0 ? Model.formatGhz(hw.gpuMhz) : "–" }
                  InfoPair { label: "Fan"; value: hw.gpuRpm >= 0 ? Model.formatRpm(hw.gpuRpm) : "–" }
                  InfoPair { label: "Driver"; value: hw.gpuInfo && hw.gpuInfo.kind ? String(hw.gpuInfo.kind) : "–" }
                }
              }
            }
          }
        }

        // Bottom breathing room spacer to guarantee zero clipping
        Item {
          width: parent.width
          height: Style.space(12)
        }
      }
    }
  }

  // One entry of an orderable row: ‹ name ›. The name shows or hides it.
  component OrderPill: Row {
    id: pill
    property string label: ""
    property bool shown: true
    property bool first: false
    property bool last: false
    signal toggled()
    signal moved(int delta)

    spacing: Style.space(2)

    ModeChip {
      label: "‹"
      enabled: !pill.first
      opacity: enabled ? 1 : 0.35
      onPicked: pill.moved(-1)
    }
    ModeChip {
      label: pill.label
      selected: pill.shown
      onPicked: pill.toggled()
    }
    ModeChip {
      label: "›"
      enabled: !pill.last
      opacity: enabled ? 1 : 0.35
      onPicked: pill.moved(1)
    }
  }

  // One row of the vertical section list: name (shows or hides it), ↑ ↓.
  component OrderRow: Item {
    id: orderRow
    property string label: ""
    property string note: ""
    property bool shown: true
    property bool first: false
    property bool last: false
    signal toggled()
    signal moved(int delta)

    implicitHeight: Math.max(orderName.implicitHeight, orderUp.implicitHeight)

    ModeChip {
      id: orderName
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      label: orderRow.label
      selected: orderRow.shown
      onPicked: orderRow.toggled()
    }

    Text {
      anchors.left: orderName.right
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      visible: orderRow.note !== ""
      textFormat: Text.PlainText
      text: orderRow.note
      color: Qt.darker(root.baseColor, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    ModeChip {
      id: orderDown
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      label: "↓"
      enabled: !orderRow.last
      opacity: enabled ? 1 : 0.35
      onPicked: orderRow.moved(1)
    }

    ModeChip {
      id: orderUp
      anchors.right: orderDown.left
      anchors.rightMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      label: "↑"
      enabled: !orderRow.first
      opacity: enabled ? 1 : 0.35
      onPicked: orderRow.moved(-1)
    }
  }

  // Interactive settings chip
  component ModeChip: Rectangle {
    id: chip
    property string label: ""
    property bool selected: false
    property color activeColor: Color.accent
    signal picked()

    implicitWidth: chipLabel.implicitWidth + Style.space(12)
    implicitHeight: chipLabel.implicitHeight + Style.space(8)
    radius: Style.cornerRadius
    color: chip.selected ? activeColor : (chipMouse.containsMouse ? Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.12) : Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.06))
    border.color: chip.selected ? activeColor : Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.12)
    border.width: 1

    Behavior on color { ColorAnimation { duration: 140 } }
    Behavior on border.color { ColorAnimation { duration: 140 } }

    scale: chipMouse.pressed ? 0.95 : 1
    Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

    Text {
      id: chipLabel
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: chip.label
      color: chip.selected ? Qt.darker(chip.activeColor, 2.4) : root.baseColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: chip.selected
    }

    MouseArea {
      id: chipMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: chip.picked()
    }
  }

  component InfoPair: Row {
    id: infoPairRoot
    property string label: ""
    property string value: ""
    property color valueColor: root.baseColor

    width: parent.width
    spacing: Style.space(8)

    Text {
      textFormat: Text.PlainText
      text: infoPairRoot.label
      color: Qt.darker(root.baseColor, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }

    Item {
      width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2)
      height: 1
    }

    Text {
      textFormat: Text.PlainText
      text: infoPairRoot.value
      color: infoPairRoot.valueColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      Behavior on color { ColorAnimation { duration: 240 } }
    }
  }

  component LoadMeter: Column {
    id: meterRoot
    property string period: ""
    property real value: 0
    property real maxVal: 8
    property color baseColor: Color.foreground
    property color hotColor: Color.urgent
    property string fontFamily: Style.font.family

    spacing: Style.space(4)

    Row {
      width: parent.width

      Text {
        textFormat: Text.PlainText
        text: meterRoot.period
        color: Qt.darker(meterRoot.baseColor, 1.4)
        font.family: meterRoot.fontFamily
        font.pixelSize: Style.font.caption
      }

      Item {
        width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth)
        height: 1
      }

      Text {
        textFormat: Text.PlainText
        text: meterRoot.value.toFixed(2)
        color: meterRoot.baseColor
        font.family: meterRoot.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }

    Rectangle {
      width: parent.width
      height: Style.space(4)
      radius: height / 2
      color: Qt.rgba(meterRoot.baseColor.r, meterRoot.baseColor.g, meterRoot.baseColor.b, 0.12)

      Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        radius: parent.radius
        color: {
          var ratio = meterRoot.maxVal > 0 ? Math.min(1, meterRoot.value / meterRoot.maxVal) : 0
          return Qt.rgba(meterRoot.baseColor.r + (meterRoot.hotColor.r - meterRoot.baseColor.r) * ratio,
                         meterRoot.baseColor.g + (meterRoot.hotColor.g - meterRoot.baseColor.g) * ratio,
                         meterRoot.baseColor.b + (meterRoot.hotColor.b - meterRoot.baseColor.b) * ratio,
                         meterRoot.baseColor.a)
        }
        width: meterRoot.maxVal > 0 ? Math.max(parent.height, Math.min(parent.width, parent.width * Math.min(1, meterRoot.value / meterRoot.maxVal))) : 0
        Behavior on width { NumberAnimation { duration: 240 } }
      }
    }
  }
}
