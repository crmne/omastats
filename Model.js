.pragma library

// Pure helpers shared by the service, bar readouts, and panel pages.
// No state lives here — everything is a function of its arguments.

var MODULES = [
  { id: "cpu",     icon: "󰻠", short: "CPU", label: "CPU",     page: "CpuPage.qml",     graph: true,  ring: true },
  { id: "gpu",     icon: "󰢮", short: "GPU", label: "GPU",     page: "GpuPage.qml",     graph: true,  ring: true },
  { id: "memory",  icon: "󰍛", short: "MEM", label: "Memory",  page: "MemoryPage.qml",  graph: true,  ring: true },
  { id: "disks",   icon: "󰋊", short: "DSK", label: "Disks",   page: "DisksPage.qml",   graph: true,  ring: true },
  { id: "network", icon: "󰛳", short: "NET", label: "Network", page: "NetworkPage.qml", graph: true,  ring: false },
  { id: "sensors", icon: "󰔏", short: "SEN", label: "Sensors", page: "SensorsPage.qml", graph: false, ring: false },
  { id: "battery", icon: "󰁹", short: "BAT", label: "Battery", page: "BatteryPage.qml", graph: false, ring: true },
  { id: "settings", icon: "󰒓", short: "SET", label: "Settings", page: "SettingsPage.qml", graph: false }
]

var PANEL_TABS = ["cpu", "gpu", "memory", "disks", "network", "sensors", "battery"]

// Every user-tunable key with its default. Flat keys keep the entry in
// shell.json readable and editable from Setup → Plugins as well as from the
// in-panel Settings page. Per-module bar styles live in "<module>Style" and
// fall back to "style" when empty. Their defaults apply only to an entry
// that has saved neither, so a bar styled before 1.8 keeps its look.
var SETTINGS = {
  modules: "cpu,memory,network,gpu,disks",
  style: "both",
  cpuStyle: "graph", gpuStyle: "graph", memoryStyle: "ring", disksStyle: "graph", networkStyle: "", sensorsStyle: "", batteryStyle: "",
  graphWidth: 36,
  barLabels: "text",
  disksSource: "all",
  barDisks: "",
  barSensors: "cpu",
  barGpus: "discrete",
  showGpuMemory: false,
  temperatureUnit: "Celsius",
  refreshSeconds: 1,
  historySeconds: 240,
  publicIp: true,
  utilizationColors: false,
  utilizationLowColor: "",
  utilizationNormalColor: "",
  utilizationWarningColor: "",
  utilizationCriticalColor: "",
  tabs: "cpu,gpu,memory,disks,network,sensors,battery",
  showProcesses: true,
  showCores: true, showLoad: true,
  showBreakdown: true,
  showVolumes: true, showActivity: true,
  showInterfaces: true, showTotals: true, showAddresses: true,
  showTemperatures: true, showFans: true,
  showHistory: true, showDetails: true, showDevices: true
}

// Sections each page can hide, as shown on the Settings page.
var PANEL_SECTIONS = {
  cpu: [
    { key: "showCores", label: "Per-core rings" },
    { key: "showLoad", label: "Load average and uptime" }
  ],
  memory: [
    { key: "showBreakdown", label: "Breakdown" }
  ],
  disks: [
    { key: "showVolumes", label: "Volumes" },
    { key: "showActivity", label: "Read and write activity" }
  ],
  network: [
    { key: "showInterfaces", label: "Interfaces" },
    { key: "showTotals", label: "Totals since boot" },
    { key: "publicIp", label: "Public IP address" },
    { key: "showAddresses", label: "IP addresses" }
  ],
  sensors: [
    { key: "showTemperatures", label: "Temperatures" },
    { key: "showFans", label: "Fans" }
  ],
  battery: [
    { key: "showHistory", label: "Charge history" },
    { key: "showDetails", label: "Details" },
    { key: "showDevices", label: "Devices" }
  ]
}

// Multiple-choice options per page, shown after that page's toggles.
var PANEL_CHOICES = {}

// Sampling intervals offered by the Settings page, in seconds.
var REFRESH_STOPS = [0.1, 0.2, 0.5, 1, 2, 5, 10]

function nearestStopIndex(value) {
  var v = Number(value)
  var best = 3
  var bestDistance = Infinity
  for (var i = 0; i < REFRESH_STOPS.length; i++) {
    var d = Math.abs(Math.log(REFRESH_STOPS[i]) - Math.log(isFinite(v) && v > 0 ? v : 1))
    if (d < bestDistance) { bestDistance = d; best = i }
  }
  return best
}

function intervalText(seconds) {
  var v = Number(seconds)
  if (!isFinite(v) || v <= 0) return "1"
  return v < 1 ? v.toFixed(1) : String(Math.round(v))
}

function parseList(raw) {
  var text = Array.isArray(raw) ? raw.join(",") : String(raw || "")
  var out = []
  var parts = text.split(/[\s,;]+/)
  for (var i = 0; i < parts.length; i++) if (parts[i] && out.indexOf(parts[i]) === -1) out.push(parts[i])
  return out
}

// ------------------------------------------------------------------- gpus

// Every GPU the sampler found, boot display first. Snapshots from an older
// sampler carry a single "gpu" object, so fall back to that.
function gpuList(snapshot) {
  var s = snapshot || {}
  if (Array.isArray(s.gpus)) return s.gpus
  return s.gpu ? [s.gpu] : []
}

function gpuId(gpu) {
  return gpu && gpu.id !== undefined && gpu.id !== null ? String(gpu.id) : ""
}

// The cards the bar shows unless told otherwise: the discrete ones, or the
// integrated one on a machine with nothing else.
function discreteGpus(snapshot) {
  var all = gpuList(snapshot)
  var out = []
  for (var i = 0; i < all.length; i++) if (!all[i].integrated) out.push(all[i])
  return out.length > 0 ? out : all
}

// The GPUs the bar shows: "discrete" (or nothing set) means discreteGpus,
// "all" every one, otherwise the PCI addresses picked on the Settings page,
// in that order.
function selectedGpus(snapshot, raw) {
  var all = gpuList(snapshot)
  var text = String(raw === undefined || raw === null ? SETTINGS.barGpus : raw).trim()
  if (!text || text.toLowerCase() === "discrete") return discreteGpus(snapshot)
  if (text.toLowerCase() === "all") return all
  if (text.toLowerCase() === "none") return []
  var ids = parseList(text)
  var out = []
  for (var i = 0; i < ids.length; i++) {
    for (var j = 0; j < all.length; j++) if (gpuId(all[j]) === ids[i]) out.push(all[j])
  }
  // A shell.json synced from another machine names cards this one lacks;
  // its own discrete cards stand in until the user picks here.
  return out.length > 0 ? out : discreteGpus(snapshot)
}

