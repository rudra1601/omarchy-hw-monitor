import QtQuick
import Quickshell.Io
import Quickshell.Wayland
import "Model.js" as Model

// Samples CPU, memory, and GPU telemetry straight out of /proc and /sys.
//
// Discovery runs `hw-probe` once to find out which sysfs files this machine
// exposes. Steady-state bar sampling is blocking reads of virtual files
// measured in microseconds — no fork on a timer, which is why a two-second
// interval is affordable inside the shell process instead of forking a script
// the way a Waybar module would. Two documented exceptions fork helpers:
// `nvidia-smi` on the sample interval (NVIDIA cards expose no sysfs telemetry)
// and `proc_top.py` up to every 3 s, only while the system panel is open.
// `disk-probe` (findmnt + lsblk) is the third, up to every 5 s, also only
// while the panel is open.
//
// One instance exists per monitor, since the bar mounts a widget per screen.
// The reads are cheap enough that this is not worth coordinating.
Item {
  id: root

  property var settings: ({})

  // Set false on a screen this widget is not drawn on: the timers stop and the
  // probe never runs, so a hidden instance costs nothing.
  property bool active: true

  // Resolved from this file's own location rather than spelled out, so a fork
  // that renames the plugin id does not silently lose the helper.
  readonly property string pluginDir: {
    var dir = String(Qt.resolvedUrl("."))
    if (dir.indexOf("file://") === 0) dir = dir.substring(7)
    return dir.replace(/\/$/, "")
  }
  readonly property string probePath: pluginDir + "/hw-probe"

  readonly property int intervalSec: intSetting("refreshIntervalSec", 2, 1, 60)

  // ------------------------------------------------------------- discovery

  property var probe: Model.parseProbe("")
  readonly property var cpuInfo: probe.cpu
  readonly property var gpuInfo: Model.pickGpu(probe.gpus, setting("gpu", "auto"))
  readonly property bool hasGpu: gpuInfo !== null
  readonly property bool gpuIsNvidia: hasGpu && String(gpuInfo.kind) === "nvidia"

  // -------------------------------------------------------------- readings
  //
  // -1 means "this machine does not report it" or "not sampled yet". Every
  // formatter in Model.js renders that as a dash, so a missing sensor degrades
  // to a gap in the readout instead of a zero that looks like real data.

  property real cpuPercent: -1
  property real cpuTempC: -1
  property real cpuMhz: -1
  property var load: null

  property var memory: null
  readonly property real memPercent: memory ? memory.percent : -1

  // zram swap devices summed: {label, algorithm, sizeBytes, origBytes,
  // comprBytes, memUsedBytes}. null when the machine has none. Sampled by the
  // panel only (sampleZram), the bar does not show it.
  readonly property var zramDevices: probe.zram || []
  property var zram: null

  property real gpuPercent: -1
  property real gpuTempC: -1
  property real gpuWatts: -1
  property real gpuRpm: -1
  property real gpuMhz: -1
  property real gpuVramUsedBytes: -1
  property real gpuVramTotalBytes: -1
  readonly property real gpuVramPercent: gpuVramTotalBytes > 0
    ? Model.clamp(100 * gpuVramUsedBytes / gpuVramTotalBytes, 0, 100) : -1

  // Top processi per RAM: campionati solo a pannello aperto, mai in background.
  // Lo stato vive qui (persiste con la shell); il worker è per-tick e non
  // sopravvive tra i poll. Guardia singola: procTopProcess.running.
  property var topProcs: []
  property bool procPanelOpen: false
  // System summary for the panel header, read only while the panel is open.
  property string hostName: ""
  property string osName: ""
  property real uptimeSec: -1
  onProcPanelOpenChanged: if (procPanelOpen) sampleSystem()
  property bool procTopFailed: false
  property string procGroupedBy: "none"
  readonly property int topProcCount: intSetting("topProcCount", 6, 3, 12)
  readonly property string topProcSort: {
    var want = String(setting("topProcSort", "ram")).trim().toLowerCase()
    return want === "cpu" ? "cpu" : "ram"
  }
  readonly property bool topProcGroup: {
    var value = setting("topProcGroup", true)
    if (typeof value === "boolean") return value
    return String(value).trim().toLowerCase() !== "false"
  }
  readonly property string procTopPath: pluginDir + "/proc_top.py"
  // nvidia-smi formats its CSV numbers with the session locale, so a
  // comma-decimal locale (de_DE, fr_FR, it_IT) turns "55.30" into "55,30" —
  // a sixth comma-separated field, after which every reading is one slot off.
  // Pinning C makes the parse locale-proof instead of making the parser
  // tolerate a shape it cannot detect. Held in a `var` because
  // Process.environment is a QVariantHash and an object literal infers
  // QVariantMap, which qmllint reports as a type mismatch; the runtime accepts
  // it either way (verified by probe: the child sees LC_ALL=C and keeps its
  // inherited PATH, so the locale is overridden and nothing else is lost).
  readonly property var cleanLocale: ({ "LC_ALL": "C", "LANG": "C" })
  property double _lastProcTopTry: 0
  property double _lastProcTopOk: 0
  // Stale-length baselines for the byte guards: StdioCollector.text still
  // holds the PREVIOUS run's output until this run's first byte arrives, so
  // each guard compares against the length recorded at spawn — without a
  // baseline a slow-first-byte run would be killed for the last run's size.
  // stderr needs the same treatment as stdout: a collector that is never
  // written to again keeps its old text forever, so a bare `err > cap` latches
  // true after one oversized run and kills every later run of that helper at
  // the first poll, for the rest of the session.
  property int _probeBase: 0
  property int _nvidiaBase: 0
  property int _procTopBase: 0
  property int _probeErrBase: 0
  property int _nvidiaErrBase: 0
  property int _procTopErrBase: 0
  // Veto anti-teardown: nessun handler tocca più lo stato dopo l'inizio
  // della distruzione (finestra di reload). Ogni callback che può mutare
  // stato — Process/StdioCollector, watchdog, kill timer, byte guard, sample
  // timer, start() — controlla questo flag. Vedi onDestruction in fondo.
  property bool _destroyed: false

  // Mounted filesystems for the panel's Storage section. Same rules as the
  // top-process worker: sampled only while the panel is open, last good value
  // kept on failure. null until the first probe lands.
  property var disks: null
  property bool disksFailed: false
  property bool disksNetworkTimedOut: false
  readonly property string diskProbePath: pluginDir + "/disk-probe"
  property double _lastDiskTry: 0

  // Cumulative jiffies from the previous tick. CPU usage is the ratio between
  // two samples, so there is nothing to show until the second one lands.
  property var _prevJiffies: null

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  // hwmon reports temperatures in millidegrees, but a handful of drivers
  // report whole degrees. Anything under 200 is already in degrees.
  function readTemp(view) {
    var raw = Model.toNumber(view.text(), -1)
    if (!isFinite(raw) || raw <= 0) return -1
    return raw > 200 ? raw / 1000 : raw
  }

  function readNumber(view, divisor) {
    var raw = Model.toNumber(view.text(), -1)
    if (!isFinite(raw) || raw < 0) return -1
    return divisor ? raw / divisor : raw
  }

  function refreshProbe() {
    probeProcess.command = [probePath]
    _probeBase = String(probeOut.text).length
    _probeErrBase = String(probeErr.text).length
    probeWatchdog.restart()
    probeProcess.running = true
  }

  // Host name and OS do not change while the shell runs: read once.
  function sampleSystem() {
    if (_destroyed) return
    if (osName === "") {
      hostFile.reload()
      hostName = Model.cleanString(hostFile.text().trim(), 64) || ""
      osFile.reload()
      osName = Model.parseOsRelease(osFile.text())
    }
    uptimeFile.reload()
    uptimeSec = Model.parseUptime(uptimeFile.text())
  }

  // Emitted after every sample, so the open panel can follow the same tick
  // instead of running a sampling timer of its own.
  signal sampled()

  function sample() {
    if (_destroyed) return
    readSensors()
    sampled()
  }

  function readSensors() {
    if (procPanelOpen) sampleSystem()
    statFile.reload()
    var jiffies = Model.parseCpuJiffies(statFile.text())
    if (jiffies) {
      var usage = Model.cpuUsage(_prevJiffies, jiffies)
      if (usage >= 0) cpuPercent = usage
      _prevJiffies = jiffies
    }

    memFile.reload()
    var parsed = Model.parseMemory(memFile.text())
    if (parsed) memory = parsed

    cpuinfoFile.reload()
    var mhz = Model.averageMhz(cpuinfoFile.text())
    cpuMhz = mhz > 0 ? mhz : -1

    loadFile.reload()
    load = Model.parseLoadAverage(loadFile.text())

    if (cpuTempFile.path !== "") {
      cpuTempFile.reload()
      cpuTempC = readTemp(cpuTempFile)
    }

    if (gpuIsNvidia) {
      sampleNvidia()
      return
    }

    if (gpuAgxFile.path !== "") sampleAgx()

    if (gpuBusyFile.path !== "") {
      gpuBusyFile.reload()
      gpuPercent = readNumber(gpuBusyFile, 0)
    }
    if (gpuTempFile.path !== "") {
      gpuTempFile.reload()
      gpuTempC = readTemp(gpuTempFile)
    }
    if (gpuPowerFile.path !== "") {
      gpuPowerFile.reload()
      gpuWatts = readNumber(gpuPowerFile, 1000000)
    }
    if (gpuFanFile.path !== "") {
      gpuFanFile.reload()
      gpuRpm = readNumber(gpuFanFile, 0)
    }
    if (gpuClockFile.path !== "") {
      gpuClockFile.reload()
      gpuMhz = readNumber(gpuClockFile, 1000000)
    }
    if (gpuVramUsedFile.path !== "") {
      gpuVramUsedFile.reload()
      gpuVramUsedBytes = readNumber(gpuVramUsedFile, 0)
    }
    if (gpuVramTotalFile.path !== "") {
      gpuVramTotalFile.reload()
      gpuVramTotalBytes = readNumber(gpuVramTotalFile, 0)
    }
  }

  function sampleZram() {
    var devices = zramDevices
    if (devices.length === 0) {
      zram = null
      return
    }
    var total = { origBytes: 0, comprBytes: 0, memUsedBytes: 0, sizeBytes: 0 }
    var algorithms = []
    for (var i = 0; i < devices.length; i++) {
      var dev = devices[i]
      var path = String(dev.dir) + "/mm_stat"
      // One FileView for every device: with a single zram (the usual case)
      // the path never changes and this is a plain reload.
      if (zramFile.path !== path) zramFile.path = path
      zramFile.reload()
      var stat = Model.parseZramStat(zramFile.text())
      if (!stat) continue
      total.origBytes += stat.origBytes
      total.comprBytes += stat.comprBytes
      total.memUsedBytes += stat.memUsedBytes
      total.sizeBytes += Model.toNumber(dev.sizeBytes, 0)
      if (dev.algorithm && algorithms.indexOf(String(dev.algorithm)) === -1) algorithms.push(String(dev.algorithm))
    }
    total.algorithm = algorithms.join(", ")
    total.label = devices.length === 1 ? String(devices[0].name) : devices.length + " devices"
    zram = total
  }

  // Apple silicon (Asahi): one stats file for load, power and temperature.
  // A field missing from this read keeps its previous value.
  property real _agxPrevBusyNs: -1
  property real _agxPrevMs: 0
  function sampleAgx() {
    gpuAgxFile.reload()
    var s = Model.parseAgxStats(gpuAgxFile.text())
    var now = Date.now()
    if (s.util >= 0) {
      gpuPercent = s.util
    } else if (s.busyNs >= 0 && _agxPrevBusyNs >= 0 && s.busyNs >= _agxPrevBusyNs && now > _agxPrevMs) {
      gpuPercent = Math.min(100, (s.busyNs - _agxPrevBusyNs) / 1e4 / (now - _agxPrevMs))
    }
    if (s.busyNs >= 0) {
      _agxPrevBusyNs = s.busyNs
      _agxPrevMs = now
    }
    if (s.tempC >= 0) gpuTempC = s.tempC
    if (s.watts >= 0) gpuWatts = s.watts
  }

  function sampleNvidia() {
    if (_destroyed || nvidiaProcess.running) return
    // hw-probe reports the absolute path it resolved, so the bar never
    // re-resolves nvidia-smi from the session PATH at sample time.
    var bin = gpuInfo && gpuInfo.nvidiaPath ? String(gpuInfo.nvidiaPath) : "nvidia-smi"
    nvidiaProcess.command = [bin,
                             "--query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total,power.draw",
                             "--format=csv,noheader,nounits",
                             "--id=" + String(gpuInfo.index !== undefined ? gpuInfo.index : 0)]
    _nvidiaBase = String(nvidiaOut.text).length
    _nvidiaErrBase = String(nvidiaErr.text).length
    nvidiaWatchdog.restart()
    nvidiaProcess.running = true
  }

  function applyNvidia(raw) {
    var sample = Model.parseNvidia(raw)
    if (!sample) return
    gpuPercent = sample.busy
    gpuTempC = sample.tempC
    gpuWatts = sample.watts
    gpuVramUsedBytes = sample.vramUsedBytes
    gpuVramTotalBytes = sample.vramTotalBytes
  }

  // Lancia proc_top.py al massimo ogni 3 s. Solo valori allowlist in argv
  // (intero clampato, sort ram/cpu validato, flag --group per presenza):
  // la stringa grezza del setting non tocca mai argv. Niente PATH, niente shell.
  function refreshProcTop() {
    if (_destroyed || !active || !(procPanelOpen || _prefetching) || procTopProcess.running) return
    var now = Date.now()
    if (_lastProcTopTry > 0 && now - _lastProcTopTry < 3000) return
    _lastProcTopTry = now
    var cmd = ["/usr/bin/python3", procTopPath, "--top", String(topProcCount), "--sort", topProcSort]
    if (topProcGroup) cmd.push("--group")
    procTopProcess.command = cmd
    _procTopBase = String(procTopOut.text).length
    _procTopErrBase = String(procTopErr.text).length
    procTopProcess.running = true
    procTopWatchdog.restart()
  }

  // At most every 5 s; free space moves slowly. `force` skips the throttle,
  // for opening the panel and the R key.
  // Hover prefetch: the widget calls this when the pointer enters it, so the
  // panel's process list and storage are usually ready by the click. The
  // usual throttles apply (processes every 3 s, disks every 5 s).
  property bool _prefetching: false
  function prefetchPanel(wantProcs, wantDisks) {
    if (_destroyed || !active || procPanelOpen) return
    _prefetching = true
    if (wantProcs) refreshProcTop()
    if (wantDisks) refreshDisks(false)
    _prefetching = false
  }

  function refreshDisks(force) {
    if (_destroyed || !active || !(procPanelOpen || _prefetching) || diskProcess.running) return
    var now = Date.now()
    if (!force && _lastDiskTry > 0 && now - _lastDiskTry < 5000) return
    _lastDiskTry = now
    // Through bash, not the shebang: a copy synced without the exec bit still runs.
    diskProcess.command = ["/usr/bin/bash", diskProbePath]
    diskProcess.running = true
    diskWatchdog.restart()
  }

  // Cambio sort/raggruppamento → refresh immediato (throttle azzerato).
  // Le guardie in refreshProcTop restano valide: a pannello chiuso non parte.
  // Il veto è ripetuto qui perché questi due handler scrivono _lastProcTopTry
  // prima di chiamare: senza, muterebbero stato su un oggetto già distrutto.
  onTopProcSortChanged: {
    if (_destroyed) return
    _lastProcTopTry = 0
    refreshProcTop()
  }
  onTopProcGroupChanged: {
    if (_destroyed) return
    _lastProcTopTry = 0
    refreshProcTop()
  }

  // ----------------------------------------------------------------- files
  //
  // blockAllReads makes reload() synchronous: without it text() returns the
  // previous tick's contents and every readout lags a full interval. These are
  // kernel-generated files of a few KB, so a blocking read never stalls the UI.

  FileView { id: statFile; path: "/proc/stat"; blockAllReads: true; printErrors: false }
  FileView { id: memFile; path: "/proc/meminfo"; blockAllReads: true; printErrors: false }
  FileView { id: cpuinfoFile; path: "/proc/cpuinfo"; blockAllReads: true; printErrors: false }
  FileView { id: loadFile; path: "/proc/loadavg"; blockAllReads: true; printErrors: false }
  FileView { id: uptimeFile; path: "/proc/uptime"; blockAllReads: true; printErrors: false }
  FileView { id: hostFile; path: "/proc/sys/kernel/hostname"; blockAllReads: true; printErrors: false }
  FileView { id: osFile; path: "/etc/os-release"; blockAllReads: true; printErrors: false }
  FileView { id: zramFile; path: ""; blockAllReads: true; printErrors: false }

  FileView {
    id: cpuTempFile
    path: root.cpuInfo && root.cpuInfo.tempPath ? String(root.cpuInfo.tempPath) : ""
    blockAllReads: true
    printErrors: false
  }

  // A GPU sensor the card does not expose leaves its path empty, and sample()
  // skips it — the widget then renders a dash rather than a fake zero.
  FileView {
    id: gpuAgxFile
    path: root.hasGpu && root.gpuInfo.agxStatsPath ? String(root.gpuInfo.agxStatsPath) : ""
    blockAllReads: true
    printErrors: false
  }
  FileView {
    id: gpuBusyFile
    path: root.hasGpu && root.gpuInfo.busyPath ? String(root.gpuInfo.busyPath) : ""
    blockAllReads: true
    printErrors: false
  }
  FileView {
    id: gpuTempFile
    path: root.hasGpu && root.gpuInfo.tempPath ? String(root.gpuInfo.tempPath) : ""
    blockAllReads: true
    printErrors: false
  }
  FileView {
    id: gpuPowerFile
    path: root.hasGpu && root.gpuInfo.powerPath ? String(root.gpuInfo.powerPath) : ""
    blockAllReads: true
    printErrors: false
  }
  FileView {
    id: gpuFanFile
    path: root.hasGpu && root.gpuInfo.fanPath ? String(root.gpuInfo.fanPath) : ""
    blockAllReads: true
    printErrors: false
  }
  FileView {
    id: gpuClockFile
    path: root.hasGpu && root.gpuInfo.clockPath ? String(root.gpuInfo.clockPath) : ""
    blockAllReads: true
    printErrors: false
  }
  FileView {
    id: gpuVramUsedFile
    path: root.hasGpu && root.gpuInfo.vramUsedPath ? String(root.gpuInfo.vramUsedPath) : ""
    blockAllReads: true
    printErrors: false
  }
  FileView {
    id: gpuVramTotalFile
    path: root.hasGpu && root.gpuInfo.vramTotalPath ? String(root.gpuInfo.vramTotalPath) : ""
    blockAllReads: true
    printErrors: false
  }

  // ------------------------------------------------------------- processes

  // Byte caps: StdioCollector never emits the parser's read signal, so the
  // cap is enforced by polling the collected text length from a short repeat
  // Timer (verified on Quickshell 0.3.1: a 64 MB spewer is stopped within one
  // polling interval). Untampered output is one JSON line of at most a few
  // KB, so a cap crossing always means a runaway or tampered helper.
  Process {
    id: probeProcess
    stdout: StdioCollector {
      id: probeOut
      waitForEnd: false
      onStreamFinished: {
        if (root._destroyed) return
        root.probe = Model.parseProbe(text)
        // Sensor paths only become known here, so take the first real sample
        // once they land instead of waiting out a whole interval.
        root.sample()
      }
    }
    stderr: StdioCollector { id: probeErr; waitForEnd: false }
    onExited: {
      if (root._destroyed) return
      probeWatchdog.stop()
      probeKillTimer.stop()
      // A killed or crashed probe leaves discovery empty for the whole
      // session otherwise: retry slowly until one run succeeds.
      if (!root.probe.ok) probeRetryTimer.restart()
    }
  }

  Process {
    id: nvidiaProcess
    environment: root.cleanLocale
    stdout: StdioCollector {
      id: nvidiaOut
      waitForEnd: false
      onStreamFinished: { if (!root._destroyed) root.applyNvidia(text) }
    }
    stderr: StdioCollector { id: nvidiaErr; waitForEnd: false }
    onExited: {
      if (root._destroyed) return
      nvidiaWatchdog.stop()
      nvidiaKillTimer.stop()
    }
  }

  // Worker top-processi: esecuzione diretta (mai sh -c), stdout limitato a una
  // riga JSON <16 KB, validato da Model.parseProcTop. Fallimento soft: tiene
  // l'ultimo valore buono e alza procTopFailed invece di svuotare la sezione.
  Process {
    id: procTopProcess
    stdout: StdioCollector {
      id: procTopOut
      waitForEnd: false
      onStreamFinished: {
        if (root._destroyed) return
        // parseProcTop degrades fail-soft on every shape it documents, but an
        // exotic value type can still throw: catch it so the section flags a
        // failure instead of freezing silently. The watchdog is stopped in
        // onExited, not here — a helper that closes stdout and then hangs
        // must still be killed.
        var res = null
        try { res = Model.parseProcTop(text, 12) } catch (e) { res = null }
        if (!res) {
          root.procTopFailed = true
          return
        }
        var list = res.rows
        if (list.length > 0 || String(text).indexOf('"procs"') !== -1) {
          root.topProcs = list
          root.procGroupedBy = res.groupedBy
          root.procTopFailed = false
          root._lastProcTopOk = Date.now()
        } else {
          root.procTopFailed = true
        }
      }
    }
    stderr: StdioCollector { id: procTopErr; waitForEnd: false }
    onExited: {
      if (root._destroyed) return
      procTopWatchdog.stop()
      procTopKillTimer.stop()
    }
  }

  // Watchdog kill-before-next-tick: 0.4 s di lettura interna << 2 s << 3 s di
  // throttle. The first trigger sends SIGTERM via running=false; the kill
  // timer escalates to SIGKILL for a helper that ignores it. Both stay armed
  // until onExited — a helper that finishes its output and then hangs must
  // still be killed. nvidia and probe get the same two-stage treatment: a
  // wedged nvidia-smi or a hung hw-probe used to latch running=true forever.
  Timer {
    id: procTopWatchdog
    interval: 2000
    repeat: false
    onTriggered: {
      if (root._destroyed) return
      if (procTopProcess.running) procTopProcess.running = false
      procTopKillTimer.restart()
      root.procTopFailed = true
    }
  }

  Process {
    id: diskProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root._destroyed) return
        diskWatchdog.stop()
        var res = Model.parseDisks(text)
        if (res.ok) {
          root.disks = res.disks
          root.disksNetworkTimedOut = res.networkTimedOut
          root.disksFailed = false
        } else {
          root.disksFailed = true
        }
      }
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: {
      if (root._destroyed) return
      diskWatchdog.stop()
    }
  }

  // disk-probe bounds its own network call at 3 s; this only catches a local
  // filesystem that hangs statfs(), which should never happen.
  Timer {
    id: diskWatchdog
    interval: 6000
    repeat: false
    onTriggered: {
      if (root._destroyed) return
      if (diskProcess.running) diskProcess.running = false
      root.disksFailed = true
    }
  }

  Timer {
    id: procTopKillTimer
    interval: 1000
    repeat: false
    onTriggered: {
      if (root._destroyed) return
      if (procTopProcess.running) procTopProcess.signal(9)
    }
  }

  Timer {
    id: nvidiaWatchdog
    interval: 10000
    repeat: false
    onTriggered: {
      if (root._destroyed) return
      if (nvidiaProcess.running) nvidiaProcess.running = false
      nvidiaKillTimer.restart()
    }
  }

  Timer {
    id: nvidiaKillTimer
    interval: 2000
    repeat: false
    onTriggered: {
      if (root._destroyed) return
      if (nvidiaProcess.running) nvidiaProcess.signal(9)
    }
  }

  Timer {
    id: probeWatchdog
    interval: 8000
    repeat: false
    onTriggered: {
      if (root._destroyed) return
      if (probeProcess.running) probeProcess.running = false
      probeKillTimer.restart()
    }
  }

  Timer {
    id: probeKillTimer
    interval: 2000
    repeat: false
    onTriggered: {
      if (root._destroyed) return
      if (probeProcess.running) probeProcess.signal(9)
    }
  }

  // Byte-cap guards, one per helper: poll the collected text length while
  // the process runs and stop it past the cap, escalating through the same
  // kill timers the watchdogs use. Two rules keep the check honest, and both
  // apply to stderr exactly as to stdout: the baseline recorded at spawn
  // separates the previous run's stale text from this run's bytes (a collector
  // is only reset once THIS run writes its first byte, and one that is never
  // written to again keeps its old length forever), and stderr counts toward
  // the cap too. The running binding stops the guard when the process ends,
  // and the teardown veto stops it touching state during a reload.
  Timer {
    id: procTopByteGuard
    interval: 100
    repeat: true
    running: procTopProcess.running
    onTriggered: {
      if (root._destroyed) return
      var len = String(procTopOut.text).length
      var err = String(procTopErr.text).length
      if ((len !== root._procTopBase && len > 16384) ||
          (err !== root._procTopErrBase && err > 16384)) {
        procTopProcess.running = false
        procTopKillTimer.restart()
      }
    }
  }

  Timer {
    id: probeByteGuard
    interval: 100
    repeat: true
    running: probeProcess.running
    onTriggered: {
      if (root._destroyed) return
      var len = String(probeOut.text).length
      var err = String(probeErr.text).length
      if ((len !== root._probeBase && len > 65536) ||
          (err !== root._probeErrBase && err > 65536)) {
        probeProcess.running = false
        probeKillTimer.restart()
      }
    }
  }

  Timer {
    id: nvidiaByteGuard
    interval: 100
    repeat: true
    running: nvidiaProcess.running
    onTriggered: {
      if (root._destroyed) return
      var len = String(nvidiaOut.text).length
      var err = String(nvidiaErr.text).length
      if ((len !== root._nvidiaBase && len > 65536) ||
          (err !== root._nvidiaErrBase && err > 65536)) {
        nvidiaProcess.running = false
        nvidiaKillTimer.restart()
      }
    }
  }

  // Slow retry for discovery: armed only when a probe run ended without
  // producing a valid payload (killed, crashed, or malformed), restart() so
  // each failed exit resets the 30 s deadline, and never re-armed once a
  // run succeeds (onTriggered checks probe.ok).
  Timer {
    id: probeRetryTimer
    interval: 30000
    repeat: false
    onTriggered: {
      if (root._destroyed || root.probe.ok) return
      refreshProbe()
    }
  }

  // Cleanup anti-teardown: ferma worker, watchdog, byte guard e sample timer,
  // poi alza il veto, così nessun callback in volo tocca lo stato durante la
  // finalizzazione (reload). Il veto va alzato per primo: è l'unica cosa che
  // impedisce a un timer già accodato di rieseguire start() e rilanciare un
  // helper dopo che i watchdog sono stati spenti — un figlio che resterebbe
  // orfano perché nessuno lo ucciderebbe più.
  Component.onDestruction: {
    _destroyed = true
    procTopWatchdog.stop()
    procTopKillTimer.stop()
    nvidiaWatchdog.stop()
    nvidiaKillTimer.stop()
    probeWatchdog.stop()
    probeKillTimer.stop()
    probeRetryTimer.stop()
    diskWatchdog.stop()
    // Fermati esplicitamente: il loro `running` è legato a quello dei Process,
    // e dipendere dalla ri-valutazione del binding significherebbe affidare lo
    // spegnimento all'ordine di valutazione invece che a una dichiarazione.
    procTopByteGuard.stop()
    probeByteGuard.stop()
    nvidiaByteGuard.stop()
    sampleTimer.stop()
    warmupSampleTimer.stop()
    idleRearm.stop()
    if (procTopProcess.running) procTopProcess.running = false
    if (diskProcess.running) diskProcess.running = false
    if (nvidiaProcess.running) nvidiaProcess.running = false
    if (probeProcess.running) probeProcess.running = false
  }

  // -------------------------------------------------------------- lifetime

  Timer {
    id: sampleTimer
    // One tick a second while the panel is open (its CPU history is per
    // second), the configured interval otherwise.
    interval: root.procPanelOpen ? Math.min(1000, root.intervalSec * 1000) : root.intervalSec * 1000
    running: root.active && !root.idlePaused
    repeat: true
    onTriggered: {
      if (root._destroyed) return
      root.sample()
    }
  }

  // Sampling pauses after pauseWhenIdleSec without keyboard or mouse input
  // (screensaver, lock, screen off, away), unless the panel is open. Idle
  // inhibitors such as a playing video count as activity, as for Omarchy's own
  // idle handling. The first input resumes with a fresh reading. 0 = never.
  readonly property int pauseWhenIdleSec: intSetting("pauseWhenIdleSec", 120, 0, 3600)
  readonly property bool idlePaused: pauseWhenIdleSec > 0 && idleMonitor !== null && idleMonitor.isIdle && !procPanelOpen

  // An IdleMonitor keeps the timeout it was created with: changing it later
  // does not reach the compositor (observed 2026-11-06), and the settings
  // arrive just after creation, so a monitor bound to the setting kept the
  // built-in default. It is therefore built once the settings have settled
  // and rebuilt whenever pauseWhenIdleSec or `active` changes.
  property QtObject idleMonitor: null

  Component {
    id: idleMonitorComponent
    IdleMonitor {
      respectInhibitors: true
    }
  }

  function rebuildIdleMonitor() {
    if (idleMonitor) {
      idleMonitor.destroy()
      idleMonitor = null
    }
    if (_destroyed || !active || pauseWhenIdleSec <= 0) return
    idleMonitor = idleMonitorComponent.createObject(root, { timeout: pauseWhenIdleSec })
  }

  Timer {
    id: idleRearm
    interval: 200
    onTriggered: root.rebuildIdleMonitor()
  }

  onPauseWhenIdleSecChanged: idleRearm.restart()

  onIdlePausedChanged: {
    if (_destroyed || !active || idlePaused) return
    // The first reading after a pause spans the whole pause; the warm-up
    // sample 350 ms later shows current CPU load again.
    sample()
    warmupSampleTimer.restart()
  }

  // CPU usage needs two samples. Take the second one shortly after startup so
  // the widget shows a real number immediately rather than a dash.
  Timer {
    id: warmupSampleTimer
    interval: 350
    running: root.active
    repeat: false
    onTriggered: {
      if (root._destroyed) return
      root.sample()
    }
  }

  function start() {
    if (_destroyed || !active || probeProcess.running) return
    sample()
    refreshProbe()
  }

  // `active` follows the widget's screen membership, which collapses to true
  // for a moment while the window/screen is being torn down or hotplugged —
  // exactly the window where start() must not run.
  onActiveChanged: {
    if (!_destroyed && active) start()
    idleRearm.restart()
  }
  Component.onCompleted: {
    start()
    idleRearm.restart()
  }
}
