import QtQuick
import qs.Commons

// Headline figure with a caption under it: "47.1 MB/s" over "Read".
Column {
  id: root

  property string value: ""
  property string unit: ""
  property string label: ""
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.family
  property int align: Text.AlignHCenter

  spacing: 0

  Item {
    width: parent.width
    height: figure.implicitHeight

    Measure {
      id: figure
      anchors.horizontalCenter: root.align === Text.AlignHCenter ? parent.horizontalCenter : undefined
      anchors.left: root.align === Text.AlignLeft ? parent.left : undefined
      anchors.right: root.align === Text.AlignRight ? parent.right : undefined
      value: root.value
      unit: root.unit
      foreground: root.foreground
      fontFamily: root.fontFamily
      valueSize: Style.font.heading
      unitSize: Style.font.bodySmall
    }
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    horizontalAlignment: root.align
    text: root.label
    color: root.foreground
    opacity: 0.55
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    elide: Text.ElideRight
  }
}
