const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { test } = require("node:test");

const model = vm.createContext({});
vm.runInContext(fs.readFileSync(path.join(__dirname, "../Model.js"), "utf8")
  .replace(/^\.pragma library\s*/, ""), model);
const plain = value => JSON.parse(JSON.stringify(value));
const legacyTabs = "cpu,memory,disks,network,sensors,battery";

test("saved 1.0 tabs retain GPU details on upgrade", () => {
  const tabs = model.settingValue({ tabs: legacyTabs }, "tabs");
  assert.equal(tabs, "cpu,gpu,memory,disks,network,sensors,battery");
  assert.ok(model.panelTabs(false, tabs, true).includes("gpu"));
  assert.equal(model.tabFor("gpu"), "gpu");
  assert.equal(model.pageFile("gpu"), "GpuPage.qml");
});

test("explicit new tab choices and previously hidden GPU details stay hidden", () => {
  for (const settings of [
    { tabs: legacyTabs, gpuTabVersion: 1 },
    { tabs: legacyTabs, showGpu: false },
    { tabs: legacyTabs, showGpu: "false" },
  ]) assert.equal(model.settingValue(settings, "tabs"), legacyTabs);
  assert.equal(model.settingValue({ tabs: "memory,network" }, "tabs"), "memory,network");
  assert.ok(!model.panelTabs(false, undefined, false).includes("gpu"));
});

test("GPU selection and histories stay tied to PCI addresses", () => {
  const gpus = [{ id: "0000:01:00.0", vendor: "nvidia", util: 24 },
    { id: "0000:10:00.0", vendor: "amd", util: 0 }];
  assert.deepEqual(plain(model.selectedGpus({ gpus }, "all")), gpus);
  assert.deepEqual(plain(model.selectedGpus({ gpus }, gpus[1].id)), [gpus[1]]);
  assert.deepEqual(plain(model.selectedGpus({ gpus }, "none")), []);
  const history = { gpus: { [gpus[0].id]: [10, 24], [gpus[1].id]: [0, 0] } };
  assert.deepEqual(plain(model.gpuHistory(history, gpus[0].id)), [10, 24]);
  assert.equal(model.gpuHasUtil({ util: null }), false);
  assert.equal(model.gpuHasUtil({ util: 0 }), true);
});

test("optional GPU memory readout uses reported VRAM and opens GPU details", () => {
  assert.equal(model.SETTINGS.showGpuMemory, false);
  assert.equal(model.tabFor("gpuMemory"), "gpu");
  assert.equal(model.moduleDef("gpuMemory").graph, true);
  assert.equal(model.moduleDef("gpuMemory").ring, true);
  assert.equal(model.moduleDef("gpuMemory").label, "VRAM");
  assert.equal(model.gpuMemoryPercent({ memUsed: 8, memTotal: 10 }), 80);
  for (const gpu of [null, {}, { memUsed: null, memTotal: 10 },
    { memUsed: 4, memTotal: 0 }, { memUsed: -1, memTotal: 10 }])
    assert.equal(model.gpuMemoryPercent(gpu), null);
  assert.deepEqual(plain(model.pushNullableHistory([80], null, 3)), [80, null]);
  assert.deepEqual(plain(model.gpuHistory({ gpu: [18, 19], gpus: { "0000:01:00.0": [40, 41] } }, "")), [18, 19]);
  const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, "../manifest.json"), "utf8"));
  assert.equal(manifest.barWidget.defaults.showGpuMemory, false);
  assert.ok(manifest.barWidget.schema.some(setting => setting.key === "showGpuMemory"));
});

test("GPU titles stay concise without erasing generic AMD identity", () => {
  assert.equal(model.gpuTitle({ vendor: "nvidia", name: "NVIDIA GeForce RTX 3090" }), "NVIDIA RTX 3090");
  assert.equal(model.gpuTitle({ vendor: "amd", name: "Radeon Graphics" }), "AMD Radeon Graphics");
  assert.equal(model.gpuTitle({ vendor: "amd", name: "AMD Radeon RX 7900 XTX" }), "AMD RX 7900 XTX");
  assert.equal(model.gpuTitle({ vendor: "intel", name: "Intel Corporation Arc A770" }), "Intel Arc A770");
});

