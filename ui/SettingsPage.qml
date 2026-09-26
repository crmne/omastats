import QtQuick
import qs.Commons
import qs.Ui
import "../Model.js" as Model

// In-panel configuration, iStat Menus style: what the bar shows and how,
// which sections each page shows, and the general knobs. Every change is
// written straight to this widget's entry in shell.json through the host.
Column {
  id: root

  property var service: null
  property var host: null
  property var settings: ({})
  property int focusedColorEditors: 0
  property string temperatureUnit: "Celsius"
  property bool publicIpEnabled: true
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.family
  readonly property bool lightTheme: host && host.bar && !host.bar.transparent && host.bar.background.a >= 0.95
    ? host.bar.background.hslLightness > 0.5 : (host && host.bar ? host.bar.barForeground : Color.bar.text).hslLightness < 0.5

  readonly property bool hasGpu: !!(service && service.hasGpu)
  readonly property bool hasBattery: !!(service && service.hasBattery)
  readonly property var barModules: Model.parseModules(Model.settingValue(settings, "modules"))
  readonly property var tabModules: Model.parseModules(Model.settingValue(settings, "tabs"))
  readonly property var availableModules: {
    var out = []
    for (var i = 0; i < Model.MODULES.length; i++) {
      var id = Model.MODULES[i].id
      if (id === "settings") continue
      if (id === "gpu" && !hasGpu) continue
      if (id === "battery" && !hasBattery) continue
      if (id === "gpu" && !hasGpu) continue
      out.push(id)
    }
    return out
  }
  // Enabled readouts first, in bar order, then the rest in canonical order.
  readonly property var orderedModules: {
    var out = []
    for (var i = 0; i < barModules.length; i++) if (availableModules.indexOf(barModules[i]) !== -1) out.push(barModules[i])
    for (var j = 0; j < availableModules.length; j++) if (out.indexOf(availableModules[j]) === -1) out.push(availableModules[j])
    return out
  }
  readonly property var pages: {
    var out = []
    for (var i = 0; i < Model.PANEL_TABS.length; i++) {
      var id = Model.PANEL_TABS[i]
      if (id === "battery" && !hasBattery) continue
      if (id === "gpu" && !hasGpu) continue
      out.push(id)
    }
    return out
  }
  readonly property var snapshot: service ? service.snapshot : ({})
  readonly property var diskOptions: Model.diskOptions(snapshot)
  readonly property var sensorOptions: Model.sensorOptions(snapshot)
  readonly property var barDiskList: Model.barDisks(settings)
  readonly property var barSensorIds: Model.parseList(Model.settingValue(settings, "barSensors"))
  readonly property var gpuOptions: Model.gpuList(snapshot)
  // "all" keeps a GPU added later visible without another visit here.
  readonly property var selectedGpuIds: {
    var text = String(Model.settingValue(settings, "barGpus") || "all").trim().toLowerCase()
    if (text === "none") return []
    if (!text || text === "all") {
      var every = []
      for (var i = 0; i < gpuOptions.length; i++) every.push(Model.gpuId(gpuOptions[i]))
      return every
    }
    return Model.parseList(text)
  }

  // Position in the sampler's order (boot display first), so the bar keeps a
  // stable left-to-right order however the switches are flipped.
  function gpuOrder(id) {
    for (var i = 0; i < gpuOptions.length; i++) if (Model.gpuId(gpuOptions[i]) === id) return i
    return gpuOptions.length
  }

  function setBarGpu(id, enabled) {
    var list = selectedGpuIds.filter(function(id) { return root.gpuOrder(id) < root.gpuOptions.length })
    var at = list.indexOf(id)
    if (enabled && at === -1) {
      list.push(id)
      list.sort(function(a, b) { return root.gpuOrder(a) - root.gpuOrder(b) })
    }
    if (!enabled && at !== -1) list.splice(at, 1)
    if (list.length === 0) set("barGpus", "none")
    else set("barGpus", list.length === gpuOptions.length ? "all" : list.join(","))
  }

  function diskIndex(list, disk) {
    for (var i = 0; i < list.length; i++) if (list[i].disk === disk) return i
    return -1
  }

  function diskShowFor(disk) {
    var at = diskIndex(barDiskList, disk)
    return at === -1 ? "speed" : barDiskList[at].show
  }

  // Add, drop, or retarget one disk readout, kept in the Source list order
  // ("All disks" first) so the bar stays stable however the switches flip.
  function setBarDisk(disk, enabled, show) {
    var list = barDiskList.map(function(entry) { return { disk: entry.disk, show: entry.show } })
    var at = diskIndex(list, disk)
    if (enabled && at === -1) list.push({ disk: disk, show: show || "speed" })
    else if (enabled && show) list[at].show = show
    if (!enabled && at !== -1) list.splice(at, 1)
    var order = diskOptions.map(function(option) { return option.value })
    list.sort(function(a, b) {
      var ia = order.indexOf(a.disk), ib = order.indexOf(b.disk)
      return (ia === -1 ? order.length : ia) - (ib === -1 ? order.length : ib)
    })
    set("barDisks", Model.barDisksText(list))
  }

  // Until barDisks is saved, the bar's disk readout is inferred from the
  // disk look and the Disks page source. Pin it before changing either.
  function pinBarDisks() {
    if (!String(Model.settingValue(settings, "barDisks") || "").trim()) set("barDisks", Model.barDisksText(barDiskList))
  }

  function setDiskLook(value) {
    pinBarDisks()
    set("disksStyle", value)
  }

  function setBarSensor(id, enabled) {
    var list = barSensorIds.slice()
    var at = list.indexOf(id)
    if (enabled && at === -1) list.push(id)
    if (!enabled && at !== -1) list.splice(at, 1)
    set("barSensors", list.join(","))
  }

  function set(key, value) {
    if (host && typeof host.persist === "function") host.persist(key, value)
  }

  function num(key) { return Number(Model.settingValue(settings, key)) }

  function setModuleEnabled(id, enabled) {
    var list = barModules.slice()
    var at = list.indexOf(id)
    if (enabled && at === -1) list.push(id)
    if (!enabled && at !== -1) list.splice(at, 1)
    set("modules", list.join(","))
  }

  function setTabEnabled(id, enabled) {
    var list = tabModules.slice()
    var at = list.indexOf(id)
    if (enabled && at === -1) {
      list.push(id)
      // Keep canonical order so the strip never reshuffles.
      list.sort(function(a, b) { return Model.PANEL_TABS.indexOf(a) - Model.PANEL_TABS.indexOf(b) })
    }
    if (!enabled && at !== -1) list.splice(at, 1)
    set("gpuTabVersion", 1)
    set("tabs", list.join(","))
  }

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(10)

  // ------------------------------------------------------------------ bar
  Card {
    foreground: root.foreground
    spacing: Style.space(6)

    SectionTitle { text: "Bar"; fontFamily: root.fontFamily }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: "Readouts shown in the bar, in this order. Each can show a mini graph, a figure, or both."
      color: root.foreground
      opacity: 0.55
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Repeater {
      model: root.orderedModules.length

      delegate: Column {
        id: moduleRow
        required property int index
        readonly property string moduleId: String(root.orderedModules[index] || "")
        readonly property var def: Model.moduleDef(moduleId)
        readonly property int position: root.barModules.indexOf(moduleId)
        readonly property bool enabled: position !== -1

        width: parent.width
        spacing: Style.space(4)
        topPadding: Style.space(4)

        Item {
          width: parent.width
          height: Style.space(26)

          ToggleSwitch {
            id: moduleSwitch
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            checked: moduleRow.enabled
            trackHeight: Style.space(18)
            foreground: root.foreground
            onToggled: root.setModuleEnabled(moduleRow.moduleId, !moduleRow.enabled)
          }

          Text {
            textFormat: Text.PlainText
            anchors.left: moduleSwitch.right
            anchors.leftMargin: Style.space(12)
            anchors.right: reorder.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: moduleRow.def.label
            color: root.foreground
            opacity: moduleRow.enabled ? 1 : 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: moduleRow.enabled
            elide: Text.ElideRight
          }

          Row {
            id: reorder
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)
            visible: moduleRow.enabled

            PanelActionButton {
              iconText: "󰁝"
              tooltipText: "Move left in the bar"
              enabled: moduleRow.position > 0
              foreground: root.foreground
              fontFamily: root.fontFamily
              size: Style.space(22)
              onClicked: root.set("modules", Model.moveInList(root.barModules, moduleRow.moduleId, -1).join(","))
            }

            PanelActionButton {
              iconText: "󰁅"
              tooltipText: "Move right in the bar"
              enabled: moduleRow.position < root.barModules.length - 1
              foreground: root.foreground
              fontFamily: root.fontFamily
              size: Style.space(22)
              onClicked: root.set("modules", Model.moveInList(root.barModules, moduleRow.moduleId, 1).join(","))
            }
          }
        }

        Dropdown {
          visible: moduleRow.enabled && (moduleRow.def.graph === true || moduleRow.def.ring === true)
          x: Style.space(12) + moduleSwitch.width + Style.space(12)
          width: parent.width - x
          label: "Look"
          options: Model.styleOptions(moduleRow.moduleId)
          value: moduleRow.moduleId === "disks"
            ? Model.diskLook(Model.moduleStyle(root.settings, "disks"))
            : Model.moduleStyle(root.settings, moduleRow.moduleId)
          foreground: root.foreground
          fontFamily: root.fontFamily
          onChanged: function(value) {
            if (moduleRow.moduleId === "disks") root.setDiskLook(value)
            else root.set(moduleRow.moduleId + "Style", value)
          }
        }

        FlagRow {
          visible: moduleRow.enabled && moduleRow.moduleId === "gpu" && root.gpuOptions.some(function(gpu) { return Model.gpuMemoryPercent(gpu) !== null })
          label: "Show VRAM in bar"
          indent: Style.space(12) + moduleSwitch.width + Style.space(12)
          checked: Model.flag(root.settings, "showGpuMemory")
          onToggled: root.set("showGpuMemory", !checked)
        }

        // Disks: a readout per device picked here, each showing transfer
        // speed, space used, or both.
        Column {
          visible: moduleRow.enabled && moduleRow.moduleId === "disks"
          x: Style.space(12) + moduleSwitch.width + Style.space(12)
          width: parent.width - x
          spacing: 0

          Repeater {
            model: moduleRow.moduleId === "disks" ? root.diskOptions.length : 0

            delegate: Column {
              id: diskRow
              required property int index
              readonly property var option: root.diskOptions[index] || ({})
              readonly property string disk: String(option.value || "")
              readonly property bool picked: root.diskIndex(root.barDiskList, disk) !== -1
              width: parent.width
              spacing: 0

              FlagRow {
                label: String(diskRow.option.label || "")
                checked: diskRow.picked
                onToggled: root.setBarDisk(diskRow.disk, !checked, "")
              }

              ChoiceRow {
                visible: diskRow.picked
                indent: Style.space(14)
                label: "Show"
                options: Model.DISK_SHOWS
                value: root.diskShowFor(diskRow.disk)
                onChanged: function(value) { root.setBarDisk(diskRow.disk, true, value) }
              }
            }
          }
        }

        // GPUs: which cards get their own readout. Only worth showing on a
        // machine that has more than one.
        Column {
          visible: moduleRow.enabled && moduleRow.moduleId === "gpu" && root.gpuOptions.length > 1
          x: Style.space(12) + moduleSwitch.width + Style.space(12)
          width: parent.width - x
          spacing: 0

          Repeater {
            model: moduleRow.moduleId === "gpu" ? root.gpuOptions.length : 0

            delegate: FlagRow {
              required property int index
              readonly property var gpu: root.gpuOptions[index] || ({})
              label: Model.gpuTitle(gpu) + (Model.gpuHasUtil(gpu) ? "" : " · no load")
              checked: root.selectedGpuIds.indexOf(Model.gpuId(gpu)) !== -1
              onToggled: root.setBarGpu(Model.gpuId(gpu), !checked)
            }
          }
        }

        // Sensors: every reading the bar readout should carry.
        Column {
          visible: moduleRow.enabled && moduleRow.moduleId === "sensors"
          x: Style.space(12) + moduleSwitch.width + Style.space(12)
          width: parent.width - x
          spacing: 0

          Repeater {
            model: moduleRow.moduleId === "sensors" ? root.sensorOptions.length : 0

            delegate: FlagRow {
              required property int index
              readonly property var option: root.sensorOptions[index] || ({})
              label: String(option.label || "")
              checked: root.barSensorIds.indexOf(String(option.value)) !== -1
              onToggled: root.setBarSensor(String(option.value), !checked)
            }
          }
        }
      }
    }
  }

  // ---------------------------------------------------------------- panel
  Card {
    foreground: root.foreground
    spacing: Style.space(6)

    SectionTitle { text: "Panel"; fontFamily: root.fontFamily }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: "Tabs shown in the panel and the sections on each page."
      color: root.foreground
      opacity: 0.55
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Repeater {
      model: root.pages.length

      delegate: Column {
        id: pageRow
        required property int index
        readonly property string pageId: String(root.pages[index] || "")
        readonly property var def: Model.moduleDef(pageId)
        readonly property bool enabled: root.tabModules.indexOf(pageId) !== -1
        readonly property var sections: Model.PANEL_SECTIONS[pageId] || []
        readonly property var choices: Model.PANEL_CHOICES[pageId] || []

        width: parent.width
        spacing: 0
        topPadding: Style.space(4)

        FlagRow {
          label: pageRow.def.label
          bold: true
          checked: pageRow.enabled
          onToggled: root.setTabEnabled(pageRow.pageId, !pageRow.enabled)
        }

        Repeater {
          model: pageRow.enabled ? pageRow.sections.length : 0

          delegate: FlagRow {
            required property int index
            readonly property var section: pageRow.sections[index] || ({})
            indent: Style.space(26)
            label: String(section.label || "")
            checked: Model.flag(root.settings, String(section.key || ""))
            onToggled: root.set(String(section.key || ""), !checked)
          }
        }

        // Disks page: which device the activity graph follows.
        Dropdown {
          visible: pageRow.enabled && pageRow.pageId === "disks"
          x: Style.space(26)
          width: parent.width - x
          label: "Activity"
          options: root.diskOptions
          value: String(Model.settingValue(root.settings, "disksSource") || "all")
          foreground: root.foreground
          fontFamily: root.fontFamily
          onChanged: function(value) {
            root.pinBarDisks()
            root.set("disksSource", value)
          }
        }

        Repeater {
          model: pageRow.enabled ? pageRow.choices.length : 0

          delegate: ChoiceRow {
            required property int index
            readonly property var choice: pageRow.choices[index] || ({})
            indent: Style.space(26)
            label: String(choice.label || "")
            options: choice.options || []
            value: String(Model.settingValue(root.settings, String(choice.key || "")))
            onChanged: function(value) { root.set(String(choice.key || ""), value) }
          }
        }
      }
    }

    PanelSeparator { foreground: root.foreground }

    FlagRow {
      label: "Top processes on every page"
      checked: Model.flag(root.settings, "showProcesses")
      onToggled: root.set("showProcesses", !checked)
    }
  }

  // -------------------------------------------------------------- general
  Card {
    foreground: root.foreground
    spacing: Style.space(6)

    SectionTitle { text: "General"; fontFamily: root.fontFamily }

    ChoiceRow {
      label: "Bar labels"
      options: [{ value: "text", label: "Letters" }, { value: "icon", label: "Icons" }]
      value: String(Model.settingValue(root.settings, "barLabels"))
      onChanged: function(value) { root.set("barLabels", value) }
    }

    ChoiceRow {
      label: "Temperature"
      options: [{ value: "Celsius", label: "°C" }, { value: "Fahrenheit", label: "°F" }]
      value: String(Model.settingValue(root.settings, "temperatureUnit"))
      onChanged: function(value) { root.set("temperatureUnit", value) }
    }

    FlagRow {
      label: "Utilization colors"
      checked: Model.flag(root.settings, "utilizationColors")
      onToggled: root.set("utilizationColors", !checked)
    }

    Repeater {
      model: Model.flag(root.settings, "utilizationColors")
        ? [
            { key: "utilizationLowColor", label: "Low (<25%)" },
            { key: "utilizationNormalColor", label: "Normal (25–59%)" },
            { key: "utilizationWarningColor", label: "Warning (60–84%)" },
            { key: "utilizationCriticalColor", label: "Critical (85%+)" }
          ] : []

      delegate: ColorRow {
        required property var modelData
        key: String(modelData.key)
        label: String(modelData.label)
      }
    }

    StepperRow {
      label: "Refresh every"
      value: root.num("refreshSeconds")
      unit: "s"
      stops: Model.REFRESH_STOPS
      onChanged: function(value) { root.set("refreshSeconds", value) }
    }

    StepperRow {
      label: "History"
      value: root.num("historySeconds")
      unit: "s"
      minimum: 30
      maximum: 3600
      step: 30
      onChanged: function(value) { root.set("historySeconds", value) }
    }

    StepperRow {
      label: "Bar graph width"
      value: root.num("graphWidth")
      unit: "px"
      minimum: 16
      maximum: 120
      step: 4
      onChanged: function(value) { root.set("graphWidth", value) }
    }

    Item {
      width: parent.width
      height: resetButton.implicitHeight + Style.space(4)

      Button {
        id: resetButton
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: "Reset to defaults"
        bordered: true
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        onClicked: if (root.host && typeof root.host.resetSettings === "function") root.host.resetSettings()
      }
    }
  }

  // ---------------------------------------------------------- components

  // Label on the left, switch on the right.
  component FlagRow: Item {
    id: flagRow

    property string label: ""
    property bool bold: false
    property bool checked: false
    property real indent: 0

    signal toggled()

    width: parent ? parent.width : implicitWidth
    height: Style.space(26)

    Text {
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.leftMargin: flagRow.indent
      anchors.right: flagSwitch.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      text: flagRow.label
      color: root.foreground
      opacity: flagRow.checked ? 0.9 : 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: flagRow.bold
      elide: Text.ElideRight
    }

    ToggleSwitch {
      id: flagSwitch
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      checked: flagRow.checked
      trackHeight: Style.space(18)
      foreground: root.foreground
      onToggled: flagRow.toggled()
    }

    MouseArea {
      anchors.fill: parent
      anchors.rightMargin: flagSwitch.width + Style.space(10)
      cursorShape: Qt.PointingHandCursor
      onClicked: flagRow.toggled()
    }
  }

  // Label on the left, a chip group on the right.
  component ChoiceRow: Item {
    id: choiceRow

    property string label: ""
    property var options: []
    property string value: ""
    property real indent: 0

    signal changed(string value)

    width: parent ? parent.width : implicitWidth
    height: Math.max(Style.space(30), chips.implicitHeight + Style.space(4))

    Text {
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.leftMargin: choiceRow.indent
      anchors.right: chips.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      text: choiceRow.label
      color: root.foreground
      opacity: 0.9
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }

    ButtonGroup {
      id: chips
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      options: choiceRow.options
      value: choiceRow.value
      foreground: root.foreground
      background: Color.popups.background
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      focusable: false
      onChanged: function(value) { choiceRow.changed(value) }
    }
  }

  // Label on the left, "− value unit +" on the right.
  component StepperRow: Item {
    id: stepper

    property string label: ""
    property real value: 0
    property string unit: ""
    property real minimum: 0
    property real maximum: 100
    property real step: 1
    // When set, the value walks these stops instead of min/max/step.
    property var stops: []

    readonly property bool stepped: Array.isArray(stops) && stops.length > 0
    readonly property int stopIndex: stepped ? Model.nearestStopIndex(value) : -1
    readonly property bool canDecrease: stepped ? stopIndex > 0 : value > minimum
    readonly property bool canIncrease: stepped ? stopIndex < stops.length - 1 : value < maximum
    readonly property string valueText: stepped ? Model.intervalText(value) : String(Math.round(value))

    signal changed(real value)

    function nudge(direction) {
      if (stepped) {
        var idx = Math.max(0, Math.min(stops.length - 1, stopIndex + direction))
        if (stops[idx] !== value) changed(stops[idx])
        return
      }
      var next = Math.max(minimum, Math.min(maximum, value + direction * step))
      if (next !== value) changed(next)
    }

    width: parent ? parent.width : implicitWidth
    height: Style.space(26)

    Text {
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.right: controls.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      text: stepper.label
      color: root.foreground
      opacity: 0.9
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }

    Row {
      id: controls
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)

      PanelActionButton {
        iconText: "󰍴"
        enabled: stepper.canDecrease
        foreground: root.foreground
        fontFamily: root.fontFamily
        size: Style.space(22)
        onClicked: stepper.nudge(-1)
      }

      Item {
        width: Style.space(84)
        height: Style.space(22)

        Measure {
          anchors.centerIn: parent
          value: stepper.valueText
          unit: stepper.unit
          foreground: root.foreground
          fontFamily: root.fontFamily
        }
      }

      PanelActionButton {
        iconText: "󰐕"
        enabled: stepper.canIncrease
        foreground: root.foreground
        fontFamily: root.fontFamily
        size: Style.space(22)
        onClicked: stepper.nudge(1)
      }
    }
  }

  component ColorRow: Item {
    id: colorRow

    property string key: ""
    property string label: ""
    property bool invalid: false
    readonly property string settingColor: Model.utilizationSettingColor(root.settings, key, root.lightTheme)
    readonly property color swatchColor: settingColor
    property string editStartText: ""
    onSettingColorChanged: if (!input.activeFocus) input.text = settingColor

    width: parent ? parent.width : implicitWidth
    height: Style.space(30) + (invalid ? Style.space(14) : 0)

    Text {
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.right: input.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: input.verticalCenter
      text: colorRow.label
      color: root.foreground
      opacity: 0.9
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }

    Rectangle {
      id: swatch
      anchors.right: parent.right
      anchors.verticalCenter: input.verticalCenter
      width: Style.space(18)
      height: width
      radius: Style.space(3)
      color: colorRow.swatchColor
      border.color: Util.alpha(root.foreground, 0.25)
      border.width: 1
    }

    TextField {
      id: input
      anchors.right: swatch.left
      anchors.rightMargin: Style.space(6)
      anchors.top: parent.top
      anchors.topMargin: Style.space(2)
      width: Style.space(88)
      height: Style.space(26)
      text: colorRow.settingColor
      placeholderText: "#RRGGBB"
      maximumLength: 7
      horizontalAlignment: TextInput.AlignRight
      foreground: root.foreground
      verticalPadding: Style.space(4)
      font.pixelSize: Style.font.caption
      onTextChanged: colorRow.invalid = false
      onActiveFocusChanged: {
        // Editors can gain and lose focus in either order during a handoff.
        if (activeFocus) colorRow.editStartText = text
        root.focusedColorEditors = Math.max(0, root.focusedColorEditors + (activeFocus ? 1 : -1))
        if (root.host) root.host.searchActive = root.focusedColorEditors > 0
      }
      onEditingFinished: {
        if (text === colorRow.editStartText) {
          text = colorRow.settingColor
          colorRow.editStartText = text
          return
        }
        if (text === "" || Model.validHexColor(text)) {
          root.set(colorRow.key, text.toLowerCase())
          colorRow.editStartText = text
        } else colorRow.invalid = true
      }
      Keys.onEscapePressed: function(event) {
        focus = false
        event.accepted = true
      }
    }

    Text {
      textFormat: Text.PlainText
      visible: colorRow.invalid
      anchors.left: parent.left
      anchors.bottom: parent.bottom
      text: "Use a six-digit hex color, or clear for the theme default."
      color: Color.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Connections {
      target: root
      function onSettingsChanged() {
        if (!input.activeFocus) input.text = colorRow.settingColor
      }
    }
  }
}
