"""CLI-03 transport tests; host/model tests own identity and artwork validation."""
import json
import os
from pathlib import Path
from urllib.parse import unquote, urlsplit
import unittest
import test_cli as fixtures


class AppCliTests(unittest.TestCase):
    setUp = fixtures.CliTests.setUp
    set_hosts = fixtures.CliTests.set_hosts
    run_cli = fixtures.CliTests.run_cli
    response = fixtures.CliTests.response
    assert_no_state = fixtures.CliTests.assert_no_state

    def reply_data(self, **extra):
        fixture = self.set_hosts('plugin')
        data = dict(fixture['hosts']['101']['status'])
        data.update(applied=False, noop=True, changedKeys=[], requested={}, effective={},
                    renderVerified=False, iconReloadRevision=7, reloaded=False)
        data.update(extra)
        fixture['hosts']['101']['data'] = data
        self.fixture.write_text(json.dumps(fixture))

    def last_request(self):
        calls = list(map(json.loads, self.calls.read_text().splitlines()))
        self.assertTrue(all(call[:1] == ['list'] or call[:2] == ['ipc', '--pid'] for call in calls))
        return json.loads(calls[-1][-1])

    def test_app_membership_and_reorder_payloads(self):
        for action in ('pin', 'unpin', 'hide', 'show'):
            with self.subTest(action=action):
                self.reply_data()
                self.response(('apps', action, 'Org.Example.desktop', '--json'))
                self.assertEqual(self.last_request(), {
                    'apiVersion': 1, 'command': 'apps.' + action,
                    'arguments': {'id': 'Org.Example.desktop'}})
        for side in ('before', 'after'):
            self.reply_data()
            self.response(('--json', 'apps', 'move', 'App Ícone', '--' + side, 'Hidden.App'))
            self.assertEqual(self.last_request()['arguments'], {'id': 'App Ícone', side: 'Hidden.App'})
        self.reply_data()
        self.response(('apps', 'show', '--all', '--json'))
        self.assertEqual(self.last_request()['arguments'], {'all': True})
        self.assert_no_state()

    def test_app_discovery_filters_and_host_selection(self):
        for options, expected in [((), {}), (('--pinned',), {'pinned': True}),
                                  (('--hidden',), {'hidden': True}),
                                  (('--query', 'Editor Ícone'), {'query': 'Editor Ícone'})]:
            self.reply_data(applications=[{'id': 'Unavailable.App', 'name': 'Unavailable.App',
                            'available': False, 'pinned': True, 'hidden': True, 'pinnedIndex': 2}])
            value = self.response(('apps', 'list', *options, '--runtime', 'plugin', '--instance', 'qs-101', '--json'))
            self.assertFalse(value['data']['applications'][0]['available'])
            self.assertEqual(self.last_request()['arguments'], expected)
            self.assertEqual(self.last_request()['command'], 'apps.list')
        self.assert_no_state()

    def test_icon_paths_are_ingested_before_host_request(self):
        svg = self.tmp / 'My Ícone.svg'
        svg.write_text('<svg xmlns="http://www.w3.org/2000/svg"/>', encoding='utf-8')
        png = self.tmp / 'My Ícone.png'
        png.write_bytes(b'\x89PNG\r\n\x1a\n' + b'fixture')
        for source, original in [(str(svg), svg), (svg.as_uri(), svg),
                                 (str(png), png)]:
            self.reply_data()
            self.response(('icons', 'set', 'Code.desktop', source, '--json'))
            request = self.last_request()
            self.assertEqual(request['command'], 'icons.set')
            managed = Path(unquote(urlsplit(request['arguments']['source']).path))
            self.assertEqual(request['arguments']['id'], 'Code.desktop')
            self.assertEqual(managed.parent, Path(self.env['XDG_DATA_HOME']) / 'dockrail/icons')
            self.assertEqual(managed.read_bytes(), original.read_bytes())
        def icon_set_calls():
            calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
            return [json.loads(call[-1]) for call in calls
                    if call[:2] == ['ipc', '--pid']
                    and json.loads(call[-1]).get('command') == 'icons.set']
        previous_sets = len(icon_set_calls())
        for source in ('https://example.invalid/a.png', 'data:image/png,bad',
                       str(self.tmp / 'does-not-exist.png')):
            self.reply_data()
            self.assertEqual(self.response(('icons', 'set', 'Code.desktop',
                                            source, '--json'), 2)['error']['code'], 'E_VALIDATION')
            self.assertEqual(len(icon_set_calls()), previous_sets,
                             'Host discovery is allowed, but no invalid icon set may dispatch')
        self.assertFalse(Path(self.env['XDG_CONFIG_HOME']).exists())
        self.assertFalse(Path(self.env['XDG_CACHE_HOME']).exists())

    def test_icon_list_reset_and_reload_are_primitive_requests(self):
        self.reply_data(overrides={'code': 'file:///missing/icon.svg'})
        value = self.response(('icons', 'list', '--json'))
        self.assertEqual(value['data']['overrides'], {'code': 'file:///missing/icon.svg'})
        self.assertFalse(value['data']['renderVerified'])
        self.assertEqual(self.last_request()['arguments'], {})
        for action in ('reset', 'reload'):
            self.reply_data(reloaded=action == 'reload')
            value = self.response(('icons', action, 'code', '--json'))
            self.assertFalse(value['data']['renderVerified'])
            self.assertEqual(self.last_request()['command'], 'icons.' + action)
            self.assertEqual(self.last_request()['arguments'], {'id': 'code'})
        self.assert_no_state()

    def test_invalid_flag_combinations_do_not_contact_a_host(self):
        cases = [('apps',), ('icons',), ('apps', 'list', '--pinned', '--hidden'),
                 ('apps', 'list', '--query', 'a', '--pinned'), ('apps', 'show'),
                 ('apps', 'show', 'code', '--all'), ('apps', 'move', 'code'),
                 ('apps', 'move', 'code', '--before', 'a', '--after', 'b'),
                 ('icons', 'reset', '--all'), ('icons', 'set', 'code')]
        for args in cases:
            value = self.response((*args, '--json'), 2)
            self.assertEqual(value['error']['code'], 'E_USAGE')
        self.assertFalse(self.calls.exists())
        self.assert_no_state()

    def test_all_new_commands_require_a_selected_running_host(self):
        for args in [('apps', 'list'), ('apps', 'pin', 'code'), ('apps', 'show', '--all'),
                     ('icons', 'list'), ('icons', 'set', 'code', '/tmp/a.png'),
                     ('icons', 'reset', 'code'), ('icons', 'reload', 'code')]:
            self.set_hosts()
            value = self.response((*args, '--json'), 3)
            self.assertEqual(value['error']['code'], 'E_RUNTIME_NOT_FOUND')
        self.set_hosts('plugin', 'plugin')
        value = self.response(('icons', 'list', '--json'), 3)
        self.assertEqual(value['error']['code'], 'E_RUNTIME_AMBIGUOUS')
        self.assert_no_state()

    def test_malformed_reads_and_unproven_render_success_are_protocol_errors(self):
        self.reply_data(applications=[{'id': 'code'}])
        self.assertEqual(self.response(('apps', 'list', '--json'), 5)['error']['code'], 'E_PROTOCOL')
        self.reply_data(overrides=[], renderVerified=False)
        self.assertEqual(self.response(('icons', 'list', '--json'), 5)['error']['code'], 'E_PROTOCOL')
        self.reply_data(renderVerified=True)
        png = self.tmp / 'valid.png'
        png.write_bytes(b'\x89PNG\r\n\x1a\n' + b'fixture')
        self.assertEqual(self.response(('icons', 'set', 'code', str(png), '--json'), 5)['error']['code'], 'E_PROTOCOL')


if __name__ == '__main__':
    unittest.main()
