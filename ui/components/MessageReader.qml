import QtQuick
import "../controls" as Widgets
import "../settings"
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "../message/Direction.js" as Direction
import "../message/Html.js" as Html
import "../message/Message.js" as Mail
import "../message/Mailto.js" as Mailto
import "../message/AttachmentPreview.js" as Preview
import "../account/Model.js" as Model

// The right column. The body goes through Qt's own rich text engine — a real
// HTML renderer, not a browser — after Html.sanitize has removed what Qt would
// render badly and the remote images that would otherwise fire every tracking
// pixel in the message the instant it opens.
Item {
  id: root

  required property var service
  required property color textColor
  required property color backgroundColor
  required property color accentColor
  required property color linkColor
  required property color dimColor
  required property color popupBackgroundColor
  required property color popupBorderColor
  required property real leadingBoundaryOverlap
  required property color dimmerColor
  required property string panelFontFamily
  // Which of the three ways of reading a message this window is set to. The
  // window's preference, not this message's: it may not be the one on screen,
  // because a message can be too heavy to draw the chosen way.
  property string bodyMode: "reader"
  property real zoom: 1.0
  property bool alwaysRenderHeavyMessages: false
  // How the direction of a message's own text is arrived at: read off the text,
  // or fixed by the reader. Not the direction itself — that is per message.
  property string contentDirection: Direction.MODE_DEFAULT
  // Set by the reader itself when a document is too heavy to lay out, and
  // cleared by the user asking for it anyway.
  property bool forceRichAnyway: false

  signal memberRequested(string id)
  signal memberMenuRequested(string id, real sceneX, real sceneY)
  signal bodyModeRequested(string mode)
  signal zoomRequested(real step)
  signal zoomResetRequested()
  signal composeRequested(string mode)
  signal mailtoRequested(string url)
  signal snoozeRequested(real sceneX, real sceneY)
  signal actionRequested(string action)
  signal agentRequested(real sceneX, real sceneY)
  // A right-click on the From line or the To line: the addresses on it, and
  // where the menu goes. What is done with them is the window's decision.
  signal addressMenuRequested(var addresses, real sceneX, real sceneY)
  // Whether the agent popup is up for this message, and whether a job is
  // running on it — passed down like every other fact the reader draws.
  property bool agentOpen: false
  property bool agentWorking: false
  property bool agentAttention: false

  // ------------------------------------------------------- the conversation

  // The rail down the right edge: every counted member of the open message's
  // conversation, oldest first, as a stop that opens in this same reader.
  //
  // Drawn above the seam for any provider that collapses its listing, off the
  // block the row was opened with — so a count of 0, which is what a provider
  // that does not collapse reports and what HEY reports for rows that already
  // are conversations, draws nothing at all. The account owns both decisions;
  // this asks.
  readonly property bool showsRail: !!service && service.showsRail === true
  readonly property var conversationStops: !root.showsRail ? []
    : (service.conversationProjection ? service.conversationProjection.stops || [] : [])
  readonly property string conversationCaption: !root.showsRail ? ""
    : (service.conversationProjection ? service.conversationProjection.caption || "" : "")

  // The member the rail should have on screen, revealed with the smallest
  // scroll — the list cursor's rule. Watched rather than called from the click,
  // because `n` and `p` move the reader from the keyboard and a stop opened
  // from off the bottom of the rail has to come into view either way.
  //
  // Deferred a turn: a conversation opened for the first time changes the stops
  // and lays them out in the same frame, and a scroll computed before the
  // Column has heights is a scroll to the wrong place.
  onConversationStopsChanged: if (root.showsRail) Qt.callLater(root.revealOpenStop)
  function revealOpenStop() {
    if (root.showsRail && root.service) rail.reveal(root.service.selectedId)
  }

  function openLink(url) {
    if (Mailto.parse(url)) {
      root.mailtoRequested(url)
      return
    }
    var opened = Html.externallyOpenableHttpUrl(url)
    if (opened === "") return
    if (root.service && typeof root.service.openExternal === "function")
      root.service.openExternal(opened)
  }

  property int imageRequestSerial: 0
  readonly property var imageOwner: service ? service.reading : null
  onImageOwnerChanged: resetImageMarker()
  onVisibleChanged: if (!visible) resetImageMarker()

  function resetImageMarker() {
    imageRequestSerial++
    imagePopover.close()
  }

  function openImageMarker(source) {
    var requestSerial = ++imageRequestSerial
    var wanted = String(source || "")
    if (Html.isRasterDataImage(wanted)) {
      imagePopover.show(wanted)
      return
    }
    if (!root.service || typeof root.service.fetchDisplayImage !== "function") {
      imagePopover.showPrepared(wanted, "")
      return
    }
    root.service.fetchDisplayImage(wanted, function(data) {
      if (!root || requestSerial !== root.imageRequestSerial) return
      imagePopover.showPrepared(wanted, data)
    })
  }

  function scrollBy(steps) {
    var maximum = Math.max(0, bodyFlick.contentHeight - bodyFlick.height)
    bodyFlick.contentY = Math.max(0, Math.min(maximum,
      bodyFlick.contentY + steps * MailStyle.space(20)))
  }

  readonly property var summary: service ? service.selectedMessage : null
  readonly property bool isDraft: !!summary && summary.isDraft === true

  // The id the service answers to, which is not always the one on the summary.
  // A list made of several mailboxes addresses a row by mailbox and id, and the
  // account that owns the message only ever knows its own half of that — so a
  // call made with the summary's own id reaches no mailbox at all. This is the
  // composed id where there is one and the same string everywhere else, which
  // is what the list and the compose view already hand back.
  readonly property string selectedId: service ? String(service.selectedId || "") : ""

  readonly property var attachments: service ? service.selectedAttachments || [] : []
  property var attachmentPreviews: ({})
  property var attachmentPreviewStates: ({})
  property var attachmentPreviewQueue: []
  property var attachmentPreviewHandle: null
  property int attachmentPreviewSerial: 0
  property bool attachmentPreviewBusy: false
  property int attachmentPreviewBytes: 0
  onSelectedIdChanged: { resetAttachments(); resetImageMarker() }
  onServiceChanged: { resetAttachments(); resetImageMarker() }
  onAttachmentsChanged: resetAttachments()

  function resetAttachments() {
    attachmentPreviewSerial++
    if (attachmentPreviewHandle && typeof attachmentPreviewHandle.cancel === "function")
      attachmentPreviewHandle.cancel()
    attachmentPreviewHandle = null
    attachmentPreviewQueue = []
    attachmentPreviewBusy = false
    attachmentPreviews = ({})
    attachmentPreviewStates = ({})
    attachmentPreviewBytes = 0
    attachmentFlick.cancelFlick()
    attachmentFlick.contentX = 0
  }

  function queueAttachmentPreview(attachment) {
    var key = "part:" + String(attachment && attachment.attachmentId || "")
    if (!Preview.supported(attachment) || attachmentPreviewStates[key]) return
    var states = Object.assign({}, attachmentPreviewStates)
    var bytes = Math.max(1, Number(attachment.size) || 8 * 1024 * 1024)
    if (attachmentPreviewBytes + bytes > 16 * 1024 * 1024) {
      states[key] = "unavailable"
      attachmentPreviewStates = states
      return
    }
    attachmentPreviewBytes += bytes
    states[key] = "loading"
    attachmentPreviewStates = states
    attachmentPreviewQueue = attachmentPreviewQueue.concat([attachment])
    fetchNextAttachmentPreview()
  }

  function fetchNextAttachmentPreview() {
    if (attachmentPreviewBusy || attachmentPreviewQueue.length === 0) return
    var queue = attachmentPreviewQueue.slice()
    var attachment = queue.shift()
    attachmentPreviewQueue = queue
    var key = "part:" + String(attachment.attachmentId)
    var serial = attachmentPreviewSerial
    attachmentPreviewBusy = true
    function done(data) {
      if (!root || serial !== root.attachmentPreviewSerial) return
      var source = Preview.rasterSource(data)
      var sources = Object.assign({}, root.attachmentPreviews)
      sources[key] = source
      root.attachmentPreviews = sources
      var states = Object.assign({}, root.attachmentPreviewStates)
      states[key] = source === "" ? "unavailable" : "ready"
      root.attachmentPreviewStates = states
      root.attachmentPreviewBusy = false
      root.attachmentPreviewHandle = null
      Qt.callLater(root.fetchNextAttachmentPreview)
    }
    if (!service || typeof service.previewAttachment !== "function") { done(""); return }
    var handle = service.previewAttachment(selectedId, attachment, done)
    if (attachmentPreviewBusy && serial === attachmentPreviewSerial) attachmentPreviewHandle = handle
  }

  function revealAttachment(card) {
    var right = card.x + card.width
    if (card.x < attachmentFlick.contentX) attachmentFlick.contentX = card.x
    else if (right > attachmentFlick.contentX + attachmentFlick.width)
      attachmentFlick.contentX = Math.max(0, right - attachmentFlick.width)
  }

  // Which way this message runs.
  //
  // The subject is asked separately from the body, and not as an optimisation:
  // they can disagree honestly. A reply prefix is Latin whatever the thread is
  // written in, so `Re: مرحبا` needs the prefix set aside before the question
  // is asked, while the body has no such wrapper around it.
  //
  // The body is read from the message's plain text rather than from its markup.
  // That is the same text in all three view modes, so switching between them
  // never changes which way the message reads — and it is the message's own
  // words rather than a template's, which is what the direction is a fact
  // about.
  //
  // What comes back is the document's base direction, which a sender's own
  // `dir` still overrides element by element. It is a default for the parts of
  // the message that state nothing, not a ruling over the parts that do.
  readonly property string subjectDirection: Direction.forced(root.contentDirection)
    || String(root.summary ? root.summary.subjectDirection || "" : "")
  readonly property string bodyDirection: Direction.forced(root.contentDirection)
    || String(root.service && root.service.selectedBody
      ? root.service.selectedBody.bodyDirection || "" : "")
  // The header lines below the subject carry a name, an address and a date, all
  // of which Qt lays out correctly from their own first strong character. There
  // is nothing to add on Auto, and a chosen direction still has to reach them.
  readonly property string headerDirection: Direction.forced(root.contentDirection)

  // `undefined` rather than a default: a `Text` whose alignment is never set
  // follows the direction of its own text, and that is the behaviour to leave
  // in place wherever there is no answer to give it. Assigning Qt's own default
  // back would render the same and would be one more thing to keep true.
  readonly property var subjectAlignment: Direction.hasAnswer(root.subjectDirection)
    ? (Direction.isRightToLeft(root.subjectDirection) ? Text.AlignRight : Text.AlignLeft)
    : undefined
  readonly property var headerAlignment: Direction.hasAnswer(root.headerDirection)
    ? (Direction.isRightToLeft(root.headerDirection) ? Text.AlignRight : Text.AlignLeft)
    : undefined
  // Already sanitised by the service, remote images and all removed. Qt's rich
  // text engine fetches an <img src="https://..."> for real, so leaving them in
  // would fire every tracking pixel in the message the instant it opened, and
  // would let a crafted one aim a request at whatever is listening on this
  // machine. They come back only when the reader asks, for this message alone.
  readonly property bool hasHtml: !!service && !!service.selectedHasHtml
  // The parsed form of the same document. Fitting it to this window is done on
  // the way out, so this is rebuilt on every relayout without being reparsed.
  readonly property var bodyDocument: service ? service.selectedDocument : null
  // The same message rebuilt for reading: paragraphs, headings, lists and
  // links, with none of the sender's presentation in it. Built beside the one
  // above off the same parse, so changing mode costs neither a fetch nor a
  // reparse — which is also why all three are available at once here.
  readonly property var readerDocument: service ? service.selectedReaderDocument : null
  // The blocked pictures of the reading actually on screen. Reading mode
  // shows fewer of a sender's images than the sanitised document does, and a
  // notice that counted the other one's would offer to load what is not there.
  readonly property int remoteImages: !service ? 0
    : root.shownMode === "reader" ? service.selectedReaderRemoteImages
    : service.selectedRemoteImages
  readonly property bool remoteImagesAllowed: !!service && service.remoteImagesAllowed

  // What this message can actually be drawn as, which is the question
  // `Html.resolveBodyMode` answers the chosen mode against. `forced` is the
  // reader having insisted on a document the bounds refused.
  readonly property var bodyOffer: ({
    html: root.hasHtml,
    reader: !!root.readerDocument && !!root.service && !root.service.selectedReaderEmpty,
    readerHeavy: !!root.service && root.service.selectedReaderTooHeavy,
    originalHeavy: !!root.service && root.service.selectedTooHeavy,
    forced: root.alwaysRenderHeavyMessages || root.forceRichAnyway
  })
  // The mode on screen, which is the chosen one unless this message cannot be
  // drawn that way.
  readonly property string shownMode: Html.resolveBodyMode(root.bodyMode, root.bodyOffer)
  readonly property bool richBody: root.shownMode !== "plain"
  // Plain text nobody asked for, which is one of the two the notices explain.
  readonly property bool tooHeavy: Html.bodyModeRefused(root.bodyMode, root.bodyOffer)
  // And the other: reading was asked for and there was nothing to rebuild.
  readonly property bool readingEmpty: Html.bodyModeEmptied(root.bodyMode, root.bodyOffer)

  // Empty for everything that is not a mailing list. The label carries its own
  // trailing "..." when the only way off this list is a page in a browser,
  // because that is the same decision as which way off it there is — and the
  // service is where it is made.
  readonly property string unsubscribeLabel: service ? service.unsubscribeLabel : ""
  readonly property string unsubscribeDetail: service ? service.unsubscribeDetail : ""
  readonly property bool unsubscribing: !!service && service.unsubscribing

  // Image markers only mean something when the plain text was made from the
  // HTML: a message that shipped its own text/plain part never had images in
  // it, and anything looking like a marker there is the sender's own words.
  readonly property string bodySource: service && service.selectedBody
    ? String(service.selectedBody.source || "") : ""
  readonly property var imageSources: service ? service.selectedImages : []

  // At a narrow window the reader gives up most of its own gutter, and the
  // sender's horizontal padding is stripped as well. Keyed off the flickable's
  // width rather than the text's, so the inset cannot feed back into itself.
  readonly property bool narrowBody: bodyFlick.width > 0
    && bodyFlick.width < MailStyle.space(420)
  // One inset for the whole page. Giving the body a narrower one bought a few
  // pixels and cost the alignment: the message text started to the left of the
  // subject above it and the toolbar below, which reads as a mistake long
  // before it reads as extra room. The space is reclaimed from the sender's own
  // padding instead, which is where it was being wasted.
  readonly property int pageInset: narrowBody ? MailStyle.space(8) : MailStyle.space(14)
  readonly property int bodyInset: pageInset
  readonly property int bodyWidth: Math.max(80, bodyFlick.width - bodyInset * 2)
  // Zoom changes the message type without changing the surrounding chrome.
  readonly property int bodyFontSize: Math.max(7, Math.round(MailStyle.messageSize * root.zoom))
  // All three modes share the same maximum; narrow panels use what fits.
  readonly property int contentWidthLimit: Html.readingColumnWidth(root.bodyWidth, MailStyle.space(800))
  readonly property int preferredBodyWidth: root.shownMode === "original"
    ? Html.preferredContentWidth(root.bodyDocument, root.contentWidthLimit)
    : root.contentWidthLimit
  // Reading mode centres its column in whatever the panel has spare. The other
  // two start at the page inset, because the sender's own layout and a
  // plain-text body both begin at the left edge.
  readonly property int bodyOffset: root.shownMode === "reader"
    ? Html.readingColumnOffset(root.bodyWidth, root.preferredBodyWidth) : 0
  // Quantised, because this is a dependency of the document itself: bound to
  // the exact width, dragging the splitter would rebuild and re-lay-out the
  // whole message on every frame.
  readonly property int imageWidth: Math.round(root.preferredBodyWidth / 20) * 20

  ReaderBlankSlate {
    anchors.fill: parent
    visible: !root.summary && !(root.service && root.service.detailLoading)
    service: root.service
    textColor: root.textColor
    accentColor: root.accentColor
    dimColor: root.dimColor
    dimmerColor: root.dimmerColor
    panelFontFamily: root.panelFontFamily
  }

  // Nothing known at all, which after the reader learned to open on the list's
  // own row is only a message that is not in the list.
  ReaderSkeleton {
    anchors.fill: parent
    visible: !root.summary && !!root.service && root.service.detailLoading
    textColor: root.textColor
    panelFontFamily: root.panelFontFamily
  }

  // The headers are known and the body is not, which is every message being
  // opened for the first time. Over the body alone, so the sender and the
  // subject stay readable while it arrives — a whole-reader skeleton would
  // hide the very thing that just became available.
  //
  // `z` rather than declaration order: this has to sit above the body it
  // stands in for, and being above it should not depend on where in the file
  // the two happen to be written.
  ReaderSkeleton {
    anchors.fill: bodyFlick
    z: 1
    visible: !!root.summary && !!root.service && root.service.detailLoading
      && !root.service.detailPainted
    textColor: root.textColor
    panelFontFamily: root.panelFontFamily
  }

  // --------------------------------------------------------------- headers

  Item {
    id: headerBlock
    visible: !!root.summary
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.margins: root.pageInset
    implicitHeight: headerColumn.implicitHeight

    IconTextButton {
      id: continueDraftButton
      objectName: "reader-continue-draft-button"
      anchors.right: parent.right
      anchors.top: parent.top
      visible: root.isDraft
      iconName: "edit"
      text: "Continue editing"
      outline: true
      foreground: root.accentColor
      accent: root.accentColor
      fontFamily: root.panelFontFamily
      onClicked: root.composeRequested("draft")
    }

    Row {
      id: readerTriage
      anchors.right: parent.right
      anchors.top: parent.top
      visible: !root.isDraft
      IconButton {
        objectName: "reader-mark-unread"
        iconName: "unread"
        iconSize: Style.font.icon * 2.5
        tooltipText: "Mark unread · Shift+U"
        foreground: root.dimColor; hoverColor: root.textColor; fontFamily: root.panelFontFamily
        onClicked: root.actionRequested("markUnread")
      }
      IconButton {
        objectName: "reader-snooze"
        iconName: "snooze"
        iconSize: Style.font.icon * 2.5
        tooltipText: "Snooze until..."
        foreground: root.dimColor; hoverColor: root.textColor; fontFamily: root.panelFontFamily
        onClicked: { var at = mapToGlobal(0,height); root.snoozeRequested(at.x,at.y) }
      }
    }

    Column {
      id: headerColumn
      anchors.left: parent.left
      anchors.right: root.isDraft ? continueDraftButton.left : readerTriage.left
      anchors.rightMargin: MailStyle.space(8)
      anchors.top: parent.top
      spacing: MailStyle.space(4)

      Item {
        width: parent.width
        height: subjectLine.implicitHeight
        Rectangle {
          objectName: "reader-subject-selection"
          anchors.fill: parent
          radius: Style.cornerRadius
          visible: subjectLine.selected
          color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.08)
        }
        Text {
          id: subjectLine
          objectName: "reader-subject"
          width: parent.width
          // A stranger wrote this. Qt's default AutoText switches a string that
          // looks like markup into rich text, and rich text with an <img> in it is
          // a fetch — the same beacon the message body is stripped of.
          textFormat: Text.PlainText
          text: root.summary ? root.summary.subject : ""
          color: root.textColor
          font.family: root.panelFontFamily
          font.pixelSize: MailStyle.subtitle
          font.bold: true
          wrapMode: Text.WordWrap
          horizontalAlignment: root.subjectAlignment

          readonly property bool selected: subjectMenu.opened
          TapHandler {
            acceptedButtons: Qt.RightButton
            onTapped: function(eventPoint) {
              if (!root.summary) return
              // Anchor to the line's own lower edge, not the pointer, so the menu
              // lands in the same place however the line was pressed.
              var scene = subjectLine.mapToGlobal(0, subjectLine.height)
              subjectMenu.openAt(root.summary.subject, scene.x, scene.y)
            }
          }
        }
      }

      Text {
        id: fromLine
        width: parent.width
        textFormat: Text.PlainText
        text: root.summary
          ? root.summary.from.display + "  <" + root.summary.from.email + ">"
          : ""
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.bodySmall
        elide: Text.ElideRight
        horizontalAlignment: root.headerAlignment

        TapHandler {
          acceptedButtons: Qt.RightButton
          onTapped: function(eventPoint) {
            var scene = fromLine.mapToGlobal(eventPoint.position.x, eventPoint.position.y)
            root.addressMenuRequested(root.summary ? [root.summary.from] : [], scene.x, scene.y)
          }
        }
      }

      // Everyone the message went to — To, Cc and Bcc, which a sent message
      // carries — so a right-click on the line can name any of them.
      Text {
        id: toLine
        width: parent.width
        textFormat: Text.PlainText
        text: root.summary
          ? "to " + Mail.formatAddressList(root.summary.to, 3) + " · " + root.summary.fullTime
          : ""
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
        elide: Text.ElideRight
        horizontalAlignment: root.headerAlignment

        TapHandler {
          acceptedButtons: Qt.RightButton
          onTapped: function(eventPoint) {
            if (!root.summary) return
            var all = (root.summary.to || []).concat(root.summary.cc || [], root.summary.bcc || [])
            var scene = toLine.mapToGlobal(eventPoint.position.x, eventPoint.position.y)
            root.addressMenuRequested(all, scene.x, scene.y)
          }
        }
      }
    }
  }

  // ------------------------------------------------------------------ rail

  // The rail keeps its width against the body rather than shrinking with it, so
  // there is a pane width at which the two of them together leave the message
  // nothing. That width is not a designed layout: it is where the reader has
  // already replaced the list, and the fallback if this proves too tight is the
  // prototype's variant A — lines under the header — rather than a rail three
  // words wide. Until then the rail simply goes, and nothing else moves.
  readonly property bool fitsRail: width >= rail.implicitWidth + MailStyle.space(260)

  // From the header's bottom edge to the footer, its own scroll owner beside
  // the body — the way the list is beside the reader. It takes width and never
  // height: the message keeps its reading measure and a long conversation
  // scrolls inside the rail rather than lengthening the page.
  ConversationRail {
    id: rail
    objectName: "conversationRail"
    visible: !!root.summary && root.showsRail && root.fitsRail
    anchors.top: headerBlock.bottom
    anchors.topMargin: MailStyle.space(10)
    anchors.right: parent.right
    anchors.bottom: footerBackdrop.visible ? footerBackdrop.top : parent.bottom
    width: visible ? implicitWidth : 0
    stops: root.conversationStops
    caption: root.conversationCaption
    textColor: root.textColor
    backgroundColor: root.backgroundColor
    accentColor: root.accentColor
    dimColor: root.dimColor
    dimmerColor: root.dimmerColor
    panelFontFamily: root.panelFontFamily
    onMemberActivated: function(id) { root.memberRequested(id) }
    onMemberMenuRequested: function(id, sceneX, sceneY) {
      root.memberMenuRequested(id, sceneX, sceneY)
    }
  }

  // --------------------------------------------------------------- notices

  // Why this message does not look the way its sender meant it to, and the one
  // thing that would change that. A column rather than a chain of anchors:
  // three of these can be up at once, and each anchoring to whichever of the
  // others happened to be visible is a rule that has to be rewritten every
  // time a fourth is added.
  Column {
    id: notices
    anchors.top: headerBlock.bottom
    anchors.left: parent.left
    anchors.right: rail.visible ? rail.left : parent.right
    anchors.leftMargin: root.pageInset
    anchors.rightMargin: root.pageInset
    // No gap where there is nothing to separate. An empty Column is zero high,
    // and a margin above it would still push the message down.
    anchors.topMargin: height > 0 ? MailStyle.space(8) : 0
    spacing: MailStyle.space(6)

    ReaderNotice {
      width: parent.width
      visible: root.tooHeavy
      text: "Showing the plain text: this message is heavy enough to stall the shell"
      actionLabel: "Show anyway"
      textColor: root.textColor
      dimColor: root.dimColor
      accentColor: root.accentColor
      panelFontFamily: root.panelFontFamily
      onActivated: root.forceRichAnyway = true
    }

    ReaderNotice {
      width: parent.width
      visible: root.readingEmpty
      text: "Showing the sender's own formatting: there was nothing here to rebuild"
      textColor: root.textColor
      dimColor: root.dimColor
      accentColor: root.accentColor
      panelFontFamily: root.panelFontFamily
    }

    // A message with nothing in it is a real answer, and an empty reader on its
    // own does not look like one — it looks like something failed. HEY's own
    // sign-up mail is the case this exists for: the CLI serves those threads
    // with no body at all, so there is genuinely nothing to draw.
    //
    // Waits for the read to be done before saying it, because "no text" is only
    // true once nothing more is coming.
    ReaderNotice {
      width: parent.width
      visible: !!root.summary && !!root.service
        && !root.service.detailLoading && root.service.detailPainted
        && root.bodySource === "" && !root.hasHtml
        && (root.service.selectedAttachments || []).length === 0
      text: "This message has no text to show"
      // Only where there is somewhere to go and read it. The service decides
      // that, and the "..." is there because what it opens is a browser.
      actionLabel: !root.service || root.service.canOpenOnWeb ? "Open on the web..." : ""
      textColor: root.textColor
      dimColor: root.dimColor
      accentColor: root.accentColor
      panelFontFamily: root.panelFontFamily
      onActivated: if (root.service && root.summary) root.service.openInBrowser(root.selectedId)
    }

    // Under the heavy-document notice when both are up: one says why the
    // message looks plain, the other why it looks bare, and they are different
    // answers to different questions.
    ReaderNotice {
      width: parent.width
      visible: !!root.summary && root.richBody
        && !root.remoteImagesAllowed && root.remoteImages > 0
      text: (root.remoteImages === 1 ? "1 image is blocked" : root.remoteImages + " images are blocked")
        + ": loading them tells the sender this message was opened"
      // What the button does is turn them on for every message, and Settings
      // is where that is turned back off — so it says "always" rather than
      // letting somebody find out afterwards.
      actionLabel: "Always show"
      textColor: root.textColor
      dimColor: root.dimColor
      accentColor: root.accentColor
      panelFontFamily: root.panelFontFamily
      onActivated: if (root.service) root.service.showRemoteImages()
    }

    // Last of the three, because it is the only one that is not about how the
    // message is being drawn. The label carries its own "..." when what it
    // opens is a browser — the service decides that, since it is the same
    // decision as which of the three ways off a list this sender offers.
    ReaderNotice {
      width: parent.width
      // Stays up after the deed is done, saying what was done. A control that
      // vanishes under the pointer reads as a misclick, and "did that work?"
      // is a question the user may come back to this message to ask.
      visible: !!root.summary && root.unsubscribeDetail !== ""
      text: root.unsubscribeDetail
      actionLabel: root.unsubscribeLabel
      busy: root.unsubscribing
      busyLabel: "Unsubscribing..."
      textColor: root.textColor
      dimColor: root.dimColor
      accentColor: root.accentColor
      panelFontFamily: root.panelFontFamily
      onActivated: if (root.service) root.service.unsubscribe()
    }
  }

  // ------------------------------------------------------------------ body

  Flickable {
    id: bodyFlick
    objectName: "messageBodyScroller"

    WheelScroller { view: bodyFlick }
    anchors.top: notices.bottom
    anchors.left: parent.left
    // The content limit uses the space remaining beside the conversation rail.
    anchors.right: rail.visible ? rail.left : parent.right
    anchors.bottom: footerBackdrop.visible ? footerBackdrop.top : parent.bottom
    contentWidth: width
    contentHeight: bodyText.y + bodyText.implicitHeight + MailStyle.space(28)
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    visible: !!root.summary
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    // The meeting in the message, drawn as a meeting. Inside the flickable
    // rather than pinned above it: a recurring invitation with a dozen guests
    // is taller than the panel, and a card that cannot scroll would leave the
    // message itself with nowhere to be.
    InviteCard {
      id: inviteCard
      objectName: "eventCard"
      // This is application UI built from the calendar part, not content from
      // the sender's HTML. Reader mode narrows the mail below it, while this
      // card keeps the panel's full content width in every mode.
      x: root.bodyInset
      y: MailStyle.space(24)
      width: root.bodyWidth
      invite: root.service ? root.service.selectedInvite : null
      response: root.service ? root.service.selectedResponse : ""
      canRespond: !!root.service && root.service.canRespondToInvite
      sending: !!root.service && root.service.rsvpSending
      fallbackAvailable: !!root.service && root.service.rsvpFallbackAvailable === true
      calendarUrl: String(root.service && root.service.rsvpCalendarUrl || "")
      textColor: root.textColor
      accentColor: root.accentColor
      dimColor: root.dimColor
      dimmerColor: root.dimmerColor
      panelFontFamily: root.panelFontFamily
      onRespondRequested: function(answer) {
        if (root.service) root.service.rsvp(answer)
      }
      onMailOnlyRequested: function(answer) { if (root.service) root.service.rsvpMailOnly(answer) }
      // The same rule the body's own links obey: this leaves the app, and it
      // leaves it through the desktop's browser rather than anything here.
      onOpenRequested: function(url) { root.openLink(url) }
    }

    // What the agent found in the message, if the owner asked it to look:
    // a card per event, with the calendar's composer one press away.
    EventSuggestionCard {
      id: suggestionCard
      objectName: "eventSuggestions"
      x: root.bodyInset
      y: inviteCard.visible ? inviteCard.y + inviteCard.height + MailStyle.space(14) : MailStyle.space(24)
      width: root.bodyWidth
      suggestions: root.service && root.service.eventSuggestions ? root.service.eventSuggestions : []
      textColor: root.textColor
      accentColor: root.accentColor
      dimColor: root.dimColor
      dimmerColor: root.dimmerColor
      panelFontFamily: root.panelFontFamily
      onAddRequested: function(suggestion) { if (root.service) root.service.addSuggestedEvent(suggestion) }
      onDismissRequested: function(key) { if (root.service) root.service.dismissSuggestion(key) }
    }

    TextEdit {
      id: bodyText
      x: root.bodyInset + root.bodyOffset
      y: suggestionCard.visible
        ? suggestionCard.y + suggestionCard.height + MailStyle.space(14)
        : (inviteCard.visible
          ? inviteCard.y + inviteCard.height + MailStyle.space(14)
          : MailStyle.space(24))
      width: root.preferredBodyWidth
      readOnly: true
      selectByMouse: true
      wrapMode: TextEdit.Wrap
      // Rich text for all three, because all three are documents by the time
      // they get here.
      textFormat: TextEdit.RichText
      // Three documents, one parse. The reading one was rebuilt out of what the
      // message says and carries no sender markup at all; the formatted one is
      // the sender's own, sanitised; the plain one is built here from escaped
      // text, line breaks and marker links and nothing else, so it stays cheap
      // to lay out even for the messages whose own markup was too heavy to draw
      // in the first place.
      text: root.shownMode === "reader"
        ? Html.readerDocumentFor(root.readerDocument, ({
            foreground: root.textColor,
            background: root.backgroundColor,
            link: root.linkColor,
            quote: root.dimColor,
            fontSize: root.bodyFontSize,
            maxImageWidth: root.imageWidth,
            direction: root.bodyDirection
          }))
        : (root.shownMode === "original"
          ? Html.documentFor(root.bodyDocument, ({
              foreground: root.textColor,
              background: root.backgroundColor,
              link: root.linkColor,
              quote: root.dimColor,
              padding: 0,
              maxImageWidth: root.imageWidth,
              compact: root.narrowBody,
              direction: root.bodyDirection
            }))
          : Html.plainTextDocument(root.service ? root.service.selectedBody.text : "",
              ({
                foreground: root.textColor,
                background: root.backgroundColor,
                link: root.linkColor,
                direction: root.bodyDirection
              }), root.bodySource === "html"))
      color: root.textColor
      selectionColor: Style.selectionFillFor(root.textColor, root.accentColor)
      selectedTextColor: root.textColor
      font.family: MailStyle.messageFamily
      // Body text, where the chrome around it is bodySmall: this is the one
      // long-form thing in the window and the only one that is read rather than
      // scanned. At bodySmall it was 11px against the 9pt — twelve — of the
      // terminal beside it, so the message was the smallest text on a screen
      // whose owner had already said what size they read at.
      font.pixelSize: root.bodyFontSize
      onLinkActivated: function(link) {
        var image = Html.imageLinkIndex(link)
        if (image > 0) {
          var sources = root.imageSources
          // The marker names the sender's src. Qt must not fetch that URL
          // itself: the account prepares raster bytes, or the popover refuses.
          if (image <= sources.length) root.openImageMarker(sources[image - 1])
          return
        }
        root.openLink(link)
      }

      // Only the right button, so selecting text still works: the left one
      // passes through to the TextEdit. The hover half turns the I-beam into
      // a hand while a link is under the pointer; the press half opens the
      // text menu, naming the link the click landed on if there is one.
      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.RightButton
        cursorShape: bodyText.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.IBeamCursor
        onPressed: function(mouse) {
          var scene = bodyText.mapToGlobal(mouse.x, mouse.y)
          textMenu.openAt(bodyText, scene.x, scene.y, bodyText.linkAt(mouse.x, mouse.y))
        }
        onWheel: function(wheel) {
          if (!(wheel.modifiers & Qt.ControlModifier)) {
            wheel.accepted = false
            return
          }
          root.zoomRequested(wheel.angleDelta.y > 0 ? 0.1 : -0.1)
          wheel.accepted = true
        }
      }
    }
  }

  // ---------------------------------------------------------------- footer

  // The toolbar sits on its own ground rather than on whatever happens to be
  // scrolled behind it. Transparent, the message ran underneath the icons and
  // through the rule, which read as text overlapping the controls.
  Rectangle {
    id: footerBackdrop
    anchors.left: parent.left
    // The reader begins after the splitter's forgiving hit target, while its
    // visible rule sits at that target's leading edge. Extend only the surface
    // boundary across the gap so the two rules meet; footer content remains
    // aligned inside the reader and the splitter stays above it for input.
    anchors.leftMargin: -root.leadingBoundaryOverlap
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: footer.implicitHeight + MailStyle.space(10)
    color: root.backgroundColor
    visible: footer.visible

    // Edge to edge, not inset with the buttons: it separates the toolbar from
    // the message, and that division runs the full width of the window.
    PanelSeparator {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      foreground: root.textColor
    }
  }

  Column {
    id: footer
    anchors.bottom: parent.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    // Control frames share the status bar's eight-pixel chrome inset. The
    // page content keeps its wider reading inset; applying that to buttons as
    // well made their glyphs sit visibly farther inward than the chrome below.
    anchors.leftMargin: MailStyle.space(8)
    anchors.rightMargin: MailStyle.space(8)
    anchors.bottomMargin: MailStyle.space(4)
    spacing: MailStyle.space(4)
    visible: !!root.summary

    Flickable {
      id: attachmentFlick
      objectName: "attachment-scroller"
      width: parent.width
      visible: root.attachments.length > 0
      height: visible ? Math.min(MailStyle.space(112), Math.max(0,
        root.height - bodyFlick.y - actionsRow.implicitHeight - MailStyle.space(18)) * 0.4) : 0
      contentWidth: attachmentCards.implicitWidth
      contentHeight: height
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.HorizontalFlick
      ScrollBar.horizontal: ScrollBar { id: attachmentScrollBar; policy: ScrollBar.AsNeeded }

      function wheelScroll(event, horizontal) {
        var pixels = horizontal ? event.pixelDelta.x : event.pixelDelta.y
        var angle = horizontal ? event.angleDelta.x : event.angleDelta.y
        contentX = Model.wheelScrollByPixels(contentX, Model.wheelPixels(angle, pixels),
          contentWidth, width, originX, leftMargin, rightMargin)
        cancelFlick()
      }
      WheelHandler {
        orientation: Qt.Vertical
        acceptedDevices: PointerDevice.AllDevices
        blocking: true
        onWheel: function(event) { attachmentFlick.wheelScroll(event, false) }
      }
      WheelHandler {
        orientation: Qt.Horizontal
        acceptedDevices: PointerDevice.AllDevices
        blocking: true
        onWheel: function(event) { attachmentFlick.wheelScroll(event, true) }
      }

      Row {
        id: attachmentCards
        spacing: MailStyle.space(8)
        height: attachmentFlick.height - (attachmentScrollBar.visible
          ? attachmentScrollBar.height + MailStyle.space(4) : MailStyle.space(2))

        Repeater {
          model: root.attachments

          AttachmentCard {
            id: card
            required property var modelData
            readonly property string previewKey: "part:" + String(modelData && modelData.attachmentId || "")
            width: Math.min(implicitWidth, attachmentFlick.width)
            height: attachmentCards.height
            attachment: modelData
            previewSource: root.attachmentPreviews[previewKey] || ""
            previewState: root.attachmentPreviewStates[previewKey] || ""
            previewActive: attachmentFlick.visible && x + width > attachmentFlick.contentX
              && x < attachmentFlick.contentX + attachmentFlick.width
            onPreviewRequested: root.queueAttachmentPreview(modelData)
            onControlFocusedChanged: if (controlFocused) root.revealAttachment(card)
            saving: !!root.service && root.service.attachmentIsSaving(root.selectedId,
              modelData && modelData.attachmentId ? modelData.attachmentId : "")
            textColor: root.textColor
            dimColor: root.dimColor
            dimmerColor: root.dimmerColor
            accent: root.accentColor
            panelFontFamily: root.panelFontFamily
            onOpenRequested: function(attachment) {
              if (root.service && root.summary)
                root.service.openAttachment(root.selectedId, attachment)
            }
            onSaveRequested: function(attachment) {
              if (root.service && root.summary)
                root.service.saveAttachment(root.selectedId, attachment)
            }
          }
        }
      }
    }

    // Icons rather than labels: six actions fit where six words would not.
    //
    // Split in two. What you do to the message — answer it, file it, throw it
    // away — sits on the left where reading ends. How you look at it is not
    // something you do to it, so it goes to the far right, out of the path of
    // the actions that change something.
    Item {
      id: actionsRow
      objectName: "readerToolbar"
      width: parent.width
      // The mode picker takes its own line when the two of them will not fit
      // across the panel. A row of controls that overlaps another row of
      // controls is worse than a taller toolbar, and the reader can be as
      // narrow as its own minimum beside the list.
      readonly property bool stacked: messageActions.visible && messageActions.implicitWidth
        + viewTools.implicitWidth + MailStyle.space(24) > width
      implicitHeight: stacked
        ? messageActions.implicitHeight + MailStyle.space(4) + viewTools.implicitHeight
        : messageActions.implicitHeight

      Item {
        id: messageActions
        visible: !root.isDraft
        readonly property int gap: MailStyle.space(2)
        implicitWidth: trashButton.x + trashButton.width
        implicitHeight: Math.max(replyButton.height, replyAllButton.height,
          forwardButton.height, archiveButton.visible ? archiveButton.height : 0,
          trashButton.height)
        width: implicitWidth
        height: implicitHeight

        IconButton {
          iconSize: Style.font.icon * 2.5
          id: replyButton
          y: (parent.height - height) / 2
          iconName: "reply"; tooltipText: "Reply · r"
          foreground: root.dimColor; hoverColor: root.textColor; fontFamily: root.panelFontFamily
          onClicked: root.composeRequested("reply")
        }
        IconButton {
          iconSize: Style.font.icon * 2.5
          id: replyAllButton
          x: replyButton.x + replyButton.width + messageActions.gap
          y: (parent.height - height) / 2
          iconName: "replyAll"; tooltipText: "Reply all · a"
          foreground: root.dimColor; hoverColor: root.textColor; fontFamily: root.panelFontFamily
          onClicked: root.composeRequested("replyAll")
        }
        IconButton {
          iconSize: Style.font.icon * 2.5
          id: forwardButton
          x: replyAllButton.x + replyAllButton.width + messageActions.gap
          y: Math.round((parent.height - height) / 2)
          iconName: "forward"; tooltipText: "Forward · f"
          foreground: root.dimColor; hoverColor: root.textColor; fontFamily: root.panelFontFamily
          onClicked: root.composeRequested("forward")
        }

        // Answering a message and disposing of one are different intentions, and
        // one of them cannot be undone from here. The gap is wide enough that a
        // hand aiming at Forward cannot land on Archive.
        //
        // As tall as the buttons it stands between, taken from one of them rather
        // than from a constant: IconButton sizes itself from its icon, so a hard
        // number drifts. A one-pixel-high item in a Row aligns to the row's top
        // edge, which left the rule floating above the icons instead of level
        // with them.
        Item {
          id: actionGap
          x: forwardButton.x + forwardButton.width + messageActions.gap
          implicitWidth: MailStyle.space(28)
          implicitHeight: replyButton.implicitHeight
          width: implicitWidth
          height: parent.height

          PanelSeparator {
            anchors.centerIn: parent
            width: 1
            height: MailStyle.space(15)
            foreground: root.dimColor
          }
        }

        // No archive button where the account has nowhere to archive to. On
        // IMAP that is a move to a folder, and a server without one would have
        // this quietly do nothing — or worse, delete.
        IconButton {
          iconSize: Style.font.icon * 2.5
          id: archiveButton
          x: actionGap.x + actionGap.width + messageActions.gap
          y: Math.round((parent.height - height) / 2)
          visible: !root.service || root.service.canArchive
          iconName: "archive"; tooltipText: "Archive · e"
          foreground: root.dimColor; hoverColor: root.textColor; fontFamily: root.panelFontFamily
          onClicked: root.actionRequested("archive")
        }
        // Archive under a label, or move to a folder: the same picker `v`
        // opens, one press away in the reader too.
        IconButton {
          iconSize: Style.font.icon * 2.5
          id: moveButton
          objectName: "reader-move-button"
          x: (archiveButton.visible
            ? archiveButton.x + archiveButton.width
            : actionGap.x + actionGap.width) + messageActions.gap
          y: Math.round((parent.height - height) / 2)
          visible: !!root.service && root.service.canMoveToLabel
          iconName: "label"; tooltipText: "Move to... · v"
          foreground: root.dimColor; hoverColor: root.textColor; fontFamily: root.panelFontFamily
          onClicked: root.actionRequested("moveToLabel")
        }
        IconButton {
          iconSize: Style.font.icon * 2.5
          id: trashButton
          x: (moveButton.visible
            ? moveButton.x + moveButton.width
            : (archiveButton.visible
              ? archiveButton.x + archiveButton.width
              : actionGap.x + actionGap.width)) + messageActions.gap
          y: Math.round((parent.height - height) / 2)
          iconName: "trash"; tooltipText: "Move to trash · d"
          foreground: root.dimColor; hoverColor: root.textColor; fontFamily: root.panelFontFamily
          onClicked: root.actionRequested("trash")
        }

      }

      // The distance across the bar is the separation here, so these need no rule
      // of their own.
      //
      // Named rather than iconed. There is no drawing that says "the message as
      // its sender laid it out" and is not a guess of one, and telling the three
      // apart is the whole point of having them — so they say what they are, and
      // the one in use wears the kit's selected surface and its border rather
      // than only a colour.
      //
      // In a slot rather than anchored itself, because it sits beside the actions
      // at a comfortable width and under them at a narrow one, and an anchor
      // cannot be two things. The slot is what holds the position, so no binding
      // in here reads the Row's own height while the Row is still deciding it.
      Item {
        id: viewTools
        objectName: "readerViewTools"
        anchors.right: parent.right
        y: actionsRow.stacked ? messageActions.height + MailStyle.space(4) : 0
        implicitWidth: modeTrack.width
          + (openWebButton.visible ? MailStyle.space(6) + openWebButton.width : 0)
        implicitHeight: Math.max(modeTrack.height,
          openWebButton.visible ? openWebButton.height : 0)
        width: implicitWidth
        height: actionsRow.stacked ? implicitHeight : messageActions.height
        readonly property bool controlsAligned: !openWebButton.visible
          || Math.abs((modeTrack.y + modeTrack.height / 2)
            - (openWebButton.y + openWebButton.height / 2)) < 1

        // Three names for one setting, so they share a track, an outside edge
        // and the seams between them. The selected fill belongs to one segment
        // of one control rather than to a loose button beside two others.
        Rectangle {
          id: modeTrack
          objectName: "bodyModeTrack"
          y: Math.round((parent.height - height) / 2)
          width: modeSegments.implicitWidth
          height: modeSegments.implicitHeight
          radius: Style.cornerRadius
          color: "transparent"
          border.width: 1
          border.color: Style.normalBorderFor(root.textColor, root.accentColor)

          Row {
            id: modeSegments
            objectName: "bodyModeSegments"
            spacing: 0

            ModeButton {
              text: "Reader"
              tooltipText: "Rebuild this message for reading"
              mode: "reader"
              firstSegment: true
            }
            ModeButton {
              text: "Original"
              tooltipText: "Show the sender's own formatting"
              mode: "original"
            }
            ModeButton {
              text: "Plain"
              tooltipText: "Show plain text"
              mode: "plain"
            }
          }
        }

        // A separate action on the same toolbar. Its centre follows the mode
        // control's centre even where their natural heights differ.
        IconButton {
          iconSize: Style.font.icon * 2.5
          id: openWebButton
          objectName: "openWebButton"
          visible: !root.service || root.service.canOpenOnWeb
          x: modeTrack.width + MailStyle.space(6)
          y: modeTrack.y
          height: modeTrack.height
          iconName: "browser"; tooltipText: "Open in browser"
          foreground: root.dimColor; hoverColor: root.textColor
          fontFamily: root.panelFontFamily
          onClicked: if (root.service && root.summary) root.service.openInBrowser(root.selectedId)
        }
      }
    }
  }

  // One of the three ways of reading a message. `selected` is the window's
  // choice rather than what is on screen: a message too heavy to draw the
  // chosen way says so in its own notice, and a picker that quietly moved to
  // the mode it fell back to would leave nothing saying the choice still
  // stands for the next message.
  component ModeButton: Widgets.Button {
    required property string mode
    property bool firstSegment: false
    // Nothing to choose between where there is no markup: the text is then the
    // message rather than one reading of it.
    visible: root.hasHtml
    selected: root.bodyMode === mode
    bordered: false
    foreground: selected ? root.textColor : root.dimColor
    accent: root.accentColor
    fontFamily: root.panelFontFamily
    fontSize: MailStyle.caption
    horizontalPadding: MailStyle.space(7)
    verticalPadding: MailStyle.space(3)
    onClicked: root.bodyModeRequested(mode)

    Rectangle {
      visible: !parent.firstSegment
      width: 1
      height: parent.height
      color: modeTrack.border.color
    }
  }

  // The body's own menu: Copy, and the link under the pointer. Placed here
  // rather than in App so the menu can be tested with the body it reads.
  TextMenu {
    id: textMenu
    objectName: "reader-text-menu"
    textColor: root.textColor
    popupBackgroundColor: root.popupBackgroundColor
    popupBorderColor: root.popupBorderColor
    panelFontFamily: root.panelFontFamily
    onCopyRequested: function(text) {
      if (root.service && typeof root.service.copyText === "function") root.service.copyText(text)
    }
    onOpenLinkRequested: function(url) { root.openLink(url) }
  }

  // The subject's own menu: one row, the subject as written. Beside the
  // body's menu for the same reason that menu lives here.
  SubjectMenu {
    id: subjectMenu
    objectName: "reader-subject-menu"
    textColor: root.textColor
    popupBackgroundColor: root.popupBackgroundColor
    popupBorderColor: root.popupBorderColor
    panelFontFamily: root.panelFontFamily
    onCopyRequested: function(subject) {
      if (root.service && typeof root.service.copyText === "function") root.service.copyText(subject)
    }
  }

  ImagePopover {
    id: imagePopover
    textColor: root.textColor
    dimColor: root.dimColor
    popupBackgroundColor: root.popupBackgroundColor
    popupBorderColor: root.popupBorderColor
    panelFontFamily: root.panelFontFamily
  }
}
