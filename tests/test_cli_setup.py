#!/usr/bin/env python3
import copy
import contextlib
import importlib.util
import io
import json
import subprocess
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    'smartdock_cli_setup', ROOT / 'scripts/smartdock_cli.py')
CLI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CLI)


def ok(data):
    return {'apiVersion': 1, 'ok': True, 'data': data, 'warnings': []}


def host_status(sidebar=False):
    return {
        'runtime': {'mode': 'plugin', 'instanceId': '77'},
        'configPath': '/tmp/dockrail-test.json',
        'loadState': 'loaded',
        'loadError': '',
        'loadPending': False,
        'revision': 4,
        'writeState': 'saved',
        'writeError': '',
        'persisted': True,
        'defaultsInUse': False,
        'presentation': {
            'perMonitor': [
                {'connector': 'DP-1', 'mode': 'sidebar' if sidebar else 'classic',
                 'source': 'explicit', 'mapped': sidebar, 'sidebarSelected': sidebar},
                {'connector': 'HDMI-A-1', 'mode': 'classic',
                 'source': 'explicit', 'mapped': False, 'sidebarSelected': False},
            ],
            'widgets': {
                'rows': [{
                    'id': 'herdr.agents',
                    'registered': True,
                    'available': True,
                    'status': 'ready',
                    'revision': 1,
                    'active': False,
                    'errorCode': '',
                }],
            },
        },
    }


class FakeTransport:
    def __init__(self):
        self.instance = {'id': 'qs-test', 'pid': 77}
        self.status_data = host_status()
        self.settings = {
            'sidebarWidgets': ['widget.one', 'widget.two'],
            'presentationModeByMonitor': {
                'DP-1': 'classic',
                'USB-C-1': 'classic',
            },
            'browserProfileBadgesEnabled': True,
            'sidebarBrowserTabsEnabled': True,
            'controlCommand': 'do-not-execute-this',
            'extensionData': {'opaque': ['keep', 7]},
        }
        self.calls = []

    def select(self, runtime='auto', instance_id=None):
        return self.instance, ok(copy.deepcopy(self.status_data))

    def request(self, instance, command, arguments=None, probe=False):
        self.calls.append((command, copy.deepcopy(arguments or {})))
        if command == 'status':
            return ok(copy.deepcopy(self.status_data))
        if command == 'config.get':
            return ok({
                'settings': copy.deepcopy(self.settings),
                'source': 'requested',
                'view': 'requested',
            })
        if command != 'config.apply':
            raise AssertionError('Unexpected request: ' + command)

        arguments = arguments or {}
        patch_value = copy.deepcopy(arguments['patch'])
        dry_run = arguments.get('dryRun') is True
        proposed = copy.deepcopy(self.settings)
        proposed.update(patch_value)
        noop = proposed == self.settings
        changed_keys = [] if noop else list(patch_value)

        if not dry_run and not noop:
            self.settings = proposed
            self.status_data['revision'] += 1

        mutation_status = copy.deepcopy(self.status_data)
        mutation_status.update({
            'persisted': False if dry_run else True,
            'applied': False if dry_run else not noop,
            'noop': noop,
            'changedKeys': changed_keys,
            'requested': proposed,
            'effective': proposed,
            'dryRun': dry_run,
            'sourcePersisted': True,
            'diff': {},
            'themeResolution': 'not-reported',
        })
        return ok(mutation_status)


class FakeProbes:
    def __init__(self):
        self.herdr_path = '/fake/herdr'
        self.herdr = (0, 9, 1)
        self.providers = {
            'browser': {
                'path': '/fake/browser-provider',
                'installed': True,
                'running': True,
                'argv': ['/fake/browser-provider', '--port', '9222'],
            },
            'launcher': {
                'path': '/fake/launcher-provider',
                'installed': True,
                'running': False,
                'argv': [],
            },
        }
        self.endpoint = True
        self.missing_launchers = []
        self.root = Path('/fake/plugin')

    def which(self, command):
        return self.herdr_path if command == 'herdr' else None

    def herdr_version(self, executable):
        self.last_herdr = executable
        return self.herdr

    def provider(self, kind):
        return copy.deepcopy(self.providers[kind])

    def devtools_reachable(self, port):
        self.last_port = port
        return self.endpoint

    def missing_agent_launchers(self):
        return list(self.missing_launchers)

    def cli_sync(self, runtime_mode):
        self.last_runtime = runtime_mode
        return 'live'

    def _runtime_root(self, runtime_mode):
        return self.root

    def _home(self):
        return Path('/home/tester')

    def _config_home(self):
        return Path('/home/tester/.config')


