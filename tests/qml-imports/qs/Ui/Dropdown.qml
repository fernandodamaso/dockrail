// Headless endpoint fixture; native behavior requires Omarchy qualification.
import QtQuick
import QtQuick.Controls
ComboBox {id:root; property var options:[]; property string value:""; property bool hasCursor:false; readonly property bool popupOpen:popup.opened; signal changed(string value); function open(){popup.open()} function close(){popup.close()} model:options; textRole:"label"; onActivated:changed(options[currentIndex].value)}