test("utilization colors follow displayed percentages and preserve missing samples", () => {
  const enabled = { utilizationColors: true };
  for (const [value, grade] of [[24.49, 0], [24.5, 1], [59.49, 1],
    [59.5, 2], [83, 2], [84.49, 2], [84.5, 3], [100, 3]]) {
    assert.equal(model.utilizationGrade(value), grade);
  }
  for (const value of [null, undefined, NaN, Infinity, ""]) {
    assert.equal(model.utilizationGrade(value), -1);
  }
  assert.equal(model.SETTINGS.utilizationColors, false);
  assert.equal(model.utilizationColor({}, 85), null);
  assert.deepEqual(plain(model.utilizationHistoryColors([24, 85], {})), []);
  assert.deepEqual(plain(model.utilizationHistoryColors([24.4, 24.5, 59.5, 84.5, null], enabled)),
    ["#72ca9b", "#759cd1", "#da9c6c", "#d67471", null]);
  assert.deepEqual(plain(model.utilizationHistoryColors([24, 25, 60, 85], enabled, true)),
    ["#277944", "#3569aa", "#9c6019", "#af4444"]);
  assert.equal(model.utilizationColor({ ...enabled, utilizationCriticalColor: "#123abc" }, 85), "#123abc");
  assert.equal(model.utilizationColor({ ...enabled, utilizationCriticalColor: "#123abc" }, 85, true), "#123abc");
  assert.equal(model.utilizationColor({ ...enabled, utilizationLowColor: "red" }, 0), "#72ca9b");
  assert.equal(model.utilizationSettingColor({ utilizationLowColor: "" }, "utilizationLowColor", true), "#277944");
  assert.deepEqual(plain(model.pushNullableHistory([24], null, 3)), [24, null]);

  function luminance(hex) {
    const channels = [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16) / 255)
      .map(x => x <= 0.04045 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4);
    return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722;
  }
  function contrast(a, b) {
    const values = [luminance(a), luminance(b)].sort((x, y) => y - x);
    return (values[0] + 0.05) / (values[1] + 0.05);
  }
  for (const background of ["#eff1f5", "#fffcf0"])
    for (const color of plain(model.utilizationHistoryColors([0, 25, 60, 85], enabled, true)))
      assert.ok(contrast(color, background) >= 4.5, `${color} is too faint on ${background}`);

  const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, "../manifest.json"), "utf8"));
  for (const key of ["utilizationColors", "utilizationLowColor", "utilizationNormalColor",
    "utilizationWarningColor", "utilizationCriticalColor"]) {
    assert.equal(manifest.barWidget.defaults[key], model.SETTINGS[key]);
    assert.ok(manifest.barWidget.schema.some(setting => setting.key === key));
  }
});

test("disk readouts keep the 1.1 bar until barDisks is set", () => {
  assert.deepEqual(plain(model.barDisks({})), [{ disk: "all", show: "speed" }]);
  assert.deepEqual(plain(model.barDisks({ disksSource: "sda", disksStyle: "ring-text" })),
    [{ disk: "sda", show: "used" }]);
  assert.deepEqual(plain(model.barDisks({ style: "ring" })), [{ disk: "all", show: "used" }]);
  assert.deepEqual(plain(model.barDisks({ barDisks: "none" })), []);
  assert.deepEqual(plain(model.barDisks({ barDisks: "ALL:space, nvme0n1:both,sda,nvme0n1:used" })),
    [{ disk: "all", show: "used" }, { disk: "nvme0n1", show: "both" }, { disk: "sda", show: "speed" }]);
  assert.equal(model.barDisksText(model.barDisks({ barDisks: "all:speed,sda:both" })), "all:speed,sda:both");
  assert.equal(model.barDisksText([]), "none");
  assert.equal(model.diskLook("ring"), "graph");
  assert.equal(model.diskLook("ring-text"), "both");
  assert.deepEqual(["nvme1n1", "sda", "mmcblk0", "all"].map(model.diskShort), ["NV1", "SDA", "MC0", "DSK"]);
});

