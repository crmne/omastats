import QtQuick
import qs.Commons

// A number and its unit set as one figure: "47.1" in the text colour with a
// smaller, quieter "MB/s" hanging off its baseline. Units never wear the
// data colour — identity comes from the dot beside the row, not the text.
Row {
  id: root

  property string value: ""
  property string unit: ""
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.family
  property real valueSize: Style.font.body
  property real unitSize: Style.font.caption
  property bool bold: true
  property real unitOpacity: 0.55
  property real valueOpacity: 1.0

  spacing: (unit === "%" || unit === "°" || unit === "") ? 0 : Style.space(3)

  Text {
    id: valueText
    textFormat: Text.PlainText
    text: root.value
    color: root.foreground
    opacity: root.valueOpacity
    font.family: root.fontFamily
    font.pixelSize: root.valueSize
    font.bold: root.bold
  }

  Text {
    textFormat: Text.PlainText
    visible: root.unit !== ""
    text: root.unit
    color: root.foreground
    opacity: root.unitOpacity
    font.family: root.fontFamily
    font.pixelSize: root.unitSize
    font.bold: false
    anchors.baseline: valueText.baseline
  }
}
