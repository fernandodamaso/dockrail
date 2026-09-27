#!/usr/bin/env python3
import importlib.util
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    'smartdock_cli_doctor', ROOT / 'scripts/smartdock_cli.py')
CLI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CLI)


class FakeProbes:
    def __init__(self):
        self.herdr_path = '/fake/herdr'
        self.herdr = (0, 9, 1)
        self.providers = {
            'browser': {
                'path': '/fake/smartdock-browser-profile-provider',
                'installed': True,
                'running': True,
                'argv': ['/fake/smartdock-browser-profile-provider',
                         '--state-file', '/tmp/browser.json', '--port', '9333'],
            },
            'launcher': {
                'path': '/fake/smartdock-launcher-badge-provider',
                'installed': True,
                'running': False,
                'argv': [],
            },
        }
        self.endpoint = True
        self.missing_launchers = []
        self.sync = 'match'
        self.endpoint_ports = []

    def which(self, command):
        return self.herdr_path if command == 'herdr' else None

    def herdr_version(self, executable):
        self.assert_path = executable
        return self.herdr

    def provider(self, kind):
        return dict(self.providers[kind])

    def devtools_reachable(self, port):
        self.endpoint_ports.append(port)
        return self.endpoint

    def missing_agent_launchers(self):
        return list(self.missing_launchers)

    def cli_sync(self, runtime_mode):
        self.runtime_mode = runtime_mode
        return self.sync


def status(sidebar=True, lease=True, monitors=True):
    per_monitor = [] if not monitors else [
        {'connector': 'DP-1', 'mode': 'sidebar' if sidebar else 'classic',
         'source': 'inherited', 'mapped': True, 'sidebarSelected': sidebar}
    ]
    return {
        'runtime': {'mode': 'plugin', 'instanceId': '101'},
        'presentation': {
            'perMonitor': per_monitor,
            'widgets': {
                'rows': [{
                    'id': 'herdr.agents', 'registered': True, 'available': True,
                    'status': 'ready', 'revision': 1, 'active': lease,
                    'errorCode': '',
                }],
            },
        },
    }


def settings(widget=True, badges=True, tabs=True):
    return {
        'sidebarWidgets': ['herdr.agents'] if widget else [],
        'browserProfileBadgesEnabled': badges,
        'sidebarBrowserTabsEnabled': tabs,
    }


class FeatureReadinessTests(unittest.TestCase):
    def test_devtools_probe_includes_non_default_port_in_host_header(self):
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                self.server.seen_host = self.headers.get('Host')
                body = json.dumps({
                    'webSocketDebuggerUrl':
                        'ws://' + self.server.seen_host + '/devtools/browser/test',
                }).encode('utf-8')
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, format, *args):
                pass

        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.addCleanup(server.server_close)
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        self.addCleanup(thread.join)
        self.addCleanup(server.shutdown)

        port = server.server_address[1]
        self.assertTrue(CLI.ReadinessProbes().devtools_reachable(port))
        self.assertEqual(server.seen_host, '127.0.0.1:' + str(port))

    def test_ready_shape_and_fake_provider_port(self):
        probes = FakeProbes()
        features = CLI.feature_readiness(status(), settings(), probes)
        self.assertEqual(list(features), list(CLI.FEATURE_ORDER))
        for value in features.values():
            self.assertEqual(set(value), {'status', 'reason', 'nextStep'})
            self.assertEqual(value['status'], 'ready')
            self.assertTrue(value['reason'])
            self.assertTrue(value['nextStep'])
        self.assertEqual(probes.endpoint_ports, [9333])
        self.assertEqual(probes.runtime_mode, 'plugin')

    def test_sidebar_missing_and_degraded(self):
        probes = FakeProbes()
        missing = CLI.feature_readiness(status(sidebar=False), settings(), probes)
        self.assertEqual(missing['sidebar']['status'], 'missing')
        degraded = CLI.feature_readiness(status(monitors=False), settings(), probes)
        self.assertEqual(degraded['sidebar']['status'], 'degraded')

    def test_herdr_missing_old_disabled_and_inactive_lease(self):
        probes = FakeProbes()
        probes.herdr_path = None
        value = CLI.feature_readiness(status(), settings(), probes)
        self.assertEqual(value['herdrAgents']['status'], 'missing')

        probes = FakeProbes()
        probes.herdr = (0, 8, 2)
        value = CLI.feature_readiness(status(), settings(), probes)
        self.assertEqual(value['herdrAgents']['status'], 'degraded')
        self.assertIn('0.9.1', value['herdrAgents']['reason'])

        probes = FakeProbes()
        value = CLI.feature_readiness(status(), settings(widget=False), probes)
        self.assertEqual(value['herdrAgents']['status'], 'missing')

        probes = FakeProbes()
        value = CLI.feature_readiness(status(lease=False), settings(), probes)
        self.assertEqual(value['herdrAgents']['status'], 'degraded')
        self.assertIn('lease', value['herdrAgents']['reason'])

    def test_chrome_missing_disabled_not_running_and_endpoint_unreachable(self):
        probes = FakeProbes()
        probes.providers['browser']['installed'] = False
        probes.providers['browser']['running'] = False
        value = CLI.feature_readiness(status(), settings(), probes)
        self.assertEqual(value['chromeProfilesTabs']['status'], 'missing')

        probes = FakeProbes()
        value = CLI.feature_readiness(status(), settings(badges=False, tabs=False), probes)
        self.assertEqual(value['chromeProfilesTabs']['status'], 'missing')

        probes = FakeProbes()
        probes.providers['browser']['running'] = False
        value = CLI.feature_readiness(status(), settings(), probes)
        self.assertEqual(value['chromeProfilesTabs']['status'], 'degraded')

        probes = FakeProbes()
        probes.endpoint = False
        value = CLI.feature_readiness(status(), settings(), probes)
        self.assertEqual(value['chromeProfilesTabs']['status'], 'degraded')
        self.assertIn('localhost:9333', value['chromeProfilesTabs']['reason'])
        self.assertIn('--user-data-dir', value['chromeProfilesTabs']['nextStep'])
        self.assertIn('security', value['chromeProfilesTabs']['nextStep'])

    def test_launcher_agent_and_cli_states(self):
        probes = FakeProbes()
        probes.providers['launcher']['installed'] = False
        probes.missing_launchers = ['smartdock-agent-cursor']
        probes.sync = 'stale'
        value = CLI.feature_readiness(status(), settings(), probes)
        self.assertEqual(value['launcherCounts']['status'], 'missing')
        self.assertEqual(value['agentLaunchers']['status'], 'missing')
        self.assertEqual(value['cliFreshness']['status'], 'degraded')

        probes = FakeProbes()
        probes.sync = 'live'
        value = CLI.feature_readiness(status(), settings(), probes)
        self.assertEqual(value['cliFreshness']['status'], 'ready')

        probes.sync = 'unknown'
        value = CLI.feature_readiness(status(), settings(), probes)
        self.assertEqual(value['cliFreshness']['status'], 'degraded')

    def test_contract_is_documented(self):
        reference = (ROOT / 'docs/CLI_REFERENCE.md').read_text(encoding='utf-8')
        self.assertIn('### Doctor feature readiness', reference)
        for key in CLI.FEATURE_ORDER:
            self.assertIn(key, reference)
        for field in ('"status"', '"reason"', '"nextStep"'):
            self.assertIn(field, reference)


