.pragma library

// Pure parsing and formatting for the hardware readouts. Everything here takes
// raw file text or numbers and returns plain values, so the sampling in
// Service.qml and the drawing in Widget.qml never have to agree on anything
// beyond these shapes.

var KIB_PER_GIB = 1048576
var BYTES_PER_GIB = 1073741824

function toNumber(value, fallback) {
  var n = Number(String(value).trim())
  return isFinite(n) ? n : (fallback === undefined ? 0 : fallback)
}

// Coerce only scalars: String()/Number() on an object whose JSON carried an
// own "toString" key throws "Cannot convert object to primitive value", which
// would take a fail-soft parser down with it. Subprocess output is untrusted,
// so every field of every row goes through this, not toNumber directly.
function toNumberSafe(value, fallback) {
  var t = typeof value
  if (t !== "number" && t !== "string" && t !== "boolean") {
    return fallback === undefined ? 0 : fallback
  }
  return toNumber(value, fallback)
}

// Sensor paths from the probe become FileView reads, so accept only the two
// virtual filesystems the probe actually scans — and only clean absolute
// forms: no '.'/'..' traversal, no empty interior segments, so a tampered
// hw-probe cannot point the shell at arbitrary readable files.
var SENSOR_PATH = /^\/(sys|proc)\/[A-Za-z0-9._:\/-]+$/
function safePath(value) {
  if (typeof value !== "string" || !SENSOR_PATH.test(value)) return undefined
  var parts = value.split("/")
  for (var i = 1; i < parts.length; i++) {
    if (parts[i] === "" || parts[i] === "." || parts[i] === "..") return undefined
  }
  return value
}

// Control, format and blank-rendering characters have no place in a label.
// Covered: C0/C1 controls (ANSI escapes, NUL, DEL), soft hyphen, the bidi marks
// and overrides (U+061C, U+200E-200F, U+202A-202E), the line/paragraph
// separators U+2028-2029 (a one-line payload's cheapest way to fake a second
// row), zero-width space/joiners, the deprecated format block U+2060-206F,
// interlinear annotation, the astral tag characters U+E0000-E007F, and the
// code points that are invisible BY DESIGN — Hangul fillers U+115F/U+1160,
// Khmer inherent vowels U+17B4-17B5, Mongolian free variation selectors
// U+180B-180D, braille blank U+2800, Hangul filler U+3164, halfwidth Hangul
// filler U+FFA0, shorthand format controls U+1BCA0-1BCA3, musical format
// controls U+1D173-1D17A. A process may name itself with any of them, and an
// override visually reverses the rest of the row.
//
// This is a blacklist at the DISPLAY layer and a blacklist can never be
// exhaustive — the authoritative allowlist lives in proc_top.py sanitize_name,
// which is where process names actually originate. This layer exists so that a
// tampered or replaced helper still cannot render something invisible; it is
// deliberately permissive for real hardware strings, which must survive
// (brackets, parens, accents, CJK, Nerd Font private-use glyphs).
//
// Replaced — not dropped — with the visible '·' proc_top.py uses, so a tampered
// helper shows its hand. Two deliberate tidiness trades: ZWJ/ZWNJ (U+200C-200D)
// are stripped, which breaks multi-codepoint emoji, and U+FE00-FE0F variation
// selectors are kept, because they choose a glyph's presentation rather than
// hiding content.
var DISPLAY_BAD = /[\u0000-\u001F\u007F-\u009F\u00AD\u061C\u115F\u1160\u17B4\u17B5\u180B-\u180E\u200B-\u200F\u2028\u2029\u202A-\u202E\u2060-\u206F\u2800\u3164\uFEFF\uFFA0\uFFF9-\uFFFC\u{1BCA0}-\u{1BCA3}\u{1D173}-\u{1D17A}\u{E0000}-\u{E007F}]/gu

