import importlib.util
from pathlib import Path
from types import SimpleNamespace
from unittest import TestCase, mock
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    'settings_actions', ROOT / 'scripts/smartdock_settings_actions.py')
import sys
sys.path.insert(0, str(ROOT / 'scripts'))
actions = importlib.util.module_from_spec(spec)
spec.loader.exec_module(actions)


class FakeStore:
    def __init__(self, base):
        self.base = Path(base)
        self.root = self.base / 'installed'
        self.calls = []
    def resolved_source(self, source):
        from contextlib import contextmanager
        @contextmanager
        def source_context():
            self.calls.append(('source', source))
            yield self.base / 'source', {'type': 'local'}
        return source_context()
    def create(self, widget_id, name):
        self.calls.append(('create', widget_id, name))
        return {'id': widget_id, 'name': name, 'sourcePath': str(self.base / widget_id)}
    def install(self, source):
        self.calls.append(('install', source))
        return {'id': 'sample.widget', 'name': 'Sample', 'enabled': False}


class SettingsTypedActionsTests(TestCase):
    def test_create_validates_and_never_installs_or_enables(self):
        with tempfile.TemporaryDirectory() as base:
            store = FakeStore(base)
            data = actions.execute('create', widget_id='sample.widget', name='Example', store=store)
            self.assertTrue(data['ok'])
            self.assertFalse(data['data']['enabled'])
            self.assertEqual(data['data']['nextAction'], 'offer-open-folder')
            self.assertEqual(store.calls, [('create','sample.widget','Example')])
            for widget_id in ('../escape', '--help', 'foo;touch /tmp/hack', '__proto__'):
                with self.assertRaises(actions.WidgetError):
                    actions.execute('create', widget_id=widget_id, name='Example', store=store)
            for name in ('', 'hello\nworld'):
                with self.assertRaises(actions.WidgetError):
                    actions.execute('create', widget_id='valid.widget', name=name, store=store)
            self.assertEqual(store.calls, [('create','sample.widget','Example')])

    def test_inspect_and_install_require_explicit_sources_and_manifest(self):
        with tempfile.TemporaryDirectory() as base:
            store = FakeStore(base)
            source = str(Path(base) / 'source')
            with mock.patch.object(actions, 'validate_manifest', return_value={'id':'sample.widget','name':'Sample'}):
                confirmation = actions.execute('prepare-install', source=source, store=store)['data']['confirmation']
                self.assertEqual(confirmation['source'], source)
                self.assertTrue(confirmation['requiresConfirmation'])
                self.assertFalse(confirmation['replacesExisting'])
                outcome = actions.execute('install', source=source, store=store)
                self.assertFalse(outcome['data']['enabledBySettings'])
                self.assertIn(('install',source),store.calls)
                store.root.mkdir()
                (store.root / 'sample.widget').mkdir()
                blocked = actions.execute('prepare-install', source=source, store=store)['data']['confirmation']
                self.assertTrue(blocked['replacesExisting'])
                self.assertFalse(blocked['canInstall'])
                with self.assertRaises(actions.WidgetError) as rejection:
                    actions.execute('install', source=source, store=store)
                self.assertEqual(rejection.exception.code, 'E_CONFLICT')
            for source in ('widget', '/tmp/new\nother', '--delete-all'):
                with self.assertRaises(actions.WidgetError):
                    actions.execute('prepare-install', source=source, store=store)

    def test_launcher_argv_is_fixed_and_error_is_structured(self):
        with tempfile.TemporaryDirectory() as base:
            store = FakeStore(base)
            calls = []
            def runner(argv, **kw):
                calls.append((argv,kw))
                return SimpleNamespace(returncode=0, stdout='{"ok":true,"data":{"added":2}}')
            added = actions.execute('launchers-add',store=store,launcher_runner=runner)
            removed = actions.execute('launchers-remove',store=store,launcher_runner=runner)
            self.assertEqual([c[0] for c in calls],
                             [['dockrail','launchers','add','--json'],['dockrail','launchers','remove','--json']])
            self.assertTrue(all(c[1]['shell'] is False for c in calls))
            self.assertEqual(added['data']['launchers'], {'added':2})
            self.assertTrue(removed['ok'])
            def missing(argv, **kw):
                return SimpleNamespace(returncode=2,stdout='')
            with self.assertRaises(actions.WidgetError) as err:
                actions.execute('launchers-add',store=store,launcher_runner=missing)
            self.assertEqual(err.exception.code,'E_UNAVAILABLE')
            with self.assertRaises(actions.WidgetError):
                actions.execute('sh -c evil',store=store,launcher_runner=runner)
