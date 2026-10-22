import QtQuick
import "../message/Message.js" as Mail
import "../message/Calendar.js" as Calendar
import "../providers/Registry.js" as Provider
import "../calendar/Calendar.js" as Events

// Invariant: native provider attendance is authoritative; unsupported providers send an RFC 5546 reply.
QtObject {
  id: rsvpAction

  required property var account
  property string reconciledKey: ""
  property bool reconciling: false
  property int attendanceRevision: 0
  property string fallbackMessageId: ""
  readonly property bool fallbackAvailable: (fallbackMessageId !== "" && fallbackMessageId === account.selectedId)
    || (!!account.selectedInvite && account.selectedId !== ""
      && Provider.calendarAttendanceMethod(account.providerId) !== ""
      && !!account.backend && account.backend.ready
      && account.backend.apiVersion > 0 && account.backend.apiVersion < 6)
  property Connections selection: Connections {
    target: rsvpAction.account
    function onSelectedIdChanged() { rsvpAction.reconciledKey = ""; rsvpAction.attendanceRevision++; rsvpAction.fallbackMessageId = "" }
    function onSelectedInviteChanged() { Qt.callLater(rsvpAction.reconcile) }
  }
  property Timer reconcileTimer: Timer {
    interval: 60000
    repeat: true
    running: !!account.selectedInvite && account.ready
    onTriggered: { rsvpAction.reconciledKey = ""; rsvpAction.reconcile() }
  }

  // Invariant: UID and organizer travel together so a forged UID cannot authorize attendance on another organizer’s event.
  function invitationParams(invited) {
    var organizer = Calendar.replyRecipient(invited)
    if (!organizer) return null
    var parameters = { accountId: account.accountId, uid: invited.uid, organizer: organizer }
    if (invited.recurrenceIdMs) {
      parameters.originalStart = new Date(invited.recurrenceIdMs).toISOString()
      var raw = String(invited.source && invited.source.recurrenceId || "")
      var day = /(?:^|;)VALUE=DATE(?:;[^:]*)?:(\d{4})(\d{2})(\d{2})$/.exec(raw)
      if (day) parameters.originalStart = day[1] + "-" + day[2] + "-" + day[3]
    }
    return parameters
  }

  function reconcile() {
    var method = Provider.calendarAttendanceMethod(account.providerId)
    if (!method || !account.selectedInvite || !account.backend || !account.backend.ready
        || account.backend.apiVersion < 6 || reconciling || account.rsvpSending) return
    var invited = account.selectedInvite
    var id = account.selectedId
    var identity = account.accountId
    var revision = attendanceRevision
    var key = identity + "\n" + id + "\n" + invited.uid
    if (key === reconciledKey) return
    reconciledKey = key
    var parameters = invitationParams(invited)
    if (!parameters) return
    reconciling = true
    account.backend.call(method, parameters, function(result, error) {
      rsvpAction.reconciling = false
      if (identity !== account.accountId || id !== account.selectedId || account.rsvpSending
          || revision !== rsvpAction.attendanceRevision) return
      if (error || !result) return
      var updated = {}
      for (var field in invited) updated[field] = invited[field]
      if (result.cancelled) {
        updated.status = "CANCELLED"
        updated.method = "CANCEL"
      } else {
        var normalized = Events.eventsFromGoogle({ items: [result.event] }, "")
        if (!normalized.length) return
        var current = normalized[0]
        var keys = ["summary", "description", "location", "start", "end", "sequence", "status", "meetLink"]
        for (var keyIndex = 0; keyIndex < keys.length; keyIndex++) updated[keys[keyIndex]] = current[keys[keyIndex]]
        updated = Calendar.withResponse(updated, account.receivedAsAddress, String(result.response || "").toUpperCase())
        if (result.response === "needsAction")
          updated.attendees = needsActionAttendees(updated.attendees || [], account.receivedAsAddress)
      }
      rsvpAction.cacheInvite(id, updated)
    })
  }

  function needsActionAttendees(attendees, address) {
    return attendees.map(function(attendee) {
      if (String(attendee.email || "").toLowerCase() !== address.toLowerCase()) return attendee
      var next = {}
      for (var key in attendee) next[key] = attendee[key]
      next.partstat = "NEEDS-ACTION"
      return next
    })
  }

  // Invariant: RSVP completion updates the invitation without triggering compose replySent behavior.
  function run(response, mailOnly) {
    if (!account.ready || account.rsvpSending || !account.canRespondToInvite) return
    var answer = String(response || "")
    var method = Provider.calendarAttendanceMethod(account.providerId)
    if (mailOnly === true && !fallbackAvailable) return
    if (method !== "" && mailOnly !== true) {
      nativeAnswer(method, answer)
      return
    }
    // Invariant: answer as the alias that received the invitation.
    var answeringAs = account.receivedAsAddress
    var answeringName = account.receivedAsName
    var fields = Calendar.replyFields(account.selectedInvite,
      ({ email: answeringAs, name: answeringName }), answer)
    if (!fields) {
      account.fail("This invitation names no organiser to answer")
      return
    }

    // Invariant: late completion updates only the invitation that owned the request.
    var messageId = account.selectedId
    var invited = account.selectedInvite
    var summary = account.selectedMessage
    account.rsvpSending = true
    account.clearNotice()

    account.api.sendMessage(Mail.buildSendPayload({
      // Invariant: the outgoing envelope identity must match the calendar ATTENDEE.
      from: answeringAs,
      fromName: answeringName,
      accountAddress: account.ownAddress,
      to: fields.to,
      subject: fields.subject,
      body: fields.body,
      calendar: fields.calendar,
      // Invariant: thread the response with its original invitation.
      inReplyTo: summary ? summary.messageId : "",
      threadId: summary ? summary.threadId : ""
    }), function(payload, error) {
      account.rsvpSending = false
      if (error) {
        account.fail(error)
        return
      }
      account.note(mailOnly === true ? "Reply email sent; Calendar attendance is not confirmed" : "Answer sent to " + fields.to)
      if (mailOnly === true) return
      if (account.selectedId !== messageId) return
      rememberResponse(messageId, invited, answeringAs, answer)
    })
  }

  function nativeAnswer(method, answer) {
    attendanceRevision++
    if (!account.backend || !account.backend.ready || account.backend.apiVersion < 6) {
      account.fail("Update the backend to answer this invitation in Calendar")
      return
    }
    var response = Calendar.normalizedResponse(answer)
    if (!response) return
    var invited = account.selectedInvite
    var messageId = account.selectedId
    var identity = account.accountId
    var answeringAs = account.receivedAsAddress
    var parameters = invitationParams(invited)
    if (!parameters) {
      account.fail("This invitation names no organiser to answer")
      return
    }
    parameters.response = response
    account.rsvpSending = true
    account.clearNotice()
    account.backend.call(method, parameters, function(result, error) {
      account.rsvpSending = false
      if (identity !== account.accountId) return
      if (error || !result || result.response !== response) {
        if (error && (error.message === "calendar_invitation_not_found"
            || error.message === "calendar_organizer_mismatch") && account.selectedId === messageId)
          rsvpAction.fallbackMessageId = messageId
        account.fail("Calendar has not confirmed your answer. Refresh the invitation or open it in Calendar.")
        return
      }
      account.note("Attendance confirmed in Calendar")
      rsvpAction.fallbackMessageId = ""
      if (account.selectedId === messageId)
        rememberResponse(messageId, invited, answeringAs, answer)
    })
  }

  // Invariant: cache the response separately because the organizer’s attachment remains unchanged.
  function rememberResponse(messageId, invited, answeringAs, answer) {
    var updated = Calendar.withResponse(invited, answeringAs, answer)
    cacheInvite(messageId, updated)
  }

  function cacheInvite(messageId, updated) {
    account.selectedInvite = updated
    account.bodies.put(messageId, ({
      text: account.selectedBody.text,
      source: account.selectedBody.source,
      html: "",
      attachments: account.selectedAttachments,
      images: account.selectedImages,
      invite: updated,
      unsubscribe: account.selectedUnsubscribe
    }))
  }
}