// Short bar tag. Several GPUs in the bar would otherwise all read "GPU".
function gpuShort(gpu) {
  switch (gpu ? String(gpu.vendor || "").toLowerCase() : "") {
    case "nvidia": return "NVD"
    case "amd": return "AMD"
    case "intel": return "INT"
  }
  return "GPU"
}

// Row label on the panel and the Settings page.
function gpuTitle(gpu) {
  return shortGpuName(gpu ? gpu.name : "") || gpuShort(gpu)
}

// Per-GPU utilisation history, falling back to the single-GPU series.
function gpuHistory(history, id) {
  var h = history || {}
  var key = String(id || "")
  if (h.gpus && h.gpus[key]) return h.gpus[key]
  return h.gpu || []
}

// Whether a card reports a utilisation figure at all. i915/xe expose none
// without the perf PMU, so an Intel readout carries clock and temperature.
function gpuHasUtil(gpu) {
  return !!gpu && gpu.util !== null && gpu.util !== undefined && isFinite(Number(gpu.util))
}

function gpuMemoryPercent(gpu) {
  if (!gpu || gpu.memUsed === null || gpu.memUsed === undefined || gpu.memTotal === null || gpu.memTotal === undefined) return null
  var used = Number(gpu.memUsed)
  var total = Number(gpu.memTotal)
  return isFinite(used) && isFinite(total) && used >= 0 && total > 0 ? Math.min(100, used / total * 100) : null
}

// ---------------------------------------------------------------- sensors

function finiteValue(v) {
  return v !== null && v !== undefined && isFinite(Number(v))
}

// The cards Sensors shows: the discrete ones, or the integrated one on a
// machine with nothing else. On a desktop with an APU the boot display is
// often the iGPU, which used to stand in for "GPU".
function sensorGpus(snapshot) {
  return discreteGpus(snapshot)
}

// The card behind the single "GPU" temperature: the first in sensorGpus
// that reports one.
function primarySensorGpu(snapshot) {
  var list = sensorGpus(snapshot)
  for (var i = 0; i < list.length; i++) if (finiteValue(list[i].temp)) return list[i]
  return null
}

// Every temperature: hwmon's, plus NVIDIA cards, which have no hwmon chip
// under the proprietary driver and report through nvidia-smi.
function sensorTemps(snapshot) {
  var s = snapshot || {}
  var sensors = s.sensors || {}
  var out = Array.isArray(sensors.temps) ? sensors.temps.slice() : []
  var gpus = gpuList(s)
  for (var i = 0; i < gpus.length; i++) {
    var gpu = gpus[i]
    if (String(gpu.vendor) !== "nvidia" || !finiteValue(gpu.temp)) continue
    out.push({ chip: "GPU", id: "gpu:" + gpuId(gpu), label: gpuTitle(gpu), title: gpuTitle(gpu), value: Number(gpu.temp), max: 0 })
  }
  return out
}

// Every fan: hwmon's in rpm, plus NVIDIA cards' in percent of full speed.
function sensorFans(snapshot) {
  var s = snapshot || {}
  var sensors = s.sensors || {}
  var out = Array.isArray(sensors.fans) ? sensors.fans.slice() : []
  var gpus = gpuList(s)
  for (var i = 0; i < gpus.length; i++) {
    var gpu = gpus[i]
    if (!finiteValue(gpu.fan)) continue
    out.push({ chip: "GPU", id: "gpufan:" + gpuId(gpu), label: gpuTitle(gpu) + " fan", percent: Number(gpu.fan) })
  }
  return out
}

function fanSpinning(fan) {
  return fan && (num(fan.rpm) > 0 || num(fan.percent) > 0)
}

// "1200 rpm", "30 %" or "Off", as {value, unit}.
function fanParts(fan) {
  if (fan && finiteValue(fan.percent)) {
    return num(fan.percent) > 0 ? { value: String(Math.round(fan.percent)), unit: "%" } : { value: "Off", unit: "" }
  }
  var rpm = num(fan ? fan.rpm : 0)
  return rpm > 0 ? { value: String(Math.round(rpm)), unit: "rpm" } : { value: "Off", unit: "" }
}

// How fast a fan spins, from 0 to 1: rpm against 2400, percent as given.
function fanFraction(fan) {
  if (fan && finiteValue(fan.percent)) return clamp(num(fan.percent) / 100, 0, 1)
  return Math.min(1, num(fan ? fan.rpm : 0) / 2400)
}

// Friendly row label for a hwmon temperature entry.
function sensorLabel(temp) {
  if (temp.title) return String(temp.title)
  var chip = String(temp.chip || "")
  var label = String(temp.label || "")
  if (!label || label === chip) return chip
  if (chip === "Board" || chip.indexOf("Board") === 0) return label
  if (label.indexOf(chip) === 0) return label
  return chip + " " + label
}

// Everything the bar's sensor readout can show, as {value, label, kind}.
function sensorOptions(snapshot) {
  var s = snapshot || {}
  var cpu = s.cpu || {}
  var gpu = primarySensorGpu(s)
  var sensors = s.sensors || {}
  var out = []
  if (isFinite(Number(cpu.temp)) && cpu.temp !== null) out.push({ value: "cpu", label: "CPU temperature", kind: "temp" })
  var gpus = gpuList(s)
  var gpuTemp = gpu ? gpu.temp : sensors.gpuTemp
  if (gpuTemp !== null && gpuTemp !== undefined && isFinite(Number(gpuTemp))) {
    out.push({ value: "gpu", label: gpus.length > 1 && gpu ? "GPU temperature (" + gpuTitle(gpu) + ")" : "GPU temperature", kind: "temp" })
  }
  if (gpus.length > 1) {
    for (var g = 0; g < gpus.length; g++) {
      if (!isFinite(Number(gpus[g].temp)) || gpus[g].temp === null) continue
      out.push({ value: "gpu:" + gpuId(gpus[g]), label: gpuTitle(gpus[g]) + " temperature", kind: "temp" })
    }
  }
  var temps = Array.isArray(sensors.temps) ? sensors.temps : []
  for (var i = 0; i < temps.length; i++) out.push({ value: String(temps[i].id), label: sensorLabel(temps[i]), kind: "temp" })
  var fans = sensorFans(s)
  for (var j = 0; j < fans.length; j++) out.push({ value: String(fans[j].id), label: String(fans[j].label || "Fan"), kind: "fan" })
  return out
}

