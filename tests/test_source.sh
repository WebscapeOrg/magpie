#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../ui"

fail() { printf 'test_source.sh: %s\n' "$1" >&2; exit 1; }

# Algorithm: git enumerates tracked and unignored worktree files without descending into ignored
# checkouts. NUL-delimited read loops preserve paths and support Bash 3.2.
QML_FILES=()
while IFS= read -r -d '' found; do
  [ ! -f "$found" ] || QML_FILES+=("$found")
done \
  < <(git ls-files -z --cached --others --exclude-standard -- '*.qml')

JS_FILES=()
while IFS= read -r -d '' found; do
  [ ! -f "$found" ] || JS_FILES+=("$found")
done \
  < <(git ls-files -z --cached --others --exclude-standard -- '*.js' ':!tests/*')

# Invariant: Scripts declaring /bin/sh must also run under dash; Bash-only substitutions can pass
# locally and fail in release CI.
if grep -rnE '\$\{[A-Za-z_][A-Za-z0-9_]*//' --include='*.sh' ../scripts; then
  fail "a /bin/sh script uses bash-only global parameter replacement"
fi

# Invariant: QML chrome must inherit the active theme so light and dark themes remain readable.
if grep -nE '(color|Color)\s*:\s*"#[0-9A-Fa-f]{3,8}"' -- "${QML_FILES[@]}"; then
  fail "hard-coded colour in QML: use Color.* or a colour passed in from App.qml"
fi
if grep -nE ':\s*"(red|blue|green|white|black|yellow|orange|purple|gray|grey)"' -- "${QML_FILES[@]}"; then
  fail "named display colour in QML: use Color.* instead"
fi

# Invariant: Maintained QML libraries use the shared ES5-compatible syntax; Node-only test harnesses
# are exempt.
for file in "${JS_FILES[@]}"; do
  head -1 "$file" | grep -q '^\.pragma library$' || fail "$file must start with .pragma library"
  # Algorithm: Comments quote code with backticks and say things like "a => b", so the check runs on
  # code lines only.
  if grep -vE '^\s*(//|\*|/\*)' "$file" | grep -nE '^\s*(const|let)\s|=>|`'; then
    fail "$file uses ES6 syntax the QML engine will not parse"
  fi
done

# Invariant: Theme colours enter JS from QML. Html.js may retain its reviewed paper/ink palette
# because sender content colours need a compatible reading background.
for file in account/Model.js providers/GmailApi.js message/Message.js; do
  if grep -vE '^\s*(//|\*|/\*)' "$file" | grep -nE '#[0-9A-Fa-f]{6}'; then
    fail "$file names a colour: pass it in from QML instead"
  fi
done
if grep -vE '^\s*(//|\*|/\*)' message/Html.js | grep -nE '#[0-9A-Fa-f]{6}' \
   | grep -vE 'PAPER|INK|paperPalette|#1155cc|#5f6368'; then
  fail "message/Html.js may only name the PAPER/INK sheet colours"
fi

# Invariant: HTML background is a resource address, not a colour. Reject resource attributes before
# consulting keepColors to prevent unexpected sender requests.
if grep -nE '^var COLOUR_ATTRIBUTES = .*\bbackground\b' message/Html.js; then
  fail "message/Html.js treats the HTML background attribute as a colour; it is an address"
fi
grep -q '^var RESOURCE_ATTRIBUTES = {' message/Html.js \
  || fail "message/Html.js must refuse resource-bearing attributes as their own class"
awk '
  /^function cleanAttributes/ { in_function = 1 }
  in_function && /RESOURCE_ATTRIBUTES\[name\] === true/ { resource = NR }
  in_function && /COLOUR_ATTRIBUTES\[name\] === true/ { colour = NR }
  in_function && /^}/ { exit !(resource && colour && resource < colour) }
  END { exit !(resource && colour && resource < colour) }
' message/Html.js \
  || fail "a resource attribute must be dropped before keepColors is consulted"

# Invariant: Escape outgoing text nodes because unwrapping adjacent elements can turn previously
# harmless text into markup on a second parse.
grep -q 'out.push(escapeMarkup(node.text))' message/Html.js \
  || fail "message/Html.js must escape a text node on the way out, not write it back raw"

# Invariant: Views consume prepared documents; sanitizer policy and reader reconstruction stay in
# their owning renderer.
if grep -nE 'Html\.(sanitize|readerTree)\(' components/MessageReader.qml; then
  fail "the reader view must not sanitise a body; the account renders it once"
fi
# Invariant: Sanitization and reader reconstruction now run in the Rust worker. Only a correlated,
# successful native result may reach the QML document properties.
python3 - <<'PY_NATIVE_RENDER'
from pathlib import Path
account = Path("account/MailAccount.qml").read_text()
start = account.index("  function renderSource(")
render = account[start:account.index("  function showRemoteImages", start)]
if 'backend.call("reader.render"' not in render or "withReader: true" not in account:
    raise SystemExit("test_source.sh: native render must prepare both safe display trees")
if "Html.sanitize(" in account or "RenderCache." in account:
    raise SystemExit("test_source.sh: body parsing and render caching belong to Rust")
for guard in ("rendering !== root.renderSerial", "account !== root.accountId",
              "selection !== root.selectedId", "detail !== root.detailSerial",
              "if (error || !result)"):
    if guard not in render or render.index(guard) > render.index("selectedDocument = ready.document"):
        raise SystemExit("test_source.sh: stale or failed renders must never reach the document")
native = Path("../src/backend/content.rs").read_text()
if "message::html::request(params)?" not in native or ".get(account, id, source, &policy)" not in native:
    raise SystemExit("test_source.sh: render results must originate in the native sanitizer and keyed cache")
cache = Path("../src/cache/render.rs").read_text()
for invariant in ("MAX_PER_ACCOUNT: usize = 12", "MAX_BYTES", "e.account == account",
                  "e.id == id", "e.source == source", "e.options == *options"):
    if invariant not in cache:
        raise SystemExit("test_source.sh: native render cache must be bounded and isolated by complete policy")
PY_NATIVE_RENDER
grep -q 'remoteImageData: remoteImagesAllowed ? remoteImageData : null' account/MailAccount.qml \
  || fail "Qt must receive prepared image bytes rather than a pending remote source"
