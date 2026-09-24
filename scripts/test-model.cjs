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