FAKE_QS = r'''
import json, os, sys
args = sys.argv[1:]
calls = os.environ.get('QS_CALLS')
if args == ['list', '--all', '--json']:
    print(json.dumps([{'id':'qs-101','pid':101,'config_path':'/fake/shell.qml',
                       'shell_id':'','launch_time':'2026-09-26T12:00:00'}]))
    raise SystemExit(0)
request = json.loads(args[7])
if calls:
    with open(calls, 'a', encoding='utf-8') as handle:
        handle.write(request['command'] + '\n')
if request['command'] == 'status':
    data = {
        'runtime': {'mode':'plugin','instanceId':'101'},
        'configPath':'/tmp/dock.json',
        'loadState':'loaded','loadError':'','revision':1,
        'writeState':'saved','writeError':'','persisted':True,
        'defaultsInUse':False,
        'presentation': {
            'perMonitor':[{'connector':'DP-1','mode':'classic','source':'inherited',
                           'mapped':False,'sidebarSelected':False}],
            'widgets': {'rows':[]}
        }
    }
elif request['command'] == 'config.get':
    data = {'settings': {
        'sidebarWidgets': [],
        'browserProfileBadgesEnabled': False,
        'sidebarBrowserTabsEnabled': False
    }, 'source':'requested', 'view':'requested'}
else:
    print(json.dumps({'apiVersion':1,'ok':False,
                      'error':{'code':'E_USAGE','message':'unexpected command'},
                      'data':{},'warnings':[]}))
    raise SystemExit(0)
print(json.dumps({'apiVersion':1,'ok':True,'data':data,'warnings':[]}))
'''


class DoctorIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='dockrail doctor ')
        self.addCleanup(self.temp.cleanup)
        self.tmp = Path(self.temp.name)
        self.bin = self.tmp / 'bin'
        self.bin.mkdir()
        qs = self.bin / 'qs'
        qs.write_text('#!/usr/bin/python3\n' + FAKE_QS, encoding='utf-8')
        qs.chmod(0o755)
        self.calls = self.tmp / 'calls'
        self.env = dict(
            os.environ,
            HOME=str(self.tmp / 'home'),
            XDG_CONFIG_HOME=str(self.tmp / 'config'),
            XDG_DATA_HOME=str(self.tmp / 'data'),
            XDG_CACHE_HOME=str(self.tmp / 'cache'),
            XDG_DATA_DIRS=str(self.tmp / 'system-data'),
            PATH=str(self.bin) + ':/usr/bin:/bin',
            QS_CALLS=str(self.calls),
        )

    def run_doctor(self, *extra):
        return subprocess.run(
            ['bash', str(ROOT / 'scripts/smartdock'), 'doctor', *extra],
            env=self.env, text=True, capture_output=True, timeout=10)

    def test_nothing_optional_installed_is_clear_read_only_success(self):
        result = self.run_doctor()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Feature readiness:', result.stdout)
        self.assertIn('Sidebar: missing', result.stdout)
        self.assertIn('Herdr agents: missing', result.stdout)
        self.assertIn('Chrome profiles/tabs: missing', result.stdout)
        self.assertIn('Next:', result.stdout)
        calls = self.calls.read_text(encoding='utf-8').splitlines()
        self.assertEqual(calls, ['status', 'config.get'])
        for path in ('config', 'data', 'cache'):
            self.assertFalse((self.tmp / path).exists(), path)

    def test_json_is_additive_api_v1_with_stable_feature_shape(self):
        result = self.run_doctor('--json')
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(result.stdout)
        self.assertEqual(value['apiVersion'], 1)
        self.assertTrue(value['ok'])
        self.assertEqual(list(value['data']['features']), list(CLI.FEATURE_ORDER))
        for feature in value['data']['features'].values():
            self.assertEqual(set(feature), {'status', 'reason', 'nextStep'})
            self.assertIn(feature['status'], ('ready', 'missing', 'degraded'))


if __name__ == '__main__':
    unittest.main()