grep -q 'backend.call("public.image"' account/MailAccount.qml \
  || fail "remote images must use the public-IP-checked native backend"
grep -q 'function isDisplayableImageUrl(value) {' message/Html.js \
  || fail "isDisplayableImageUrl must remain the Image-element gate"
grep -q 'return isRasterDataImage(value)' message/Html.js \
  || fail "the reader may hand Qt only prepared raster bytes, never a remote URL"
grep -q 'function fetchDisplayImage' account/MailAccount.qml \
  || fail "a plain-text image marker must fetch through the public-host worker"
grep -q '"public.unsubscribe"' account/Unsubscribe.qml \
  || fail "one-click unsubscribe must use the public-IP-checked native backend"
# Invariant: Redirect and DNS policy require behavioral tests, not a matching config line.

# Invariant: Cursor previews must not fetch sender images, even when explicitly opened mail may use
# the saved always-show preference.
grep -q 'remoteImagesAllowed = Model.showsRemoteImages(alwaysShowImages, selectionIsPreview)' account/MailAccount.qml \
  || fail "a message the cursor merely previewed must not fetch the sender's images"
grep -q 'property string bodyMode: "reader"' Service.qml \
  || fail "a message opens in reading mode"
# Invariant: Mode changes select already prepared documents; they must not rerender or repeat
# network reads.
if awk '
  /function setBodyMode\(value\)/ { in_function = 1 }
  in_function && /(renderSource|select\(|getMessage|showRemoteImages)/ { found = 1 }
  in_function && /^  }/ { exit found ? 0 : 1 }
  END { exit found ? 0 : 1 }
' Service.qml; then
  fail "changing how a message is read must not re-render or re-fetch it"
fi

grep -q 'promoteDirection' message/Html.js \
  || fail "a CSS direction must be promoted to the dir attribute Qt actually reads"
# Algorithm: The sheet's physical sides and the body's `dir` are one statement. Qt places a list
# marker on the side the block runs from, so a sheet that indents a list from the right while the
# block is still left-to-right does not move the bullet — it drops it. Splitting these was tried;
# the bullets went missing.
grep -q 'function baseDirectionAttribute' message/Html.js \
  || fail "the body direction and the stylesheet's sides must be written together"
if grep -n 'palette.pinned' message/Html.js; then
  fail "a document has one direction, not a direction and a flag saying whether to mean it"
fi

# Algorithm: Ignore Latin reply prefixes when resolving subject direction so every reply keeps the
# sender-language alignment.
for file in components/MessageRow.qml components/MessageReader.qml bar/BarPreview.qml; do
  grep -q 'subjectDirection' "$file" \
    || fail "$file must consume the native subject direction"
done

# Algorithm: Ignore app-generated image markers when resolving body direction; their Latin text is
# not sender content.
grep -q 'selectedBody.bodyDirection' components/MessageReader.qml \
  || fail "the reader must consume the native body direction"
grep -q 'direction::resolve_subject' ../src/message/content.rs \
  || fail "native summaries must resolve subjects through the reply-prefix-aware rule"
grep -q 'direction::resolve_body' ../src/message/content.rs \
  || fail "native body preparation must resolve text through the image-marker-aware rule"

# Invariant: Content direction must not mirror the surrounding interface.
if grep -rn 'LayoutMirroring' -- "${QML_FILES[@]}"; then
  fail "message direction must not mirror the interface; it applies to content only"
fi

# Invariant: Transparent bar contrast follows barForeground, not the fixed theme foreground.
grep -q 'bar ? bar\.barForeground' BarWidget.qml \
  || fail "the bar icon must follow bar.barForeground in transparent mode"
grep -q 'MagpieLogo {' components/AppMenu.qml \
  || fail "the app menu must carry Magpie's identity"
! grep -q 'MagpieLogo {' App.qml \
  || fail "the list header must leave branding in the menu"
grep -q 'color: Commons.Color.accent' BarWidget.qml \
  || fail "the unread marker must use the active theme accent"

# Invariant: Assigning an unknown IconTextButton property makes its parent component unavailable at
# runtime.
if awk '
  /^[[:space:]]*IconTextButton[[:space:]]*\{/ { in_button = 1; next }
  in_button && /^[[:space:]]*hoverColor:/ { print NR ":" $0; found = 1 }
  in_button && /^[[:space:]]*\}/ { in_button = 0 }
  END { exit !found }
' components/SetupPage.qml; then
  fail "SetupPage assigns the non-existent IconTextButton.hoverColor property"
fi
for file in components/MessageList.qml components/ReaderBlankSlate.qml; do
  if grep -n 'resultSummary' "$file"; then
    fail "$file must not expose result-count estimates in the interface"
  fi
done
if grep -n 'modelData\.unread' components/AccountSwitcher.qml; then
  fail "the account switcher must identify mailboxes without count badges"
fi
if [ -e components/UserBar.qml ] || grep -q 'UserBar {' components/MailboxSidebar.qml; then
  fail "the account control belongs in the status bar, not the sidebar"
fi
grep -q 'objectName: "header-account-button"' App.qml \
  || fail "the header account button must be the account switcher trigger"
grep -q 'selected: accountSwitcher.opened' App.qml \
  || fail "the header account trigger must stay selected while its popup is open"
grep -q 'accountSwitcher.openAt(scene.x, scene.y)' App.qml \
  || fail "the account switcher must anchor to the header account button"
awk '
  /id: footer$/ { in_footer = 1 }
  in_footer && /anchors.leftMargin: MailStyle.space\(8\)/ { left = 1 }
  in_footer && /anchors.rightMargin: MailStyle.space\(8\)/ { right = 1 }
  in_footer && /spacing: MailStyle.space\(4\)/ { exit !(left && right) }
  END { exit !(left && right) }
' components/MessageReader.qml \
  || fail "the reader toolbar control frames must share the status-bar inset"

# Invariant: The bar trigger stays selected while its window is open.
grep -q 'windowOpen' BarWidget.qml \
  || fail "the bar icon must show an active style while the window is open"
grep -q 'KeyboardPanel {' BarWidget.qml \
  || fail "the bar icon must open a mail preview"
[ -f bar/BarPreview.qml ] || fail "the bar preview view is missing"
python3 - <<'PY'
from pathlib import Path

