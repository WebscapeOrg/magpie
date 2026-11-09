import QtQuick
import QtTest
import "../../components" as Components
import "../../inbox" as Inbox
import "../../inbox/Bundles.js" as Bundles

// Invariant: bundles shape the Inbox only, every mail in a bundled row is acted on together, and an
// answer that is missing or fails leaves one row per mail.
Item {
  id: canvas
  width: 900
  height: 700

  QtObject {
    id: host
    property string accountId: "dave@example.org"
    property string providerId: "gmail"
    property var previewMessages: []
    property var messages: []
    property var local: QtObject {
      property var cancelled: []
      property var refuseTickets: []
      function cancelEdits(tickets, callback) {
        cancelled = cancelled.concat(tickets)
        var refused = tickets.filter(function(ticket) { return refuseTickets.indexOf(ticket) >= 0 }).length
        Qt.callLater(function() { callback(refused) })
      }
    }
    function hydrateSummary(row) { row.time = "Yesterday"; return row }
    function refresh() {}
    function select(id, previewOnly) { canvas.opened = canvas.opened.concat([id]) }
  }

  QtObject {
    id: backend
    property bool ready: false
    property int apiVersion: 8
    property var protocolInfo: ({methods: ["inbox.bundles"]})
    property var calls: []
    function call(method, params, done) { calls = calls.concat([{method: method, params: params, done: done}]) }
    function answerAll(method, result, failure) {
      var pending = calls.filter(function(request) { return request.method === method && !request.answered })
      for (var index = 0; index < pending.length; index++) { pending[index].answered = true; pending[index].done(result, failure) }
      return pending.length
    }
    function of(method) { return calls.filter(function(request) { return request.method === method }) }
  }

  QtObject {
    id: service
    property var backend: backend
    property bool curatedInbox: true
    property bool windowOpen: true
    property bool unified: false
    property string activeAccountId: host.accountId
    property var accountSummaries: [{id: host.accountId}]
    property var rawMessages: []
    readonly property var messages: tools.stack.messages
    property var actManyCalls: []
    property bool actManyStarts: true
    property var toasts: []
    readonly property var inboxTools: tools
    property string selectedId: ""
    property bool canArchive: true
    property bool listLoading: false
    property bool listLoaded: true
    property bool hasMore: false
    property string mailboxKey: "inbox"
    function hostForId(id) { return host }
    function findAccount(id) { return id === host.accountId ? host : null }
    function sourceIdFor(id) { return String(id) }
    function refresh() {}
    function actMany(ids, action, completion) {
      actManyCalls = actManyCalls.concat([{ids: ids, action: action, helpers: host.previewMessages.map(function(row) { return row.id })}])
      if (!actManyStarts) return false
      if (typeof completion === "function") completion({failedIds: [], tickets: []})
      return true
    }
  }

  property var opened: []
  Inbox.InboxTools {
    id: tools
    service: service
    visibleRows: service.messages
  }

  Components.MessageList {
    id: list
    width: 760
    height: 600
    service: service
    textColor: Qt.rgba(0,0,0,1)
    accentColor: Qt.rgba(0,0.5,0,1)
    dimColor: Qt.rgba(0.5,0.5,0.5,1)
    urgentColor: Qt.rgba(0.7,0,0,1)
    panelFontFamily: "sans-serif"
  }

  Components.MessageRow {
    id: narrowRow
    width: 320
    textColor: Qt.rgba(0,0,0,1)
    accentColor: Qt.rgba(0,0.5,0,1)
    dimColor: Qt.rgba(0.5,0.5,0.5,1)
    panelFontFamily: "sans-serif"
    summary: ({id:"front",from:{display:"Uptime"},time:"09:14",bundleCount:3,unread:true})
  }

  Components.ApprovedSenders {
    id: settings
    width: 400
    service: service
    textColor: Qt.rgba(0,0,0,1)
    dimColor: Qt.rgba(0.5,0.5,0.5,1)
    accentColor: Qt.rgba(0,0.5,0,1)
    panelFontFamily: "sans-serif"
  }

  function setRows(rows) {
    var prepared = ({})
    for (var index = 0; index < rows.length; index++) prepared[host.accountId + "\n" + rows[index].id] = {state:"ready",version:2,text:"Point for " + rows[index].id,expiresAt:0}
    tools.overviews = Object.assign({}, tools.overviews, prepared)
    service.rawMessages = rows
  }

  function mail(id, opts) {
    return Object.assign({id:id,threadId:"t-"+id,from:{display:"Sender "+id,email:id+"@example.com"},subject:"Subject "+id,time:"09:00",unread:false,labelIds:["INBOX"]}, opts||{})
  }

  Component {
    id: railComponent
    Components.ConversationRail {
      width: 300
      height: 300
      caption: "Also in this Point"
      textColor: Qt.rgba(0,0,0,1)
      backgroundColor: Qt.rgba(1,1,1,1)
      accentColor: Qt.rgba(0,0.5,0,1)
      dimColor: Qt.rgba(0.5,0.5,0.5,1)
      dimmerColor: Qt.rgba(0.7,0.7,0.7,1)
      panelFontFamily: "sans-serif"
    }
  }

  Component {
    id: toastComponent
    Components.UndoToast {
      message: "Archived 2 messages"
      textColor: Qt.rgba(0,0,0,1)
      accentColor: Qt.rgba(0,0.5,0,1)
      popupBackgroundColor: Qt.rgba(1,1,1,1)
      popupBorderColor: Qt.rgba(0.5,0.5,0.5,1)
      panelFontFamily: "sans-serif"
    }
  }

  TestCase {
    name: "InboxBundles"
    when: windowShown

    function init() {
      backend.ready = false
      backend.calls = []
      backend.apiVersion = 8
      backend.protocolInfo = ({methods: ["inbox.bundles"]})
      tools.descriptionsEnabled = true
      service.curatedInbox = true
      service.mailboxKey = "inbox"
      service.selectedId = ""
      service.actManyCalls = []
      canvas.opened = []
      canvas.setRows([])
      tools.bundles.states = ({})
      tools.bundles.fetched = ({})
      tools.bundles.answered = ({})
      tools.bundles.inflight = ({})
      tools.bundles.dirty = ({})
      tools.bundles.failures = ({})
      tools.bundles.fetchesInflight = ({})
      tools.bundles.dismissUndo()
      host.local.cancelled = []
      host.local.refuseTickets = []
      host.previewMessages = []
      settings.senders = []
      backend.ready = true
    }

    function waitAndAnswer(state) {
      tryVerify(function() { return backend.of("inbox.bundles").some(function(call) { return !call.answered }) })
      backend.answerAll("inbox.bundles", state)
      wait(0)
    }

    function seedBundle() {
      canvas.setRows([mail("front", {unread: false}), mail("older", {unread: true}), mail("oldest")])
      tools.refresh()
      waitAndAnswer({bundles:[{front:"front",covered:["older","oldest"]}],proposals:[]})
      compare(service.messages.length, 1)
    }

    function test_hides_covered_rows_and_shows_a_count() {
      seedBundle()
      compare(service.messages[0].id, "front")
      compare(service.messages[0].bundleCount, 3)
      list.forceLayout(); waitForRendering(list)
      var row = list.itemAtIndex(0)
      compare(row.bundleCount, 3)
      var badge = findChild(row, "message-bundle-count")
      verify(badge.visible)
    }

    function test_row_is_unread_when_any_mail_in_it_is_unread() {
      seedBundle()
      compare(service.messages[0].unread, true, "the older mail is unread")
      canvas.setRows([mail("front", {unread: false}), mail("older", {unread: false}), mail("oldest")])
      wait(0)
      compare(service.messages[0].unread, false)
    }

    function test_covered_rows_stay_when_their_front_is_not_loaded() {
      canvas.setRows([mail("older"), mail("oldest")])
      tools.refresh()
      waitAndAnswer({bundles:[{front:"not-loaded",covered:["older"]}],proposals:[]})
      compare(service.messages.length, 2)
    }

    function test_search_labels_and_original_subjects_keep_one_row_per_mail() {
      seedBundle()
      service.curatedInbox = false
      wait(0)
      compare(service.messages.length, 3, "search, labels and Sent stay one row per mail")
      service.curatedInbox = true
      wait(0)
      tools.descriptionsEnabled = false
      wait(0)
      compare(service.messages.length, 3, "original subjects stay one row per mail")
    }

    function test_engine_without_bundles_keeps_one_row_per_mail() {
      backend.ready = false
      backend.protocolInfo = ({methods: ["inbox.snapshot"]})
      backend.ready = true
      backend.calls = []
      canvas.setRows([mail("front"), mail("older")])
      tools.refresh()
      wait(0)
      compare(service.messages.length, 2)
      compare(backend.of("inbox.bundles").length, 0, "an engine without the method is never asked")
    }

    function test_older_api_keeps_one_row_per_mail() {
      backend.ready = false
      backend.apiVersion = 7
      backend.ready = true
      backend.calls = []
      canvas.setRows([mail("front"), mail("older")])
      tools.refresh()
      wait(0)
      compare(service.messages.length, 2)
      compare(backend.of("inbox.bundles").length, 0)
    }

    function test_failed_first_answer_keeps_one_row_per_mail() {
      canvas.setRows([mail("front"), mail("older")])
      tools.refresh()
      tryVerify(function() { return backend.of("inbox.bundles").length > 0 })
      backend.answerAll("inbox.bundles", null, {message:"inbox_storage_invalid"})
      wait(0)
      compare(service.messages.length, 2)
    }

    function test_rows_hold_until_the_first_answer_then_settle_without_jumping() {
      canvas.setRows([mail("front"), mail("older")])
      tools.refresh()
      compare(service.messages.length, 0, "rows wait for the first bundles answer")
      verify(tools.bundles.holding)
      waitAndAnswer({bundles:[{front:"front",covered:["older"]}],proposals:[]})
      compare(service.messages.length, 1, "the covered mail never shows as its own row")
      verify(!tools.bundles.holding)
    }

    function test_refresh_keeps_the_bundle_until_a_new_answer_arrives() {
      seedBundle()
      tools.bundles.refresh(host.accountId)
      compare(service.messages.length, 1, "no flicker while the next answer is awaited")
      backend.answerAll("inbox.bundles", {bundles:[],proposals:[]})
      wait(0)
      compare(service.messages.length, 3)
    }

    function test_refusal_and_not_the_same_point_restore_rows() {
      seedBundle()
      list.forceLayout(); waitForRendering(list)
      verify(tools.bundles.notTheSamePoint("front"))
      var refuse = backend.of("inbox.refuseBundle")[0]
      compare(refuse.params.accountId, host.accountId)
      compare(refuse.params.ids.slice().sort(), ["older","oldest"])
      refuse.done({bundles:[],proposals:[]})
      wait(0)
      compare(service.messages.length, 3, "the older mails are rows again")
    }

    function test_many_covered_mails_are_refused_in_chunks_of_sixty_four() {
      var covered = []
      for (var i = 0; i < 70; i++) covered.push("m" + i)
      compare(Bundles.chunks(covered, 64).map(function(part) { return part.length }), [64, 6])
    }

    function test_proposal_keeps_two_rows_and_approves_or_dismisses() {
      canvas.setRows([mail("newer"), mail("other")])
      tools.refresh()
      waitAndAnswer({bundles:[],proposals:[{front:"newer",covered:["other"],sender:{email:"a@b.c",name:"A"}}]})
      compare(service.messages.length, 2)
      list.forceLayout(); waitForRendering(list)
      var row = list.itemAtIndex(0)
      var lane = findChild(row, "bundle-proposal")
      verify(lane.visible)
      compare(findChild(row, "bundle-question").text, "Bundle these?")
      mouseClick(findChild(row, "bundle-approve"))
      var approve = backend.of("inbox.approveBundle")[0]
      compare(approve.params, {accountId: host.accountId, front: "newer"})
      approve.done({bundles:[{front:"newer",covered:["other"]}],proposals:[]})
      wait(0)
      compare(service.messages.length, 1, "approving bundles them")
    }

    function test_proposal_dismiss_refuses_and_keeps_the_rows() {
      canvas.setRows([mail("newer"), mail("other")])
      tools.refresh()
      waitAndAnswer({bundles:[],proposals:[{front:"newer",covered:["other"],sender:{email:"a@b.c",name:"A"}}]})
      list.forceLayout(); waitForRendering(list)
      mouseClick(findChild(list.itemAtIndex(0), "bundle-dismiss"))
      var refuse = backend.of("inbox.refuseBundle")[0]
      compare(refuse.params.ids, ["other"])
      refuse.done({bundles:[],proposals:[]})
      wait(0)
      compare(service.messages.length, 2)
      verify(!findChild(list.itemAtIndex(0), "bundle-proposal").visible)
    }

    function test_row_height_does_not_change_on_hover_with_a_bundle_and_a_proposal_data() {
      return [{tag:"bundle", bundle:true},{tag:"proposal", bundle:false}]
    }
    function test_row_height_does_not_change_on_hover_with_a_bundle_and_a_proposal(data) {
      service.rawMessages = data.bundle ? [mail("front"), mail("older")] : [mail("newer"), mail("other")]
      tools.refresh()
      waitAndAnswer(data.bundle ? {bundles:[{front:"front",covered:["older"]}],proposals:[]}
        : {bundles:[],proposals:[{front:"newer",covered:["other"],sender:{email:"a@b.c",name:"A"}}]})
      list.forceLayout(); waitForRendering(list)
      var row = list.itemAtIndex(0)
      mouseMove(row, -20, -20); waitForRendering(row)
      var rest = row.implicitHeight
      mouseMove(row, row.width / 2, 10); waitForRendering(row)
      verify(findChild(row, "message-actions").visible, "the tools appear")
      compare(row.implicitHeight, rest, "hovering must not change the row's height")
      mouseMove(row, -20, -20)
    }

    function test_narrow_row_keeps_the_badge_clear_of_the_text_and_time() {
      narrowRow.summary = ({id:"front",from:{display:"A long sender name that needs to shorten itself here"},time:"09:14",bundleCount:3,unread:true})
      waitForRendering(narrowRow)
      var badge = findChild(narrowRow, "message-bundle-count")
      var sender = findChild(narrowRow, "message-sender")
      var time = findChild(narrowRow, "message-time")
      verify(badge.visible)
      verify(sender.x + sender.width <= badge.x + 0.5, "the name stops before the badge")
      verify(badge.x + badge.width <= time.x, "the badge stays clear of the time")
    }

    function test_hostile_sender_name_stays_plain_text() {
      narrowRow.summary = ({id:"front",from:{display:"<b>x</b>"},time:"09:14",bundleCount:2,unread:true})
      waitForRendering(narrowRow)
      compare(findChild(narrowRow, "message-sender").text, "<b>x</b>")
      compare(findChild(narrowRow, "message-sender").textFormat, Text.PlainText)
    }

    function test_opening_a_bundled_row_marks_every_mail_read() {
      seedBundle()
      tools.bundles.markRead("front")
      compare(service.actManyCalls.length, 1)
      compare(service.actManyCalls[0].action, "markRead")
      compare(service.actManyCalls[0].ids, ["older"], "only the unread older mail needs marking")
    }

    function test_mail_outside_the_page_is_added_only_while_it_is_marked_read() {
      backend.ready = true
      host.previewMessages = []
      canvas.setRows([mail("front")])
      tools.refresh()
      waitAndAnswer({bundles:[{front:"front",covered:["far"]}],proposals:[]})
      backend.answerAll("local.summaries", {summaries:[mail("far",{unread:true})]})
      wait(0)
      tools.bundles.markRead("front")
      compare(service.actManyCalls[0].ids, ["far"])
      compare(service.actManyCalls[0].helpers, ["far"], "the action can find it")
      compare(host.previewMessages.length, 0, "and it is gone again, so the bar never shows it")
    }

    function test_reader_lists_the_others_by_sender_time_and_subject() {
      seedBundle()
      var stops = tools.bundles.readerStops("front")
      compare(stops.map(function(stop) { return stop.id }), ["older", "oldest"])
      compare(stops[0].sender, "Sender older")
      compare(stops[0].subject, "Subject older")
      verify(!stops[0].point, "subjects, never Points")
    }

    function test_action_plan_reaches_every_mail_and_failures_map_to_their_row() {
      seedBundle()
      var plan = tools.bundles.planAction(["front", "alone"], "archive")
      compare(plan.ids, ["front", "older", "oldest", "alone"])
      verify(plan.bundled)
      compare(Bundles.mapFailed(["front","older"], plan.frontOf), ["front"], "a failed row keeps its older mail with it")
      compare(Bundles.mapFailed(["older"], plan.frontOf), ["older"], "with the front gone the older mail comes back as its own row")
      var star = tools.bundles.planAction(["front"], "star")
      compare(star.ids, ["front"], "star is per mail")
    }

    function test_undo_names_the_count_and_says_so_when_too_late() {
      seedBundle()
      tools.bundles.offerEdits("archive", 3, [{accountId: host.accountId, tickets: ["t1"]}])
      compare(tools.bundles.undoOffer.text, "Archived 3 messages")
      verify(tools.bundles.runUndo())
      compare(host.local.cancelled, ["t1"])
      tryVerify(function() { return tools.bundles.undoOffer === null })
      tools.bundles.offerEdits("trash", 3, [{accountId: host.accountId, tickets: ["t2","t3"]}])
      compare(tools.bundles.undoOffer.text, "Moved 3 messages to trash")
      host.local.refuseTickets = ["t2"]
      tools.bundles.runUndo()
      tryVerify(function() { return tools.bundles.undoOffer && !tools.bundles.undoOffer.canUndo })
      compare(tools.bundles.undoOffer.text, "1 of 2 had already reached Gmail, so they stayed. Find them in Trash and restore them.")
    }

    function test_snooze_acts_on_every_mail_once_per_thread_with_undo_naming_the_count() {
      seedBundle()
      canvas.setRows([mail("front"), mail("older",{threadId:"shared"}), mail("oldest",{threadId:"shared"})])
      wait(0)
      verify(tools.snooze("front", Date.now()+3600000))
      var snoozes = backend.of("inbox.snooze")
      compare(snoozes.length, 2, "two mails in one thread snooze once")
      for (var i = 0; i < snoozes.length; i++) snoozes[i].done({ok:true})
      compare(tools.bundles.undoOffer.text, "Snoozed 3 messages")
      compare(tools.bundles.undoOffer.entries.length, 2)
      tools.bundles.runUndo()
      compare(backend.of("inbox.wake").length, 2)
    }

    function test_report_spam_and_move_to_label_stay_on_the_front_mail_data() {
      return [{tag:"spam",action:"spam"},{tag:"label",action:"label:Label_1"}]
    }
    function test_report_spam_and_move_to_label_stay_on_the_front_mail(data) {
      seedBundle()
      var plan = tools.bundles.planAction(["front"], data.action)
      compare(plan.ids, ["front"], "Q-020 decided only the actions Undo can restore")
      verify(!plan.bundled)
    }

    function test_refusing_many_covered_mails_sends_every_chunk() {
      var covered = []
      for (var i = 0; i < 70; i++) covered.push("m" + i)
      backend.ready = true
      verify(tools.bundles.refuseIds(host.accountId, covered))
      compare(backend.of("inbox.refuseBundle").length, 1, "one chunk at a time")
      compare(backend.of("inbox.refuseBundle")[0].params.ids.length, 64)
      backend.of("inbox.refuseBundle")[0].done({bundles:[],proposals:[]})
      compare(backend.of("inbox.refuseBundle").length, 2)
      compare(backend.of("inbox.refuseBundle")[1].params.ids.length, 6)
    }

    function test_an_answer_from_before_a_refusal_cannot_bring_the_bundle_back() {
      seedBundle()
      tools.bundles.refresh(host.accountId)
      var stale = backend.of("inbox.bundles").filter(function(call) { return !call.answered })[0]
      verify(tools.bundles.notTheSamePoint("front"))
      backend.of("inbox.refuseBundle")[0].done({bundles:[],proposals:[]})
      wait(0)
      compare(service.messages.length, 3, "the refusal shows at once")
      stale.answered = true
      stale.done({bundles:[{front:"front",covered:["older","oldest"]}],proposals:[]})
      wait(0)
      compare(service.messages.length, 3, "the older answer is dropped")
      var again = backend.of("inbox.bundles").filter(function(call) { return !call.answered })
      compare(again.length, 1, "and asked for again")
    }

    function test_three_failed_answers_in_a_row_fall_back_to_one_row_per_mail() {
      seedBundle()
      for (var attempt = 1; attempt <= 3; attempt++) {
        tools.bundles.refresh(host.accountId)
        compare(service.messages.length, attempt === 1 ? 1 : (attempt === 2 ? 1 : 1))
        backend.answerAll("inbox.bundles", null, {message:"inbox_storage_invalid"})
        wait(0)
        compare(service.messages.length, attempt < 3 ? 1 : 3, "after failure " + attempt)
      }
    }

    function test_undo_pressed_twice_cancels_once() {
      seedBundle()
      host.local.cancelled = []
      host.local.refuseTickets = []
      tools.bundles.offerEdits("archive", 3, [{accountId: host.accountId, tickets: ["t9"]}])
      verify(tools.bundles.runUndo())
      verify(!tools.bundles.runUndo(), "the second press does nothing while the first runs")
      compare(host.local.cancelled, ["t9"])
      tryVerify(function() { return tools.bundles.undoOffer === null })
    }

    function test_a_snooze_undo_on_mail_already_back_is_not_called_a_failure() {
      seedBundle()
      tools.bundles.offerSnooze(3, [{accountId: host.accountId, id: "front"}])
      verify(tools.bundles.runUndo())
      backend.of("inbox.wake").slice(-1)[0].done(null, {message:"snooze_missing"})
      compare(tools.bundles.undoOffer, null)
    }

    function test_a_snooze_undo_that_breaks_does_not_blame_gmail() {
      seedBundle()
      tools.bundles.offerSnooze(3, [{accountId: host.accountId, id: "front"}])
      verify(tools.bundles.runUndo())
      backend.of("inbox.wake").slice(-1)[0].done(null, {message:"engine_gone"})
      compare(tools.bundles.undoOffer.canUndo, false)
      compare(tools.bundles.undoOffer.text, "Undo could not finish. Find them under Snoozed mail.")
      tools.bundles.dismissUndo()
    }

    function test_a_partly_failed_snooze_counts_the_mails_that_went() {
      canvas.setRows([mail("front"), mail("older",{threadId:"shared"}), mail("oldest",{threadId:"shared"})])
      tools.refresh()
      waitAndAnswer({bundles:[{front:"front",covered:["older","oldest"]}],proposals:[]})
      verify(tools.snooze("front", Date.now()+3600000))
      var snoozes = backend.of("inbox.snooze")
      compare(snoozes.length, 2)
      snoozes[0].done(null, {message:"gmail_failed"})
      snoozes[1].done({ok:true})
      compare(tools.bundles.undoOffer.text, "Snoozed 2 messages", "both mails of the shared thread went")
      tools.bundles.dismissUndo()
      tools.error = ""
    }

    function test_narrow_proposal_keeps_its_buttons_on_the_row_data() {
      return [{tag:"at-rest",hover:false},{tag:"under-the-pointer",hover:true}]
    }
    function test_narrow_proposal_keeps_its_buttons_on_the_row(data) {
      narrowRow.summary = ({id:"newer",from:{display:"A sender"},time:"09:14",bundleProposal:true})
      waitForRendering(narrowRow)
      mouseMove(narrowRow, data.hover ? narrowRow.width / 2 : -20, data.hover ? 10 : -20)
      waitForRendering(narrowRow)
      var approve = findChild(narrowRow, "bundle-approve"), dismiss = findChild(narrowRow, "bundle-dismiss")
      var actions = findChild(narrowRow, "message-actions")
      var right = dismiss.mapToItem(narrowRow, dismiss.width, 0).x
      var left = approve.mapToItem(narrowRow, 0, 0).x
      verify(left >= 0, "Bundle starts on the row")
      verify(right <= narrowRow.width, "Dismiss ends on the row: " + right)
      if (actions.visible) verify(right <= actions.mapToItem(narrowRow, 0, 0).x, "Dismiss stays clear of the tools")
      mouseMove(narrowRow, -20, -20)
    }

    function test_hostile_sender_and_subject_stay_plain_in_also_in_this_point() {
      var stops = Bundles.readerStops({members: [
        {id:"front", summary:{}},
        {id:"older", summary:{from:{display:"<b>x</b>"},time:"09:00",subject:"<img src=x>"}}]}, "front")
      var rail = createTemporaryObject(railComponent, canvas, {stops: stops})
      verify(rail)
      waitForRendering(rail)
      var seen = []
      function walk(item) {
        if (item.textFormat !== undefined && (item.text === "<b>x</b>" || item.text === "<img src=x>")) seen.push(item)
        for (var i = 0; i < item.children.length; i++) walk(item.children[i])
      }
      walk(rail)
      verify(seen.length >= 2, "both the sender and the subject were found: " + seen.length)
      seen.forEach(function(item) { compare(item.textFormat, Text.PlainText) })
    }

    function test_an_answer_sent_before_the_engine_wrote_an_approval_cannot_bring_the_proposal_back() {
      canvas.setRows([mail("newer"), mail("other")])
      tools.refresh()
      var offerState = {bundles:[],proposals:[{front:"newer",covered:["other"],sender:{email:"a@b.c",name:"A"}}]}
      waitAndAnswer(offerState)
      while (backend.answerAll("inbox.bundles", offerState) > 0) wait(0)
      verify(tools.bundles.approve("newer"))
      tools.bundles.refresh(host.accountId)
      var waiting = backend.of("inbox.bundles").filter(function(call) { return !call.answered })
      compare(waiting.length, 1, "a request sent after the tap, before the engine has written it")
      var stale = waiting[0]
      backend.of("inbox.approveBundle")[0].done({bundles:[{front:"newer",covered:["other"]}],proposals:[]})
      wait(0)
      compare(service.messages.length, 1)
      stale.answered = true
      stale.done(offerState)
      wait(0)
      compare(service.messages.length, 1, "the answer from before the approval is dropped")
    }

    function test_a_slow_undo_leaves_a_newer_toast_alone() {
      seedBundle()
      tools.bundles.offerSnooze(3, [{accountId: host.accountId, id: "front"}])
      verify(tools.bundles.runUndo())
      var wake = backend.of("inbox.wake").slice(-1)[0]
      tools.bundles.offerEdits("archive", 2, [{accountId: host.accountId, tickets: ["t1"]}])
      wake.done({ok:true})
      compare(tools.bundles.undoOffer.text, "Archived 2 messages")
      verify(tools.bundles.undoOffer.canUndo)
      tools.bundles.dismissUndo()
    }

    function test_the_toast_shows_the_key_only_when_it_reaches_this_toast() {
      var toast = createTemporaryObject(toastComponent, canvas, {showsKey: true})
      compare(findChild(toast, "undo-toast-button").text, "Undo  alt+z")
      toast.showsKey = false
      compare(findChild(toast, "undo-toast-button").text, "Undo")
    }

    function test_a_narrow_proposal_stops_short_of_tools_that_stay_showing() {
      narrowRow.summary = ({id:"newer",from:{display:"A sender"},time:"09:14",bundleProposal:true})
      waitForRendering(narrowRow)
      verify(narrowRow.proposalCrowded)
      verify(findChild(narrowRow, "bundle-proposal").clip)
      narrowRow.writing = true
      verify(!narrowRow.proposalCrowded, "no buttons showing, so nothing to make room for")
      narrowRow.writing = false
    }

    function test_snooze_from_an_older_mail_reaches_the_whole_bundle() {
      seedBundle()
      verify(tools.snooze("older", Date.now()+3600000))
      var snoozes = backend.of("inbox.snooze")
      compare(snoozes.length, 3, "every mail of the bundle")
      for (var i = 0; i < snoozes.length; i++) snoozes[i].done({ok:true})
      compare(tools.bundles.undoOffer.text, "Snoozed 3 messages")
      tools.bundles.dismissUndo()
    }

    function test_a_helper_row_is_taken_back_when_mark_read_cannot_start() {
      backend.ready = true
      host.previewMessages = []
      canvas.setRows([mail("front")])
      tools.refresh()
      waitAndAnswer({bundles:[{front:"front",covered:["far"]}],proposals:[]})
      backend.answerAll("local.summaries", {summaries:[mail("far",{unread:true})]})
      wait(0)
      service.actManyStarts = false
      tools.bundles.markRead("front")
      service.actManyStarts = true
      compare(host.previewMessages.length, 0)
    }

    function test_approved_senders_list_and_remove() {
      tryVerify(function() { return backend.of("inbox.approvedSenders").length > 0 })
      var sender = {email:"up@robot.example",name:"<i>Uptime</i>",approved:1}
      backend.of("inbox.approvedSenders").slice(-1)[0].done({senders:[sender]})
      wait(0)
      compare(findChild(settings, "approved-sender-name-0").text, "<i>Uptime</i>")
      compare(findChild(settings, "approved-sender-name-0").textFormat, Text.PlainText)
      mouseClick(findChild(settings, "approved-sender-remove-0"))
      var remove = backend.of("inbox.removeApprovedSender")[0]
      compare(remove.params, {email:"up@robot.example",name:"<i>Uptime</i>"})
      remove.done({senders:[]})
      wait(0)
      compare(settings.senders.length, 0)
      compare(findChild(settings, "approved-senders-empty").visible, true)
    }
  }
}
