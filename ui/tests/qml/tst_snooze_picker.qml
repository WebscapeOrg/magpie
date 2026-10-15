import QtQuick
import QtTest
import "../../components" as Components
Item {
  width: 1000
  height: 850
  Components.SnoozePicker {
    id: picker
    anchors.fill: parent
    textColor: Qt.rgba(1,1,1,1); dimColor: Qt.rgba(0.7,0.7,0.7,1); accentColor: Qt.rgba(0.5,0.8,0.5,1); popupBackgroundColor: Qt.rgba(0.08,0.13,0.13,1); popupBorderColor: Qt.rgba(0.4,0.4,0.4,1); panelFontFamily: "sans-serif"
  }
  SignalSpy { id: spy; target: picker; signalName: "snoozed" }
  TestCase {
    name: "SnoozePicker"
    when: windowShown
    function test_custom_validation_and_keyboard_escape() {
      picker.openAt("mail-id",950,800)
      var popup=findChild(picker,"snooze-popup")
      tryCompare(picker,"opened",true)
      verify(popup.x>=0 && popup.x+popup.width<=picker.width)
      verify(popup.y>=0 && popup.y+popup.height<=picker.height)
      findChild(picker,"snooze-custom").clicked()
      var date=findChild(picker,"snooze-date")
      date.text="2026-02-30"
      compare(picker.chosenTime,null)
      date.text=Qt.formatDate(new Date(Date.now()+86400000),"yyyy-MM-dd")
      verify(!!picker.chosenTime)
      keyClick(Qt.Key_Escape)
      tryCompare(picker,"opened",false)
      compare(spy.count,0,"closing never mutates a mailbox")
    }
    function test_preset_emits_original_id_and_local_eight_am() {
      picker.openAt("second-id",10,10)
      var expected=picker.choices[0].date
      picker.choose(expected)
      compare(spy.count,1)
      compare(spy.signalArguments[0][0],"second-id")
      compare(spy.signalArguments[0][1],expected.getTime())
      compare(expected.getHours(),8)
    }
  }
}
