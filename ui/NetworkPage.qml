import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
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
  property string copiedValue: ""

  readonly property var snap: service ? service.snapshot : ({})
  readonly property var hist: service ? service.history : Model.emptyHistory()
  readonly property color s1: service ? service.series1 : Color.accent
  readonly property color s2: service ? service.series2 : Color.accent

  readonly property var net: snap.net || ({})
  readonly property var connections: Array.isArray(net.procs) ? net.procs : []
  readonly property var ifaces: Array.isArray(net.ifaces) ? net.ifaces : []
  readonly property var primary: {
    for (var i = 0; i < ifaces.length; i++) if (ifaces[i].default) return ifaces[i]
    for (var j = 0; j < ifaces.length; j++) if (ifaces[j].up) return ifaces[j]
    return ifaces.length > 0 ? ifaces[0] : null
  }
  readonly property var shownIfaces: {
    var out = []
    for (var i = 0; i < ifaces.length; i++) if (ifaces[i].up || ifaces[i].default || ifaces[i].wireless) out.push(ifaces[i])
    return out
  }
  readonly property var upParts: Model.rateParts(net.tx)
  readonly property var downParts: Model.rateParts(net.rx)
  readonly property var addresses: {
    var out = []
    if (!primary) return out
    var v4 = Array.isArray(primary.ipv4) ? primary.ipv4 : []
    var v6 = Array.isArray(primary.ipv6) ? primary.ipv6 : []
    for (var i = 0; i < v4.length; i++) out.push(v4[i])
    for (var j = 0; j < Math.min(2, v6.length); j++) out.push(v6[j])
    return out
  }

  function copy(text) {
    if (!text) return
    Quickshell.execDetached(["/usr/bin/wl-copy", "--", String(text)])
    copiedValue = text
    copiedTimer.restart()
  }

  Timer {
    id: copiedTimer
    interval: 1400
    onTriggered: root.copiedValue = ""
  }

  function lookupPublicIp() {
    if (service && publicIpEnabled) service.requestPublicIp(false)
  }

  Component.onCompleted: lookupPublicIp()
  onServiceChanged: lookupPublicIp()
  onPublicIpEnabledChanged: lookupPublicIp()

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(10)

  Card {
    foreground: root.foreground

    Row {
      width: parent.width

      BigStat {
        width: parent.width / 2
        value: root.upParts.value
        unit: root.upParts.unit
        label: "Upload"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      BigStat {
        width: parent.width / 2
        value: root.downParts.value
        unit: root.downParts.unit
        label: "Download"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }
    }

    MirrorGraph {
      id: graph
      width: parent.width
      height: Style.space(72)
      up: root.hist.netTx || []
      down: root.hist.netRx || []
      upColor: root.s2
      downColor: root.s1
      floor: 10240
      midlineColor: Util.alpha(root.foreground, 0.18)
    }

    Legend {
      foreground: root.foreground
      fontFamily: root.fontFamily
      items: [
        { color: root.s2, label: "Peak ↑", value: Model.rateParts(graph.peakUp).value, unit: Model.rateParts(graph.peakUp).unit },
        { color: root.s1, label: "Peak ↓", value: Model.rateParts(graph.peakDown).value, unit: Model.rateParts(graph.peakDown).unit }
      ]
    }
  }

  Card {
    visible: root.flag("showInterfaces") || root.flag("showTotals")
    foreground: root.foreground
    spacing: Style.space(4)

    Text {
      textFormat: Text.PlainText
      visible: root.flag("showInterfaces") && root.shownIfaces.length === 0
      text: "No network interfaces"
      color: root.foreground
      opacity: 0.5
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Repeater {
      model: root.flag("showInterfaces") ? root.shownIfaces.length : 0

      delegate: Item {
        id: row
        required property int index
        readonly property var modelData: root.shownIfaces[index] || ({})
        readonly property string status: modelData.up
          ? (Model.linkSpeedText(modelData) || "Connected")
          : "Disconnected"
        readonly property string name: modelData.wireless && modelData.ssid
          ? modelData.ssid
          : modelData.name

        width: parent.width
        height: Style.space(26)
        opacity: modelData.up ? 1 : 0.5

        Text {
          id: icon
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: Model.ifaceIcon(row.modelData)
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.icon
        }

        Text {
          anchors.left: icon.right
          anchors.leftMargin: Style.space(10)
          anchors.right: state.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: row.name + (row.modelData.wireless && row.modelData.ssid ? "  " + row.modelData.name : "")
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: row.modelData.default === true
          elide: Text.ElideRight
        }

        Text {
          id: state
          textFormat: Text.PlainText
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: row.status + (row.modelData.wireless && isFinite(Number(row.modelData.dbm)) ? " · " + row.modelData.dbm + " dBm" : "")
          color: root.foreground
          opacity: 0.6
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
    }

    PanelSeparator {
      visible: !!root.primary && root.flag("showInterfaces") && root.flag("showTotals")
      foreground: root.foreground
    }

    StatRow {
      visible: !!root.primary && root.flag("showTotals")
      label: "Received"
      detail: "since boot"
      value: root.primary ? Model.bytesParts(root.primary.rxTotal).value : ""
      unit: root.primary ? Model.bytesParts(root.primary.rxTotal).unit : ""
      boldValue: false
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    StatRow {
      visible: !!root.primary && root.flag("showTotals")
      label: "Sent"
      detail: "since boot"
      value: root.primary ? Model.bytesParts(root.primary.txTotal).value : ""
      unit: root.primary ? Model.bytesParts(root.primary.txTotal).unit : ""
      boldValue: false
      foreground: root.foreground
      fontFamily: root.fontFamily
    }
  }

  Card {
    visible: root.publicIpEnabled
    foreground: root.foreground
    spacing: Style.space(4)

    SectionTitle { text: "Public IP address"; fontFamily: root.fontFamily }

    AddressRow {
      value: root.net.publicIp || ""
      placeholder: root.net.online === false ? "Offline" : "Looking up…"
    }
  }

  Card {
    visible: root.flag("showAddresses")
    foreground: root.foreground
    spacing: Style.space(4)

    SectionTitle {
      text: "IP addresses" + (root.primary ? " · " + root.primary.name : "")
      fontFamily: root.fontFamily
    }

    Text {
      textFormat: Text.PlainText
      visible: root.addresses.length === 0
      text: "No address assigned"
      color: root.foreground
      opacity: 0.5
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Repeater {
      model: root.addresses.length
      delegate: AddressRow {
        required property int index
        value: String(root.addresses[index] || "")
      }
    }
  }

  Card {
    visible: root.flag("showProcesses")
    foreground: root.foreground

    ProcessList {
      host: root.host
      title: "Processes"
      caption: "TCP traffic per process from the kernel's socket counters. QUIC and other UDP traffic cannot be attributed without root."
      items: root.connections.slice(0, 6)
      allItems: root.connections
      total: root.connections.length
      sortKey: "net"
      columns: [
        { key: "rx", kind: "rate", title: "Down" },
        { key: "tx", kind: "rate", title: "Up" }
      ]
      columnWidth: Style.space(70)
      emptyText: net.procs === null || net.procs === undefined ? "Measuring…" : "No traffic"
      foreground: root.foreground
      fontFamily: root.fontFamily
    }
  }

  // Click-to-copy line for an address.
  component AddressRow: Item {
    id: addr

    property string value: ""
    property string placeholder: "—"
    readonly property bool copied: root.copiedValue !== "" && root.copiedValue === value

    width: parent ? parent.width : implicitWidth
    height: Style.space(22)

    Rectangle {
      anchors.fill: parent
      anchors.leftMargin: -Style.space(6)
      anchors.rightMargin: -Style.space(6)
      radius: Style.cornerRadius
      color: mouse.containsMouse && addr.value !== "" ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
    }

    Text {
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.right: hint.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: addr.value !== "" ? addr.value : addr.placeholder
      color: root.foreground
      opacity: addr.value !== "" ? 0.92 : 0.45
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideMiddle
    }

    Text {
      id: hint
      textFormat: Text.PlainText
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: addr.copied ? "Copied" : "󰆏"
      visible: addr.value !== "" && (mouse.containsMouse || addr.copied)
      color: root.foreground
      opacity: addr.copied ? 0.9 : 0.5
      font.family: root.fontFamily
      font.pixelSize: addr.copied ? Style.font.caption : Style.font.icon
    }

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: addr.value !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: root.copy(addr.value)
    }
  }
}
