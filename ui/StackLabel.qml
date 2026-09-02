import QtQuick
import qs.Commons

// iStat-style vertical label: the letters of a short name stacked one per
// row, small and bold, so "CPU" reads at a glance without a glyph.
Item {
  id: root

  property string text: ""
  property color color: Color.foreground
  property string fontFamily: Style.font.family
  property real letterSize: Style.spaceReal(10)
  // Rows are spaced by cap height, not line height: these are all capitals,
  // which fill about three quarters of the em box, so packing the rows that
  // tightly lets the letters be large (and therefore thick-stemmed) inside a
  // short strip. `maxHeight` is the budget the letters must fit.
  readonly property real rowFactor: 0.78
  property real maxHeight: 0
  readonly property real fittedSize: maxHeight > 0 && rows > 0
    ? Math.max(6, Math.min(letterSize, Math.floor(maxHeight / rows / rowFactor)))
    : letterSize
  property real rowHeight: Math.round(fittedSize * rowFactor)
  property real letterOpacity: 1.0

  readonly property int rows: text.length

  implicitWidth: Math.ceil(metrics.advanceWidth) + 1
  implicitHeight: rows * rowHeight
  width: implicitWidth
  height: implicitHeight

  TextMetrics {
    id: metrics
    font.family: root.fontFamily
    font.pixelSize: root.fittedSize
    font.bold: true
    text: "W"
  }

  Repeater {
    model: root.rows

    delegate: Text {
      required property int index
      y: index * root.rowHeight
      width: root.width
      height: root.rowHeight
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
      textFormat: Text.PlainText
      text: root.text.charAt(index)
      color: root.color
      opacity: root.letterOpacity
      font.family: root.fontFamily
      font.pixelSize: root.fittedSize
      font.bold: true
      renderType: Text.NativeRendering
    }
  }
}
