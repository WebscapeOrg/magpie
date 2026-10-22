import QtQuick
import "../controls" as Widgets
import "../settings"
import "../search" as Search
import "../search/Completion.js" as Completion
import qs.Commons
import qs.Ui

Item {
  id: root

  required property color textColor
  required property color accentColor
  required property color dimColor
  required property color popupBackgroundColor
  required property color popupBorderColor
  required property string panelFontFamily
  property bool serverSearching: false
  property bool assistanceAvailable: false
  property var operators: []
  property var labels: []
  property Item overlayParent: root
  property int suggestionIndex: -1
  property string selectedSuggestionKey: ""
  property string dismissedText: "\u0000"
  property bool replacing: false
  property int helpSelectionStart: 0
  property int helpSelectionEnd: 0
  readonly property bool inputMethodComposing: field.inputMethodComposing
  readonly property var suggestions: assistanceAvailable && !field.inputMethodComposing
    ? Completion.suggestions(field.text,field.cursorPosition,field.selectionStart,field.selectionEnd,operators,labels) : []
  readonly property bool suggestionsOpen: assistanceAvailable && field.activeFocus && !help.opened
    && field.text !== dismissedText && suggestions.length > 0
  readonly property bool helpOpened: help.opened
  readonly property bool controlsFocused: helpButton.activeFocus || clearButton.activeFocus
  readonly property string editingContext: JSON.stringify([field.text,field.cursorPosition,field.selectionStart,field.selectionEnd])
  onEditingContextChanged: { suggestionIndex = -1; selectedSuggestionKey = "" }
  onSuggestionsChanged: retainSuggestion()
  onSuggestionsOpenChanged: if (suggestionsOpen) Qt.callLater(placeAssistance)
  onWidthChanged: Qt.callLater(placeAssistance)
  onHeightChanged: Qt.callLater(placeAssistance)
  onVisibleChanged: if (!visible) dismissAssistance()

  readonly property bool showServerLabel: width >= MailStyle.space(260)

  signal submitted(string query)
  signal cleared()
  signal keyPressed(var event)

  readonly property bool fieldFocused: field.activeFocus
  // Invariant: window shortcuts own Escape; a focused-item Keys handler would never receive it.
  readonly property string queryText: field.text

  implicitHeight: field.implicitHeight

  function focusField() {
    dismissedText = "\u0000"
    field.forceActiveFocus()
    field.selectAll()
  }

  function takeFocus() { if (visible) field.forceActiveFocus() }

  function dismissAssistance() {
    if (help.opened) { help.close(); return true }
    if (!suggestionsOpen) return false
    dismissedText = field.text
    return true
  }

  function moveSuggestion(delta) {
    if (!suggestionsOpen) return false
    var count = suggestions.length
    suggestionIndex = suggestionIndex < 0 ? (delta < 0 ? count - 1 : 0)
      : (suggestionIndex + delta + count) % count
    selectedSuggestionKey = suggestionKey(suggestions[suggestionIndex])
    return true
  }

  function suggestionKey(suggestion) {
    return JSON.stringify([suggestion.value,suggestion.start,suggestion.end])
  }

  function retainSuggestion() {
    var retained = -1
    for (var index = 0; selectedSuggestionKey !== "" && index < suggestions.length; index++) {
      if (suggestionKey(suggestions[index]) === selectedSuggestionKey) { retained = index; break }
    }
    suggestionIndex = retained
    if (retained < 0) selectedSuggestionKey = ""
  }

  function replaceRange(edit) {
    replacing = true
    field.cursorPosition = edit.start !== field.cursorPosition ? edit.start
      : edit.end !== edit.start ? edit.end : Math.max(0,edit.start - 1)
    field.select(edit.start,edit.end)
    field.remove(edit.start,edit.end)
    field.insert(edit.start,edit.value)
    field.cursorPosition = edit.start + edit.value.length
    dismissedText = field.text
    suggestionIndex = -1
    replacing = false
    takeFocus()
  }

  function completeSuggestion(index) {
    if (!suggestionsOpen || field.inputMethodComposing) return false
    var selected = typeof index === "number" ? index : Math.max(0,suggestionIndex)
    if (selected < 0 || selected >= suggestions.length) return false
    replaceRange(Completion.replacement(field.text,suggestions[selected]))
    return true
  }

  function accept() {
    if (field.inputMethodComposing) return false
    if (suggestionsOpen && suggestionIndex >= 0) return completeSuggestion(suggestionIndex)
    dismissedText = field.text
    root.submitted(field.text.trim())
    return true
  }

  function openHelp() {
    helpSelectionStart = field.selectionStart
    helpSelectionEnd = field.selectionEnd
    dismissedText = field.text
    help.open()
    placeAssistance()
  }

  function placeAssistance() {
    var container = overlayParent || root
    var anchor = root.mapToItem(container,0,root.height)
    var margin = MailStyle.space(8)
    var availableWidth = Math.max(0,container.width - margin * 2)
    matches.width = Math.min(MailStyle.space(380),availableWidth)
    help.width = Math.min(MailStyle.space(480),availableWidth)
    var below = Math.max(0,container.height - anchor.y - margin * 2)
    var above = Math.max(0,anchor.y - root.height - margin * 2)
    matches.maximumHeight = Math.min(MailStyle.space(340),Math.max(below,above))
    help.maximumHeight = Math.max(below,above)
    matches.x = Math.max(0,Math.min(anchor.x,container.width - matches.width - margin))
    help.x = Math.max(0,Math.min(anchor.x,container.width - help.width - margin))
    matches.y = Math.max(0,below >= matches.height ? anchor.y + margin : anchor.y - root.height - matches.height - margin)
    help.y = Math.max(0,below >= help.height ? anchor.y + margin : anchor.y - root.height - help.height - margin)
  }

  function clear() {
    field.remove(0,field.length)
    dismissedText = ""
    root.cleared()
  }

  function setQuery(text) {
    var value = String(text || "")
    if (value === "" || field.text.trim() !== value.trim()) field.text = value
    dismissedText = field.text
  }

  Widgets.TextField {
    id: field
    objectName: "search-query-field"
    anchors.fill: parent
    foreground: root.textColor
    accent: root.accentColor
    placeholderText: "Search mail..."
    Accessible.name: "Search mail"
    Accessible.description: root.suggestionsOpen && root.suggestionIndex >= 0
      ? root.suggestions[root.suggestionIndex].label + ". Suggestion " + (root.suggestionIndex + 1) + " of " + root.suggestions.length + ". Tab or Enter completes."
      : root.assistanceAvailable ? "Gmail filters available. Tab completes a suggestion. Enter searches." : "Press Enter to search."
    font.family: root.panelFontFamily
    font.pixelSize: MailStyle.bodySmall
    rightPadding: horizontalPadding + MailStyle.space(22)
      + (root.assistanceAvailable ? helpButton.width + MailStyle.space(3) : 0)
      + (root.serverSearching ? serverState.width + MailStyle.space(7) : 0)
    onAccepted: root.accept()
    onTextChanged: if (!root.replacing) root.dismissedText = "\u0000"
    Keys.onPressed: function(event) {
      if (!inputMethodComposing && root.suggestionsOpen) root.keyPressed(event)
    }

    background: Rectangle {
      radius: Style.cornerRadius
      color: field.activeFocus || field.hovered
        ? Style.hoverFillFor(root.textColor, root.accentColor)
        : Style.normalFillFor(root.textColor, root.accentColor)
      border.width: 1
      border.color: field.activeFocus
        ? Style.hoverBorderFor(root.textColor, root.accentColor)
        : Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.12)
    }
  }

  Item {
    id: serverState
    anchors.right: helpButton.visible ? helpButton.left : clearButton.left
    anchors.rightMargin: MailStyle.space(3)
    anchors.verticalCenter: parent.verticalCenter
    visible: root.serverSearching
    width: visible ? serverStateRow.implicitWidth : 0
    height: MailStyle.space(22)

    Row {
      id: serverStateRow
      anchors.centerIn: parent
      spacing: root.showServerLabel ? MailStyle.space(5) : 0

      ActionIcon {
        anchors.verticalCenter: parent.verticalCenter
        name: "refresh"
        iconSize: Style.font.iconSmall
        color: root.accentColor

        RotationAnimator on rotation {
          from: 0
          to: 360
          duration: 900
          loops: Animation.Infinite
          running: root.serverSearching
        }
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.showServerLabel
        text: "Searching server"
        textFormat: Text.PlainText
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: MailStyle.caption
      }
    }
  }

  Widgets.Button {
    id: helpButton
    objectName: "search-help-button"
    anchors.right: clearButton.left
    anchors.verticalCenter: parent.verticalCenter
    visible: root.assistanceAvailable
    text: "?"
    tooltipText: "Search help..."
    Accessible.name: "Search help..."
    selected: help.opened
    focusable: true
    foreground: root.textColor
    accent: root.accentColor
    fontFamily: root.panelFontFamily
    fontSize: MailStyle.bodySmall
    horizontalPadding: MailStyle.space(6)
    verticalPadding: MailStyle.space(2)
    onClicked: help.opened ? help.close() : root.openHelp()
  }

  Widgets.PanelActionButton {
    id: clearButton
    anchors.right: parent.right
    anchors.rightMargin: MailStyle.space(4)
    anchors.verticalCenter: parent.verticalCenter
    visible: field.text !== ""
    focusable: true
    tooltipText: "Clear search · esc"
    foreground: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.55)
    hoverColor: root.textColor
    fontSize: MailStyle.body
    onClicked: root.clear()
    Accessible.role: Accessible.Button
    Accessible.name: "Clear search"
    ActionIcon {
      anchors.centerIn: parent
      name: "close"
      color: clearButton._hot ? clearButton.hoverColor : clearButton.foreground
      iconSize: clearButton.fontSize
    }
  }

  Search.SearchSuggestions {
    id: matches
    parent: root.overlayParent
    z: 1000
    visible: root.suggestionsOpen
    suggestions: root.suggestions
    selectedIndex: root.suggestionIndex
    textColor: root.textColor
    dimColor: root.dimColor
    accentColor: root.accentColor
    backgroundColor: root.popupBackgroundColor
    borderColor: root.popupBorderColor
    panelFontFamily: root.panelFontFamily
    onChosen: function(index) { root.completeSuggestion(index) }
    onHeightChanged: if (visible) Qt.callLater(root.placeAssistance)
  }

  Search.SearchHelp {
    id: help
    parent: root.overlayParent
    operators: root.operators
    textColor: root.textColor
    dimColor: root.dimColor
    accentColor: root.accentColor
    backgroundColor: root.popupBackgroundColor
    borderColor: root.popupBorderColor
    panelFontFamily: root.panelFontFamily
    onHeightChanged: if (opened) Qt.callLater(root.placeAssistance)
    onExampleChosen: function(example) {
      var edit = Completion.exampleInsertion(field.text,root.helpSelectionStart,root.helpSelectionEnd,example)
      close()
      root.replaceRange(edit)
    }
    onDismissed: Qt.callLater(root.takeFocus)
  }
  Connections {
    target: root.overlayParent
    function onWidthChanged() { Qt.callLater(root.placeAssistance) }
    function onHeightChanged() { Qt.callLater(root.placeAssistance) }
  }
}
