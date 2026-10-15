# 🐦 Magpie

Magpie is Dave's MIT-licensed fork of [Omamail](https://github.com/huacnlee/omamail). It uses Omarchy's theme with proportional fonts and offers a single-pane reading flow alongside the original split view.

Open a message with a click or Enter. **Back**, Escape, or Left returns to the list. The toolbar's **Split view / Single pane** button changes layouts. The first launch uses single pane; the choice is saved.

Open **Settings → Layout and fonts** with **Ctrl+,**. Interface, message list, and message body each have their own font chooser, size in points, and preview. Settings save automatically. Initial values are **Chillax Light, 17 pt** in all three regions. Choose **System UI font** to follow the desktop's proportional `sans-serif` fontconfig alias. This does not change Omarchy's bar or terminal fonts. Message zoom remains available with Ctrl++ / Ctrl+- / Ctrl+0 on top of the configured message size. Original-format messages may retain their sender's explicit styling; Reading and Plain text use your message font.

## Enterprise installation

The maintained checkout is `~/code/magpie`. Enterprise's `omarchy/install.sh` copies its runtime files into the `magpie` plugin and `script/omarchy-selfheal` verifies those copies. There are no development symlinks. The installer checks the session lock before every watched write and never restarts Quickshell. See [Enterprise's living machine map](https://github.com/dreinecke/enterprise/blob/main/docs/omarchy-setup.md#magpie) for the migration and account setup.

Install the supplied font archive locally with `python3 scripts/install-font.py /path/to/Chillax_Complete.zip`. The font and its Fontshare license stay in the user's font directory; they are not redistributed in this repository. The UI loads the installed face through FontLoader, so it does not need a shell restart to recognize the new font.

The native backend remains pinned to upstream's immutable release through `backend-version`. The `omamail` backend filename, data/config directories, keyring namespace, and compatibility desktop handler filename intentionally remain unchanged. This preserves Google authorizations, account registry, cache, drafts, and undo-send state. The visible application and shell plugin are Magpie. Do not run stock Omamail and Magpie simultaneously against that shared state.

## Development

Keep `upstream` pointing at huacnlee/omamail and `origin` at dreinecke/magpie. Changes go through a branch and PR in this fork. `make validate` runs the inherited backend, UI, and packaging checks. Magpie's behavior tests are `ui/tests/test_display.js`, `ui/tests/qml/tst_display_settings.qml`, and the single-pane navigation test in `tst_app_compose_pending.qml`.

The font-aware primitives in `ui/controls` are copies of the installed Omarchy Quattro toolkit with local typography bindings. Their upstream MIT notice is in `ui/controls/LICENSE`. They keep Omarchy's theme and interaction conventions while letting Magpie's interface size differ from the rest of the shell.
