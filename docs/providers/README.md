# Gmail account boundaries

Magpie supports Gmail and Google Workspace mailboxes through the Gmail API, and Google Calendar through the same Google account. Account identity is the lower-cased mailbox address, including custom Workspace domains. Do not restrict addresses to `gmail.com` or rename IDs: credentials, cached mail, drafts and outbox entries depend on their existing identities.

- Use the shared Gmail session for transport, quota pacing, token refresh and mutations. UI components express mail operations; they do not select a protocol or credential destination.
- On iOS, token refresh uses the public OAuth client ID saved on that exact account in the private registry and the account/client-bound Keychain grant. It must not read desktop `credentials.json` or borrow another account's client. Desktop client-file compatibility remains separate.
- Gmail message resources retain headers, MIME structure and base64url bodies. Detail reads update only fields they carry; absence must not erase listing metadata.
- Gmail has server thread identity, but the list remains one row per message. The reader can show thread members. Do not infer conversation grouping from thread identity.
- Product actions are fixed for Gmail. Authentication, backend readiness, account refusals, ownership and calendar write permissions still gate operations before optimistic updates.
- Qualify message, thread, label and attachment identities by account. Two Gmail accounts can contain identical IDs or label names.
- Historical account records with no provider mean Gmail. Explicit unsupported providers must fail before credential access or network activity; never normalize them to Gmail or delete their stored data.
- Retained `providers.*` RPCs are Gmail compatibility interfaces. They do not expose a configurable provider registry.
- Preserve official Gmail artwork colors, and resolve web locations with the account-aware Gmail helpers.

Read [security boundaries](../SECURITY-BOUNDARIES.md) before touching transport or authentication, and [backend compatibility](../BACKEND-RUNTIME.md) before changing wire methods.
