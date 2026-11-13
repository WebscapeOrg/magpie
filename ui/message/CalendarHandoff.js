.pragma library

function invitation(accountId, value) {
  return {
    version: 1, kind: "invitation", accountId: accountId,
    invitation: {
      uid: value.uid,
      organizer: {email: value.organizer && value.organizer.email},
      recurrenceIdMs: value.recurrenceIdMs,
      source: {recurrenceId: value.source && value.source.recurrenceId},
      summary: Array.from(String(value.summary || "")).slice(0, 512).join(""),
      method: value.method === "CANCEL" ? "CANCEL" : "REQUEST"
    }
  }
}
