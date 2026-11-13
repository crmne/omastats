const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { test } = require("node:test");

// Exercise the actual Canvas paint handler, recording its rectangles.
function paint(name, width, length, dpr = 1) {
  const source = fs.readFileSync(path.join(__dirname, `../ui/${name}.qml`), "utf8");
  const rectangles = [];
  const ctx = { clearRect() {}, fillRect(x, y, w, h) { rectangles.push({ x, y, w, h, color: this.fillStyle }); } };
  const samples = Array.from({ length }, () => 50);
  const root = { series: [samples], colors: ["green"], sampleColors: [],
    up: samples, down: samples, upColor: "green", downColor: "orange",
    barWidth: 2, gap: 1, ceiling: 100, floor: 1, headroom: 1.06,
    showBaseline: false, peakUp: 50, peakDown: 50, midlineColor: "gray" };
  const context = vm.createContext({ root, width, height: 100,
    Screen: { devicePixelRatio: dpr }, Commons: { Color: { accent: "green" } },
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
        test(`${name} fills ${width}px with ${length} samples at ${dpr}x`, () => {
          const bars = paint(name, width, length, dpr);
          assert.ok(bars.length > 0);
          assert.equal(bars[0].x, 0);
          const last = bars.at(-1);
          assert.ok(Math.abs(last.x + last.w - width) <= 1 / dpr);
          assert.ok(bars.every(bar => bar.x >= 0 && bar.w > 0 && bar.x + bar.w <= width + 1 / dpr));
        });
      }
    }
  }
  test(`${name} tolerates empty history`, () => {
    assert.deepEqual(paint(name, 700, 0), []);
  });
}
