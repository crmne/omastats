import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// One sampler process per shell, shared by every bar instance on every
// monitor. Holds the latest snapshot, the rolling histories the graphs draw
// from, and the theme-derived two-hue palette.
Item {
  id: root

  property var snapshot: ({})
  property var history: Model.emptyHistory()
  property int seq: -1
  property bool ready: false
  property string samplerError: ""
  property int historyLength: 240
  property real historySeconds: 240
  property real intervalSeconds: 1
  property int detailRefs: 0
  property int fullRefs: 0
  property int sentDetail: 0
  property string focusPage: ""
  property var themeColors: ({})
  property var instanceSettings: ({})
  property int restartCount: 0
  property var instances: []
  property bool destroying: false

  readonly property var palette: Model.pickPalette(themeColors, Color.accent, Color.foreground, Color.background, Color.urgent)
  readonly property color series1: palette.series1
  readonly property color series2: palette.series2
  readonly property color tertiary: palette.tertiary
  readonly property color warn: palette.warn
  readonly property color danger: palette.danger
  readonly property color good: palette.good

  readonly property bool hasGpu: !!(snapshot && snapshot.gpu)
  readonly property bool hasBattery: !!(snapshot && snapshot.battery && snapshot.battery.present)
  // The isolated Python entry point immediately execs the compiled sampler
  // when it is compatible, otherwise it remains the fallback implementation.
  // Absolute paths and a cleared environment keep launch behavior independent
  // of PATH, shell startup files, and Python environment hooks.
  readonly property string samplerPath: Qt.resolvedUrl("sampler.py").toString().replace(/^file:\/\//, "")

  function ingest(line) {
    var text = String(line || "")
    if (!text || text.length > 524288) return
    var data
    try { data = JSON.parse(text) } catch (error) { return }
    if (!data || typeof data !== "object") return

    var h = root.history
    var n = root.historyLength
    var cpu = data.cpu || {}
    var mem = data.mem || {}
    var net = data.net || {}
    var disks = data.disks || {}
    var gpu = data.gpu
    var battery = data.battery
    var memPercent = mem.total > 0 ? mem.used / mem.total * 100 : 0
    var perDisk = disks.perDisk || {}
    var diskHistory = {}
    for (var name in perDisk) {
      var previous = h.disks && h.disks[name] ? h.disks[name] : { read: [], write: [] }
      diskHistory[name] = {
        read: Model.pushHistory(previous.read, perDisk[name].read, n),
        write: Model.pushHistory(previous.write, perDisk[name].write, n)
      }
    }

    root.history = {
      cpuUser: Model.pushHistory(h.cpuUser, cpu.user, n),
      cpuSystem: Model.pushHistory(h.cpuSystem, cpu.system, n),
      cpuTotal: Model.pushHistory(h.cpuTotal, cpu.total, n),
      gpu: Model.pushHistory(h.gpu, gpu && isFinite(Number(gpu.util)) ? gpu.util : 0, n),
      memUsed: Model.pushHistory(h.memUsed, memPercent, n),
      memPressure: Model.pushHistory(h.memPressure, mem.pressureSome, n),
      netRx: Model.pushHistory(h.netRx, net.rx, n),
      netTx: Model.pushHistory(h.netTx, net.tx, n),
      diskRead: Model.pushHistory(h.diskRead, disks.read, n),
      diskWrite: Model.pushHistory(h.diskWrite, disks.write, n),
      disks: diskHistory,
      battery: Model.pushHistory(h.battery, battery && battery.present ? battery.percent : 0, n),
      batteryCharging: Model.pushHistory(h.batteryCharging, battery && battery.status === "Charging" ? 1 : 0, n)
    }
    root.snapshot = data
    root.seq = Number(data.seq) || 0
    root.ready = true
    root.samplerError = Array.isArray(data.errors) && data.errors.length > 0 ? data.errors.join("; ") : ""
  }

  function send(text) {
    if (sampler.running) sampler.write(text + "\n")
  }

  // Detail level: 0 nothing, 1 top processes, 2 every process. Open panels
  // hold a detail reference; an expanded process list holds a full one.
  function syncDetail() {
    var level = detailRefs > 0 ? (fullRefs > 0 ? 2 : 1) : 0
    if (level === sentDetail) return
    sentDetail = level
    send("detail " + level)
  }

  function acquireDetail() { detailRefs += 1; syncDetail() }
  function releaseDetail() { detailRefs = Math.max(0, detailRefs - 1); syncDetail() }
  function acquireFull() { fullRefs += 1; syncDetail() }
  function releaseFull() { fullRefs = Math.max(0, fullRefs - 1); syncDetail() }

  // Which page the open panel shows; the sampler adds page-specific extras
  // (per-process connections for the Network page).
  function setFocus(page) {
    var next = String(page || "")
    if (next === focusPage) return
    focusPage = next
    send("focus " + (next || "none"))
  }

  property real publicIpStamp: 0
  property bool publicIpPending: false

  // At most one lookup every ten minutes unless forced (the r key / IPC).
  // A request made before the sampler is up is held until it starts.
  function requestPublicIp(force) {
    var now = Date.now()
    if (!force && now - publicIpStamp < 600000) return
    publicIpStamp = now
    if (sampler.running) send("pubip")
    else publicIpPending = true
  }

  // Every bar instance reports its settings; the sampler runs at the fastest
  // requested interval and keeps the longest requested history.
  function registerSettings(key, settings) {
    var next = {}
    for (var k in instanceSettings) next[k] = instanceSettings[k]
    next[String(key)] = settings || {}
    instanceSettings = next
    recompute()
  }

  function unregisterSettings(key) {
    var next = {}
    for (var k in instanceSettings) if (k !== String(key)) next[k] = instanceSettings[k]
    instanceSettings = next
    recompute()
  }

  // The sampler runs at the fastest requested interval and the graphs keep
  // the longest requested span, converted to samples at that interval.
  function recompute() {
    var interval = 60
    var seconds = 0
    var any = false
    for (var k in instanceSettings) {
      var s = instanceSettings[k] || {}
      any = true
      interval = Math.min(interval, Model.clamp(s.refreshSeconds === undefined ? 1 : s.refreshSeconds, 0.1, 30))
      seconds = Math.max(seconds, Model.clamp(s.historySeconds === undefined ? 240 : s.historySeconds, 30, 3600))
    }
    if (!any) { interval = 1; seconds = 240 }
    historySeconds = seconds
    var samples = Math.round(Model.clamp(seconds / interval, 60, 3600))
    if (samples !== historyLength) historyLength = samples
    if (Math.abs(interval - intervalSeconds) > 0.001) {
      intervalSeconds = interval
      send("interval " + interval)
    }
  }

  function registerInstance(item) {
    if (!item || instances.indexOf(item) !== -1) return
    instances = instances.concat([item])
  }

  function unregisterInstance(item) {
    instances = instances.filter(function(existing) { return existing !== item })
  }

  // Route a tab request through the shell so it lands on the focused monitor's
  // copy of the widget, after pointing every copy at the requested tab.
  function showTab(tab, mode) {
    var live = instances.filter(function(item) { return !!item })
    if (live.length === 0) return "no-widget"
    var target = String(tab || "")
    for (var i = 0; i < live.length; i++) {
      if (target && typeof live[i].showTab === "function") live[i].showTab(target)
    }
    var shell = live[0].bar ? live[0].bar.shell : null
    if (!shell) return "no-shell"
    if (mode === "hide") shell.hide("crmne.omastats")
    else if (mode === "toggle") shell.toggle("crmne.omastats", "{}")
    else shell.summon("crmne.omastats", "{}")
    return "ok"
  }

  function summary() {
    var s = snapshot || {}
    var cpu = s.cpu || {}
    var mem = s.mem || {}
    var net = s.net || {}
    return {
      ready: ready,
      seq: seq,
      cpu: cpu.total,
      cpuTemp: cpu.temp,
      memoryPercent: mem.total > 0 ? Math.round(mem.used / mem.total * 1000) / 10 : 0,
      download: net.rx,
      upload: net.tx,
      gpu: s.gpu ? s.gpu.util : null,
      battery: s.battery && s.battery.present ? s.battery.percent : null,
      error: samplerError
    }
  }

  Process {
    id: sampler
    command: ["/usr/bin/python3", "-I", root.samplerPath, "--interval", "1"]
    clearEnvironment: true
    environment: ({ "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8" })
    running: true
    stdinEnabled: true
    stdout: SplitParser {
      onRead: function(line) { root.ingest(line) }
    }
    // Expected diagnostics travel in the bounded JSON stream. Leaving stderr
    // unbound makes Quickshell close that channel instead of buffering it.
    onStarted: {
      if (root.sentDetail > 0) root.send("detail " + root.sentDetail)
      if (root.focusPage) root.send("focus " + root.focusPage)
      if (root.publicIpPending) { root.publicIpPending = false; root.send("pubip") }
      if (Math.abs(root.intervalSeconds - 1) > 0.001) root.send("interval " + root.intervalSeconds)
    }
    onExited: function(code, status) {
      root.ready = false
      if (root.destroying) return
      root.restartCount += 1
      restartTimer.interval = Math.min(30000, 1000 * Math.pow(2, Math.min(5, root.restartCount)))
      restartTimer.restart()
    }
  }

  Timer {
    id: restartTimer
    repeat: false
    onTriggered: if (!root.destroying && !sampler.running) sampler.running = true
  }

  // A healthy sampler that has streamed for a while resets the backoff.
  Timer {
    interval: 60000
    repeat: true
    running: root.ready
    onTriggered: root.restartCount = 0
  }

  // The theme's named colours (red, blue, magenta, …) are not part of the
  // shell's Color singleton, so read colors.toml directly for the graph hues.
  FileView {
    id: colorsFile
    path: Color.currentThemePath + "/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.themeColors = Model.parseColorsToml(text())
    onFileChanged: reload()
    onLoadFailed: root.themeColors = ({})
  }

  Connections {
    target: Color
    function onAccentChanged() { colorsFile.reload() }
    function onBackgroundChanged() { colorsFile.reload() }
    function onForegroundChanged() { colorsFile.reload() }
  }

  Component.onDestruction: {
    root.destroying = true
    restartTimer.stop()
    if (sampler.running) {
      sampler.write("quit\n")
      sampler.running = false
    }
  }

  IpcHandler {
    target: "crmne.omastats"

    function status(): string { return JSON.stringify(root.summary()) }
    function refresh(): string { root.requestPublicIp(true); return "ok" }
    function locate(): string {
      return JSON.stringify(root.instances.map(function(item) {
        return item && typeof item.locateSelf === "function" ? item.locateSelf() : null
      }))
    }
    function show(tab: string): string { return root.showTab(tab, "show") }
    function toggle(tab: string): string { return root.showTab(tab, "toggle") }
    function hide(): string { return root.showTab("", "hide") }
  }
}
