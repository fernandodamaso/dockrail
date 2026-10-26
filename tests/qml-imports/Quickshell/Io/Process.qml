import QtQuick
Item {
  property var command: []
  property bool running: false
  property var stdout: null
  property var stderr: null
  signal exited(int exitCode)
}
