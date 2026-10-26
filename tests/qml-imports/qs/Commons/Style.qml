pragma Singleton
import QtQuick

QtObject {
  property int cornerRadius: 8
  readonly property int normalBorderWidth: 1
  readonly property QtObject font: QtObject {
    readonly property string family: "Sans Serif"
    readonly property int title: 18
    readonly property int body: 14
    readonly property int bodySmall: 12
    readonly property int caption: 10
    readonly property int icon: 16
  }

  function space(value) {
    return Number(value)
  }
}
