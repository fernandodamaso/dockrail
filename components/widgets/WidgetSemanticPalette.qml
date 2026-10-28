import QtQuick
import qs.Commons
import qs.Commons as Commons

// Central semantic palette for Widget primitives. Hue conveys meaning while
// luminance adapts to the active Omarchy background so semantic surfaces remain
// legible across light and dark themes without fixture-specific body colors.
QtObject {
  id: root

  readonly property real backgroundLuminance:
    0.2126 * Commons.Color.background.r + 0.7152 * Commons.Color.background.g + 0.0722 * Commons.Color.background.b
  readonly property bool darkBackground: root.backgroundLuminance < 0.5

  readonly property color danger: Commons.Color.urgent
  readonly property color warning: Qt.hsla(0.115, 0.82, root.darkBackground ? 0.66 : 0.42, 1)
  readonly property color success: Qt.hsla(0.43, 0.62, root.darkBackground ? 0.62 : 0.36, 1)
  readonly property color info: Commons.Color.accent
  readonly property color neutral: Commons.Color.foreground
  // Commons.Color.muted is the sidebar's preferred secondary role. The audited dark/light
  // themes fail WCAG 4.5:1 for normal Widget text on card/stat/input surfaces,
  // and the legacy 0.62 foreground alpha also fails. Keep the preferred token
  // visible for theme propagation/audits, but centralize the required normal-text
  // exception here instead of scattering opacity literals across primitives.
  readonly property color mutedTextBase: Commons.Color.muted
  readonly property color mutedText: Commons.Color.foreground

  function tone(semantic) {
    return semantic === "danger" ? root.danger
      : semantic === "warning" ? root.warning
      : semantic === "success" ? root.success
      : semantic === "info" ? root.info : root.neutral
  }

  function surface(semantic, alpha) {
    return Qt.tint(Commons.Color.background, Util.alpha(root.tone(semantic), alpha))
  }
}
