import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "ui" as UI

// Bar entry point. One instance per bar per monitor; every instance shares
// the single OmaStatsService for data and opens its own popup panel.
Panel {
  id: root
  moduleName: "crmne.omastats"
  ipcTarget: ""

  readonly property var service: bar && bar.shell ? bar.shell.serviceFor("crmne.omastats") : null
  readonly property bool vertical: bar ? bar.vertical : false
  readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal
  readonly property int graphWidth: Math.round(Model.clamp(setting("graphWidth", Model.SETTINGS.graphWidth), 16, 120))
  readonly property string temperatureUnit: String(setting("temperatureUnit", "Celsius")).toLowerCase() === "fahrenheit" ? "Fahrenheit" : "Celsius"
  readonly property bool publicIpEnabled: Model.flag(settings, "publicIp")
  readonly property var configuredModules: Model.parseModules(setting("modules", Model.SETTINGS.modules))
  readonly property bool hasGpu: !!(service && service.hasGpu)
  readonly property bool hasBattery: !!(service && service.hasBattery)
  readonly property var barModules: {
    var out = []
    for (var i = 0; i < configuredModules.length; i++) {
      var id = configuredModules[i]
      if (id === "battery" && !hasBattery) continue
      if (id === "gpu" && !hasGpu) continue
      out.push(id)
    }
    return out.length > 0 ? out : ["cpu"]
  }
  readonly property var moduleTabs: Model.panelTabs(hasBattery, setting("tabs", Model.SETTINGS.tabs))
  readonly property var panelTabs: moduleTabs.concat(["settings"])
  readonly property color fg: Color.popups.text
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string instanceKey: moduleName + ":" + Math.random().toString(36).slice(2, 8)

  readonly property string disksSource: String(setting("disksSource", Model.SETTINGS.disksSource) || "all")
  readonly property string barSensors: String(setting("barSensors", Model.SETTINGS.barSensors) || "cpu")
  readonly property string barLabels: String(setting("barLabels", Model.SETTINGS.barLabels)).toLowerCase() === "icon" ? "icon" : "text"

  property string currentTab: "cpu"
  property int tabCursor: -1

  // Expanded process list + its search, shared by every page.
  property bool processesExpanded: false
  property string processQuery: ""
  property bool searchActive: false
  property var searchField: null
  property bool fullHeld: false

  function setProcessesExpanded(value) {
    processesExpanded = value === true
    if (!processesExpanded) {
      processQuery = ""
      searchActive = false
    }
    syncFull()
  }

  // Hold a "full process list" reference on the service only while the
  // panel is open with the list unfolded.
  function syncFull() {
    var want = opened && processesExpanded
    if (!service || want === fullHeld) return
    fullHeld = want
    if (want) service.acquireFull()
    else service.releaseFull()
  }

  function focusSearch() {
    if (!processesExpanded) setProcessesExpanded(true)
    Qt.callLater(function() { if (root.searchField) root.searchField.forceActiveFocus() })
  }

  function styleFor(module) { return Model.moduleStyle(settings, module) }

  function showTab(id) {
    var tab = Model.tabFor(id)
    if (panelTabs.indexOf(tab) === -1) tab = panelTabs[0]
    if (currentTab !== tab) {
      currentTab = tab
      resetScroll()
    }
  }

  // Bar click: open on that module; a second click on the same module closes.
  function toggleModule(id) {
    var tab = Model.tabFor(id)
    if (opened && currentTab === tab) { close(); return }
    showTab(tab)
    if (!opened) open()
  }

  function cycleTab(delta) {
    var idx = panelTabs.indexOf(currentTab)
    if (idx < 0) idx = 0
    idx = (idx + delta + panelTabs.length) % panelTabs.length
    showTab(panelTabs[idx])
  }

  function resetScroll() {
    var flick = scrollArea.contentItem
    if (flick && flick.contentY !== undefined) flick.contentY = 0
  }

  function scrollBy(steps) {
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var max = Math.max(0, flick.contentHeight - flick.height)
    flick.contentY = Math.max(0, Math.min(max, flick.contentY + steps * Style.space(48)))
  }

  function refresh() {
    if (service && publicIpEnabled) service.requestPublicIp(true)
  }

  function pushSettings() {
    if (!service) return
    service.registerSettings(instanceKey, {
      refreshSeconds: setting("refreshSeconds", 1),
      historySeconds: setting("historySeconds", 240)
    })
  }

  // ---------------------------------------------------------- persistence

  // Where this instance lives in shell.json, so a change touches only this
  // copy even when the widget appears several times in the bar.
  function locateSelf() {
    if (!bar || typeof bar.layoutEntries !== "function" || !Array.isArray(bar.moduleSlots)) return null
    var mine = null
    for (var i = 0; i < bar.moduleSlots.length; i++) {
      var slot = bar.moduleSlots[i]
      if (slot && slot.activeItem === root) { mine = slot; break }
    }
    if (!mine) return null
    var region = String(mine.region || "")
    var entries = bar.layoutEntries(region)
    var direct = entries.indexOf(mine.entry)
    if (direct !== -1) return { section: region, index: direct }
    var candidates = []
    for (var j = 0; j < entries.length; j++) {
      if (typeof bar.entryId === "function" && bar.entryId(entries[j]) === moduleName) candidates.push(j)
    }
    if (candidates.length === 1) return { section: region, index: candidates[0] }
    if (candidates.length === 0) return null
    // Several copies in this region: rank this slot among its siblings on the same screen.
    var siblings = []
    for (var k = 0; k < bar.moduleSlots.length; k++) {
      var other = bar.moduleSlots[k]
      if (!other || other.region !== region || other.moduleName !== moduleName) continue
      if (typeof bar.sameWindow === "function" && typeof bar.slotWindow === "function"
          && !bar.sameWindow(bar.slotWindow(other), bar.slotWindow(mine))) continue
      siblings.push(other)
    }
    siblings.sort(function(a, b) { return root.vertical ? a.y - b.y : a.x - b.x })
    var ordinal = siblings.indexOf(mine)
    if (ordinal < 0 || ordinal >= candidates.length) return null
    return { section: region, index: candidates[ordinal] }
  }

  function persist(key, value) {
    var next = {}
    for (var k in settings) next[k] = settings[k]
    next[key] = value
    settings = next
    if (!bar || !bar.shell) return
    var registry = bar.shell.pluginRegistry
    var where = locateSelf()
    if (registry && where && typeof registry.setBarWidget === "function") {
      var error = registry.setBarWidget(moduleName, key, value, { section: where.section, index: where.index })
      if (!error) return
      console.warn("crmne.omastats: per-instance setting failed, falling back:", error)
    }
    if (typeof bar.shell.updateEntryInline === "function") {
      var entry = { id: moduleName }
      for (var e in next) if (e !== "id") entry[e] = next[e]
      bar.shell.updateEntryInline(moduleName, entry)
    }
  }

  function resetSettings() {
    var defaults = Model.SETTINGS
    for (var key in defaults) persist(key, defaults[key])
  }

  implicitWidth: readouts.implicitWidth + Style.space(2)
  implicitHeight: vertical ? readouts.implicitHeight : barSize

  onOpenedChanged: {
    if (!service) return
    if (opened) {
      service.acquireDetail()
      service.setFocus(currentTab)
      tabCursor = -1
    } else {
      service.releaseDetail()
      service.setFocus("")
      searchActive = false
    }
    syncFull()
  }

  onCurrentTabChanged: if (opened && service) service.setFocus(currentTab)

  onPanelTabsChanged: if (panelTabs.indexOf(currentTab) === -1) currentTab = panelTabs[0]
  onSettingsChanged: pushSettings()
  onServiceChanged: {
    pushSettings()
    if (service) service.registerInstance(root)
  }
  Component.onCompleted: {
    pushSettings()
    if (service) service.registerInstance(root)
  }
  Component.onDestruction: {
    if (service) {
      if (opened) service.releaseDetail()
      if (fullHeld) service.releaseFull()
      service.unregisterSettings(instanceKey)
      service.unregisterInstance(root)
    }
  }

  Grid {
    id: readouts
    anchors.centerIn: parent
    columns: root.vertical ? 1 : root.barModules.length
    rows: root.vertical ? root.barModules.length : 1
    columnSpacing: 0
    rowSpacing: 0

    Repeater {
      model: root.barModules

      delegate: UI.BarReadout {
        required property var modelData
        bar: root.bar
        module: modelData
        service: root.service
        mode: root.styleFor(modelData)
        graphWidth: root.graphWidth
        temperatureUnit: root.temperatureUnit
        disksSource: root.disksSource
        barSensors: root.barSensors
        labelMode: root.barLabels
        onActivated: function(id, button) {
          if (button === Qt.LeftButton) root.toggleModule(id)
          else if (button === Qt.RightButton && root.bar) root.bar.run("omarchy-launch-or-focus-tui btop")
          else if (button === Qt.MiddleButton) root.refresh()
        }
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // Wide enough to name every tab in full; the strip abbreviates only if
    // the screen cannot give it that much.
    contentWidth: panel.fittedContentWidth(Math.max(Style.space(372),
      Math.ceil(tabs.spelledWidth) + Style.spacing.popupPadding * 2))
    // Grow with the page; KeyboardPanel caps this at the screen, which is the
    // only point at which the page scrolls.
    contentHeight: panel.fittedContentHeight(
      tabs.height + Style.space(10) + statusLine.height + pageLoader.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the process search has focus, keys belong to it.
      blocked: root.searchActive

      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.cycleTab(dx)
        else if (dy !== 0) root.scrollBy(dy)
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        var digit = parseInt(text, 10)
        if (isFinite(digit) && digit >= 1 && digit <= root.moduleTabs.length) {
          root.showTab(root.moduleTabs[digit - 1])
          return
        }
        if (text === "r") root.refresh()
        if (text === "," || text === "s") root.showTab("settings")
        if (text === "/") root.focusSearch()
      }

      UI.ModuleTabs {
        id: tabs
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        tabs: root.moduleTabs
        settingsTab: "settings"
        current: root.currentTab
        cursorIndex: root.tabCursor
        foreground: root.fg
        fontFamily: root.fontFamily
        onActivated: function(id) { root.showTab(id) }
        onHovered: function(index, isHovered) { root.tabCursor = isHovered ? index : (root.tabCursor === index ? -1 : root.tabCursor) }
      }

      Text {
        id: statusLine
        anchors.top: tabs.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        textFormat: Text.PlainText
        readonly property string message: {
          if (!root.service) return "The OmaStats service is not loaded — re-enable the plugin."
          if (!root.service.ready) return "Starting the sampler…"
          return root.service.samplerError ? "Sampler: " + root.service.samplerError : ""
        }
        visible: message !== ""
        height: visible ? implicitHeight + Style.space(10) : 0
        verticalAlignment: Text.AlignBottom
        text: message
        color: root.fg
        opacity: 0.6
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }

      ScrollView {
        id: scrollArea
        anchors.top: statusLine.bottom
        anchors.topMargin: Style.space(10)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: pageLoader.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: pageLoader.implicitHeight > scrollArea.height
        }

        Loader {
          id: pageLoader
          width: scrollArea.availableWidth
          active: root.opened || panel.visible
          source: Qt.resolvedUrl("ui/" + Model.pageFile(root.currentTab))
        }

        Binding { target: pageLoader.item; property: "service"; value: root.service; when: pageLoader.status === Loader.Ready }
        Binding { target: pageLoader.item; property: "settings"; value: root.settings; when: pageLoader.status === Loader.Ready }
        Binding { target: pageLoader.item; property: "host"; value: root; when: pageLoader.status === Loader.Ready && pageLoader.item && pageLoader.item.hasOwnProperty("host") }
        Binding { target: pageLoader.item; property: "temperatureUnit"; value: root.temperatureUnit; when: pageLoader.status === Loader.Ready }
        Binding { target: pageLoader.item; property: "publicIpEnabled"; value: root.publicIpEnabled; when: pageLoader.status === Loader.Ready }
        Binding { target: pageLoader.item; property: "foreground"; value: root.fg; when: pageLoader.status === Loader.Ready }
        Binding { target: pageLoader.item; property: "fontFamily"; value: root.fontFamily; when: pageLoader.status === Loader.Ready }
      }
    }
  }
}
