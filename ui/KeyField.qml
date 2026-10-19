import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// A single-line field built from key events instead of Qt's text input.
// Every editable TextInput asks the clipboard for its contents whenever
// another application changes it, so a focused field let any application
// make the shell read what it offered. This one never touches the
// clipboard: it takes typed characters, Backspace and Return, and draws the
// text itself. There is no paste, selection or caret movement, which the
// process search and the hex color fields do not need.
//
// It mirrors the kit TextField's look and the parts of its API those fields
// use: text, placeholderText, maximumLength, horizontalAlignment,
// editingFinished and accepted.
Item {
  id: root

  property string text: ""
  property string placeholderText: ""
  property int maximumLength: 32767
  property int horizontalAlignment: Text.AlignLeft
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property real horizontalPadding: Style.spacing.controlPaddingX
  property real verticalPadding: Style.spacing.inputPaddingY
  property alias font: label.font

  signal accepted()
  signal editingFinished()

  readonly property bool _hot: mouse.containsMouse
  readonly property var _borderSpec: Border.controlSpec(activeFocus ? "focus" : (_hot ? "hover-cursor" : "normal"), root.foreground, root.accent)

  // Typed text from a key event, or "" for anything that is not plain input.
  function typed(event) {
    if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return ""
    var value = String(event.text || "")
    for (var i = 0; i < value.length; i++) if (value.charCodeAt(i) < 32 || value.charCodeAt(i) === 127) return ""
    return value
  }

  activeFocusOnTab: true
  implicitWidth: Style.space(160)
  implicitHeight: label.implicitHeight + 2 * verticalPadding + Border.top(_borderSpec) + Border.bottom(_borderSpec)

  onActiveFocusChanged: if (!activeFocus) editingFinished()

  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Backspace) {
      // Ctrl+Backspace clears, as there is no selection to delete.
      if (event.modifiers & Qt.ControlModifier) root.text = ""
      else root.text = root.text.slice(0, -1)
      event.accepted = true
    } else if (event.key === Qt.Key_U && (event.modifiers & Qt.ControlModifier)) {
      root.text = ""
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.accepted()
      root.editingFinished()
      event.accepted = true
    } else {
      var value = root.typed(event)
      if (value === "") return
      if (root.text.length < root.maximumLength) root.text = (root.text + value).slice(0, root.maximumLength)
      event.accepted = true
    }
  }

  BorderSurface {
    anchors.fill: parent
    color: Style.controlFill(root.activeFocus, root._hot, root.foreground, root.accent)
    borderSpec: root._borderSpec
    radius: Style.cornerRadius
  }

  Item {
    id: inner
    anchors.fill: parent
    anchors.leftMargin: root.horizontalPadding + Border.left(root._borderSpec)
    anchors.rightMargin: root.horizontalPadding + Border.right(root._borderSpec)
    clip: true

    Text {
      id: label
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      // Long text keeps its end, where typing happens, in view.
      x: implicitWidth > inner.width ? inner.width - implicitWidth - caret.width
        : (root.horizontalAlignment === Text.AlignRight ? inner.width - implicitWidth - caret.width
          : (root.horizontalAlignment === Text.AlignHCenter ? (inner.width - implicitWidth) / 2 : 0))
      text: root.text !== "" ? root.text : root.placeholderText
      color: root.text !== "" ? root.foreground : Qt.darker(root.foreground, 1.6)
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    Rectangle {
      id: caret
      visible: root.activeFocus && blink.on
      x: root.text !== "" ? label.x + label.implicitWidth : label.x
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(1, Style.spaceReal(1))
      height: label.font.pixelSize * 1.2
      color: root.foreground
    }
  }

  Timer {
    id: blink
    property bool on: true
    interval: 530
    repeat: true
    running: root.activeFocus
    onRunningChanged: on = true
    onTriggered: on = !on
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.IBeamCursor
    onClicked: root.forceActiveFocus()
  }
}
