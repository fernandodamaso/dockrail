// Headless endpoint fixture; native behavior requires Omarchy qualification.
import QtQuick
import QtQuick.Controls
Column {id:root; property int value:0; property int from:0; property int to:100; property bool hasCursor:false; property alias field:spin; signal modified(int value); SpinBox {id:spin; value:root.value; from:root.from; to:root.to; editable:true; onValueModified:root.modified(value)}}
