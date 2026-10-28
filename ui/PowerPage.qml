import QtQuick
import qs.Commons
import qs.Commons as Commons
import "../Model.js" as Model

// Where the machine's power goes: the best total it can measure, then every
// reading behind it (CPU package and RAPL zones, each discrete GPU, the
// power supply), then the battery, which this tab replaced in 1.8.
Column {
  id: root

  property var service: null
  property var host: null
  property var settings: ({})
  property string temperatureUnit: "Celsius"
  property bool publicIpEnabled: true
  property color foreground: Commons.Color.popups.text
  property string fontFamily: Style.font.family

  readonly property var snap: service ? service.snapshot : ({})
  readonly property var hist: service ? service.history : Model.emptyHistory()
  readonly property color s1: service ? service.series1 : Commons.Color.accent
  readonly property color s2: service ? service.series2 : Commons.Color.accent
  readonly property var summary: Model.powerSummary(snap)
  readonly property bool measured: summary.source !== "" && summary.source !== "estimate"
  readonly property bool hasBattery: !!(snap.battery && snap.battery.present)
  readonly property string acText: summary.acOnline === null ? "" : (summary.acOnline ? "On AC power" : "On battery")

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(10)

  Card {
    foreground: root.foreground

    CardHeader {
      title: "Power"
      detail: root.acText
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    BigStat {
      width: parent.width
      visible: root.summary.total !== null
      value: Model.wattsParts(root.summary.total).value
      unit: Model.wattsParts(root.summary.total).unit
      label: root.summary.detail
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    // A measured total is one series; an estimate shows its two parts.
    HistoryGraph {
      width: parent.width
      visible: root.summary.total !== null
      height: visible ? Style.space(64) : 0
      series: root.measured ? [root.hist.powerTotal || []] : [root.hist.powerCpu || [], root.hist.powerGpu || []]
      colors: root.measured ? [root.s1] : [root.s1, root.s2]
      floor: 10
      baselineColor: Util.alpha(root.foreground, 0.14)
    }

    Legend {
      visible: !root.measured && root.summary.cpu !== null && root.summary.gpu !== null
      foreground: root.foreground
      fontFamily: root.fontFamily
      items: [
        { color: root.s1, label: "CPU", value: Model.wattsParts(root.summary.cpu).value, unit: "W" },
        { color: root.s2, label: "GPUs", value: Model.wattsParts(root.summary.gpu).value, unit: "W" }
      ]
    }

    Text {
      textFormat: Text.PlainText
      visible: root.summary.total === null
      width: parent.width
      wrapMode: Text.WordWrap
      text: root.service && root.service.ready
        ? "This machine reports no power readings. CPU package power needs RAPL counters readable without root, or an AMD APU."
        : "Starting the sampler…"
      color: root.foreground
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  Card {
    visible: root.summary.rows.length > 0
    foreground: root.foreground
    spacing: Style.space(2)

    SectionTitle { text: "Readings"; fontFamily: root.fontFamily }

    Repeater {
      model: root.summary.rows.length

      delegate: StatRow {
        required property int index
        readonly property var row: root.summary.rows[index] || ({})
        label: String(row.label || "")
        detail: String(row.detail || "")
        value: row.watts === null ? "Off" : Model.wattsParts(row.watts).value
        unit: row.watts === null ? "" : "W"
        boldValue: false
        labelOpacity: row.watts === null ? 0.5 : 0.85
        foreground: root.foreground
        fontFamily: root.fontFamily
      }
    }
  }

  BatteryPage {
    visible: root.hasBattery
    service: root.service
    host: root.host
    settings: root.settings
    temperatureUnit: root.temperatureUnit
    foreground: root.foreground
    fontFamily: root.fontFamily
  }
}
