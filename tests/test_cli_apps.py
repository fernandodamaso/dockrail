"""CLI-03 transport tests; host/model tests own identity and artwork validation."""
import json
import os
from pathlib import Path
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

    def test_local_icon_sources_are_ingested_into_managed_storage(self):
        pictures = self.tmp / 'Pictures'
        pictures.mkdir()
        svg = pictures / 'My Ícone.svg'
        svg.write_bytes(b'<svg/>')
        png = self.tmp / 'icon.png'
        png.write_bytes(b'\x89PNG\r\n\x1a\n')
        managed_dir = (Path(self.env['XDG_DATA_HOME']) / 'dockrail' / 'icons').resolve()
        self.assertFalse(managed_dir.exists())
        # Local plain paths and file URLs are copied into Dockrail-managed
        # persistent storage; the host receives the managed reference, never
        # the original path, and the original file is never modified.
        requested = []
        for source in (str(svg), str(png), svg.as_uri()):
            self.reply_data()
            self.response(('icons', 'set', 'Code.desktop', source, '--json'))
            self.assertEqual(self.last_request()['command'], 'icons.set')
            self.assertEqual(self.last_request()['arguments']['id'], 'Code.desktop')
            requested.append(self.last_request()['arguments']['source'])
        copies = sorted(managed_dir.iterdir())
        self.assertEqual(len(copies), 2, copies)
        for name in (copy.name for copy in copies):
            self.assertRegex(name, r'^[A-Za-z0-9._-]+-[0-9a-f]{12}\.(png|svg)$')
        self.assertEqual({copy.suffix for copy in copies}, {'.png', '.svg'})
        self.assertEqual({copy.read_bytes() for copy in copies}, {b'<svg/>', b'\x89PNG\r\n\x1a\n'})
        for url in requested:
            self.assertTrue(url.startswith(managed_dir.as_uri() + '/'), url)
        self.assertTrue(svg.exists())
        self.assertEqual(svg.read_bytes(), b'<svg/>')
        self.assertEqual(png.read_bytes(), b'\x89PNG\r\n\x1a\n')
        # A second ingestion of the same content under the same key reuses the
        # same managed asset instead of minting a new file.
        self.assertEqual(requested[0], requested[2])
        self.assertEqual(len(list(managed_dir.iterdir())), 2)

    def test_remote_and_data_icon_sources_pass_through_without_ingestion(self):
        managed_dir = Path(self.env['XDG_DATA_HOME']) / 'dockrail' / 'icons'
        for source in ('https://example.invalid/a.png', 'data:image/png,bad'):
            self.reply_data()
            self.response(('icons', 'set', 'Code.desktop', source, '--json'))
            self.assertEqual(self.last_request()['command'], 'icons.set')
            self.assertEqual(self.last_request()['arguments'],
                             {'id': 'Code.desktop', 'source': source})
        # Non-local schemes keep the historic pass-through for host validation;
        # no managed copy is created for them.
        self.assertFalse(managed_dir.exists())
        self.assert_no_state()

    def test_missing_local_icon_source_fails_before_any_host_intent(self):
        self.reply_data()
        missing = str(self.tmp / 'missing.png')
        icon_intents = lambda: [line for line in self.calls.read_text().splitlines()
                                if '\"command\":\"icons.set\"' in line]
        value = self.response(('icons', 'set', 'Code.desktop', missing, '--json'), 2)
        self.assertEqual(value['error']['code'], 'E_VALIDATION')
        self.assertIn('does not exist', value['error']['message'])
        # The host-selection status probe may run, but no icon mutation intent
        # is ever sent for a source that could not be ingested.
        self.assertEqual(icon_intents(), [])
        self.assertFalse((Path(self.env['XDG_DATA_HOME']) / 'dockrail').exists())

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
        self.assertEqual(self.response(('icons', 'set', 'code', 'https://example.invalid/a.png', '--json'), 5)['error']['code'], 'E_PROTOCOL')


if __name__ == '__main__':
    unittest.main()
