from pathlib import Path
import subprocess

root = Path.cwd()
assert subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip() == 'b240c3612f4e7581ed0a3474a574685ade2e94ca'
paths = ['README.md', 'docs/CONFIGURATION.md', 'docs/CLI_REFERENCE.md',
         'docs/AGENT_CONFIGURATION.md', 'docs/HERDR_DATA_ACCESS.md',
         'docs/browser-activity.md']
texts = {p: (root / p).read_text() for p in paths}

def replace(path, old, new, count=1):
    actual = texts[path].count(old)
    if actual != count:
        raise ValueError(f'{path}: expected {count} copies, got {actual}: {old[:100]!r}')
    texts[path] = texts[path].replace(old, new)

p = 'README.md'
note = ('Want to try an unmerged version on your desktop? Use\n'
        '`dockrail dev use <worktree-path-or-local-branch>`, then `dockrail dev reset`\n'
        'to return to the installed copy. See [local version switching](docs/DEV_SWITCH.md)\n'
        'for setup, reload, and recovery commands.\n\n')
replace(p, note, '')
replace(p, '### Development\n\n', '## Contributing\n\n' + note)
replace(p, '- Hyprland\n- Quickshell 0.3 or newer\n- Python 3 for the configuration CLI (standard library only)\n- GLib\'s `gio` command for optional Trash integration\n- A working freedesktop icon theme\n- Optional numeric launcher counts: CMake, a C++20 compiler, and Qt 6.6+ Core/DBus development files to build the native provider',
'''- Omarchy 4.x with the Quattro plugin host for the plugin installation below
- Hyprland and Quickshell 0.3 or newer
- Python 3 for the configuration CLI (standard library only)
- A working freedesktop icon theme
- Git for a standalone source checkout

Optional features have additional requirements:

| Feature | Requirement |
| --- | --- |
| Herdr agents | Herdr 0.9.1+ for click-to-focus; older versions cannot jump to agents. See [Herdr setup](docs/HERDR_DATA_ACCESS.md). |
| Chrome profiles, unread counts and tabs | Chrome with remote debugging explicitly enabled, a separate user-data directory, and the browser-profile provider. Omarchy does not enable remote debugging by default. See the [setup and security notes](docs/browser-activity.md#enable-the-feature). |
| Numeric launcher counts | CMake, a C++20 compiler, and Qt 6.6+ Core/DBus development files to build the optional provider. |
| Trash | GLib's `gio` command. |''')
replace(p, 'Standalone use is a secondary mode. From a source checkout, make sure\nQuickshell is installed and run:\n\n```bash\n./install.sh\n```',
'''Standalone use is a secondary mode. After installing the requirements above,
clone the source and run the installer:

```bash
git clone https://github.com/fernandodamaso/dockrail.git && cd dockrail && ./install.sh
```''')
replace(p, 'FDM-809 ', '', count=6)
replace(p, 'FDM-814 motion follows active badge severity:', 'Attention motion follows active badge severity:')
replace(p, 'Its recipes are executed against\nthe real CLI parser and production host/model harness in the existing CI;\nthat is not real Omarchy rendering or IPC qualification.',
        'It explains safe changes, backups,\nreadback and recovery. A successful CLI response confirms only the reported\nconfiguration and persistence state, not the visible result on your desktop.')
replace(p, 'Configuration is CLI-first: there is no settings window or live preference preview.\nIcon artwork is the one exception:',
        'The CLI is the configuration interface for AI coding agents and automation.\nThe accepted [Settings 3.1 design](docs/SETTINGS.md) is not shipped yet; there is\nno live preference preview. **Change Icon** remains the sole icon editor:')
replace(p, 'image decoding or a visible redraw. Real rendering/cache behavior is reserved\nfor local Omarchy qualification, not claimed by headless tests.',
        'image decoding or a visible redraw. Check the visible result on your Omarchy\ndesktop; headless tests cannot confirm image decoding or cache behavior there.')
replace(p, '### Grouped-window wheel cycling\n\nAttention dots', '### Application attention badges\n\nAttention dots')
replace(p, 'For a full-height vertical dock on the left, use one related patch:\n\n```bash\nprintf \'%s\\n\' \'{"position":"left","fullLength":true}\' | dockrail config apply --stdin --json\n```',
'''For a left sidebar as the default presentation, use one related patch. Existing
per-monitor choices in `presentationModeByMonitor` take precedence and are kept;
use **Switch to sidebar** on that monitor's Dock Controls menu to change only
that monitor. The classic dock remains bottom-only.

<!-- recipe: sidebar-default -->
```bash
printf '%s\\n' '{"presentationMode":"sidebar","sidebarEdge":"left"}' | dockrail config apply --stdin --json
```''')
replace(p, '"groupWindows": true,', '"groupWindows": false,')
replace(p, '| `fullLength` | Fill the screen width, or height for a vertical dock |',
        '| `fullLength` | Fill the classic dock screen width |')
