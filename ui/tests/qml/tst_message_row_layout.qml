import QtQuick
import QtTest
import "../../components" as Omamail

Item {
  width: 640
  height: 160
  Omamail.MessageRow {
    id: row
    width: 600
    textColor: Qt.rgba(1, 1, 1, 1)
    accentColor: Qt.rgba(1, 0.5, 0, 1)
    dimColor: Qt.rgba(0.6, 0.6, 0.6, 1)
    panelFontFamily: "monospace"
    summary: ({id:"one",subject:"Title",from:{display:"Sender"},snippet:"Description",time:"09:14",unread:true,starred:false})
  }
  TestCase {
    name: "MessageRowLayout"
    when: windowShown
    function init() {
      failOnWarning(/Unable to assign|TypeError|ReferenceError/)
      mouseMove(row,-20,-20)
      row.width=600;row.hasCursor=false;row.checked=false;row.conversations=false
      row.attachmentIndicatorEnabled=true;row.overview="";row.overviewState="";row.overviewReason=""
      row.summary={id:"one",subject:"Title",from:{display:"Sender"},time:"09:14",unread:false,starred:false}
      waitForRendering(row)
    }
    function test_attachment_indicator_keeps_line_height_and_text_gap_data() {
      return [{tag:"wide",width:600,actions:false},{tag:"narrow-actions",width:360,actions:true}]
    }
    function test_attachment_indicator_keeps_line_height_and_text_gap(data) {
      row.width=data.width;row.hasCursor=data.actions;row.checked=false
      row.summary={id:"one",subject:"Title",from:{display:"Sender"},time:"09:14",unread:false,starred:false,hasAttachments:false}
      waitForRendering(row)
      var description=findChild(row,"message-description")
      var glyph=findChild(row,"message-attachment-indicator")
      var before=description.mapToItem(row,0,0)
      var heightBeforePixels=row.height
      var lineHeightPixels=description.height
      var subject=findChild(row,"message-subject").mapToItem(row,0,0)
      compare(glyph.visible,false)
      row.summary=Object.assign({},row.summary,{hasAttachments:true})
      waitForRendering(row)
      compare(glyph.visible,true)
      compare(row.height,heightBeforePixels)
      compare(description.height,lineHeightPixels)
      compare(description.mapToItem(row,0,0).y,before.y)
      compare(findChild(row,"message-subject").mapToItem(row,0,0).y,subject.y)
      verify(glyph.height<=description.height)
      verify(glyph.height<=description.font.pixelSize)
      var time=findChild(row,"message-time")
      verify(time.x-glyph.x-glyph.width>=8,"the paperclip has right-hand breathing room")
      verify(Math.abs(glyph.mapToItem(row,0,glyph.height/2).y
        - findChild(row,"message-sender").mapToItem(row,0,findChild(row,"message-sender").height/2).y) < 0.01)
      row.attachmentIndicatorEnabled=false
      compare(glyph.visible,false)
      compare(description.mapToItem(row,0,0).x,before.x)
      row.attachmentIndicatorEnabled=true
    }
    function test_long_failure_tooltip_fits_a_narrow_row() {
      row.width=360;row.hasCursor=false
      row.overview="";row.overviewState="failed"
      row.overviewReason="AI response could not be verified against the mail; retry from Menu"
      waitForRendering(row)
      var description=findChild(row,"message-subject")
      mouseMove(description,5,5)
      var tooltip=findChild(row,"overview-tooltip")
      tryCompare(tooltip,"visible",true)
      verify(tooltip.width<=row.width)
      compare(tooltip.contentItem.textFormat,Text.PlainText)
      compare(tooltip.contentItem.wrapMode,Text.WordWrap)
      verify(tooltip.contentItem.height>tooltip.fontSize*1.5)
      mouseMove(row,-20,-20)
      row.overviewState="";row.overviewReason=""
    }
    function test_phase_four_tools_and_failure_detail() {
      row.hasCursor=true
      row.overview=""
      row.overviewState="failed"
      row.overviewReason="AI response could not be verified against the mail; retry from Menu"
      row.summary={id:"one",subject:"Title",from:{display:"Sender"},time:"09:14",unread:false,starred:false,sourceLabel:"Personal"}
      waitForRendering(row)
      var time=findChild(row,"message-time")
      compare(findChild(row,"message-source"),null)
      compare(Math.round(time.x+time.width),Math.round(time.parent.width))
      var actions=findChild(row,"message-actions")
      var unread=findChild(row,"message-mark-unread")
      compare(actions.spacing,unread.width*0.15)
      compare(findChild(row,"message-subject").text,"Title")
      compare(findChild(row,"message-description").visible,false)
      row.overviewState="";row.overviewReason="";row.hasCursor=false
    }
    function test_description_replaces_subject_and_preview_without_colliding_with_actions() {
      row.width=360;row.hasCursor=true
      row.summary={id:"one",subject:"Original subject",snippet:"Old preview",from:{display:"Sender"},time:"Yesterday",unread:true,hasAttachments:true}
      row.overview="Reminder — Your electricity bill for the garden office was due yesterday"
      waitForRendering(row)
      var subject=findChild(row,"message-subject"),actions=findChild(row,"message-actions")
      compare(subject.text,row.overview)
      compare(subject.textFormat,Text.PlainText)
      compare(findChild(row,"message-description").visible,false)
      verify(subject.lineCount>1)
      verify(subject.mapToItem(row,subject.width,0).x<=actions.x)
      verify(subject.mapToItem(row,0,subject.height).y<=row.height-6)
      row.overview=""
      compare(subject.text,"Original subject")
      compare(findChild(row,"message-description").visible,true)
    }
    function test_time_stays_fixed_when_actions_appear() {
      row.hasCursor=false
      row.checked=false
      row.width=600
      row.summary={id:"one",subject:"Title",from:{display:"Sender"},snippet:"Description",time:"Sep 10, 2025",unread:false,starred:false}
      mouseMove(row, -20, -20)
      waitForRendering(row)
      var time=findChild(row,"message-time")
      var before=time.mapToItem(row,0,0)
      row.hasCursor=true
      waitForRendering(row)
      compare(time.mapToItem(row,0,0).x,before.x)
      compare(time.mapToItem(row,0,0).y,before.y)
      row.hasCursor=false
      row.checked=true
      waitForRendering(row)
      compare(time.mapToItem(row,0,0).x,before.x)
      compare(time.mapToItem(row,0,0).y,before.y)
      var check=findChild(row,"message-check")
      var subject=findChild(row,"message-subject")
      var description=findChild(row,"message-description")
      verify(check.visible)
      compare(Math.round(check.mapToItem(row,0,check.height/2).y),
        Math.round((subject.mapToItem(row,0,0).y+description.mapToItem(row,0,description.height).y)/2))
      row.checked=false
    }
    function test_sender_and_time_lead_title_and_description_data() {
      return [{tag:"normal",width:600,actions:false,source:"",conversation:false},
        {tag:"actions",width:360,actions:true,source:"Webscape",conversation:false},
        {tag:"unified-conversation",width:360,actions:true,source:"Personal mailbox with a long name",conversation:true},
        {tag:"selected",width:360,actions:true,source:"",conversation:false,checked:true},
        {tag:"rtl",width:360,actions:false,source:"",conversation:false,rtl:true}]
    }
    function test_sender_and_time_lead_title_and_description(data) {
      row.width=data.width
      row.hasCursor=data.actions
      row.conversations=data.conversation
      row.checked=!!data.checked
      row.summary={id:"one",subject:data.rtl?"Re: مرحبا بالعالم":"Title",subjectDirection:data.rtl?"rtl":"ltr",
        from:{display:data.rtl?"محمد":"Sender with a longer display name"},snippet:"Description",time:"09:14",unread:true,starred:false,
        sourceLabel:data.source,thread:data.conversation?{id:"thread",memberIds:["one","two"],count:2,total:2}:null}
      waitForRendering(row)
      var sender=findChild(row,"message-sender")
      var time=findChild(row,"message-time")
      var subject=findChild(row,"message-subject")
      var description=findChild(row,"message-description")
      var senderPoint=sender.mapToItem(row,0,0)
      var timePoint=time.mapToItem(row,0,0)
      var subjectPoint=subject.mapToItem(row,0,0)
      var descriptionPoint=description.mapToItem(row,0,0)
      compare(Math.round(senderPoint.y+sender.baselineOffset),Math.round(timePoint.y+time.baselineOffset))
      verify(subjectPoint.y>=senderPoint.y+sender.height,"title occupies the second line")
      verify(descriptionPoint.y>=subjectPoint.y+subject.height,"description occupies the third line")
      var actions=findChild(row,"message-actions")
      if(actions.visible)
        compare(Math.round(actions.y+actions.height/2),Math.round((subjectPoint.y+descriptionPoint.y+description.height)/2),"actions center on title and description")
      verify(timePoint.x+time.width>=subjectPoint.x+subject.width,"time stays at the full row edge")
      var trash=findChild(row,"message-trash")
      if(trash.visible) verify(trash.iconSize>25,"tools use enlarged icons")
      if(!actions.visible) {
        compare(Math.round(timePoint.x+time.width),Math.round(subjectPoint.x+subject.width))
        verify(descriptionPoint.x+description.width<=timePoint.x-8,"overview stops before the date")
      }
      verify(sender.width>0)
      verify(senderPoint.x+sender.width<=timePoint.x)
      compare(subject.font.bold,false,"unread text uses the regular weight")
      compare(subject.marked,true,"the marker identifies unread mail")
      verify(subject.bands.length > 0,"the marker follows the laid-out text")
      compare(subject.textFormat,Text.PlainText)
      compare(subject.effectiveHorizontalAlignment,data.rtl?Text.AlignRight:Text.AlignLeft)
      compare(findChild(row,"message-source"),null)
      compare(findChild(row,"message-conversation-count").visible,data.conversation)
    }
  }
}
