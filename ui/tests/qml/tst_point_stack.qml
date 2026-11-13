import QtQuick
import QtTest
import "../../components" as Components

Item {
  id: canvas
  width: 600
  height: 400
  property var actions: []
  property var inspected: []
  property var opened: []
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
    onPointDetailsRequested: function(id) { canvas.inspected = canvas.inspected.concat([id]) }
    onMessageActivated: function(id) { canvas.opened = canvas.opened.concat([id]) }
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
      canvas.actions=[]; canvas.inspected=[]; canvas.opened=[]
      waitForRendering(list)
      list.forceLayout()
    }
    function test_stable_rows_move_smoothly_and_keep_identity() {
      mail.messages=[{id:"old",subject:"Completed Point",from:{display:"Original sender"}},{id:"next",subject:"Next current",from:{display:"Next sender"}},{id:"read",subject:"Readable",from:{display:"Reader"}}]
      list.forceLayout();waitForRendering(list)
      var completed=list.itemAtIndex(0), next=list.itemAtIndex(1)
      var before=completed.y
      mail.messages=[mail.messages[1],mail.messages[0],mail.messages[2]]
      list.forceLayout();wait(100)
      compare(completed.summary.id,"old");compare(next.summary.id,"next")
      verify(completed.y>before,"the same card has started moving toward the list")
      verify(completed.y<next.height+list.spacing,"the card passes through an intermediate position")
      wait(550)
      compare(list.itemAtIndex(1),completed,"moving a card keeps its delegate identity")
      list.motionEnabled=false
      mail.messages=[mail.messages[1],mail.messages[0],mail.messages[2]]
      list.forceLayout();waitForRendering(list)
      compare(list.itemAtIndex(0),completed)
      compare(completed.y,0)
      list.motionEnabled=true
    }
    function test_hold_opens_details_without_opening_mail() {
      var row=list.itemAtIndex(0)
      mousePress(row,50,25,Qt.LeftButton)
      wait(1000)
      mouseRelease(row,50,25,Qt.LeftButton)
      compare(JSON.stringify(canvas.inspected),'["old"]')
      compare(JSON.stringify(canvas.opened),'[]')
      mouseClick(row,50,25,Qt.LeftButton)
      compare(JSON.stringify(canvas.opened),'["old"]',"a fresh tap still opens mail")
    }
    function test_hold_cannot_follow_a_reused_row_or_an_account_switch() {
      var row=list.itemAtIndex(0)
      mousePress(row,50,25,Qt.LeftButton)
      mail.activeAccountId="work"
      wait(1000)
      mouseRelease(row,50,25,Qt.LeftButton)
      compare(JSON.stringify(canvas.inspected),'[]')
      compare(JSON.stringify(canvas.opened),'[]')
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
