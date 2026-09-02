import QtQuick
import qs.Commons

// Ring gauge with a figure in the middle. Either a single `value` (0..1) in
// `color`, or `segments` — an ordered list of {value, color} slices drawn
// clockwise from twelve o'clock with a surface gap between them.
Item {
  id: root

  property real size: Style.space(76)
  property real thickness: Style.space(5)
  property real value: -1
  property color color: Color.accent
  property var segments: []
  property color foreground: Color.popups.text
  property color trackColor: Util.alpha(foreground, 0.10)
  property string fontFamily: Style.font.family
  property string topText: ""
  property string valueText: ""
  property string unitText: ""
  property string labelText: ""
  property string subText: ""
  property real valueSize: Style.font.display
  property real gapPx: 2
  property real animatedValue: Math.max(0, Math.min(1, value))

  Behavior on animatedValue {
    NumberAnimation { duration: 420; easing.type: Easing.OutCubic }
  }

  readonly property var paintSegments: value >= 0
    ? [{ value: animatedValue, color: color }]
    : (Array.isArray(segments) ? segments : [])

  implicitWidth: size
  implicitHeight: size
  width: size
  height: size

  onPaintSegmentsChanged: canvas.requestPaint()
  onTrackColorChanged: canvas.requestPaint()
  onThicknessChanged: canvas.requestPaint()
  onWidthChanged: canvas.requestPaint()
  onHeightChanged: canvas.requestPaint()
  onVisibleChanged: if (visible) canvas.requestPaint()

  Canvas {
    id: canvas
    anchors.fill: parent
    antialiasing: true
    renderStrategy: Canvas.Cooperative

    onPaint: {
      var ctx = getContext("2d")
      ctx.clearRect(0, 0, width, height)
      var r = Math.min(width, height) / 2 - root.thickness / 2
      if (r <= 0) return
      var cx = width / 2
      var cy = height / 2
      ctx.lineWidth = root.thickness
      ctx.lineCap = "butt"
      ctx.strokeStyle = root.trackColor
      ctx.beginPath()
      ctx.arc(cx, cy, r, 0, Math.PI * 2)
      ctx.stroke()

      var segs = root.paintSegments
      var start = -Math.PI / 2
      var gapAngle = root.gapPx / r
      var multi = segs.length > 1
      var filled = 0
      for (var i = 0; i < segs.length; i++) {
        var frac = Math.max(0, Math.min(1 - filled, Number(segs[i].value) || 0))
        if (frac < 0.004) continue
        var a0 = start + filled * Math.PI * 2
        var a1 = a0 + frac * Math.PI * 2
        var from = multi ? a0 + gapAngle / 2 : a0
        var to = multi ? a1 - gapAngle / 2 : a1
        if (to > from) {
          ctx.strokeStyle = segs[i].color
          ctx.lineCap = multi ? "butt" : "round"
          ctx.beginPath()
          ctx.arc(cx, cy, r, from, to)
          ctx.stroke()
        }
        filled += frac
      }
    }
  }

  Column {
    anchors.centerIn: parent
    spacing: 0
    width: root.size - root.thickness * 2 - Style.space(6)

    Text {
      textFormat: Text.PlainText
      visible: root.topText !== ""
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      text: root.topText
      color: root.foreground
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 0.8
      elide: Text.ElideRight
    }

    Item {
      width: parent.width
      height: figure.implicitHeight

      Measure {
        id: figure
        anchors.horizontalCenter: parent.horizontalCenter
        value: root.valueText
        unit: root.unitText
        foreground: root.foreground
        fontFamily: root.fontFamily
        valueSize: root.valueSize
        unitSize: Style.font.bodySmall
        bold: true
      }
    }

    Text {
      textFormat: Text.PlainText
      visible: root.labelText !== ""
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      text: root.labelText
      color: root.foreground
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1
      font.capitalization: Font.AllUppercase
      elide: Text.ElideRight
    }

    Text {
      textFormat: Text.PlainText
      visible: root.subText !== ""
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      text: root.subText
      color: root.foreground
      opacity: 0.55
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }
}
