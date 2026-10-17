// Renders OmaStats' real panel pages with a made-up
// machine, for preview.png. No sampler runs: a stand-in service serves a
// fixed, fictional snapshot and four minutes of history, so nothing about
// this computer (processes, addresses, drives) reaches the images. Run
// through scripts/render-preview.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "plugin" as Plugin
import "plugin/Model.js" as Model

ShellRoot {
  id: shell

  readonly property string outDir: Quickshell.env("OMASTATS_PREVIEW_OUT")
  readonly property var pages: ["cpu", "memory"]

  // ---- A fictional machine. Sizes in bytes, rates in bytes per second.
  readonly property real gib: 1073741824
  function proc(pid, name, cpu, memGiB, count) {
    return { pid: pid, name: name, cpu: cpu, mem: Math.round(memGiB * shell.gib), count: count || 1, read: 0, write: 0 }
  }
  readonly property var sampleGpu: ({
    id: "0000:01:00.0", name: "NVIDIA GeForce RTX 3080", vendor: "nvidia", util: 37, temp: 58, fan: 41,
    power: 182, mhz: 1710, maxMhz: 1905, memUsed: 4.3 * gib, memTotal: 10 * gib
  })
  readonly property var sampleSnapshot: ({
    seq: 240, t: 0, interval: 1, elapsed: 0.01, errors: [], battery: null,
    gpu: sampleGpu, gpus: [sampleGpu],
    cpu: {
      total: 40, user: 31, system: 9, iowait: 0.4, mhz: 4870, maxMhz: 5400, temp: 67, power: 74,
      model: "AMD Ryzen 7 7700X 8-Core Processor", coreCount: 8, threadCount: 16, uptime: 13320,
      load: [5.42, 4.87, 4.11], efficiency: [],
      cores: [62, 48, 35, 71, 22, 44, 30, 57, 41, 66, 38, 74, 19, 52, 33, 60]
    },
    mem: {
      total: Math.round(32 * gib), used: Math.round(13.4 * gib), apps: Math.round(9.8 * gib),
      shared: Math.round(1.1 * gib), cached: Math.round(11.2 * gib), free: Math.round(6.2 * gib),
      available: Math.round(18.6 * gib), compressed: Math.round(2.4 * gib), compressedSize: Math.round(0.8 * gib),
      swapTotal: Math.round(8 * gib), swapUsed: Math.round(1.3 * gib), pressureSome: 0.4, pressureFull: 0
    },
    net: { rx: 3145728, tx: 260096, online: true, default: "", publicIp: "", procs: null, ifaces: [] },
    disks: { read: 0, write: 0, perDisk: {}, volumes: [] },
    sensors: { temps: [], fans: [] },
    procs: {
      total: 412,
      cpu: [proc(1201, "cargo", 18, 0.4), proc(1202, "rust-analyzer", 10, 1.9), proc(1203, "firefox", 6, 3.4, 24),
        proc(1204, "Hyprland", 2, 0.2), proc(1205, "quickshell", 1, 0.24, 2), proc(1206, "alacritty", 1, 0.1, 3)],
      mem: [proc(1203, "firefox", 6, 3.4, 24), proc(1202, "rust-analyzer", 10, 1.9), proc(1207, "code", 0.8, 1.2, 9),
        proc(1208, "spotify", 0.6, 0.61, 6), proc(1201, "cargo", 18, 0.412), proc(1205, "quickshell", 1, 0.24, 2)],
      io: []
    }
  })

  // Smooth, repeatable curves for the history graphs: a few slow waves, no
  // randomness, so every render draws the same picture.
  function wave(i, base, amp, a, b) {
    return Math.max(0, base + amp * (0.55 * Math.sin(i / a) + 0.3 * Math.sin(i / b + 1.3) + 0.15 * Math.sin(i * 0.9)))
  }
  function sampleHistory(n) {
    var h = Model.emptyHistory()
    for (var i = 0; i < n; i++) {
      var user = wave(i, 30, 16, 17, 6)
      var system = wave(i, 9, 5, 21, 4)
      h.cpuUser = Model.pushHistory(h.cpuUser, user, n)
      h.cpuSystem = Model.pushHistory(h.cpuSystem, system, n)
      h.cpuTotal = Model.pushNullableHistory(h.cpuTotal, user + system, n)
      h.memUsed = Model.pushNullableHistory(h.memUsed, wave(i, 41, 2, 40, 13), n)
      h.memPressure = Model.pushHistory(h.memPressure, 0.4, n)
      h.netRx = Model.pushHistory(h.netRx, wave(i, 2.4e6, 1.6e6, 9, 4), n)
      h.netTx = Model.pushHistory(h.netTx, wave(i, 2.2e5, 1.4e5, 11, 3), n)
      var load = wave(i, 35, 14, 15, 6)
      h.gpu = Model.pushNullableHistory(h.gpu, load, n)
      h.gpus[shell.sampleGpu.id] = Model.pushNullableHistory(h.gpus[shell.sampleGpu.id] || [], load, n)
      h.diskRead = Model.pushHistory(h.diskRead, 0, n)
      h.diskWrite = Model.pushHistory(h.diskWrite, 0, n)
    }
    return h
  }

  // ---- Stand-in for OmaStatsService: the same properties, fixed data.
  Item {
    id: service
    property var snapshot: shell.sampleSnapshot
    property var history: shell.sampleHistory(240)
    property bool ready: true
    property string samplerError: ""
    property var savedBarConfig: null
    property var themeColors: ({})
    readonly property var palette: Model.pickPalette(themeColors, Color.accent, Color.foreground, Color.background, Color.urgent)
    readonly property color series1: palette.series1
    readonly property color series2: palette.series2
    readonly property color tertiary: palette.tertiary
    readonly property color warn: palette.warn
    readonly property color danger: palette.danger
    readonly property color good: palette.good
    readonly property bool hasGpu: Model.gpuList(snapshot).length > 0
    readonly property bool hasBattery: false
    function acquireDetail() {}
    function releaseDetail() {}
    function acquireFull() {}
    function releaseFull() {}
    function setFocus(page) {}
    function requestPublicIp(force) {}
    function registerSettings(key, settings) {}
    function unregisterSettings(key) {}
    function registerInstance(item) {}
    function unregisterInstance(item) {}

    // The theme's named colours, as the real service reads them.
    FileView {
      path: Color.currentThemePath + "/colors.toml"
      printErrors: false
      onLoaded: service.themeColors = Model.parseColorsToml(text())
    }
  }

  // ---- Stand-in for the bar the widget sits in.
  QtObject {
    id: fakeBar
    property string position: "top"
    property bool vertical: false
    property int barSize: 40
    property var activePopout: null
    property var clickTargets: []
    property color barForeground: Color.foreground
    property color foreground: Color.foreground
    property color background: Color.background
    property bool transparent: false
    property string fontFamily: Style.font.family
    property var shell: QtObject {
      property var barConfig: null
      property var pluginRegistry: null
      function serviceFor(id) { return service }
      function updateEntryInline(id, entry) { return true }
    }
    function run(command) {}
    function requestPopout(key) { activePopout = key }
    function releasePopout(key) { if (activePopout === key) activePopout = null }
    function targetBelongsToWindow(target, window) { return false }
    function switchPanelFrom(item, direction) { return false }
    function setCenterHoverRevealSuppressed(value) {}
  }

  // A bar-shaped strip across the top of the screen holding the widget, so
  // its panel opens beneath it. Layer-shell, so nothing on the desktop is
  // retiled.
  PanelWindow {
    id: strip
    anchors { top: true; left: true; right: true }
    implicitHeight: fakeBar.barSize
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "omastats-preview"

    Rectangle {
      id: barBox
      anchors.centerIn: parent
      width: widget.implicitWidth + 48
      height: parent.height
      color: Color.background

      Plugin.OmaStatsWidget {
        id: widget
        anchors.centerIn: parent
        height: parent.height
        bar: fakeBar
        settings: ({ id: "crmne.omastats", modules: "cpu,gpu,memory,network,sensors" })
      }
    }
  }

  function findByProperty(item, name) {
    if (!item) return null
    if (item[name] !== undefined && item.hasOwnProperty && item.hasOwnProperty(name)) return item
    var kids = item.data || item.children || []
    for (var i = 0; i < kids.length; i++) {
      var found = findByProperty(kids[i], name)
      if (found) return found
    }
    return null
  }

  function save(item, name) {
    // Twice the on-screen size, for sharp images on any display.
    item.grabToImage(function(result) { result.saveToFile(shell.outDir + "/" + name) },
      Qt.size(item.width * 2, item.height * 2))
  }

  Timer {
    interval: 700
    running: true
    repeat: true
    property int phase: 0
    property int page: 0
    onTriggered: {
      phase++
      var popup = shell.findByProperty(widget, "cardOrigin")
      // The popup's card: the bordered surface its content sits in.
      var cardItem = popup ? popup.contentItem[0] : null
      while (cardItem && cardItem.borderSpec === undefined) cardItem = cardItem.parent
      if (phase === 1) {
        widget.showTab(shell.pages[page])
        widget.open()
      }
      // Waits for the popup to map and lay out before grabbing it.
      if (phase === 3 && (!cardItem || cardItem.height < 100)) {
        phase--
        return
      }
      if (phase === 3) shell.save(cardItem, shell.pages[page] + "-full.png")
      if (phase === 4) {
        page++
        if (page < shell.pages.length) {
          widget.showTab(shell.pages[page])
          phase = 1
        } else {
          widget.close()
        }
      }
      if (phase === 5) Qt.quit()
    }
  }
}
