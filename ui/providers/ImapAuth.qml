import QtQuick
import Quickshell
import Quickshell.Io

import "ImapProtocol.js" as Imap

// Invariant: Passwords travel through the native credential API, never argv, and
// are scoped by account. Server verification must finish before a credential is stored.
Item {
  id: root

  visible: false
  width: 0
  height: 0

  required property string pluginDir
  property var backend: null
  property var platform: null

  property string accountId: ""

  property var settings: Imap.normalizeSettings(null)

  readonly property string authMode: "password"

  readonly property bool configured: Imap.validateSettings(settings).ok

  // Performance: The password, once the keyring has answered. Held in this process for as
  // long as the account exists, exactly as the access token is: every request
  // needs it, and a keyring round trip per request would be both slow and a
  // stream of authorisation prompts on some setups.
  property string password: ""
  property bool passwordChecked: false
  readonly property bool loggedIn: configured && password !== ""

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

  readonly property var requiredTools: []
  property var missingTools: []
  property bool toolsChecked: true
  readonly property bool toolsPresent: toolsChecked && missingTools.length === 0

  property var credentialWaiters: []
  property bool lookupHandled: false
  property string pendingPassword: ""

  signal loginSucceeded()
  signal loggedOut()
  signal sessionUnavailable(string reason)
  signal credentialsSaved()

  function safeError(value) {
    return Imap.redact(String(value || ""))
  }

  function finishWaiters(value, error) {
    var pending = credentialWaiters.slice()
    credentialWaiters = []
    for (var itemIndex = 0; itemIndex < pending.length; itemIndex++) {
      try { pending[itemIndex](value || "", safeError(error)) }
      catch (error) { /* Invariant: one consumer must not prevent later waiters from completing. */ }
    }
  }

  /** The one entry point the transport uses. Hands back "user:password" — the
   * single credential field the native client consumes — rather than the two halves, so nothing
   * downstream has to know how they are joined.
   */
  function withCredentials(callback) {
    if (typeof callback !== "function") return
    if (!configured) {
      callback("", "Add this mailbox's server settings first")
      return
    }
    if (password !== "") {
      callback(settings.username + ":" + password, "")
      return
    }
    if (passwordChecked) {
      callback("", "No password saved for this mailbox. Sign in again")
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
      passwordChecked = true
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
    platform.credentialGet("imap-password", boundAccount, "", function(value, error) {
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
      passwordChecked = false
      lastError = "The credential store is unavailable"
      finishWaiters("", lastError)
      if (configured) sessionUnavailable(lastError)
      return
    }
    passwordChecked = true
    var value = String(line || "")
    if (value === "") {
      finishWaiters("", "No password saved for this mailbox. Sign in again")
      if (configured) sessionUnavailable("Sign in to this mailbox")
      return
    }
    password = value
    finishWaiters(settings.username + ":" + password, "")
    loginSucceeded()
  }

  /** Called by the setup page once the user has filled the form in. The password
   * is verified by using it — a mailbox that answers a NOOP is a mailbox that
   * will answer everything else — rather than by being written down first and
   * failing silently later.
   */
  function signIn(secret) {
    if (loginBusy || credentialWriteBusy) return false
    if (platform && platform.canAccessCredentials === false) {
      lastError = "Install or update the mail backend before signing in"
      return false
    }
    if (!toolsPresent) {
      lastError = "Missing " + missingTools.join(", ")
      return false
    }
    // Invariant: Pasting from a line can include its trailing line break. Remove only
    // that suffix; silently changing controls inside a password would verify
    // and save a different secret from the one the user entered.
    var value = String(secret || "").replace(/[\r\n]+$/, "")
    if (/[\x00-\x1f\x7f]/.test(value)) {
      lastError = "The password contains a control character. Enter it again"
      return false
    }
    if (value === "") {
      lastError = "Enter the password for this mailbox"
      return false
    }
    var check = Imap.validateSettings(settings)
    if (!check.ok) {
      lastError = check.error
      return false
    }
    sessionGeneration++
    lastError = ""
    loginBusy = true
    pendingPassword = value
    verifyRequested(settings, settings.username + ":" + value)
    return true
  }

  signal verifyRequested(var settings, string credentials)

  function completeSignIn(ok, error, generation) {
    if (!loginBusy || (generation !== undefined && generation !== sessionGeneration)) return
    loginBusy = false
    if (!ok) {
      pendingPassword = ""
      lastError = safeError(error) || "The server rejected that username or password"
      return
    }
    password = pendingPassword
    pendingPassword = ""
    passwordChecked = true
    lastError = ""
    storePassword()
    loginSucceeded()
  }

  function storePassword() {
    if (!platform || typeof platform.credentialPut !== "function" || accountId === ""
        || password === "" || credentialWriteBusy) return
    var boundAccount = accountId
    var value = password
    credentialWriteBusy = true
    credentialWriteAccount = boundAccount
    platform.credentialPut("imap-password", boundAccount, "", value, function(ok, error) {
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
      if (!ok) root.lastError = "Signed in, but the password could not be saved. "
        + "You may need to enter it again after a restart"
      else root.credentialsSaved()
    })
  }

  function deleteCredential(boundAccount) {
    if (platform && typeof platform.credentialDelete === "function" && boundAccount !== "")
      platform.credentialDelete("imap-password", boundAccount, "", function() {})
  }

  function logout() {
    var boundAccount = accountId
    cancelLogin()
    credentialLookupSerial++
    credentialLookupBusy = false
    password = ""
    pendingPassword = ""
    passwordChecked = true
    if (credentialWriteBusy && credentialWriteAccount === boundAccount)
      pendingCredentialDelete = boundAccount
    else deleteCredential(boundAccount)
    finishWaiters("", "Signed out")
    loggedOut()
  }

  /** Kept so `MailAccount` can call the same thing on either provider. An IMAP
   * password does not expire, so there is nothing to invalidate — but a server
   * that has started rejecting it should not be asked a hundred more times
   * with the same value.
   */
  function invalidateAccessToken() {
    password = ""
    passwordChecked = false
  }

  /** The Gmail manager has these; an IMAP account reaches neither, and
   * `MailAccount` should not have to ask which provider it holds before
   * calling one.
   */
  function beginLogin() {  }
  function cancelLogin() {
    sessionGeneration++
    loginBusy = false
    pendingPassword = ""
  }

  onAccountIdChanged: {
    cancelLogin()
    password = ""
    passwordChecked = false
    lookupHandled = false
    credentialLookupSerial++
    credentialLookupBusy = false
    finishWaiters("", "The mailbox changed before its credential was loaded")
    if (credentialWriteBusy && credentialWriteAccount !== "")
      pendingCredentialDelete = credentialWriteAccount
  }

}
