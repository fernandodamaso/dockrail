"""CLI-02 argv/value/export tests; actual mutation semantics live in the JS test."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

import test_cli

ROOT = test_cli.ROOT
FAKE_QS = r'''
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['QS_CALLS'], 'a') as log:
    log.write(json.dumps(args) + '\n')
f = json.loads(Path(os.environ['QS_FIXTURE']).read_text())
if args == ['list', '--all', '--json']:
    print(json.dumps(f['instances']))
    sys.exit(0)
assert len(args) == 8 and args[:2] == ['ipc', '--pid']
assert args[3:7] == ['call', '--', 'smartdock', 'request']
request = json.loads(args[7])
assert request['apiVersion'] == 1
host = f['hosts'][args[2]]
command = request['command']
arguments = request['arguments']
data = dict(host['status'])
root = Path(os.environ['SMARTDOCK_TEST_ROOT'])
defaults = json.loads((root / 'config/dock.json').read_text())
metadata = json.loads((root / 'config/settings-schema.json').read_text())
reply = None
if command == 'config.schema':
    key = arguments.get('key')
    if key is not None and key not in metadata['settings']:
        reply = {'apiVersion': 1, 'ok': False, 'error': {'code': 'E_VALIDATION', 'message': 'Unknown key'}, 'data': data, 'warnings': []}
    else:
        keys = metadata['settings'] if key is None else [key]
        data.update(source='runtime', schemaVersion=1, commands=metadata['commands'],
                    settings={name: dict(metadata['settings'][name], default=defaults[name]) for name in keys})
elif command == 'config.get':
    values = dict(defaults, extensionData={'keep': 'exact'})
    values.update(f.get('settings', {}))
    key = arguments.get('key')
    data.update(source='requested', settings=values if key is None else {key: values[key]})
elif command not in ('status', 'doctor'):
    data.update(applied=True, persisted=True, writeState='saved', changedKeys=[],
                requested={}, effective={}, revision=1, noop=False)
    if command.startswith('icons.'):
        data.update(reloaded=True, renderVerified=False, iconReloadRevision=1)
    reply = f.get('mutationReply')
if reply is None:
    reply = {'apiVersion': 1, 'ok': True, 'data': data, 'warnings': []}
print('fixture diagnostic', file=sys.stderr)
print(json.dumps(reply))
'''


class MutationCliTests(unittest.TestCase):
    set_hosts = test_cli.CliTests.set_hosts
    run_cli = test_cli.CliTests.run_cli
    response = test_cli.CliTests.response

    def setUp(self):
        test_cli.CliTests.setUp(self)
        self.set_hosts('plugin')
        self.env['SMARTDOCK_TEST_ROOT'] = str(ROOT)
        (self.bin / 'qs').write_text('#!' + sys.executable + '\n' + FAKE_QS)

    def requests(self, command):
        if not self.calls.exists():
            return []
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        requests = [json.loads(call[-1]) for call in calls if call[:1] == ['ipc']]
        return [item['arguments'] for item in requests if item['command'] == command]

    def test_set_parses_by_runtime_schema_without_evaluation(self):
        values = [('showTrash', 'false', False), ('iconSize', '48', 48),
                  ('hoverGlowOpacity', '0.72', .72),
                  ('backgroundColor', '#80112233', '#80112233'),
                  ('pinned', '["code","Unavailable.App"]', ['code', 'Unavailable.App'])]
        for key, text, value in values:
            self.response(('config', 'set', key, text, '--json'))
            self.assertEqual(self.requests('config.apply')[-1],
                             {'patch': {key: value}, 'dryRun': False})
        marker = self.tmp / 'not-executed'
        command = 'touch "' + str(marker) + '"; $(not-evaluated)'
        self.response(('config', 'set', 'controlCommand', command, '--json'))
        self.assertEqual(self.requests('config.apply')[-1]['patch']['controlCommand'], command)
        self.assertFalse(marker.exists())

    def test_bad_scalar_parse_and_unknown_key_never_mutate(self):
        for key, value in [('showTrash', 'False'), ('showTrash', '0'),
                           ('iconSize', 'false'), ('magnification', 'NaN'),
                           ('magnification', '1e999'), ('pinned', 'not JSON'),
                           ('notASetting', 'anything')]:
            result = self.response(('config', 'set', key, value, '--json'), 2)
            self.assertEqual(result['error']['code'], 'E_VALIDATION')
        self.assertEqual(self.requests('config.apply'), [])

    def test_apply_explicit_sources_utf8_and_dry_run(self):
        source = self.tmp / 'config patch ü.json'
        source.write_text('{"showTrash":false,"controlCommand":"literal ü command"}', encoding='utf-8')
        self.response(('config', 'apply', '--file', str(source), '--dry-run', '--json'))
        self.assertEqual(self.requests('config.apply')[-1],
                         {'patch': {'showTrash': False, 'controlCommand': 'literal ü command'}, 'dryRun': True})
        result = subprocess.run(['bash', str(ROOT / 'scripts/smartdock'), 'config', 'apply', '--stdin', '--json'],
                                input='{"autoHide":true}', env=self.env, text=True,
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads(result.stdout)['ok'])
        self.assertEqual(self.requests('config.apply')[-1]['patch'], {'autoHide': True})

    def test_apply_source_errors_and_duplicate_json_keys(self):
        for args in [('config', 'apply'), ('config', 'apply', '--stdin', '--file', '/a')]:
            self.response((*args, '--json'), 2)
        source = self.tmp / 'patch.json'
        for text in ('{"iconSize":42,"iconSize":50}', '{broken', '\ufeff{}', 'NaN'):
            source.write_text(text, encoding='utf-8')
            self.response(('config', 'apply', '--file', str(source), '--json'), 2)
        self.assertEqual(self.requests('config.apply'), [])

    def test_reset_and_retry_are_explicit_host_intents(self):
        self.response(('config', 'reset', 'margin', '--json'))
        self.assertEqual(self.requests('config.reset')[-1], {'key': 'margin'})
        self.response(('--json', 'config', 'reset', '--preferences'))
        self.assertEqual(self.requests('config.reset')[-1], {'preferences': True})
        self.response(('config', 'retry', '--json'))
        self.assertEqual(self.requests('config.retry'), [{}])
        for args in [('config', 'reset'), ('config', 'reset', 'margin', '--preferences')]:
            self.response((*args, '--json'), 2)

    def test_mutation_response_requires_truthful_fields(self):
        fixture = json.loads(self.fixture.read_text())
        fixture['mutationReply'] = {'apiVersion': 1, 'ok': True, 'data': {}, 'warnings': []}
        self.fixture.write_text(json.dumps(fixture))
        result = self.response(('config', 'set', 'showTrash', 'false', '--json'), 5)
        self.assertEqual(result['error']['code'], 'E_PROTOCOL')

    def test_window_icon_title_pattern_cli_is_explicit_and_exclusive(self):
        source = self.tmp / 'window icon.svg'
        source.write_text('<svg/>', encoding='utf-8')
        self.response(('icons', 'set', 'org.ghostty', str(source),
                       '--title-pattern', ' *solar* ', '--json'))
        request = self.requests('icons.set')[-1]
        self.assertEqual(request['id'], 'org.ghostty')
        self.assertEqual(request['titlePattern'], ' *solar* ')
        # The host receives a Dockrail-managed copy, never the original path.
        managed_dir = (Path(self.env['XDG_DATA_HOME']) / 'dockrail' / 'icons').resolve()
        self.assertTrue(request['source'].startswith(managed_dir.as_uri() + '/'), request['source'])
        copies = list(managed_dir.iterdir())
        self.assertEqual(len(copies), 1, copies)
        self.assertRegex(copies[0].name, r'^[A-Za-z0-9._-]+-[0-9a-f]{12}\.svg$')
        self.assertEqual(copies[0].read_bytes(), b'<svg/>')
        self.assertEqual(source.read_text(encoding='utf-8'), '<svg/>')
        self.response(('icons', 'reset', 'org.ghostty',
                       '--title-pattern', '*solar*', '--json'))
        self.assertEqual(self.requests('icons.reset')[-1], {
            'id': 'org.ghostty',
            'titlePattern': '*solar*',
        })
        before = len(self.requests('icons.set'))
        self.response(('icons', 'set', 'org.ghostty', str(source),
                       '--profile', 'Profile 1', '--title-pattern', '*solar*', '--json'), 2)
        self.assertEqual(len(self.requests('icons.set')), before)
        self.response(('icons', 'reload', 'org.ghostty',
                       '--title-pattern', '*solar*', '--json'), 2)
        self.assertEqual(self.requests('icons.reload'), [])

    def export_fixture(self, live):
        fixture = json.loads(self.fixture.read_text())
        fixture['hosts']['101']['status']['configPath'] = str(live)
        self.fixture.write_text(json.dumps(fixture))

    def test_export_plain_snapshot_keeps_source_unsaved_truth(self):
        live = self.tmp / 'live missing.json'
        self.export_fixture(live)
        output = self.tmp / 'new snapshot ü.json'
        reply = self.response(('config', 'export', '--output', str(output), '--json'))
        values = json.loads(output.read_text(encoding='utf-8'))
        self.assertNotIn('apiVersion', values)
        self.assertEqual(values['extensionData'], {'keep': 'exact'})
        self.assertTrue(reply['data']['exportWritten'])
        self.assertFalse(reply['data']['sourcePersisted'])
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        self.assertFalse(live.exists())
        self.assertEqual(self.requests('config.apply'), [])

    def test_export_refuses_existing_symlinks_and_live_aliases(self):
        live = self.tmp / 'live.json'
        self.export_fixture(live)
        self.response(('config', 'export', '--output', str(live), '--json'), 4)
        self.assertFalse(live.exists())
        existing = self.tmp / 'existing.json'
        existing.write_text('keep bytes')
        symlink = self.tmp / 'link.json'
        symlink.symlink_to(existing)
        broken = self.tmp / 'broken.json'
        broken.symlink_to(self.tmp / 'absent.json')
        parent_alias = self.tmp / 'alias'
        parent_alias.symlink_to(self.tmp, target_is_directory=True)
        for output in [existing, symlink, broken, parent_alias / 'live.json']:
            value = self.response(('config', 'export', '--output', str(output), '--json'), 4)
            self.assertEqual(value['error']['code'], 'E_EXPORT')
        self.assertEqual(existing.read_text(), 'keep bytes')
        self.assertFalse(live.exists())
        live.write_text('live keep bytes')
        hardlink = self.tmp / 'hardlink.json'
        os.link(live, hardlink)
        self.response(('config', 'export', '--output', str(hardlink), '--json'), 4)
        self.assertEqual(live.read_text(), 'live keep bytes')

    def test_export_requires_live_host_and_never_overwrites_on_repeat(self):
        output = self.tmp / 'snapshot.json'
        self.set_hosts()
        self.response(('config', 'export', '--output', str(output), '--json'), 3)
        self.assertFalse(output.exists())
        self.set_hosts('plugin')
        self.export_fixture(self.tmp / 'live.json')
        self.response(('config', 'export', '--output', str(output), '--json'))
        content = output.read_bytes()
        self.response(('config', 'export', '--output', str(output), '--json'), 4)
        self.assertEqual(output.read_bytes(), content)

    def test_export_fsync_error_removes_only_new_snapshot(self):
        path = ROOT / 'scripts/smartdock_cli.py'
        spec = importlib.util.spec_from_file_location('smartdock_export_cli', path)
        cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cli)
        self.assertTrue(hasattr(cli, 'export_snapshot'), 'Implement safe snapshot export')
        output = self.tmp / 'incomplete.json'
        response = {'apiVersion': 1, 'ok': True, 'warnings': [], 'data': {
            'settings': {'pinned': ['code']}, 'configPath': str(self.tmp / 'live.json'),
            'persisted': False, 'revision': 0, 'runtime': {'mode': 'plugin', 'instanceId': '101'}}}
        with patch.object(cli.os, 'fsync', side_effect=OSError('simulated storage error')):
            with self.assertRaises(cli.CliError) as caught:
                cli.export_snapshot(response, str(output))
        self.assertEqual(caught.exception.code, 'E_EXPORT')
        self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()
