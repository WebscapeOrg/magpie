# 🐦 Magpie

Magpie is Dave's MIT-licensed fork of [Omamail](https://github.com/huacnlee/omamail). It uses Omarchy's theme with proportional fonts and offers a single-pane reading flow alongside the original split view.

Open a message with a click or Enter. **Back**, Escape, or Left returns to the list. **Menu → Split view / Single pane** changes layouts. The first launch uses single pane; the choice is saved.

Open **Settings → Layout and fonts** with **Ctrl+,**. Interface, message list, and message body each have their own font chooser, size in points, and preview. Settings save automatically. Initial values are **Chillax Light, 17 pt** in all three regions. Choose **System UI font** to follow the desktop's proportional `sans-serif` fontconfig alias. This does not change Omarchy's bar or terminal fonts. An inherited Omamail message zoom is reset to 100% when Magpie first creates its font preferences. Later zoom choices are retained. Message zoom remains available with Ctrl++ / Ctrl+- / Ctrl+0 on top of the configured message size. Original-format messages may retain their sender's explicit styling; Reading and Plain text use your message font.

## Inbox

Unread subjects are bold. Each row has a circular sender avatar: an available Google contact photo, an organization logo cached by sender domain, or one initial. The Personal mailbox uses a house and Webscape uses a tree. The top-right **All / house / tree** button switches accounts or opens the unified inbox. **Folder** shows or hides folder navigation; it starts hidden. Layout, refresh and AI tools live in the main menu. The monochrome bird is shared by the window and bar.

Hover a row or move to it with the keyboard for **Mark unread**, **Snooze**, **Archive**, and **Trash**. Snooze offers tomorrow, the next Saturday and the next Monday at 08:00 in the local timezone, plus a custom future date and time. It archives the conversation and saves the schedule before changing Gmail. The persistent shell service returns due messages to Inbox as unread, catches up after resume, and leaves later Trash or Spam moves intact. **Menu → Snoozed mail…** returns a conversation early. Snooze currently requires Gmail and Enterprise to be awake to run on time.

The third line is an AI overview of the email's purpose, concrete request or useful outcome. A background worker reads message bodies (up to 48,000 characters, retaining the beginning and end of longer mail) without changing read state, drafts a concise line, then runs a separate editing pass against the original mail. It checks source evidence and caches the result by account and message. It identifies deadlines and amounts, treats promotions as optional, never invents the contents of linked pages or attachments, and omits sign-in codes and secrets. It has no mail-writing tools. Errors remain visible and **Menu → Retry AI overviews** retries unavailable results. **Menu → Pause new AI overviews** finishes the admitted batch and stops new work; the preference survives reopening. **Resume AI overviews** continues. An AI overview is a reading aid; opening the message remains the way to inspect its details.

The worker uses the isolated Claude CLI. A candidate that fails the length or exact-evidence checks gets one correction pass; an invalid correction stays unavailable for retry. When Enterprise's `claude-routed` is installed, it uses that existing headless routing policy; see the linked machine map for the policy. Google sign-in requests optional read-only Contacts access for contact photos. After granting it, choose **Menu → Refresh sender images** to refresh cached photos and logos immediately. If that access is unavailable, the row still uses the organization logo or initial. Avatar fetches use the backend's checked public HTTP transport and return raster data to Qt; the UI never loads sender-supplied remote URLs. Caches and snooze schedules live in private files below the platform state directory's `omamail/inbox/`.

## Enterprise installation

The maintained checkout is `~/code/magpie`. Enterprise's `omarchy/install.sh` copies its runtime files into the `magpie` plugin and `script/omarchy-selfheal` verifies those copies. There are no development symlinks. The installer checks the session lock before every watched write and never restarts Quickshell. See [Enterprise's living machine map](https://github.com/dreinecke/enterprise/blob/main/docs/omarchy-setup.md#magpie) for the migration and account setup.

Install the supplied font archive locally with `python3 scripts/install-font.py /path/to/Chillax_Complete.zip`. The font and its Fontshare license stay in the user's font directory; they are not redistributed in this repository. The UI loads the installed face through FontLoader, so it does not need a shell restart to recognize the new font.

The upstream release remains the fallback pin in `backend-version`. Phase 2 requires API 8 from this checkout. Follow the linked Enterprise machine map to build and install it. An installation with the older pinned API keeps mail working and waits for API 8 before starting these inbox features. The `omamail` backend filename, data/config directories, keyring namespace, and compatibility desktop handler filename intentionally remain unchanged. This preserves Google authorizations, account registry, cache, drafts, and undo-send state. The visible application and shell plugin are Magpie. Do not run stock Omamail and Magpie simultaneously against that shared state.

## Development

Keep `upstream` pointing at huacnlee/omamail and `origin` at dreinecke/magpie. Changes go through a branch and PR in this fork. `make validate` runs the inherited backend, UI, and packaging checks. Magpie's behavior tests are `ui/tests/test_display.js`, `ui/tests/qml/tst_display_settings.qml`, and the single-pane navigation test in `tst_app_compose_pending.qml`.

The font-aware primitives in `ui/controls` are copies of the installed Omarchy Quattro toolkit with local typography bindings. Their upstream MIT notice is in `ui/controls/LICENSE`. They keep Omarchy's theme and interaction conventions while letting Magpie's interface size differ from the rest of the shell.

### List view refinements

The list header keeps Search, Folder, Compose and the account selector; the Magpie name and bird appear at the top of Menu. The content frame uses equal insets on all four edges. Mailbox house/tree symbols follow the date, and row action centers are 15% farther apart. Icons use scalable Material Design font outlines at the display scale.

Sender artwork preserves its aspect ratio and fits inside the circular background with at least 30% radial clearance, including at square logo corners. LinkedIn uses its official 144 px tile and xneelo its official 300 px site icon; other organizations request up to 256 px through the existing domain-only logo service, whose available resolution varies. The avatar cache revision refreshes older low-resolution entries automatically. Sources: [LinkedIn brand site](https://brand.linkedin.com/) and [xneelo](https://xneelo.co.za/).

Unavailable overviews show a specific safe reason for worker startup, AI response, format/length, evidence validation or mail preparation failures, followed by the retry action. Older cached failures explicitly say no reason was saved. Hovering an elided overview reveals the full explanation. Paused, queued and running states remain distinct. This uses the unreleased API 8 snapshot contract; backend disconnection or an older backend has its own explanation.
