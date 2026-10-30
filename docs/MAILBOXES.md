# Connect Gmail

Magpie supports multiple Gmail and Google Workspace accounts, including accounts with custom domains. Open Settings and choose **Add mailbox...** to go directly to Google setup.

## Connect a mailbox

1. Follow the setup page to create a Google Cloud OAuth client and enable the Gmail API.
2. Save the client details, then sign in with Google in your browser.
3. Add further accounts through the same setup flow. Magpie reuses the saved OAuth client.

Existing Gmail accounts keep their credentials, account names, signatures, aliases, drafts and downloaded mail when upgrading. Refresh tokens stay in the system credential store. Client configuration stays in the private Omamail configuration directory; it does not go into shell settings.

## Calendars in Skylark

Skylark is a separate app with its own Google authorization and calendar storage. Open a meeting invitation or suggested event from Magpie to review it in Skylark. Existing calendar files remain untouched until the migration is verified. On iPhone, use Skylark’s reminder settings to explicitly move scheduled reminders; upgrading Magpie does not stop them.

## Search and offline mail

Search accepts plain text and Gmail operators such as `from:`, `to:`, `is:unread` and `label:`. Saved results appear first, then Gmail determines the online results. **All accounts** searches each account separately, so `me` and labels resolve in the owning account. Typing and accepting suggestions do not send Gmail requests.

Downloaded mail remains readable offline. Background downloads and queued edits follow the account's existing pacing and retry rules. Attachments download on demand. An inbox overview reuses downloaded message text before fetching missing content.

## Unsupported configurations

Other mail services and non-Google calendar integrations are no longer supported. An explicit unsupported account must not be interpreted as Gmail. Existing unsupported records and credentials remain intact; an incompatible account configuration is refused rather than rewritten. Skylark preserves unsupported historical calendar sources without activating them.

## Remove the application

Removing the plugin preserves account data, caches, drafts and credentials. If you enabled the optional CLI link, run `python3 scripts/backend-runtime.py disable-cli` before removing the plugin. Signing out from an account clears its own credential through the application.

See [Magpie installation and controls](../MAGPIE.md) and [backend recovery](BACKEND-RUNTIME.md).
