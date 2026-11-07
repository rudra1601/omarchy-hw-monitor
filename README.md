# Hardware Monitor + Storage

> **Fork:** `zoltanf.hw-monitor`, based on
> [meviusisback/omarchy-hw-monitor](https://github.com/meviusisback/omarchy-hw-monitor)
> 1.3.2. It adds:
>
> - a **Storage** section in the system panel: free space per mounted disk,
>   removable drive and network share (`/boot` and other EFI mounts hidden);
> - **RAM compression** (zram) details in the memory section;
> - **layout controls** in the panel's gear settings: reorder and show/hide
>   the bar items, the panel dials and the panel sections.

**GPU, CPU, temperature, and RAM in the bar as sleek icon + figure readouts, with a first-class visual system panel.**

![The system panel, anchored under the bar readout](preview.png)

*Based on [Edgar Silva's omarchy-hw-monitor](https://github.com/edgarsilva/omarchy-hw-monitor) (MIT) — continued and extended.*

## Why it exists

Checking thermals or "what is eating my RAM" should not mean opening a
terminal. The bar keeps the four numbers that matter — GPU, CPU, temperature,
memory — readable at a glance, and one click opens a full visual breakdown
without leaving the workspace. Everything stays in one screen: the glance in
the bar, the diagnosis in the panel.

## What it does

- **Four bar readouts, cycled with a right click** — sleek icon groups
  (Noctalia-style), gauges alone, gauges with temperatures, or the numbers
  spelled out as words.
- **Visual system panel on left click** — telemetry dials, 60 s CPU sparkline,
  processor details, memory breakdown, top processes, and graphics metrics,
  with full keyboard navigation.
- **Top processes by RAM or CPU** — with a Group toggle that collapses rows
  per application, and per-tab `[domain]` hints for Chromium-family browsers
  when grouping is off (a hint, not evidence — see [How it works](#how-it-works)).
- **Warn/critical coloring** — numbers, glyphs, and gauges warm toward the
  theme's urgent colour at configurable load and temperature thresholds.
- **Per-widget settings** — readout mode, formats, icons, thresholds, and
  which screens to draw on, all without touching code.

### The four bar readouts

**`icons`** *(default)* — GPU load, CPU load, CPU temperature with thermometer
icon, and RAM (e.g. `0% 34% 46°C 11/23G`), ~150px.

**`compact`** — a glyph and a gauge per component, ~80px. The gauge fills from
the bottom and warms toward the theme's urgent colour as load climbs, so the
machine's state is readable without reading a digit.

![compact](preview-compact.png)

**`full`** — the same, plus CPU and GPU temperature, ~106px. Memory has no
temperature sensor, so its gauge is the whole readout.

![full](preview-full.png)

**`labels`** — the Waybar hardware group, tightened: no glyph, no gauge, each
label welded to its figure, ~230px.

![labels](preview-labels.png)

## Install

```sh
omarchy plugin add https://github.com/zoltanf/omarchy-hw-monitor.git --enable
```

Then place it where you want it and restart the shell:

```sh
omarchy bar move zoltanf.hw-monitor --section right --after omarchy.tray
omarchy restart shell
```

Nothing to configure — it finds this machine's sensors on its own.

## Usage

- **Left click** — opens the built-in visual system telemetry panel anchored to
  the widget (or runs `clickCommand` if configured).
- **Right click** — cycles `icons` → `compact` → `full` → `labels`, and
  remembers it.
- **Middle click** — resamples immediately.
- **Hover** — says what the clicks do. The full breakdown is a `status` call
  away (see below).

### The system panel

Clicking the widget opens an Omarchy keyboard-driven popup panel anchored to
the bar:

- **Header** — the CPU model, with the host name, OS version and uptime
  under it.
- **Telemetry dials** — 270° circular gauges with live figures for CPU load &
  temp, RAM usage, and GPU load & temp with dynamic temperature coloring.
- **60s CPU load sparkline** — live history trend buffer sampled while open
  (zero background cost when closed).
- **Processor details** — full CPU model name (without cutoff), load, clock
  frequency, dynamic temperature color, and 1m/5m/15m load average meters.
- **Memory & Swap** — used/total GiB visual meter, available, cache, and swap usage. With zram swap: a **RAM Compression** block (device, algorithm, fill, data stored, compressed size, RAM it really costs, effective ratio); with zswap, its stored size and ratio.
- **Storage** — one row per mounted filesystem: internal disks, removable drives and network shares (NFS, SMB, sshfs, rclone), each with a used-space bar, free of total, the disk model or share source, and the filesystem type. A filesystem mounted in several places (btrfs subvolumes) is one row, named after its shortest mount point. Idle automounts are not triggered, and a network share that does not answer within 3 s is left out rather than holding up the rest. Sampled only while the panel is open.
- **Top processes** — the top processes sorted by RAM or CPU (switch in the
  header), with share and CPU% per process, blue ramp bars toward the theme
  accent. The Group toggle collapses them per application (systemd scope, name
  fallback) with counts and sums. With grouping off, Chromium-family browsers
  are disambiguated by role (`[main]`, `[gpu]`, `[ext]`, `[zygote]`…) or by the
  tab's domain (`brave [mail.google.com]`). That domain has two sources: for an
  app window it is the URL on the command line (a PWA launched with only an app
  id shows `[app]`); otherwise it is the most frequent host found in the
  renderer's own memory, when the kernel lets the shell attach to that process
  — with no minimum count, since one sighting already makes a host a candidate,
  and every sighting counts once, so whichever appears most often wins among
  the hosts that are not on the built-in CDN and asset ignore list. Treat it as
  a hint, not as evidence: the page decides what its renderer holds, so a site
  can make its row read as a different domain. The row reads `[tab]` when the
  attach is refused, when nothing was found, or when what was found is not a
  plain domain name (a single-label intranet name, an IPv6 literal, a
  percent-encoded host). An app window whose URL is not a plain domain shows its
  role tag instead. Firefox tabs stay plain. Sampled only while the panel is
  open (zero cost while closed).
- **Graphics metrics** — full GPU card name, load, dynamic temperature color,
  VRAM meter, power draw (W), fan RPM, and clock speeds.
- **Folding** — click a section's header to fold it down to the header and
  back. The fold is remembered, and a folded section stops sampling.
- **Layout (gear settings)** — *Items* orders the bar readouts, *Dials* the round gauges at the top of the panel, *Sections* the panel's cards. `‹ ›` / `↑ ↓` move an entry; clicking its name shows or hides it. Saved to the widget's `shell.json` entry like every other setting.
- **Keyboard navigation** — `Escape` to close, `Tab`/`Shift+Tab` to switch
  panels, `r` to resample, `c`/`f` to toggle °C/°F.

### IPC

Call methods through `omarchy-shell`:

```sh
# Open the system telemetry popup
omarchy-shell zoltanf.hw-monitor open

# Close the system panel
omarchy-shell zoltanf.hw-monitor close

# Toggle the system panel popup
omarchy-shell zoltanf.hw-monitor toggle

# Toggle Celsius / Fahrenheit
omarchy-shell zoltanf.hw-monitor toggleFahrenheit

# Cycle the display mode
omarchy-shell zoltanf.hw-monitor cycleMode

# Force an immediate resample
omarchy-shell zoltanf.hw-monitor refresh

# Dump the full multi-line telemetry breakdown
omarchy-shell zoltanf.hw-monitor status
```

## Requirements

- A Nerd Font for the glyphs, which Omarchy already ships
- `pciutils` (`lspci`) — optional, only to name the GPU card in the panel
- `nvidia-smi` — only for NVIDIA cards, installed with the driver
- `python3` (`/usr/bin/python3`) — only for the top-processes panel section;
  the section shows a fallback message when absent
- `findmnt` and `lsblk` (util-linux, part of every Arch install) — for the
  Storage section
- a writable runtime directory (`/run/user/<uid>`) — only for the
  top-processes cache; without one the cache is skipped
- a kernel that lets the shell attach to the browser's renderer — only for the
  `[domain]` hints; otherwise rows read `[tab]` instead

No pip packages, no daemon, no elevated privileges. Data sources: `/proc` and
`/sys` via `FileView`, the optional helpers above, `proc_top.py` reading
`/proc/<pid>/mem` for the browser hints — and `clickCommand`, which runs an
arbitrary user-configured shell command on left click when set (empty by
default, which opens the built-in panel instead).

## Settings

Settings are read from this widget's entry in `~/.config/omarchy/shell.json`:

```json
{
  "id": "zoltanf.hw-monitor",
  "mode": "icons",
  "refreshIntervalSec": 2,
  "batteryRefreshIntervalSec": 3,
  "showRam": true,
  "showCpu": true,
  "showGpu": true,
  "ramFormat": "used/total",
  "tempFormat": "degree",
  "fahrenheit": false,
  "warnPercent": 70,
  "criticalPercent": 90,
  "warnTempC": 75,
  "criticalTempC": 90
}
```

Or set dynamically from the command line:

```sh
omarchy bar set zoltanf.hw-monitor mode full
omarchy bar set zoltanf.hw-monitor fahrenheit true --json
```

| Key | Type | Default | Description |
|---|---|---|---|
| `mode` | string | `"icons"` | `"icons"`, `"compact"`, `"full"`, or `"labels"`. Right-clicking cycles them. |
| `itemsOrder` | array/string | `"gpu,cpu,cpu-temp,ram"` | Sequence of telemetry items in the top bar (`"gpu,cpu,cpu-temp,ram"` or `"gpu,cpu,cpu-temp,gpu-temp,ram"`). |
| `showGpu` | bool | `true` | Show GPU load (hidden automatically if no card was found). |
| `showCpu` | bool | `true` | Show CPU load. |
| `showCpuTemp` | bool | `true` | Show CPU temperature with thermometer icon. |
| `showGpuTemp` | bool | `false` | Show GPU temperature in the bar. |
| `showRam` | bool | `true` | Show memory / RAM usage. |
| `showTopProcs` | bool | `true` | Show the top-processes section in the system panel (sampled only while open). |
| `topProcCount` | int | `6` | How many rows to list (3–12, sorted by the active metric). |
| `topProcSort` | enum | `ram` | Sort top processes by `ram` or `cpu` (switchable in the panel header). |
| `topProcGroup` | bool | `true` | Collapse processes by application (systemd scope, name fallback) with counts and summed figures. |
| `showDisks` | bool | `true` | Show the Storage section in the system panel (sampled only while open). |
| `diskHideMounts` | array/string | `["/boot", "/boot/efi", "/efi"]` | Mount points left out of the Storage section. |
| `panelSections` | array/string | `dials,history,processor,memory,storage,procs,gpu` | Order of the panel sections. Missing ones are appended, so new sections never vanish. |
| `panelSectionsHidden` | array/string | `[]` | Panel sections to hide. |
| `panelSectionsCollapsed` | array/string | `[]` | Panel sections folded to their header. Clicking a section's header edits this; folded sections skip their sampling. |
| `pauseWhenIdleSec` | int | `120` | Stop sampling after this many seconds without keyboard or mouse input (screensaver, lock, screen off), unless the panel is open; the first input resumes it. A playing video counts as activity. `0` never pauses. |
| `panelDials` | array/string | `cpu,ram,gpu` | Order of the round dials at the top of the panel. |
| `panelDialsHidden` | array/string | `[]` | Dials to hide. |
| `ramFormat` | string | `"used/total"` | `"used/total"` (`12/23G`), `"used"` (`12.3G`), `"percent"` (`52%`), `"free"` (`11.1G`), or `"available"` (`11.1G`). |
| `tempFormat` | string | `"degree-unit"` | `"degree-unit"` (`45°C`), `"degree"` (`45°`), `"unit"` (`45C`), `"unit-lower"` (`45c`), or `"bare"` (`45`). |
| `fahrenheit` | bool | `false` | Temperatures in °F instead of °C. |
| `percentPad` | string | `"none"` | `"none"`, `"zero"`, `"lead"`, or `"trail"`. Figure cells always reserve their slot width, so neighbours stay put in every mode. |
| `showGauges` | bool | mode-dependent | Show vertical capsule gauges. Manifest default `true`; entries without the key fall back to on in `compact`/`full`, off in `icons`/`labels`. |
| `showValues` | bool | `false` | Put percentages back on the row beside each gauge in `compact`/`full` modes. (`icons` and `labels` always show them). |
| `showClocks` | bool | `false` | Show CPU and GPU clock speeds in GHz. |
| `gpuIcon` | string | `"󰾲"` | Glyph marking the GPU figure. |
| `cpuIcon` | string | `""` | Glyph marking the CPU figure. |
| `tempIcon` | string | `""` | Glyph marking the CPU temperature figure. |
| `gpuTempIcon` | string | `"󰔏"` | Glyph marking the GPU temperature figure. |
| `ramIcon` | string | `""` | Glyph marking the RAM figure. |
| `clockIcon` | string | `"󰓅"` | Glyph marking the clock figure. Empty draws the number alone. |
| `iconSize` | int | `0` | Overall scale in pixels. `0` follows the bar's icon font. |
| `padOpacity` | number | `0.3` | Opacity of the padded percentage background (0-1). |
| `gpuIconRotation` | int | `0` | Rotate the GPU glyph (0, 90, 180, 270). |
| `cpuIconRotation` | int | `0` | Rotate the CPU glyph (0, 90, 180, 270). |
| `tempIconRotation` | int | `0` | Rotate the temperature glyph (0, 90, 180, 270). |
| `ramIconRotation` | int | `0` | Rotate the memory glyph (0, 90, 180, 270). |
| `refreshIntervalSec` | int | `2` | Seconds between samples. `1` is as fast as `FileView` makes sense; `5` is plenty for a background bar. |
| `batteryRefreshIntervalSec` | int | `3` | Seconds between samples while the laptop runs on battery; the larger of this and `refreshIntervalSec` applies. The open panel still ticks every second. |
| `gpu` | string | `"auto"` | `"auto"` picks the card reporting load; otherwise an index (`0`, `1`) or name substring. |
| `warnPercent` | int | `70` | Load threshold where numbers and glyphs warm toward the urgent colour. |
| `criticalPercent` | int | `90` | Load threshold where the gauge glows and color reaches full urgent. |
| `warnTempC` | int | `75` | Temperature threshold (°C) where figures warm toward urgent. |
| `criticalTempC` | int | `90` | Temperature threshold (°C) where temperature turns hot urgent red. |
| `diskWarnPercent` | int | `80` | Disk use (%) where a Storage row starts warming toward urgent. |
| `diskCriticalPercent` | int | `95` | Disk use (%) where a Storage row reaches full urgent. |
| `clickCommand` | string | `""` | Shell command run on left click via `bash -lc` as you, unsandboxed. Empty opens the built-in system panel popup. Only set it from a source you trust: whatever can write this widget's settings can run code on your next click. |
| `monitors` | array/string | `[]` | Connector names to draw on (e.g. `["DP-1"]`). Empty draws on all screens. |

## How it works

Bar sampling reads `/proc` and `/sys` inside the shell process via `FileView` —
no polling script on a timer for that. Three documented helpers do fork:
`nvidia-smi` on the sample interval (NVIDIA cards only — they expose no sysfs
telemetry), `proc_top.py` up to every 3 s and `disk-probe` up to every 5 s,
the last two only while the system panel is open.

| | Source | Shown |
|---|---|---|
| Memory | `/proc/meminfo` | used against total, measured with `MemAvailable` so reclaimable page cache is not counted as used |
| RAM compression | `/sys/block/zramN/mm_stat`, `/proc/meminfo` (`Zswap`, `Zswapped`) | zram devices used as swap are found by `hw-probe`; ratio is data stored against RAM used, allocator overhead included |
| CPU load | `/proc/stat` | jiffie deltas between samples, `iowait` counted as idle — the same arithmetic `top` and `btop` use |
| CPU clock | `/proc/cpuinfo` | mean across every thread |
| CPU temperature | `hwmon` | die/package sensor, picked by scoring (`k10temp` `Tdie`/`Tctl`, `coretemp` `Package id 0`, `zenpower`, ThinkPad, ARM SoC, then `acpitz`) |
| GPU | the card's own `sysfs` | load, edge temperature, VRAM, board power, fan, core clock |
| Apple silicon GPU | `<card>/device/agx_stats` (asahi driver, Omarchy's `linux-aurora` kernel) | load (firmware `util1`, else `busy_ns` deltas), temperature, power. Only used when the file holds the firmware figures; a field missing from one read keeps its last value |
| Load average | `/proc/loadavg` | 1/5/15 minute |
| Storage | `findmnt` + `lsblk`, via [`disk-probe`](disk-probe) | size, used and available per mounted filesystem (percent as `df` computes it), disk model, removable or network |
| Browser tab hints | `/proc/<pid>/mem` of Chromium-family processes | read-only, and only for the processes the kernel lets the shell attach to. With the Group toggle off, the most frequent host in the renderer's memory becomes the `[domain]` tag, and rows read `[tab]` when the attach is refused or nothing was found |

An NVIDIA card is the exception: it reports none of this through sysfs, so it
is polled through `nvidia-smi` on the same interval.

Sensor paths are found once, at load, by [`hw-probe`](hw-probe) — a small shell
script, because working out *which* files a machine exposes means globbing
`hwmon` and matching labels, and every vendor names its sensors differently.
After that the resolved sysfs/`/proc` paths need no fork on a timer the way a
Waybar custom module does: the widget reads them directly with `FileView`, which
is what makes a two-second interval reasonable for something that runs for the
life of your session.

With more than one monitor, each bar draws its own copy of the widget, but
only one copy samples and the others show its readings. The system panel is
built when it opens and dropped once it closes, and while it is open the
widget samples once a second, which also feeds the CPU history.
Hovering the widget starts the process list and storage scan early, so they
are usually ready when the panel opens. After two minutes without input
(screensaver, lock, screen off) sampling pauses until you are back.

`blockAllReads` is set on those views deliberately. Without it `reload()` is
asynchronous and `text()` returns the *previous* tick's contents, so every
readout lags a full interval. These are kernel-generated files of a few KB, so
a blocking read never stalls the UI.

Run the probe yourself to see what it found:

```sh
~/.config/omarchy/plugins/zoltanf.hw-monitor/hw-probe | jq
```

A sensor missing from that output is one this machine does not expose, and the
widget renders a dash rather than a zero that looks like real data.

`proc_top.py` keeps one small state file in the run directory:
`/run/user/<uid>/hw_monitor_browser_cache.json` (0600; **on a default setup
that is tmpfs**, cleared on logout — the widget uses whatever
`$XDG_RUNTIME_DIR` points at and does not check the filesystem type, so a
runtime dir you have moved to disk keeps the file). It holds, for each browser
row, the label — **which for a tab is a domain you have open** — plus the
previous CPU snapshot, so a poll costs 20–40 ms instead of re-scanning `/proc`
twice. An entry is reused for 45 s, or 10 s for a sample that could not be
resolved in full; note that is the entry's validity, not the file's lifetime:
the file is only rewritten while the panel is open, so the last set of domains
stays there until logout or until you delete it. Without a writable runtime
directory the cache is skipped rather than written elsewhere. Deleting the file
at any time is safe — the next poll rebuilds it.

## Removal

```sh
omarchy plugin remove zoltanf.hw-monitor
```

That drops it from the bar and deletes the plugin. Per-widget settings live in
the shell's own config (`~/.config/omarchy/shell.json`) and are left for the
shell to prune — remove the widget's entry there if you want a clean slate. The
process-list cache at `/run/user/<uid>/hw_monitor_browser_cache.json` is on
tmpfs on a default setup and disappears at logout; delete it by hand if you want
it gone sooner, together with any `.hw_monitor_cache.*.tmp` left beside it by a
killed poll.

## License

MIT — see [LICENSE](LICENSE). Original work by Edgar Silva; continued and
extended by meviusisback; Storage, zram and layout additions by zoltanf.

## Credits

Based on [Edgar Silva's omarchy-hw-monitor](https://github.com/edgarsilva/omarchy-hw-monitor)
(MIT). This fork continues the plugin — the original repository has been
inactive since August 2026 — with the Noctalia-style readout, the visual
system panel, and per-widget settings. The original MIT license is preserved;
copyright lines in [LICENSE](LICENSE) reflect both authors.