widget = Path("BarWidget.qml").read_text()
open_window = widget[widget.index("function openWindow()"):widget.index("function openMessage(")]
if "shell.toggle" not in open_window or open_window.index("shell.toggle") > open_window.index("shell.summon"):
    raise SystemExit("test_source.sh: the bar's main-window action must toggle an open window closed")
pressed = widget[widget.index("onPressed: function(buttonCode)"):]
pressed = pressed[:pressed.index("\n    }")]
if "buttonCode === Qt.LeftButton" not in pressed or "root.openWindow()" not in pressed:
    raise SystemExit("test_source.sh: left-clicking the bar icon must open Omamail")
PY
# Invariant: An open window uses the shell-style inner accent line; a filled glyph square conveys a
# different state.
grep -q 'id: openIndicator' BarWidget.qml \
  || fail "the open Omamail window must use the bar's accent-line indicator"
if grep -q 'id: openFill' BarWidget.qml; then
  fail "the bar icon must not replace the native-style indicator with a selected fill"
fi
if grep -vE '^[[:space:]]*//' BarWidget.qml | grep -n 'activeColor'; then
  fail "BarWidget must not paint its glyph with the bar's urgent-derived activeColor"
fi

# Algorithm: Qt can report hover when keyboard scrolling moves content under a stationary pointer.
# Hover styling must never move the keyboard cursor.
if grep -n 'onRowHovered' App.qml; then
  fail "hovering a row must not move the keyboard cursor"
fi

# Invariant: Park keyboard focus on a plain Item. Focusing the scope reselects its previous text
# field and leaves bare shortcuts swallowed.
grep -q 'onKeyContextChanged' App.qml \
  || fail "the key context must move the keyboard when it changes"
grep -q 'function parkKeyboard' App.qml \
  || fail "App.qml must park the keyboard on a plain Item, not on the focus scope"
if grep -vE '^[[:space:]]*//' App.qml | grep -n 'focusScope\.forceActiveFocus'; then
  fail "forceActiveFocus on the focus scope re-elects the field being left; park the keyboard instead"
fi

# Invariant: Hidden items can still hold focus; the key context owns focus placement.
if grep -rn '^\s*focus: true\s*$' components/ComposeView.qml; then
  fail "ComposeView must not hold the focus unconditionally"
fi

grep -q 'Qt.rgba(popupBackgroundColor.r, popupBackgroundColor.g, popupBackgroundColor.b, 1)' \
  components/RecipientSuggestions.qml \
  || fail "recipient suggestions must obscure the compose form behind them"
grep -q 'z: root.toSuggestions.length > 0 ? 100 : 0' components/ComposeView.qml \
  || fail "recipient suggestions must stack above later compose rows"
grep -q 'id: bccToggle' components/ComposeView.qml \
  || fail "a draft must offer Bcc the same way it offers Cc, not only when a mailto names one"
grep -q 'NumberField {' components/SettingsPage.qml \
  || fail "the in-app settings page must expose numeric settings"
grep -q 'setUndoSendSeconds' components/SettingsPage.qml \
  || fail "the in-app settings page must save the undo window"

# Invariant: Runtime-selected disclosure icon names need explicit coverage because literal icon
# scans cannot discover both states.
for icon in chevronLeft chevronRight chevronDown mail; do
  if ! grep -qE "^  $icon: \"[a-z-]+\"" components/Icons.js; then
    fail "Icons.js does not define the $icon icon"
  fi
done
python3 - <<'PY'
from pathlib import Path
text = Path("App.qml").read_text()
if "function switchAccount(index)" not in text:
    raise SystemExit("test_source.sh: account entry points must share view-preserving switching")
switch = text[text.index("function switchAccount(index)"):text.index("function editAccount", text.index("function switchAccount(index)"))]
if "mailboxAfterAccountSwitch" not in switch:
    raise SystemExit("test_source.sh: account switching must retain the current mailbox tab")
if "onAccountChosen" not in text or "root.switchAccount(index)" not in text:
    raise SystemExit("test_source.sh: the account picker must use view-preserving switching")

PY
python3 - <<'PY'
from pathlib import Path

text = Path("App.qml").read_text()
header = text[text.index("id: headerRight"):text.index("PanelSeparator {", text.index("id: headerRight"))]
if "spacing: MailStyle.space(8)" not in header:
    raise SystemExit("test_source.sh: refresh needs breathing room before the header action")
for name in ("compose-button",):
    marker = 'objectName: "' + name + '"'
    start = text.index(marker)
    opening = text.rfind("\n          Widgets.Button {", 0, start)
    if opening < 0:
        raise SystemExit("test_source.sh: " + name + " must use a normal text button")
    block = text[opening:text.index("\n          }", start)]
    if "iconName:" in block:
        raise SystemExit("test_source.sh: " + name + " must not carry an icon")
PY
python3 - <<'PY'
from pathlib import Path
sidebar = Path("components/MailboxSidebar.qml").read_text()
assert 'label: "Skylark..."' in sidebar and "calendarRequested" in sidebar
service = Path("Service.qml").read_text()
assert "readonly property var pendingSendHost" in service
assert "calendarController:" not in service
assert not Path("calendar").exists()
PY
if grep -q 'Open Omamail' bar/BarPreview.qml; then
  fail "the bar preview must not contain a redundant Open Omamail button"
fi
grep -q 'messages: host ? host.previewMessages : \[\]' Service.qml \
  || fail "the bar preview must use each account's unread preview feed"
grep -q 'width: parent ? parent.width : 0' BarWidget.qml \
  || fail "bar preview rows must stay inside the panel's padded content area"
# Invariant: Row fills reach the list/reader divider; content padding belongs inside a row, not in a
# gutter that cuts every selected background short.
grep -q 'width: root.width$' components/MessageList.qml \
  || fail "message rows must reach the list column edge"
grep -q 'leadingBoundaryOverlap: listSplitter.visible ? listSplitter.width : 0' App.qml \
  || fail "the reader toolbar boundary must cross the splitter hit area to meet its visible rule"
grep -q 'anchors.leftMargin: -root.leadingBoundaryOverlap' components/MessageReader.qml \
  || fail "the reader toolbar boundary must meet the list/reader divider"
