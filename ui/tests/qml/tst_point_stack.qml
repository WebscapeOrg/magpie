import QtQuick
import QtTest
import "../../components" as Components

Item {
  id: canvas
  width: 600
  height: 400
  property var actions: []
  QtObject {
    id: mail
    property var messages: [{id:"old",subject:"Old current",from:{display:"Original sender"}}]
    property bool listLoaded: true
    property bool listLoading: false
    property bool hasMore: false
    property bool canArchive: true
    property string selectedId: ""
    property string activeAccountId: "personal"
  }
  Components.MessageList {
    id: list
    width: 600
    height: 300
    service: mail
    textColor: Qt.rgba(0,0,0,1)
    accentColor: Qt.rgba(0,0.5,0,1)
    dimColor: Qt.rgba(0.5,0.5,0.5,1)
    urgentColor: Qt.rgba(0.7,0,0,1)
    panelFontFamily: "sans-serif"
    onRowActionRequested: function(id, action) {
      canvas.actions = canvas.actions.concat([{id:id,action:action}])
    }
  }
  TestCase {
    name: "CardIdentity"
    when: windowShown
    function init() {
      mail.activeAccountId="personal"
      mail.messages=[{id:"old",subject:"Old current",from:{display:"Original sender"}}]
      canvas.actions=[]
      waitForRendering(list)
      list.forceLayout()
    }
    function test_rotation_during_press_does_not_archive_new_current() {
      waitForRendering(list)
      list.forceLayout()
      var row = list.itemAtIndex(0)
      verify(row)
      verify(row.visible)
      verify(row.height > 40)
      mouseClick(row,50,25,Qt.MiddleButton)
      compare(JSON.stringify(canvas.actions),'[{"id":"old","action":"archive"}]',"the harness must exercise the archive action")
      canvas.actions=[]
      mousePress(row,50,25,Qt.MiddleButton)
      mail.messages=[{id:"new",subject:"New current",from:{display:"Different sender"}}]
      waitForRendering(list)
      mouseRelease(row,50,25,Qt.MiddleButton)
      compare(JSON.stringify(canvas.actions),"[]","a current-card change must not redirect an in-progress click")
    }
    function test_rotation_during_button_press_does_not_trash_new_current() {
      var row=list.itemAtIndex(0)
      verify(row)
      mouseMove(row,50,25)
      waitForRendering(list)
      var button=findChild(row,"message-trash")
      verify(button)
      verify(button.visible)
      mouseClick(button,button.width/2,button.height/2)
      compare(JSON.stringify(canvas.actions),'[{"id":"old","action":"trash"}]',"the harness must exercise the trash button")
      canvas.actions=[]
      mousePress(button,button.width/2,button.height/2)
      mail.messages=[{id:"new",subject:"New current",from:{display:"Different sender"}}]
      waitForRendering(list)
      mouseRelease(button,button.width/2,button.height/2)
      compare(JSON.stringify(canvas.actions),"[]","a changed current card must not redirect its pressed trash button")
    }
    function test_account_change_during_press_invalidates_same_provider_id() {
      var row=list.itemAtIndex(0)
      verify(row)
      mouseClick(row,50,25,Qt.MiddleButton)
      compare(JSON.stringify(canvas.actions),'[{"id":"old","action":"archive"}]')
      canvas.actions=[]
      mousePress(row,50,25,Qt.MiddleButton)
      mail.activeAccountId="work"
      mail.messages=[{id:"old",subject:"Same provider ID in a different account",from:{display:"Different sender"}}]
      waitForRendering(list)
      mouseRelease(row,50,25,Qt.MiddleButton)
      compare(JSON.stringify(canvas.actions),"[]","single-account summaries need their owning account in the gesture identity")
    }
  }
}
