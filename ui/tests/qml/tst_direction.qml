import QtQuick 2.15
import QtTest 1.3
import "../../components" as Omamail

// Invariant: actual Text items verify that direction reaches the renderer and auto mode restores Qt’s own resolution.
Item {
  width: 600
  height: 400

  function summaryFor(subject, sender, direction) {
    return ({
      id: "message-1",
      subject: subject,
      subjectDirection: direction || "",
      from: ({ display: sender, email: "sender@example.com" }),
      to: [({ display: "Reader", email: "reader@example.com" })],
      snippet: sender,
      time: "09:14",
      fullTime: "24 August 2026",
      unread: false,
      starred: false
    })
  }

  Omamail.MessageRow {
    id: row
    width: 600
    summary: summaryFor("Hello there", "Alice")
    textColor: Qt.rgba(1, 1, 1, 1)
    accentColor: Qt.rgba(1, 0.5, 0, 1)
    dimColor: Qt.rgba(0.67, 0.67, 0.67, 1)
    panelFontFamily: "monospace"
  }

  TestCase {
    name: "MessageDirection"
    when: windowShown

    // Invariant: find the subject by its content so child layout order remains unconstrained.
    function subjectItem() {
      var found = texts(row, [])
      for (var itemIndex = 0; itemIndex < found.length; itemIndex++) {
        if (found[itemIndex].text === row.summary.subject) return found[itemIndex]
      }
      return null
    }

    function texts(item, matches) {
      if (!item) return matches
      if ((item.toString().indexOf("QQuickText") === 0 || item.objectName === "message-subject")
        && item.toString().indexOf("QQuickTextEdit") !== 0) matches.push(item)
      var values = item.children || []
      for (var itemIndex = 0; itemIndex < values.length; itemIndex++) texts(values[itemIndex], matches)
      return matches
    }

    function init() {
      row.contentDirection = "Auto"
      row.summary = summaryFor("Hello there", "Alice")
    }

    function alignmentOf(item) {
      verify(item, "the row draws the subject it was given")
      return item.effectiveHorizontalAlignment
    }

    function test_a_latin_subject_reads_left_to_right() {
      compare(alignmentOf(subjectItem()), Text.AlignLeft)
    }

    function test_an_arabic_subject_reads_right_to_left() {
      row.summary = summaryFor("مرحبا بالعالم", "Alice")
      compare(alignmentOf(subjectItem()), Text.AlignRight)
    }

    function test_a_hebrew_subject_reads_right_to_left() {
      row.summary = summaryFor("שלום עולם", "Alice")
      compare(alignmentOf(subjectItem()), Text.AlignRight)
    }

    // Invariant: a Latin reply prefix must not override the subject’s strong text direction.
    function test_a_reply_prefix_does_not_flip_an_arabic_subject() {
      row.summary = summaryFor("Re: مرحبا بالعالم", "Alice", "rtl")
      compare(alignmentOf(subjectItem()), Text.AlignRight)
    }

    function test_a_list_tag_and_a_forward_prefix_stack() {
      row.summary = summaryFor("[team] Fwd: Re: שלום עולם", "Alice", "rtl")
      compare(alignmentOf(subjectItem()), Text.AlignRight)
    }

    function test_a_reply_prefix_leaves_a_latin_subject_alone() {
      row.summary = summaryFor("Re: Hello there", "Alice")
      compare(alignmentOf(subjectItem()), Text.AlignLeft)
    }

    function test_native_metadata_is_authoritative_and_forced_mode_overrides() {
      row.summary = summaryFor("Re: sample", "Alice", "rtl")
      compare(alignmentOf(subjectItem()), Text.AlignRight)
      row.contentDirection = "Left to right"
      compare(alignmentOf(subjectItem()), Text.AlignLeft)
      row.contentDirection = "Auto"
      compare(alignmentOf(subjectItem()), Text.AlignRight)
    }

    function test_a_chosen_direction_moves_a_latin_subject() {
      row.contentDirection = "Right to left"
      compare(alignmentOf(subjectItem()), Text.AlignRight)
    }

    function test_a_chosen_direction_moves_an_arabic_subject_back() {
      row.summary = summaryFor("مرحبا بالعالم", "Alice")
      row.contentDirection = "Left to right"
      compare(alignmentOf(subjectItem()), Text.AlignLeft)
    }

    // Invariant: auto mode leaves sender and snippet direction to their individual text.
    function test_auto_leaves_the_sender_to_qt() {
      row.summary = summaryFor("Hello there", "محمد")
      var found = texts(row, [])
      var sender = null
      for (var itemIndex = 0; itemIndex < found.length; itemIndex++) {
        if (found[itemIndex].text === "محمد") sender = found[itemIndex]
      }
      verify(sender, "the row draws the sender it was given")
      compare(sender.effectiveHorizontalAlignment, Text.AlignRight)
    }

    // Invariant: a subject without strong characters leaves direction to Qt.
    function test_a_neutral_subject_is_left_alone() {
      row.summary = summaryFor("2024 — 09:14", "Alice")
      compare(alignmentOf(subjectItem()), Text.AlignLeft)
      row.summary = summaryFor("مرحبا", "Alice")
      compare(alignmentOf(subjectItem()), Text.AlignRight,
        "and the next subject still resolves on its own")
    }
  }
}
