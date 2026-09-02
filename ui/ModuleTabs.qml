import QtQuick
import qs.Commons
import qs.Ui
import "../Model.js" as Model

// Segmented switcher across the top of the panel: one equal slot per tab,
// Settings included, each named in full. The panel sizes itself to
// `spelledWidth` so the names always fit. The active slot is filled;
// nothing moves when you switch. Abbreviations belong to the bar, where
// height is scarce, not here.
Item {
  id: root

  property var tabs: []
  property string settingsTab: ""
  property string current: ""
  property int cursorIndex: -1
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.family

  signal activated(string id)
  signal hovered(int index, bool isHovered)

  readonly property int count: Array.isArray(tabs) ? tabs.length : 0
  readonly property bool hasSettings: settingsTab !== ""
  readonly property int slots: count + (hasSettings ? 1 : 0)
  readonly property real slotWidth: slots > 0 ? width / slots : width
  readonly property real pillHeight: Style.space(28)
  readonly property real labelSize: Style.font.caption

  // The longest name decides the slot width, Settings included.
  readonly property string longestFull: {
    var best = hasSettings ? Model.moduleDef(settingsTab).label : ""
    for (var i = 0; i < count; i++) {
      var label = Model.moduleDef(String(tabs[i])).label
      if (label.length > best.length) best = label
    }
    return best
  }
  readonly property real spelledSlot: Math.ceil(fullMetrics.advanceWidth) + Style.space(14)
  // Width at which every tab can be named in full; the panel asks for it.
  readonly property real spelledWidth: spelledSlot * slots

  TextMetrics {
    id: fullMetrics
    font.family: root.fontFamily
    font.pixelSize: root.labelSize
    font.bold: true
    text: root.longestFull
  }

  width: parent ? parent.width : implicitWidth
  implicitHeight: pillHeight
  height: implicitHeight

  Repeater {
    model: root.slots

    delegate: Item {
      id: slot
      required property int index
      readonly property bool isSettings: root.hasSettings && index === root.count
      readonly property string tabId: isSettings ? root.settingsTab : String(root.tabs[index] || "")
      readonly property var def: Model.moduleDef(tabId)
      readonly property bool active: root.current === tabId
      readonly property bool hot: root.cursorIndex === index || mouse.containsMouse

      x: index * root.slotWidth
      width: root.slotWidth
      height: root.height

      Rectangle {
        anchors.centerIn: parent
        width: Math.max(Style.space(24), root.slotWidth - Style.space(4))
        height: root.pillHeight
        radius: Style.cornerRadius
        color: slot.active
          ? Style.selectedFillFor(root.foreground, Color.accent)
          : (slot.hot ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent")
        border.width: slot.active ? 1 : 0
        border.color: Util.alpha(root.foreground, 0.12)

        Behavior on color { ColorAnimation { duration: 90 } }
      }

      Text {
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: slot.def.label
        width: Math.min(implicitWidth, root.slotWidth - Style.space(8))
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
        color: root.foreground
        opacity: slot.active || slot.hot ? 1 : 0.7
        font.family: root.fontFamily
        font.pixelSize: root.labelSize
        font.bold: true
        renderType: Text.NativeRendering

        Behavior on opacity { NumberAnimation { duration: 120 } }
      }

      MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.activated(slot.tabId)
        onContainsMouseChanged: root.hovered(slot.index, containsMouse)
      }

      PanelToolTip {
        visible: !slot.active && mouse.containsMouse
        text: slot.def.label
        fontFamily: root.fontFamily
      }
    }
  }
}
