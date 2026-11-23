# Recording Dockrail demo clips

Record these on a real Omarchy desktop after the dock is installed and
running. Each clip is 3 to 8 seconds. Save the GIF under `docs/media/` at
about 800 px wide, 15 fps, and under 5 MB. Then uncomment the matching
`<img>` tag in `README.md`.

Do not commit a stand-in or generated placeholder. `preview.png` stays the
hero until `hero.gif` exists.

Use `slurp` to pick the region, `wf-recorder` or `wl-screenrec` to capture,
and `ffmpeg` to build the GIF. Hyprland speaks the `wlr-screencopy` protocol
both recorders use.

## Shot list

| File | Length | What to show |
| --- | --- | --- |
| `docs/media/hero.gif` | 5 s | The bottom dock. Move the pointer across the icons so one magnifies, and keep a running-app indicator visible. |
| `docs/media/autohide.gif` | 6 s | With `autoHide` on, move the pointer away until the dock hides, then touch the screen edge so it reveals. |
| `docs/media/workspaces.gif` | 5 s | Click two chips on the trailing workspace switcher. The focused workspace changes. |
| `docs/media/pinning.gif` | 6 s | Drag one pinned icon past another and release. The new order stays. |
| `docs/media/theming.gif` | 6 s | Switch the Omarchy theme. The dock colors, border, and type follow. |
| `docs/media/sidebar.gif` | 6 s | Drag empty dock background to the left until that monitor commits to the sidebar. |

Turn auto-hide on only for the auto-hide clip, then set it back if that is
not your normal dock:

```bash
dockrail config set autoHide true --json
```

Switch themes from Omarchy's theme picker. The sidebar clip uses the existing
empty-background drag. It writes one `presentationModeByMonitor` entry for
that monitor.

## Capture

Install the tools if they are missing. On Omarchy that is Arch packages
`wf-recorder`, `slurp`, and `ffmpeg`. `wl-screenrec` is an alternative
capture tool when it is already installed.

Pick a region, then record for a few seconds. `timeout` sends Ctrl-C
(`SIGINT`) so the recorder finishes the file.

`wf-recorder`:

```bash
geom="$(slurp)"
timeout --signal=INT 5 wf-recorder -g "$geom" -f /tmp/dockrail-hero.mp4
```

`wl-screenrec` uses the same geometry string:

```bash
geom="$(slurp)"
timeout --signal=INT 5 wl-screenrec -g "$geom" -f /tmp/dockrail-hero.mp4
```

Use 6 instead of 5 for the auto-hide, pinning, theming, and sidebar clips.
Keep the pointer and the dock inside the region you selected. A region that
crosses two monitors is a poor `wl-screenrec` target. Capture one output.

## Convert

Palette GIF conversion, about 800 px wide and 15 fps:

```bash
src=/tmp/dockrail-hero.mp4
dest=docs/media/hero.gif
ffmpeg -y -i "$src" -vf "fps=15,scale=800:-1:flags=lanczos,palettegen" /tmp/dockrail-palette.png
ffmpeg -y -i "$src" -i /tmp/dockrail-palette.png \
  -lavfi "fps=15,scale=800:-1:flags=lanczos[x];[x][1:v]paletteuse" \
  "$dest"
stat -c%s "$dest"
```

`stat` prints the size in bytes. Keep it under 5000000. If the GIF is
larger, record a shorter clip or drop to `fps=12` in both `ffmpeg`
commands and run them again. Repeat with the matching `/tmp` file and
`docs/media/<name>.gif` for each row in the shot list.

After a real GIF is in `docs/media/`, uncomment its `<img width="800">` tag
in `README.md`. Leave `preview.png` in place as the still hero.