function cleanString(value, maxLen) {
  if (typeof value !== "string") return undefined
  // Trim BEFORE replacing: U+FEFF is whitespace to trim(), so a leading BOM is
  // discarded as it always was instead of turning into a visible placeholder.
  // Interior U+FEFF still has to be neutralised, which is why it is in the
  // class even though this trim already handles it at the edges.
  var s = value.trim().replace(DISPLAY_BAD, "\u00b7")
  s = s.trim()
  if (s === "") return undefined
  return s.length > maxLen ? s.substring(0, maxLen) : s
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value))
}

// ------------------------------------------------------------------- probe

// Probe output is one JSON line from a helper we spawn, but treat it as
// untrusted anyway: keep only known keys with expected types, and accept a
// sensor path only when it lives under /sys or /proc.
function parseProbe(raw) {
  var empty = { ok: false, cpu: { model: "CPU", cores: 0, threads: 0 }, gpus: [], zram: [] }
  var text = String(raw || "").trim()
  if (text === "") return empty
  try {
    var parsed = JSON.parse(text)
    if (!parsed || typeof parsed !== "object") return empty
    var rawCpu = parsed.cpu && typeof parsed.cpu === "object" ? parsed.cpu : {}
    var cpu = {
      model: cleanString(rawCpu.model, 128) || "CPU",
      cores: Math.max(0, Math.floor(toNumberSafe(rawCpu.cores, 0))),
      threads: Math.max(0, Math.floor(toNumberSafe(rawCpu.threads, 0)))
    }
    var tempPath = safePath(rawCpu.tempPath)
    if (tempPath !== undefined) {
      cpu.tempPath = tempPath
      cpu.tempLabel = cleanString(rawCpu.tempLabel, 64)
    }
    var gpus = []
    var rawGpus = parsed.gpus instanceof Array ? parsed.gpus : []
    var PATH_KEYS = ["busyPath", "vramUsedPath", "vramTotalPath", "tempPath",
                     "powerPath", "fanPath", "clockPath", "agxStatsPath"]
    for (var i = 0; i < rawGpus.length; i++) {
      var g = rawGpus[i]
      if (!g || typeof g !== "object") continue
      var gpu = {}
      var kind = cleanString(g.kind, 64)
      if (kind !== undefined) gpu.kind = kind
      var name = cleanString(g.name, 256)
      if (name !== undefined) gpu.name = name
      var card = cleanString(g.card, 64)
      if (card !== undefined) gpu.card = card
      gpu.index = Math.max(0, Math.floor(toNumberSafe(g.index, 0)))
      // Absolute path of the nvidia-smi the probe resolved: must be a clean
      // absolute path (no relative names, no traversal); the widget falls
      // back to a bare 'nvidia-smi' when it is missing or malformed.
      if (typeof g.nvidiaPath === "string" && /^\/[A-Za-z0-9._\/+-]+$/.test(g.nvidiaPath)
          && g.nvidiaPath.indexOf("..") === -1) {
        gpu.nvidiaPath = g.nvidiaPath
      }
      for (var k = 0; k < PATH_KEYS.length; k++) {
        var path = safePath(g[PATH_KEYS[k]])
        if (path !== undefined) gpu[PATH_KEYS[k]] = path
      }
      gpus.push(gpu)
    }
    // zram swap devices (fork addition): the widget reads <dir>/mm_stat, so
    // accept only a /sys/block/zramN directory.
    var zram = []
    var rawZram = parsed.zram instanceof Array ? parsed.zram : []
    for (var z = 0; z < rawZram.length; z++) {
      var d = rawZram[z]
      if (!d || typeof d !== "object") continue
      if (typeof d.dir !== "string" || !/^\/sys\/block\/zram[0-9]+$/.test(d.dir)) continue
      zram.push({
        name: cleanString(d.name, 32) || d.dir.substring(11),
        dir: d.dir,
        algorithm: cleanString(d.algorithm, 32) || "",
        sizeBytes: Math.max(0, toNumberSafe(d.sizeBytes, 0))
      })
    }
    return { ok: true, cpu: cpu, gpus: gpus, zram: zram }
  } catch (e) {
    return empty
  }
}

