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
  readonly property color s1: service ? service.series1 : Color.accent
  readonly property color s2: service ? service.series2 : Color.accent
  readonly property color warn: service ? service.warn : Color.urgent
  readonly property color danger: service ? service.danger : Color.urgent

  readonly property var cpu: snap.cpu || ({})
  readonly property var gpu: snap.gpu || null
  readonly property var sensors: snap.sensors || ({})
  readonly property var temps: sortedTemps(Array.isArray(sensors.temps) ? sensors.temps : [])
  readonly property var fans: Array.isArray(sensors.fans) ? sensors.fans : []
  readonly property real cpuTemp: Model.num(cpu.temp, NaN)
  readonly property real gpuTemp: gpu && gpu.temp !== null && isFinite(Number(gpu.temp))
    ? Number(gpu.temp)
    : Model.num(sensors.gpuTemp, NaN)
  readonly property var fanSummary: {
    var active = 0
    var sum = 0
    var peak = 0
    for (var i = 0; i < fans.length; i++) {
      var rpm = Model.num(fans[i].rpm)
      if (rpm > 0) { active += 1; sum += rpm; peak = Math.max(peak, rpm) }
    }
    return { active: active, average: active > 0 ? sum / active : 0, peak: peak }
  }

  function chipRank(chip) {
    var order = ["CPU", "GPU", "NVMe", "Drive", "Memory", "Board", "Ethernet", "Wi-Fi", "ACPI"]
    var base = String(chip || "").replace(/\s\d+$/, "")
    var idx = order.indexOf(base)
    return idx < 0 ? order.length : idx
  }

  function sortedTemps(list) {
    var copy = list.slice()
    copy.sort(function(a, b) {
      var ra = chipRank(a.chip), rb = chipRank(b.chip)
      if (ra !== rb) return ra - rb
      return String(a.label).localeCompare(String(b.label))
    })
    return copy
  }

  function tempColor(celsius, max) {
    var limit = max > 0 ? max : 95
    var frac = Model.num(celsius) / limit
    if (frac >= 0.92) return danger
    if (frac >= 0.78) return warn
    return s1
  }

  function fraction(celsius, max) {
    var limit = max > 0 ? max : 100
    return Math.max(0, Math.min(1, Model.num(celsius) / limit))
  }

  function displayLabel(temp) { return Model.sensorLabel(temp) }

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
        spacing: Style.space(18)

        RingGauge {
          visible: isFinite(root.cpuTemp)
          value: root.fraction(root.cpuTemp, 100)
          color: root.tempColor(root.cpuTemp, 95)
          foreground: root.foreground
          fontFamily: root.fontFamily
          topText: "CPU"
          valueText: Model.tempParts(root.cpuTemp, root.temperatureUnit).value
          unitText: "°"
          subText: Model.freqText(root.cpu.mhz)
          valueSize: Style.font.heading
          size: Style.space(84)
        }

        RingGauge {
          visible: isFinite(root.gpuTemp)
          value: root.fraction(root.gpuTemp, 100)
          color: root.tempColor(root.gpuTemp, 90)
          foreground: root.foreground
          fontFamily: root.fontFamily
          topText: "GPU"
          valueText: Model.tempParts(root.gpuTemp, root.temperatureUnit).value
          unitText: "°"
          subText: root.gpu ? Model.freqText(root.gpu.mhz) : ""
          valueSize: Style.font.heading
          size: Style.space(84)
        }

        RingGauge {
          visible: root.fans.length > 0
          value: root.fanSummary.active > 0 ? Math.min(1, root.fanSummary.average / 2400) : 0
          color: root.s2
          foreground: root.foreground
          fontFamily: root.fontFamily
          topText: "Fans"
          valueText: root.fanSummary.active > 0 ? String(Math.round(root.fanSummary.average)) : "Off"
          unitText: root.fanSummary.active > 0 ? "rpm" : ""
          subText: root.fanSummary.active > 0 ? root.fanSummary.active + " of " + root.fans.length + " on" : ""
          valueSize: root.fanSummary.active > 0 ? Style.font.heading : Style.font.title
          size: Style.space(84)
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      visible: !isFinite(root.cpuTemp) && !isFinite(root.gpuTemp) && root.fans.length === 0
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      text: "No hardware sensors found"
      color: root.foreground
      opacity: 0.5
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  Card {
    visible: root.temps.length > 0 && root.flag("showTemperatures")
    foreground: root.foreground
    spacing: Style.space(2)

    SectionTitle { text: "Temperature"; fontFamily: root.fontFamily }

    Repeater {
      model: root.temps.length

      delegate: StatRow {
        required property int index
        readonly property var modelData: root.temps[index] || ({})
        label: root.displayLabel(modelData)
        value: Model.tempParts(modelData.value, root.temperatureUnit).value
        unit: "°"
        boldValue: false
        foreground: root.foreground
        fontFamily: root.fontFamily
        trailing: Component {
          MiniRing {
            value: root.fraction(modelData.value, modelData.max)
            color: root.tempColor(modelData.value, modelData.max)
            foreground: root.foreground
            size: Style.space(14)
            thickness: Style.spaceReal(2.2)
          }
        }
      }
    }
  }

  Card {
    visible: root.fans.length > 0 && root.flag("showFans")
    foreground: root.foreground
    spacing: Style.space(2)

    SectionTitle { text: "Fans"; fontFamily: root.fontFamily }

    Repeater {
      model: root.fans.length

      delegate: StatRow {
        required property int index
        readonly property var modelData: root.fans[index] || ({})
        readonly property real rpm: Model.num(modelData.rpm)
        label: String(modelData.label || "Fan")
        value: rpm > 0 ? String(Math.round(rpm)) : "Off"
        unit: rpm > 0 ? "rpm" : ""
        boldValue: false
        labelOpacity: rpm > 0 ? 0.85 : 0.5
        foreground: root.foreground
        fontFamily: root.fontFamily
        trailing: Component {
          MiniRing {
            value: Math.min(1, rpm / 2400)
            color: root.s2
            foreground: root.foreground
            size: Style.space(14)
            thickness: Style.spaceReal(2.2)
          }
        }
      }
    }
  }
}