awk '
  /id: listSplitter/ { in_splitter = 1 }
  in_splitter && /PanelSeparator[[:space:]]*\{/ { in_separator = 1 }
  in_separator && /anchors\.left: parent\.left/ { found = 1 }
  in_separator && /^[[:space:]]*\}/ { exit !found }
  END { exit !found }
' App.qml || fail "the list divider must sit on the splitter edge beside row fills"

# Performance: Initial loading is represented by rows shaped like the content that will arrive,
# rather than a lone Loading label that makes the column jump.
grep -q 'ListSkeleton {' components/MessageList.qml \
  || fail "an initially empty message list needs its skeleton"
grep -q 'Model\.showInitialListSkeleton' components/MessageList.qml \
  || fail "the list skeleton must only replace an empty initial fetch"
if grep -q 'implicitHeight: childrenRect\.height' components/ListSkeleton.qml; then
  fail "Column.implicitHeight is read-only and makes ListSkeleton unavailable"
fi

# Invariant: Provider DSL and capability ceilings are native; UI files retain presentation.
if grep -Eq 'Provider\.(query|labelQuery|addressQuery|webMessageUrl|webBoxUrl)\(' \
    account/MailAccount.qml account/LabelActions.qml App.qml components/MailboxSidebar.qml; then
  fail "provider query and message URL construction must use the native domain"
fi
if grep -Eq '^function (query|searchQuery|labelQuery|addressQuery|webMessageUrl|webBoxUrl|cachedSummaryInSearch)\(' \
    providers/Registry.js providers/Gmail.js; then
  fail "legacy provider domain functions belong only in test oracles"
fi
grep -q 'capabilities: facts.capabilities' providers/Registry.js \
  || fail "UI capability ceilings must come from the generated native snapshot"

# Performance: A first-time search paints what every cached mailbox page already knows, then accepts
# provider results without waiting for the last metadata request. The progress argument is part of
# the shared client interface, not a Gmail branch in MailAccount.
grep -q 'cacheStore.getPreview(effectiveQuery, maxMessages,' account/MailAccount.qml \
  || fail "typed searches must inspect eligible cached message summaries first"
grep -q 'eligible(source_query(key), row)' ../src/cache/query.rs \
  || fail "cached search previews must stay inside the provider's live scope"
grep -q 'function loadSearchMessages' account/MailAccount.qml \
  || fail "typed searches need a progressive list pipeline"
grep -q 'operation: "searchFinish"' account/MailAccount.qml \
  || fail "the final server ids must replace the cached search preview"
grep -q 'operation: "missingSearchSummaryIds"' account/MailAccount.qml \
  || fail "a partial metadata page must close paging before a missing row"
grep -q '}, idsArrived)' account/MailAccount.qml \
  || fail "server ids must be consumed before the final list callback"
grep -q 'readonly property bool serverSearchLoading:' account/MailAccount.qml \
  || fail "typed searches must expose that the server answer is still loading"
grep -q 'searching: !!root\.service && SearchPresentation.busy' App.qml \
  || fail "the search field must receive the live search state"
grep -q 'text: "Searching\.\.\."' components/SearchBar.qml \
  || fail "the search field must name what is still running"
for client in providers/GmailApiClient.qml; do
  grep -q 'function listMessages(query, maxResults, pageToken, callback, progress)' "$client" \
    || fail "$client must expose the shared progressive search interface"
  grep -q 'function getMessages(ids, full, callback, existingHandle, progress)' "$client" \
    || fail "$client must expose the shared progressive list interface"
done
# Invariant: Every provider answers the conversation-member callback, returning an empty list when
# conversation expansion is unsupported.
for client in providers/GmailApiClient.qml; do
  grep -q 'function getSummaries(ids, callback)' "$client" \
    || fail "$client must expose the shared conversation-member interface"
done
grep -q 'fetchQueue\.push(wanted)' account/MailAccount.qml \
  || fail "streamed metadata reads need one shared queue"
# Invariant: Native intent preparation owns row/member updates, scoped rollback and conversation
# expansion. QML still owns queueing provider writes and navigation.
python3 - <<'PY_NATIVE_INTENTS'
from pathlib import Path
account = Path("account/MailAccount.qml").read_text()
start = account.index("  function runNativeAction(")
run = account[start:account.index("  function rememberList", start)]
for marker in ("intents.begin(parameters", "intents.settle(account, actionQuery",
               "root.applyIntentView(prepared.view", "prepared.targets", "prepared.change",
               "prepared.generation", "allRead: allRead === true", "quiet: quiet === true",
               "memberOnly: memberOnly === true", "sourceLabelId: hasLabels ? rawLabelId"):
    if marker not in run:
        raise SystemExit("test_source.sh: native action contract missing: " + marker)
if not run.index("stopLiveList()\n    var parameters") < run.index("intents.begin(parameters"):
    raise SystemExit("test_source.sh: action preparation must invalidate pre-edit list snapshots")
if not run.index("root.applyIntentView(prepared.view") < run.index("function dispatch()"):
    raise SystemExit("test_source.sh: optimistic native view must apply before provider dispatch")
dispatch = run[run.index("function dispatch()"):]
if not dispatch.index("stopLiveList()") < dispatch.index("root.pendingAction = action"):
    raise SystemExit("test_source.sh: queued provider writes must interrupt stale list reads")
settle = run[run.index("intents.settle(account, actionQuery, prepared.token, failed"):]
if not settle.index("root.runQueuedAction()") < settle.index("root.resumeDeferredListLoad("):
    raise SystemExit("test_source.sh: completed actions must drain the write queue before revalidation")
for marker in ("prepared.invalidatesPage === true || parameters.opaqueQuery",
               'root.nextPageToken = ""', "cacheStore.invalidate(targets",
               "root.loadMessages(false, true, message)", "root.active && root.cacheKey !== actionQuery"):
    if marker not in run:
        raise SystemExit("test_source.sh: mutation cache/pagination reconciliation missing: " + marker)
if '(pendingAction !== "" || actionPreparations > 0) && cacheKey === pendingActionQuery' not in account:
    raise SystemExit("test_source.sh: preparations and writes must only defer their own query")
if "deferredListLoad = ({" not in account or "next.dispatch()" not in account:
    raise SystemExit("test_source.sh: navigation and queued provider writes must not be discarded")
