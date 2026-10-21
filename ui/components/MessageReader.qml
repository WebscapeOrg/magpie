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

// Invariant: only sanitized message documents may reach Qt rich text; raw sender markup can fetch
// tracking or local-network resources.
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
  property string bodyMode: "reader"
  property real zoom: 1.0
  property bool alwaysRenderHeavyMessages: false
  property string contentDirection: Direction.MODE_DEFAULT
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
  signal addressMenuRequested(var addresses, real sceneX, real sceneY)
  property bool agentOpen: false
  property bool agentWorking: false
  property bool agentAttention: false


  readonly property bool showsRail: !!service && service.showsRail === true
  readonly property var conversationStops: !root.showsRail ? []
    : (service.conversationProjection ? service.conversationProjection.stops || [] : [])
  readonly property string conversationCaption: !root.showsRail ? ""
    : (service.conversationProjection ? service.conversationProjection.caption || "" : "")

  // Invariant: defer rail scrolling until the new conversation’s Column has laid out its stops.
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

  // Invariant: use the service’s composed selection ID; a provider-local summary ID can address the
  // wrong mailbox in unified views.
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

  // Invariant: subject and body direction are independent; sender element-level direction remains
  // authoritative.
  readonly property string subjectDirection: Direction.forced(root.contentDirection)
    || String(root.summary ? root.summary.subjectDirection || "" : "")
  readonly property string bodyDirection: Direction.forced(root.contentDirection)
    || String(root.service && root.service.selectedBody
      ? root.service.selectedBody.bodyDirection || "" : "")
  readonly property string headerDirection: Direction.forced(root.contentDirection)

  // Invariant: undefined alignment preserves Qt’s first-strong-character default when no direction
  // is forced.
  readonly property var subjectAlignment: Direction.hasAnswer(root.subjectDirection)
    ? (Direction.isRightToLeft(root.subjectDirection) ? Text.AlignRight : Text.AlignLeft)
    : undefined
  readonly property var headerAlignment: Direction.hasAnswer(root.headerDirection)
    ? (Direction.isRightToLeft(root.headerDirection) ? Text.AlignRight : Text.AlignLeft)
    : undefined
  // Invariant: Qt rich text fetches remote img sources; only explicitly prepared raster bytes may
  // restore blocked images.
  readonly property bool hasHtml: !!service && !!service.selectedHasHtml
  // Performance: relayout reuses the parsed document rather than reparsing sender HTML.
  readonly property var bodyDocument: service ? service.selectedDocument : null
  // Performance: all reading modes share one parse and require neither refetch nor reparse when
  // switched.
  readonly property var readerDocument: service ? service.selectedReaderDocument : null
  readonly property int remoteImages: !service ? 0
    : root.shownMode === "reader" ? service.selectedReaderRemoteImages
    : service.selectedRemoteImages
  readonly property bool remoteImagesAllowed: !!service && service.remoteImagesAllowed

  readonly property var bodyOffer: ({
    html: root.hasHtml,
    reader: !!root.readerDocument && !!root.service && !root.service.selectedReaderEmpty,
    readerHeavy: !!root.service && root.service.selectedReaderTooHeavy,
    originalHeavy: !!root.service && root.service.selectedTooHeavy,
    forced: root.alwaysRenderHeavyMessages || root.forceRichAnyway
  })
  readonly property string shownMode: Html.resolveBodyMode(root.bodyMode, root.bodyOffer)
  readonly property bool richBody: root.shownMode !== "plain"
  readonly property bool tooHeavy: Html.bodyModeRefused(root.bodyMode, root.bodyOffer)
  readonly property bool readingEmpty: Html.bodyModeEmptied(root.bodyMode, root.bodyOffer)

  readonly property string unsubscribeLabel: service ? service.unsubscribeLabel : ""
  readonly property string unsubscribeDetail: service ? service.unsubscribeDetail : ""
  readonly property bool unsubscribing: !!service && service.unsubscribing

  // Invariant: image markers apply only to HTML-derived plain text; a native text/plain marker is
  // literal sender content.
  readonly property string bodySource: service && service.selectedBody
    ? String(service.selectedBody.source || "") : ""
  readonly property var imageSources: service ? service.selectedImages : []

  // Invariant: the inset depends on the Flickable width, not the resulting text width, to avoid a
  // layout feedback loop.
  readonly property bool narrowBody: bodyFlick.width > 0
    && bodyFlick.width < MailStyle.space(420)
  readonly property int pageInset: narrowBody ? MailStyle.space(8) : MailStyle.space(14)
  readonly property int bodyInset: pageInset
  readonly property int bodyWidth: Math.max(80, bodyFlick.width - bodyInset * 2)
  readonly property int bodyFontSize: Math.max(7, Math.round(MailStyle.messageSize * root.zoom))
  readonly property int contentWidthLimit: Html.readingColumnWidth(root.bodyWidth, MailStyle.space(800))
  readonly property int preferredBodyWidth: root.shownMode === "original"
    ? Html.preferredContentWidth(root.bodyDocument, root.contentWidthLimit)
    : root.contentWidthLimit
  readonly property int bodyOffset: root.shownMode === "reader"
    ? Html.readingColumnOffset(root.bodyWidth, root.preferredBodyWidth) : 0
  // Performance: quantize render width so splitter drags do not rebuild the document every frame.
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

  ReaderSkeleton {
    anchors.fill: parent
    visible: !root.summary && !!root.service && root.service.detailLoading
    textColor: root.textColor
    panelFontFamily: root.panelFontFamily
  }

  ReaderSkeleton {
    anchors.fill: bodyFlick
    z: 1
    visible: !!root.summary && !!root.service && root.service.detailLoading
      && !root.service.detailPainted
    textColor: root.textColor
    panelFontFamily: root.panelFontFamily
  }


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
          // Invariant: sender-controlled headers must remain plain text to prevent Qt resource
          // loading.
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


  // Invariant: hide the fixed-width conversation rail when it would leave the body below its
  // minimum reading width.
  readonly property bool fitsRail: width >= rail.implicitWidth + MailStyle.space(260)

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


  Column {
    id: notices
    anchors.top: headerBlock.bottom
    anchors.left: parent.left
    anchors.right: rail.visible ? rail.left : parent.right
    anchors.leftMargin: root.pageInset
    anchors.rightMargin: root.pageInset
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

    // Invariant: an empty-body notice is valid only after detail loading has finished.
    ReaderNotice {
      width: parent.width
      visible: !!root.summary && !!root.service
        && !root.service.detailLoading && root.service.detailPainted
        && root.bodySource === "" && !root.hasHtml
        && (root.service.selectedAttachments || []).length === 0
      text: "This message has no text to show"
      actionLabel: !root.service || root.service.canOpenOnWeb ? "Open on the web..." : ""
      textColor: root.textColor
      dimColor: root.dimColor
      accentColor: root.accentColor
      panelFontFamily: root.panelFontFamily
      onActivated: if (root.service && root.summary) root.service.openInBrowser(root.selectedId)
    }

    ReaderNotice {
      width: parent.width
      visible: !!root.summary && root.richBody
        && !root.remoteImagesAllowed && root.remoteImages > 0
      text: (root.remoteImages === 1 ? "1 image is blocked" : root.remoteImages + " images are blocked")
        + ": loading them tells the sender this message was opened"
      actionLabel: "Always show"
      textColor: root.textColor
      dimColor: root.dimColor
      accentColor: root.accentColor
      panelFontFamily: root.panelFontFamily
      onActivated: if (root.service) root.service.showRemoteImages()
    }

    ReaderNotice {
      width: parent.width
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


  Flickable {
    id: bodyFlick
    objectName: "messageBodyScroller"

    WheelScroller { view: bodyFlick }
    anchors.top: notices.bottom
    anchors.left: parent.left
    anchors.right: rail.visible ? rail.left : parent.right
    anchors.bottom: footerBackdrop.visible ? footerBackdrop.top : parent.bottom
    contentWidth: width
    contentHeight: bodyText.y + bodyText.implicitHeight + MailStyle.space(28)
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    visible: !!root.summary
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    // Invariant: invitation cards must scroll with the message; long guest lists can exceed the
    // viewport.
    InviteCard {
      id: inviteCard
      objectName: "eventCard"
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
      onOpenRequested: function(url) { root.openLink(url) }
    }

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
      textFormat: TextEdit.RichText
      // Invariant: formatted/reader documents are sanitized; plain mode is built only from escaped
      // text and image markers.
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
      font.pixelSize: root.bodyFontSize
      onLinkActivated: function(link) {
        var image = Html.imageLinkIndex(link)
        if (image > 0) {
          var sources = root.imageSources
          // Invariant: an image marker must never hand a sender URL to Qt; the account supplies
          // prepared raster bytes.
          if (image <= sources.length) root.openImageMarker(sources[image - 1])
          return
        }
        root.openLink(link)
      }

      // Invariant: only right-button presses are intercepted so normal TextEdit selection remains
      // available.
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


  // Invariant: the footer needs an opaque surface to prevent scrolled message text overlapping
  // controls.
  Rectangle {
    id: footerBackdrop
    anchors.left: parent.left
    // Invariant: extend only the footer’s surface across the splitter hit target; preserve aligned
    // content and splitter input.
    anchors.leftMargin: -root.leadingBoundaryOverlap
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: footer.implicitHeight + MailStyle.space(10)
    color: root.backgroundColor
    visible: footer.visible

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

    Item {
      id: actionsRow
      objectName: "readerToolbar"
      width: parent.width
      // Invariant: put the mode picker on a separate line when both control groups cannot fit.
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

        // Invariant: keep destructive actions separated from reply/forward, with separator height
        // derived from the buttons.
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

        // Invariant: an account with no archive capability must not expose the archive action.
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

      // Invariant: the mode-picker slot owns placement; reading the Row’s own unresolved height
      // creates a binding loop.
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

  // Invariant: the picker retains the user’s requested mode when a heavy message temporarily falls
  // back.
  component ModeButton: Widgets.Button {
    required property string mode
    property bool firstSegment: false
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
