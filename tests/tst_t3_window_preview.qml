import QtQuick
import QtTest
import "../components"

// DockWindowPreview is a Quickshell PopupWindow and cannot instantiate under
// qmltestrunner, so this test pins the exact production bindings in source
// and evaluates the real header/footer/accessibility expressions.
TestCase {
  id: testCase
  name: "T3WindowPreview"
  when: windowShown
  width: 320
  height: 240

  function previewSource() {
    var request = new XMLHttpRequest()
    request.open("GET", Qt.resolvedUrl("../components/DockWindowPreview.qml"), false)
    request.send()
    if (!request.responseText) throw new Error("QML_XHR_ALLOW_FILE_READ=1 is required")
    return request.responseText
  }

  function evalOn(rootValues, expression) {
    var body = "return (" + expression.split("root.").join("R.") + ")"
    return (new Function("R", body))(rootValues)
  }

  function lineExpression(source, marker) {
    var lines = source.split("\n")
    for (var i = 0; i < lines.length; i++) {
      var at = lines[i].indexOf(marker)
      if (at >= 0) return lines[i].slice(at + marker.length).trim()
    }
    throw new Error("Binding not found: " + marker)
  }

  function test_productionBindingsPinned() {
    var source = previewSource()
    verify(source.indexOf('property string herdrProduct: "Herdr"') >= 0)
    verify(source.indexOf('property string herdrFocusHint: "Click a row to focus its pane."') >= 0)
    verify(source.indexOf('text: root.herdrFocusHint') >= 0)
    verify(source.indexOf('root.herdrProduct === "T3 Code" ? "Open this T3 thread" : "Focus this Herdr agent pane"') >= 0)
    verify(source.indexOf('function onPreviewHerdrProductChanged()') >= 0)
    verify(source.indexOf('function onPreviewHerdrFocusHintChanged()') >= 0)
    verify(source.indexOf('anchorItem["previewHerdrProduct"]') >= 0)
    verify(source.indexOf('anchorItem["previewHerdrFocusHint"]') >= 0)
  }

  function test_t3HeaderAndFooter() {
    var source = previewSource()
    var header = lineExpression(source, "text: root.herdrLabel ? ")
    var t3 = { herdrLabel: "", herdrProduct: "T3 Code",
      herdrFocusHint: "Click a row to open this thread in T3 Code." }
    compare(evalOn(t3, "root.herdrLabel ? " + header), "T3 Code")
    compare(evalOn(t3, "root.herdrFocusHint"), "Click a row to open this thread in T3 Code.")
    var labeled = { herdrLabel: "proj", herdrProduct: "T3 Code",
      herdrFocusHint: "Click a row to open this thread in T3 Code." }
    compare(evalOn(labeled, "root.herdrLabel ? " + header), "T3 Code · proj")
  }

  function test_herdrHeaderAndFooterUnchanged() {
    var source = previewSource()
    var header = lineExpression(source, "text: root.herdrLabel ? ")
    var herdr = { herdrLabel: "proj", herdrProduct: "Herdr",
      herdrFocusHint: "Click a row to focus its pane." }
    compare(evalOn(herdr, "root.herdrLabel ? " + header), "Herdr · proj")
    compare(evalOn(herdr, "root.herdrFocusHint"), "Click a row to focus its pane.")
    var bare = { herdrLabel: "", herdrProduct: "Herdr",
      herdrFocusHint: "Click a row to focus its pane." }
    compare(evalOn(bare, "root.herdrLabel ? " + header), "Herdr")
  }

  function test_rowAccessibilityHint() {
    var source = previewSource()
    var marker = '(root.herdrProduct === "T3 Code"'
    var start = source.indexOf(marker)
    verify(start >= 0)
    var depth = 0
    var end = start
    for (; end < source.length; end++) {
      if (source[end] === "(") depth++
      else if (source[end] === ")" && --depth === 0) break
    }
    verify(depth === 0)
    var expression = source.slice(start, end + 1)
    compare(evalOn({ herdrProduct: "T3 Code" }, expression), "Open this T3 thread")
    compare(evalOn({ herdrProduct: "Herdr" }, expression), "Focus this Herdr agent pane")
  }
}
