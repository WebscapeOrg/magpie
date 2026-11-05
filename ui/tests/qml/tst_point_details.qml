import QtQuick
import QtTest
import "../../components" as Components
Item {
  id: canvas
  width: 600; height: 620
  Components.PointDetails {
    id: details
    textColor: Qt.rgba(0.12,0.16,0.22,1); dimColor: Qt.rgba(0.32,0.38,0.43,1); backgroundColor: Qt.rgba(1,1,1,1); borderColor: Qt.rgba(0.80,0.84,0.88,1); panelFontFamily: "sans-serif"
  }
  TestCase {
    name: "PointDetails"
    when: windowShown
    function cleanup() { details.close(); canvas.width=600; canvas.height=620 }
    function test_details_fit_and_close_data() { return [{tag:"wide",width:600,height:620},{tag:"narrow",width:280,height:320}] }
    function test_details_fit_and_close(data) {
      failOnWarning(/TypeError|ReferenceError|Unable to assign/)
      canvas.width=data.width;canvas.height=data.height
      details.openFor({from:{display:"<b>Untrusted sender</b>"}}, {state:"ready",details:{requestedModel:"sonnet",model:"haiku",gmailMs:125,decideMs:42,createMs:2500,batchSize:3}})
      tryCompare(details,"opened",true)
      waitForRendering(canvas)
      var popup=findChild(details,"point-details"), done=findChild(details,"point-details-done")
      verify(popup.width<=canvas.width-24);verify(popup.height<=canvas.height-24)
      compare(details.sender,"<b>Untrusted sender</b>")
      verify(done.activeFocus)
      var words=findChild(details,"point-details-scroll")
      keyClick(Qt.Key_Down)
      if (words.contentHeight > words.height) {
        verify(words.contentY>0,"keyboard scroll reaches hidden timings")
        words.contentY=0
        mouseWheel(words,words.width/2,words.height/2,0,-120)
        verify(words.contentY>0,"wheel scroll reaches hidden timings")
      }
      verify(done.visible)
      keyClick(Qt.Key_Escape)
      tryCompare(details,"opened",false)
      compare(details.sender,"")
      details.openFor({from:{display:"Other account"}}, {})
      tryCompare(details,"opened",true)
      compare(JSON.stringify(details.overview),"{}")
      mouseClick(done)
      tryCompare(details,"opened",false)
    }
  }
}
