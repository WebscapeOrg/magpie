import QtQuick
import "../settings"
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Item {
  id: root

  required property string logo
  // Invariant: provider artwork retains its own proportions; only its height is constrained.
  property real size: MailStyle.space(40)

  property string fallbackIcon: ""
  property color fallbackColor: Commons.Color.foreground

  readonly property bool present: logo !== "" || fallbackIcon !== ""
  readonly property bool drawn: logo !== ""
  readonly property real aspect: drawn && mark.implicitHeight > 0
    ? mark.implicitWidth / mark.implicitHeight : 1

  visible: present
  width: present ? Math.round(size * aspect) : 0
  height: present ? size : 0
  implicitWidth: width
  implicitHeight: height

  Image {
    id: mark
    anchors.fill: parent
    visible: root.drawn
    source: root.drawn ? "../assets/" + root.logo : ""
    // Invariant: load at twice the drawn height for HiDPI clarity while deriving width from the
    // artwork.
    sourceSize.height: Math.round(root.size * 2)
    fillMode: Image.PreserveAspectFit
    smooth: true
    // Invariant: these small bundled assets load synchronously to avoid a zero-size frame and
    // layout jump.
    asynchronous: false
    cache: true
  }

  ActionIcon {
    anchors.centerIn: parent
    visible: !root.drawn && root.fallbackIcon !== ""
    name: root.fallbackIcon
    iconSize: Math.round(root.size * 0.8)
    color: root.fallbackColor
  }
}
