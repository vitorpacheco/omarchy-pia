import QtQuick
import qs.Commons
import qs.Ui

// Shield glyph for the bar and the panel hero. `crossed` draws a strike-through
// for the disconnected state, `pulsing` breathes while a connection is in
// flight, and `warning` adds a badge when the user must log in.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property color badgeColor: Color.urgent
  property string fontFamily: Style.font.family
  property bool crossed: false
  property bool pulsing: false
  property bool warning: false

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  Text {
    id: glyph
    anchors.centerIn: parent
    text: "󰒃"
    color: root.color
    font.family: root.fontFamily
    font.pixelSize: root.iconSize
    opacity: root.pulsing ? 0.45 : 1.0

    SequentialAnimation on opacity {
      running: root.pulsing
      loops: Animation.Infinite
      NumberAnimation { to: 1.0; duration: 520; easing.type: Easing.InOutQuad }
      NumberAnimation { to: 0.35; duration: 520; easing.type: Easing.InOutQuad }
    }
  }

  Rectangle {
    visible: root.crossed
    anchors.centerIn: parent
    width: parent.width * 1.22
    height: Math.max(2, parent.height * 0.14)
    radius: height / 2
    color: root.color
    rotation: -45
  }

  BorderSurface {
    visible: root.warning
    width: Math.max(7, parent.width * 0.42)
    height: width
    radius: width / 2
    color: root.badgeColor
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    borderSpec: Border.flat(Color.popups.background, 1)

    Text {
      anchors.centerIn: parent
      text: "!"
      color: Color.background
      font.family: root.fontFamily
      font.pixelSize: Math.max(6, parent.height * 0.72)
      font.bold: true
    }
  }
}