replace(p, '| `groupWindows` | When `true`, combine an app\'s open windows into one dock icon; when `false`, show one icon per window |',
        '| `groupWindows` | Deprecated; new writes accept only `false`. Use `workspaceGroups` for grouping in classic workspace cards. |')
replace(p, 'The left position renders flat without changing the saved preference. Window\nscope, workspace sorting and urgent-outside-scope affect the flat layout; their\nsaved values are preserved. `groupWindows` remains effective in either layout.',
        'Workspace cards are a classic-dock layout; the sidebar keeps its own hierarchy.\nWindow scope, workspace sorting and urgent-outside-scope affect the flat layout;\ntheir saved values are preserved. Use `workspaceGroups` to group applications in\nworkspace cards; the legacy `groupWindows` setting is deprecated.')
replace(p, '[implementation plan and remote/local handoff](docs/superpowers/plans/2026-09-09-smartdock-workspace-drag.md)\nfor test coverage and the separate real-pointer Omarchy qualification gate.',
        '[developer test notes](docs/superpowers/plans/2026-09-09-smartdock-workspace-drag.md)\nfor automated coverage and the pointer checks that need an Omarchy desktop.')
replace(p, '### Global sidebar source foundation (FDM-964 / SB-02)\n\nThe unreleased sidebar candidate adds',
        '### Global sidebar\n\nThe sidebar is configured with')
replace(p, 'Classic preferences remain unchanged. This source slice is Draft, not a deployed\nor fully interactive sidebar release. [Implementation and qualification](docs/SIDEBAR.md).',
        'Classic preferences remain unchanged. Check the selected host with\n`dockrail config schema --json` for the settings supported by your installation.\nSee the [sidebar developer reference](docs/SIDEBAR.md) for implementation details.')
replace(p, 'The [Widget foundation](docs/SIDEBAR_WIDGETS.md) keeps the FDM-967 host-owned\nprovider leases while FDM-999 lays out independently scrollable hierarchy and\nWidget body panes.',
        'The [Widget system](docs/SIDEBAR_WIDGETS.md) shares host-owned provider leases\nacross independently scrollable hierarchy and Widget body panes.')
replace(p, 'Real compositor qualification remains a local follow-up.',
        'Scrolling, focus and pointer behavior must be checked in the actual desktop session.')

p = 'docs/CONFIGURATION.md'
replace(p, '**Unreleased CLI-first candidate.** Discover', '**Configuration reference.** Discover')
replace(p, 'CLI preferences and icons replace the removed Settings page; ordinary dock menus, app picker and window previews remain.',
        'The CLI configures preferences, and Change Icon is the sole icon editor. The accepted Settings 3.1 design is not shipped yet; ordinary dock menus, app picker and window previews remain.')
replace(p, 'FDM-942/FDM-943 workspace-monitor pin enforcement hooks', 'workspace-monitor pin enforcement hooks')
replace(p, ' FDM-949 remains the full-host qualification reference.', '')
replace(p, '## Sidebar presentation (SB-02 + SB-03 source foundation)', '## Sidebar presentation')
replace(p, '''This is an **unreleased Draft foundation**, not integrated sidebar acceptance.
SB-03 owns resize gestures, SB-04 owns full navigation/menus/keyboard/drag,
SB-05 owns the internal provider lifecycle and FDM-973 moves Widget cards into the
hierarchy's shared scroll. Local compositor qualification follows in FDM-974 after
the reusable UI-kit slice. See the source-only `docs/SIDEBAR.md` contract.''',
'''Sidebar resizing, navigation and Widget lifecycle details are in the source-only
`docs/SIDEBAR.md` reference. Configuration readback is not proof that a compositor
has rendered the requested layout; check placement and input on the desktop.''')
replace(p, '`sidebarWidgets` uses the internal source registry, currently empty in production.',
        '`sidebarWidgets` uses the selected host\'s Widget registry.')
