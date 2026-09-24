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
  // Disks: "speed" (read/write), "used" (space), or "both".
  property string diskShow: "speed"
  property string barSensors: "cpu"
  property var settings: ({})
  // GPU: which card this readout follows, by PCI address ("" = the first).
  property string gpuId: ""
  // Replaces the stacked label when several GPUs share the bar.
  property string shortLabel: ""
  // "text" stacks the module's short name vertically, iStat style; "icon" uses a glyph.
  property string labelMode: "text"

  signal activated(string module, int button)

  readonly property var snap: service ? service.snapshot : ({})
  readonly property var hist: service ? service.history : ({})
  readonly property var def: Model.moduleDef(module)
  readonly property bool ready: !!(service && service.ready)
  readonly property bool ringable: def.ring === true
  readonly property bool graphable: def.graph === true
  // Disks split the look from the metric: the picture is a read/write graph
  // for speed and a ring for space used, the figure rates or a percentage.
  readonly property bool isDisk: module === "disks"
  readonly property string diskLook: Model.diskLook(mode)
  readonly property bool diskSpeed: diskShow !== "used"
  readonly property bool diskUsed: diskShow === "used" || diskShow === "both"
  readonly property bool diskPicture: diskLook !== "text"
  readonly property bool diskFigure: diskLook !== "graph"
  readonly property bool showGraph: !vertical && graphable && (isDisk ? diskPicture && diskSpeed : (mode === "both" || mode === "graph"))
  readonly property bool showRing: !vertical && ringable && (isDisk ? diskPicture && diskUsed : (mode === "ring" || mode === "ring-text"))
  readonly property bool showText: !vertical && (isDisk ? diskFigure && diskUsed : (mode === "both" || mode === "text" || mode === "ring-text" || (!graphable && !ringable)))
  // Disk read/write figures, stacked beside the graph.
  readonly property bool showRates: !vertical && isDisk && diskFigure && diskSpeed
  readonly property bool twoLine: module === "network" || isDisk
  readonly property color s1: service ? service.series1 : foreground
  readonly property color s2: service ? service.series2 : foreground
  readonly property bool lightTheme: bar && !bar.transparent && bar.background.a >= 0.95
    ? bar.background.hslLightness > 0.5 : foreground.hslLightness < 0.5
  readonly property real graphHeight: Math.max(8, barSize - Style.space(11))

  readonly property var cpu: snap.cpu || ({})
  readonly property var gpu: {
    var list = Model.gpuList(snap)
    if (list.length === 0) return null
    if (!gpuId) return list[0]
    for (var i = 0; i < list.length; i++) if (Model.gpuId(list[i]) === gpuId) return list[i]
    return null
  }
  readonly property var gpuSeries: Model.gpuHistory(hist, gpuId || Model.gpuId(gpu))
  readonly property var mem: snap.mem || ({})
  readonly property var net: snap.net || ({})
  readonly property var disks: snap.disks || ({})
  readonly property var sensors: snap.sensors || ({})
  readonly property var battery: snap.battery || null

  readonly property var diskUsage: Model.diskUsage(snap, singleDisk ? disksSource : "all")
  readonly property real memPercent: mem.total > 0 ? mem.used / mem.total * 100 : 0
  readonly property real utilizationPercent: module === "cpu" ? Number(cpu.total)
    : (module === "gpu" ? (Model.gpuHasUtil(gpu) ? Number(gpu.util) : NaN)
    : (module === "memory" ? (mem.total > 0 ? memPercent : NaN)
    : (isDisk && diskUsed && diskUsage.size > 0 ? ringValue * 100 : NaN)))
  readonly property color utilizationColor: Model.utilizationColor(settings, utilizationPercent, lightTheme) || s1
  readonly property color percentageColor: Model.utilizationColor(settings, utilizationPercent, lightTheme) || foreground
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
      case "gpu": return Model.gpuHasUtil(gpu) ? Model.num(gpu.util) / 100 : 0
      case "memory": return isFinite(memPercent) ? memPercent / 100 : 0
      case "battery": return battery ? Model.num(battery.percent) / 100 : 0
      case "disks": return diskUsage.fraction
    }
    return 0
  }
  readonly property color ringColor: {
    if (module === "battery") return battery && charging ? (service ? service.good : s1) : (ringValue <= 0.15 ? (service ? service.danger : s1) : s1)
    if (module === "disks") return Model.utilizationColor(settings, utilizationPercent, lightTheme) || (ringValue >= 0.92 ? (service ? service.danger : s1) : (ringValue >= 0.8 ? (service ? service.warn : s1) : s1))
    if (module === "cpu" || module === "gpu" || module === "memory") return utilizationColor
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
      case "gpu":
        if (Model.gpuHasUtil(gpu)) return Model.percentText(gpu.util)
        return gpu ? Model.compactFreq(gpu.mhz) : "—"
      case "memory": return Model.percentText(memPercent)
      case "battery": return battery ? Model.percentText(battery.percent) : "—"
      case "network": return "↑ " + Model.compactRate(net.tx)
      case "disks": return "R " + Model.compactRate(diskRead)
    }
    return ""
  }

  readonly property string secondaryText: {
    if (!ready) return "…"
    if (module === "network") return "↓ " + Model.compactRate(net.rx)
    if (module === "disks") return "W " + Model.compactRate(diskWrite)
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
        parts.push(Model.gpuTitle(gpu) + (Model.gpuHasUtil(gpu) ? " " + Model.percentText(gpu.util) : ""))
        if (!Model.gpuHasUtil(gpu)) parts.push("load not reported")
        if (Model.freqText(gpu.mhz)) parts.push(Model.freqText(gpu.mhz))
        if (isFinite(Number(gpu.temp))) parts.push(Model.tempLongText(gpu.temp, temperatureUnit))
        if (gpu.memTotal > 0) parts.push(Model.pairText(gpu.memUsed, gpu.memTotal))
        return parts.join(" · ")
      case "memory":
        return "Memory " + Model.percentText(memPercent) + " · " + Model.pairText(mem.used, mem.total)
          + (mem.swapUsed > 0 ? "\nSwap " + Model.bytesText(mem.swapUsed) : "")
      case "network":
        return (net.default || "Network") + " · ↓ " + Model.rateText(net.rx) + " · ↑ " + Model.rateText(net.tx)
      case "disks": {
        var name = singleDisk ? disksSource : "All disks"
        var speed = "read " + Model.rateText(diskRead) + " · write " + Model.rateText(diskWrite)
        var space = diskUsage.size > 0 ? Model.pairText(diskUsage.used, diskUsage.size) + " used (" + Model.percentText(ringValue * 100) + ")" : "no volumes mounted"
        if (diskShow === "used") return name + " · " + space + "\n" + speed
        return name + " · " + speed + "\n" + space
      }
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
    font.pixelSize: Style.font.caption
    text: root.reserveText
  }

  TextMetrics {
    id: figureReserve
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    text: "100%"
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
      text: root.shortLabel || root.def.short || root.def.label
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
      active: root.showRates
      visible: active
      anchors.verticalCenter: parent.verticalCenter
      sourceComponent: twoLineText
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
      sourceComponent: root.module === "network" ? twoLineText : singleText
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
        : [root.module === "memory" ? (root.hist.memUsed || []) : root.gpuSeries]
      colors: [root.s1, root.s2]
      sampleColors: {
        if (root.module === "cpu") {
          var grades = Model.utilizationHistoryColors(root.hist.cpuTotal, root.settings, root.lightTheme)
          return [grades, grades]
        }
        if (root.module === "memory") return [Model.utilizationHistoryColors(root.hist.memUsed, root.settings, root.lightTheme)]
        if (root.module === "gpu") return [Model.utilizationHistoryColors(root.gpuSeries, root.settings, root.lightTheme)]
        return []
      }
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
      width: Math.ceil(figureReserve.advanceWidth)
      horizontalAlignment: Text.AlignRight
      text: root.isDisk ? (root.ready ? Model.percentText(root.ringValue * 100) : "…") : root.primaryText
      color: root.percentageColor
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
