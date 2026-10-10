# omarchy-hw-monitor — agent notes

Fork of `meviusisback/omarchy-hw-monitor` (Omarchy bar widget + system panel),
plugin id `zoltanf.hw-monitor`, public GitHub repo `zoltanf/omarchy-hw-monitor`
(a GitHub fork of upstream; created 2026-10-10). README.md covers features and
settings; this file covers what a future agent needs on top of that.

**Public repo:** keep home-network details (IPs, hostnames, share names) and
screenshots of the author's machine out of it.

Git remotes: `origin` = the fork, `upstream` = meviusisback.

## State (2026-10-10)

- Based on upstream `main` at `ff91bb8` (1.2.0). Upstream 1.2.0 added a
  top-processes section with Italian UI strings — translated here.
- Added: Storage section (panel only); layout controls in the gear drawer
  (order + show/hide for bar items, panel dials, panel sections); `/boot`,
  `/boot/efi`, `/efi` hidden from Storage by default (`diskHideMounts`).
- On the author's laptop it is installed as a **symlink**
  `~/.config/omarchy/plugins/zoltanf.hw-monitor` → this checkout, in the bar
  slot `meviusisback.hw-monitor` used to have (that one is disabled).
- Verified live: Storage rows (btrfs subvolumes collapsed, NFS share via
  systemd automount, `/boot` hidden), the drawer's Items / Dials / Sections
  controls render, the section stack lays out. Clicking the reorder buttons
  was not exercised by the agent (no pointer tool); `Model.moveKey`,
  `setHidden`, `normalizeOrder`, `parseDisks` were unit-tested in node.

## Design

- `disk-probe` (bash) runs `findmnt --real` twice — local filesystems, then
  network types under `timeout -s KILL 3` so a dead NFS server cannot hold back
  the local rows — plus `lsblk` for the parent-disk model/removable flag.
  `--real` skips autofs placeholders, so opening the panel never triggers an
  idle automount.
- `Model.parseDisks` filters (`/dev/*` minus loop/zram for local), groups by
  filesystem UUID (btrfs subvolumes → one row, named by the shortest mount
  point), sorts internal → removable → network. Percent = used/(used+avail),
  as `df`.
- `Service.refreshDisks` follows upstream's `proc_top.py` pattern: only while
  the panel is open, throttled to 5 s, watchdog, last good value kept on
  failure. Run through `/usr/bin/bash` so a copy without the exec bit works.
  The panel calls the workers only for sections that are shown
  (`refreshWorkers`), so hiding Top processes also stops `proc_top.py`.
- **Section order:** sections are children of `sectionStack` and take
  `y: sectionStack.offsetOf(key)`; no re-parenting or Loaders, so ids such as
  `sparklineBox` keep working. Hidden sections take no space.
  `sectionWanted()` is the user's choice, `sectionShown()` adds what the
  machine can show (no GPU → no Graphics; no dials left → no Dials row).
  The older `showTopProcs` / `showDisks` switches still hide their sections;
  showing one from the drawer flips them back on.
- Stored lists are normalized by `Model.normalizeOrder`: unknown keys dropped,
  missing known keys appended — so a section added later appears instead of
  vanishing. Bar-item visibility stays in the original `showGpu` … `showRam`
  keys; `itemsOrder` is rewritten as a full array when moved.
- `Widget.persistSettings(changes)` writes several keys in one go (a toggle
  that touches two keys must not race its own first half).

## Gotchas

- **Reloading after edits:** saving a file did not trigger the shell's
  local-plugin reload through the symlink, and `omarchy-shell shell
  rescanPlugins` reloaded it badly (panel kept the old QML). `omarchy restart
  shell` applied changes cleanly.
- `omarchy bar set <id> key false` stores the string `"false"`; add `--json`
  for booleans.
- `omarchy-shell zoltanf.hw-monitor open` opens the panel on the laptop
  screen even with an external monitor focused. Do not send keys with `wtype`
  to reach the panel: they go to whatever window has focus. To screenshot the
  gear drawer, temporarily default `settingsOpen` to true (and stop
  `onOpenChanged` resetting it), `omarchy restart shell`, capture, revert.
- `grim -g` with logical geometry captures at physical resolution (scale
  1.25), so crop coordinates are ×1.25.
- Dial delegates: do not name a property `data` — it clashes with `Item.data`.

## Open

- Offer Storage and the layout controls upstream as PRs (upstream accepts
  them, see #2/#3)?
- Unmounted but connected drives are not listed (no free space without a
  mount). Could be shown dimmed with size only.
- Drag-and-drop ordering instead of arrow buttons, if the arrows feel slow.
