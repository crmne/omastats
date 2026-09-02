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
  property string temperatureUnit: "Celsius"
  property bool publicIpEnabled: true
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.family

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
      out.push(id)
    }
    return out
  }
  readonly property var snapshot: service ? service.snapshot : ({})
  readonly property var diskOptions: Model.diskOptions(snapshot)
  readonly property var sensorOptions: Model.sensorOptions(snapshot)
  readonly property var barSensorIds: Model.parseList(Model.settingValue(settings, "barSensors"))

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
          value: Model.moduleStyle(root.settings, moduleRow.moduleId)
          foreground: root.foreground
          fontFamily: root.fontFamily
          onChanged: function(value) { root.set(moduleRow.moduleId + "Style", value) }
        }

        // Disks: which device the readout and the activity graph follow.
        Dropdown {
          visible: moduleRow.enabled && moduleRow.moduleId === "disks"
          x: Style.space(12) + moduleSwitch.width + Style.space(12)
          width: parent.width - x
          label: "Source"
          options: root.diskOptions
          value: String(Model.settingValue(root.settings, "disksSource") || "all")
          foreground: root.foreground
          fontFamily: root.fontFamily
          onChanged: function(value) { root.set("disksSource", value) }
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
}
