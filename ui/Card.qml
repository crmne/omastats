import QtQuick
import qs.Commons

// Grouped surface, the iStat "card": a faint fill with a hairline border
// that groups one topic (a graph and its legend, a list, a set of rings).
Rectangle {
  id: root

  property color foreground: Color.popups.text
  property real padding: Style.space(12)
  property real spacing: Style.space(8)
  default property alias content: column.data

  width: parent ? parent.width : implicitWidth
  implicitHeight: column.implicitHeight + padding * 2
  radius: Style.cornerRadius
  color: Util.alpha(foreground, 0.035)
  border.width: 1
  border.color: Util.alpha(foreground, 0.09)

  Column {
    id: column
    anchors.fill: parent
    anchors.margins: root.padding
    spacing: root.spacing
  }
}
