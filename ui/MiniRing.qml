import QtQuick
import qs.Commons

// Tiny ring for per-core load and per-sensor headroom.
Item {
  id: root

  property real value: 0
  property color color: Color.accent
  property color foreground: Color.popups.text
  property color trackColor: Util.alpha(foreground, 0.12)
  property real size: Style.space(16)
  property real thickness: Style.spaceReal(2.4)
  property real animatedValue: Math.max(0, Math.min(1, value))

  Behavior on animatedValue {
    NumberAnimation { duration: 380; easing.type: Easing.OutCubic }
  }

  implicitWidth: size
  implicitHeight: size
  width: size
  height: size

  onAnimatedValueChanged: canvas.requestPaint()
  onColorChanged: canvas.requestPaint()
  onTrackColorChanged: canvas.requestPaint()
  onWidthChanged: canvas.requestPaint()
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
      var v = root.animatedValue
      if (v <= 0.002) return
      ctx.strokeStyle = root.color
      ctx.lineCap = "round"
      ctx.beginPath()
      ctx.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + v * Math.PI * 2)
      ctx.stroke()
    }
  }
}
