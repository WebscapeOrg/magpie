.pragma library

function install(client) {
  if (!client.backend || !client.backend.testCalls) {
    var backend = {
      ready: true,
      testCalls: [],
      call: function(method, parameters, callback) {
        var request = { method: method, params: parameters, callback: callback, answered: false }
        this.testCalls.push(request)
        return this.testCalls.length
      }
    }
    client.backend = backend
  }
  return client.backend
}

function transports(client) {
  if (!client) return []
  // Invariant: Mail request counts exclude cancellation and stream supervision, which have separate lifetime tests.
  return install(client).testCalls.filter(function(request) {
    return (request.method.indexOf("jmap.") === 0
      && request.method !== "jmap.cancel" && request.method !== "jmap.invalidate"
      && request.method !== "jmap.watch" && request.method.indexOf("jmap.stream.") !== 0)
      || request.method.indexOf("imap.") === 0
      || request.method === "smtp.send" || request.method === "outlook.graphSend"
  })
}

function newSince(client, before) {
  var now = transports(client)
  var result = []
  for (var requestIndex = 0; requestIndex < now.length; requestIndex++) {
    if (before.indexOf(now[requestIndex]) < 0) result.push(now[requestIndex])
  }
  return result
}

function requested(request) {
  var parameters = request.params
  var credential = parameters.credential || {}
  return {
    verb: parameters.verb,
    url: parameters.url || "",
    scheme: credential.scheme || "",
    fields: [parameters.url || "", credential.scheme || "", credential.username || "",
      credential.secret || "", parameters.body || ""]
  }
}

function reply(request, result, error) {
  if (request.answered) throw new Error("Backend request answered twice")
  request.answered = true
  request.callback(result, error || "")
}

function answer(request, status, body) {
  answerText(request, status, body === undefined || body === null ? "" : JSON.stringify(body))
}

function answerText(request, status, body) {
  reply(request, { exit: 0, status: status, redirect: "", body: String(body || ""), stderr: "" }, "")
}

function fail(request) {
  reply(request, null, "jmap_network_failed")
}

function verified(request, session, mailboxReply, scheme) {
  var boxes = mailboxReply.methodResponses[0][1].list
  reply(request, { session: session, mailboxes: boxes,
    sessionUrl: request.params.settings.sessionUrl,
    authScheme: scheme || request.params.settings.authScheme || "basic",
    accountId: mailboxReply.methodResponses[0][1].accountId,
    canSend: !!session.capabilities["urn:ietf:params:jmap:submission"],
    mailboxCount: boxes.length }, "")
}

function complete(request, data, state) {
  reply(request, {data:data, state:state || null}, "")
}
