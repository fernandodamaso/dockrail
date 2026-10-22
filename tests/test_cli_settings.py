"""Settings CLI routing exercises the real parser and the fixed IPC argv."""
import importlib.util
from pathlib import Path
from unittest import TestCase, mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('dockrail_settings_cli', ROOT / 'scripts/smartdock_cli.py')
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)


class FakeTransport:
    def __init__(self):
        self.calls = []
        self.message = 'opened'
    def select(self, runtime, instance_id):
        self.calls.append(('select',runtime,instance_id))
        return ({'id':'fixture','pid':641}, {'apiVersion':1,'ok':True,'data': {
            'runtime': {'mode':'plugin','instanceId':'fixture'},
            'loadState':'loaded', 'writeState':'idle',
        },'warnings':[]})
    def run(self, argv):
        self.calls.append(('run',argv))
        return self.message


class SettingsCliTests(TestCase):
    def test_settings_opens_one_host_without_writing_any_config(self):
        transport = FakeTransport()
        with mock.patch.object(cli, 'Transport', return_value=transport):
            result = cli.execute(cli.build_parser().parse_args(['settings','--runtime','plugin']))
        self.assertTrue(result['ok'])
        self.assertTrue(result['data']['opened'])
        self.assertEqual(transport.calls, [
            ('select','plugin',None),
            ('run',['qs','ipc','--pid','641','call','--','dockrail-settings','open']),
        ])
    def test_missing_real_anchor_is_not_claimed_as_success(self):
        transport = FakeTransport()
        transport.message = 'no-anchor'
        with mock.patch.object(cli, 'Transport', return_value=transport):
            with self.assertRaises(cli.CliError) as caught:
                cli.execute(cli.build_parser().parse_args(['settings']))
        self.assertEqual(caught.exception.code,'E_RUNTIME_NOT_FOUND')