replace(p, '''The normal Widget section has no independent footer cap/scrollbar and consumes zero
height when no Widgets are enabled; Add/Manage remains available in expanded mode.''',
'''The hierarchy and Widget bodies scroll independently, while the Widget header,
PINNED and Applications stay fixed. A content-aware 55% hierarchy cap returns
unused space. The Widget section consumes zero height when no Widgets are enabled;
Add/Manage remains available in expanded mode.''')

p = 'docs/CLI_REFERENCE.md'
replace(p, '**CLI interface (source candidate).** This describes implemented CLI source, not an available release, permission to deploy, or completed Omarchy runtime qualification. Older installed builds may not implement this interface. Discover the selected host\'s schema instead of assuming this document describes that installation.',
        '**CLI interface.** Older installed builds may not implement every command in this reference. Discover the selected host\'s schema before changing settings, and use `dockrail doctor` to check the current installation.')
replace(p, 'Source qualification belongs to [CLI_RUNTIME_CHECKS.md](CLI_RUNTIME_CHECKS.md); historical delivery evidence is not evidence for a newer SHA.',
        'Desktop verification steps are in [CLI_RUNTIME_CHECKS.md](CLI_RUNTIME_CHECKS.md). Results from another version do not confirm behavior on your installation.')
replace(p, 'SET-01 records that policy and design foundation; it does **not** ship the Settings UI or a new `dockrail settings` command.',
        'That record describes the planned panel; it does **not** ship the Settings UI or a new `dockrail settings` command.')
replace(p, 'a plugin-linked ONB-01 client', 'a plugin-linked client')
replace(p, 'the same ONB-05 readiness projection', 'the same readiness projection')
replace(p, 'Compatibility with the installed Quickshell build and real scheduling is a local gate.',
        'Verify compatibility and timing with the Quickshell build running on your desktop.')
replace(p, 'Use the normal, separately authorized Omarchy deployment path for a released plugin. No merge/deploy is authorized by this candidate reference.',
        'Updating or restarting an installed plugin is a separate, explicit operation; configuration commands never do it automatically.')
replace(p, 'The SB-02 candidate adds', 'Sidebar settings include')
replace(p, 'host; do not assume an installed release implements this candidate.\n\nIn an isolated candidate session only:',
        'host; older installations may not expose every setting.\n\nExamples below replace the named map or value. Read current values first and\npreserve other connectors\' entries when applying a per-monitor change:')
replace(p, "dockrail config apply --json '{\"sidebarCollapsedByMonitor\":{\"DP-1\":true,\"HDMI-A-1\":false}}'",
        "printf '%s\\n' '{\"sidebarCollapsedByMonitor\":{\"DP-1\":true,\"HDMI-A-1\":false}}' | dockrail config apply --stdin --json")
replace(p, '''These controls do not install widgets or alter the stock topbar. This Draft slice
is not an integrated release; see `docs/SIDEBAR.md` in the source checkout.

### Internal Widgets (FDM-967 / FDM-973)''',
'''These controls do not install widgets or alter the stock topbar. See
`docs/SIDEBAR.md` in the source checkout for the sidebar implementation details.

### Built-in sidebar widgets''')

p = 'docs/AGENT_CONFIGURATION.md'
replace(p, 'but SET-01 is policy/design foundation only: the Settings UI is not shipped by this change.',
        'but the Settings UI is not shipped yet.')
replace(p, 'Real cache invalidation, image decoding and multi-monitor redraw remain local qualification, not headless-test claims.',
        'Verify cache invalidation, image decoding and multi-monitor redraw on the actual desktop; headless tests cannot establish those results.')
replace(p, '[local qualification runbook](CLI_RUNTIME_CHECKS.md); installing that document does not start qualification.',
        '[desktop verification runbook](CLI_RUNTIME_CHECKS.md); installing that document does not run any desktop checks.')
replace(p, 'Full Omarchy IPC/FileView/theme/image/monitor behavior belongs to the exact-SHA local handoff; this guide does not authorize deployment or claim those checks passed.',
        'Check Omarchy IPC/FileView/theme/image/monitor behavior on the actual installation. This guide does not authorize deployment or claim those checks passed.')
replace(p, '## Sidebar candidate boundary', '## Sidebar configuration')
replace(p, 'schema. They may be unavailable in the installed version. Source SB-02 is a Draft\nfoundation, not permission to deploy or change the production desktop.',
        'schema. They may be unavailable in the installed version. Only change the\nsettings the user requested; do not update or restart the desktop implicitly.')
replace(p, 'without persisted readback. Physical qualification belongs to SB-06; the source\nhandoff and runnable production fixture are documented in `docs/SIDEBAR.md` in the source checkout.',
        'without persisted readback. Desktop checks and the runnable production fixture\nare documented in `docs/SIDEBAR.md` in the source checkout.')