// One reading for the bar: {icon, label, text, unit, kind} or null.
function sensorReading(snapshot, id, unit) {
  var s = snapshot || {}
  var cpu = s.cpu || {}
  var gpu = primarySensorGpu(s)
  var sensors = s.sensors || {}
  if (id === "cpu") {
    if (!(isFinite(Number(cpu.temp)) && cpu.temp !== null)) return null
    var c = tempParts(cpu.temp, unit)
    return { icon: "󰻠", short: "CPU", label: "CPU", text: c.value, unit: c.unit, kind: "temp", celsius: cpu.temp }
  }
  if (id.indexOf("gpu:") === 0) {
    var picked = null
    var list = gpuList(s)
    for (var p = 0; p < list.length; p++) if (gpuId(list[p]) === id.slice(4)) picked = list[p]
    if (!picked || !isFinite(Number(picked.temp)) || picked.temp === null) return null
    var pt = tempParts(picked.temp, unit)
    return { icon: "󰢮", short: gpuShort(picked), label: gpuTitle(picked), text: pt.value, unit: pt.unit, kind: "temp", celsius: picked.temp }
  }
  if (id === "gpu") {
    var gpuTemp = gpu ? gpu.temp : sensors.gpuTemp
    if (gpuTemp === null || gpuTemp === undefined || !isFinite(Number(gpuTemp))) return null
    var g = tempParts(gpuTemp, unit)
    return { icon: "󰢮", short: "GPU", label: "GPU", text: g.value, unit: g.unit, kind: "temp", celsius: gpuTemp }
  }
  var temps = Array.isArray(sensors.temps) ? sensors.temps : []
  for (var i = 0; i < temps.length; i++) {
    if (String(temps[i].id) === id) {
      var t = tempParts(temps[i].value, unit)
      return { icon: "󰔏", short: "TMP", label: sensorLabel(temps[i]), text: t.value, unit: t.unit, kind: "temp", celsius: temps[i].value }
    }
  }
  var fans = sensorFans(s)
  for (var j = 0; j < fans.length; j++) {
    if (String(fans[j].id) === id) {
      var f = fanParts(fans[j])
      return { icon: "󰈐", short: "FAN", label: String(fans[j].label || "Fan"), text: f.value, unit: f.unit, kind: "fan", rpm: num(fans[j].rpm) }
    }
  }
  return null
}

