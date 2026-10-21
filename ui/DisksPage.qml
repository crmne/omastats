import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "../Model.js" as Model

Column {
  id: root

  property var service: null
  property var host: null
  property var settings: ({})
  property string temperatureUnit: "Celsius"
  property bool publicIpEnabled: true
  property color foreground: Commons.Color.popups.text
  property string fontFamily: Style.font.family

  function flag(key) { return Model.flag(settings, key) }

  readonly property var snap: service ? service.snapshot : ({})
  readonly property var hist: service ? service.history : Model.emptyHistory()
  readonly property color s1: service ? service.series1 : Commons.Color.accent
  readonly property color s2: service ? service.series2 : Commons.Color.accent
  readonly property color warn: service ? service.warn : Commons.Color.urgent
  readonly property color danger: service ? service.danger : Commons.Color.urgent
  readonly property color calm: Util.alpha(foreground, 0.55)

  readonly property var disks: snap.disks || ({})
  readonly property var perDisk: disks.perDisk || ({})
  readonly property var volumes: Array.isArray(disks.volumes) ? disks.volumes : []
  readonly property var groups: Model.volumeGroups(volumes)
  readonly property var procs: snap.procs || null
  readonly property real pressureSome: Model.num(disks.pressureSome)
  readonly property real pressureFull: Model.num(disks.pressureFull)
  readonly property bool hasPressure: disks.pressureSome !== undefined && disks.pressureSome !== null

  // The drive the page follows: one clicked here, else the Settings choice.
  // A click lasts while the panel stays open.
  property string picked: ""
  readonly property string source: Model.resolveDisk(snap, Model.settingValue(settings, "disksSource"))
  readonly property string selected: picked !== "" ? picked : source
  readonly property bool singleDisk: selected !== "all" && !!perDisk[selected]
  readonly property var selectedVolume: {
    if (selected === "all") return null
    for (var i = 0; i < volumes.length; i++) if (Model.volumeKey(volumes[i]) === selected) return volumes[i]
    return null
  }
  // A network share has no transfer counters of its own, only processes.
  readonly property bool selectedNetwork: !!selectedVolume && selectedVolume.kind === "network"
  readonly property var load: singleDisk ? perDisk[selected] : null
  readonly property var health: Model.driveHealth(load, pressureFull, !!(selectedVolume && selectedVolume.rotational))

  readonly property real readRate: singleDisk ? Model.num(load.read) : Model.num(disks.read)
  readonly property real writeRate: singleDisk ? Model.num(load.write) : Model.num(disks.write)
  readonly property var readHistory: singleDisk && hist.disks && hist.disks[selected] ? hist.disks[selected].read : (hist.diskRead || [])
  readonly property var writeHistory: singleDisk && hist.disks && hist.disks[selected] ? hist.disks[selected].write : (hist.diskWrite || [])
  readonly property var readParts: Model.rateParts(readRate)
  readonly property var writeParts: Model.rateParts(writeRate)
  readonly property var shownChecks: Model.driveChecks(volumes, selected)
  readonly property var shownProcs: {
    if (!procs) return []
    if (selected === "all") return procs.io || []
    var byDrive = procs.ioByDrive || null
    return byDrive ? (byDrive[selected] || []) : (procs.io || [])
  }

  function select(key) {
    picked = selected === key ? "all" : key
  }

  function openVolume(mount) {
    if (!mount) return
    Util.execArgv(["xdg-open", String(mount)])
    if (host && typeof host.close === "function") host.close()
  }

  function runFix(check) {
    var argv = Model.fixCommand(check)
    if (!argv) return
    Util.execArgv(argv)
    if (host && typeof host.close === "function") host.close()
  }

  function levelColor(level) {
    return level === "danger" ? danger : (level === "warn" ? warn : calm)
  }

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(10)

  Card {
    visible: root.flag("showVolumes")
    foreground: root.foreground
    spacing: Style.space(4)

    Text {
      textFormat: Text.PlainText
      visible: root.volumes.length === 0
      text: "No mounted volumes"
      color: root.foreground
      opacity: 0.5
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Repeater {
      model: root.groups.length

      delegate: Column {
        id: group
        required property int index
        readonly property var groupData: root.groups[index] || ({ items: [] })
        width: parent.width
        spacing: Style.space(4)

        SectionTitle {
          // One group needs no heading.
          visible: root.groups.length > 1
          topPadding: group.index > 0 ? Style.space(8) : 0
          text: group.groupData.title || ""
          fontFamily: root.fontFamily
        }

        Repeater {
          model: group.groupData.items.length

          delegate: Item {
            id: row
            required property int index
            readonly property var modelData: (group.groupData.items[index] || {}).volume || ({})
            readonly property string key: Model.volumeKey(modelData)
            readonly property bool isSelected: root.selected === key
            readonly property real fraction: modelData.size > 0 ? modelData.used / modelData.size : 0
            readonly property string tempText: isFinite(Number(modelData.temp)) && modelData.temp !== null
              ? Model.tempText(modelData.temp, root.temperatureUnit) : ""
            readonly property var checks: Array.isArray(modelData.checks) ? modelData.checks : []
            readonly property var rowHealth: Model.driveHealth(root.perDisk[modelData.disk], root.pressureFull, !!modelData.rotational)
            readonly property string alertLevel: rowHealth.level === "danger" ? "danger" : ((rowHealth.level || checks.length) ? "warn" : "")
            readonly property string alertText: {
              var lines = []
              if (rowHealth.text) lines.push(rowHealth.text)
              for (var i = 0; i < checks.length; i++) lines.push(Model.checkText(checks[i]).title)
              return lines.join("\n")
            }

            width: parent.width
            height: Style.space(34)

            MiniRing {
              id: ring
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              size: Style.space(24)
              thickness: Style.spaceReal(3)
              value: row.fraction
              color: row.fraction >= 0.92 ? root.danger : (row.fraction >= 0.8 ? root.warn : root.s1)
              foreground: root.foreground
            }

            Text {
              textFormat: Text.PlainText
              anchors.centerIn: ring
              text: Math.round(row.fraction * 100)
              color: root.foreground
              opacity: 0.85
              font.family: root.fontFamily
              font.pixelSize: Math.max(7, Style.font.caption - 2)
              font.bold: true
            }

            Column {
              anchors.left: ring.right
              anchors.leftMargin: Style.space(10)
              anchors.right: trailing.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: 0

              Row {
                width: parent.width
                spacing: Style.space(6)

                Text {
                  id: nameText
                  textFormat: Text.PlainText
                  width: Math.min(implicitWidth, parent.width - (alert.visible ? alert.width + parent.spacing : 0))
                  text: Model.volumeName(row.modelData.mount)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  elide: Text.ElideRight
                }

                Text {
                  id: alert
                  visible: row.alertLevel !== ""
                  anchors.verticalCenter: nameText.verticalCenter
                  textFormat: Text.PlainText
                  text: "󰀦"
                  color: root.levelColor(row.alertLevel)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: Model.bytesText(row.modelData.avail) + " available"
                color: root.foreground
                opacity: 0.55
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            Column {
              id: trailing
              anchors.right: openButton.left
              anchors.rightMargin: Style.space(4)
              anchors.verticalCenter: parent.verticalCenter
              spacing: 0

              Measure {
                anchors.right: parent.right
                value: Model.bytesParts(row.modelData.size).value
                unit: Model.bytesParts(row.modelData.size).unit
                foreground: root.foreground
                fontFamily: root.fontFamily
                bold: false
                valueOpacity: 0.85
              }

              Text {
                textFormat: Text.PlainText
                anchors.right: parent.right
                text: [row.modelData.fstype, row.tempText].filter(function(v) { return !!v }).join(" · ")
                color: root.foreground
                opacity: 0.45
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            MouseArea {
              id: hover
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.select(row.key)
            }

            PanelActionButton {
              id: openButton
              z: 1
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰉋"
              tooltipText: "Open in Files"
              property bool pointed: false
              opacity: hover.containsMouse || pointed ? 1 : 0.35
              onHovered: function(isHovered) { pointed = isHovered }
              foreground: root.foreground
              fontFamily: root.fontFamily
              size: Style.space(22)
              onClicked: root.openVolume(row.modelData.mount)
            }

            Rectangle {
              anchors.fill: parent
              anchors.leftMargin: -Style.space(6)
              anchors.rightMargin: -Style.space(6)
              z: -1
              radius: Style.cornerRadius
              color: row.isSelected
                ? Util.alpha(Commons.Color.accent, 0.16)
                : (hover.containsMouse ? Style.hoverFillFor(root.foreground, Commons.Color.accent) : "transparent")
            }

            PanelToolTip {
              visible: hover.containsMouse
              text: [row.modelData.model, row.modelData.device, row.modelData.mount, row.alertText].filter(function(v) { return !!v }).join("\n")
                + (row.isSelected ? "\nClick to show all disks" : "\nClick to show this drive")
              fontFamily: root.fontFamily
            }
          }
        }
      }
    }
  }

  Card {
    visible: root.flag("showActivity")
    foreground: root.foreground

    CardHeader {
      title: root.selected === "all" ? "All disks" : Model.volumeName(root.selectedVolume ? root.selectedVolume.mount : root.selected)
      detail: {
        if (root.selected === "all") return ""
        var v = root.selectedVolume
        if (root.selectedNetwork) return v.device || ""
        return root.selected + (v && v.model ? " · " + v.model : "")
      }
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Text {
      visible: root.selectedNetwork
      width: parent.width
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: "Network shares have no transfer counters on this side. The processes below have files open on it."
      color: root.foreground
      opacity: 0.55
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Row {
      visible: !root.selectedNetwork
      width: parent.width

      BigStat {
        width: parent.width / 2
        value: root.readParts.value
        unit: root.readParts.unit
        label: "Read"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      BigStat {
        width: parent.width / 2
        value: root.writeParts.value
        unit: root.writeParts.unit
        label: "Write"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }
    }

    MirrorGraph {
      id: graph
      visible: !root.selectedNetwork
      width: parent.width
      height: Style.space(72)
      up: root.readHistory
      down: root.writeHistory
      upColor: root.s2
      downColor: root.s1
      floor: 262144
      midlineColor: Util.alpha(root.foreground, 0.18)
    }

    Legend {
      visible: !root.selectedNetwork
      foreground: root.foreground
      fontFamily: root.fontFamily
      items: [
        { color: root.s2, label: "Read peak", value: Model.rateParts(graph.peakUp).value, unit: Model.rateParts(graph.peakUp).unit },
        { color: root.s1, label: "Write peak", value: Model.rateParts(graph.peakDown).value, unit: Model.rateParts(graph.peakDown).unit }
      ]
    }

    // How long each request takes, how many wait, and how much of the time
    // the drive is working. Rising latency with a deep queue is a drive that
    // cannot keep up.
    Legend {
      visible: root.singleDisk
      foreground: root.foreground
      fontFamily: root.fontFamily
      items: root.load ? [
        { color: root.levelColor(root.health.level), label: "Latency",
          value: Model.latencyText(root.load.latency).replace(/ ms$/, ""), unit: root.load.latency === null || root.load.latency === undefined ? "" : "ms" },
        { color: root.levelColor(root.health.level), label: "Queue", value: Model.num(root.load.queue).toFixed(1), unit: "" },
        { color: root.levelColor(root.health.level), label: "Busy", value: Math.round(Model.num(root.load.busy)), unit: "%" }
      ] : []
    }

    // The kernel's own measure of time lost waiting for storage, for the
    // whole system: "some" when any task waits, "all" when every one does.
    // High "all" is the desktop freezing.
    Legend {
      visible: root.hasPressure
      foreground: root.foreground
      fontFamily: root.fontFamily
      items: [
        { color: Model.pressureColor(root.pressureSome, root.calm, root.warn, root.danger), label: "I/O waits", value: Math.round(root.pressureSome), unit: "%" },
        { color: Model.pressureColor(root.pressureFull, root.calm, root.warn, root.danger), label: "All stalled", value: Math.round(root.pressureFull), unit: "%" }
      ]
    }

    Text {
      visible: root.health.text !== ""
      width: parent.width
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: root.health.text
      color: root.levelColor(root.health.level)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  Card {
    visible: root.shownChecks.length > 0
    foreground: root.foreground
    spacing: Style.space(10)

    SectionTitle {
      text: root.shownChecks.length === 1 ? "1 problem" : root.shownChecks.length + " problems"
      fontFamily: root.fontFamily
    }

    Repeater {
      model: root.shownChecks.length

      delegate: Item {
        id: checkRow
        required property int index
        readonly property var entry: root.shownChecks[index] || ({})
        readonly property var words: Model.checkText(entry.check)
        readonly property var command: Model.fixCommand(entry.check)

        width: parent.width
        height: Math.max(checkText.implicitHeight, fixButton.visible ? fixButton.implicitHeight : 0)

        Column {
          id: checkText
          anchors.left: parent.left
          anchors.right: fixButton.visible ? fixButton.left : parent.right
          anchors.rightMargin: fixButton.visible ? Style.space(10) : 0
          spacing: Style.space(2)

          Text {
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: checkRow.words.title + "  ·  " + Model.volumeName(checkRow.entry.volume ? checkRow.entry.volume.mount : "")
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: checkRow.words.detail
            color: root.foreground
            opacity: 0.65
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        Button {
          id: fixButton
          visible: !!checkRow.command
          anchors.right: parent.right
          anchors.top: parent.top
          text: checkRow.words.fixLabel
          tooltipText: "Opens a terminal that shows each command and asks before running it"
          bordered: true
          foreground: root.foreground
          fontFamily: root.fontFamily
          fontSize: Style.font.bodySmall
          onClicked: root.runFix(checkRow.entry.check)
        }
      }
    }
  }

  Card {
    visible: root.flag("showProcesses")
    foreground: root.foreground

    ProcessList {
      host: root.host
      items: root.shownProcs
      allItems: root.procs ? (root.procs.all || []) : []
      total: root.procs ? Model.num(root.procs.total) : 0
      sortKey: "io"
      caption: root.selected === "all" ? "" : "files open here"
      columns: [
        { key: "read", kind: "rate", title: "Read" },
        { key: "write", kind: "rate", title: "Write" }
      ]
      columnWidth: Style.space(70)
      emptyText: root.procs ? (root.selected === "all" ? "No disk activity" : "Nothing here is reading or writing") : "Measuring…"
      foreground: root.foreground
      fontFamily: root.fontFamily
    }
  }
}
