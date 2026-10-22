import QtQuick

import "ImapProtocol.js" as Imap
import "Outlook.js" as Outlook
import "MicrosoftOAuth.js" as Microsoft

// Invariant: Microsoft sign-in for the Outlook provider. The refresh token lives in
// GNOME Keyring; native backend clients handle OAuth, IMAP and SMTP networking.
Item {
  id: root

  Deferred { id: deferred }

  visible: false
  width: 0
  height: 0

  required property string pluginDir
  property var backend: null
  property var platform: null
  property string accountId: ""
  property string configuredClientId: ""
  readonly property string clientId: Microsoft.effectiveClientId(configuredClientId)
  property string configuredEmail: ""
  // Invariant: The account entry's server settings. Outlook's servers are fixed by
  // `Outlook.settings` whatever these say; only two readings are taken from
  // them — the tenant the sign-in is addressed to, which `normalizeTenant`
  // keeps to one path segment of Microsoft's own URL, and whether the mailbox
  // sends through Graph, a mode with one fixed address of its own.
  property var entrySettings: null
  readonly property string tenant: Microsoft.normalizeTenant(entrySettings ? entrySettings.tenant : "")
  readonly property string configuredSend: entrySettings ? String(entrySettings.send || "") : ""
  // Invariant: Microsoft grants this token for its own mail service. Persisted generic
  // IMAP settings must never select its destination or disable transport TLS.
  readonly property var settings: Outlook.settings(configuredEmail, tenant, configuredSend)
  property var scopes: Microsoft.SCOPES
  property string devicePurpose: "mail"
  property bool graphConsentNeeded: false
  property bool graphRoundOfSignIn: false
  // Invariant: A Graph sign-in asked for from the setup page, on a mailbox that is
  // signed in and stays so: not `loginBusy`, which would take the mailbox
  // out of service for the code's duration.
  property bool graphRoundBusy: false
  property int graphRoundSerial: 0
  property int graphGrants: 0
  // Invariant: The mail session's account, by tenant and object id, from the id
  // token that came with its token: what the Graph sign-in is held to.
  property string accountKey: ""

  readonly property string authMode: "oauth2"
  readonly property bool configured: Imap.validateSettings(settings).ok
  readonly property bool credentialsPresent: configured && Microsoft.isValidClientId(clientId)

  property string accessToken: ""
  property double accessTokenExpiresAt: 0
  property bool loggedIn: false
  property bool sessionChecked: false
  property bool savedSessionPresent: false
  readonly property bool recoveringSession: savedSessionPresent && !loggedIn
  property bool loginBusy: false
  property bool refreshBusy: false
  readonly property bool sessionBusy: !!lookupProcess || refreshBusy || restoreQueued
  property string lastError: ""

  readonly property var requiredTools: []
  property var missingTools: []
  property bool toolsChecked: true
  readonly property bool toolsPresent: toolsChecked && missingTools.length === 0

  property var tokenWaiters: []
  property int sessionGeneration: 0
  property bool sessionEnabled: true
  property var lookupProcess: null
  property bool restoreQueued: false
  property var keyringJobs: []
  property var keyringJob: null
  property int refreshRetryAttempt: 0

  property string deviceCode: ""
  property string userCode: ""
  property string verificationUri: ""
  property double deviceExpiresAt: 0
  property int devicePollIntervalMs: 5000
  property string pendingAccessToken: ""
  property string pendingRefreshToken: ""
  property double pendingExpiresIn: 0
  property string pendingIdToken: ""

  property var tokenRequests: []
  property int tokenRequestCount: 0
  readonly property int tokenTimeoutMs: 30000

  signal loginSucceeded()
  signal graphRefused(string reason)
  signal loggedOut()
  signal sessionUnavailable(string reason)
  signal credentialsSaved()
  signal verifyRequested(var settings, string credentials)

  function sessionContext() {
    return { generation: sessionGeneration, accountId: accountId, clientId: clientId, tenant: tenant }
  }

  function isCurrent(context) {
    return !!context && context.generation === sessionGeneration
      && context.accountId === accountId && context.clientId === clientId && context.tenant === tenant
  }

  function safeError(value) {
    return Microsoft.redact(String(value || ""))
  }

  function tokenIsFresh() {
    return accessToken !== "" && Date.now() + 60000 < accessTokenExpiresAt
  }

  function resetMemorySession() {
    accessToken = ""
    accessTokenExpiresAt = 0
    loggedIn = false
    graphAccessToken = ""
    graphAccessTokenExpiresAt = 0
    graphConsentNeeded = false
    accountKey = ""
    cancelGraphRound()
  }

  // Invariant: A token of Graph's audience, for a tenant that sends through Graph. The
  // refresh token in the keyring is exchanged for it the same way the mail
  // token is refreshed, with Graph's scope in place of IMAP's; nothing new is
  // signed in to, and a rotated refresh token is stored back as before.
  property string graphAccessToken: ""
  property double graphAccessTokenExpiresAt: 0
  property var graphWaiters: []
  property var graphLookupProcess: null
  property bool graphQueued: false
  property bool graphProbeQueued: false

  function graphTokenIsFresh() {
    return graphAccessToken !== "" && Date.now() < graphAccessTokenExpiresAt - 60000
  }

  function finishGraphWaiters(token, error) {
    var context = sessionContext()
    var waiting = graphWaiters
    graphWaiters = []
    for (var itemIndex = 0; itemIndex < waiting.length; itemIndex++) {
      var current = isCurrent(context) && sessionEnabled
      try { waiting[itemIndex](current ? token : "", current ? error : "Session changed") }
      catch (error) { /* Invariant: one consumer cannot strand another waiter. */ }
    }
  }

  /** Native calendar work resolves its own tokens. Bind its consent result
   * before it starts, so an old request cannot change a replacement session
   * or undo the Graph device flow that completed while it was in flight.
   */
  function graphConsentHandler() {
    var context = sessionContext()
    var requestedTenant = tenant
    var grants = graphGrants
    return function(error) {
      if (!root || !root.isCurrent(context) || !root.sessionEnabled
          || root.tenant !== requestedTenant || root.graphGrants !== grants
          || !error || error.message !== "auth_consent_required") return false
      root.graphConsentNeeded = true
      return true
    }
  }

  function withGraphToken(callback) {
    if (typeof callback !== "function") return
    if (!sessionEnabled) {
      callback("", "Signed out")
      return
    }
    if (graphTokenIsFresh()) {
      callback(graphAccessToken, "")
      return
    }
    if (!credentialsPresent) {
      callback("", "Add this Outlook mailbox and its OAuth client first")
      return
    }
    var next = graphWaiters.slice()
    next.push(callback)
    graphWaiters = next
    if (graphLookupProcess || loginBusy || graphRoundBusy) return
    startGraphLookup()
  }

  function startGraphLookup() {
    if (graphLookupProcess || graphWaiters.length === 0) return
    if (loginBusy || graphRoundBusy) return
    if (keyringJob || keyringJobs.length > 0) {
      graphQueued = true
      return
    }
    graphQueued = false
    if (backend && accountId) {
      handleGraphLookup("", sessionContext())
      return
    }
    var context = sessionContext()
    if (!platform || typeof platform.credentialGet !== "function" || !clientId || !accountId) {
      handleGraphLookup("", context)
      return
    }
    var operation = { context: context }
    graphLookupProcess = operation
    platform.credentialGet("outlook-refresh-token", accountId, clientId, function(value, error) {
      if (root.graphLookupProcess !== operation) return
      root.graphLookupProcess = null
      root.handleGraphLookup(error ? "" : value, context)
    })
  }

  function handleGraphLookup(raw, context) {
    if (!isCurrent(context) || !sessionEnabled) {
      // Invariant: A lookup from before a cancel, exiting now: waiters queued behind
      // it since are asked for again, or nothing would.
      if (sessionEnabled && graphWaiters.length > 0) deferred.call(root.startGraphLookup)
      return
    }
    var grants = graphGrants
    var refreshToken = String(raw || "")
    if (refreshToken === "" && !(backend && accountId)) {
      finishGraphWaiters("", "Sign in to Outlook first")
      return
    }
    if (backend && accountId) refreshToken = ""
    postForm(Microsoft.tokenUrlFor(tenant),
      Microsoft.graphRefreshBody(clientId, refreshToken),
      function(status, text) {
        if (!root.isCurrent(context) || !root.sessionEnabled) return
        // Invariant: A Graph sign-in went through while this was out: its answer is
        // the newer one, and this refusal or grant is of a token since
        // replaced.
        if (grants !== root.graphGrants && root.graphTokenIsFresh()) {
          root.finishGraphWaiters(root.graphAccessToken, "")
          return
        }
        var result = Microsoft.parseTokenResponse(status, text, refreshToken)
        refreshToken = ""
        if (!result.ok) {
          if (result.consentRequired) root.graphConsentNeeded = true
          // Invariant: A dead session is Microsoft's own words for it, not a missing
          // permission.
          root.finishGraphWaiters("", root.safeError(result.consentRequired
            ? Microsoft.graphConsentMessage() : result.error))
          return
        }
        if (Microsoft.missingGraphScope(result.scope)) {
          if (result.refreshToken) root.storeRefreshToken(result.refreshToken)
          root.graphConsentNeeded = true
          root.finishGraphWaiters("", Microsoft.graphConsentMessage())
          return
        }
        root.acceptGraphToken(result)
      })
  }

  function acceptGraphToken(result) {
    graphGrants++
    graphConsentNeeded = false
    graphAccessToken = result.accessToken
    graphAccessTokenExpiresAt = Date.now() + result.expiresIn * 1000
    if (result.refreshToken) storeRefreshToken(result.refreshToken)
    finishGraphWaiters(graphAccessToken, "")
  }

  /** Whether this client is consented for Graph is found out with the
   * refresh token in hand, straight after the mail sign-in of a tenant that
   * sends through Graph, and mended by a second code where it is not —
   * rather than at the first send. Any other refusal is sending's to
   * report: the mailbox is signed in.
   */
  function probeGraphConsent(refreshToken) {
    if (backend && (keyringJob || keyringJobs.length > 0)) { graphProbeQueued = true; return }
    var context = sessionContext()
    if (backend && accountId) refreshToken = ""
    postForm(Microsoft.tokenUrlFor(tenant),
      Microsoft.graphRefreshBody(clientId, refreshToken),
      function(status, text) {
        if (!root.isCurrent(context) || !root.sessionEnabled) return
        var result = Microsoft.parseTokenResponse(status, text, refreshToken)
        refreshToken = ""
        if ((!result.ok && result.consentRequired) || (result.ok && Microsoft.missingGraphScope(result.scope))) {
          if (result.ok && result.refreshToken) root.storeRefreshToken(result.refreshToken)
          root.graphConsentNeeded = true
          root.graphRoundOfSignIn = true
          root.startDeviceFlow("graph")
          return
        }
        if (result.ok) {
          root.acceptGraphToken(result)
        } else {
          var message = "Microsoft Graph could not be checked: " + root.safeError(result.error) + ". Sending will ask again"
          root.finishGraphWaiters("", message)
          if (!root.isCurrent(context) || !root.sessionEnabled) return
          root.graphRefused(message)
        }
        if (!root.isCurrent(context) || !root.sessionEnabled) return
        root.graphRoundOfSignIn = false
        root.loginBusy = false
        root.loginSucceeded()
      })
  }

  /** The Graph sign-in answered: a token of Graph's audience, and a refresh
   * token consented for both resources, kept in place of the mail one —
   * the same user's and client's, and exchangeable for either.
   */
  function acceptGraphSignIn(result) {
    // Invariant: The mail sign-in is verified by logging in to the mailbox with its
    // token; this one by the name on its id token, since a code entered
    // as someone else would file that someone's token as the mailbox's.
    if (!Microsoft.sameAccount(result.idToken, configuredEmail, accountKey)) {
      failGraphRound(Microsoft.otherAccountMessage(Microsoft.signedInAs(result.idToken), configuredEmail))
      return
    }
    if (Microsoft.missingGraphScope(result.scope)) {
      // Invariant: Issued to the right account without the permission: its refresh
      // token is the live one all the same.
      if (result.refreshToken) storeRefreshToken(result.refreshToken)
      failGraphRound(Microsoft.graphScopeMessage())
      return
    }
    cancelDeviceLogin()
    loginBusy = false
    graphRoundBusy = false
    lastError = ""
    var context = sessionContext()
    acceptGraphToken(result)
    if (!isCurrent(context) || !sessionEnabled) return
    var afterSignIn = graphRoundOfSignIn
    graphRoundOfSignIn = false
    if (afterSignIn) loginSucceeded()
  }

  /** The Graph sign-in failing leaves the mail one as it was: the account is
   * not told its session is gone, only what Graph will say when asked.
   */
  function failGraphRound(reason) {
    var message = Microsoft.graphRefusedMessage(safeError(reason || "Microsoft sign-in failed"))
    loginBusy = false
    graphRoundBusy = false
    cancelDeviceLogin()
    var context = sessionContext()
    finishGraphWaiters("", message)
    if (!isCurrent(context) || !sessionEnabled) return
    graphRefused(message)
    if (!isCurrent(context) || !sessionEnabled) return
    var afterSignIn = graphRoundOfSignIn
    graphRoundOfSignIn = false
    if (afterSignIn) loginSucceeded()
  }

  function invalidateAccessToken() {
    if (backend && accountId) backend.call("auth.invalidate", { accountId: accountId }, function() {})
    accessToken = ""
    accessTokenExpiresAt = 0
  }

  function finishWaiters(token, error) {
    var context = sessionContext()
    var pending = tokenWaiters.slice()
    tokenWaiters = []
    for (var itemIndex = 0; itemIndex < pending.length; itemIndex++) {
      // Invariant: A consumer can synchronously sign out or switch accounts. Remaining
      // callbacks still belong to the session captured above.
      var current = isCurrent(context) && sessionEnabled
      try { pending[itemIndex](current ? (token || "") : "",
        current ? safeError(error) : "Session changed") }
      catch (error) { /* Invariant: one consumer must not prevent later waiters from completing. */ }
    }
  }

  function withCredentials(callback) {
    if (typeof callback !== "function") return
    if (!sessionEnabled) {
      callback("", "Signed out")
      return
    }
    if (tokenIsFresh()) {
      callback(accessToken, "")
      return
    }
    if (!credentialsPresent) {
      callback("", "Add this Outlook mailbox and its OAuth client first")
      return
    }
    var next = tokenWaiters.slice()
    next.push(callback)
    tokenWaiters = next
    if (refreshBusy || lookupProcess || loginBusy) return
    startSecretLookup()
  }

  function restoreSession() {
    if (!sessionEnabled || loginBusy) return
    sessionChecked = false
    if (!credentialsPresent || accountId === "") {
      savedSessionPresent = false
      sessionChecked = true
      resetMemorySession()
      return
    }
    if (lookupProcess || refreshBusy) return
    startSecretLookup()
  }

  function startSecretLookup() {
    // Invariant: A preceding store/clear must finish before a lookup can observe the key.
    if (keyringJob || keyringJobs.length > 0) {
      restoreQueued = true
      return
    }
    restoreQueued = false
    if (backend && accountId) {
      savedSessionPresent = true
      refreshWithToken("", sessionContext())
      return
    }
    var context = sessionContext()
    if (!platform || typeof platform.credentialGet !== "function" || !clientId || !accountId) {
      handleSecretLookup("", context)
      return
    }
    var operation = { context: context }
    lookupProcess = operation
    platform.credentialGet("outlook-refresh-token", accountId, clientId, function(value, error) {
      if (root.lookupProcess !== operation) return
      root.lookupProcess = null
      root.handleSecretLookup(error ? "" : value, context)
    })
  }

  function handleSecretLookup(raw, context) {
    if (!isCurrent(context) || !sessionEnabled) return
    var token = String(raw || "")
    if (token === "") {
      savedSessionPresent = false
      resetMemorySession()
      sessionChecked = true
      finishWaiters("", "Sign in to Outlook first")
      return
    }
    savedSessionPresent = true
    refreshWithToken(token, context)
  }

  function storeRefreshToken(token) {
    if (!token || !clientId || !accountId) return
    enqueueKeyringJob("store", [], String(token))
  }

  function clearStoredToken() {
    if (!clientId || !accountId) return
    enqueueKeyringJob("clear", [], "")
  }

  /** Jobs own immutable destinations. Serialize them so logout's clear cannot
   * race a preceding store, even when the account host is reused meanwhile.
   */
  function enqueueKeyringJob(kind, attributes, token) {
    var next = keyringJobs.slice()
    next.push({ kind: kind, attributes: attributes.slice(), token: token,
      context: sessionContext() })
    keyringJobs = next
    runKeyringJob()
  }

  function runKeyringJob() {
    if (keyringJob) return
    if (keyringJobs.length === 0) {
      if (restoreQueued) deferred.call(root.restoreSession)
      if (graphQueued) deferred.call(root.startGraphLookup)
      if (graphProbeQueued) { graphProbeQueued = false; deferred.call(function() { root.probeGraphConsent("") }) }
      return
    }
    var next = keyringJobs.slice()
    keyringJob = next.shift()
    keyringJobs = next
    var job = keyringJob
    var nativeStore = backend && typeof backend.call === "function"
    if (!nativeStore && (!platform || (job.kind === "store" && typeof platform.credentialPut !== "function")
        || (job.kind === "clear" && typeof platform.credentialDelete !== "function"))) {
      job.token = ""
      keyringJob = null
      if (isCurrent(job.context)) lastError = "Could not update the saved Microsoft session"
      runKeyringJob()
      return
    }
    var done = function(ok, error) {
      if (root.keyringJob !== job) return
      root.keyringJob = null
      if (!ok && root.isCurrent(job.context)) root.lastError = "Could not update the saved Microsoft session"
      root.runKeyringJob()
    }
    if (nativeStore) {
      // Invariant: Device grants and logout share the backend's account refresh lane.
      // A mail/Graph refresh already in flight must finish its rotation before
      // this newer grant replaces it, or the old grant can overwrite consent.
      var fields = { accountId: job.context.accountId, clientId: job.context.clientId }
      if (job.kind === "store") fields.token = job.token
      backend.call(job.kind === "store" ? "auth.store" : "auth.clear", fields, function(result, error) {
        done(!error && !!result && (job.kind === "store" ? result.saved === true : result.cleared === true),
          error ? String(error.message || "") : "")
      })
    } else if (job.kind === "store")
      platform.credentialPut("outlook-refresh-token", job.context.accountId,
        job.context.clientId, job.token, done)
    else
      platform.credentialDelete("outlook-refresh-token", job.context.accountId,
        job.context.clientId, done)
    job.token = ""
  }

  function postForm(url, body, callback) {
    var id = ++tokenRequestCount
    var request = { abort: function() {
      var kept = []
      for (var itemIndex = 0; itemIndex < root.tokenRequests.length; itemIndex++) {
        if (root.tokenRequests[itemIndex].id !== id) kept.push(root.tokenRequests[itemIndex])
      }
      root.tokenRequests = kept
    } }
    tokenRequests = tokenRequests.concat([{ id: id, request: request }])
    function finish(result, error) {
      var live = false
      for (var itemIndex = 0; itemIndex < root.tokenRequests.length; itemIndex++) {
        if (root.tokenRequests[itemIndex].id === id) live = true
      }
      if (!live) return
      request.abort()
      callback(error ? 0 : result.status, error ? "" : result.body)
    }
    if (!backend || !backend.ready) { finish(null, true); return }
    var endpoint = url === Microsoft.deviceUrlFor(tenant) ? "device" : "token"
    if (url !== Microsoft.deviceUrlFor(tenant) && url !== Microsoft.tokenUrlFor(tenant)) {
      finish(null, true)
      return
    }
    if (endpoint === "token" && body.indexOf("grant_type=refresh_token") >= 0 && accountId) {
      backend.call("auth.token", { provider: "outlook", accountId: accountId,
        resource: body.indexOf("graph.microsoft.com") >= 0 ? "graph" : "mail" }, function(result, error) {
        var reason = error ? String(error.message || "") : ""
        var code = reason === "auth_signed_out" ? "invalid_grant" : "temporarily_unavailable"
        var failure = reason === "auth_consent_required"
          ? { error: "interaction_required", error_codes: [65001] } : { error: code }
        finish({ status: error ? 400 : 200, body: JSON.stringify(error ? failure : result) }, "")
      })
      return
    }
    backend.call("auth.form", { provider: "outlook", endpoint: endpoint,
      tenant: tenant, body: body }, finish)
  }

  function refreshWithToken(refreshToken, context) {
    if (backend && accountId) refreshToken = ""
    refreshBusy = true
    // Invariant: The mail scopes alone: a token is for one resource, and Microsoft
    // refuses a refresh that names two. The Graph exchange asks for its own.
    postForm(Microsoft.tokenUrlFor(tenant),
      Microsoft.refreshTokenBody(clientId, refreshToken, Microsoft.SCOPES),
      function(status, text) {
        if (!root.isCurrent(context) || !root.sessionEnabled) return
        var result = Microsoft.parseTokenResponse(status, text, refreshToken)
        refreshToken = ""
        root.refreshBusy = false
        root.sessionChecked = true
        if (!result.ok) {
          root.resetMemorySession()
          root.lastError = root.safeError(result.error)
          if (Microsoft.refreshFailureDisposition(result) === "signed_out") {
            root.savedSessionPresent = false
            refreshRetry.stop()
            root.clearStoredToken()
          } else {
            root.scheduleRefreshRetry()
          }
          root.finishWaiters("", root.lastError)
          root.sessionUnavailable(root.lastError)
          return
        }
        root.acceptToken(result)
        root.finishWaiters(root.accessToken, "")
      })
  }

  function acceptToken(result) {
    var key = Microsoft.accountKey(result.idToken)
    if (key !== "") accountKey = key
    accessToken = result.accessToken
    accessTokenExpiresAt = Date.now() + result.expiresIn * 1000
    loggedIn = true
    savedSessionPresent = true
    refreshRetryAttempt = 0
    refreshRetry.stop()
    lastError = ""
    if (result.refreshToken) storeRefreshToken(result.refreshToken)
  }

  function scheduleRefreshRetry() {
    if (!savedSessionPresent || refreshRetry.running) return
    refreshRetry.interval = Microsoft.refreshRetryDelay(refreshRetryAttempt)
    refreshRetryAttempt++
    refreshRetry.start()
  }

  function beginLogin() {
    if (loginBusy || graphRoundBusy || refreshBusy) return
    if (!credentialsPresent) {
      lastError = "Add the mailbox address and Microsoft OAuth client ID first"
      return
    }
    if (platform && platform.canAccessCredentials === false) {
      lastError = "Install or update the mail backend before signing in"
      return
    }
    if (!toolsPresent && toolsChecked) {
      lastError = missingTools.length > 0 ? "Missing " + missingTools.join(", ")
        : "Install or update the mail backend before signing in"
      return
    }
    var forGraph = graphConsentNeeded && loggedIn
    if (forGraph) {
      lastError = ""
      graphRoundOfSignIn = false
      graphRoundBusy = true
      startDeviceFlow("graph")
      return
    }
    cancelLogin()
    sessionEnabled = true
    lastError = ""
    loginBusy = true
    startDeviceFlow("mail")
  }

  /** One device-code round: the code and the page to enter it on, then the
   * poll until Microsoft answers with a token or a refusal.
   */
  function startDeviceFlow(purpose) {
    var context = sessionContext()
    var round = graphRoundSerial
    devicePurpose = purpose
    postForm(Microsoft.deviceUrlFor(tenant),
      Microsoft.deviceAuthorizationBody(clientId,
        purpose === "graph" ? Microsoft.GRAPH_SIGN_IN_SCOPES : scopes),
      function(status, text) {
        if (!root.isCurrent(context) || round !== root.graphRoundSerial) return
        var result = Microsoft.parseDeviceResponse(status, text)
        if (!result.ok) {
          root.failLogin(result.error)
          return
        }
        root.deviceCode = result.deviceCode
        root.userCode = result.userCode
        root.verificationUri = result.verificationUri
        root.deviceExpiresAt = Date.now() + result.expiresIn * 1000
        root.devicePollIntervalMs = result.interval * 1000
        if (root.platform && typeof root.platform.openExternal === "function")
          root.platform.openExternal(root.verificationUri)
        devicePoll.interval = root.devicePollIntervalMs
        devicePoll.start()
      })
  }

  function pollDeviceCode() {
    if (!(loginBusy || graphRoundBusy) || deviceCode === "") return
    if (Date.now() >= deviceExpiresAt) {
      failLogin("The Microsoft sign-in code expired. Please try again")
      return
    }
    var context = sessionContext()
    var round = graphRoundSerial
    postForm(Microsoft.tokenUrlFor(tenant),
      Microsoft.deviceTokenBody(clientId, deviceCode),
      function(status, text) {
        if (!root.isCurrent(context) || round !== root.graphRoundSerial) return
        var result = Microsoft.parseTokenResponse(status, text, "")
        if (result.pending) {
          if (result.slowDown) root.devicePollIntervalMs += 5000
          devicePoll.interval = root.devicePollIntervalMs
          devicePoll.start()
          return
        }
        if (!result.ok) {
          root.failLogin(result.error)
          return
        }
        if (root.devicePurpose === "graph") {
          root.acceptGraphSignIn(result)
          return
        }
        var missing = Microsoft.missingMailScopes(result.scope)
        if (missing.length > 0) {
          root.failLogin(Microsoft.missingScopeMessage(missing))
          return
        }
        if (!result.refreshToken) {
          root.failLogin("Microsoft sign-in did not grant offline access. Check the app registration and sign in again")
          return
        }
        root.pendingAccessToken = result.accessToken
        root.pendingRefreshToken = result.refreshToken
        root.pendingExpiresIn = result.expiresIn
        root.pendingIdToken = result.idToken
        root.deviceCode = ""
        root.userCode = ""
        root.verificationUri = ""
        root.verifyRequested(root.settings, root.pendingAccessToken)
      })
  }

  function completeSignIn(ok, error, generation) {
    if (generation !== sessionGeneration || !loginBusy || pendingAccessToken === "") return
    if (!ok) {
      clearPendingToken()
      failLogin(error || "Outlook rejected this mailbox sign-in")
      return
    }
    var result = ({
      accessToken: pendingAccessToken,
      refreshToken: pendingRefreshToken,
      expiresIn: pendingExpiresIn,
      idToken: pendingIdToken
    })
    clearPendingToken()
    sessionChecked = true
    acceptToken(result)
    var context = sessionContext()
    finishWaiters(accessToken, "")
    if (!isCurrent(context) || !sessionEnabled || !loggedIn) return
    if (configuredSend === "graph") {
      graphRoundOfSignIn = true
      probeGraphConsent(result.refreshToken)
      return
    }
    loginBusy = false
    loginSucceeded()
    if (graphWaiters.length > 0) startGraphLookup()
  }

  function clearPendingToken() {
    pendingAccessToken = ""
    pendingRefreshToken = ""
    pendingExpiresIn = 0
    pendingIdToken = ""
  }

  function cancelDeviceLogin() {
    devicePoll.stop()
    deviceCode = ""
    userCode = ""
    verificationUri = ""
    deviceExpiresAt = 0
    devicePurpose = "mail"
    clearPendingToken()
  }

  function failLogin(reason) {
    if (devicePurpose === "graph") {
      failGraphRound(reason)
      return
    }
    lastError = safeError(reason || "Microsoft sign-in failed. Please try again")
    loginBusy = false
    cancelDeviceLogin()
    finishWaiters("", lastError)
    finishGraphWaiters("", lastError)
    sessionUnavailable(lastError)
  }

  /** A Graph sign-in asked for from the setup page, cut short: the code goes
   * and its waiters are told, and nothing of the mail session — a refresh
   * in flight, its waiters, a lookup — is touched.
   */
  function cancelGraphRound() {
    if (!graphRoundBusy) return
    graphRoundSerial++
    graphRoundBusy = false
    cancelDeviceLogin()
    finishGraphWaiters("", "Sign-in cancelled")
  }

  function cancelLogin() {
    // Invariant: Cancel on a settings-page Graph code, the mailbox staying signed in,
    // is that code's alone. Signing out or changing identity is everything's:
    // a mail refresh in flight would otherwise be left busy for good, its
    // answer refused for the session being over.
    if (graphRoundBusy && !loginBusy && sessionEnabled) {
      cancelGraphRound()
      return
    }
    sessionGeneration++
    var oldLookup = lookupProcess
    lookupProcess = null
    // Invariant: Async credential callbacks compare this sentinel and the generation;
    // clearing it cancels their authority to update the session.
    restoreQueued = false
    graphProbeQueued = false
    refreshRetry.stop()
    // Invariant: Where what is cut short is the Graph tail of a sign-in — the check
    // or the second code — the mail half is in and is said so.
    var afterSignIn = graphRoundOfSignIn && sessionEnabled
    graphRoundOfSignIn = false
    cancelDeviceLogin()
    var open = tokenRequests
    tokenRequests = []
    for (var itemIndex = 0; itemIndex < open.length; itemIndex++) {
      if (open[itemIndex].request && open[itemIndex].request.abort) open[itemIndex].request.abort()
    }
    refreshBusy = false
    loginBusy = false
    graphRoundBusy = false
    finishWaiters("", "Sign-in cancelled")
    finishGraphWaiters("", "Sign-in cancelled")
    if (afterSignIn) loginSucceeded()
  }

  function logout() {
    if (backend && accountId) backend.call("auth.invalidate", { accountId: accountId }, function() {})
    sessionEnabled = false
    cancelLogin()
    refreshRetry.stop()
    refreshRetryAttempt = 0
    savedSessionPresent = false
    resetMemorySession()
    sessionChecked = true
    lastError = ""
    finishWaiters("", "Signed out")
    finishGraphWaiters("", "Signed out")
    clearStoredToken()
    loggedOut()
  }

  function changeIdentity() {
    sessionEnabled = false
    resetMemorySession()
    cancelLogin()
    savedSessionPresent = false
    sessionChecked = false
    sessionEnabled = true
    var context = sessionContext()
    deferred.call(function() {
      if (root.isCurrent(context)) root.restoreSession()
    })
  }

  onAccountIdChanged: changeIdentity()
  onClientIdChanged: changeIdentity()
  onTenantChanged: changeIdentity()

  Timer {
    id: devicePoll
    repeat: false
    onTriggered: root.pollDeviceCode()
  }

  Timer {
    id: refreshRetry
    repeat: false
    onTriggered: root.restoreSession()
  }

}
