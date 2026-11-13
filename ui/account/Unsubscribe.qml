import QtQuick
import "../message/Message.js" as Mail
import "../message/Unsubscribe.js" as Unsub

QtObject {
  id: unsubscribeAction

  required property var account


  function readerSelection() {
    return {accountId: account.accountId, messageId: account.selectedId,
      revision: account.detailSerial}
  }

  function isCurrentSelection(selection) {
    return selection.accountId === account.accountId
      && selection.messageId === account.selectedId
      && selection.revision === account.detailSerial
  }

  function run() {
    if (account.unsubscribing || account.unsubscribeDone !== "") return
    var info = account.selectedUnsubscribe
    var how = Unsub.plan(info, account.canSend)
    if (how === "") return
    account.clearNotice()

    if (how === "browser") {
      if (account.platform && typeof account.platform.openExternal === "function")
        account.platform.openExternal(info.url)
      // Invariant: Opening the provider's page does not prove the subscription was removed.
      account.unsubscribeDone = "The unsubscribe page is open in your browser"
      return
    }

    if (how === "mail") {
      if (!account.ready) {
        account.fail("Sign in before unsubscribing")
        return
      }
      var selection = readerSelection()
      account.unsubscribing = true
      account.api.sendMessage(Mail.buildSendPayload({
        // Invariant: Unsubscribe uses the original recipient alias, which may be the only address the list knows.
        from: account.receivedAsAddress,
        fromName: account.receivedAsName,
        accountAddress: account.ownAddress,
        to: info.mail.to,
        subject: info.mail.subject,
        body: info.mail.body
      }), function(payload, error) {
        account.unsubscribing = false
        if (!isCurrentSelection(selection)) return
        if (error) {
          account.fail(error)
          return
        }
        account.unsubscribeDone = "Unsubscribe request sent to " + info.mail.to
      })
      return
    }

    postUnsubscribe(info.postUrl)
  }

  // Invariant: Rust validates public destinations and resolved addresses without redirects; Qt XHR would bypass revalidation on redirect.
  function postUnsubscribe(url) {
    if (!Unsub.isPostableUrl(url)) {
      account.fail("That unsubscribe address is not one this can post to")
      return
    }
    account.unsubscribing = true
    if (!account.backend || !account.backend.ready) {
      account.unsubscribing = false
      account.fail("The mail backend is not ready")
      return
    }
    var selection = readerSelection()
    account.backend.call("public.unsubscribe", { url: String(url) }, function(result, error) {
      var status = result ? Number(result.status || 0) : 0
      account.unsubscribing = false
      if (!isCurrentSelection(selection)) return
      account.unsubscribeDone = ""
      if (error || status === 0) {
        account.fail("The unsubscribe request could not be sent")
        return
      }
      if (status >= 200 && status < 300) {
        account.unsubscribeDone = "Unsubscribed from this list"
        return
      }
      // Invariant: A redirect has not fulfilled the one-click request and points to an unvalidated destination.
      account.fail(status >= 300 && status < 400
        ? "This list answered with a redirect instead of unsubscribing (" + status + ")"
        : "This list refused the unsubscribe request (" + status + ")")
    })
  }
}