// A saved sensor id from before 1.5 names a chip by driver alone, so two NVMe
// drives or two DIMMs shared one id. Now a shared driver name carries its
// device ("nvme@0000:02:00.0/temp1"); map an old id to its first such sensor.
function stableSensorId(snapshot, id) {
  var sensors = (snapshot || {}).sensors || {}
  var all = (Array.isArray(sensors.temps) ? sensors.temps : []).concat(Array.isArray(sensors.fans) ? sensors.fans : [])
  var legacy = null
  for (var i = 0; i < all.length; i++) {
    var current = String(all[i].id)
    if (current === id) return id
    if (legacy === null && current.replace(/@[^\/]*\//, "/") === id) legacy = current
  }
  return legacy === null ? id : legacy
}

// ------------------------------------------------------------------ disks

// The sampler reports disks by kernel name, which follows probe order:
// nvme0n1 can be a different drive after a reboot. Each disk also carries
// an id from /dev/disk/by-id (model and serial), and settings save that.
function diskId(snapshot, name) {
  var perDisk = (((snapshot || {}).disks || {}).perDisk) || {}
  var entry = perDisk[name]
  return entry && entry.id ? String(entry.id) : String(name || "")
}

// The kernel name behind a saved disk: "all", the disk with that id, a disk
// saved by kernel name before ids existed, or "" when it is not attached.
function resolveDisk(snapshot, value) {
  var saved = String(value || "")
  if (!saved || saved === "all") return "all"
  var perDisk = (((snapshot || {}).disks || {}).perDisk) || {}
  for (var name in perDisk) if (perDisk[name] && String(perDisk[name].id) === saved) return name
  return perDisk[saved] ? saved : ""
}

// The id to save for a disk setting. A disk that is not attached keeps its
// saved value, so unplugging a drive never loses its readout.
function stableDiskId(snapshot, value) {
  var name = resolveDisk(snapshot, value)
  return name === "" ? String(value || "") : (name === "all" ? "all" : diskId(snapshot, name))
}

// Colour for a /proc/pressure share (0-100): calm below 10%, a warning
// from 10% and danger from 40%, when tasks stall most of the time.
function pressureColor(percent, calm, warn, danger) {
  var p = Number(percent) || 0
  return p >= 40 ? danger : (p >= 10 ? warn : calm)
}

// Saved disk and sensor choices rewritten to the identities the sampler
// reports, as {key: value} for each setting that changes, or null.
function stableSettings(settings, snapshot) {
  var out = {}
  var any = false
  var raw = String(settingValue(settings, "barDisks") || "").trim()
  if (raw && raw.toLowerCase() !== "none") {
    var list = barDisks(settings)
    var next = list.map(function(entry) { return { disk: stableDiskId(snapshot, entry.disk), show: entry.show } })
    var text = barDisksText(next)
    if (text !== barDisksText(list)) { out.barDisks = text; any = true }
  }
  var source = settingValue(settings, "disksSource")
  if (source !== undefined && source !== null && String(source).trim()) {
    var stableSource = stableDiskId(snapshot, String(source).trim())
    if (stableSource !== String(source).trim()) { out.disksSource = stableSource; any = true }
  }
  var sensorsRaw = settingValue(settings, "barSensors")
  if (sensorsRaw !== undefined && sensorsRaw !== null) {
    var ids = parseList(sensorsRaw)
    var stableIds = ids.map(function(id) { return stableSensorId(snapshot, id) })
    if (stableIds.join(",") !== ids.join(",")) { out.barSensors = stableIds.join(","); any = true }
  }
  return any ? out : null
}

// Settings as they read once stableSettings is applied.
function withStableSettings(settings, snapshot) {
  var changes = stableSettings(settings, snapshot)
  if (!changes) return settings
  var out = {}
  for (var k in settings) out[k] = settings[k]
  for (var c in changes) out[c] = changes[c]
  return out
}

function diskOptions(snapshot) {
  var s = snapshot || {}
  var disks = s.disks || {}
  var perDisk = disks.perDisk || {}
  var volumes = Array.isArray(disks.volumes) ? disks.volumes : []
  var models = {}
  for (var i = 0; i < volumes.length; i++) if (volumes[i].disk && volumes[i].model) models[volumes[i].disk] = volumes[i].model
  var out = [{ value: "all", label: "All disks" }]
  var names = Object.keys(perDisk).sort()
  for (var j = 0; j < names.length; j++) {
    var model = models[names[j]] ? " · " + String(models[names[j]]).slice(0, 22) : ""
    out.push({ value: diskId(snapshot, names[j]), label: names[j] + model })
  }
  return out
}

// What a disk readout reports: transfer speed, space used, or both.
var DISK_SHOWS = [
  { value: "speed", label: "Speed" },
  { value: "used", label: "Used" },
  { value: "both", label: "Both" }
]

function normalizeDiskShow(value) {
  var show = String(value || "").toLowerCase()
  if (show === "activity" || show === "rate" || show === "rates" || show === "io") show = "speed"
  if (show === "space" || show === "usage" || show === "capacity") show = "used"
  for (var i = 0; i < DISK_SHOWS.length; i++) if (DISK_SHOWS[i].value === show) return show
  return ""
}

// The bar's disk readouts as [{disk, show}]. "barDisks" lists entries like
// "all:speed,nvme-KIOXIA_EXCERIA_G3_SSD_YFWKS0TJZ3TS:both"; "none" means no
// readout. Disk ids can contain colons (usb-..._0:0), so the show is the
// text after the last one, when it names a show. Unset, it reproduces the
// 1.1 readout: one for disksSource, showing capacity when the disk look was
// a ring and transfer speed otherwise.
function barDisks(settings) {
  var raw = String(settingValue(settings, "barDisks") || "").trim()
  if (raw.toLowerCase() === "none") return []
  if (!raw) {
    var style = moduleStyle(settings, "disks")
    var styled = isSaved(settings, "disksStyle") || isSaved(settings, "style")
    return [{
      disk: String(settingValue(settings, "disksSource") || "all").trim() || "all",
      show: !styled || style === "ring" || style === "ring-text" ? "used" : "speed"
    }]
  }
  var out = []
  var seen = []
  var parts = parseList(raw)
  for (var i = 0; i < parts.length; i++) {
    var at = parts[i].lastIndexOf(":")
    var show = at === -1 ? "" : normalizeDiskShow(parts[i].slice(at + 1))
    var disk = show ? parts[i].slice(0, at) : parts[i]
    if (disk.toLowerCase() === "all") disk = "all"
    if (!disk || seen.indexOf(disk) !== -1) continue
    seen.push(disk)
    out.push({ disk: disk, show: show || "speed" })
  }
  return out
}

// barDisks on this machine. When every saved drive is missing, as when
// shell.json is synced from another computer, one readout covers all disks.
function barDisksHere(snapshot, settings) {
  var list = barDisks(settings)
  var perDisk = snapshot && snapshot.disks ? (snapshot.disks.perDisk || {}) : {}
  if (list.length === 0 || Object.keys(perDisk).length === 0) return list
  for (var i = 0; i < list.length; i++) if (resolveDisk(snapshot, list[i].disk) !== "") return list
  return [{ disk: "all", show: list[0].show }]
}

function barDisksText(list) {
  if (!list || list.length === 0) return "none"
  return list.map(function(entry) { return entry.disk + ":" + entry.show }).join(",")
}

// Bar tag for a disk readout when several share the bar: nvme0n1 -> NV0,
// sda -> SDA, mmcblk0 -> MC0.
function diskShort(disk) {
  var name = String(disk || "")
  if (!name || name === "all") return "DSK"
  var m = name.match(/^nvme(\d+)n\d+$/)
  if (m) return "NV" + m[1]
  m = name.match(/^mmcblk(\d+)$/)
  if (m) return "MC" + m[1]
  return name.replace(/[^A-Za-z0-9]/g, "").slice(0, 3).toUpperCase() || "DSK"
}

// Space used on one disk, or on every local disk for "all", summed over its
// mounted volumes: {used, size, fraction}. Network mounts have no block
// device behind them, so they never count; a ZFS pool is local even when its
// drive is unknown, so it does. If no volume maps to a known disk, "all"
// falls back to the root volume as 1.1 did.
function diskUsage(snapshot, disk) {
  var disks = (snapshot || {}).disks || {}
  var perDisk = disks.perDisk || {}
  var volumes = Array.isArray(disks.volumes) ? disks.volumes : []
  var used = 0
  var size = 0
  for (var i = 0; i < volumes.length; i++) {
    var v = volumes[i]
    if (disk === "all" ? !perDisk[v.disk] && v.fstype !== "zfs" : v.disk !== disk) continue
    used += num(v.used)
    size += num(v.size)
  }
  if (size <= 0 && disk === "all") {
    for (var j = 0; j < volumes.length; j++) {
      if (volumes[j].mount !== "/") continue
      used = num(volumes[j].used)
      size = num(volumes[j].size)
    }
  }
  return { used: used, size: size, fraction: size > 0 ? clamp(used / size, 0, 1) : 0 }
}

// ------------------------------------------------------------- processes

function processSortValue(item, key) {
  if (!item) return 0
  if (key === "io") return num(item.read) + num(item.write)
  if (key === "net") return num(item.rx) + num(item.tx)
  return num(item[key])
}

function filterProcesses(list, query, key) {
  var items = Array.isArray(list) ? list.slice() : []
  var q = String(query || "").trim().toLowerCase()
  if (q) items = items.filter(function(item) { return String(item.name || "").toLowerCase().indexOf(q) !== -1 })
  items.sort(function(a, b) {
    var d = processSortValue(b, key) - processSortValue(a, key)
    return d !== 0 ? d : String(a.name || "").localeCompare(String(b.name || ""))
  })
  return items
}

// The bar section of shell.json's text, or null when it does not parse.
function parseShellBar(text) {
  var config
  try { config = JSON.parse(String(text || "")) } catch (error) { return null }
  return config && typeof config === "object" && config.bar && typeof config.bar === "object" ? config.bar : null
}

// A widget's saved settings with the changes it has written that shell.json
// does not show yet. pending is {key: {value, at}}.
function withPending(saved, pending) {
  if (!saved) return null
  var out = {}
  for (var key in saved) out[key] = saved[key]
  for (var p in pending) out[p] = pending[p].value
  return out
}

// Pending changes still waiting for shell.json: one the file now shows is
// done, and one the file has not shown for ten seconds was overridden.
function prunePending(saved, pending, now) {
  var out = {}
  for (var key in pending) {
    var entry = pending[key]
    if (saved && JSON.stringify(saved[key]) === JSON.stringify(entry.value)) continue
    if (now - entry.at > 10000) continue
    out[key] = entry
  }
  return out
}

// Read the authoritative inline settings rather than a bar slot's cached
// copy. Without a location, only a unique entry is safe to identify.
function savedBarSettings(barConfig, id, location) {
  var layout = barConfig && barConfig.layout
  if (!layout) return null
  var entry = null
  if (location) {
    var entries = layout[location.section]
    entry = Array.isArray(entries) ? entries[location.index] : null
    if (!entry || entry.id !== id) return null
  } else {
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var list = layout[sections[s]]
      if (!Array.isArray(list)) continue
      for (var i = 0; i < list.length; i++) {
        if (!list[i] || list[i].id !== id) continue
        if (entry) return null
        entry = list[i]
      }
    }
  }
  if (!entry) return null
  var out = {}
  for (var key in entry) if (key !== "id") out[key] = entry[key]
  return out
}

function settingValue(settings, key) {
  var value = settings ? settings[key] : undefined
  if (key === "tabs" && value !== undefined && value !== null
      && !(settings && Number(settings.gpuTabVersion) >= 1)) {
    // Before 1.1, GPU details lived on CPU. Preserve access when upgrading a
    // saved tab list; after the first tab edit, honor explicit GPU choices.
    var tabs = parseModules(value)
    if (tabs.indexOf("cpu") !== -1 && tabs.indexOf("gpu") === -1
        && truthy(settings.showGpu, true)) {
      tabs.splice(tabs.indexOf("cpu") + 1, 0, "gpu")
      return tabs.join(",")
    }
  }
  return value === undefined || value === null ? SETTINGS[key] : value
}

function truthy(value, fallback) {
  if (typeof value === "boolean") return value
  if (typeof value === "number") return value !== 0
  if (typeof value === "string") {
    var s = value.trim().toLowerCase()
    if (s === "true" || s === "on" || s === "yes" || s === "1") return true
    if (s === "false" || s === "off" || s === "no" || s === "0") return false
  }
  return value === undefined || value === null ? fallback : !!value
}

function flag(settings, key) {
  return truthy(settingValue(settings, key), SETTINGS[key] === true)
}

var BAR_LABEL_MODES = ["text", "inline", "icon"]

// Bar label look: stacked letters (text), a horizontal short name (inline), or
// a glyph (icon). An unknown or missing value falls back to stacked letters.
function barLabelMode(value) {
  var mode = String(value === undefined || value === null ? "" : value).toLowerCase()
  return BAR_LABEL_MODES.indexOf(mode) !== -1 ? mode : "text"
}

function utilizationGrade(value) {
  if (value === null || value === undefined || value === "") return -1
  var n = Number(value)
  if (!isFinite(n)) return -1
  n = Math.round(clamp(n, 0, 100))
  return n < 25 ? 0 : (n < 60 ? 1 : (n < 85 ? 2 : 3))
}

function validHexColor(value) {
  return typeof value === "string" && /^#[0-9A-Fa-f]{6}$/.test(value)
}

var UTILIZATION_KEYS = ["utilizationLowColor", "utilizationNormalColor", "utilizationWarningColor", "utilizationCriticalColor"]
var UTILIZATION_DARK = ["#72ca9b", "#759cd1", "#da9c6c", "#d67471"]
var UTILIZATION_LIGHT = ["#277944", "#3569aa", "#9c6019", "#af4444"]

function utilizationSettingColor(settings, key, lightTheme) {
  var chosen = settingValue(settings, key)
  if (validHexColor(chosen)) return chosen
  var index = UTILIZATION_KEYS.indexOf(key)
  return (lightTheme ? UTILIZATION_LIGHT : UTILIZATION_DARK)[index]
}

function utilizationColor(settings, value, lightTheme) {
  var grade = utilizationGrade(value)
  if (!flag(settings, "utilizationColors") || grade < 0) return null
  return utilizationSettingColor(settings, UTILIZATION_KEYS[grade], lightTheme)
}

function utilizationHistoryColors(values, settings, lightTheme) {
  if (!flag(settings, "utilizationColors")) return []
  var out = []
  var list = Array.isArray(values) ? values : []
  for (var i = 0; i < list.length; i++) out.push(utilizationColor(settings, list[i], lightTheme))
  return out
}

// Bar readout looks: graph, ring, text (figure only), both (graph + figure),
// ring-text (ring + figure).
var STYLES = ["graph", "ring", "text", "both", "ring-text"]

function normalizeStyle(value) {
  var mode = String(value || "").toLowerCase().replace("+", "-").replace("_", "-")
  if (mode === "ringtext" || mode === "ring-figure") mode = "ring-text"
  if (mode === "graph-text") mode = "both"
  return STYLES.indexOf(mode) !== -1 ? mode : ""
}

// Style choices offered for one module: rings only where fullness means something.
function styleOptions(module) {
  var def = moduleDef(module)
  var out = []
  // Disk readouts pick speed or space per disk: speed draws a graph and
  // space a ring, so the look only chooses between picture and figure.
  if (module === "disks") {
    return [
      { value: "graph", label: "Graph or ring" },
      { value: "text", label: "Figure" },
      { value: "both", label: "Graph or ring, and figure" }
    ]
  }
  if (def.graph) out.push({ value: "graph", label: "Graph" })
  if (def.ring) out.push({ value: "ring", label: "Ring" })
  out.push({ value: "text", label: "Figure" })
  if (def.graph) out.push({ value: "both", label: "Graph and figure" })
  if (def.ring) out.push({ value: "ring-text", label: "Ring and figure" })
  return out
}

function isSaved(settings, key) {
  return !!settings && settings[key] !== undefined && settings[key] !== null
}

// Effective bar style for one module: its own override, else the global one.
// Unsaved, the module's default look applies, unless a global style was
// saved, which before 1.8 every module followed.
function moduleStyle(settings, module) {
  var key = module + "Style"
  var global = normalizeStyle(settingValue(settings, "style")) || "both"
  if (isSaved(settings, key)) return normalizeStyle(settings[key]) || global
  if (isSaved(settings, "style")) return global
  return normalizeStyle(SETTINGS[key]) || global
}

// A disk readout's look folded onto picture / figure / both.
function diskLook(style) {
  if (style === "ring") return "graph"
  if (style === "ring-text") return "both"
  return normalizeStyle(style) || "both"
}

function moveInList(list, id, delta) {
  var out = list.slice()
  var from = out.indexOf(id)
  if (from < 0) return out
  var to = Math.max(0, Math.min(out.length - 1, from + delta))
  if (to === from) return out
  out.splice(from, 1)
  out.splice(to, 0, id)
  return out
}

function moduleDef(id) {
  if (id === "gpuMemory") return { id: "gpuMemory", icon: "V󰍛", short: "VRM", label: "VRAM", page: "GpuPage.qml", graph: true, ring: true }
  for (var i = 0; i < MODULES.length; i++) if (MODULES[i].id === id) return MODULES[i]
  return MODULES[0]
}

function pageFile(tab) {
  return moduleDef(tab).page
}

// The panel tab that shows a given bar module. Every module has its own.
function tabFor(module) {
  return module === "gpuMemory" ? "gpu" : module
}

function parseModules(raw) {
  var text = Array.isArray(raw) ? raw.join(",") : String(raw || "")
  var parts = text.toLowerCase().split(/[\s,;]+/)
  var out = []
  for (var i = 0; i < parts.length; i++) {
    var id = parts[i]
    if (id === "mem" || id === "ram") id = "memory"
    if (id === "disk" || id === "storage") id = "disks"
    if (id === "net" || id === "wifi") id = "network"
    if (id === "temp" || id === "temps" || id === "sensor") id = "sensors"
    if (id === "bat") id = "battery"
    var known = false
    for (var j = 0; j < MODULES.length; j++) if (MODULES[j].id === id) known = true
    if (known && out.indexOf(id) === -1) out.push(id)
  }
  return out
}

// Module tabs in canonical order, filtered by the "tabs" setting and by the
// hardware present. Never empty: the CPU tab is the floor.
function panelTabs(hasBattery, tabsSetting, hasGpu) {
  var wanted = parseModules(tabsSetting === undefined ? SETTINGS.tabs : tabsSetting)
  var out = []
  for (var i = 0; i < PANEL_TABS.length; i++) {
    var id = PANEL_TABS[i]
    if (id === "battery" && !hasBattery) continue
    if (id === "gpu" && !hasGpu) continue
    if (wanted.indexOf(id) === -1) continue
    out.push(id)
  }
  return out.length > 0 ? out : ["cpu"]
}

// ------------------------------------------------------------------ numbers

function clamp(v, lo, hi) {
  var n = Number(v)
  if (!isFinite(n)) return lo
  return Math.max(lo, Math.min(hi, n))
}

function num(v, fallback) {
  var n = Number(v)
  return isFinite(n) ? n : (fallback === undefined ? 0 : fallback)
}

var BYTE_UNITS = ["B", "KB", "MB", "GB", "TB", "PB"]

function bytesParts(n) {
  var v = Number(n)
  if (!isFinite(v) || v < 0) v = 0
  var i = 0
  while (v >= 1024 && i < BYTE_UNITS.length - 1) { v /= 1024; i++ }
  var text
  if (i <= 1 || v >= 100) text = String(Math.round(v))
  else text = v.toFixed(1)
  return { value: text, unit: BYTE_UNITS[i] }
}

function bytesText(n) {
  var p = bytesParts(n)
  return p.value + " " + p.unit
}

function rateParts(n) {
  var p = bytesParts(n)
  return { value: p.value, unit: p.unit + "/s" }
}

function rateText(n) {
  var p = rateParts(n)
  return p.value + " " + p.unit
}

// Ultra-compact rate for the bar: "0", "34K", "1.2M".
function compactRate(n) {
  var v = Number(n)
  if (!isFinite(v) || v < 512) return "0"
  var p = bytesParts(v)
  return p.value + p.unit.charAt(0)
}

// "1.2 / 24 GB" — drop the unit from the first number when both share it.
function pairText(a, b) {
  var pa = bytesParts(a), pb = bytesParts(b)
  if (pa.unit === pb.unit) return pa.value + " / " + pb.value + " " + pb.unit
  return pa.value + " " + pa.unit + " / " + pb.value + " " + pb.unit
}

function percentParts(v) {
  return { value: String(Math.round(clamp(v, 0, 100))), unit: "%" }
}

function percentText(v) {
  return Math.round(clamp(v, 0, 100)) + "%"
}

function tempValue(celsius, unit) {
  var c = Number(celsius)
  if (!isFinite(c)) return NaN
  return unit === "Fahrenheit" ? c * 9 / 5 + 32 : c
}

function tempParts(celsius, unit) {
  var v = tempValue(celsius, unit)
  if (!isFinite(v)) return { value: "—", unit: "" }
  return { value: String(Math.round(v)), unit: "°" }
}

function tempText(celsius, unit) {
  var p = tempParts(celsius, unit)
  return p.value + p.unit
}

function tempLongText(celsius, unit) {
  var v = tempValue(celsius, unit)
  if (!isFinite(v)) return "—"
  return Math.round(v) + (unit === "Fahrenheit" ? "°F" : "°C")
}

function freqText(mhz) {
  var m = Number(mhz)
  if (!isFinite(m) || m <= 0) return ""
  return m >= 1000 ? (m / 1000).toFixed(2) + " GHz" : Math.round(m) + " MHz"
}

// "167 W" for a power reading, or "" when there is none.
function wattsText(watts) {
  if (watts === null || watts === undefined || watts === "") return ""
  var w = Number(watts)
  if (!isFinite(w) || w < 0) return ""
  return (w < 10 ? w.toFixed(1) : String(Math.round(w))) + " W"
}

// Bar-width-friendly clock, shown instead of a load figure by a card that
// reports no utilisation.
function compactFreq(mhz) {
  var m = Number(mhz)
  if (!isFinite(m) || m <= 0) return "\u2014"
  return m >= 1000 ? (m / 1000).toFixed(1) + "G" : Math.round(m) + "M"
}

function uptimeText(seconds) {
  var s = Math.max(0, Math.floor(Number(seconds) || 0))
  var d = Math.floor(s / 86400)
  var h = Math.floor((s % 86400) / 3600)
  var m = Math.floor((s % 3600) / 60)
  if (d > 0) return d + "d " + h + "h"
  if (h > 0) return h + "h " + m + "m"
  if (m > 0) return m + "m"
  return "<1m"
}

function clockText(minutes) {
  var m = Math.max(0, Math.round(Number(minutes) || 0))
  var h = Math.floor(m / 60)
  var r = m % 60
  return h + ":" + (r < 10 ? "0" : "") + r
}

function loadText(load) {
  if (!Array.isArray(load) || load.length < 3) return "—"
  return load.map(function(v) { return Number(v).toFixed(2) }).join("  ")
}

function volumeName(mount) {
  var m = String(mount || "")
  if (m === "/") return "Root"
  if (m === "/home") return "Home"
  if (m === "/boot" || m === "/boot/efi" || m === "/efi") return "Boot"
  var parts = m.split("/")
  return parts[parts.length - 1] || m
}

// ------------------------------------------------------------- disk groups

var VOLUME_KINDS = [
  { kind: "internal", title: "Internal" },
  { kind: "external", title: "External" },
  { kind: "network", title: "Network" }
]

// Volumes in the order internal, external, network, as
// [{kind, title, items: [{volume, index}]}]; empty groups are left out.
// Snapshots from an older sampler carry no kind and count as internal.
function volumeGroups(volumes) {
  var list = Array.isArray(volumes) ? volumes : []
  var out = []
  for (var g = 0; g < VOLUME_KINDS.length; g++) {
    var items = []
    for (var i = 0; i < list.length; i++) {
      var kind = list[i] && list[i].kind ? String(list[i].kind) : "internal"
      if (kind === VOLUME_KINDS[g].kind) items.push({ volume: list[i], index: i })
    }
    if (items.length) out.push({ kind: VOLUME_KINDS[g].kind, title: VOLUME_KINDS[g].title, items: items })
  }
  return out
}

// What a click on a volume selects: its drive, or for a network mount the
// share itself.
function volumeKey(volume) {
  if (!volume) return ""
  return String(volume.key || volume.disk || volume.device || "")
}

// How a drive is coping right now, from its latest load and the system's
// I/O pressure: {level: "" | "warn" | "danger", text}. A drive that is busy
// nearly all the time while every task waits on I/O is what freezes a desktop.
function driveHealth(load, pressureFull, rotational) {
  if (!load) return { level: "", text: "" }
  var busy = Number(load.busy) || 0
  var latency = load.latency === null || load.latency === undefined ? NaN : Number(load.latency)
  var full = Number(pressureFull) || 0
  if (busy >= 90 && full >= 20)
    return { level: "danger", text: "Stalling the system: busy " + Math.round(busy) + "% of the time while every task waits on I/O" }
  if (isFinite(latency) && busy >= 50 && latency >= (rotational ? 100 : 20))
    return { level: "warn", text: "Slow to answer: " + latencyText(latency) + " per request" }
  return { level: "", text: "" }
}

function latencyText(ms) {
  var v = Number(ms)
  if (!isFinite(v)) return "—"
  if (v < 1) return (Math.round(v * 100) / 100) + " ms"
  if (v < 10) return (Math.round(v * 10) / 10) + " ms"
  return Math.round(v) + " ms"
}

// ------------------------------------------------------------- disk checks

// Wording for each problem the sampler reports on a volume. The sampler
// sends facts only; what it means and how to fix it is said here.
function checkText(check) {
  var c = check || {}
  switch (String(c.id || "")) {
    case "trim-blocked":
      return {
        title: "TRIM never reaches this drive",
        detail: "The encrypted volume " + (c.layer || "") + " was unlocked without allowing discards, so fstrim reports success "
          + "but the SSD is never told which blocks are free. It slows down as it fills and wears faster."
          + (c.fix ? "" : " Unlock it with discards allowed (allow-discards in crypttab, or rd.luks.options=discard)."),
        fixLabel: "Allow TRIM"
      }
    case "trim-off":
      return {
        title: "Free space is never trimmed",
        detail: "This SSD is mounted without discard and the weekly fstrim timer is off, so the drive is never told which blocks are free.",
        fixLabel: "Turn on weekly TRIM"
      }
    case "fat-flush":
      var flags = Array.isArray(c.flags) ? c.flags.join(", ") : "flush"
      return {
        title: "Every file written waits for the drive",
        detail: "Mounted with " + flags + ": closing each written file waits for the drive, about a tenth of a second on a USB stick, "
          + "so copying many small files crawls."
          + (c.fix ? " The fix mounts it without that option from now on; eject it before unplugging."
                   : " Mount it without " + flags + " to fix it."),
        fixLabel: "Mount without flush"
      }
  }
  return { title: String(c.id || "Check"), detail: "", fixLabel: "Fix" }
}

// Shell scripts behind each Fix button. Each runs in a terminal, says what it
// will change, asks before changing it, and gets its names as positional
// arguments, never spliced into the script.
var FIX_SCRIPTS = {
  "allow-discards": {
    args: 1,
    body: 'echo "Let TRIM pass through the encrypted volume $1 to the SSD."\n'
      + 'echo "This runs: sudo cryptsetup refresh --allow-discards --persistent $1"\n'
      + 'echo "The setting is stored in the LUKS header, so it lasts across reboots."\n'
      + 'confirm || exit 1\n'
      + 'sudo cryptsetup refresh --allow-discards --persistent "$1" || exit 1\n'
      + 'echo "Trimming free space now:"\n'
      + 'sudo fstrim -av\n'
  },
  "enable-fstrim": {
    args: 0,
    body: 'echo "Turn on the weekly TRIM of every mounted SSD."\n'
      + 'echo "This runs: sudo systemctl enable --now fstrim.timer"\n'
      + 'confirm || exit 1\n'
      + 'sudo systemctl enable --now fstrim.timer\n'
  },
  "udisks-no-flush": {
    args: 2,
    body: 'conf=/etc/udisks2/mount_options.conf\n'
      + 'echo "Mount the FAT drive $2 without flush from now on, so small writes are fast."\n'
      + 'echo "This adds a section for it to $conf, then unmounts and mounts it again."\n'
      + 'echo "Let any copy to it finish first. Afterwards, always eject it before unplugging."\n'
      + 'confirm || exit 1\n'
      + 'if ! grep -qsF "[/dev/disk/by-uuid/$1]" "$conf"; then\n'
      + '  printf \'\\n# Added by OmaStats: mount this FAT drive without flush.\\n[/dev/disk/by-uuid/%s]\\nvfat_defaults=uid=$UID,gid=$GID,shortname=mixed,utf8=1,showexec\\n\' "$1" | sudo tee -a "$conf" >/dev/null || exit 1\n'
      + 'fi\n'
      + 'udisksctl unmount -b "$2" && udisksctl mount -b "$2"\n'
  }
}

var FIX_PRELUDE = 'confirm() { printf "Continue? [y/N] "; read -r answer; [ "$answer" = y ] || [ "$answer" = Y ]; }\n'
var FIX_EPILOGUE = 'status=$?\necho\nif [ "$status" -eq 0 ]; then echo "Done."; else echo "Nothing changed, or it failed (status $status)."; fi\n'
  + 'printf "Press Enter to close. "; read -r _\n'

function fixArgOk(value) {
  var v = String(value === undefined || value === null ? "" : value)
  return v.length > 0 && v.length <= 128 && /^[A-Za-z0-9._:\/-]+$/.test(v) && v.indexOf("..") === -1
}

// The command a Fix button runs, as argv, or null when the check has no fix
// or its arguments are not plain names.
function fixCommand(check) {
  var c = check || {}
  var spec = FIX_SCRIPTS[String(c.fix || "")]
  if (!spec) return null
  var args = Array.isArray(c.args) ? c.args : []
  if (args.length !== spec.args) return null
  for (var i = 0; i < args.length; i++) if (!fixArgOk(args[i])) return null
  var script = FIX_PRELUDE + "(\n" + spec.body + ")\n" + FIX_EPILOGUE
  return ["xdg-terminal-exec", "sh", "-c", script, "omastats-fix"].concat(args.map(String))
}

// Checks on the volumes of one drive (by volumeKey), or on every volume for
// "all", as [{check, volume}].
function driveChecks(volumes, key) {
  var list = Array.isArray(volumes) ? volumes : []
  var out = []
  for (var i = 0; i < list.length; i++) {
    if (key && key !== "all" && volumeKey(list[i]) !== key) continue
    var checks = Array.isArray(list[i].checks) ? list[i].checks : []
    for (var j = 0; j < checks.length; j++) out.push({ check: checks[j], volume: list[i] })
  }
  return out
}

function shortGpuName(name) {
  var raw = String(name || "GPU")
  // Keep the manufacturer so cards remain distinct in multi-GPU views. Drop
  // only redundant product-family or corporate wording.
  if (/^(AMD\s+)?Radeon\s+Graphics$/i.test(raw)) return "AMD Radeon Graphics"
  return raw
    .replace(/^NVIDIA\s+GeForce\s+/i, "NVIDIA ")
    .replace(/^GeForce\s+/i, "NVIDIA ")
    .replace(/^AMD\s+Radeon\s+/i, "AMD ")
    .replace(/^Radeon\s+/i, "AMD ")
    .replace(/^Intel\s+Corporation\s+/i, "Intel ")
}

function batteryIcon(percent, charging) {
  if (charging) return "󰂄"
  var icons = ["󰂎", "󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
  return icons[Math.round(clamp(percent, 0, 100) / 10)]
}

function wifiIcon(dbm) {
  var d = Number(dbm)
  if (!isFinite(d)) return "󰤨"
  if (d >= -55) return "󰤨"
  if (d >= -65) return "󰤥"
  if (d >= -75) return "󰤢"
  if (d >= -85) return "󰤟"
  return "󰤯"
}

function ifaceIcon(iface) {
  if (!iface) return "󰈀"
  if (iface.wireless) return wifiIcon(iface.dbm)
  if (/^(tun|tap|wg|tailscale|proton|nord|vpn)/.test(iface.name || "")) return "󰖂"
  return "󰈀"
}

function linkSpeedText(iface) {
  if (!iface) return ""
  if (iface.wireless && iface.bitrate) return Math.round(iface.bitrate) + " Mb/s"
  var mbps = Number(iface.speed)
  if (!isFinite(mbps) || mbps <= 0) return ""
  return mbps >= 1000 ? (mbps / 1000) + " Gb/s" : mbps + " Mb/s"
}

// ------------------------------------------------------------------ history

function emptyHistory() {
  return {
    cpuUser: [], cpuSystem: [], cpuTotal: [], gpu: [], gpus: {}, gpuMemory: { gpus: {} },
    memUsed: [], memPressure: [],
    netRx: [], netTx: [], diskRead: [], diskWrite: [], disks: {},
    battery: [], batteryCharging: []
  }
}

function pushHistory(arr, value, max) {
  var list = Array.isArray(arr) ? arr : []
  var keep = Math.max(1, max - 1)
  var out = list.length > keep ? list.slice(list.length - keep) : list.slice()
  out.push(Number(value) || 0)
  return out
}

function pushNullableHistory(arr, value, max) {
  var valid = value !== null && value !== undefined && value !== "" && isFinite(Number(value))
  var out = pushHistory(arr, valid ? Number(value) : 0, max)
  out[out.length - 1] = valid ? Number(value) : null
  return out
}

function maxOf(arr, count) {
  if (!Array.isArray(arr) || arr.length === 0) return 0
  var start = count > 0 ? Math.max(0, arr.length - count) : 0
  var m = 0
  for (var i = start; i < arr.length; i++) if (arr[i] > m) m = arr[i]
  return m
}

function last(arr, fallback) {
  if (!Array.isArray(arr) || arr.length === 0) return fallback
  return arr[arr.length - 1]
}

// ------------------------------------------------------------------ palette

function parseColorsToml(text) {
  var out = {}
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var m = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
    if (m) out[m[1]] = m[2]
  }
  return out
}

function hueOf(c) {
  var q = Qt.color(c)
  return q.hslHue < 0 ? -1 : q.hslHue * 360
}

function hueDistance(a, b) {
  if (a < 0 || b < 0) return 0
  var d = Math.abs(a - b) % 360
  return d > 180 ? 360 - d : d
}

function shiftHue(c, degrees, minSaturation) {
  var q = Qt.color(c)
  var h = q.hslHue < 0 ? 0.6 : (q.hslHue + degrees / 360 + 1) % 1
  return Qt.hsla(h, Math.max(minSaturation || 0.45, q.hslSaturation), clamp(q.hslLightness, 0.45, 0.72), 1)
}

// Derive the two-hue iStat scheme from the active theme: series1 is the
// accent; series2 is the theme colour furthest around the wheel from it
// (magenta/cyan/blue preferred), and a tertiary colour covers a third
// category where one is needed. Warn/danger are the theme's yellow/red.
function pickPalette(theme, accent, foreground, background, urgent) {
  var t = theme || {}
  var accentHue = hueOf(accent)
  var bgLight = Qt.color(background).hslLightness
  var names = ["blue", "magenta", "cyan", "green", "yellow", "orange", "red"]
  var candidates = []
  for (var i = 0; i < names.length; i++) {
    var c = t[names[i]]
    if (!c) continue
    var q = Qt.color(c)
    if (q.hslSaturation < 0.2 || Math.abs(q.hslLightness - bgLight) < 0.25) continue
    candidates.push({ name: names[i], color: c, hue: hueOf(c), dist: hueDistance(accentHue, hueOf(c)) })
  }
  candidates.sort(function(a, b) { return b.dist - a.dist })

  var second = null
  for (var j = 0; j < candidates.length; j++) {
    var cand = candidates[j]
    if ((cand.name === "magenta" || cand.name === "cyan" || cand.name === "blue") && cand.dist >= 50) { second = cand; break }
  }
  if (!second && candidates.length > 0 && candidates[0].dist >= 30) second = candidates[0]
  var series2 = second ? second.color : shiftHue(accent, 180)
  var series2Hue = hueOf(series2)

  var tertiary = null
  for (var k = 0; k < candidates.length; k++) {
    var alt = candidates[k]
    if (alt === second) continue
    if (alt.dist >= 35 && hueDistance(alt.hue, series2Hue) >= 35) { tertiary = alt.color; break }
  }
  if (!tertiary) tertiary = t.yellow || shiftHue(accent, 120)

  return {
    series1: accent,
    series2: series2,
    tertiary: tertiary,
    warn: t.yellow || t.orange || tertiary,
    danger: t.red || urgent,
    good: t.green || accent
  }
}
