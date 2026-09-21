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
  readonly property var gpuCards: Model.gpuList(snap)

  function headerDetail(mhz, temp) {
    var parts = []
    var freq = Model.freqText(mhz)
    if (freq) parts.push(freq)
    if (isFinite(Number(temp)) && temp !== null) parts.push(Model.tempText(temp, temperatureUnit))
    return parts.join(", ")
  }

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(10)

  Repeater {
    model: root.gpuCards.length
    delegate: Card {
      id: gpuCard
      required property int index
      readonly property var gpu: root.gpuCards[index]
      readonly property bool hasUtil: Model.gpuHasUtil(gpu)
      foreground: root.foreground

      CardHeader {
        title: gpuCard.gpu ? Model.gpuTitle(gpuCard.gpu) : "GPU"
        detail: gpuCard.gpu ? root.headerDetail(gpuCard.gpu.mhz, gpuCard.gpu.temp) : ""
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      HistoryGraph {
        width: parent.width
        visible: gpuCard.hasUtil
        height: visible ? Style.space(64) : 0
        series: [Model.gpuHistory(root.hist, Model.gpuId(gpuCard.gpu))]
        colors: [root.s1]
        ceiling: 100
        baselineColor: Util.alpha(root.foreground, 0.14)
      }

      StatRow {
        label: "Load"
        detail: gpuCard.hasUtil ? "" : "load not reported"
        dot: root.s1
        value: gpuCard.hasUtil ? String(Math.round(gpuCard.gpu.util)) : "—"
        unit: gpuCard.hasUtil ? "%" : ""
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      StatRow {
        visible: !!(gpuCard.gpu && gpuCard.gpu.memTotal > 0)
        label: "Memory"
        detail: gpuCard.gpu && gpuCard.gpu.memTotal > 0 ? Model.percentText(gpuCard.gpu.memUsed / gpuCard.gpu.memTotal * 100) : ""
        value: gpuCard.gpu ? Model.pairText(gpuCard.gpu.memUsed, gpuCard.gpu.memTotal).replace(/ [A-Z]+$/, "") : ""
        unit: gpuCard.gpu ? Model.bytesParts(gpuCard.gpu.memTotal).unit : ""
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      StatRow {
        visible: !!(gpuCard.gpu && isFinite(Number(gpuCard.gpu.power)) && gpuCard.gpu.power !== null)
        label: "Power"
        value: gpuCard.gpu && gpuCard.gpu.power !== null ? String(Math.round(gpuCard.gpu.power)) : ""
        unit: "W"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      StatRow {
        visible: !!(gpuCard.gpu && isFinite(Number(gpuCard.gpu.fan)) && gpuCard.gpu.fan !== null)
        label: "Fan"
        value: gpuCard.gpu && gpuCard.gpu.fan !== null ? String(Math.round(gpuCard.gpu.fan)) : ""
        unit: "%"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }
    }
  }

  Card {
    visible: root.gpuCards.length === 0
    foreground: root.foreground

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: root.service && root.service.ready
        ? "No GPU detected."
        : "Starting the sampler…"
      color: root.foreground
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      wrapMode: Text.WordWrap
    }
  }
}
