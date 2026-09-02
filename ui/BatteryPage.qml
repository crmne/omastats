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
  readonly property color good: service ? service.good : Color.accent
  readonly property color warn: service ? service.warn : Color.urgent
  readonly property color danger: service ? service.danger : Color.urgent

  readonly property var battery: snap.battery || ({})
  readonly property bool present: battery.present === true
  readonly property real percent: Model.num(battery.percent)
  readonly property string status: String(battery.status || "Unknown")
  readonly property bool charging: status === "Charging"
  readonly property bool full: status === "Full" || (percent >= 99 && battery.acOnline)
  readonly property var peripherals: Array.isArray(battery.peripherals) ? battery.peripherals : []
  readonly property string timeText: {
    if (charging && battery.timeToFull > 0) return Model.clockText(battery.timeToFull) + " to full"
    if (status === "Discharging" && battery.timeToEmpty > 0) return Model.clockText(battery.timeToEmpty) + " left"
    if (full) return "Fully charged"
    if (status === "Not charging") return "Charge held"
    return charging ? "Charging" : status
  }
  readonly property var chargeHistory: {
    var raw = Array.isArray(hist.battery) ? hist.battery : []
    var flags = Array.isArray(hist.batteryCharging) ? hist.batteryCharging : []
    var onCharge = []
    var onBattery = []
    for (var i = 0; i < raw.length; i++) {
      var isCharging = flags[i] === 1
      onCharge.push(isCharging ? raw[i] : 0)
      onBattery.push(isCharging ? 0 : raw[i])
    }
    return { charging: onCharge, discharging: onBattery }
  }

  function ringColor() {
    if (charging || full) return good
    if (percent <= 10) return danger
    if (percent <= 20) return warn
    return s1
  }

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
          value: root.percent / 100
          color: root.ringColor()
          foreground: root.foreground
          fontFamily: root.fontFamily
          valueText: String(Math.round(root.percent))
          unitText: "%"
          subText: root.timeText
          size: Style.space(88)
        }

        RingGauge {
          visible: isFinite(Number(root.battery.health)) && root.battery.health !== null
          value: Model.num(root.battery.health) / 100
          color: root.s2
          foreground: root.foreground
          fontFamily: root.fontFamily
          valueText: String(Math.round(Model.num(root.battery.health)))
          unitText: "%"
          labelText: "Health"
          size: Style.space(88)
        }
      }
    }
  }

  Card {
    visible: root.flag("showHistory")
    foreground: root.foreground

    CardHeader {
      title: "Charge"
      detail: root.charging ? "Charging" : (root.full ? "Full" : "On battery")
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    HistoryGraph {
      width: parent.width
      height: Style.space(56)
      series: [root.chargeHistory.charging, root.chargeHistory.discharging]
      colors: [root.good, root.s1]
      ceiling: 100
      baselineColor: Util.alpha(root.foreground, 0.14)
    }

    Legend {
      foreground: root.foreground
      fontFamily: root.fontFamily
      items: [
        { color: root.good, label: "Charging", value: "", unit: "" },
        { color: root.s1, label: "On battery", value: "", unit: "" }
      ]
    }
  }

  Card {
    visible: root.flag("showDetails")
    foreground: root.foreground
    spacing: Style.space(2)

    StatRow {
      label: "Status"
      value: root.status
      boldValue: false
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    StatRow {
      visible: Model.num(root.battery.power) > 0
      label: root.charging ? "Charging at" : "Power draw"
      value: Model.num(root.battery.power).toFixed(1)
      unit: "W"
      boldValue: false
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    StatRow {
      visible: Model.num(root.battery.energyFull) > 0
      label: "Capacity"
      detail: Model.num(root.battery.energyDesign) > 0 ? "designed " + Model.num(root.battery.energyDesign).toFixed(1) + " Wh" : ""
      value: Model.num(root.battery.energyFull).toFixed(1)
      unit: "Wh"
      boldValue: false
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    StatRow {
      visible: Model.num(root.battery.cycles) > 0
      label: "Cycles"
      value: String(Math.round(Model.num(root.battery.cycles)))
      boldValue: false
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    StatRow {
      visible: Model.num(root.battery.voltage) > 0
      label: "Voltage"
      value: Model.num(root.battery.voltage).toFixed(2)
      unit: "V"
      boldValue: false
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    StatRow {
      label: "Power adapter"
      value: root.battery.acOnline ? "Connected" : "Unplugged"
      boldValue: false
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    StatRow {
      visible: !!root.battery.model
      label: "Battery"
      value: String(root.battery.model || "")
      boldValue: false
      foreground: root.foreground
      fontFamily: root.fontFamily
    }
  }

  Card {
    visible: root.peripherals.length > 0 && root.flag("showDevices")
    foreground: root.foreground
    spacing: Style.space(2)

    SectionTitle { text: "Devices"; fontFamily: root.fontFamily }

    Repeater {
      model: root.peripherals.length

      delegate: StatRow {
        required property int index
        readonly property var modelData: root.peripherals[index] || ({})
        label: String(modelData.name || "Device")
        detail: String(modelData.status || "") === "Charging" ? "charging" : ""
        value: String(Math.round(Model.num(modelData.percent)))
        unit: "%"
        boldValue: false
        foreground: root.foreground
        fontFamily: root.fontFamily
        trailing: Component {
          MiniRing {
            value: Model.num(modelData.percent) / 100
            color: Model.num(modelData.percent) <= 20 ? root.warn : root.s1
            foreground: root.foreground
            size: Style.space(14)
            thickness: Style.spaceReal(2.2)
          }
        }
      }
    }
  }
}
