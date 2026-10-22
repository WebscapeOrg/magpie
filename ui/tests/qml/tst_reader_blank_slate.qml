import "../../settings"
import QtQuick 2.15
import QtTest 1.3

// Invariant: The version remains readable across pane sizes, even when the shortcut legend hides.
Item {
  width: 400
  height: 400

  QtObject {
    id: mailService
    property string providerId: "gmail"
    property string mailboxKey: "inbox"
    property string searchQuery: ""
    property var searchStatus: ({})
    property bool listLoaded: true
    property bool listLoading: false
    property var messages: [({ id: "m1" })]
    property string pluginName: "Omamail"
    property string version: "0.7.0"
  }

  Loader {
    id: blankSlateLoader
    width: 400
    height: 400
    Component.onCompleted: setSource("../../components/ReaderBlankSlate.qml", ({
      service: mailService,
      textColor: Qt.rgba(1, 1, 1, 1),
      accentColor: Qt.rgba(0.4, 0.6, 1, 1),
      dimColor: Qt.rgba(0.67, 0.67, 0.67, 1),
      dimmerColor: Qt.rgba(0.47, 0.47, 0.47, 1),
      panelFontFamily: "monospace"
    }))
  }


  Loader {
    id: serviceless
    width: 400
    height: 400
    Component.onCompleted: setSource("../../components/ReaderBlankSlate.qml", ({
      service: null,
      textColor: Qt.rgba(1, 1, 1, 1),
      accentColor: Qt.rgba(0.4, 0.6, 1, 1),
      dimColor: Qt.rgba(0.67, 0.67, 0.67, 1),
      dimmerColor: Qt.rgba(0.47, 0.47, 0.47, 1),
      panelFontFamily: "monospace"
    }))
  }

  TestCase {
    name: "ReaderBlankSlate"
    when: windowShown

    function slate() {
      tryCompare(blankSlateLoader, "status", Loader.Ready)
      return blankSlateLoader.item
    }

    function version() {
      var label = findChild(slate(), "reader-version")
      verify(label, "the blank slate must carry an identifiable version label")
      return label
    }

    // Invariant: Force Column polish before measuring; stale geometry can hide overlap failures.
    // Performance: Synchronous layout keeps the one-pixel height sweep fast.
    function resize(width, height) {
      blankSlateLoader.width = width
      blankSlateLoader.height = height
      slate().children[0].forceLayout()
    }

    // Invariant: Independent anchors require a coordinate comparison to detect overlap.
    function overlapping(label) {
      var column = label.parent.children[0]
      var columnBottom = column.y + column.height
      return label.visible && columnBottom > label.y
    }

    function init() {
      mailService.searchQuery = ""
      mailService.searchStatus = ({})
      mailService.messages = [({id:"m1"})]
      mailService.pluginName = "Omamail"
      mailService.version = "0.7.0"
      blankSlateLoader.width = MailStyle.space(400)
      blankSlateLoader.height = MailStyle.space(400)
    }

    function textLabel(item, value) {
      if (item.text !== undefined && item.text === value && item.textFormat !== undefined) return item
      var children = item.children || []
      for (var childIndex = 0; childIndex < children.length; childIndex++) {
        var match = textLabel(children[childIndex], value)
        if (match) return match
      }
      return null
    }
    function test_query_markup_is_literal_text() {
      mailService.searchQuery = '<b>Search terms</b>'
      var label = textLabel(slate(), '\"<b>Search terms</b>\"')
      verify(label)
      compare(label.textFormat, Text.PlainText)
    }
    function test_pending_failed_and_stopped_searches_do_not_claim_no_matches() {
      mailService.searchQuery = "from:sender@example.test"
      mailService.messages = []
      var label = findChild(slate(), "reader-empty-status")
      verify(label)
      var phases = ["preparing", "local", "checking", "failed", "partial", "stopped", "invalid"]
      for (var index = 0; index < phases.length; index++) {
        mailService.searchStatus = {phase:phases[index]}
        verify(label.text !== "")
        verify(label.text.indexOf("No messages match") === -1, phases[index])
      }
      mailService.searchStatus = {phase:"complete"}
      verify(label.text.indexOf("No messages match") === 0)
    }
    function test_manifest_markup_is_literal_text() {
      mailService.pluginName = '<b>Mail</b>'
      compare(version().textFormat, Text.PlainText)
    }
    function test_names_the_running_version() {
      var label = version()
      compare(label.text, "Omamail 0.7.0")
      verify(label.visible)
    }

    function test_follows_the_name_the_manifest_gives() {
      mailService.pluginName = "Forkmail"
      compare(version().text, "Forkmail 0.7.0")
    }

    function test_outlasts_the_shortcut_legend() {
      var label = version()
      resize(MailStyle.space(200), MailStyle.space(240))
      verify(!slate().showLegend,
        "this pane must be too small for the legend, or the test proves nothing")
      verify(label.visible, "the version outlives the legend it is not part of")
    }

    // Invariant: Sweep every height across both legend states; one fixed threshold misses overlap.
    function test_never_prints_over_the_centred_block() {
      var label = version()
      for (var height = 120; height <= 520; height++) {
        resize(400, height)
        verify(!overlapping(label),
          "version label overlaps the centred column at height " + height
            + (slate().showLegend ? " (legend shown)" : ""))
      }
    }

    function test_says_nothing_without_a_version() {
      var label = version()
      mailService.version = ""
      verify(!label.visible)
    }

    function test_says_nothing_without_a_service() {
      tryCompare(serviceless, "status", Loader.Ready)
      var label = findChild(serviceless.item, "reader-version")
      verify(label, "the label exists even with no service behind it")
      verify(!label.visible)
    }
  }
}
