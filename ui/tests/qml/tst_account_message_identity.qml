import QtQuick
import QtTest
import "../../account" as Account

Item {
  id: fixture
  property var fetched: []
  property var painted: []
  property var merged: null
  property var downloads: []
  QtObject {
    id: backend
    property bool ready: true
    function call(method, parameters, done) {
      if (method === "attachment.download") { fixture.downloads.push(parameters); return }
      if (method !== "model.apply") return
      if (parameters.operation === "searchProgress") {
        fixture.painted = fixture.painted.concat(parameters.args[2])
        done({live: fixture.painted, visible: fixture.painted}, null)
      }
    }
  }
  Component {
    id: clientFactory
    QtObject {
      function listMessages(query, limit, token, done, progress) {
        progress({ids: ["constructor", "__proto__", "toString", "ordinary"], estimate: 4})
        return null
      }
    }
  }
  Account.MailAccount {
    id: account
    pluginDir: "/synthetic/identity"
    accountId: "synthetic@example.org"
    backend: backend
    clientOverride: clientFactory
    function summarizedRead(ids, withBody, done) {
      fixture.fetched = fixture.fetched.concat(ids)
      done(ids.map(function(id) { return {id: id, nativeSummary: {id: id}} }), "")
    }
    function mergeMembers(additions) { fixture.merged = JSON.parse(JSON.stringify(additions)) }
    function hydrateSummaries(values) { return values }
  }
  Account.LabelActions { id: labels; account: account }
  TestCase {
    name: "AccountMessageIdentity"
    function init() {
      fixture.fetched = []
      fixture.painted = []
      fixture.merged = null
      fixture.downloads = []
      account.messages = []
    }
    function test_server_ids_are_not_inherited_object_properties() {
      account.loadSearchMessages(false, "", 50, account.listSerial, "")
      compare(fixture.fetched, ["constructor", "__proto__", "toString", "ordinary"])
      compare(fixture.painted.map(function(summary) { return summary.id }), fixture.fetched)
      compare(({}).id, undefined)
    }
    function test_first_label_count_is_not_reported_as_growth() {
      account.labels = [{id: "constructor", name: "Synthetic", unread: 0}]
      labels.recordMonitorCount("constructor", {unread: 2, total: 2})
      compare(labels.monitorGrown.length, 0)
      labels.recordMonitorCount("constructor", {unread: 3, total: 3})
      compare(labels.monitorGrown.length, 1)
    }
    function test_attachment_ids_do_not_skip_or_duplicate_downloads() {
      var resources = account.children.filter(function(child) {
        return typeof child.downloadAttachment === "function"
      })[0]
      verify(!!resources)
      resources.downloadAttachment("message", {attachmentId: "constructor", filename: "synthetic.txt"}, false)
      compare(fixture.downloads.length, 1)
      resources.downloadAttachment("message", {attachmentId: "__proto__", filename: "synthetic.txt"}, false)
      compare(fixture.downloads.length, 2)
      resources.downloadAttachment("message", {attachmentId: "__proto__", filename: "synthetic.txt"}, false)
      compare(fixture.downloads.length, 2)
      account.markSavingAttachment("__proto__", false)
      verify(!account.savingAttachmentIds["__proto__"])
    }
    function test_member_identity_survives_json_transport() {
      account.rememberMember({id: "__proto__", subject: "Synthetic member"})
      verify(Object.prototype.hasOwnProperty.call(fixture.merged, "__proto__"))
      compare(fixture.merged["__proto__"].subject, "Synthetic member")
      compare(({}).subject, undefined)
    }
  }
}
