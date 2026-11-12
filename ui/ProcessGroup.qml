pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui
import "../Model.js" as Model

FocusScope {
  id: root

  required property Commons.Translations strings
  property var snapshot: null
  property color foreground: Commons.Color.popups.text
  property string fontFamily: Style.font.family

  signal terminateRequested(var member)
  signal windowCloseRequested(var member, var window)
  signal confirmed()
  signal canceled()

  readonly property var details: snapshot ? snapshot.data : null
  readonly property var pending: snapshot ? snapshot.pending : null
  readonly property bool busy: snapshot ? snapshot.busy : false
  readonly property bool confirming: !!pending
  readonly property real rowHeight: Style.space(24)
  readonly property var entries: {
    const rows = []
    for (const member of details ? details.members : []) {
      rows.push({ member: member, window: null })
      for (const window of member.windows) rows.push({ member: member, window: window })
    }
    return rows
  }

  implicitHeight: card.implicitHeight

  function label(key) { return strings.t("processGroup." + key) }

  function countLabel(key, count) {
    return strings.tn("processGroup." + key, count).arg(Commons.I18n.formatNumber(count))
  }

  function statusText() {
    if (!snapshot) return ""
    if (snapshot.loading && !details) return label("loading")
    if (snapshot.result) {
      const status = snapshot.result.status
      if (status === "sent" || status === "skipped") {
        const messages = []
        if (snapshot.result.sent > 0) messages.push(countLabel("sent", snapshot.result.sent))
        if (snapshot.result.skipped > 0) messages.push(countLabel("skipped", snapshot.result.skipped))
        return messages.join(" · ")
      }
      return label(status === "none" ? "noActions" : "failed")
    }
    return details && !details.members.length ? label("empty") : ""
  }

  onConfirmingChanged: if (confirming) Qt.callLater(function() {
    if (root.confirming && root.enabled) cancelButton.forceActiveFocus()
  })

  Keys.onEscapePressed: function(event) {
    event.accepted = root.confirming
    if (root.confirming) root.canceled()
  }

  component Caption: Text {
    width: parent.width
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.Wrap
  }

  component ConfirmationButton: Ui.Button {
    foreground: root.foreground
    fontFamily: root.fontFamily
    fontSize: Style.font.bodySmall
    horizontalPadding: Style.space(8)
    verticalPadding: Style.space(4)
    focusable: true
    bordered: true
    Accessible.role: Accessible.Button
    Accessible.name: text
    Accessible.onPressAction: if (enabled) clicked()
  }

  Card {
    id: card
    height: implicitHeight
    foreground: root.foreground
    padding: Style.space(8)
    spacing: Style.space(4)

    Caption {
      visible: text !== ""
      text: root.statusText()
      opacity: 0.8
    }

    Caption {
      visible: !!root.details && (!root.details.windowsAvailable || root.details.truncated)
      text: root.label(root.details && root.details.truncated ? "truncated" : "windowListUnavailable")
      opacity: 0.8
    }

    Column {
      width: parent.width
      visible: root.confirming
      spacing: Style.space(4)

      Caption {
        text: !root.pending ? "" : root.pending.pid
          ? root.label("terminatePrompt").arg(root.pending.pid)
          : root.label("closeGroupPrompt").arg(root.snapshot.group)
      }

      Caption {
        visible: text !== ""
        opacity: 0.8
        text: {
          if (!root.pending || root.pending.pid) return ""
          const messages = []
          if (root.pending.windows) messages.push(root.countLabel("closeWindows", root.pending.windows))
          if (root.pending.processes) messages.push(root.countLabel("terminateProcesses", root.pending.processes))
          return messages.join(" · ")
        }
      }

      Row {
        anchors.right: parent.right
        spacing: Style.space(6)

        ConfirmationButton {
          id: cancelButton
          text: Commons.I18n.t("common.cancel")
          onClicked: root.canceled()
        }

        ConfirmationButton {
          text: root.pending && root.pending.pid ? root.label("terminate") : root.label("closeGroup")
          accent: Commons.Color.urgent
          onClicked: root.confirmed()
        }
      }
    }

    ListView {
      id: list
      width: parent.width
      visible: count > 0
      height: Math.min(count, 7) * root.rowHeight
      model: root.entries
      clip: true
      interactive: count > 7
      boundsBehavior: Flickable.StopAtBounds
      Controls.ScrollBar.vertical: Controls.ScrollBar { policy: list.interactive ? Controls.ScrollBar.AsNeeded : Controls.ScrollBar.AlwaysOff }

      delegate: Item {
        id: entry
        required property var modelData
        readonly property var member: modelData.member
        readonly property var window: modelData.window
        readonly property bool actionable: !!window || member.canTerminate
        readonly property var memory: Model.bytesParts(member.mem)

        width: list.width - (list.interactive ? Style.space(12) : 0)
        height: root.rowHeight

        Text {
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.leftMargin: entry.window ? Style.space(12) : 0
          anchors.right: memory.visible ? memory.left : action.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: entry.window ? entry.window.title || root.label("untitledWindow") : root.label("pid").arg(entry.member.pid)
          color: root.foreground
          opacity: entry.window ? 0.65 : 0.9
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        Measure {
          id: memory
          visible: !entry.window
          anchors.right: action.left
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          value: entry.memory.value
          unit: entry.memory.unit
          foreground: root.foreground
          fontFamily: root.fontFamily
          bold: false
          valueOpacity: 0.75
        }

        Ui.PanelActionButton {
          id: action
          visible: entry.actionable
          enabled: !root.busy && !root.confirming
          opacity: enabled ? 1 : 0.4
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(22)
          height: parent.height
          fontFamily: root.fontFamily
          fontSize: Style.font.body
          foreground: root.foreground
          hoverColor: Commons.Color.urgent
          iconText: "×"
          tooltipText: root.label(entry.window ? "closeWindow" : "terminateProcess")
          focusable: true
          Accessible.role: Accessible.Button
          Accessible.name: tooltipText
          Accessible.onPressAction: if (enabled) clicked()
          onClicked: {
            if (entry.window) root.windowCloseRequested(entry.member, entry.window)
            else root.terminateRequested(entry.member)
          }
        }
      }
    }
  }
}
