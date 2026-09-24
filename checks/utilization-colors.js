import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../Model.js", import.meta.url), "utf8")
  .replace(/^\.pragma library\s*/, "")
const api = new Function(source + "\nreturn { SETTINGS, gpuHistory, utilizationGrade, utilizationColor, utilizationHistoryColors, validHexColor, pushNullableHistory }")()
const defaults = api.SETTINGS

for (const [value, grade] of [[0, 0], [24.9, 0], [25, 1], [59.9, 1], [60, 2], [83, 2], [84.9, 2], [85, 3], [100, 3]]) {
  assert.equal(api.utilizationGrade(value), grade)
}
for (const value of [null, undefined, NaN, Infinity, ""]) assert.equal(api.utilizationGrade(value), -1)

assert.equal(defaults.utilizationColors, false)
assert.equal(api.utilizationColor({}, 100), null)
assert.deepEqual(api.utilizationHistoryColors([0, 25, 60, 85], {}), [null, null, null, null])
const enabled = { utilizationColors: true }
assert.deepEqual(api.utilizationHistoryColors([24, 25, 60, 85, null], enabled), [
  "#72ca9b", "#759cd1", "#da9c6c", "#d67471", null
])
assert.equal(api.utilizationColor({ ...enabled, utilizationCriticalColor: "#123abc" }, 85), "#123abc")
assert.equal(api.utilizationColor({ ...enabled, utilizationLowColor: "red" }, 0), "#72ca9b")
assert.equal(api.validHexColor("#123aBc"), true)
assert.equal(api.validHexColor("#123ab"), false)

const gpuA = "0000:01:00.0"
const gpuB = "0000:10:00.0"
const histories = { gpus: { [gpuA]: [24, null], [gpuB]: [85, 60] } }
assert.deepEqual(api.gpuHistory(histories, gpuA), [24, null])
assert.deepEqual(api.utilizationHistoryColors(api.gpuHistory(histories, gpuB), enabled), ["#d67471", "#da9c6c"])
assert.deepEqual(api.pushNullableHistory([24], null, 3), [24, null])

const manifest = JSON.parse(readFileSync(new URL("../manifest.json", import.meta.url), "utf8"))
assert.equal(manifest.barWidget.defaults.utilizationColors, false)
assert.equal(manifest.barWidget.defaults.utilizationLowColor, defaults.utilizationLowColor)
for (const key of ["utilizationColors", "utilizationLowColor", "utilizationNormalColor", "utilizationWarningColor", "utilizationCriticalColor"]) {
  assert.ok(manifest.barWidget.schema.some(setting => setting.key === key), `manifest schema missing ${key}`)
}
