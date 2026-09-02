import QtQuick
import qs.Commons
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
  property var host: null
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.family
  property real columnWidth: Style.space(66)
  property int maxRows: 200

  readonly property bool expanded: expandable && !!host && host.processesExpanded === true
  readonly property string query: host ? String(host.processQuery || "") : ""
  readonly property var shown: expanded
    ? Model.filterProcesses(allItems, query, sortKey)
    : (Array.isArray(items) ? items : [])
  readonly property int rowCount: Math.min(shown.length, maxRows)
  readonly property bool collecting: expanded && (!Array.isArray(allItems) || allItems.length === 0)

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

  TextField {
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
    model: root.rowCount

    delegate: Item {
      id: procRow
      required property int index
      readonly property var proc: root.shown[index] || ({})
      width: parent.width
      height: Style.space(20)

      Row {
        anchors.left: parent.left
        anchors.right: figures.left
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
          width: Math.min(implicitWidth, parent.width - (countText.visible ? countText.implicitWidth + Style.space(6) : 0))
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
        anchors.right: parent.right
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
