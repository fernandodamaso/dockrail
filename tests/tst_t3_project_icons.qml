import QtQuick
import QtTest
import qs.Commons as Commons
import "../components"

TestCase {
  id: test
  name: "T3ProjectIcons"
  when: windowShown
  visible: true
  width: 320
  height: 160

  Component { id: factory; DockT3ProjectIcon {} }
  Component { id: fallbackFactory; DockHerdrAgentsView { sourceFilter: "t3" } }

  function child(item, name, text) {
    for (var i = 0; i < item.children.length; ++i) {
      if (item.children[i].objectName === name
          && (text === undefined || item.children[i].text === text)) return item.children[i]
      var nested = child(item.children[i], name, text)
      if (nested) return nested
    }
    return null
  }

  function test_emoji_and_monogram_update_live() {
    var item = createTemporaryObject(factory, test, {
      icon: { kind: "emoji", emoji: "🎨" }
    })
    verify(item !== null)
    compare(child(item, "t3-project-text", "🎨").text, "🎨")
    compare(child(item, "t3-project-text").textFormat, Text.PlainText)
    item.icon = { kind: "monogram", text: "CU", color: "blue" }
    compare(child(item, "t3-project-text").text, "CU")
    compare(child(item, "t3-project-monogram-background").visible, true)
    item.icon = { kind: "monogram", text: "कि", color: "rose" }
    compare(child(item, "t3-project-text").text, "कि")
    verify(item.clip)
    item.icon = null
    compare(item.visible, false)
  }

  function test_lucide_decodes_and_uses_project_color() {
    var svg = '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"><circle cx="12" cy="12" r="9" fill="white"/></svg>'
    var item = createTemporaryObject(factory, test, { icon: {
      kind: "lucide", color: "rose", source: "data:image/svg+xml;base64," + Qt.btoa(svg)
    } })
    var glyph = child(item, "t3-project-lucide")
    verify(glyph !== null)
    tryCompare(glyph, "ready", true)
    compare(glyph.tint, item.tint)
    verify(item.width > 0 && item.height > 0)
  }

  function test_light_dark_theme_and_plain_text() {
    var old = Commons.Color.background
    var item = createTemporaryObject(factory, test, {
      icon: { kind: "monogram", text: "AB", color: "blue" }
    })
    Commons.Color.background = "#101010"
    var dark = String(item.tint)
    Commons.Color.background = "#ffffff"
    verify(String(item.tint) !== dark)
    Commons.Color.background = old
  }

  function test_external_image_sources_are_not_loaded() {
    var item = createTemporaryObject(factory, test, { icon: {
      kind: "lucide", color: "blue", source: "file:///etc/passwd"
    } })
    compare(item.localSvg, "")
    compare(child(item, "t3-project-lucide"), null)
  }

  function test_unattached_t3_rows_keep_project_icon() {
    var context = { presentation: "expanded", data: {
        servers: [{ id: "t3:test", source: "t3", health: "live", transport: "local" }],
        agents: [{ id: "thread", serverId: "t3:test", status: "idle", title: "Example",
          workspaceLabel: "ComfyUI", projectIcon: { kind: "emoji", emoji: "🎨" } }]
      } }
    var item = createTemporaryObject(fallbackFactory, test, { width: 240 })
    verify(item !== null)
    // Match the host's binding; creation properties convert arrays to QVariant lists.
    item.widgetContext = Qt.binding(function() { return context })
    compare(item.rows[1].projectIcon.emoji, "🎨")
    verify(child(item, "t3-project-text", "🎨") !== null)
  }
}
