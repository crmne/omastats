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

test("GPU titles stay concise without erasing generic AMD identity", () => {
  assert.equal(model.gpuTitle({ vendor: "nvidia", name: "NVIDIA GeForce RTX 3090" }), "NVIDIA RTX 3090");
  assert.equal(model.gpuTitle({ vendor: "amd", name: "Radeon Graphics" }), "AMD Radeon Graphics");
  assert.equal(model.gpuTitle({ vendor: "amd", name: "AMD Radeon RX 7900 XTX" }), "AMD RX 7900 XTX");
  assert.equal(model.gpuTitle({ vendor: "intel", name: "Intel Corporation Arc A770" }), "Intel Arc A770");
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
  assert.equal(model.diskUsage({ disks: { perDisk: {}, volumes: [{ disk: "nas", used: 1, size: 4 }] } }, "all").fraction, 0.25);
});