intents = Path("account/Intents.qml").read_text()
if 'account.backend.call("model.intent"' not in intents or "Model." in intents:
    raise SystemExit("test_source.sh: optimistic replay must run in the native intent store")
if "account.runNativeAction(" not in Path("account/BatchAction.qml").read_text():
    raise SystemExit("test_source.sh: bulk edits must share the native transaction pipeline")
PY_NATIVE_INTENTS
grep -q 'if (!service.act(acted, action)) return false' App.qml \
  || fail "a refused action must not move the keyboard cursor"
awk '
  /if \(!finalPage\)/ { in_null_page = 1 }
  in_null_page && /root\.nextPageToken = ""/ { cleared = 1 }
  in_null_page && /return/ { exit !cleared }
  END { exit !cleared }
' account/MailAccount.qml \
  || fail "a failed page-one search must clear cached pagination"
awk '
  /function fetchSummaries/ { in_fetch = 1 }
  in_fetch && /operation: "missingSearchSummaryIds"/ { checks_ids = 1 }
  in_fetch && /root\.nextPageToken = ""/ { clears_page = 1 }
  /function applySummaries/ { exit !(checks_ids && clears_page) }
  END { exit !(checks_ids && clears_page) }
' account/MailAccount.qml \
  || fail "ordinary metadata reads must detect holes and close paging"
grep -Fq 'callback(ordered, firstError, firstDetail)' providers/GmailApiClient.qml \
  || fail "Gmail must report partial metadata failures"
grep -q 'progressTimerComponent' providers/GmailApiClient.qml \
  || fail "parallel Gmail metadata replies must be coalesced before repainting"
grep -q 'MAX_SUMMARIES_PER_QUERY' cache/Cache.js \
  || fail "each cached query needs a row cap"

# Invariant: New-mail notifications use the application's own mark, not the desktop's generic
# unread-mail glyph.
grep -q 'assets/magpie.svg' ../scripts/notify-mail.py \
  || fail "new-mail notifications need the Omamail app icon"
[ -f assets/magpie.svg ] || fail "the notification app icon is missing"

# Invariant: Account actions live on the account's edit page. The switcher only changes accounts and
# leads to management; the management list only leads to editing.
grep -q 'text: "Manage accounts\.\.\."' components/AccountSwitcher.qml \
  || fail "the account switcher needs a Manage accounts... entry"
if grep -q 'removeAccountRequested' components/AccountSwitcher.qml; then
  fail "the account switcher must not remove accounts directly"
fi
grep -q 'signal editRequested(int index)' components/SettingsPage.qml \
  || fail "the account list needs an edit action"
if grep -qE 'signal (signIn|signOut|remove)Requested' components/SettingsPage.qml; then
  fail "sign-in, sign-out and removal belong on the account edit page"
fi
grep -q 'signal removeRequested()' components/SetupPage.qml \
  || fail "the account edit page needs to own account removal"

grep -q 'service\.discardCurrentDraft()' App.qml \
  || fail "leaving Add account must discard its unnamed draft"
if awk '
  /function addAccount\(/ { in_add = 1 }
  in_add && /saveAccounts\(\)/ { found = 1 }
  in_add && /^  \}/ { exit found ? 0 : 1 }
  END { exit found ? 0 : 1 }
' Service.qml; then
  fail "Add account must not persist its blank draft"
fi

# Invariant: Destructive account actions consume the semantic danger role passed from the app.
# Calling it dim or urgent at the button loses the action's meaning.
for page in components/SetupPage.qml; do
  grep -q 'required property color dangerColor' "$page" \
    || fail "$page must receive the semantic danger colour"
  awk '
    /text: "Remove account"/ { in_remove = 1 }
    in_remove && /foreground: root\.dangerColor/ { found = 1 }
    in_remove && /^[[:space:]]*\}/ { exit !found }
    END { if (!in_remove) exit 1; exit !found }
  ' "$page" || fail "$page Remove account must be a danger button"
done

# Invariant: Removing a mailbox is destructive. The edit pages may request it, but only a
# confirmation owned by App may call the service after naming the target.
grep -q 'AccountRemovalDialog {' App.qml \
  || fail "account removal needs a confirmation dialog"
if awk '
  /function removeCurrentAccountFromEditor\(/ { in_remove = 1 }
  in_remove && /service\.removeAccountAt/ { found = 1 }
  in_remove && /^  }/ { exit }
  END { exit !found }
' App.qml; then
  fail "requesting account removal must not remove it immediately"
fi

# Invariant: Qt QML XMLHttpRequest requires a Timer that aborts; assigning timeout does not impose a
# deadline. Source checks catch that misuse; controlled-network tests prove actual timing.
if grep -rnE '\.timeout[[:space:]]*=' --include=*.qml . | grep -v '^./tests/'; then
  fail "XMLHttpRequest.timeout does not exist in Qt's QML engine; use a Timer that aborts"
fi

# Invariant: MailAccount identity must match Accounts.accountId, including provider prefixes;
# assigning the bare address can silently select another mailbox.
if grep -nE 'accountId = accountEmail' account/MailAccount.qml; then
  fail "a mailbox's id must come from Accounts.accountId, not from the address alone"
fi
grep -q 'accountId = Accounts.accountId(accountEmail, providerId)' account/MailAccount.qml \
  || fail "MailAccount must name itself through Accounts.accountId"

# Invariant: Native desktop controls retain the arrow cursor. A pointing hand is reserved for actual
# links such as URLs inside the message reader.
for file in components/IconButton.qml components/IconTextButton.qml components/AppMenu.qml \
  components/MessageMenu.qml components/AccountSwitcher.qml \
  components/MailboxSidebar.qml; do
  if grep -n 'PointingHandCursor' "$file"; then
    fail "$file uses a web-link cursor for a native control"
  fi
done

# Invariant: Labels say when an action leaves the app and use three periods for the established
# workflow suffix. Busy state is status, not decorative prose.
if grep -rnE 'Checking…|Fetching the mailbox…|Not signed in yet|Open in Gmail|text: "(Shortcuts|GitHub|Twitter)"' \
  App.qml components; then
  fail "UI copy does not follow the project action and status vocabulary"
