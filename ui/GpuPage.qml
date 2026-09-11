import QtQuick
import qs.Commons
import "../Model.js" as Model

// The GPU's own page: utilisation history, memory and power. It used to be a
// card at the foot of the CPU page, which left it sharing that page's
// scroll position and section toggles.
Column {
  id: root

  property var service: null
  property var host: null
  property var settings: ({})
  property string temperatureUnit: "Celsius"
  property bool publicIpEnabled: true
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.family

  readonly property var snap: service ? service.snapshot : ({})
  readonly property var hist: service ? service.history : Model.emptyHistory()
  readonly property color s1: service ? service.series1 : Color.accent
  readonly property var gpu: snap.gpu || null
  readonly property bool hasUtil: !!gpu && gpu.util !== null && isFinite(Number(gpu.util))

  function headerDetail(mhz, temp) {
    var parts = []
    var freq = Model.freqText(mhz)
    if (freq) parts.push(freq)
    if (isFinite(Number(temp)) && temp !== null) parts.push(Model.tempText(temp, temperatureUnit))
    return parts.join(", ")
  }

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(10)

  Card {
    visible: !!root.gpu
    foreground: root.foreground

    CardHeader {
      title: root.gpu ? Model.shortGpuName(root.gpu.name) : "GPU"
      detail: root.gpu ? root.headerDetail(root.gpu.mhz, root.gpu.temp) : ""
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    HistoryGraph {
      width: parent.width
      height: Style.space(64)
      series: [root.hist.gpu || []]
      colors: [root.s1]
      ceiling: 100
      baselineColor: Util.alpha(root.foreground, 0.14)
    }

    StatRow {
      label: "Load"
      dot: root.s1
      value: root.hasUtil ? String(Math.round(root.gpu.util)) : "—"
      unit: root.hasUtil ? "%" : ""
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    StatRow {
      visible: !!(root.gpu && root.gpu.memTotal > 0)
      label: "Memory"
      detail: root.gpu && root.gpu.memTotal > 0 ? Model.percentText(root.gpu.memUsed / root.gpu.memTotal * 100) : ""
      value: root.gpu ? Model.pairText(root.gpu.memUsed, root.gpu.memTotal).replace(/ [A-Z]+$/, "") : ""
      unit: root.gpu ? Model.bytesParts(root.gpu.memTotal).unit : ""
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    StatRow {
      visible: !!(root.gpu && isFinite(Number(root.gpu.power)) && root.gpu.power !== null)
      label: "Power"
      value: root.gpu && root.gpu.power !== null ? String(Math.round(root.gpu.power)) : ""
      unit: "W"
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    StatRow {
      visible: !!(root.gpu && isFinite(Number(root.gpu.fan)) && root.gpu.fan !== null)
      label: "Fan"
      value: root.gpu && root.gpu.fan !== null ? String(Math.round(root.gpu.fan)) : ""
      unit: "%"
      foreground: root.foreground
      fontFamily: root.fontFamily
    }
  }

  Card {
    visible: !root.gpu
    foreground: root.foreground

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: root.service && root.service.ready
        ? "No GPU detected. NVIDIA cards need nvidia-smi on PATH."
        : "Starting the sampler…"
      color: root.foreground
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      wrapMode: Text.WordWrap
    }
  }
}
