import QtQuick
import qs.Commons

// Legend row under a graph: "● User      86%    ● System     2%".
// Items are {color, label, value, unit}; each takes an equal share of
// the width with its figure pushed to the right edge of that share.
Item {
  id: root

  property var items: []
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.family

  width: parent ? parent.width : implicitWidth
  implicitHeight: Style.space(18)
  height: implicitHeight

  Row {
    anchors.fill: parent
    spacing: Style.space(12)

    Repeater {
      model: root.items.length

      delegate: Item {
        required property int index
        readonly property var modelData: root.items[index] || ({})
        readonly property int count: Math.max(1, root.items.length)
        width: (root.width - Style.space(12) * (count - 1)) / count
        height: root.height

        Row {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(6)
          width: Math.min(implicitWidth, parent.width - figure.width - Style.space(6))
          clip: true

          Rectangle {
            width: Style.space(8)
            height: width
            radius: width / 2
            color: modelData.color || root.foreground
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            textFormat: Text.PlainText
            text: modelData.label || ""
            color: root.foreground
            opacity: 0.8
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
          }
        }

        Measure {
          id: figure
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          value: modelData.value === undefined ? "" : String(modelData.value)
          unit: modelData.unit || ""
          foreground: root.foreground
          fontFamily: root.fontFamily
          valueSize: Style.font.bodySmall
          unitSize: Style.font.caption
        }
      }
    }
  }
}