replace(p, 'assume clock/Herdr/Todoist IDs or inject test IDs. This source slice has no production\nproviders. New ordered arrays must be registered/unique;',
        'assume clock/Herdr/Todoist IDs or inject test IDs. Available providers depend on\nthe installed host. New ordered arrays must be registered/unique;')
replace(p, 'Source API: `docs/SIDEBAR_WIDGETS.md`; actual\nOmarchy footer/input/popup qualification stays with SB-06.',
        'Source API: `docs/SIDEBAR_WIDGETS.md`. Verify Widget scrolling, input and popups\nin the actual Omarchy session.')

p = 'docs/HERDR_DATA_ACCESS.md'
replace(p, '# Herdr data access: Dockrail-owned local + attached-remote provider (FDM-970 / FDM-980)',
        '# Herdr data access: local and attached-remote agents')
replace(p, 'The production path is:',
'''**Requirements:** Herdr 0.9.1+ is required for click-to-focus. Older versions can
report agents but cannot jump to them. Attached remote hosts also need Python 3
and working non-interactive SSH access; Dockrail does not install either for you.

The data path is:''')
replace(p, '''Normalized snapshots continue to advertise global `capabilities.remote: false`
until FDM-982 completes native qualification. FDM-980 can nevertheless emit
source-qualified server rows with `transport: "remote"`; those rows advertise
`capabilities.focusAgent: false`. The global bit therefore remains a rollout /
qualification gate rather than a claim that remote source code is absent.''',
'''Normalized snapshots advertise global `capabilities.remote: false`. Attached
remote servers can still appear as rows with `transport: "remote"` and
`capabilities.focusAgent: false`. Check each server's transport, health and
capabilities rather than treating the global bit as an empty remote inventory.
Remote availability depends on the attached TUI and SSH connection.''')
replace(p, '''These tests use controlled socket/provider fixtures. They establish source and
protocol behavior but are not a substitute for FDM-982 native
Omarchy/Quickshell qualification with real local and remote Herdr installations.
That gate owns real SSH reachability, current installed Herdr/Python compatibility
and the decision to enable global `capabilities.remote`.

Canonical issues:
- https://linear.app/fdamaso/issue/FDM-970
- https://linear.app/fdamaso/issue/FDM-980''',
'''These tests use controlled socket/provider fixtures. They do not confirm SSH
reachability, Herdr/Python compatibility or focus behavior on your desktop and
remote hosts. For the corresponding on-desktop checks, see the
[Herdr desktop verification guide](HERDR_REMOTE_QUALIFICATION.md).''')

p = 'docs/browser-activity.md'
replace(p, 'focus, or auto-hide qualification; those require an isolated graphical session',
        'focus, or auto-hide behavior; those require an isolated graphical session')

for path, text in texts.items():
    (root / path).write_text(text)

