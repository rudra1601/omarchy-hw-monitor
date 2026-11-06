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
- 2026-11-06: merged upstream 1.3.2 (`a74aaec`): security hardening of the
  helpers, browser-tab hints in `proc_top.py`, README restyle. Kept on purpose:
  the fork's two-digit temperature width and no RAM width reservation
  (`Widget.qml`), the fork's `SystemPanel.qml` (upstream only translated
  strings). `Model.parseProbe` now also validates the fork's `zram` entries
  (`dir` must be `/sys/block/zramN`). `disk-probe` has a watchdog but no byte
  guard, unlike upstream's helpers. Version `1.3.2+storage.3`.
- 2026-10-12: Memory section renamed "Memory & Swap", RAM Compression block
  (zram from `mm_stat`, devices found by `hw-probe` via `/proc/swaps`;
  zswap from `/proc/meminfo`). zswap path untested (off on the author's
  laptop).
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

- One sampler per bar entry across monitors (2026-11-06): `Widget.samplerWidget`
  is the first copy in `bar.moduleWidgets(moduleName)` that is `onThisScreen`;
  only its `Service` is active, the others bind `hw` to it. Verified with a
  temporary log line on two monitors (one Service sampling) and by moving the
  `monitors` setting between screens. Not exercised: the sampler copy being
  destroyed (unplugging the monitor whose copy samples); `samplerHw` is a
  QtObject property so it nulls and falls back to the own Service meanwhile.
- `SystemPanel` content is lazy (`content: PanelKeyCatcher {...}`) and unloaded
  after the fade-out (`contentRequested = false` in `onVisibleChanged`). Root
  code must not reference content ids; use `loadedContent` (see the sparkline
  size properties). Non-Item helpers at the panel root go in a property
  (`historyFollower`), not as children: the default property takes Items.
- Layout Behaviors in the panel (section `y`, card `implicitHeight`, bar fill
  `width`) are gated by `root.layoutAnimated`, which turns on 400 ms after
  open. Without the gate the lazily built body visibly slid and grew into place
  on every open. A new layout Behavior needs `enabled: root.layoutAnimated`.
  The process list keeps `topProcCount` invisible placeholder rows until the
  first list arrives (first open after a shell start, ~0.5 s).
- While the panel is open the Service ticks at 1 s and emits `sampled()`; the
  panel's history and helper refresh follow that signal (no timer of its own).
- Measuring: whole-shell CPU varies ±1-2% between 40 s windows on this laptop
  while it is in use, so A/B numbers need interleaved runs.
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
