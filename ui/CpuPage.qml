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

  readonly property var cpu: snap.cpu || ({})
  readonly property var gpu: snap.gpu || null
  // One card per GPU the user picked on the Settings page.
  readonly property var gpuCards: flag("showGpu")
    ? Model.selectedGpus(snap, Model.settingValue(settings, "barGpus"))
    : []
  readonly property var procs: snap.procs || null
  readonly property var cores: Array.isArray(cpu.cores) ? cpu.cores : []
  readonly property var efficiency: Array.isArray(cpu.efficiency) ? cpu.efficiency : []
  readonly property bool hybrid: efficiency.length > 0 && efficiency.length < cores.length

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
    foreground: root.foreground

    CardHeader {
      title: "CPU"
      detail: root.headerDetail(root.cpu.mhz, root.cpu.temp)
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    HistoryGraph {
      width: parent.width
      height: Style.space(64)
      series: [root.hist.cpuUser || [], root.hist.cpuSystem || []]
      colors: [root.s1, root.s2]
      ceiling: 100
      baselineColor: Util.alpha(root.foreground, 0.14)
    }

    Legend {
      foreground: root.foreground
      fontFamily: root.fontFamily
      items: [
        { color: root.s1, label: "User", value: Math.round(Model.num(root.cpu.user)), unit: "%" },
        { color: root.s2, label: "System", value: Math.round(Model.num(root.cpu.system)), unit: "%" }
      ]
    }
  }

  Card {
    visible: root.flag("showCores")
    foreground: root.foreground
    spacing: Style.space(10)

    Flow {
      width: parent.width
      spacing: Style.space(6)

      Repeater {
        model: root.cores.length

        delegate: MiniRing {
          required property int index
          value: Model.num(root.cores[index]) / 100
          color: root.efficiency.indexOf(index) >= 0 ? root.s2 : root.s1
          foreground: root.foreground
          size: Style.space(18)
          thickness: Style.spaceReal(2.6)
        }
      }
    }

    Legend {
      foreground: root.foreground
      fontFamily: root.fontFamily
      items: root.hybrid
        ? [
            { color: root.s1, label: "Performance", value: root.cores.length - root.efficiency.length, unit: "" },
            { color: root.s2, label: "Efficiency", value: root.efficiency.length, unit: "" }
          ]
        : [
            { color: root.s1, label: "Cores", value: Model.num(root.cpu.coreCount), unit: "" },
            { color: Util.alpha(root.foreground, 0.25), label: "Threads", value: Model.num(root.cpu.threadCount), unit: "" }
          ]
    }

    Text {
      textFormat: Text.PlainText
      visible: text !== ""
      width: parent.width
      text: String(root.cpu.model || "")
      color: root.foreground
      opacity: 0.45
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }

  Card {
    visible: root.flag("showLoad")
    foreground: root.foreground

    Row {
      width: parent.width

      Column {
        width: parent.width / 2
        spacing: Style.space(3)

        SectionTitle { text: "Load average"; fontFamily: root.fontFamily }

        Text {
          textFormat: Text.PlainText
          text: Model.loadText(root.cpu.load)
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }
      }

      Column {
        width: parent.width / 2
        spacing: Style.space(3)

        SectionTitle { text: "Uptime"; fontFamily: root.fontFamily; anchors.right: parent.right }

        Text {
          textFormat: Text.PlainText
          anchors.right: parent.right
          text: Model.uptimeText(root.cpu.uptime)
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }
      }
    }
  }

  Repeater {
    model: root.gpuCards.length

    delegate: Card {
      id: gpuCard
      required property int index
      readonly property var gpu: root.gpuCards[index] || null
      readonly property bool hasUtil: Model.gpuHasUtil(gpu)

      foreground: root.foreground

      CardHeader {
        // Naming each card only matters once there is more than one.
        title: root.gpuCards.length > 1 ? Model.gpuTitle(gpuCard.gpu) : "GPU"
        detail: gpuCard.gpu ? root.headerDetail(gpuCard.gpu.mhz, gpuCard.gpu.temp) : ""
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      HistoryGraph {
        // A card with no utilisation figure would only draw a flat line.
        visible: gpuCard.hasUtil
        height: visible ? Style.space(48) : 0
        width: parent.width
        series: [Model.gpuHistory(root.hist, Model.gpuId(gpuCard.gpu))]
        colors: [root.s1]
        ceiling: 100
        baselineColor: Util.alpha(root.foreground, 0.14)
      }

      StatRow {
        // The header already names the card when several are listed.
        label: root.gpuCards.length > 1 ? "Load" : (gpuCard.gpu ? Model.gpuTitle(gpuCard.gpu) : "Processor")
        // i915/xe publish no busy counter through sysfs, so say so rather
        // than leaving a bare dash to be read as idle.
        detail: gpuCard.hasUtil ? "" : "load not reported"
        dot: root.s1
        value: gpuCard.hasUtil ? String(Math.round(gpuCard.gpu.util)) : "\u2014"
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
    }
  }

  Card {
    visible: root.flag("showProcesses")
    foreground: root.foreground

    ProcessList {
      host: root.host
      items: root.procs ? (root.procs.cpu || []) : []
      allItems: root.procs ? (root.procs.all || []) : []
      total: root.procs ? Model.num(root.procs.total) : 0
      columns: [{ key: "cpu", kind: "percent", title: "" }]
      emptyText: root.procs ? "Nothing busy" : "Measuring…"
      foreground: root.foreground
      fontFamily: root.fontFamily
    }
  }
}
