import QtQuick
import qs.Commons
import qs.Commons as Commons

Canvas {
  id: root
  property var values: []
  property color lineColor: Commons.Color.accent
  property real lineWidth: 2

  implicitWidth: 120
  implicitHeight: 34

  onValuesChanged: requestPaint()
  onWidthChanged: requestPaint()
  onHeightChanged: requestPaint()

  onPaint: {
    var ctx = getContext("2d")
    ctx.clearRect(0, 0, width, height)
    if (!root.values || root.values.length < 2 || width <= 0 || height <= 0) return
    var min = Number(root.values[0])
    var max = min
    for (var i = 1; i < root.values.length; ++i) {
      var value = Number(root.values[i])
      min = Math.min(min, value)
      max = Math.max(max, value)
    }
    var range = Math.max(0.0001, max - min)
    ctx.beginPath()
    ctx.strokeStyle = root.lineColor
    ctx.lineWidth = root.lineWidth
    for (var n = 0; n < root.values.length; ++n) {
      var x = n * width / (root.values.length - 1)
      var y = height - ((Number(root.values[n]) - min) / range) * Math.max(1, height - 2) - 1
      if (n === 0) ctx.moveTo(x, y)
      else ctx.lineTo(x, y)
    }
    ctx.stroke()
  }
}