import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import "../Model.js" as Model

// iStat-style vertical label: the letters of a short name stacked one per
// row, small and bold, so "CPU" reads at a glance without a glyph.
Item {
  id: root

  property string text: ""
  property color color: Commons.Color.foreground
  property string fontFamily: Style.font.family
  property real letterSize: Style.spaceReal(10)
  // Fit by cap height and keep a physical pixel between baselines. A single
  // text layout avoids each glyph being rounded independently on fractional-
  // scale displays.
  readonly property real rowFactor: 0.78
  readonly property real deviceScale: Model.deviceScale(root.QsWindow.window)
  readonly property real pixelGap: 1 / deviceScale
  readonly property real totalSpacing: Math.max(0, rows - 1) * pixelGap
  property real maxHeight: 0
  readonly property real fittedSize: maxHeight > 0 && rows > 0
    ? Math.max(6, Math.min(letterSize, Math.floor((maxHeight - totalSpacing) / rows / rowFactor)))
    : letterSize
  // Tight bounds come back in whole pixels, rounded outward (7 for a capital
  // 6.29 px tall), so the capital is also measured a hundred times larger;
  // stackRows uses whichever is drawn at this ratio.
  readonly property int metricsScale: 100
  readonly property var geometry: Model.stackRows({
    ascent: -metrics.boundingRect.y,
    top: -metrics.tightBoundingRect.y,
    height: metrics.tightBoundingRect.height,
    outlineTop: -capMetrics.tightBoundingRect.y / metricsScale,
    outlineHeight: capMetrics.tightBoundingRect.height / metricsScale
  }, deviceScale)
  readonly property real rowHeight: geometry.rowHeight
  readonly property real rowStep: geometry.rowStep
  // Capitals sit below the top of the em box. With the rows packed to the
  // ink, that leading is empty space above the first letter. The text moves
  // up by it, snapped to a device pixel, so the letters sit in the middle.
  readonly property real capShift: geometry.shift
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
    renderType: Text.NativeRendering
    text: "W"
  }

  TextMetrics {
    id: capMetrics
    font.family: root.fontFamily
    // A pixel size is a whole number, so match the rounding the text gets.
    font.pixelSize: Math.round(root.fittedSize) * root.metricsScale
    font.bold: true
    text: "W"
  }

  Text {
    y: -root.capShift
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
