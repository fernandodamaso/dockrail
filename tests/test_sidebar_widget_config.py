"""Real CLI parsing and production host methods; test providers never enter schema."""
import json
import shlex
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch
from test_cli_docs import cli, ModelTransport

class SidebarWidgetConfigTests(unittest.TestCase):
    def setUp(self):
        self.transport = ModelTransport()
        self.transport.initial['sidebarWidgets'] = ['future.clock']
        self.mock = patch.object(cli, 'Transport', return_value=self.transport)
        self.mock.start()
        self.addCleanup(self.mock.stop)

    def command(self, command):
        return cli.execute(cli.build_parser().parse_args(shlex.split(command)))

    def test_schema_and_unknown_imported_requested_state(self):
        result = self.command('config schema sidebarWidgets --json')
        self.assertTrue(result['ok'], result)
        spec = result['data']['settings']['sidebarWidgets']
        self.assertEqual(spec['default'], [])
        self.assertEqual(spec['registeredIds'], ['herdr.agents', 't3.threads'])
        self.assertEqual(spec['format'], 'sidebar-widget-ids')
        before = self.command('config get --json')['data']['settings']
        self.assertEqual(before['sidebarWidgets'], ['future.clock'])
        self.assertTrue(self.command('config set iconSize 48 --json')['ok'])
        self.assertEqual(self.command('config get sidebarWidgets --json')['data']['settings']['sidebarWidgets'], ['future.clock'])
        effective = self.command('config get --effective --json')['data']
        self.assertEqual(effective['settings']['sidebarWidgets'], [])
        self.assertEqual(effective['presentation']['widgets']['rows'][0]['status'], 'unavailable')
        self.assertEqual(effective['presentation']['widgets']['rows'][0]['id'], 'future.clock')
        self.assertTrue(self.command('config reset sidebarWidgets --json')['ok'])
        self.assertEqual(self.command('config get sidebarWidgets --json')['data']['settings']['sidebarWidgets'], [])
        collapse = self.command('config schema sidebarWidgetCollapsed --json')
        self.assertTrue(collapse['ok'], collapse)
        collapse_spec = collapse['data']['settings']['sidebarWidgetCollapsed']
        self.assertEqual(collapse_spec['default'], {})
        self.assertEqual(collapse_spec['format'], 'sidebar-widget-collapsed')

    def test_strict_bulk_validation_is_atomic_and_independent_of_readiness(self):
        before = self.command('config get --json')['data']['settings']
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'widgets.json'
            for value in [None, {}, 'clock', 42, [True], ['clock'], ['clock', 'clock'],
                          ['fixture.one'], ['../provider.qml'], ['sh -c bad'], ['constructor']]:
                path.write_text(json.dumps({'sidebarWidgets':value, 'iconSize':48}))
                result = self.command('config apply --file ' + shlex.quote(str(path)) + ' --json')
                self.assertFalse(result['ok'], value)
                self.assertEqual(self.command('config get --json')['data']['settings'], before)
            path.write_text(json.dumps({'sidebarWidgets':[]}))
            result = self.command('config apply --file ' + shlex.quote(str(path)) + ' --dry-run --json')
            self.assertTrue(result['ok'], result)
            self.assertFalse(result['data']['applied'])
            self.assertEqual(self.command('config get --json')['data']['settings'], before)
            result = self.command('config apply --file ' + shlex.quote(str(path)) + ' --json')
            self.assertTrue(result['ok'], result)
            self.assertTrue(result['data']['persisted'])
        self.assertEqual(self.command('config get sidebarWidgets --json')['data']['settings']['sidebarWidgets'], [])

    def test_cli_set_checks_registered_ids_not_transient_readiness(self):
        with self.assertRaises(cli.CliError) as rejected:
            self.command("config set sidebarWidgets '[\"fixture.one\"]' --json")
        self.assertEqual(rejected.exception.code, 'E_VALIDATION')
        accepted = self.command("config set sidebarWidgets '[\"herdr.agents\"]' --json")
        self.assertTrue(accepted['ok'], accepted)
        spec = {'type':'array', 'format':'sidebar-widget-ids', 'registeredIds':['future.clock'],
                'status':'unavailable'}
        self.assertEqual(cli.scalar_value('["future.clock"]', spec), ['future.clock'])
        for value in ['["future.clock","future.clock"]', '["unregistered"]', '[42]']:
            with self.assertRaises(cli.CliError):
                cli.scalar_value(value, spec)

    def test_bundled_schema_never_advertises_fixture_ids(self):
        result = cli.bundled_schema('sidebarWidgets')
        self.assertEqual(result['data']['settings']['sidebarWidgets']['registeredIds'], ['herdr.agents', 't3.threads'])
        self.assertNotIn('fixture.', json.dumps(result))
