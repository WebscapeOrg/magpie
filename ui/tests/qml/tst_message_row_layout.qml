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
    function test_long_failure_tooltip_fits_a_narrow_row() {
      row.width=360;row.hasCursor=false
      row.overview="";row.overviewState="failed"
      row.overviewReason="AI response could not be verified against the mail; retry from Menu"
      waitForRendering(row)
      var description=findChild(row,"message-description")
      mouseMove(description,5,5)
      var tip=findChild(row,"overview-tooltip")
      tryCompare(tip,"visible",true)
      verify(tip.width<=row.width)
      compare(tip.contentItem.textFormat,Text.PlainText)
      compare(tip.contentItem.wrapMode,Text.WordWrap)
      verify(tip.contentItem.height>tip.fontSize*1.5)
      mouseMove(row,-20,-20)
      row.overviewState="";row.overviewReason=""
    }
    function test_phase_four_tools_and_failure_detail() {
      row.hasCursor=true
      row.overview=""
      row.overviewState="failed"
      row.overviewReason="AI response could not be verified against the mail; retry from Menu"
      row.summary={id:"one",subject:"Title",from:{display:"Sender"},time:"09:14",sourceLabel:"Personal"}
      waitForRendering(row)
      var source=findChild(row,"message-source")
      var time=findChild(row,"message-time")
      verify(source.mapToItem(row,0,0).x > time.mapToItem(row,time.width,0).x)
      var actions=findChild(row,"message-actions")
      var unread=findChild(row,"message-mark-unread")
      compare(actions.spacing,unread.width*0.15)
      verify(findChild(row,"message-description").text.indexOf(row.overviewReason)>=0)
      row.overviewState="";row.overviewReason="";row.hasCursor=false
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
        {tag:"actions",width:360,actions:true,source:"",conversation:false},
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
        var source=findChild(row,"message-source")
        var edge=source.visible ? source.mapToItem(row,source.width,0).x : timePoint.x+time.width
        compare(Math.round(edge),Math.round(subjectPoint.x+subject.width))
        verify(descriptionPoint.x+description.width<=timePoint.x-8,"overview stops before the date")
      }
      verify(sender.width>0)
      verify(senderPoint.x+sender.width<=timePoint.x)
      compare(subject.font.bold,true,"unread emphasis survives reordering")
      compare(subject.textFormat,Text.PlainText)
      compare(subject.effectiveHorizontalAlignment,data.rtl?Text.AlignRight:Text.AlignLeft)
      compare(findChild(row,"message-source").visible,data.source!=="")
      compare(findChild(row,"message-conversation-count").visible,data.conversation)
      if(data.source!=="")verify(findChild(row,"message-source").width<=row.width/3)
    }
  }
}