fi
if grep -rnE '^[[:space:]]*(text|tooltipText):.*…' App.qml components; then
  fail "UI labels use the project ellipsis convention (...), while progress uses state"
fi
grep -q 'text: "Add a mailbox\.\.\."' components/SettingsPage.qml \
  || fail "Add a mailbox opens a workflow and needs an ellipsis"
grep -q 'tooltipText: "Add another mail account"' components/SettingsPage.qml \
  || fail "the add-account tooltip must explain the account workflow"
python3 - <<'PY'
from pathlib import Path

menu = Path("components/AppMenu.qml").read_text()
calendar = menu.index("id: calendarRow")
settings = menu.index("id: settingsRow")
switch = menu.index("id: switchRow")
separator = menu.index("MenuSeparatorLine {", switch)
if not calendar < switch < settings < separator:
    raise SystemExit("test_source.sh: Settings must stay with the account actions below Skylark")
settings_block = menu[settings:menu.index("}", settings)]
if 'text: "Settings..."' not in settings_block:
    raise SystemExit("test_source.sh: Settings opens an extra page and needs an ellipsis")
PY
if awk '
  /id: statusBar$/ { in_status = 1 }
  in_status && /resultSummary/ { found = 1 }
  in_status && /^      }/ { exit }
  END { exit !found }
' App.qml; then
  fail "the window status line must not repeat the list result count"
fi

# Invariant: Both action menus own navigation locally because Qt popups intercept window shortcuts.
# Placement happens after opening and whenever content is measured.
for file in components/AppMenu.qml components/MessageMenu.qml; do
  grep -q 'Keys.onPressed' "$file" \
    || fail "$file needs popup-local keyboard navigation"
  grep -q 'onOpened:' "$file" \
    || fail "$file must place itself after its contents exist"
  grep -q 'onHeightChanged: root.place()' "$file" \
    || fail "$file must re-place itself when its measured height changes"
  grep -q 'MenuActionRow {' "$file" \
    || fail "$file must use the shared menu-row contract"
  if grep -q 'component MenuRow: Rectangle' "$file"; then
    fail "$file duplicates the shared menu-row presentation"
  fi
done

# Invariant: Every drawn action row must be in menuRows or keyboard selection and Enter cannot reach
# it.
python3 - <<'MENUROWS'
import re
from pathlib import Path

for name in ("components/AppMenu.qml", "components/MessageMenu.qml"):
    source = Path(name).read_text()
    listed = re.search(r"property var menuRows:\s*(?:\w+\s*\?\s*)?(\[[^\]]*\](?:\s*:\s*\[[^\]]*\])?)", source, re.S)
    if not listed:
        raise SystemExit("test_source.sh: %s must list its rows in menuRows" % name)
    known = set(re.findall(r"[A-Za-z_][A-Za-z0-9_]*", listed.group(1)))
    drawn = re.findall(r"MenuRow \{\s*id: ([A-Za-z_][A-Za-z0-9_]*)", source)
    missing = [row for row in drawn if row not in known]
    if missing:
        raise SystemExit("test_source.sh: %s draws %s without listing it in menuRows"
                         % (name, ", ".join(missing)))
MENUROWS

# Invariant: Feature views receive semantic colours from App. Reading theme roles locally makes the
# same concept drift between pages and prevents App from naming it.
for file in components/AppMenu.qml components/MessageMenu.qml components/AccountSwitcher.qml \
  components/MailboxTabs.qml components/SetupPage.qml \
  components/SetupPage.qml components/ImagePopover.qml \
  components/ComposeView.qml; do
  if grep -nE '(^|[^A-Za-z])Color\.' "$file"; then
    fail "$file reads theme colours instead of receiving semantic roles"
  fi
done

# Invariant: Row actions must meet the compact desktop hit-target floor.
if grep -n 'size: Style\.space(20)' components/MessageRow.qml; then
  fail "message row actions need at least a 24px hit target"
fi
grep -q 'anchors.margins: root.visualInset' components/IconButton.qml \
  || fail "IconButton hover fill must sit inside its hit target"
grep -q 'verticalPadding: MailStyle.space(2)' components/ReaderNotice.qml \
  || fail "ReaderNotice actions must keep their visual surface inside the notice"
grep -q 'width: implicitWidth' components/ReaderNotice.qml \
  || fail "ReaderNotice actions need a trailing intrinsic-width lane"
if grep -q 'Ctrl+Enter sends' components/ComposeView.qml; then
  fail "Compose must render shortcut hints from Keymap instead of hand-writing a second copy"
fi
grep -q 'visible: !root.showPage && !root.composing' App.qml \
  || fail "mailbox header commands must stand down while Compose owns the task"
awk '
  /id: header$/ { in_header = 1 }
  in_header && /visible: !root.composing/ { found = 1 }
  in_header && /id: body$/ { exit !found }
  END { exit !found }
' App.qml || fail "Compose must replace the mailbox header instead of stacking another one below it"
grep -q 'anchors.top: header.visible ? header.bottom : parent.top' App.qml \
  || fail "Compose must reclaim the space of the hidden mailbox header"
if grep -q 'text: subjectField.text' components/ComposeView.qml; then
  fail "the Compose header must not repeat the Subject field"
fi
awk '
  /id: titleRow/ { in_title = 1 }
  in_title && /anchors.horizontalCenter: parent.horizontalCenter/ { centered = 1 }
  in_title && /anchors.left: backBar.right/ { follows_back = 1 }
  in_title && /^    }/ { exit !(centered && !follows_back) }
  END { exit !(centered && !follows_back) }
' components/ComposeView.qml \
  || fail "the Compose title must stay centered independently of the Back control"
awk '
  /id: fromButton/ { in_from = 1 }
  in_from && /bordered: true/ { found = 1 }
  in_from && /^      }/ { exit !found }
  END { exit !found }
' components/ComposeView.qml \
  || fail "the From dropdown must use an outline treatment"
awk '
  /id: fromButton/ { in_from = 1 }
  in_from && /background: Style.normalFillFor\(root.textColor, root.accentColor\)/ { fill = 1 }
  in_from && /verticalPadding: Style.spacing.inputPaddingY/ { padding = 1 }
  in_from && /^      }/ { exit !(fill && padding) }
  END { exit !(fill && padding) }
