import QtQuick
import QtTest
import "../../components" as Components
Item {
  width: 1000
  height: 850
  Components.SnoozePicker {
    id: picker
    property var clock: ({time: Date.now()})
    function currentTime() { return clock.time }
    anchors.fill: parent
    textColor: Qt.rgba(1,1,1,1); dimColor: Qt.rgba(0.7,0.7,0.7,1); accentColor: Qt.rgba(0.5,0.8,0.5,1); popupBackgroundColor: Qt.rgba(0.08,0.13,0.13,1); popupBorderColor: Qt.rgba(0.4,0.4,0.4,1); panelFontFamily: "sans-serif"
  }
  SignalSpy { id: snoozedSpy; target: picker; signalName: "snoozed" }
  TestCase {
    name: "SnoozePicker"
    when: windowShown
    function init() { snoozedSpy.clear() }
    function cleanup() { picker.clock = {time: Date.now()}; findChild(picker, "snooze-popup").close() }
    function test_custom_validation_and_keyboard_escape() {
      picker.openAt("mail-id",950,800)
      var popup=findChild(picker,"snooze-popup")
      tryCompare(picker,"opened",true)
      verify(popup.x>=0 && popup.x+popup.width<=picker.width)
      verify(popup.y>=0 && popup.y+popup.height<=picker.height)
      findChild(picker,"snooze-custom").clicked()
      var date=findChild(picker,"snooze-date")
      date.text=(new Date().getFullYear()+1)+"-02-30"
      compare(picker.chosenTime,null)
      date.text=Qt.formatDate(new Date(Date.now()+86400000),"yyyy-MM-dd")
      verify(!!picker.chosenTime)
      keyClick(Qt.Key_Escape)
      tryCompare(picker,"opened",false)
      compare(snoozedSpy.count,0,"closing never mutates a mailbox")
    }
    function test_expired_custom_time_keeps_the_dialog_and_updates_validation() {
      picker.openAt("expired-id", 10, 10)
      tryCompare(picker, "opened", true)
      wait(50)
      var custom = findChild(picker, "snooze-custom")
      mouseClick(custom, custom.width / 2, custom.height / 2)
      tryCompare(picker, "custom", true)
      wait(50)
      var chosen = new Date(Date.now() + 86400000)
      chosen.setHours(8, 0, 0, 0)
      picker.clock.time = chosen.getTime() - 60000
      findChild(picker, "snooze-date").text = Qt.formatDate(chosen, "yyyy-MM-dd")
      verify(!!picker.chosenTime)
      var submit = findChild(picker, "snooze-submit")
      verify(submit.enabled)
      picker.clock.time = chosen.getTime() + 60000
      mouseClick(submit, submit.width / 2, submit.height / 2)
      compare(snoozedSpy.count, 0, "An expired time must never change the mailbox")
      verify(picker.opened)
      compare(picker.chosenTime, null)
      verify(!submit.enabled)
    }
    function test_preset_emits_original_id_and_local_eight_am_data() {
      return [{tag: "first", messageId: "first-id"}, {tag: "second", messageId: "second-id"}]
    }
    function test_preset_emits_original_id_and_local_eight_am(data) {
      picker.openAt(data.messageId,10,10)
      var expected=picker.choices[0].date
      picker.choose(expected)
      compare(snoozedSpy.count,1)
      compare(snoozedSpy.signalArguments[0][0],data.messageId)
      compare(snoozedSpy.signalArguments[0][1],expected.getTime())
      compare(expected.getHours(),8)
    }
  }
}
