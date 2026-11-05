import QtQuick
import QtTest
import "../../components" as Components

Item {
  id: testRoot
  width: 600
  height: 400
  QtObject {
    id: mockTools
    property string hold: ""
    property string holdText: ""
    property int writingCount: 0
    property var resumed: []
    function setPaused(value) { resumed = resumed.concat([value]) }
    function status(row) { return row.id === "writing" ? "writing" : "plain" }
    function overviewFor(row) { return ({}) }
    function avatarFor(row) { return "" }
    property bool descriptionsEnabled: true
  }
  QtObject {
    id: mail
    property var inboxTools: mockTools
    property var messages: [{id:"writing",subject:"Notes from yesterday",from:{display:"Sam Kelly"},time:"22:58",unread:true},{id:"plain",subject:"Website review",snippet:"The updated home page",from:{display:"Webscape"},time:"Yesterday",unread:false}]
    property bool listLoaded: true
    property bool hasMore: false
    property bool listLoading: false
    property string selectedId: ""
    property bool canArchive: true
    property string contentDirection: "auto"
  }
  Component {
    id: progressComponent
    Components.PointProgress {
      tools: mockTools
      textColor: Qt.rgba(0.1, 0.1, 0.1, 1)
      accentColor: Qt.rgba(0.2, 0.42, 0.31, 1)
      dimColor: Qt.rgba(0.4, 0.4, 0.4, 1)
      panelFontFamily: "monospace"
    }
  }
  Component {
    id: listComponent
    Components.MessageList {
      service: mail
      height: 400
      textColor: Qt.rgba(0.1, 0.1, 0.1, 1)
      accentColor: Qt.rgba(0.2, 0.42, 0.31, 1)
      dimColor: Qt.rgba(0.4, 0.4, 0.4, 1)
      urgentColor: Qt.rgba(1, 0.2, 0.2, 1)
      panelFontFamily: "monospace"
    }
  }
  TestCase {
    id: testCase
    name: "PointProgress"
    when: windowShown
    function init() { mockTools.hold = ""; mockTools.holdText = ""; mockTools.writingCount = 0; mockTools.resumed = [] }

    function test_the_line_says_how_many_points_magpie_is_writing_data() {
      return [{tag: "wide", width: 600}, {tag: "narrow", width: 280}]
    }
    function test_the_line_says_how_many_points_magpie_is_writing(data) {
      failOnWarning(/TypeError|ReferenceError|Unable to assign/)
      var progress = createTemporaryObject(progressComponent, testRoot, {width: data.width})
      verify(progress); waitForRendering(progress)
      compare(progress.visible, false); compare(progress.height, 0, "nothing to say, no line")
      mockTools.writingCount = 2
      waitForRendering(progress)
      var line = findChild(progress, "point-progress"), dot = findChild(progress, "point-progress-dot")
      compare(line.text, "Magpie is reading 2 messages")
      verify(dot.visible)
      verify(progress.height >= line.height, "the line has room")
      verify(dot.x + dot.width + 8 <= line.x, "the dot and the words do not touch")
      verify(dot.y >= line.y && dot.y + dot.height <= line.y + line.contentHeight / line.lineCount + 1, "the dot sits beside the first line")
      verify(line.x + line.width <= progress.width, "the line fits at " + data.width)
      mockTools.writingCount = 1
      compare(line.text, "Magpie is reading 1 message")
      mockTools.writingCount = 0
      compare(progress.height, 0, "the line goes when nothing is being written")
    }

    function test_a_pause_is_named_with_resume_beside_it_data() {
      return [{tag: "wide", width: 600}, {tag: "narrow", width: 280}]
    }
    function test_a_pause_is_named_with_resume_beside_it(data) {
      failOnWarning(/TypeError|ReferenceError|Unable to assign/)
      var progress = createTemporaryObject(progressComponent, testRoot, {width: data.width})
      verify(progress)
      mockTools.writingCount = 0; mockTools.hold = "paused"; mockTools.holdText = "New Points are paused."
      waitForRendering(progress)
      var line = findChild(progress, "point-progress")
      compare(line.text, "New Points are paused.")
      verify(!findChild(progress, "point-progress-dot").visible, "nothing is being written")
      var resume = findChild(progress, "point-resume")
      verify(resume.visible)
      verify(line.x + line.width + 8 <= resume.x, "the text and Resume do not touch at " + data.width)
      verify(resume.x + resume.width <= progress.width)
      mouseClick(resume)
      compare(mockTools.resumed, [false])
      mockTools.hold = "subscriptions"; mockTools.holdText = "Your Claude subscriptions are all used up for now. Points continue when one resets."
      waitForRendering(progress)
      verify(!findChild(progress, "point-resume").visible, "nothing to press when there is nothing to do")
      mockTools.writingCount = 2
      compare(line.text, mockTools.holdText, "a lasting problem replaces the count")
      verify(!findChild(progress, "point-progress-dot").visible, "no moving dot while every Point is held")
      verify(line.lineCount >= 1 && line.x + line.width <= progress.width)
      verify(progress.height >= line.implicitHeight, "a wrapped line keeps its room")
    }

    function test_rows_show_moving_lines_only_while_their_point_is_written() {
      failOnWarning(/TypeError|ReferenceError|Unable to assign/)
      var list = createTemporaryObject(listComponent, testRoot, {width: 360})
      verify(list); waitForRendering(list)
      var writingRow = null, plainRow = null
      for (var i = 0; i < list.count; i++) {
        var item = list.itemAtIndex(i)
        if (item && item.summary.id === "writing") writingRow = item
        if (item && item.summary.id === "plain") plainRow = item
      }
      verify(writingRow && plainRow)
      compare(writingRow.writing, true); compare(plainRow.writing, false)
      compare(findChild(writingRow, "point-placeholder").visible, true)
      compare(findChild(writingRow, "message-subject").visible, false)
      compare(findChild(plainRow, "message-subject").text, "Website review", "a failed Point shows the subject")
      compare(list.contentY, list.originY - list.topMargin, "the list starts at its first row")
    }
  }
}
