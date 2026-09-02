import QtQuick
import qs.Commons

// Card title line: name in the accent on the left, a quiet detail on the
// right ("CPU" ......... "4.85 GHz, 49°").
Item {
  id: root

  property string title: ""
  property string detail: ""
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.family

  width: parent ? parent.width : implicitWidth
  implicitHeight: Math.max(titleText.implicitHeight, detailText.implicitHeight)
  height: implicitHeight

  Text {
    id: titleText
    textFormat: Text.PlainText
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    text: root.title
    color: Color.accent
    font.family: root.fontFamily
    font.pixelSize: Style.font.subtitle
    font.bold: true
    elide: Text.ElideRight
    width: Math.min(implicitWidth, parent.width - detailText.width - Style.space(8))
  }

  Text {
    id: detailText
    textFormat: Text.PlainText
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    text: root.detail
    color: root.foreground
    opacity: 0.6
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
