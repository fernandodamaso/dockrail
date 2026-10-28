#!/usr/bin/env python3
"""Settings' fixed-action broker: never a generic command runner.

This is a separate process so widget validation/creation cannot block the QML
render thread. The only dynamic arguments are individually validated inputs;
launcher argv is constant. This module does not touch dock.json.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

from smartdock_widget import Store, WidgetError, envelope, error_envelope, is_git_source, validate_manifest, valid_widget_id

MAX_INPUT = 2048
MAX_NAME = 128


def explicit_source(source):
    if not isinstance(source, str) or not source or len(source) > MAX_INPUT or any(c in source for c in '\r\n\0'):
        raise WidgetError('E_VALIDATION', 'An explicit local folder or repository URL is required.')
    if is_git_source(source):
        return source
    if not Path(source).is_absolute():
        raise WidgetError('E_SOURCE', 'Local Widget sources must be absolute directory paths.')
    return source


def inspect_install(store, source):
    source = explicit_source(source)
    with store.resolved_source(source) as (root, metadata):
        manifest = validate_manifest(root)
        existing = (store.root / manifest['id']).exists()
        return {
            'source': source, 'id': manifest['id'], 'name': manifest['name'],
            'replacesExisting': existing, 'canInstall': not existing,
            'requiresConfirmation': True, 'manifest': manifest,
        }


def execute(action, widget_id=None, name=None, source=None, expected_manifest=None, store=None, launcher_runner=None):
    store = store or Store()
    if action == 'prepare-install':
        return envelope({'confirmation': inspect_install(store, source)})
    if action == 'create':
        if not valid_widget_id(widget_id):
            raise WidgetError('E_VALIDATION', 'Invalid Widget ID.')
        if not isinstance(name, str) or not name.strip() or len(name) > MAX_NAME or any(c in name for c in '\r\n\0'):
            raise WidgetError('E_VALIDATION', 'Widget name must be 1-128 characters without control lines.')
        return envelope({'created': store.create(widget_id, name), 'enabled': False,
                         'nextAction': 'offer-open-folder'})
    if action == 'install':
        if not isinstance(expected_manifest, dict) or not valid_widget_id(expected_manifest.get('id')):
            raise WidgetError('E_CONFIRMATION', 'Install requires a reviewed Widget manifest.')
        package = store.install(explicit_source(source), expected_manifest=expected_manifest)
        return envelope({'package': package, 'enabledBySettings': False})
    if action in ('launchers-add', 'launchers-remove'):
        # INF-4 owns these commands and their file ownership tracking.
        # A missing INF-4 implementation fails closed; never emulate --agent-assets-only.
        runner = launcher_runner or subprocess.run
        argv = ['dockrail', 'launchers', 'add' if action == 'launchers-add' else 'remove', '--json']
        try:
            completed = runner(argv, shell=False, stdin=subprocess.DEVNULL,
                               capture_output=True, text=True, timeout=60, check=False)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise WidgetError('E_UNAVAILABLE', 'Launcher management is not available: ' + type(error).__name__) from error
        if completed.returncode:
            raise WidgetError('E_UNAVAILABLE', 'Launcher manager (INF-4) is unavailable or failed.')
        try:
            reply = json.loads(completed.stdout)
            if reply.get('ok') is not True:
                raise WidgetError('E_UNAVAILABLE', 'Launcher manager rejected this action.')
        except (ValueError, AttributeError) as error:
            raise WidgetError('E_PROTOCOL', 'Launcher manager did not return valid JSON.') from error
        return envelope({'launchers': reply.get('data', {})})
    raise WidgetError('E_USAGE', 'Unsupported Settings action.')


def main(argv=None):
    parser = argparse.ArgumentParser(prog='dockrail-settings-actions')
    parser.add_argument('action', choices=['prepare-install', 'create', 'install', 'launchers-add', 'launchers-remove'])
    parser.add_argument('--id')
    parser.add_argument('--name')
    parser.add_argument('--source')
    parser.add_argument('--expected-manifest')
    args = parser.parse_args(argv)
    try:
        result = execute(args.action, widget_id=args.id, name=args.name, source=args.source,
                         expected_manifest=json.loads(args.expected_manifest) if args.expected_manifest else None)
    except WidgetError as error:
        result = error_envelope(error)
    except (OSError, ValueError) as error:
        result = error_envelope(WidgetError('E_ACTION', 'Settings action could not finish: ' + type(error).__name__))
    print(json.dumps(result, ensure_ascii=False, allow_nan=False))
    return 0 if result['ok'] else 1


if __name__ == '__main__':
    sys.exit(main())