test("disk choices follow the drive, not the kernel name it booted with", () => {
  const kioxia = "nvme-KIOXIA-EXCERIA_G3_SSD_YFWKS0TJZ3TS";
  const samsung = "nvme-Samsung_SSD_970_EVO_Plus_1TB_S4EWNF0M921645X";
  const usb = "usb-Micron_CT2000X6SSD9_2305E4919FFA-0:0";
  const boot = { disks: { perDisk: { nvme0n1: { id: kioxia }, nvme1n1: { id: samsung }, sdd: { id: usb } } } };
  // The next boot probes the controllers the other way round.
  const swapped = { disks: { perDisk: { nvme0n1: { id: samsung }, nvme1n1: { id: kioxia }, sdd: { id: usb } } } };
  assert.equal(model.resolveDisk(boot, kioxia), "nvme0n1");
  assert.equal(model.resolveDisk(swapped, kioxia), "nvme1n1");
  assert.equal(model.resolveDisk(swapped, "all"), "all");
  assert.equal(model.resolveDisk(swapped, "nvme-unplugged"), "");
  assert.equal(model.resolveDisk(swapped, "nvme0n1"), "nvme0n1");
  assert.deepEqual(plain(model.diskOptions(boot)).map(option => option.value), ["all", kioxia, samsung, usb]);
  assert.deepEqual(plain(model.barDisks({ barDisks: `${usb}:both,${kioxia}` })),
    [{ disk: usb, show: "both" }, { disk: kioxia, show: "speed" }]);
  assert.deepEqual(plain(model.barDisks({ barDisks: usb })), [{ disk: usb, show: "speed" }]);
});

test("disks and sensors saved by kernel or driver name move to their ids once", () => {
  const kioxia = "nvme-KIOXIA-EXCERIA_G3_SSD_YFWKS0TJZ3TS";
  const snapshot = {
    disks: { perDisk: { nvme0n1: { id: kioxia }, sda: { id: "ata-Samsung_SSD_860" } } },
    sensors: { temps: [{ id: "nvme@0000:10:00.0/temp1" }, { id: "nvme@0000:02:00.0/temp1" }, { id: "k10temp/temp1" }],
      fans: [{ id: "nct6687/fan1" }] },
  };
  const legacy = { barDisks: "nvme0n1:used,all:speed,sdz:both", disksSource: "sda",
    barSensors: "cpu,nvme/temp1,k10temp/temp1,nct6687/fan1" };
  assert.deepEqual(plain(model.stableSettings(legacy, snapshot)), {
    barDisks: `${kioxia}:used,all:speed,sdz:both`,
    disksSource: "ata-Samsung_SSD_860",
    barSensors: "cpu,nvme@0000:10:00.0/temp1,k10temp/temp1,nct6687/fan1",
  });
  const stable = plain(model.withStableSettings(legacy, snapshot));
  assert.equal(model.stableSettings(stable, snapshot), null);
  // Defaults, and a sampler that reports no ids yet, leave settings alone.
  assert.equal(model.stableSettings({}, snapshot), null);
  assert.equal(model.stableSettings(legacy, { disks: { perDisk: { nvme0n1: {}, sda: {} } } }), null);
  assert.equal(model.stableSettings(legacy, {}), null);
});

test("disk space used sums a device's volumes and skips network mounts", () => {
  const snapshot = { disks: {
    perDisk: { nvme0n1: {}, sda: {} },
    volumes: [
      { disk: "nvme0n1", used: 30, size: 100 },
      { disk: "nvme0n1", used: 10, size: 100 },
      { disk: "sda", used: 50, size: 200 },
      { disk: "nas", used: 900, size: 1000 },
    ],
  } };
  assert.equal(model.diskUsage(snapshot, "nvme0n1").fraction, 0.2);
  assert.deepEqual(plain(model.diskUsage(snapshot, "all")), { used: 90, size: 400, fraction: 0.225 });
  assert.equal(model.diskUsage(snapshot, "sdb").fraction, 0);
  assert.equal(model.diskUsage({ disks: { perDisk: {}, volumes: [{ disk: "nas", mount: "/mnt/nas", used: 1, size: 4 }] } }, "all").fraction, 0);
  assert.equal(model.diskUsage({ disks: { perDisk: {}, volumes: [
    { disk: "nas", mount: "/mnt/nas", used: 1, size: 4 },
    { disk: "dm-0", mount: "/", used: 3, size: 4 },
  ] } }, "all").fraction, 0.75);
});

test("a ZFS pool counts towards all disks even when its drive is unknown", () => {
  const snapshot = { disks: { perDisk: { nvme0n1: {} }, volumes: [
    { disk: "", fstype: "zfs", mount: "/", used: 80, size: 100 },
    { disk: "nvme0n1", fstype: "vfat", mount: "/boot", used: 0, size: 100 },
  ] } };
  assert.deepEqual(plain(model.diskUsage(snapshot, "all")), { used: 80, size: 200, fraction: 0.4 });
});