// Pick which discovered card the widget reports on. `auto` means the first,
// which hw-probe has already sorted so a card with a load counter wins.
function pickGpu(gpus, preference) {
  if (!(gpus instanceof Array) || gpus.length === 0) return null
  var want = String(preference === undefined || preference === null ? "auto" : preference).trim().toLowerCase()
  if (want === "" || want === "auto") return gpus[0]

  var index = parseInt(want, 10)
  if (isFinite(index) && index >= 0 && index < gpus.length) return gpus[index]

  // Otherwise treat it as a substring match on card, kind, or name — so
  // "card1", "amdgpu", and "9070" all select the same GPU.
  for (var i = 0; i < gpus.length; i++) {
    var gpu = gpus[i]
    var haystack = [gpu.card, gpu.kind, gpu.name].join(" ").toLowerCase()
    if (haystack.indexOf(want) !== -1) return gpu
  }
  return gpus[0]
}

// --------------------------------------------------------------------- cpu

// The aggregate line of /proc/stat holds cumulative jiffies since boot:
// cpu user nice system idle iowait irq softirq steal guest guest_nice
function parseCpuJiffies(raw) {
  var text = String(raw || "")
  var end = text.indexOf("\n")
  var line = end === -1 ? text : text.substring(0, end)
  var parts = line.replace(/\s+/g, " ").split(" ")
  if (parts.length < 5 || parts[0] !== "cpu") return null

  var total = 0
  // Fields past `steal` are already counted inside user/nice, so stop at 8.
  for (var i = 1; i < parts.length && i <= 8; i++) total += toNumber(parts[i])
  // iowait is time with nothing to run, so it belongs with idle rather than
  // being charged to a process — this matches what top and btop report.
  var idle = toNumber(parts[4]) + toNumber(parts[5])
  return { total: total, idle: idle }
}

// Usage is a ratio of jiffie deltas, not of wall-clock time, so an uneven
// sampling interval cannot skew it.
function cpuUsage(previous, current) {
  if (!previous || !current) return -1
  var totalDelta = current.total - previous.total
  var idleDelta = current.idle - previous.idle
  if (totalDelta <= 0) return -1
  return clamp(100 * (1 - idleDelta / totalDelta), 0, 100)
}

// Average current clock across every thread. /proc/cpuinfo is the one place
// that reports it without globbing 32 cpufreq directories.
function averageMhz(raw) {
  var matches = String(raw || "").match(/^cpu MHz\s*:\s*([\d.]+)/gm)
  if (!matches || matches.length === 0) return 0
  var sum = 0
  for (var i = 0; i < matches.length; i++) sum += toNumber(matches[i].split(":")[1])
  return sum / matches.length
}

function parseLoadAverage(raw) {
  var parts = String(raw || "").trim().split(/\s+/)
  if (parts.length < 3) return null
  return { one: toNumber(parts[0]), five: toNumber(parts[1]), fifteen: toNumber(parts[2]) }
}

// ------------------------------------------------------------------ system

// /proc/uptime: "<seconds since boot> <idle seconds summed over CPUs>".
function parseUptime(raw) {
  var first = String(raw || "").trim().split(/\s+/)[0]
  var sec = toNumberSafe(first, -1)
  return sec >= 0 ? sec : -1
}

// "up 2d 6h", "up 5h 12m", "up 12m"; empty when unknown.
function formatUptime(sec) {
  if (!isFinite(sec) || sec < 0) return ""
  var m = Math.floor(sec / 60), h = Math.floor(m / 60), d = Math.floor(h / 24)
  if (d > 0) return "up " + d + "d " + (h % 24) + "h"
  if (h > 0) return "up " + h + "h " + (m % 60) + "m"
  return "up " + m + "m"
}

