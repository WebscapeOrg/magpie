# Connect Gmail and Google Calendar

Magpie supports multiple Gmail and Google Workspace accounts, including accounts with custom domains. Open Settings and choose **Add mailbox...** to go directly to Google setup.

## Connect a mailbox

1. Follow the setup page to create a Google Cloud OAuth client and enable the Gmail API.
2. Save the client details, then sign in with Google in your browser.
3. Add further accounts through the same setup flow. Magpie reuses the saved OAuth client.

Existing Gmail accounts keep their credentials, account names, signatures, aliases, drafts and downloaded mail when upgrading. Refresh tokens stay in the system credential store. Client configuration stays in the private Omamail configuration directory; it does not go into shell settings.

## Choose calendars

Enable the Google Calendar API in the same Cloud project when using calendars. In calendar settings, enable Google Calendar access if required, refresh the account's calendars and choose which discovered calendars to show. Calendar settings preserve your choices, colors, reminders and default writable calendar. Shared and read-only calendars retain their permissions.

Calendar and mail keep separate caches. A calendar failure does not discard saved mail. Google authorization and API errors are reported without exposing credential or server-response text.

## Search and offline mail

Search accepts plain text and Gmail operators such as `from:`, `to:`, `is:unread` and `label:`. Saved results appear first, then Gmail determines the online results. **All accounts** searches each account separately, so `me` and labels resolve in the owning account. Typing and accepting suggestions do not send Gmail requests.

Downloaded mail remains readable offline. Background downloads and queued edits follow the account's existing pacing and retry rules. Attachments download on demand. An inbox overview reuses downloaded message text before fetching missing content.

## Unsupported configurations

Other mail services and non-Google calendar integrations are no longer supported. An explicit unsupported account must not be interpreted as Gmail. Existing unsupported records and credentials remain intact; an incompatible account configuration is refused rather than rewritten. Unsupported calendar sources are preserved but are not activated.

## Remove the application

Removing the plugin preserves account data, caches, drafts and credentials. If you enabled the optional CLI link, run `python3 scripts/backend-runtime.py disable-cli` before removing the plugin. Signing out from an account clears its own credential through the application.

See [Magpie installation and controls](../MAGPIE.md) and [backend recovery](BACKEND-RUNTIME.md).
