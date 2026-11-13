# Updating Dockrail

Dockrail is installed as a Git-managed Omarchy plugin from the public
`fernandodamaso/dockrail` repository. Update it with:

```bash
omarchy plugin update io.github.fernandodamaso.dockrail --yes
```

Updates pull the repository's default `main` branch. They preserve the
canonical user configuration at `~/.config/dockrail/dock.json` (or its
`XDG_CONFIG_HOME` equivalent). The existing 3.x legacy SmartDock migration
compatibility is retained; updating the plugin does not reset user settings.

If you have temporarily linked a development checkout with `dockrail dev use`,
run `dockrail dev reset` **before** updating the installed plugin. Otherwise
the update could affect the linked source checkout.

Installed plugin files are deployment state and must not be edited directly.
Contributors should use a separate source clone and deliver changes through
a reviewed pull request to `main`.

## Fast-forward failures

Omarchy updates the installed checkout with a fast-forward-only pull. A
fast-forward failure means the installed checkout has local changes or no
longer follows the repository history. Preserve intentional edits in a
separate checkout before reinstalling from the public repository; do not
repair the deployed plugin by editing its files in place.

## Standalone installations

The `dockrail update` command applies to an installed **standalone** copy
from its local source; it does not update the Omarchy plugin. Use the
`omarchy plugin update` command above for plugin installations.
