import QtQuick
import qs.Commons

// Bidirectional bar history for send/receive and read/write: `up` grows
// from the midline upward, `down` grows from it downward, both on one
// shared scale so the eye can compare them.
Canvas {
  id: root

  property var up: []
  property var down: []
  property color upColor: Color.accent
  property color downColor: Color.accent
  property real floor: 10240      // 10 KB/s keeps an idle link from looking busy
  property real headroom: 1.08
  property int barWidth: 2
  property int gap: 1
  property color midlineColor: Util.alpha(Color.popups.text, 0.18)

  readonly property int pitch: Math.max(1, barWidth + gap)
  readonly property int capacity: Math.max(1, Math.floor((width + gap) / pitch))
  readonly property real peakUp: computePeak(up)
  readonly property real peakDown: computePeak(down)

  function computePeak(list) {
    if (!Array.isArray(list)) return 0
    var start = Math.max(0, list.length - capacity)
    var m = 0
    for (var i = start; i < list.length; i++) if (list[i] > m) m = list[i]
    return m
  }

  antialiasing: false
  renderStrategy: Canvas.Cooperative

  onUpChanged: requestPaint()
  onDownChanged: requestPaint()
  onUpColorChanged: requestPaint()
  onDownColorChanged: requestPaint()
  onWidthChanged: requestPaint()
  onHeightChanged: requestPaint()
  onMidlineColorChanged: requestPaint()
  onVisibleChanged: if (visible) requestPaint()

  onPaint: {
    var ctx = getContext("2d")
    ctx.clearRect(0, 0, width, height)
    if (width <= 0 || height <= 0) return

    var dpr = (Screen && Screen.devicePixelRatio) ? Screen.devicePixelRatio : 1
    var snap = function(v) { return Math.round(v * dpr) / dpr }
    var n = root.capacity
    var upList = Array.isArray(root.up) ? root.up : []
    var downList = Array.isArray(root.down) ? root.down : []
    var len = Math.max(upList.length, downList.length)
    var mid = snap(height / 2)
    var half = Math.max(1, mid - 1)
    var max = Math.max(Number(root.floor) || 1, root.peakUp, root.peakDown) * root.headroom

    var paint = function(list, color, direction) {
      ctx.fillStyle = color
      for (var b = 0; b < n; b++) {
        var idx = len - n + b
        if (idx < 0) continue
        var v = Number(list[idx]) || 0
        if (v <= 0) continue
        var h = Math.min(half, v / max * half)
        if (h < 1 / dpr) h = 1 / dpr
        var x = snap(width - (n - b) * root.pitch + root.gap)
        var w = Math.max(1 / dpr, snap(root.barWidth))
        if (direction < 0) {
          var top = snap(mid - h)
          ctx.fillRect(x, top, w, mid - top)
        } else {
          var bottom = snap(mid + 1 + h)
          ctx.fillRect(x, mid + 1, w, bottom - (mid + 1))
        }
      }
    }

    paint(upList, root.upColor, -1)
    paint(downList, root.downColor, 1)

    ctx.fillStyle = root.midlineColor
    ctx.fillRect(0, mid, width, 1)
  }
}