test("saved bar settings identify only the selected instance", () => {
  const id = "crmne.omastats";
  const entry = { id, barDisks: "nvme1n1:used", disksSource: "nvme0n1" };
  const config = { layout: { right: [{ id: "omarchy.clock" }, entry] } };
  assert.deepEqual(plain(model.savedBarSettings(config, id, null)),
    { barDisks: "nvme1n1:used", disksSource: "nvme0n1" });
  assert.equal(model.savedBarSettings(null, id, null), null);
  assert.equal(model.savedBarSettings(config, "missing", null), null);
  assert.equal(model.savedBarSettings(config, id, { section: "right", index: 0 }), null);
  config.layout.left = [{ id, barDisks: "sda:speed" }];
  assert.equal(model.savedBarSettings(config, id, null), null);
  assert.deepEqual(plain(model.savedBarSettings(config, id, { section: "right", index: 1 })),
    { barDisks: "nvme1n1:used", disksSource: "nvme0n1" });
});

// Execute the widget's own persistence functions with a host that can reapply
// an old slot snapshot, as the shell does after inline settings changes.
function persistenceHost(savedEntry, slotSettings, withConfig = true) {
  let entry = plain(savedEntry);
  const widget = vm.createContext({
    Model: model,
    moduleName: "crmne.omastats",
    settings: plain(slotSettings),
    pendingSettings: {},
    locateSelf: () => null,
    bar: { shell: { updateEntryInline: (id, next) => { entry = plain(next); } } },
  });
  Object.defineProperty(widget, "savedSettings", { get: () => withConfig
    ? model.savedBarSettings({ layout: { right: [entry] } }, widget.moduleName, null) : null });
  const source = fs.readFileSync(path.join(__dirname, "../OmaStatsWidget.qml"), "utf8");
  for (const name of ["persist", "restoreSavedSettings", "adoptStableSettings"]) {
    const code = source.match(new RegExp(`^  function ${name}\\([\\s\\S]*?^  }`, "m"));
    assert.ok(code, `widget function ${name} is missing`);
    vm.runInContext(code[0], widget);
  }
  return { widget, savedEntry: () => entry };
}

test("an unrelated edit cannot save a stale disk selection over the current choice", () => {
  const saved = { id: "crmne.omastats", barDisks: "nvme1n1:used",
    disksSource: "nvme0n1", graphWidth: 36, disksStyle: "text" };
  const stale = { ...saved, barDisks: "nvme0n1:speed" };
  const { widget, savedEntry } = persistenceHost(saved, stale);
  widget.persist("graphWidth", 48);
  assert.equal(savedEntry().barDisks, "nvme1n1:used");
  assert.equal(savedEntry().graphWidth, 48);
  assert.equal(savedEntry().disksStyle, "text");
  // Loading the serialized entry again keeps Used on NVMe 1, independently
  // of the Disks panel's NVMe 0 activity source.
  assert.deepEqual(plain(model.barDisks(plain(savedEntry()))), [{ disk: "nvme1n1", show: "used" }]);
});

test("a re-injected slot snapshot restores the saved disk before further edits", () => {
  const initial = { id: "crmne.omastats", barDisks: "nvme0n1:speed", graphWidth: 36 };
  const { widget, savedEntry } = persistenceHost(initial, initial);
  widget.persist("barDisks", "nvme1n1:used");
  widget.settings = plain(initial);
  widget.restoreSavedSettings();
  assert.deepEqual(plain(model.barDisks(widget.settings)), [{ disk: "nvme1n1", show: "used" }]);
  widget.persist("disksStyle", "text");
  assert.equal(savedEntry().barDisks, "nvme1n1:used");
  assert.equal(savedEntry().disksStyle, "text");
});

test("shells without a saved bar config still persist inline settings", () => {
  const initial = { id: "crmne.omastats", barDisks: "nvme1n1:used", graphWidth: 36 };
  const { widget, savedEntry } = persistenceHost(initial, initial, false);
  widget.persist("graphWidth", 48);
  widget.restoreSavedSettings();
  assert.equal(savedEntry().barDisks, "nvme1n1:used");
  assert.equal(widget.settings.graphWidth, 48);
});

test("the widget saves a legacy disk choice under the drive's id", () => {
  const kioxia = "nvme-KIOXIA-EXCERIA_G3_SSD_YFWKS0TJZ3TS";
  const initial = { id: "crmne.omastats", barDisks: "nvme0n1:used", disksSource: "all", graphWidth: 36 };
  const { widget, savedEntry } = persistenceHost(initial, initial);
  widget.service = { snapshot: { disks: { perDisk: { nvme0n1: { id: kioxia } } } } };
  widget.adoptStableSettings();
  assert.equal(savedEntry().barDisks, `${kioxia}:used`);
  assert.equal(savedEntry().disksSource, "all");
  assert.equal(savedEntry().graphWidth, 36);
});

