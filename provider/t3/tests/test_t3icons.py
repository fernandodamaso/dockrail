"""T3 project branding stays bounded, local and consistent with T3's initials."""
import base64
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from t3icons import project_icon


class ProjectIconTests(unittest.TestCase):
    def test_explicit_icon_types(self):
        for icon in (
            {"kind": "emoji", "emoji": "👩🏽‍💻"},
            {"kind": "monogram", "text": "AB", "color": "blue"},
            {"kind": "monogram", "text": "कि", "color": "rose"},
            {"kind": "monogram", "text": "किकि", "color": "green"},
            {"kind": "monogram", "text": "A\u200dB", "color": "blue"},
            {"kind": "monogram", "text": "\U00016ea0", "color": "violet"},
        ):
            with self.subTest(icon=icon):
                self.assertEqual(project_icon({"title": "Example", "projectIcon": icon}), icon)

    def test_lucide_names_and_aliases_resolve_to_local_svg(self):
        for name in ("message-square-dashed", "folder-code", "code-2", "globe-2", "layers-3"):
            with self.subTest(name=name):
                icon = project_icon({"title": "Example", "projectIcon": {
                    "kind": "lucide", "name": name, "color": "rose",
                }})
                self.assertIsInstance(icon, dict)
                self.assertEqual((icon["kind"], icon["name"], icon["color"]), ("lucide", name, "rose"))
                self.assertTrue(icon["source"].startswith("data:image/svg+xml;base64,"))
                svg = base64.b64decode(icon["source"].split(",", 1)[1]).decode()
                self.assertIn('viewBox="0 0 24 24"', svg)
                self.assertNotIn("href=", svg)

    def test_generated_initials_and_colors_match_t3(self):
        for title, text, color in (
            ("dockrail", "DL", "red"),
            ("ComfyUI", "CI", "teal"),
            ("Krea2", "K2", "violet"),
            ("style-studio", "SS", "sky"),
            ("???", "PR", "cyan"),
            (" Ｋｒｅａ２ ", "K2", "violet"),
        ):
            with self.subTest(title=title):
                self.assertEqual(project_icon({"title": title}), {
                    "kind": "monogram", "text": text, "color": color,
                })

    def test_invalid_icons_fall_back_without_loading_provider_paths(self):
        for icon in (None, [], {"kind": "image", "source": "file:///etc/passwd"},
                     {"kind": "lucide", "name": "../../secret", "color": "blue"},
                     {"kind": "lucide", "name": "unknown-future-icon", "color": "blue"},
                     {"kind": "monogram", "text": "<script>", "color": "blue"},
                     {"kind": "monogram", "text": "A" * 33, "color": "blue"},
                     {"kind": "monogram", "text": "\u0301A", "color": "blue"},
                     {"kind": "emoji", "emoji": ""},
                     {"kind": "emoji", "emoji": "x" * 1000}):
            with self.subTest(icon=icon):
                self.assertEqual(project_icon({"title": "dockrail", "projectIcon": icon}), {
                    "kind": "monogram", "text": "DL", "color": "red",
                })
        self.assertIsNone(project_icon(None))

    def test_initials_distinguish_unicode_letters_from_number_characters(self):
        self.assertEqual(project_icon({"title": "ab一z"})["text"], "AZ")
        self.assertEqual(project_icon({"title": "第二项目"})["text"], "第目")


if __name__ == "__main__":
    unittest.main()
