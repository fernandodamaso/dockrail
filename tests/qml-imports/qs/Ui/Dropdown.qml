// Headless endpoint fixture; native behavior requires Omarchy qualification.
import QtQuick
import QtQuick.Controls
// Mirrors the native selectCurrent contract: the control assigns its own value
// before emitting changed, so QML must re-establish any binding afterwards.
ComboBox {id:root; property var options:[]; property string value:""; property bool hasCursor:false; readonly property bool popupOpen:popup.opened; signal changed(string value); function open(){popup.open()} function close(){popup.close()} model:options; textRole:"label"; onActivated:{root.value=options[currentIndex].value;changed(options[currentIndex].value)}}
