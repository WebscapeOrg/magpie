import QtQuick 2.15
import QtTest 1.3

// Invariant: Qt emits hover changes when content scrolls under a stationary pointer; this fixture pins that framework behavior.
Item {
  id: host
  width: 200; height: 100

  property string entered: ""

  Flickable {
    id: flick
    anchors.fill: parent
    contentWidth: width
    contentHeight: col.height
    clip: true

    Column {
      id: col
      width: flick.width
      Repeater {
        model: 10
        Rectangle {
          id: row
          required property int index
          width: col.width
          height: 40
          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            onEntered: host.entered = "row" + row.index
          }
        }
      }
    }
  }

  TestCase {
    name: "HoverUnderScroll"
    when: windowShown

    function test_scrolling_under_a_still_pointer_reports_a_new_row() {
      mouseMove(host, 100, 50)
      wait(50)
      compare(host.entered, "row1", "the pointer is parked on a row")

      host.entered = ""
      flick.contentY = 160
      wait(80)
      compare(host.entered, "row5",
        "a still pointer reports a different row once the content moves under it "
        + "— which is why hover must not be allowed to write the keyboard cursor")
    }
  }
}