' components/ComposeView.qml \
  || fail "the From dropdown must share the TextField fill and vertical sizing"

# Invariant: Sign out and removal are peer account actions. Removal stays last in the action row
# instead of falling onto a detached row beneath it.
awk '
  /text: "Sign out"/ { saw_sign_out = 1 }
  saw_sign_out && /text: "Remove account"/ { saw_remove_after = 1 }
  saw_remove_after && /bordered: false/ { ghost = 1 }
  END { exit !(saw_sign_out && saw_remove_after && ghost) }
' components/SetupPage.qml \
  || fail "Remove account must be the trailing danger ghost beside Sign out"
awk '
  /^  Widgets\.Button \{/ { top_button = 1; next }
  top_button && /text: "Remove account"/ { exit 1 }
  top_button && /^  \}/ { top_button = 0 }
' components/SetupPage.qml \
  || fail "Remove account must not be detached from the account action row"

# Invariant: The mailbox selected expression includes its search continuation; an intervening
# binding silently attaches that guard to another property.
awk '
  /selected: !!root.service && root.service.mailboxKey/ {
    getline
    if ($0 !~ /searchQuery/) exit 1
  }
' components/MailboxSidebar.qml \
  || fail "the mailbox row's selected guard lost its search continuation line"

# Performance: Repository assets ship with every plugin clone. Keep explicit bounded exceptions for
# marketplace preview art and the pinned bundle icon.
limit=$((128 * 1024))
preview_limit=$((384 * 1024))
oversized=$(cd ..
  while IFS= read -r -d '' file; do
      [ -f "$file" ] || continue
      case "$file" in
        (preview.png) ceiling=$preview_limit ;;
        (app/resources/macos/omamail.icns) ceiling=111809 ;;
        (*) ceiling=$limit ;;
      esac
      size=$(wc -c < "$file")
      if [ "$size" -gt "$ceiling" ]; then
        printf '%s\t%s\n' "$size" "$file"
      fi
  done < <(git ls-files -z))
if [ -n "$oversized" ]; then
  printf '%s\n' "$oversized" >&2
  fail "the files above are over their size ceiling; keep large assets out of the clone"
fi

# Invariant: the standalone icon subset must match its reviewed bytes and
# provenance. Native resource tests verify coverage of maintained QML glyphs.
font_provenance=app/assets/fonts/NerdFonts-PROVENANCE.md
[ -f "../$font_provenance" ] || fail "bundled fonts must record their provenance"
while read -r expected file; do
  actual=$(cd .. && shasum -a 256 "$file" | awk '{print $1}')
  [ "$actual" = "$expected" ] || fail "$file does not match its reviewed upstream checksum"
  grep -q "$expected" "../$font_provenance" \
    || fail "$file checksum is missing from its shipped provenance"
done <<'FONT_CHECKSUMS'
a6de4cfc8a01d6e1271370e35591e23e696c84c52e36929b55d719916ada6b08 app/assets/fonts/SymbolsNerdFontMono-Regular.ttf
FONT_CHECKSUMS

# Invariant: Generated bundle icons must match their reviewed size, checksum and provenance recipe.
icon_provenance=app/resources/macos/ICON-PROVENANCE.md
[ -f "../$icon_provenance" ] || fail "the macOS icon must record its provenance"
mac_icon=app/resources/macos/omamail.icns
[ "$(cd .. && wc -c < "$mac_icon")" -eq 111809 ] \
  || fail "$mac_icon does not match its reviewed byte size"
mac_icon_checksum=bd29ce1e72aa9db37ed5b1cb930956d2d933dc4426e7cea7f1b8baf2edb9262d
actual_mac_icon_checksum=$(cd .. && shasum -a 256 "$mac_icon" | awk '{print $1}')
[ "$actual_mac_icon_checksum" = "$mac_icon_checksum" ] \
  || fail "$mac_icon does not match its reviewed checksum"
grep -q "$mac_icon_checksum" "../$icon_provenance" \
  || fail "$mac_icon checksum is missing from its shipped provenance"
grep -q '1277a2cf247b275a15961fb20175420abb5dfc5489acb95313f4f604c09b6e78' "../$icon_provenance" \
  || fail "the macOS icon source checksum is missing from its shipped provenance"
windows_icon=app/resources/windows/omamail.ico
windows_icon_checksum=2562966adb272711ae0274f7eade7ef2680781bb4405182280a310658752131d
actual_windows_icon_checksum=$(cd .. && shasum -a 256 "$windows_icon" | awk '{print $1}')
[ "$actual_windows_icon_checksum" = "$windows_icon_checksum" ] \
  || fail "$windows_icon does not match its reviewed checksum"
grep -q "$windows_icon_checksum" "../$icon_provenance" \
  || fail "$windows_icon checksum is missing from its shipped provenance"
grep -q '3c780a0881ca98ffb717eb2877bf2e8a877deb9ddc3593a2bcca1d19139616e4' "../$icon_provenance" \
  || fail "the canonical Omamail logo checksum is missing from icon provenance"

# Invariant: The compose form, account boundary and raw-message builder must keep the selected
# send-as address all the way to the provider. A missing link silently falls back to a default
# address and makes the selector lie. A mailto: link is a draft, not a page. The desktop handler
# summons the window with the URL; open() turns that into compose fields. Toggle would close a
# mailbox that is already on screen.
grep -q 'import "message/Mailto.js" as Mailto' App.qml \
  || fail "App.qml must parse mailto payloads through Mailto.js"
grep -q 'Mailto.draftFromPayload(payload)' App.qml \
  || fail "open() must seed compose from a mailto payload"
grep -q 'function beginDraft' components/ComposeView.qml \
  || fail "ComposeView must fill a new draft from a mailto"
grep -q 'omarchy-shell shell summon' ../scripts/mailto.sh \
  || fail "the mailto handler must summon Omamail, not toggle it"
grep -q 'exec "$installer"' ../scripts/link-plugin.sh \
  || fail "Magpie's install helper must use Enterprise's guarded copy installer"
grep -q 'registerMailtoHandler' Service.qml \
  || fail "the service must register the mailto handler when the plugin loads"
grep -q 'signal mailtoRequested(string url)' components/MessageReader.qml \
  || fail "a mailto in a message body must compose here, not leave through xdg-open"
