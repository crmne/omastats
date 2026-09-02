import QtQuick
import qs.Commons
import qs.Ui
import "../Model.js" as Model

// One module's compact readout in the bar: glyph, a live mini graph, and a
// figure. Built on WidgetButton so it registers as a bar click target and
// shares the bar's tooltip and hover conventions.
WidgetButton {
  id: root

  property string module: "cpu"
  property var service: null
  property string mode: "both"
  property int graphWidth: 36
  property string temperatureUnit: "Celsius"
  // Disks: "all" or a block device name. Sensors: comma list of sensor ids.
  property string disksSource: "all"
  property string barSensors: "cpu"
  // "text" stacks the module's short name vertically, iStat style; "icon" uses a glyph.
  property string labelMode: "text"

  signal activated(string module, int button)

  readonly property var snap: service ? service.snapshot : ({})
  readonly property var hist: service ? service.history : ({})
  readonly property var def: Model.moduleDef(module)
  readonly property bool ready: !!(service && service.ready)
  readonly property bool ringable: def.ring === true
  readonly property bool graphable: def.graph === true
  readonly property bool showGraph: !vertical && graphable && (mode === "both" || mode === "graph")
  readonly property bool showRing: !vertical && ringable && (mode === "ring" || mode === "ring-text")
  readonly property bool showText: !vertical && (mode === "both" || mode === "text" || mode === "ring-text" || (!graphable && !ringable))
  readonly property bool twoLine: module === "network" || (module === "disks" && !showRing)
  readonly property color s1: service ? service.series1 : foreground
  readonly property color s2: service ? service.series2 : foreground
  readonly property real graphHeight: Math.max(8, barSize - Style.space(11))

  readonly property var cpu: snap.cpu || ({})
  readonly property var gpu: snap.gpu || null
  readonly property var mem: snap.mem || ({})
  readonly property var net: snap.net || ({})
  readonly property var disks: snap.disks || ({})
  readonly property var sensors: snap.sensors || ({})
  readonly property var battery: snap.battery || null

  readonly property real memPercent: mem.total > 0 ? mem.used / mem.total * 100 : 0
  readonly property bool charging: !!(battery && (battery.status === "Charging" || battery.status === "Full"))

  // Disk activity: the selected device when present, otherwise every disk.
  readonly property bool singleDisk: disksSource !== "all" && !!(disks.perDisk && disks.perDisk[disksSource])
  readonly property real diskRead: singleDisk ? Model.num(disks.perDisk[disksSource].read) : Model.num(disks.read)
  readonly property real diskWrite: singleDisk ? Model.num(disks.perDisk[disksSource].write) : Model.num(disks.write)
  readonly property var diskReadHistory: singleDisk && hist.disks && hist.disks[disksSource] ? hist.disks[disksSource].read : (hist.diskRead || [])
  readonly property var diskWriteHistory: singleDisk && hist.disks && hist.disks[disksSource] ? hist.disks[disksSource].write : (hist.diskWrite || [])

  // Fullness for the ring: usage now, or capacity for disks and charge for battery.
  readonly property real ringValue: {
    switch (module) {
      case "cpu": return Model.num(cpu.total) / 100
      case "gpu": return gpu && isFinite(Number(gpu.util)) ? Model.num(gpu.util) / 100 : 0
      case "memory": return memPercent / 100
      case "battery": return battery ? Model.num(battery.percent) / 100 : 0
      case "disks": {
        var volumes = Array.isArray(disks.volumes) ? disks.volumes : []
        var chosen = null
        for (var i = 0; i < volumes.length; i++) {
          var v = volumes[i]
          if (singleDisk ? v.disk === disksSource : v.mount === "/") { chosen = v; break }
        }
        if (!chosen && volumes.length > 0) chosen = volumes[0]
        return chosen && chosen.size > 0 ? Model.num(chosen.used) / Model.num(chosen.size) : 0
      }
    }
    return 0
  }
  readonly property color ringColor: {
    if (module === "battery") return battery && charging ? (service ? service.good : s1) : (ringValue <= 0.15 ? (service ? service.danger : s1) : s1)
    if (module === "disks") return ringValue >= 0.92 ? (service ? service.danger : s1) : (ringValue >= 0.8 ? (service ? service.warn : s1) : s1)
    return s1
  }

  // Sensors: one glyph + figure per selected sensor that exists right now.
  readonly property var sensorReadings: {
    var ids = Model.parseList(barSensors)
    var out = []
    for (var i = 0; i < ids.length; i++) {
      var reading = Model.sensorReading(snap, ids[i], temperatureUnit)
      if (reading) out.push(reading)
    }
    if (out.length === 0) {
      var fallback = Model.sensorReading(snap, "cpu", temperatureUnit)
      if (fallback) out.push(fallback)
    }
    return out
  }

  readonly property string glyph: module === "battery" && battery
    ? Model.batteryIcon(battery.percent, charging)
    : def.icon

  readonly property string primaryText: {
    if (!ready) return "…"
    switch (module) {
      case "cpu": return Model.percentText(cpu.total)
      case "gpu": return gpu && isFinite(Number(gpu.util)) ? Model.percentText(gpu.util) : "—"
      case "memory": return Model.percentText(memPercent)
      case "battery": return battery ? Model.percentText(battery.percent) : "—"
      case "network": return "↑ " + Model.compactRate(net.tx)
      case "disks": return showRing ? Model.percentText(ringValue * 100) : "R " + Model.compactRate(diskRead)
    }
    return ""
  }

  readonly property string secondaryText: {
    if (!ready) return "…"
    if (module === "network") return "↓ " + Model.compactRate(net.rx)
    if (module === "disks") return showRing ? "" : "W " + Model.compactRate(diskWrite)
    return ""
  }

  // Widest string each figure can take, so the readout never jitters.
  readonly property string reserveText: {
    switch (module) {
      case "network":
      case "disks": return "↓ 999K"
      default: return "100%"
    }
  }

  function fanSummary() {
    var fans = Array.isArray(sensors.fans) ? sensors.fans : []
    var active = 0
    var sum = 0
    for (var i = 0; i < fans.length; i++) {
      if (fans[i].rpm > 0) { active += 1; sum += fans[i].rpm }
    }
    if (active === 0) return fans.length > 0 ? "Fans off" : ""
    return "Fans " + Math.round(sum / active) + " rpm"
  }

  function tooltip() {
    if (!ready) return def.label + " · starting sampler…"
    var parts = []
    switch (module) {
      case "cpu":
        parts.push("CPU " + Model.percentText(cpu.total))
        if (Model.freqText(cpu.mhz)) parts.push(Model.freqText(cpu.mhz))
        if (isFinite(Number(cpu.temp))) parts.push(Model.tempLongText(cpu.temp, temperatureUnit))
        return parts.join(" · ") + "\nLoad " + Model.loadText(cpu.load) + " · Up " + Model.uptimeText(cpu.uptime)
      case "gpu":
        if (!gpu) return "GPU not detected"
        parts.push(Model.shortGpuName(gpu.name) + " " + (isFinite(Number(gpu.util)) ? Model.percentText(gpu.util) : ""))
        if (Model.freqText(gpu.mhz)) parts.push(Model.freqText(gpu.mhz))
        if (isFinite(Number(gpu.temp))) parts.push(Model.tempLongText(gpu.temp, temperatureUnit))
        if (gpu.memTotal > 0) parts.push(Model.pairText(gpu.memUsed, gpu.memTotal))
        return parts.join(" · ")
      case "memory":
        return "Memory " + Model.percentText(memPercent) + " · " + Model.pairText(mem.used, mem.total)
          + (mem.swapUsed > 0 ? "\nSwap " + Model.bytesText(mem.swapUsed) : "")
      case "network":
        return (net.default || "Network") + " · ↓ " + Model.rateText(net.rx) + " · ↑ " + Model.rateText(net.tx)
      case "disks":
        return (singleDisk ? disksSource : "All disks") + " · read " + Model.rateText(diskRead) + " · write " + Model.rateText(diskWrite)
      case "sensors":
        for (var i = 0; i < sensorReadings.length; i++) {
          var r = sensorReadings[i]
          parts.push(r.label + " " + (r.kind === "temp" ? Model.tempLongText(r.celsius, temperatureUnit) : (r.rpm > 0 ? Math.round(r.rpm) + " rpm" : "off")))
        }
        var fans = fanSummary()
        if (fans && parts.length < 3) parts.push(fans)
        return parts.length ? parts.join(" · ") : "No sensors"
      case "battery":
        if (!battery) return "No battery"
        parts.push("Battery " + Model.percentText(battery.percent))
        parts.push(battery.status)
        if (battery.status === "Discharging" && battery.timeToEmpty > 0) parts.push(Model.clockText(battery.timeToEmpty) + " left")
        if (battery.status === "Charging" && battery.timeToFull > 0) parts.push(Model.clockText(battery.timeToFull) + " to full")
        return parts.join(" · ")
    }
    return def.label
  }

  labelVisible: false
  hasVisualContent: true
  text: def.icon
  horizontalMargin: 5
  fixedWidth: vertical ? -1 : content.implicitWidth + scaledHorizontalMargin * 2
  fixedHeight: vertical ? Style.bar.iconSlot : -1
  tooltipText: tooltip()

  onPressed: function(button) { root.activated(root.module, button) }

  TextMetrics {
    id: reserve
    font.family: root.fontFamily
    font.pixelSize: root.twoLine ? Style.font.caption : Style.font.body
    text: root.reserveText
  }

  Row {
    id: content
    anchors.centerIn: parent
    spacing: Style.space(4)

    // Every module but sensors: one label, then graph and/or figure.
    Text {
      visible: root.module !== "sensors" && root.labelMode !== "text"
      textFormat: Text.PlainText
      text: root.glyph
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.bar.iconFont
      renderType: Text.NativeRendering
      anchors.verticalCenter: parent.verticalCenter
    }

    StackLabel {
      visible: root.module !== "sensors" && root.labelMode === "text"
      text: root.def.short || root.def.label
      color: root.foreground
      fontFamily: root.fontFamily
      letterSize: Style.spaceReal(10)
      maxHeight: root.barSize - Style.space(3)
      anchors.verticalCenter: parent.verticalCenter
    }

    Loader {
      active: root.showGraph && root.module !== "sensors"
      visible: active
      anchors.verticalCenter: parent.verticalCenter
      sourceComponent: root.twoLine ? mirrorGraph : historyGraph
    }

    Loader {
      active: root.showRing
      visible: active
      anchors.verticalCenter: parent.verticalCenter
      sourceComponent: ringGauge
    }

    Loader {
      active: root.showText && root.module !== "sensors"
      visible: active
      anchors.verticalCenter: parent.verticalCenter
      sourceComponent: root.twoLine ? twoLineText : singleText
    }

    // Sensors: a glyph + figure pair per selected sensor.
    Repeater {
      model: root.module === "sensors" ? root.sensorReadings.length : 0

      delegate: Row {
        id: sensorPair
        required property int index
        readonly property var reading: root.sensorReadings[index] || ({})
        spacing: Style.space(3)
        anchors.verticalCenter: parent.verticalCenter

        Text {
          visible: root.labelMode !== "text"
          textFormat: Text.PlainText
          text: sensorPair.reading.icon || "󰔏"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.bar.iconFont
          renderType: Text.NativeRendering
          anchors.verticalCenter: parent.verticalCenter
        }

        StackLabel {
          visible: root.labelMode === "text"
          text: sensorPair.reading.short || "TMP"
          color: root.foreground
          fontFamily: root.fontFamily
          letterSize: Style.spaceReal(10)
          maxHeight: root.barSize - Style.space(3)
          anchors.verticalCenter: parent.verticalCenter
        }

        TextMetrics {
          id: sensorReserve
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          text: sensorPair.reading.kind === "fan" ? "9999" : "100°"
        }

        Text {
          textFormat: Text.PlainText
          visible: !root.vertical
          width: Math.ceil(sensorReserve.advanceWidth)
          horizontalAlignment: Text.AlignRight
          text: root.ready ? String(sensorPair.reading.text || "") + String(sensorPair.reading.unit === "°" ? "°" : "") : "…"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          renderType: Text.NativeRendering
          anchors.verticalCenter: parent.verticalCenter
        }
      }
    }
  }

  Component {
    id: ringGauge

    MiniRing {
      size: Math.max(10, root.barSize - Style.space(10))
      thickness: Style.spaceReal(2.4)
      value: root.ringValue
      color: root.ringColor
      foreground: root.foreground
      trackColor: Util.alpha(root.foreground, 0.22)
    }
  }

  Component {
    id: historyGraph

    HistoryGraph {
      width: root.graphWidth
      height: root.graphHeight
      barWidth: 1
      gap: 1
      ceiling: 100
      series: root.module === "cpu"
        ? [root.hist.cpuUser || [], root.hist.cpuSystem || []]
        : [root.module === "memory" ? (root.hist.memUsed || []) : (root.hist.gpu || [])]
      colors: [root.s1, root.s2]
      baselineColor: Util.alpha(root.foreground, 0.28)
    }
  }

  Component {
    id: mirrorGraph

    MirrorGraph {
      width: root.graphWidth
      height: root.graphHeight
      barWidth: 1
      gap: 1
      up: root.module === "network" ? (root.hist.netTx || []) : root.diskReadHistory
      down: root.module === "network" ? (root.hist.netRx || []) : root.diskWriteHistory
      upColor: root.s2
      downColor: root.s1
      floor: root.module === "network" ? 10240 : 262144
      midlineColor: Util.alpha(root.foreground, 0.32)
    }
  }

  Component {
    id: singleText

    Text {
      textFormat: Text.PlainText
      width: Math.ceil(reserve.advanceWidth)
      horizontalAlignment: Text.AlignRight
      text: root.primaryText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      renderType: Text.NativeRendering
    }
  }

  Component {
    id: twoLineText

    Column {
      spacing: 0

      Text {
        textFormat: Text.PlainText
        width: Math.ceil(reserve.advanceWidth)
        text: root.primaryText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        lineHeight: 0.95
        renderType: Text.NativeRendering
      }

      Text {
        textFormat: Text.PlainText
        width: Math.ceil(reserve.advanceWidth)
        text: root.secondaryText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        lineHeight: 0.95
        renderType: Text.NativeRendering
      }
    }
  }
}
