import QtQuick

import "JmapProtocol.js" as Jmap

// Invariant: Rust detects the credential scheme and constructs Authorization.
// Secrets travel through the native credential API and are scoped by account.
Item {
  id: root

  visible: false
  width: 0
  height: 0

  property var backend: null
  property var platform: null
  required property string pluginDir

  property string accountId: ""

  property string address: ""

  property var settings: ({ sessionUrl: "", username: "", authScheme: "basic", accountId: "" })

  // Invariant: A mailbox this client knows where to talk to. Unlike IMAP's, this is not
  // something the user typed: it is what sign-in learned and wrote down.
  readonly property bool configured: String((settings || {}).sessionUrl || "") !== ""
    && String((settings || {}).accountId || "") !== ""

  // Performance: The secret, once the keyring has answered. Held for as long as the account
  // exists, exactly as the IMAP password is: every request needs it, and a
  // keyring round trip per request would be both slow and a stream of
  // authorisation prompts on some setups.
  property string secret: ""
  property bool secretChecked: false
  readonly property bool loggedIn: configured && secret !== ""

  readonly property bool credentialsPresent: configured
  property bool loginBusy: false
  property int sessionGeneration: 0
  property bool credentialLookupBusy: false
  property bool credentialWriteBusy: false
  property int credentialLookupSerial: 0
  property string credentialWriteAccount: ""
  property string pendingCredentialDelete: ""
  readonly property bool sessionBusy: credentialLookupBusy || credentialWriteBusy
  property string lastError: ""

  property int progressStep: 0

  function reportProgress(step) {
    var value = Math.floor(Number(step))
    progressStep = isFinite(value) && value > 0 ? value : 0
  }

  property bool serverNeeded: false

  // Invariant: Whether the credential that signed in may submit mail. A missing
  // submission capability does not fail sign-in — the mailbox reads perfectly
  // well — so the account signs in and the page says what it cannot do. The
  // standing refusal is the client's, read from the session (`Jmap.refusals`);
  // this is only what the last check found out, for the page's one sentence.
  property bool sendingOffered: true

  readonly property var requiredTools: []
  property var missingTools: []
  property bool toolsChecked: true
  readonly property bool toolsPresent: toolsChecked && missingTools.length === 0

  property var credentialWaiters: []
  property bool lookupHandled: false
  property string pendingSecret: ""

  signal loginSucceeded()
  signal loggedOut()
  signal sessionUnavailable(string reason)
  signal credentialsSaved()

  signal sessionVerified(var result)

  function safeError(value) {
    return Jmap.redact(String(value || ""))
  }

  /** Three fields rather than one string. The script joins them into whichever
   * header the scheme needs, and refuses a scheme it does not know before networking
   * starts — so there is no place here where an `Authorization` value is built.
   */
  function credential() {
    var values = settings || {}
    var user = String(values.username || "")
    return Jmap.credential(values.authScheme, user !== "" ? user : String(address || ""), secret)
  }

  function finishWaiters(value, error) {
    var context = { account: accountId, generation: sessionGeneration }
    var pending = credentialWaiters.slice()
    credentialWaiters = []
    for (var itemIndex = 0; itemIndex < pending.length; itemIndex++) {
      var current = context.account === accountId && context.generation === sessionGeneration
      try { pending[itemIndex](current ? value : null, current ? safeError(error) : "The mailbox changed during this request") }
      catch (error) { /* Invariant: one consumer must not prevent later waiters from completing. */ }
    }
  }

  /** The one entry point the transport uses.
   */
  function withCredentials(callback) {
    if (typeof callback !== "function") return
    if (!configured) {
      callback(null, "Sign in to this mailbox first")
      return
    }
    if (secret !== "") {
      callback(credential(), "")
      return
    }
    if (secretChecked) {
      callback(null, "No app password saved for this mailbox. Sign in again")
      return
    }

    var next = credentialWaiters.slice()
    next.push(callback)
    credentialWaiters = next
    if (credentialLookupBusy) return
    startSecretLookup()
  }

  function restoreSession() {
    if (!configured) {
      secretChecked = true
      return
    }
    if (credentialLookupBusy) return
    startSecretLookup()
  }

  function startSecretLookup() {
    var boundAccount = accountId
    if (!platform || typeof platform.credentialGet !== "function" || boundAccount === "") {
      handleSecretLookup("", "credential_store_unavailable")
      return
    }
    lookupHandled = false
    var serial = ++credentialLookupSerial
    credentialLookupBusy = true
    platform.credentialGet("jmap-secret", boundAccount, "", function(value, error) {
      if (serial !== root.credentialLookupSerial) return
      root.credentialLookupBusy = false
      if (boundAccount !== root.accountId) return
      root.handleSecretLookup(error ? "" : value, error)
    })
  }

  function handleSecretLookup(line, error) {
    if (lookupHandled) return
    lookupHandled = true
    if (error && error !== "credential_missing") {
      secretChecked = false
      lastError = "The credential store is unavailable"
      finishWaiters(null, lastError)
      if (configured) sessionUnavailable(lastError)
      return
    }
    secretChecked = true
    var value = String(line || "")
    if (value === "") {
      finishWaiters(null, "No app password saved for this mailbox. Sign in again")
      if (configured) sessionUnavailable("Sign in to this mailbox")
      return
    }
    secret = value
    var generation = sessionGeneration
    finishWaiters(credential(), "")
    if (generation === sessionGeneration && loggedIn) loginSucceeded()
  }

  /** Called by the setup page once the form is filled in. The secret is
   * verified by using it — discovery, the session GET under each scheme in
   * turn, and one `Mailbox/get` — rather than being written down first and
   * failing later on a page with no field to correct.
   */
  function signIn(value) {
    if (loginBusy || credentialWriteBusy) return false
    if (platform && platform.canAccessCredentials === false) {
      lastError = "Install or update the mail backend before signing in"
      return false
    }
    if (!toolsPresent) {
      lastError = "Missing " + missingTools.join(", ")
      return false
    }
    var typed = String(value || "")
    // Invariant: "Save changes" re-verifies, and the field it would have come from is
    // empty on a signed-in page: nothing ever writes a saved secret back into
    // a text box. The one already held is what the server is asked about.
    if (typed === "" && secret !== "") typed = secret
    if (typed === "") {
      lastError = "Enter the app password or API token for this mailbox"
      return false
    }
    if (String(address || "") === "") {
      lastError = "Add the email address for this mailbox"
      return false
    }
    sessionGeneration++
    lastError = ""
    serverNeeded = false
    loginBusy = true
    pendingSecret = typed
    verifyRequested(settings, address, typed)
    return true
  }

  signal verifyRequested(var settings, string address, string secret)

  /** `result` is what the check learned when it succeeded: `sessionUrl`,
   * `authScheme` and `accountId`. It is emitted before the secret is stored,
   * because the keyring entry is named after the account and the account is
   * not named until the page has written the address down.
   */
  function completeSignIn(ok, result, error, needsServer, generation) {
    if (!loginBusy || (generation !== undefined && generation !== sessionGeneration)) return
    loginBusy = false
    progressStep = 0
    if (!ok) {
      pendingSecret = ""
      lastError = safeError(error) || "The server rejected that app password or API token"
      serverNeeded = needsServer === true
      return
    }
    serverNeeded = false
    sendingOffered = !result || result.canSend !== false
    secret = pendingSecret
    pendingSecret = ""
    secretChecked = true
    lastError = ""
    sessionVerified(result || {})
    storeSecret()
    // Invariant: A tick later than the rest of this, and deliberately: `sessionVerified`
    // is what has the account list write the session URL, the scheme and the
    // account id onto the entry, and only then is this object `configured`.
    // Emitting in the same turn would have `MailAccount` start fetching
    // against settings that had not landed yet.
    var completedGeneration = sessionGeneration
    Qt.callLater(function() {
      if (root && root.sessionGeneration === completedGeneration && root.loggedIn) root.loginSucceeded()
    })
  }

  function storeSecret() {
    if (!platform || typeof platform.credentialPut !== "function" || accountId === ""
        || secret === "" || credentialWriteBusy) return
    var boundAccount = accountId
    var value = secret
    credentialWriteBusy = true
    credentialWriteAccount = boundAccount
    platform.credentialPut("jmap-secret", boundAccount, "", value, function(ok, error) {
      value = ""
      root.credentialWriteBusy = false
      root.credentialWriteAccount = ""
      var deleteAccount = root.pendingCredentialDelete
      root.pendingCredentialDelete = ""
      if (deleteAccount !== "") {
        root.deleteCredential(deleteAccount)
        return
      }
      if (boundAccount !== root.accountId) return
      if (!ok) root.lastError = "Signed in, but the app password could not be saved. "
        + "You may need to enter it again after a restart"
      else root.credentialsSaved()
    })
  }

  function deleteCredential(boundAccount) {
    if (platform && typeof platform.credentialDelete === "function" && boundAccount !== "")
      platform.credentialDelete("jmap-secret", boundAccount, "", function() {})
  }

  function logout() {
    var boundAccount = accountId
    cancelLogin()
    credentialLookupSerial++
    credentialLookupBusy = false
    secret = ""
    pendingSecret = ""
    secretChecked = true
    if (credentialWriteBusy && credentialWriteAccount === boundAccount)
      pendingCredentialDelete = boundAccount
    else deleteCredential(boundAccount)
    finishWaiters(null, "Signed out")
    loggedOut()
  }

  /** Kept so `MailAccount` can call the same thing on any provider. An app
   * password does not expire, so there is nothing to invalidate — but a server
   * that has started refusing it should not be asked a hundred more times with
   * the same value.
   */
  function invalidateAccessToken() {
    secret = ""
    secretChecked = false
  }

  /** Gmail's manager has these; a JMAP account reaches neither, and
   * `MailAccount` should not have to ask which provider it holds before
   * calling one.
   */
  function beginLogin() {  }
  function cancelLogin() {
    sessionGeneration++
    pendingSecret = ""
    loginBusy = false
    progressStep = 0
  }

  onAccountIdChanged: {
    cancelLogin()
    secret = ""
    secretChecked = false
    lookupHandled = false
    credentialLookupSerial++
    credentialLookupBusy = false
    finishWaiters(null, "The mailbox changed before its credential was loaded")
    if (credentialWriteBusy && credentialWriteAccount !== "")
      pendingCredentialDelete = credentialWriteAccount
  }

}