if awk '
  /onLinkActivated:/ { in_link = 1 }
  in_link && /Qt.openUrlExternally\(link\)/ { found = 1 }
  in_link && /^[[:space:]]*\}/ { exit found ? 0 : 1 }
  END { exit found ? 0 : 1 }
' components/MessageReader.qml; then
  fail "MessageReader must not send mailto links out through Qt.openUrlExternally"
fi

grep -q 'sendIdentities' components/ComposeView.qml \
  || fail "compose From must list every connected mailbox that can send"
grep -q 'backend.call("account.identities"' Service.qml \
  || fail "sender identities must be projected by the native account domain"
grep -q 'root.service.switchTo' components/ComposeView.qml \
  || fail "choosing another mailbox as From must switch the sending account"
python3 - <<'PY'
from pathlib import Path

service = Path("Service.qml").read_text()
start = service.index("readonly property var senderSources:")
end = service.index("  function editingEntry()", start)
block = service[start:end]
if "hostsEpoch" not in block:
    raise SystemExit(
        "test_source.sh: sendIdentities must re-read after a mailbox host signs in"
    )
for required in ('onSenderSourcesChanged: scheduleSenderIdentities()',
                 'senderRequestSerial++', 'sendIdentities = []',
                 'serial !== root.senderRequestSerial', 'error || !result',
                 'backend.call("account.identities"'):
    if required not in block:
        raise SystemExit("test_source.sh: sender projection must fail closed and reject stale replies: " + required)
projection = service[service.index('property var conversationProjection:'):service.index('function refreshConversationProjection()')]
if 'conversationProjectionSerial++' not in projection or 'showsRail: false' not in projection:
    raise SystemExit("test_source.sh: conversation changes must invalidate the previous projection")
if 'serial !== root.conversationProjectionSerial' not in service:
    raise SystemExit("test_source.sh: stale conversation projections must not reach the reader")
recount = service[service.index("function recount("):]
recount = recount[:recount.index("\n  }") + 4]
if "hostsEpoch" not in recount:
    raise SystemExit(
        "test_source.sh: recount() must bump hostsEpoch so From can see signed-in mailboxes"
    )
PY

grep -q 'from: root.fromEmail' components/ComposeView.qml \
  || fail "ComposeView must submit the selected From address"
grep -q 'from: from' account/MailAccount.qml \
  || fail "MailAccount must pass the selected From address to Message.js"
grep -q 'fromHeader(values.from, values.fromName)' message/Message.js \
  || fail "Message.js must write the selected From header, display name and all"
for client in providers/GmailApiClient.qml; do
  grep -q 'function getSendAs' "$client" \
    || fail "$client must implement the provider-neutral sender-list operation"
done

# Invariant: Attach files uses a child-process picker because Qt FileDialog under the gtk3 platform
# theme aborts the host shell.
if grep -nE 'FileDialog|QtQuick\.Dialogs' -- "${QML_FILES[@]}"; then
  fail "QML must not open FileDialog: it crashes Quickshell under the gtk3 platform theme"
fi
python3 - <<'PY'
from pathlib import Path

compose = Path("components/ComposeView.qml").read_text()
start = compose.index("function chooseFiles()")
end = compose.index("\n  function ", start + 1)
block = compose[start:end]
if 'enqueueAttach("pick")' not in block:
    raise SystemExit("test_source.sh: Attach must pick files out of process through attachment.sh")
if "FileDialog" in block or "execDetached" in block:
    raise SystemExit(
        "test_source.sh: Attach must not open an in-process dialog or a detached file manager"
    )
PY

python3 - <<'PLUGINDIR'
from pathlib import Path
source = Path("Service.qml").read_text()
if "Qt.resolvedUrl(\"..\")" not in source:
    raise SystemExit("test_source.sh: Service must resolve its own directory when Omarchy hides __sourceDir")
if "decodeURIComponent" not in source:
    raise SystemExit("test_source.sh: Service must decode its resolved filesystem path")
PLUGINDIR

python3 - <<'PREVIEWREAD'
import re
from pathlib import Path

source = Path("account/MailAccount.qml").read_text()

# Invariant: The read mark on arrival must ask whether this was a preview. The decision itself lives
# in `Model.marksReadOnArrival`, where it is unit-tested; what is guarded here is that the call site
# still asks it.
mark = re.search(r"if \((?:!markedRead && )?Model\.marksReadOnArrival\([^)]*\)\)\s*\n?\s*(?:markedRead = )?root\.act\([^)]*markRead",
                 source)
if not mark:
    raise SystemExit("test_source.sh: MailAccount must mark an opened message read")
if "selectionIsPreview" not in mark.group(0):
    raise SystemExit("test_source.sh: the read mark on arrival must skip a preview "
                     "(`root.selectionIsPreview`), or stepping a list reads it")
PREVIEWREAD

# Invariant: Backend calls must be declared in the contract and gated on fixed feature revisions
# that survive release folding.
python3 - <<'CONTRACTCALLS' || exit 1
import json, pathlib, re
root = pathlib.Path("..")
contract = json.loads((root / "backend-api.json").read_text())
methods = set(contract["methods"])
files = [p for p in (root / "ui").rglob("*") if p.suffix in (".qml", ".js") and "tests" not in p.parts]
called = {}
for path in files:
    for match in re.finditer(r'\.call\(\s*"([a-z][A-Za-z0-9]*(?:\.[a-z][A-Za-z0-9]*)+)"', path.read_text()):
        called.setdefault(match.group(1), set()).add(str(path.relative_to(root)))
unknown = sorted(set(called) - methods)
if unknown:
    raise SystemExit("test_source.sh: QML calls backend methods the contract does not declare: "
                     + ", ".join(m + " (" + ", ".join(sorted(called[m])) + ")" for m in unknown))

CONTRACTCALLS
# Invariant: Credential metadata and secret values cross one typed backend RPC. Provider and
# presentation QML must never regain a platform command or keyring helper.
if grep -E 'secret-tool|scripts/keyring-(lookup|store|clear)\.sh' \
    providers/*.qml >/dev/null; then
  fail "QML credential paths must use the typed backend credential RPC"
fi

printf 'test_source.sh ok\n'
