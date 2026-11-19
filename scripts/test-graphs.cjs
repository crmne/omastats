const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { test } = require("node:test");

// Exercise the actual Canvas paint handler, recording its rectangles.
function paint(name, width, length, dpr = 1, historyLength = 240, barWidth = 2) {
  const source = fs.readFileSync(path.join(__dirname, `../ui/${name}.qml`), "utf8");
  const rectangles = [];
  const ctx = { clearRect() {}, fillRect(x, y, w, h) { rectangles.push({ x, y, w, h, color: this.fillStyle }); } };
  const samples = Array.from({ length }, () => 50);
  const root = { series: [samples], colors: ["green"], sampleColors: [],
    up: samples, down: samples, upColor: "green", downColor: "orange",
    barWidth, gap: 1, historyLength, deviceScale: dpr, ceiling: 100, floor: 1, headroom: 1.06,
    showBaseline: false, peakUp: 50, peakDown: 50, midlineColor: "gray" };
  const context = vm.createContext({ root, width, height: 100,
    Commons: { Color: { accent: "green" } },
    getContext: () => ctx });
  for (const key of ["pitch", "capacity"]) {
    const expression = source.match(new RegExp(`readonly property int ${key}: (.+)`))[1];
    root[key] = vm.runInContext(expression, vm.createContext({ ...root, width }));
  }
  const body = source.slice(source.indexOf("onPaint: {") + "onPaint: {".length, source.lastIndexOf("}"));
  vm.runInContext(`(function () { ${body} )()`, context);
  return rectangles.filter(rect => rect.color === "green");
}

for (const name of ["HistoryGraph", "MirrorGraph"]) {
  for (const width of [36, 450, 700, 1120]) {
    for (const length of [1, 150, 240, 3600]) {
      for (const dpr of [1, 1.25, 2]) {
        test(`${name} draws within ${width}px with ${length} samples at ${dpr}x`, () => {
          const bars = paint(name, width, length, dpr);
          assert.ok(bars.length > 0);
          assert.ok(bars[0].x >= 0);
          const last = bars.at(-1);
          assert.ok(last.x + last.w <= width + 1 / dpr);
          if (length === 1 && width > 10) assert.ok(last.w < width / 4);
          assert.ok(bars.every(bar => bar.x >= 0 && bar.w > 0 && bar.x + bar.w <= width + 1 / dpr));
        });
      }
    }
  }
  test(`${name} tolerates empty history`, () => {
    assert.deepEqual(paint(name, 700, 0), []);
  });
}

for (const name of ["HistoryGraph", "MirrorGraph"]) {
  test(`${name} preserves narrow graph pitch`, () => {
    const bars = paint(name, 36, 240, 1.25, 240, 1);
    assert.equal(bars.length, 18);
    assert.ok(bars.every(bar => bar.w === 0.8));
    assert.ok(bars.every((bar, i) => bar.x === Math.round((1 + i * 2) * 1.25) / 1.25));
  });
  test(`${name} expands full short history and right-aligns startup`, () => {
    const full = paint(name, 800, 240, 1, 240);
    const first = paint(name, 800, 1, 1, 240);
    assert.ok(full[0].x <= 1);
    assert.equal(first[0].x, full.at(-1).x);
    assert.ok(first[0].w < 4);
  });
}