// /etc/os-release: PRETTY_NAME (or NAME), plus BUILD_ID or VERSION_ID when the
// name does not already carry it. Returns "" when nothing usable is found.
function parseOsRelease(raw) {
  var text = String(raw || "")
  function field(key) {
    var match = text.match(new RegExp("^" + key + "=(.*)$", "m"))
    if (!match) return ""
    return cleanString(match[1].trim().replace(/^(["'])(.*)\1$/, "$2"), 64) || ""
  }
  var name = field("PRETTY_NAME") || field("NAME")
  var version = field("BUILD_ID") || field("VERSION_ID")
  if (name === "") return ""
  return version !== "" && name.indexOf(version) === -1 ? name + " " + version : name
}

// ------------------------------------------------------------------ memory

// MemAvailable is the kernel's own estimate of what a new allocation can get
// without swapping, which is what "used" should be measured against — total
// minus free counts reclaimable page cache as used and always reads ~90%.
function parseMemory(raw) {
  var text = String(raw || "")
  function field(key) {
    var match = text.match(new RegExp("^" + key + ":\\s+(\\d+)", "m"))
    return match ? toNumber(match[1]) : 0
  }

  var total = field("MemTotal")
  var available = field("MemAvailable")
  if (total <= 0) return null
  if (available <= 0) available = field("MemFree") + field("Buffers") + field("Cached")

  var swapTotal = field("SwapTotal")
  return {
    totalKib: total,
    availableKib: available,
    usedKib: Math.max(0, total - available),
    cachedKib: field("Cached") + field("SReclaimable"),
    swapTotalKib: swapTotal,
    swapUsedKib: Math.max(0, swapTotal - field("SwapFree")),
    // zswap: pages swapped out but kept compressed in RAM. Zswapped is what
    // they would take uncompressed, Zswap what they take now.
    zswapKib: field("Zswap"),
    zswappedKib: field("Zswapped"),
    percent: clamp(100 * (total - available) / total, 0, 100)
  }
}

// -------------------------------------------------------------------- zram
//
// /sys/block/zramN/mm_stat: orig_data_size compr_data_size mem_used_total
// mem_limit mem_used_max same_pages pages_compacted huge_pages …
// orig is what was stored, compr what the compressor made of it, and
// mem_used_total the RAM that actually costs, allocator overhead included.

function parseZramStat(raw) {
  var parts = String(raw || "").trim().split(/\s+/)
  if (parts.length < 3) return null
  var orig = toNumber(parts[0], -1)
  var compr = toNumber(parts[1], -1)
  var used = toNumber(parts[2], -1)
  if (orig < 0 || compr < 0 || used < 0) return null
  return { origBytes: orig, comprBytes: compr, memUsedBytes: used }
}

// Effective ratio: stored data against the RAM it really takes. Below 1 MiB
// stored the allocator's fixed overhead dominates and the figure means nothing.
function formatRatio(stored, cost) {
  if (!(stored >= 1048576) || !(cost > 0)) return "–"
  return (stored / cost).toFixed(1) + "×"
}

// ------------------------------------------------------------------ nvidia
//
// nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,memory.used,
// memory.total,power.draw --format=csv,noheader,nounits
// Unsupported fields come back as "[N/A]".

// ------------------------------------------------------------------ asahi
//
// Apple silicon GPUs on Asahi Linux: <card>/device/agx_stats holds
// "key value" lines. util1 is the firmware's own load figure (the one its clock
// governor uses); busy_ns is a running busy-time counter, kept for when util1
// is absent. Temperature is hundredths of a degree times temperature_scale.
// The file sometimes holds only memory figures, so every field is optional and
// a missing one comes back as -1.
function parseAgxStats(raw) {
  var out = { util: -1, busyNs: -1, tempC: -1, watts: -1 }
  var text = String(raw || "")
  if (text.length > 65536) return out
  var values = {}
  var lines = text.split("\n")
  for (var i = 0; i < lines.length; i++) {
    var m = /^([a-z0-9_]+) ([0-9]+)$/.exec(lines[i].trim())
    if (m) values[m[1]] = Number(m[2])
  }
  if (values.util1 !== undefined) out.util = Math.max(0, Math.min(100, values.util1))
  if (values.busy_ns !== undefined) out.busyNs = values.busy_ns
  if (values.temperature_raw !== undefined && values.temperature_scale > 0) {
    var c = values.temperature_raw / values.temperature_scale / 100
    if (c > 0 && c < 150) out.tempC = c
  }
  if (values.power_mw !== undefined) out.watts = values.power_mw / 1000
  return out
}

function parseNvidia(raw) {
  var line = String(raw || "").trim().split("\n")[0]
  if (!line) return null
  var parts = line.split(",")
  // Exactly the five fields this widget asks for in its own --query-gpu argv
  // (Service.qml sampleNvidia). The Process pins LC_ALL=C, so the numbers are
  // always '.'-separated and a decimal comma cannot add a sixth field; any
  // other count therefore means a shifted field, a stray delimiter or a driver
  // change, and the caller keeps the last good sample on null.
  if (parts.length !== 5) return null

  // Out of range means "not a reading", not "clamp to the nearest plausible
  // figure": saturating 1e9 % to 100 % and 999 °C to 150 °C prints credible
  // numbers the UI shows verbatim, while -1 already renders as a dash. Negative
  // values are equally impossible for any of these sensors.
  function value(index, max) {
    var text = String(parts[index] || "").trim()
    if (text === "" || text.indexOf("N/A") !== -1) return -1
    var n = toNumber(text, -1)
    return isFinite(n) && n >= 0 && n <= max ? n : -1
  }

  var vramUsed = value(2, 1048576)
  var vramTotal = value(3, 1048576)
  // Used larger than installed cannot be a real reading — it is the signature
  // of a shifted field. Drop the sample rather than draw a >100 % VRAM bar.
  if (vramUsed >= 0 && vramTotal >= 0 && vramUsed > vramTotal) return null

  return {
    busy: value(0, 100),
    tempC: value(1, 150),
    vramUsedBytes: vramUsed >= 0 ? vramUsed * 1048576 : -1,
    vramTotalBytes: vramTotal >= 0 ? vramTotal * 1048576 : -1,
    watts: value(4, 2000)
  }
}

// -------------------------------------------------------------- formatting

function gibFromKib(kib) {
  return kib / KIB_PER_GIB
}

function gibFromBytes(bytes) {
  return bytes / BYTES_PER_GIB
}

// One decimal below 10 GiB, none above: "9.4G" and "62G" both stay narrow,
// and the bar never reflows as memory crosses a rounding boundary.
function formatGib(gib) {
  if (!isFinite(gib) || gib < 0) return "–"
  if (gib === 0) return "0"
  if (gib < 10) return gib.toFixed(1)
  return String(Math.round(gib))
}

// One decimal always, for the label mode where the figure is the whole point
// and the column is wide enough to carry it.
function formatGibPrecise(gib) {
  if (!isFinite(gib) || gib < 0) return "–"
  return gib.toFixed(1)
}

function formatPercent(value) {
  if (!isFinite(value) || value < 0) return "–"
  return Math.round(value) + "%"
}

// A leading zero rather than a leading space: same constant width, but the
// figure still starts where the eye expects it to, hard against its label.
function formatPercentPadded(value) {
  if (!isFinite(value) || value < 0) return "–"
  var n = Math.round(value)
  return (n < 10 ? "0" + n : String(n)) + "%"
}

// Just the figure, for callers that want to choose their own unit marker.
function tempNumber(celsius, fahrenheit) {
  if (!isFinite(celsius) || celsius <= 0) return "–"
  return String(Math.round(fahrenheit ? celsius * 9 / 5 + 32 : celsius))
}

function formatTemp(celsius, fahrenheit) {
  if (!isFinite(celsius) || celsius <= 0) return "–"
  var deg = Math.round(fahrenheit ? celsius * 9 / 5 + 32 : celsius)
  return deg + "°" + (fahrenheit ? "F" : "C")
}

function formatGhz(mhz) {
  if (!isFinite(mhz) || mhz <= 0) return "–"
  return (mhz / 1000).toFixed(1) + " GHz"
}

// Just the number, for a bar row where an icon already says what it measures.
function formatGhzShort(mhz) {
  if (!isFinite(mhz) || mhz <= 0) return "–"
  return (mhz / 1000).toFixed(1)
}

function formatWatts(watts) {
  if (!isFinite(watts) || watts < 0) return "–"
  return Math.round(watts) + " W"
}

function formatRpm(rpm) {
  if (!isFinite(rpm) || rpm < 0) return "–"
  return rpm === 0 ? "idle" : Math.round(rpm) + " rpm"
}

// ------------------------------------------------------------ top processes

// Difesa-in-profondità: proc_top.py sanifica già tutto, qui si valida di
// nuovo perché lo stdout di un subprocess è input non fidato. Ritorna sempre
// {rows, groupedBy} (righe vuote su qualsiasi forma inattesa); tronca a maxN
// righe, nomi a 48 char, numeri clampati ai range. Ordine del collector
// (per metrica scelta) preservato.
var PROC_TOP_MAX = 12
var PROC_NAME_MAX = 48
var PROC_GROUPEDS = ["none", "scope", "comm"]

function parseProcTop(raw, maxN) {
  var out = { rows: [], groupedBy: "none" }
  var limit = maxN === undefined ? PROC_TOP_MAX : Math.max(1, Math.min(PROC_TOP_MAX, toNumber(maxN, PROC_TOP_MAX)))
  var text = String(raw || "").trim()
  if (text === "" || text.length > 16384) return out
  var parsed = null
  try {
    parsed = JSON.parse(text)
  } catch (e) {
    return out
  }
  if (!parsed || !(parsed.procs instanceof Array)) return out
  var rawGroupedBy = parsed.groupedBy
  var groupedBy = (typeof rawGroupedBy === "string" || typeof rawGroupedBy === "number")
    ? String(rawGroupedBy) : "none"
  out.groupedBy = PROC_GROUPEDS.indexOf(groupedBy) === -1 ? "none" : groupedBy
  for (var i = 0; i < parsed.procs.length && out.rows.length < limit; i++) {
    var p = parsed.procs[i]
    if (!p || typeof p !== "object") continue
    var pid = Math.floor(toNumberSafe(p.pid, -1))
    if (pid <= 0 || pid > 4194304) continue
    var rawName = typeof p.name === "string" || typeof p.name === "number"
      ? String(p.name) : ""
    var name = cleanString(rawName.replace(/[\r\n\t]/g, " "), PROC_NAME_MAX)
    if (name === undefined) name = "?"
    var count = Math.floor(toNumberSafe(p.count, 1))
    if (!isFinite(count) || count < 1) count = 1
    if (count > 4096) count = 4096
    var rssKib = Math.floor(toNumberSafe(p.rssKib, -1))
    if (rssKib < 0 || rssKib > 68719476736) continue
    out.rows.push({
      pid: pid,
      name: name,
      count: count,
      cpu: clamp(toNumberSafe(p.cpu, 0), 0, 100),
      rssKib: rssKib,
      memPct: clamp(toNumberSafe(p.memPct, 0), 0, 100)
    })
  }
  return out
}

// ------------------------------------------------------------------ storage
//
// disk-probe prints {"local", "network", "networkTimedOut", "blocks"}, the
// first two straight from `findmnt --json --bytes`, the last from
// `lsblk --json`. Returns {ok, disks, networkTimedOut}; each disk is one
// filesystem, however many places it is mounted.

var DISK_SKIP_SOURCE = /^\/dev\/(loop|zram|ram)\d/

// btrfs subvolumes show as "/dev/mapper/root[/@home]"; the device is the part
// before the bracket.
function diskDevice(source) {
  return String(source || "").replace(/\[.*\]$/, "")
}

// Short name for the panel row: the mount point, except desktop automounts
// (/run/media/<user>/<name>, /media/<name>), which read better as the name.
function diskTitle(target, label) {
  var t = String(target || "")
  var auto = t.match(/^\/run\/media\/[^\/]+\/(.+)$/) || t.match(/^\/media\/(?:[^\/]+\/)?(.+)$/)
  if (auto) return label ? String(label) : auto[1]
  return t
}

// Walk lsblk's parent chain (partition → crypt/LVM → disk) for the physical
// disk's model and whether it is removable.
function diskHardware(device, blocks) {
  var byPath = {}
  var byName = {}
  for (var i = 0; i < blocks.length; i++) {
    var b = blocks[i]
    if (!b || typeof b !== "object") continue
    if (b.path) byPath[String(b.path)] = b
    if (b.name) byName[String(b.name)] = b
  }

  var info = { model: "", removable: false, transport: "" }
  var node = byPath[device] || null
  for (var hops = 0; node && hops < 8; hops++) {
    if (node.model && !info.model) info.model = String(node.model).trim()
    if (node.tran && !info.transport) info.transport = String(node.tran)
    if (node.rm === true || node.tran === "usb" || /^mmcblk/.test(String(node.name || ""))) info.removable = true
    node = node.pkname ? byName[String(node.pkname)] || null : null
  }
  return info
}

function parseDisks(raw) {
  var out = { ok: false, disks: [], networkTimedOut: false }
  var text = String(raw || "").trim()
  if (text === "") return out
  var parsed = null
  try {
    parsed = JSON.parse(text)
  } catch (e) {
    return out
  }
  if (!parsed || typeof parsed !== "object") return out

  var blocks = parsed.blocks && parsed.blocks.blockdevices instanceof Array ? parsed.blocks.blockdevices : []
  var groups = {}
  var order = []

  function collect(list, network) {
    if (!(list instanceof Array)) return
    for (var i = 0; i < list.length; i++) {
      var fs = list[i]
      if (!fs || typeof fs !== "object") continue
      var source = String(fs.source || "")
      var size = toNumber(fs.size, -1)
      if (size <= 0) continue
      if (!network && (source.indexOf("/dev/") !== 0 || DISK_SKIP_SOURCE.test(source))) continue

      var device = network ? source : diskDevice(source)
      var key = !network && fs.uuid ? "uuid:" + fs.uuid : "dev:" + device
      var target = String(fs.target || "")
      var group = groups[key]
      if (!group) {
        group = groups[key] = {
          key: key,
          device: device,
          fstype: String(fs.fstype || ""),
          label: fs.label ? String(fs.label) : "",
          kind: network ? "network" : "internal",
          readOnly: false,
          targets: [],
          sizeBytes: size,
          usedBytes: Math.max(0, toNumber(fs.used, 0)),
          availBytes: Math.max(0, toNumber(fs.avail, 0))
        }
        order.push(key)
      }
      group.targets.push(target)
      if (/(^|,)ro(,|$)/.test(String(fs.options || ""))) group.readOnly = true
    }
  }

  collect(parsed.local && parsed.local.filesystems, false)
  collect(parsed.network && parsed.network.filesystems, true)

  var rank = { internal: 0, removable: 1, network: 2 }
  for (var k = 0; k < order.length; k++) {
    var g = groups[order[k]]
    // The shortest mount point names the filesystem: "/" rather than "/home".
    g.targets.sort(function(a, b) { return a.length - b.length || (a < b ? -1 : 1) })
    g.target = g.targets[0]
    g.title = diskTitle(g.target, g.label)
    g.extraMounts = g.targets.length - 1

    g.model = ""
    g.transport = ""
    if (g.kind !== "network") {
      var info = diskHardware(g.device, blocks)
      g.model = info.model
      g.transport = info.transport
      if (info.removable) g.kind = "removable"
    }

    // Percent as df reports it: against what non-root users can actually use,
    // so a disk at 100% really is full even with root-reserved blocks left.
    var usable = g.usedBytes + g.availBytes
    g.percent = usable > 0 ? clamp(100 * g.usedBytes / usable, 0, 100) : -1
    out.disks.push(g)
  }

  out.disks.sort(function(a, b) {
    if (rank[a.kind] !== rank[b.kind]) return rank[a.kind] - rank[b.kind]
    if (a.target === "/") return -1
    if (b.target === "/") return 1
    return a.target < b.target ? -1 : (a.target > b.target ? 1 : 0)
  })
  out.networkTimedOut = parsed.networkTimedOut === true
  out.ok = true
  return out
}

// Mount points left out of the Storage section unless the user says otherwise:
// the EFI system partition is a few hundred MB that only the bootloader uses.
var DISK_HIDE_DEFAULT = ["/boot", "/boot/efi", "/efi"]

function visibleDisks(disks, hiddenMounts) {
  if (!(disks instanceof Array)) return []
  var hidden = hiddenMounts instanceof Array ? hiddenMounts : []
  return disks.filter(function(d) { return hidden.indexOf(d.target) === -1 })
}

// Binary units like df -h, with the unit spelled out to match the GiB used
// elsewhere in the panel: "1.8 GiB", "205 GiB", "3.6 TiB".
function formatBytes(bytes) {
  if (!isFinite(bytes) || bytes < 0) return "–"
  var units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
  var value = bytes
  var i = 0
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024
    i++
  }
  var figure = i === 0 || value >= 10 ? String(Math.round(value)) : value.toFixed(1)
  return figure + " " + units[i]
}

// ---------------------------------------------------------------- ordering
//
// The bar items, the panel dials and the panel sections are each an ordered
// list of known keys, stored in shell.json as an array (a comma-separated
// string is accepted too, as `itemsOrder` always has been). Whatever the
// stored list leaves out is appended in default order, so a section added in a
// later version shows up instead of vanishing.

var BAR_ITEMS = ["gpu", "cpu", "cpu-temp", "gpu-temp", "ram"]
var PANEL_DIALS = ["cpu", "ram", "gpu"]
var PANEL_SECTIONS = ["dials", "history", "processor", "memory", "storage", "procs", "gpu"]

// Case is kept: mount points are case-sensitive.
function stringList(raw) {
  if (raw === undefined || raw === null) return []
  var items = raw instanceof Array ? raw : String(raw).split(/[,\s]+/)
  var out = []
  for (var i = 0; i < items.length; i++) {
    var s = String(items[i] === undefined || items[i] === null ? "" : items[i]).trim()
    if (s !== "") out.push(s)
  }
  return out
}

function keyList(raw) {
  return stringList(raw).map(function(s) { return s.toLowerCase() })
}

function normalizeOrder(raw, known) {
  var out = []
  var wanted = keyList(raw)
  for (var i = 0; i < wanted.length; i++) {
    if (known.indexOf(wanted[i]) !== -1 && out.indexOf(wanted[i]) === -1) out.push(wanted[i])
  }
  for (var j = 0; j < known.length; j++) {
    if (out.indexOf(known[j]) === -1) out.push(known[j])
  }
  return out
}

// Swap `key` with its neighbour `delta` places away; ends do not wrap.
function moveKey(order, key, delta) {
  var out = order.slice()
  var from = out.indexOf(key)
  var to = from + delta
  if (from === -1 || to < 0 || to >= out.length) return out
  out[from] = out[to]
  out[to] = key
  return out
}

// Add `key` to a hidden list or take it out.
function setHidden(list, key, hidden) {
  var out = keyList(list).filter(function(k) { return k !== key })
  if (hidden) out.push(key)
  return out
}

// ------------------------------------------------------------------ severity
//
// 0 while a reading is unremarkable, ramping to 1 as it crosses from `warn` to
// `critical`. Widget.qml mixes the theme foreground toward urgent by this
// amount, so a busy machine warms up gradually instead of flipping to red.

function severity(value, warn, critical) {
  if (!isFinite(value) || value < 0) return 0
  if (value <= warn) return 0
  return clamp((value - warn) / Math.max(1, critical - warn), 0, 1)
}

// Monospace digits are all the same width, so left-padding a reading to the
// width of its widest realistic value keeps the bar from reflowing every time
// a number gains or loses a digit. Values past that width still render — they
// just push the widget wider, which for 100% or 100°C is rare enough to accept.
function padLeft(text, width) {
  var out = String(text)
  while (out.length < width) out = " " + out
  return out
}
