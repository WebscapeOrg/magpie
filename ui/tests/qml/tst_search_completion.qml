import QtQuick
import QtQuick.Window
import QtTest
import qs.Commons
import "../../components" as Components
import "../../settings"
import "../../settings/Display.js" as Display

Rectangle {
  id: host
  width: 800
  height: 700
  color: Color.background
  property var submitted: []
  property int clearCount: 0
  Item { id: parking; width: 1; height: 1 }
  Components.SearchBar {
    id: bar
    x: 24; y: 24; width: 420
    textColor: Color.foreground
    dimColor: Color.foreground
    accentColor: Color.accent
    popupBackgroundColor: Color.background
    popupBorderColor: Color.foreground
    panelFontFamily: "sans-serif"
    overlayParent: host
    assistanceAvailable: true
    operators: [
      {operator:"from",values:["me"],example:"from:alex@example.com",description:"Sender",primary:true},
      {operator:"is",values:["read","unread","starred"],example:"is:unread",description:"Message state",primary:true},
      {operator:"label",values:[],example:'label:"Client work"',description:"Label",primary:true},
      {operator:"newer_than",values:[],example:"newer_than:7d",description:"Recent mail",primary:false}
    ]
    labels: [{name:"Client work"},{name:"<b>Untrusted</b>"}]
    onSubmitted: function(query) { host.submitted = host.submitted.concat([query]) }
    onCleared: host.clearCount++
    onKeyPressed: function(event) { router.routeKeyEvent(event) }
  }
  Components.KeyRouter {
    id: router
    context: bar.suggestionsOpen ? "searchSuggestions" : "search"
    onTriggered: function(id) {
      if (id === "searchSuggestionNext") bar.moveSuggestion(1)
      else if (id === "searchSuggestionPrevious") bar.moveSuggestion(-1)
      else if (id === "searchSuggestionComplete") bar.completeSuggestion()
      else if (id === "searchSuggestionAccept") bar.accept()
      else if (id === "back") {
        if (bar.dismissAssistance()) return
        bar.clear()
        parking.forceActiveFocus()
      }
    }
  }
  TestCase {
    name: "SearchCompletion"
    when: windowShown
    function field() { return findChild(bar,"search-query-field") }
    function enter(text) {
      bar.setQuery("")
      bar.takeFocus()
      for (var index = 0; index < text.length; index++) keyClick(text[index])
    }
    function init() {
      MailStyle.preferences = Display.normalize({interfaceSize:12})
      host.height = 700
      bar.dismissAssistance()
      bar.assistanceAvailable = true
      bar.setQuery("")
      bar.width = 420
      parking.forceActiveFocus()
      host.submitted = []
      host.clearCount = 0
    }
    function test_enter_without_selected_suggestion_submits_exact_query() {
      enter("fr")
      compare(bar.suggestionIndex,-1)
      verify(bar.suggestionsOpen)
      keyClick(Qt.Key_Return)
      compare(host.submitted,["fr"])
      compare(bar.queryText,"fr")
    }
    function test_arrows_enter_complete_without_submitting() {
      enter("fr")
      keyClick(Qt.Key_Down)
      compare(bar.suggestionIndex,0)
      keyClick(Qt.Key_Return)
      compare(bar.queryText,"from:")
      compare(host.submitted,[])
      verify(bar.fieldFocused)
      compare(field().selectedText,"")
    }
    function test_tab_completes_label_without_network_submission() {
      enter("label:Cl")
      keyClick(Qt.Key_Tab)
      compare(bar.queryText,'label:"Client work" ')
      compare(host.submitted,[])
    }
    function test_first_escape_preserves_query_then_leaves() {
      enter("fr")
      keyClick(Qt.Key_Escape)
      compare(bar.queryText,"fr")
      compare(host.clearCount,0)
      verify(!bar.suggestionsOpen)
      verify(bar.fieldFocused)
      keyClick(Qt.Key_Escape)
      compare(bar.queryText,"")
      compare(host.clearCount,1)
    }
    function test_completion_retains_native_undo() {
      enter("fr")
      keyClick(Qt.Key_Tab)
      compare(bar.queryText,"from:")
      keyClick(Qt.Key_Z,Qt.ControlModifier)
      compare(bar.queryText,"fr")
    }
    function test_mid_query_caret_replaces_only_active_token() {
      bar.setQuery("is:unread fr label:Work")
      field().cursorPosition = 12
      bar.dismissedText = "\u0000"
      bar.takeFocus()
      keyClick(Qt.Key_Tab)
      compare(bar.queryText,"is:unread from: label:Work")
    }
    function test_background_catalogue_refresh_keeps_selected_identity() {
      enter("fr")
      keyClick(Qt.Key_Down)
      compare(bar.suggestionIndex,0)
      bar.operators = JSON.parse(JSON.stringify(bar.operators))
      bar.labels = JSON.parse(JSON.stringify(bar.labels))
      compare(bar.suggestionIndex,0)
      keyClick(Qt.Key_Return)
      compare(bar.queryText,"from:")
      compare(host.submitted,[])
    }
    function test_removed_label_deselects_without_choosing_another_label() {
      var previous = bar.labels
      enter("label:Cl")
      keyClick(Qt.Key_Down)
      compare(bar.suggestionIndex,0)
      bar.labels = [{name:"Completely different"}]
      compare(bar.suggestionIndex,-1)
      keyClick(Qt.Key_Return)
      compare(host.submitted,["label:Cl"])
      bar.labels = previous
    }
    function test_help_example_inserts_without_submit() {
      enter("invoice")
      bar.openHelp()
      tryCompare(bar,"helpOpened",true)
      var example = findChild(findChild(host,"search-help").contentItem,"search-help-from")
      verify(example)
      example.clicked()
      tryCompare(bar,"helpOpened",false)
      compare(bar.queryText,"invoice from:alex@example.com ")
      compare(host.submitted,[])
      tryCompare(bar,"fieldFocused",true)
      keyClick(Qt.Key_Z,Qt.ControlModifier)
      compare(bar.queryText,"invoice")
    }
    function test_old_backend_has_no_assistance() {
      bar.assistanceAvailable = false
      enter("from:alex")
      verify(!bar.suggestionsOpen)
      verify(!findChild(bar,"search-help-button").visible)
      keyClick(Qt.Key_Return)
      compare(host.submitted,["from:alex"])
    }
    function test_help_keyboard_scrolls_focused_examples_at_large_text() {
      MailStyle.preferences = Display.normalize({interfaceSize:26})
      host.height = 540
      bar.width = 300
      bar.openHelp()
      tryCompare(bar,"helpOpened",true)
      var help = findChild(host,"search-help")
      wait(20)
      var names = ["from","is","label","newer_than"]
      for (var index = 0; index < names.length; index++) {
        keyClick(Qt.Key_Tab)
        var focused = host.Window.window.activeFocusItem
        compare(focused.objectName,"search-help-" + names[index])
        var top = focused.mapToItem(help.contentItem,0,0).y
        verify(top >= -1,"Focused example top stays visible")
        verify(top + focused.height <= help.contentItem.height + 1,"Focused example bottom stays visible")
      }
      for (var back = 0; back < names.length; back++) keyClick(Qt.Key_Tab,Qt.ShiftModifier)
      var close = host.Window.window.activeFocusItem
      compare(close.objectName,"search-help-close")
      verify(close.mapToItem(help.contentItem,0,0).y >= -1)
      keyClick(Qt.Key_Escape)
      tryCompare(bar,"helpOpened",false)
      tryCompare(bar,"fieldFocused",true)
    }
  }
}
