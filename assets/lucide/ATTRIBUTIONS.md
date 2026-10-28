# Lucide icons

The SVGs in this directory are from the Lucide icon library:

- Source: https://github.com/lucide-icons/lucide
- Icon pages: https://lucide.dev/icons/
- License: ISC (see https://github.com/lucide-icons/lucide/blob/main/LICENSE)

Bundled icons include:

- `app-window`, `arrow-right-left`, `bot`, `chevron-left`, `chevron-right`, `earth`,
  `eye`, `eye-off`, `focus`, `folder-open`, `layout-grid`, `maximize-2`,
  `minimize-2`, `minus`, `monitor`, `mouse-pointer-click`, `move`, `palette`,
  `panel-bottom`, `panel-left-close`, `panel-left-open`, `pin`, `pin-off`,
  `plus`, `rocket`, `rotate-ccw`, `settings`, `settings-2`, `sparkles`, `square`,
  `terminal`, `trash-2`, `x`, `search`, `check`, `chevron-down`, `circle-alert`,
  `cloud-off`, `inbox`, `loader-circle`, `clock-3`, `image`

They are bundled locally so the dock does not need a network connection at runtime.

`catalog.json.gz` contains the Lucide SVG shapes and name aliases used for T3
project icons. The shapes were extracted from the installed T3 Code
`0.1.3-nightly.20261024.3617` frontend (commit `27e0c684c585`), including its
Lucide name aliases. The deterministic gzip contains a JSON name-to-SVG map;
no JavaScript executes at runtime. The SVGs use a neutral stroke for the
existing WidgetIcon tint renderer. See the bundled `LICENSE` for Lucide's ISC
and inherited Feather MIT notices. Unknown names fall back to project initials.
