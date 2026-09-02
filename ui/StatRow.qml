import QtQuick
import qs.Commons

// One "label ....... value unit" line, optionally keyed by a colour dot on
// the left and finished by a trailing control (a mini ring) on the right.
Item {
  id: root

  property string label: ""
  property string detail: ""
  property string value: ""
  property string unit: ""
  property color dot: "transparent"
  property bool showDot: dot.a > 0
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.family
  property real labelOpacity: 0.85
  property bool boldValue: true
  property Component trailing: null
  property real rowHeight: Style.space(20)

  readonly property real dotInset: showDot ? Style.space(8) + Style.space(7) : 0
  readonly property real detailInset: detailText.visible ? detailText.implicitWidth + Style.space(7) : 0
  readonly property real labelBudget: Math.max(0, width - right.width - Style.space(10) - dotInset - detailInset)

  width: parent ? parent.width : implicitWidth
  implicitHeight: Math.max(rowHeight, labelText.implicitHeight)
  height: implicitHeight

  Rectangle {
    id: dotMark
    visible: root.showDot
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    width: Style.space(8)
    height: width
    radius: width / 2
    color: root.dot
  }

  Text {
    id: labelText
    textFormat: Text.PlainText
    anchors.left: parent.left
    anchors.leftMargin: root.dotInset
    anchors.verticalCenter: parent.verticalCenter
    width: Math.min(implicitWidth, root.labelBudget)
    text: root.label
    color: root.foreground
    opacity: root.labelOpacity
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    elide: Text.ElideRight
  }

  Text {
    id: detailText
    textFormat: Text.PlainText
    visible: root.detail !== ""
    anchors.left: labelText.right
    anchors.leftMargin: Style.space(7)
    anchors.verticalCenter: parent.verticalCenter
    text: root.detail
    color: root.foreground
    opacity: 0.45
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Row {
    id: right
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(8)

    Measure {
      value: root.value
      unit: root.unit
      foreground: root.foreground
      fontFamily: root.fontFamily
      bold: root.boldValue
      anchors.verticalCenter: parent.verticalCenter
    }

    Loader {
      sourceComponent: root.trailing
      anchors.verticalCenter: parent.verticalCenter
      visible: status === Loader.Ready
    }
  }
}
