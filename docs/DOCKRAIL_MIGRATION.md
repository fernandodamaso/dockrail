# Dockrail migration contract

This is the source-controlled migration matrix for FDM-1002. It distinguishes intentional SmartDock compatibility contracts from branding leftovers.

## Pinned baseline

- Source baseline: `4db288d5991dae7989add897ee5dc56c5542feb8`
- Pinned when FDM-1002 execution began on 2026-09-25.
- Repository cutover completed on 2026-09-25 after the MIG-05 native rehearsal (FDM-1010) passed on `92430da`.
- Omarchy/Quickshell/Hyprland native revisions are recorded by MIG-05, not guessed here.

## Identifier and ownership matrix

| Identifier/state | Policy |
| --- | --- |
| Product/display name | Rename to Dockrail in the branding slice. |
| `dockrail` CLI | Canonical command. |
| `smartdock` CLI | Retain as a thin compatibility entry point. |
| canonical Dockrail XDG roots | Activate only through the journaled MIG-02 migration. |
| legacy SmartDock XDG roots | Preserve as source/recovery state; never silently reset. |
| `DOCKRAIL_CONFIG` | Canonical explicit override. |
| `SMARTDOCK_CONFIG` | Retain; canonical non-empty override wins when both are set. |
| `smartdock` IPC target, `request`, apiVersion 1 | Retain unchanged. |
| plugin ID | `io.github.fernandodamaso.dockrail` from 3.0.0; legacy `io.github.fernandodamaso.smartdock` installs are removed and re-added once (see MIG-06). |
| `SmartDock.WidgetKit 1.0` | Retain; MIG-03 adds `Dockrail.WidgetKit 1.0` over the same maintained components. |
| `special:smartdock-minimized` | Retain unchanged. |
| terminal-agent desktop/application IDs | Retain stable IDs. |
| Herdr helper/provider executable names | Retain executable identities. |
| Wayland layer namespaces | Retain unchanged. |
| development recovery records/worktrees | Preserve; rebase only by explicit migration policy. |
| external widget/icon/source paths | Preserve verbatim. |
| `DockHost`, `DockModel`, `DockItem`, `dock.json` | Keep as dock-domain internals. |
| historical issues/releases/plans | Keep historical names. |

## Read-only resolver contract

`scripts/dockrail_paths.py` computes canonical and legacy roots without creating,
migrating, repairing, or deleting anything. Explicit config precedence is:
non-empty `DOCKRAIL_CONFIG`, then non-empty `SMARTDOCK_CONFIG`, then the canonical
XDG config path. An explicit missing/invalid path is authoritative and must not
fall through silently.

The migration journal/lock will live outside roots being moved under the XDG
state home in `dockrail/migrations/`. MIG-02 owns transaction/recovery and startup activation.

Read-only CLI calls, bare/help, discovery, `--cli-only`, and
`--agent-assets-only` must never initiate migration. Omarchy plugin update cannot
assume `install.sh` runs, so MIG-02 owns the single service-start bootstrap.

## Cutover gate

GitHub repository rename, canonical URL replacement, Linear project rename and
the Dockrail 3.0.0 release were gated on a real legacy plugin + standalone
upgrade rehearsal. That gate passed in MIG-05; see the MIG-06 section below.
The old GitHub name is preserved as a redirect and is not recreated as a second
repository.

## MIG-02 startup and transaction contract

Production plugin startup is service-owned. `Service.qml` owns exactly one
`DockMigrationBootstrap`; provider services are created only after that bootstrap
returns a validated ready result. `Overlay.qml` consumes the same result and
does not resolve config/data roots independently. Standalone `shell.qml` uses
the same bootstrap before creating DockHost or Herdr.

The migration coordinator is `scripts/dockrail_migrate.py`. It:

1. acquires the coordinator lock under
   `${XDG_STATE_HOME:-$HOME/.local/state}/dockrail/migrations/`;
2. validates canonical and legacy config state without repairing either;
3. refuses a pending migration while plugin or Widget development overrides are
   active, while the Widget package lock is busy, or while a standalone writer
   has not been explicitly handed off;
4. stages config and shared `widgets/` + `providers/` on their target
   filesystems and records a source signature;
5. publishes canonical roots without overwriting established canonical state;
6. preserves recovery copies in the migration transaction directory;
7. replaces only the managed legacy config/package/provider roots with aliases
   to canonical state; and
8. marks the journal committed only after those aliases validate.

Interrupted `staged`, `published`, or `aliased` transactions are resumed
idempotently. A source change after staging blocks recovery rather than
publishing stale state. Once committed canonical state validates, later active
development does not block ordinary startup.

### Canonical roots after MIG-02

