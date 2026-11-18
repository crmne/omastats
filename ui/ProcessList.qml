import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "../Model.js" as Model

// "PROCESSES" block: the top consumers with one or two right-aligned figure
// columns. "All" unfolds it into every process, sorted by the page's own
// column, with a search field; that state lives on the host so it follows
// you from page to page.
Column {
  id: root

  property var items: []
  property var allItems: []
  property int total: 0
  // [{ key: "cpu", kind: "percent" | "bytes" | "rate" | "count", title: "" }]
  property var columns: [{ key: "cpu", kind: "percent", title: "" }]
  // Key the unfolded list sorts by; "io" means read + write.
  property string sortKey: columns.length > 0 ? String(columns[0].key) : "cpu"
  property string title: "Processes"
  property string caption: ""
  property string emptyText: "Nothing to show yet"
  property bool expandable: true
  property ProcessActions actions: null
  property var host: null
  property color foreground: Commons.Color.popups.text
  property string fontFamily: Style.font.family
  property real columnWidth: Style.space(66)
  property int maxRows: 200

  readonly property bool manageGroups: !!actions
  readonly property bool expanded: expandable && !!host && host.processesExpanded === true
  readonly property string query: host ? String(host.processQuery || "") : ""
  readonly property var shown: expanded
    ? Model.filterProcesses(allItems, query, sortKey)
    : (Array.isArray(items) ? items : [])
  readonly property var displayed: {
    if (!pinned) return shown
    const name = pinned.row.name
    const rows = shown.filter(row => row.name !== name)
    const latest = shown.find(row => row.name === name)
    rows.splice(pinned.index, 0, latest || pinned.row)
    return rows
  }
  readonly property int rowCount: Math.min(displayed.length, maxRows)
  readonly property bool collecting: expanded && (!Array.isArray(allItems) || allItems.length === 0)
  property var pinned: null

  Commons.Translations {
    id: groupStrings
    directory: root.manageGroups ? Qt.resolvedUrl("../i18n") : ""
  }

  Connections {
    target: root.actions
    function onGroupChanged() {
      if (!root.actions.group) Qt.callLater(root.releasePinnedRow)
    }
  }

  onQueryChanged: if (actions) actions.clear()
  onExpandedChanged: if (actions) actions.clear()

  function selectGroup(index, forClosing) {
    const row = displayed[index]
    if (!actions || !actions.available || !row || !row.name) return
    actions.select(row.name, forClosing)
    // Keep the chosen row under the pointer when the live list changes rank.
    // Its figure still uses the latest sample whenever the group is present.
    if (actions.group === row.name && (!pinned || pinned.row.name !== row.name))
      pinned = { row: row, index: index }
  }

  function releasePinnedRow() {
    if (!pinned || actions?.group) return
    for (let i = 0; i < processRows.count; i++) {
      if (processRows.itemAt(i)?.detailsVisible) return
    }
    pinned = null
  }

  component GroupButton: PanelActionButton {
    fontSize: Style.font.body
    foreground: root.foreground
    fontFamily: root.fontFamily
    focusable: true
    opacity: enabled ? 1 : 0.4
    Accessible.role: Accessible.Button
    Accessible.name: tooltipText
    Accessible.onPressAction: if (enabled) clicked()
  }

  function figure(item, column) {
    var raw = item ? item[column.key] : undefined
    if (column.kind === "percent") return Model.percentParts(raw)
    if (column.kind === "count") return { value: String(Math.round(Model.num(raw))), unit: "" }
    if (column.kind === "rate") {
      if (!(raw > 0)) return { value: "–", unit: "" }
      return Model.rateParts(raw)
    }
    return Model.bytesParts(raw)
  }

  function setExpanded(value) {
    if (host && typeof host.setProcessesExpanded === "function") host.setProcessesExpanded(value)
    if (value) Qt.callLater(function() { search.forceActiveFocus() })
  }

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(4)

  Item {
    width: parent.width
    height: Style.space(18)

    SectionTitle {
      id: titleText
      text: root.title + (root.expanded && root.total > 0 ? " · " + root.total : "")
      fontFamily: root.fontFamily
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: expandLabel
      visible: root.expandable
      textFormat: Text.PlainText
      anchors.left: titleText.right
      anchors.leftMargin: Style.space(10)
      anchors.baseline: titleText.baseline
      text: root.expanded ? "Show less" : "Show all"
      color: root.foreground
      opacity: expandMouse.containsMouse ? 0.9 : 0.5
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true

      Behavior on opacity { NumberAnimation { duration: 90 } }

      MouseArea {
        id: expandMouse
        anchors.fill: parent
        anchors.margins: -Style.space(4)
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.setExpanded(!root.expanded)
      }
    }

    Row {
      anchors.right: parent.right
      anchors.rightMargin: root.manageGroups ? Style.space(28) : 0
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      Repeater {
        model: root.columns
        delegate: Text {
          required property var modelData
          textFormat: Text.PlainText
          width: root.columnWidth
          horizontalAlignment: Text.AlignRight
          text: modelData.title || ""
          color: root.foreground
          opacity: 0.5
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }
    }
  }

  Text {
    textFormat: Text.PlainText
    visible: root.caption !== ""
    width: parent.width
    text: root.caption
    color: root.foreground
    opacity: 0.45
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  // Not a TextField: see KeyField for why.
  KeyField {
    id: search
    visible: root.expanded
    width: parent.width
    height: visible ? implicitHeight : 0
    placeholderText: "Search processes"
    text: root.query
    foreground: root.foreground
    verticalPadding: Style.space(4)
    font.pixelSize: Style.font.bodySmall
    onTextChanged: if (root.host && root.host.processQuery !== text) root.host.processQuery = text
    onActiveFocusChanged: if (root.host) root.host.searchActive = activeFocus
    Keys.onEscapePressed: function(event) {
      if (text !== "") { text = ""; event.accepted = true; return }
      focus = false
      event.accepted = true
    }
    Component.onCompleted: if (root.host && root.expandable) root.host.searchField = search
    Component.onDestruction: if (root.host && root.host.searchField === search) root.host.searchField = null
  }

  Text {
    textFormat: Text.PlainText
    visible: root.collecting || root.shown.length === 0
    text: root.collecting ? "Collecting…" : (root.expanded ? "No match" : root.emptyText)
    color: root.foreground
    opacity: 0.45
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    topPadding: Style.space(2)
    bottomPadding: Style.space(2)
  }

  Repeater {
    id: processRows
    model: root.rowCount

    delegate: Item {
      id: procRow
      required property int index
      readonly property var proc: root.displayed[index] || ({})
      readonly property bool selected: root.manageGroups && root.actions.group !== "" && proc.name === root.actions.group
      readonly property bool detailsVisible: detailsViewport.height > 0
      width: parent.width
      height: header.height + detailsViewport.height

      Item {
        id: header
        width: parent.width
        height: Style.space(root.manageGroups ? 24 : 20)

        Row {
          anchors.left: parent.left
          anchors.right: disclosure.left
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(6)

          Text {
            textFormat: Text.PlainText
            text: procRow.proc.name || ""
            color: root.foreground
            opacity: 0.9
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
            width: Math.max(0, Math.min(implicitWidth, parent.width - (countText.visible ? countText.implicitWidth + Style.space(6) : 0)))
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: countText
            textFormat: Text.PlainText
            visible: (procRow.proc.count || 1) > 1
            text: "×" + (procRow.proc.count || 1)
            color: root.foreground
            opacity: 0.4
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        Row {
          id: figures
          anchors.right: closeGroup.left
          anchors.rightMargin: root.manageGroups ? Style.space(6) : 0
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(8)

          Repeater {
            model: root.columns
            delegate: Item {
              id: cell
              required property var modelData
              readonly property var parts: root.figure(procRow.proc, modelData)
              width: root.columnWidth
              height: Style.space(20)

              Measure {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                value: cell.parts.value
                unit: cell.parts.unit
                foreground: root.foreground
                fontFamily: root.fontFamily
                bold: false
                valueOpacity: 0.9
              }
            }
          }
        }

        Loader {
          id: disclosure
          anchors.right: figures.left
          anchors.verticalCenter: parent.verticalCenter
          width: active ? Style.space(22) : 0
          height: parent.height
          active: root.manageGroups
          sourceComponent: GroupButton {
            enabled: root.actions.available && (!root.actions.busy || (procRow.selected && root.actions.loading))
              && (!root.actions.pending || procRow.selected)
            iconText: procRow.selected ? "▾" : (Commons.I18n.rightToLeft ? "‹" : "›")
            tooltipText: groupStrings.t(procRow.selected ? "processGroup.hide" : "processGroup.show")
            onClicked: root.selectGroup(procRow.index, false)
          }
        }

        Loader {
          id: closeGroup
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          width: active ? Style.space(22) : 0
          height: parent.height
          active: root.manageGroups
          sourceComponent: GroupButton {
            enabled: root.actions.available && !root.actions.busy && !root.actions.pending
              && (!procRow.selected || !root.actions.data || (root.actions.data.windowsAvailable && !root.actions.data.truncated))
            iconText: "×"
            hoverColor: Commons.Color.urgent
            tooltipText: groupStrings.t("processGroup.closeGroupTooltip")
            onClicked: root.selectGroup(procRow.index, true)
          }
        }
      }

      Item {
        id: detailsViewport
        readonly property bool sameGroup: !!detailsLoader.item && !!detailsLoader.item.snapshot
          && detailsLoader.item.snapshot.group === procRow.proc.name
        y: header.height
        width: parent.width
        height: procRow.selected && detailsLoader.item ? detailsLoader.item.implicitHeight : 0
        visible: height > 0 && (procRow.selected || sameGroup)
        clip: true
        onHeightChanged: if (height === 0 && !root.actions?.group) Qt.callLater(root.releasePinnedRow)

        Behavior on height {
          id: resize
          NumberAnimation {
            duration: Style.duration(resize.targetValue > 0 ? 220 : 150)
            easing.type: Easing.OutCubic
          }
        }

        Loader {
          id: detailsLoader
          active: procRow.selected || (detailsViewport.height > 0 && detailsViewport.sameGroup)
          enabled: procRow.selected
          width: parent.width
          sourceComponent: ProcessGroup {
            id: detailsContent
            strings: groupStrings
            foreground: root.foreground
            fontFamily: root.fontFamily

            // Keep the last snapshot in the clipping viewport as it closes.
            Binding {
              target: detailsContent
              property: "snapshot"
              value: root.actions?.view
              when: procRow.selected && root.actions.view.group === procRow.proc.name
              restoreMode: Binding.RestoreNone
            }

            onTerminateRequested: function(member) { root.actions.prepareTermination(member) }
            onWindowCloseRequested: function(member, window) { root.actions.closeWindow(member, window) }
            onConfirmed: root.actions.confirm()
            onCanceled: root.actions.pending = null
          }
        }
      }
    }
  }

  Text {
    textFormat: Text.PlainText
    visible: root.expanded && root.shown.length > root.maxRows
    text: "and " + (root.shown.length - root.maxRows) + " more — narrow the search"
    color: root.foreground
    opacity: 0.45
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    topPadding: Style.space(2)
  }
}
