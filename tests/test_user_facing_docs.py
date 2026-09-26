"""Keep public documentation usable without internal project context."""
from pathlib import Path
import re
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
REQUIRED_DOCUMENTS = (
    'README.md',
    'docs/CONFIGURATION.md',
    'docs/CLI_REFERENCE.md',
    'docs/AGENT_CONFIGURATION.md',
    'docs/browser-activity.md',
    'docs/browser-tabs.md',
    'docs/HERDR_DATA_ACCESS.md',
)
# The landing-page task moves the long README reference here. Check it as soon
# as it exists, without forcing that separate relocation into this change.
FUTURE_USER_GUIDE = 'docs/USER_GUIDE.md'
INTERNAL_TICKET = re.compile(r'FDM-[0-9]', re.IGNORECASE)
QUALIFICATION_JARGON = re.compile(
    r'unreleased CLI-first candidate|qualification gate|native qualification',
    re.IGNORECASE,
)


def public_documents(root):
    paths = [root / name for name in REQUIRED_DOCUMENTS]
    guide = root / FUTURE_USER_GUIDE
    if guide.exists():
        paths.append(guide)
    return paths


def internal_references(text):
    """Return line-numbered violations, including link destinations and code."""
    return [
        (number, line)
        for number, line in enumerate(text.splitlines(), start=1)
        if INTERNAL_TICKET.search(line) or QUALIFICATION_JARGON.search(line)
    ]


class UserFacingDocumentationTests(unittest.TestCase):
    def test_required_public_documents_exist(self):
        for name in REQUIRED_DOCUMENTS:
            with self.subTest(document=name):
                self.assertTrue((ROOT / name).is_file(), name)

    def test_public_documents_have_no_internal_tickets_or_qualification_jargon(self):
        for path in public_documents(ROOT):
            with self.subTest(document=str(path.relative_to(ROOT))):
                text = path.read_text(encoding='utf-8')
                self.assertEqual(internal_references(text), [])

    def test_guard_rejects_tickets_in_prose_links_and_code(self):
        for text in (
            'Attention from FDM-809',
            '[Details](https://linear.app/fdamaso/issue/FDM-1019)',
            '```sh\necho FDM-9\n```',
            'Unreleased CLI-first candidate',
            'Run the native qualification gate',
        ):
            with self.subTest(text=text):
                self.assertTrue(internal_references(text))
        self.assertEqual(internal_references('Use dockrail doctor to check readiness.'), [])

    def test_landing_page_user_guide_is_checked_when_present(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            guide = root / FUTURE_USER_GUIDE
            self.assertNotIn(guide, public_documents(root))
            guide.parent.mkdir()
            guide.write_text('Leaked FDM-1019\n', encoding='utf-8')
            self.assertIn(guide, public_documents(root))
            self.assertEqual(internal_references(guide.read_text()), [(1, 'Leaked FDM-1019')])

    def test_readme_states_core_and_optional_requirements_before_install(self):
        text = (ROOT / 'README.md').read_text(encoding='utf-8')
        requirements = text.split('## Requirements\n', 1)[1].split('\n## ', 1)[0]
        self.assertLess(text.index('## Requirements\n'), text.index('## Install\n'))
        for required in ('Omarchy 4.x', 'Quickshell 0.3', 'Python 3',
                         'Herdr 0.9.1+', 'Chrome', 'remote debugging',
                         'CMake', 'C++20', 'Qt 6.6'):
            with self.subTest(requirement=required):
                self.assertIn(required, requirements)

    def test_standalone_install_starts_with_a_clone(self):
        text = (ROOT / 'README.md').read_text(encoding='utf-8')
        standalone = text.split('### Standalone installation\n', 1)[1].split('\n### ', 1)[0]
        self.assertIn(
            'git clone https://github.com/fernandodamaso/dockrail.git && cd dockrail && ./install.sh',
            standalone,
        )

    def test_development_switch_is_in_contributing_not_the_introduction(self):
        text = (ROOT / 'README.md').read_text(encoding='utf-8')
        self.assertIn('## Contributing\n', text)
        intro, contributing = text.split('## Contributing\n', 1)
        self.assertNotIn('dockrail dev use', intro.split('\n## ', 1)[0])
        self.assertIn('dockrail dev use <worktree-path-or-local-branch>', contributing)
        self.assertIn('dockrail dev reset', contributing)
        self.assertIn('docs/DEV_SWITCH.md', contributing)

    def test_plugin_setup_sequence_remains_documented(self):
        text = (ROOT / 'README.md').read_text(encoding='utf-8')
        sequence = (
            'omarchy plugin add https://github.com/fernandodamaso/dockrail.git --enable --yes',
            'bash ~/.config/omarchy/plugins/io.github.fernandodamaso.dockrail/install.sh --cli-only',
            'dockrail setup',
        )
        positions = [text.index(command) for command in sequence]
        self.assertEqual(positions, sorted(positions))
        self.assertIn('Omarchy does not run install hooks', text)
        self.assertIn('omarchy plugin update', text)


if __name__ == '__main__':
    unittest.main()
