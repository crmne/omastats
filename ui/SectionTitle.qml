import QtQuick
import qs.Commons

// Small-caps section label in the accent colour, iStat-style ("PROCESSES",
// "TEMPERATURE", "PUBLIC IP ADDRESSES").
Text {
  id: root

  property string fontFamily: Style.font.family

  textFormat: Text.PlainText
  color: Color.accent
  font.family: fontFamily
  font.pixelSize: Style.font.caption
  font.bold: true
  font.letterSpacing: 1.1
  font.capitalization: Font.AllUppercase
  elide: Text.ElideRight
  // Nerd Font outlines overshoot the em box; reserve it so the first row in a
  // clipping list is never beheaded (mirrors qs.Ui.PanelSectionHeader).
  topPadding: Math.ceil(Style.font.caption * 0.15)
}
