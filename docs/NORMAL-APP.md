# Magpie Mail as a normal app

Magpie Mail runs as a native application, not as a mail window inside the Omarchy shell. The application composes the shared `ui/Service.qml` and `ui/App.qml`, starts `omamail serve`, and uses the existing accounts, credentials, cache, drafts, outbox, and managed engine. The `omamail` binary and data names remain unchanged so those records keep their identities.

The `magpie-mail` shell plugin is only a small envelope. It shows the numeric unread count and opens or raises the native app. It has no message preview, window toggle, account registry, backend process, credentials, or mail content.

## Window and background behavior

Closing the window hides it. The native process remains available for new-mail notifications and for activation from the envelope, a notification, a launcher, or a `mailto:` link. **Quit** in the app menu exits the process.

The managed `magpie-mail-engine.service` remains responsible for local sync, Point preparation, and the 30-second snooze schedule. Snoozed mail can therefore return while the window is hidden or after the native app has explicitly quit, provided the managed engine is running. New-mail notification decisions and desktop delivery belong to the native app, so they continue while its window is hidden but not after explicit Quit. Login startup uses `magpie-mail --background` to restore alert delivery without opening a window.

The managed engine is required for curated notifications while the window is hidden because it prepares Points in the background. A frontend-owned backend does not provide that background guarantee.

## Activation

The stable `magpie-mail` launcher supports:

- `magpie-mail` — open or raise the app;
- `magpie-mail --background` — start hidden, or leave an existing window unchanged;
- `magpie-mail --compose` — open a new draft;
- `magpie-mail 'mailto:…'` — open the draft represented by that exact URL.

One native instance owns the window. Later invocations hand their bounded activation payload to that instance and exit after acknowledgement. Activation payloads are `{}` for open, `{"compose":true}` for compose, and `{"mailto":<exact url>}` for a mailto draft. Command-line URLs retain their exact valid UTF-8 bytes. Platform file-open events use Qt's parsed URL representation, which can normalize percent escapes while preserving the draft's decoded fields. This is native application IPC, not an engine RPC, and no methods were added to `backend-api.json`.

The `omamail.desktop` identity remains stable for notification activation and the saved default mail client. Its desktop entry claims `x-scheme-handler/mailto` and preserves one `%u` argument. Default-client migration and mail keybindings use the native launcher, never `omarchy-shell shell summon` or `toggle`. The default-client settings action and its XDG/Hyprland status helper are Linux-only. macOS keeps incoming `mailto:` through `CFBundleURLTypes` without those controls.

## Envelope status boundary

The native app publishes `$XDG_RUNTIME_DIR/magpie-mail/status.json` atomically with owner-only access. The snapshot contains only:

- `ready`;
- `windowOpen`;
- `showBarIcon`;
- `unreadTotal`;
- `updated`, the native host's epoch-millisecond publication time.

The envelope rejects malformed, oversized, non-finite, negative, fractional, or excessively large values. It also rejects a snapshot more than 45 seconds old or more than five seconds in the future. Unknown fields are discarded. Account names, addresses, subjects, message bodies, authentication objects, and tokens never cross this interface.

The app refreshes the snapshot every five seconds and immediately after relevant state changes. A stale or unavailable snapshot shows the envelope without a count; clicking still launches the app. The native activation socket is `activation.sock` beside the status file in the same private runtime directory.

## Settings migration

The old shell Service stores ordinary settings in `~/.config/omamail/settings.json`. The inherited native host stores them in `${XDG_DATA_HOME:-~/.local/share}/Omamail/Omamail/settings.json`. On the first native cutover, the host validates and copies the complete existing file to the native path atomically with owner-only permissions, but only when no native settings file already exists. It migrates `notification-routes.json` by the same rule. Existing native settings and routes are never overwritten. The two tolerated legacy keys `previewOnCursor` and `markReadDelaySec` remain accepted so the whole current file survives.

Display, layout, remote-image and Inbox window preferences stay in the shared `~/.config/omamail/window.json`, which the native host already reads and writes through its backend-compatible configuration path. Accounts, credentials, drafts, cache and outbox records do not move.

## Installation and updates

On the main machine, use only the maintained Enterprise installer described in `MAGPIE.md`. It builds and publishes the native app and matching backend outside the watched shell-plugin tree, installs the stable launcher and desktop metadata, preserves settings and account state, and installs the envelope separately. During the first cutover, the native app starts with `OMAMAIL_DISABLE_NOTIFICATIONS=1`, so the old shell Service remains the only alert producer while its replacement is checked. The installer replaces the envelope only after the native app is ready, restarts it normally, and verifies it again before enabling the login service. The initial cutover requires an unlocked desktop. Later native app, engine, launcher, and icon updates can proceed while locked; envelope and shell-configuration writes still wait for unlock.

Do not run the inherited standalone installer or the repository's install targets on the main machine. They do not provide Enterprise's lock checks, staging, rollback, service ownership, and self-heal integration.