test("settings written but not yet in shell.json stay saved until the file shows them", () => {
  const bar = model.parseShellBar(JSON.stringify({ version: 1, bar: { layout: { right: [
    { id: "crmne.omastats", barDisks: "all:speed", graphWidth: 36 }] } } }));
  assert.equal(model.parseShellBar("{ half-written"), null);
  const saved = model.savedBarSettings(bar, "crmne.omastats", null);
  const pending = { barDisks: { value: "sda:used", at: 1000 } };
  assert.deepEqual(plain(model.withPending(saved, pending)), { barDisks: "sda:used", graphWidth: 36 });
  assert.equal(model.withPending(null, pending), null);
  // Still waiting, then landed, then given up on after ten seconds.
  assert.deepEqual(plain(model.prunePending(saved, pending, 2000)), pending);
  assert.deepEqual(plain(model.prunePending({ ...saved, barDisks: "sda:used" }, pending, 2000)), {});
  assert.deepEqual(plain(model.prunePending(saved, pending, 12000)), {});
});

test("no text control can read the clipboard, focused or not", () => {
  // Every editable TextInput, TextField, TextEdit or TextArea asks the
  // clipboard for its contents whenever another application changes it,
  // focused or not. Fields are KeyFields, which only take key events.
  const files = [".", "ui"].flatMap(dir => fs.readdirSync(path.join(__dirname, "..", dir))
    .filter(name => name.endsWith(".qml")).map(name => path.join(__dirname, "..", dir, name)));
  let keyFields = 0;
  for (const file of files) {
    const code = fs.readFileSync(file, "utf8").replace(/\/\/.*$/gm, "");
    assert.doesNotMatch(code, /\b(TextField|TextInput|TextEdit|TextArea)\s*\{/, `${path.basename(file)} uses a Qt text input`);
    assert.doesNotMatch(code, /clipboard|Clipboard/i, `${path.basename(file)} touches the clipboard`);
    keyFields += (code.match(/\bKeyField\s*\{/g) || []).length;
  }
  assert.ok(keyFields >= 2, "the process search and color fields are KeyFields");
});

test("copied addresses never go on a command line", () => {
  // wl-copy stays running to serve what it copies, and a process's arguments
  // are readable by every local user in /proc/<pid>/cmdline, so the text goes
  // on its standard input.
  const files = [".", "ui"].flatMap(dir => fs.readdirSync(path.join(__dirname, "..", dir))
    .filter(name => name.endsWith(".qml")).map(name => path.join(__dirname, "..", dir, name)));
  for (const file of files) {
    const code = fs.readFileSync(file, "utf8").replace(/\/\/.*$/gm, "");
    assert.doesNotMatch(code, /execDetached/, `${path.basename(file)} starts a process with arguments only`);
    assert.doesNotMatch(code, /"\/usr\/bin\/wl-copy"\s*,/, `${path.basename(file)} passes wl-copy an argument`);
  }
  const network = fs.readFileSync(path.join(__dirname, "..", "ui", "NetworkPage.qml"), "utf8");
  assert.match(network, /command: \["\/usr\/bin\/wl-copy"\]/);
  assert.match(network, /write\(text\)/);
});

test("power readings read as watts", () => {
  assert.equal(model.wattsText(167.04), "167 W");
  assert.equal(model.wattsText(4.26), "4.3 W");
  assert.equal(model.wattsText(null), "");
  assert.equal(model.wattsText(undefined), "");
  assert.equal(model.wattsText("n/a"), "");
});

test("bar label mode keeps inline and falls back to stacked letters", () => {
  assert.equal(model.barLabelMode("text"), "text");
  assert.equal(model.barLabelMode("inline"), "inline");
  assert.equal(model.barLabelMode("INLINE"), "inline");
  assert.equal(model.barLabelMode("icon"), "icon");
  assert.equal(model.barLabelMode("Icons"), "text");
  assert.equal(model.barLabelMode("nonsense"), "text");
  assert.equal(model.barLabelMode(""), "text");
  assert.equal(model.barLabelMode(undefined), "text");
  assert.equal(model.barLabelMode(null), "text");
});
