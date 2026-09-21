import QtQuick
import QtQuick.Window
import qs.Commons

// iStat-style vertical label: the letters of a short name stacked one per
// row, small and bold, so "CPU" reads at a glance without a glyph.
Item {
  id: root

  property string text: ""
  property color color: Color.foreground
  property string fontFamily: Style.font.family
  property real letterSize: Style.spaceReal(10)
  // Fit by cap height and keep a physical pixel between baselines. A single
  // text layout avoids each glyph being rounded independently on fractional-
  // scale displays.
  readonly property real rowFactor: 0.78
  readonly property real deviceScale: Screen.devicePixelRatio > 0 ? Screen.devicePixelRatio : 1
  readonly property real pixelGap: 1 / deviceScale
  readonly property real totalSpacing: Math.max(0, rows - 1) * pixelGap
  property real maxHeight: 0
  readonly property real fittedSize: maxHeight > 0 && rows > 0
    ? Math.max(6, Math.min(letterSize, Math.floor((maxHeight - totalSpacing) / rows / rowFactor)))
    : letterSize
  readonly property real rowHeight: Math.ceil(metrics.tightBoundingRect.height * deviceScale) / deviceScale
  readonly property real rowStep: (Math.ceil(rowHeight * deviceScale) + 1) / deviceScale
  property real letterOpacity: 1.0

  readonly property int rows: text.length
  readonly property string stackedText: text.split("").join("\n")

  implicitWidth: Math.ceil(metrics.advanceWidth) + 1
  implicitHeight: rows > 0 ? rowHeight + (rows - 1) * rowStep : 0
  width: implicitWidth
  height: implicitHeight

  TextMetrics {
    id: metrics
    font.family: root.fontFamily
    font.pixelSize: root.fittedSize
    font.bold: true
    text: "W"
  }

  Text {
    width: root.width
    height: root.height
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignTop
    textFormat: Text.PlainText
    text: root.stackedText
    color: root.color
    opacity: root.letterOpacity
    font.family: root.fontFamily
    font.pixelSize: root.fittedSize
    font.bold: true
    lineHeightMode: Text.FixedHeight
    lineHeight: root.rowStep
    renderType: Text.NativeRendering
  }
}