class FakeActions:
    def __init__(self):
        self.browser_calls = 0
        self.agent_calls = 0
        self.manual_calls = 0

    def install_browser_provider(self):
        self.browser_calls += 1
        return {'script': '/fake/plugin/scripts/install-browser-profile-provider'}

    def install_agent_launchers(self):
        self.agent_calls += 1
        return {'script': '/fake/plugin/install.sh'}

    def launcher_counts_command(self):
        self.manual_calls += 1
        return "bash '/fake/plugin/scripts/build-launcher-badge-provider'"


class SetupTests(unittest.TestCase):
    def setUp(self):
        self.transport = FakeTransport()
        self.probes = FakeProbes()
        self.actions = FakeActions()
        self.checks = {
            'python': True,
            'quickshell': True,
            'omarchyShell': True,
            'liveRuntime': True,
        }

    def parsed(self, *arguments):
        return CLI.build_parser().parse_args(['setup', *arguments])

    def run_scripted(self, feature):
        instance, status = self.transport.select()
        return CLI.run_setup(
            self.transport,
            instance,
            status,
            self.parsed('--feature', feature, '--yes'),
            self.checks,
            probes=self.probes,
            actions=self.actions,
            stdin_is_tty=False)

    def apply_calls(self):
        return [call for call in self.transport.calls if call[0] == 'config.apply']

    def test_final_scripted_feature_names_only(self):
        self.assertEqual(
            CLI.SETUP_FEATURES,
            ('chrome', 'herdr', 'launcher-counts', 'agent-launchers'))
        for feature in CLI.SETUP_FEATURES:
            parsed = self.parsed('--feature', feature, '--yes')
            self.assertEqual(parsed.feature, feature)
            self.assertTrue(parsed.yes)
        with self.assertRaises(CLI.CliError):
            self.parsed('--feature', 'sidebar', '--yes')

    def test_prompt_delay_does_not_consume_discovery_deadline(self):
        transport = CLI.Transport()
        transport.deadline = 0  # Simulate a user spending over eight seconds reading.
        timeouts = []

        def run(argv, **kwargs):
            timeouts.append(kwargs['timeout'])
            payload = json.loads(argv[-1])
            reply = self.transport.request(
                self.transport.instance, payload['command'], payload['arguments'])
            return subprocess.CompletedProcess(argv, 0, json.dumps(reply), '')

        args = CLI.build_parser().parse_args(['setup'])
        with patch.object(CLI.subprocess, 'run', side_effect=run), contextlib.redirect_stdout(io.StringIO()):
            reply = CLI.run_setup(
                transport, self.transport.instance, ok(self.transport.status_data),
                args, {}, probes=self.probes, actions=self.actions,
                input_fn=lambda prompt: 'n', stdin_is_tty=True)
        self.assertTrue(reply['ok'])
        self.assertTrue(timeouts)
        self.assertEqual(set(timeouts), {transport.timeout})

    def test_herdr_dry_run_apply_readback_preserves_widget_order_and_unknown_settings(self):
        original_unknown = copy.deepcopy(self.transport.settings['extensionData'])
        original_control = self.transport.settings['controlCommand']

        reply = self.run_scripted('herdr')
        calls = self.apply_calls()
        self.assertEqual(len(calls), 2)
        self.assertTrue(calls[0][1]['dryRun'])
        self.assertFalse(calls[1][1]['dryRun'])
        expected_widgets = ['widget.one', 'widget.two', 'herdr.agents']
        self.assertEqual(calls[0][1]['patch'], {'sidebarWidgets': expected_widgets})
        self.assertEqual(self.transport.settings['sidebarWidgets'], expected_widgets)
        self.assertEqual(self.transport.settings['extensionData'], original_unknown)
        self.assertEqual(self.transport.settings['controlCommand'], original_control)
        action = reply['data']['actions'][0]
        self.assertEqual(action['feature'], 'herdr')
        self.assertEqual(action['status'], 'changed')
        self.assertTrue(action['mutation']['applied'])
        self.assertTrue(action['mutation']['persisted'])

        before = len(self.apply_calls())
        second = self.run_scripted('herdr')
        self.assertEqual(len(self.apply_calls()), before)
        self.assertEqual(self.transport.settings['sidebarWidgets'], expected_widgets)
        self.assertEqual(second['data']['actions'][0]['status'], 'unchanged')

    def test_old_herdr_is_enabled_but_warns_about_click_to_focus(self):
        self.probes.herdr = (0, 8, 2)
        reply = self.run_scripted('herdr')
        self.assertIn('0.9.1', reply['data']['actions'][0]['message'])
        self.assertIn('herdr.agents', self.transport.settings['sidebarWidgets'])

    def test_missing_herdr_refuses_mutation(self):
        self.probes.herdr_path = None
        reply = self.run_scripted('herdr')
        self.assertEqual(self.apply_calls(), [])
        action = reply['data']['actions'][0]
        self.assertEqual(action['status'], 'unavailable')
        self.assertIn('Herdr 0.9.1', action['message'])

    def test_chrome_uses_fake_installer_and_only_prints_manual_flags(self):
        self.probes.providers['browser']['installed'] = False
        self.probes.providers['browser']['running'] = False
        reply = self.run_scripted('chrome')
        self.assertEqual(self.actions.browser_calls, 1)
        self.assertEqual(self.apply_calls(), [])
        self.assertTrue(reply['data']['reloadNeeded'])
        self.assertTrue(reply['data']['chromeRestartNeeded'])
        message = reply['data']['actions'][0]['message']
        self.assertIn('--user-data-dir=/home/tester/.config/google-chrome-debug', message)
        self.assertIn('--remote-debugging-port=9222', message)
        self.assertIn('any local process', message)
        self.assertIn('never edits chrome-flags.conf', message)

    def test_agent_launchers_use_existing_assets_path_without_config_write(self):
        self.probes.missing_launchers = ['smartdock-agent-cursor']
        reply = self.run_scripted('agent-launchers')
        self.assertEqual(self.actions.agent_calls, 1)
        self.assertEqual(self.apply_calls(), [])
        self.assertTrue(reply['data']['reloadNeeded'])

    def test_launcher_counts_never_builds_automatically(self):
        self.probes.providers['launcher']['installed'] = False
        reply = self.run_scripted('launcher-counts')
        self.assertEqual(self.actions.browser_calls, 0)
        self.assertEqual(self.actions.agent_calls, 0)
        self.assertEqual(self.actions.manual_calls, 1)
        self.assertEqual(self.apply_calls(), [])
        action = reply['data']['actions'][0]
        self.assertEqual(action['status'], 'manual')
        self.assertIn('never builds launcher counts automatically', action['message'])
        self.assertIn('build-launcher-badge-provider', action['message'])

    def test_interactive_sidebar_writes_one_monitor_entry_and_preserves_others(self):
        self.probes.herdr_path = None
        answers = iter(['yes', '2'])
        instance, status = self.transport.select()
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            reply = CLI.run_setup(
                self.transport,
                instance,
                status,
                self.parsed(),
                self.checks,
                probes=self.probes,
                actions=self.actions,
                input_fn=lambda prompt: next(answers),
                stdin_is_tty=True)
        self.assertIn('Feature readiness:', output.getvalue())
        calls = self.apply_calls()
        self.assertEqual(len(calls), 2)
        expected = {
            'DP-1': 'classic',
            'USB-C-1': 'classic',
            'HDMI-A-1': 'sidebar',
        }
        self.assertEqual(calls[0][1]['patch'], {'presentationModeByMonitor': expected})
        self.assertEqual(self.transport.settings['presentationModeByMonitor'], expected)
        self.assertEqual(reply['data']['actions'][0]['feature'], 'sidebar')

    def test_non_tty_requires_scripted_feature_yes(self):
        instance, status = self.transport.select()
        with self.assertRaises(CLI.CliError) as caught:
            CLI.run_setup(
                self.transport,
                instance,
                status,
                self.parsed(),
                self.checks,
                probes=self.probes,
                actions=self.actions,
                stdin_is_tty=False)
        self.assertEqual(caught.exception.code, 'E_USAGE')
        self.assertEqual(self.apply_calls(), [])

    def test_no_host_refuses_before_setup_actions_or_mutations(self):
        class NoHost:
            def select(self, runtime='auto', instance_id=None):
                raise CLI.CliError('E_RUNTIME_NOT_FOUND', 'No host.')

        parsed = self.parsed('--feature', 'herdr', '--yes')
        with patch.object(CLI, 'Transport', return_value=NoHost()), \
                patch.object(CLI, 'SetupActions', side_effect=AssertionError('must not instantiate')):
            with self.assertRaises(CLI.CliError) as caught:
                CLI.execute(parsed)
        self.assertEqual(caught.exception.code, 'E_RUNTIME_NOT_FOUND')


if __name__ == '__main__':
    unittest.main()
