.pragma library

// Only compositor popup endpoints are replaced. Area/manager logic, bindings,
// input, timers and helpers are executed from current production source.
function source(name) {
  var request = new XMLHttpRequest()
  request.open("GET", Qt.resolvedUrl("../components/" + name + ".qml"), false)
  request.send()
  if (!request.responseText) throw new Error("QML_XHR_ALLOW_FILE_READ=1 is required")
  return request.responseText
}
function sourceFile(path) {
  var request = new XMLHttpRequest()
  request.open("GET", Qt.resolvedUrl(path), false)
  request.send()
  if (!request.responseText) throw new Error("QML_XHR_ALLOW_FILE_READ=1 is required")
  return request.responseText
}
function balancedBlock(sourceText, start) {
  var open = sourceText.indexOf("{", start)
  if (open < 0) throw new Error("Expected a QML block")
  var depth = 0
  for (var i = open; i < sourceText.length; i++) {
    if (sourceText[i] === "{") depth++
    else if (sourceText[i] === "}" && --depth === 0) return sourceText.slice(start, i + 1)
  }
  throw new Error("Unclosed QML block")
}
function makeHostRegistry(parent, bridge, service) {
  var host = sourceFile("../DockHost.qml")
  var registryStart = host.indexOf("readonly property var sidebarWidgetRegistry:")
  if (registryStart < 0) throw new Error("DockHost sidebarWidgetRegistry binding not found")
  var registry = balancedBlock(host, registryStart)
  var methodStart = host.indexOf("function acquireHerdrWidget(owner)")
  var acquire = methodStart < 0 ? "" : balancedBlock(host, methodStart)
  var componentPath = Qt.resolvedUrl("../components")
  var code = 'import QtQuick\nimport "' + componentPath + '"\n'
    + 'Item { id:root; property var herdrWindowAgents; property var herdrService; '
    + 'function saveSetting(key,value) { return {ok:true,data:{applied:true}} }\n'
    + 'QtObject { id:demoWidgetRegistry; property var descriptors: ({}) }\n'
    + 'QtObject { id:externalWidgetRegistry; property var descriptors: ({}) }\n'
    + 'property alias externalDescriptors: externalWidgetRegistry.descriptors\n'
    + 'Component { id:herdrExpandedView; DockHerdrAgentsView {} }\n'
    + 'Component { id:herdrCompactView; DockHerdrAgentsView {} }\n'
    + 'Component { id:herdrPopupView; DockHerdrAgentsView {} }\n'
    + acquire + '\n' + registry + '\n}'
  var item = Qt.createQmlObject(code, parent, Qt.resolvedUrl("HostRegistryFixture.qml"))
  if (!item) throw new Error("Failed to instantiate production DockHost registry")
  item.herdrWindowAgents = bridge
  item.herdrService = service
  return item
}
function makeArea(parent, properties) {
  var code = source("DockSidebarWidgetArea")
  code = code.replace("import Quickshell\n", "")
  code = code.replace(/^  PopupWindow \{[\s\S]*?^  \}/m,
    '  Item { id:popup; visible:root.ownsPopupAnchor() && root.controller.widgetPopupId !== "" && root.panel.visible\n'
    + 'property QtObject anchor: QtObject { property int updates:0; function updateAnchor(){updates++} }\n'
    + 'onVisibleChanged: geometryTimer.restart()\n  }')
  code = code.replace('import "widgets"', 'import "' + Qt.resolvedUrl('../components/widgets') + '"')
  code = code.replace(/import "(Dock[^"/]+\.js)"/g, function(_,name) { return 'import "' + Qt.resolvedUrl('../components/'+name) + '"' })
  code = code.replace('import QtQuick\n','import QtQuick\nimport "' + Qt.resolvedUrl('../components') + '"\n')
  // Inject required endpoints before bindings evaluate.
  code = code.replace('required property var controller','property var controller: parent.controller')
    .replace('required property var panel','property var panel: parent')
    .replace('required property var viewport','property var viewport: parent.viewport')
    .replace('required property real windowRowHeight','property real windowRowHeight: 34')
  var item = Qt.createQmlObject(code, parent, Qt.resolvedUrl("SplitAreaFixture.qml"))
  Object.keys(properties || {}).forEach(function(key){item[key]=properties[key]})
  return item
}
function makeManager(parent) {
  var code = source("DockSidebarWidgetManager")
  code = code.replace(/^  Ui\.PopupCard \{[\s\S]*?^  \}/m,
    '  Item { id:managerPopup; property QtObject anchor: QtObject { property int updates:0; function updateAnchor(){updates++} } }')
  code = code.replace(/import "(Dock[^"/]+\.js)"/g, function(_,name) { return 'import "'+Qt.resolvedUrl('../components/'+name)+'"' })
  code = code.replace('required property var controller','property var controller: parent.controller')
    .replace('required property var panel','property var panel: parent')
    .replace('required property var viewport','property var viewport: parent.viewport')
  return Qt.createQmlObject(code, parent, Qt.resolvedUrl("SplitManagerFixture.qml"))
}