p = Path('README.md')
s = p.read_text()
s = s.replace('docs/browser-activity.md#enable-the-feature', 'docs/browser-activity.md#enable-chrome-profiles-and-tabs')
s = s.replace('grouping cannot identify a session.\n## Contributing', 'grouping cannot identify a session.\n\n## Contributing')
s = s.replace('no live preference preview. **Change Icon** remains the sole icon editor: right-click an app, window or pinned app and\nchoose', 'no live preference preview. **Change Icon** remains the sole icon editor:\nright-click an app, window or pinned app and choose')
s = s.replace('Show application attention badges. dot severity', 'Show application attention badges. Dot severity')
p.write_text(s)
p = Path('tests/test_user_facing_docs.py')
s = p.read_text().replace("r'unreleased CLI-first candidate|qualification gate|native qualification',", "r'unreleased CLI-first candidate|source candidate|\\bqualification\\b',")
s = s.replace("'Run the native qualification gate',", "'Run the native qualification gate',\n            'Requires local qualification',\n            'CLI interface (source candidate)',")
s = s.replace("self.assertIn('## Contributing\\n', text)", "self.assertIn('## Contributing\\n', text, 'Missing Contributing section')")
p.write_text(s)
p = Path('docs/CLI_REFERENCE.md')
s = p.read_text()
a = "preserve other connectors' entries when applying a per-monitor change:\n\n```sh"
assert s.count(a) == 1
s = s.replace(a, a[:-5] + '<!-- recipe: sidebar-settings -->\n```sh')
p.write_text(s)
p = Path('tests/test_cli_docs.py')
s = p.read_text().replace('import importlib.util\n', 'import importlib.util\nimport io\n')
s = s.replace('def block(self, name, language):', 'def block(self, name, language, text=None):').replace("+ language + r'\\n(.*?)\\n```', self.guide, re.S)", "+ language + r'\\n(.*?)\\n```', self.guide if text is None else text, re.S)")
anchor = '    def test_application_recipe_restores_and_orders_without_dropping_unknown_ids(self):'
assert s.count(anchor) == 1
new = '''    def run_shell_recipe_line(self, command):
        # Parse the documented printf pipeline without invoking a shell or any
        # live command. Only transport is replaced; stdin parsing and the host
        # settings methods are production code.
        args = shlex.split(command)
        if args[0] == 'dockrail':
            return self.run_command(command)
        self.assertEqual(args[:2], ['printf', '%s\\\\n'])
        self.assertEqual(args[3:5], ['|', 'dockrail'])
        self.assertIn('--stdin', args[5:])
        with io.TextIOWrapper(io.BytesIO((args[2] + '\\n').encode())) as stdin:
            with patch.object(cli.sys, 'stdin', stdin):
                reply = cli.execute(cli.build_parser().parse_args(args[5:]))
        self.assertTrue(reply['ok'], reply)
        return reply['data']

    def test_readme_sidebar_recipe_preserves_monitor_choices_and_other_settings(self):
        self.transport.initial['presentationModeByMonitor'] = {'DP-1': 'classic'}
        text = (ROOT / 'README.md').read_text(encoding='utf-8')
        before = self.run_command('dockrail config get --json')['settings']
        result = self.run_shell_recipe_line(self.block('sidebar-default', 'bash', text))
        self.assertTrue(result['persisted'])
        after = self.run_command('dockrail config get --json')['settings']
        self.assertEqual(after, dict(before, presentationMode='sidebar', sidebarEdge='left'))
        self.assertEqual(after['presentationModeByMonitor'], {'DP-1': 'classic'})
        self.assertIn('per-monitor choices in `presentationModeByMonitor` take precedence', text)

    def test_reference_sidebar_examples_use_the_real_cli_and_host(self):
        text = (ROOT / 'docs/CLI_REFERENCE.md').read_text(encoding='utf-8')
        for line in self.block('sidebar-settings', 'sh', text).splitlines():
            with self.subTest(command=line):
                self.run_shell_recipe_line(line)
        settings = self.run_command('dockrail config get --json')['settings']
        self.assertEqual(settings['sidebarCollapsedByMonitor'], {'DP-1': True, 'HDMI-A-1': False})
        self.assertEqual(settings['presentationMode'], 'classic')
        self.assertEqual(settings['presentationModeByMonitor'], {})
        self.assertEqual(settings['extensionData'], self.transport.initial['extensionData'])
        self.assertEqual(settings['iconOverrides'], self.transport.initial['iconOverrides'])
        self.assertEqual(settings['pinned'], self.transport.initial['pinned'])

'''
s = s.replace(anchor, new + anchor)
p.write_text(s)

EXPECTED_BLOBS = {
    'README.md': 'e80728b9efe6b0b4fd284fe7fea2a5a11fb185e1',
    'docs/AGENT_CONFIGURATION.md': 'dce7b089c3be21444e121e38a7d58b13ec2cf43e',
    'docs/CLI_REFERENCE.md': '8f623d93513c837c2d8bbba19a7338bb6d8c68d5',
    'docs/CONFIGURATION.md': 'be7587869441afcea1893e0f0975725012f251c8',
    'docs/HERDR_DATA_ACCESS.md': '7e50c996645fb2c1a1a7004d2a6d4284096987d3',
    'docs/browser-activity.md': '4c9cb72a82a63b33c7085b0a40001d73187cc078',
    'tests/test_cli_docs.py': '1af06eab070d2e2dfe24a12062d9ada944b0c5bc',
    'tests/test_user_facing_docs.py': '10a0ba4bc3b05ce77ab7b6250ad381a41ca8e9e5',
}
changed = set(subprocess.check_output(['git', 'diff', '--name-only'], text=True).splitlines())
assert changed == set(EXPECTED_BLOBS), changed
for path, expected in EXPECTED_BLOBS.items():
    actual = subprocess.check_output(['git', 'hash-object', path], text=True).strip()
    assert actual == expected, (path, actual, expected)
print('Exact local document/test blobs reproduced:', len(EXPECTED_BLOBS))
