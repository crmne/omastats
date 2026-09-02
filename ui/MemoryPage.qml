import QtQuick
import qs.Commons
import "../Model.js" as Model

Column {
  id: root

  property var service: null
  property var host: null
  property var settings: ({})
  property string temperatureUnit: "Celsius"
  property bool publicIpEnabled: true
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.family

  function flag(key) { return Model.flag(settings, key) }

  readonly property var snap: service ? service.snapshot : ({})
  readonly property var hist: service ? service.history : Model.emptyHistory()
  readonly property color s1: service ? service.series1 : Color.accent
  readonly property color s2: service ? service.series2 : Color.accent
  readonly property color s3: service ? service.tertiary : Color.accent
  readonly property color warn: service ? service.warn : Color.urgent
  readonly property color danger: service ? service.danger : Color.urgent
  readonly property color track: Util.alpha(foreground, 0.16)

  readonly property var mem: snap.mem || ({})
  readonly property var procs: snap.procs || null
  readonly property real total: Math.max(1, Model.num(mem.total, 1))
  readonly property real usedPercent: Model.num(mem.used) / total * 100
  readonly property real pressure: Math.max(Model.num(mem.pressureSome), Model.num(mem.pressureFull))
  readonly property bool hasCompression: Model.num(mem.compressed) >= 1048576
  readonly property bool hasSwap: Model.num(mem.swapTotal) > 0
  readonly property real swapTotal: Model.num(mem.swapTotal)
  readonly property real swapUsed: Model.num(mem.swapUsed)
  readonly property real cached: Model.num(mem.cached)

  // The ring beside "Memory": swap, with the zram compression ratio as its
  // caption once something is actually compressed.
  readonly property var gaugeSpec: {
    if (swapTotal <= 0) {
      return { value: 0, color: s1, text: "Off", unit: "", label: "Swap", sub: "" }
    }
    var frac = swapUsed / swapTotal
    // Just the figure: the ring is small, and "used" is implied by the arc.
    var sub = Model.bytesText(swapUsed > 0 ? swapUsed : swapTotal)
    return {
      value: frac,
      color: frac >= 0.85 ? danger : (frac >= 0.5 ? warn : s1),
      text: String(Math.round(frac * 100)), unit: "%", label: "Swap", sub: sub
    }
  }

  function part(bytes) { return Model.bytesParts(bytes) }

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(10)

  Card {
    foreground: root.foreground

    Item {
      width: parent.width
      height: rings.implicitHeight

      Row {
        id: rings
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(30)

        RingGauge {
          value: root.gaugeSpec.value
          color: root.gaugeSpec.color
          foreground: root.foreground
          fontFamily: root.fontFamily
          valueText: root.gaugeSpec.text
          unitText: root.gaugeSpec.unit
          labelText: root.gaugeSpec.label
          subText: root.gaugeSpec.sub
          valueSize: root.gaugeSpec.unit === "" ? Style.font.title : Style.font.display
          size: Style.space(86)
        }

        RingGauge {
          foreground: root.foreground
          fontFamily: root.fontFamily
          segments: [
            { value: Model.num(root.mem.apps) / root.total, color: root.s1 },
            { value: Model.num(root.mem.shared) / root.total, color: root.s3 },
            { value: Model.num(root.mem.cached) / root.total, color: root.s2 }
          ]
          valueText: String(Math.round(root.usedPercent))
          unitText: "%"
          labelText: "Memory"
          subText: root.pressure >= 0.5 ? "pressure " + Math.round(root.pressure) + "%" : ""
          size: Style.space(86)
        }
      }
    }
  }

  Card {
    visible: root.flag("showBreakdown")
    foreground: root.foreground
    spacing: Style.space(2)

    StatRow {
      label: "Apps"
      dot: root.s1
      value: root.part(root.mem.apps).value
      unit: root.part(root.mem.apps).unit
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    StatRow {
      label: "Cached"
      dot: root.s2
      value: root.part(root.mem.cached).value
      unit: root.part(root.mem.cached).unit
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    StatRow {
      label: "Shared"
      dot: root.s3
      value: root.part(root.mem.shared).value
      unit: root.part(root.mem.shared).unit
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    StatRow {
      visible: root.hasCompression
      label: "Compressed"
      dot: root.warn
      value: root.part(root.mem.compressed).value
      unit: root.part(root.mem.compressed).unit
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    StatRow {
      label: "Free"
      dot: root.track
      value: root.part(root.mem.free).value
      unit: root.part(root.mem.free).unit
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    StatRow {
      visible: root.hasSwap
      label: "Swap"
      detail: "of " + Model.bytesText(root.mem.swapTotal)
      dot: Model.num(root.mem.swapUsed) > 0 ? root.danger : "transparent"
      showDot: true
      value: root.part(root.mem.swapUsed).value
      unit: root.part(root.mem.swapUsed).unit
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    StatRow {
      label: "Total"
      showDot: true
      value: root.part(root.mem.total).value
      unit: root.part(root.mem.total).unit
      labelOpacity: 0.55
      boldValue: false
      foreground: root.foreground
      fontFamily: root.fontFamily
    }
  }

  Card {
    visible: root.flag("showProcesses")
    foreground: root.foreground

    ProcessList {
      host: root.host
      items: root.procs ? (root.procs.mem || []) : []
      allItems: root.procs ? (root.procs.all || []) : []
      total: root.procs ? Model.num(root.procs.total) : 0
      columns: [{ key: "mem", kind: "bytes", title: "" }]
      emptyText: root.procs ? "Nothing resident" : "Measuring…"
      foreground: root.foreground
      fontFamily: root.fontFamily
    }
  }
}