- config: `${XDG_CONFIG_HOME:-$HOME/.config}/dockrail/`
- shared/deployment data: `${XDG_DATA_HOME:-$HOME/.local/share}/dockrail/`
- client bundle: `${XDG_DATA_HOME:-$HOME/.local/share}/dockrail-cli/`
- cache: `${XDG_CACHE_HOME:-$HOME/.cache}/dockrail/`

The stable desktop/autostart IDs, IPC target, minimized-workspace
name, Wayland namespaces, terminal-agent IDs, Herdr executable identities and
legacy WidgetKit import remain unchanged.

### Non-migrating paths

`install.sh --cli-only`, `--agent-assets-only`, bare/help/status/schema
discovery, and ordinary IPC reads do not invoke the migration transaction.
A CLI-only bundle may discover a pre-cutover legacy client/application bundle,
but it does not move shared state.

### Removal boundary

Standalone uninstall removes deployment-owned files from the canonical data
root but preserves shared `widgets/` and `providers/`. `--purge` refuses
to delete configuration while the Omarchy plugin (including its saved
development backup) is present. External Widget source repositories, icon
files, Git worktrees and Herdr-owned external state are never recursively
deleted by this migration.


## MIG-03 WidgetKit and package compatibility

Dockrail exposes `Dockrail.WidgetKit 1.0` as the canonical public QML module while
retaining `SmartDock.WidgetKit 1.0` for existing Widget sources. Both named module
surfaces reference the same maintained files under `components/widgets/`; they are
not independent component implementations.

New package installation and development snapshots materialize one local
`Dockrail/WidgetKit` runtime copy and rewrite either named import to that
package-relative runtime path. The rewrite preserves aliases, comments and nested
QML-relative paths. Source repositories are never modified.

Existing installed/development snapshots that already contain
`SmartDock/WidgetKit` remain valid and are not rewritten merely because the
product acquired a canonical Dockrail module name. Legacy metadata filenames,
package IDs, registry ordering and source locations remain compatibility
contracts. Both module surfaces ship in full and CLI-only bundles so source
validation and package preparation do not depend on a separate checkout.


## MIG-04 product-facing branding

Current product-facing identity is Dockrail. The manifest display name/author,
standalone desktop entry, canonical CLI help/diagnostics, installer/uninstaller
output, Widget scaffolds and active documentation use Dockrail terminology and
the `dockrail` command.

This branding pass deliberately does **not** rename compatibility contracts:
the plugin ID (changed later in MIG-06), the `smartdock` IPC target,
`special:smartdock-minimized`, terminal-agent/application IDs, Wayland layer
namespaces, `smartdock-herdr-helper`, `smartdock-herdr-provider`,
`SmartDock.WidgetKit 1.0`, legacy XDG aliases/recovery records, historical
plans/releases. The GitHub repository URL moved in MIG-06 (see below).

The optional launcher-badge and browser-profile installer scripts now install
their binaries under the canonical Dockrail data root so they match the MIG-02
provider consumers; executable filenames remain unchanged.


## MIG-06 repository cutover

MIG-05 (FDM-1010) qualified exact head `92430da5d18fea307ea52fc6c2012a8522b8b77d`
on Omarchy 4.0.4 / Hyprland 0.56.2: a native plugin update with dev-override
refusal and a committed migration, dev reset and minimized-window recovery across
restart, plus an isolated frozen-legacy (`5a619f4`) standalone upgrade with
injected interruption at every phase and removal-ownership checks.

The repository was then renamed in place to `fernandodamaso/dockrail`. The
old `fernandodamaso/smart-omarchy-dock` name remains a GitHub redirect and must
never be recreated. Existing plugin checkouts keep their old origin URL and
continue updating through that redirect. Upstream attribution to
`nick-friedrich/hyprland-dock` and the fork relationship are unchanged. The
repository had no GitHub Pages site or external Actions consumers to migrate.
The GitHub rename did not rename local checkout directories.

Current installation examples use `https://github.com/fernandodamaso/dockrail.git`.
The plugin ID changed from `io.github.fernandodamaso.smartdock` to
`io.github.fernandodamaso.dockrail` so the permanent marketplace identity matches
the product. Omarchy names the plugin directory and keys enabled state by the
manifest ID, so an in-place `omarchy plugin update` of a legacy install is not
supported across this change. Existing installs run
`omarchy plugin remove io.github.fernandodamaso.smartdock --yes` and then
`omarchy plugin add https://github.com/fernandodamaso/dockrail.git --enable --yes`.
Settings, Widget packages, providers and migration state live under the
Dockrail XDG roots and are not touched by plugin removal. Migration
development-override detection and `uninstall.sh --purge` refusal recognize
both IDs.
