# Native iPhone engine

`magpie-mobile` packages the shared Rust engine as an Apple static library. Its C interface in `include/` owns opaque engine/request/result handles; Swift's `NativeEngine` actor in the sibling `magpie-ios` repository handles asynchronous completions and releases results. No desktop executable or JSON-RPC subprocess runs on iOS.

The engine uses one bounded executor with a Tokio `LocalSet`, at most 32 admitted requests, 32 MiB per frame and 64 MiB of aggregate admitted input. Responses preserve the backend's method-specific bounds. Admission and lifecycle state are separate from provider completion: cancellation or a Swift timeout cannot release a mutation's ownership lock while its underlying future is still running. Suspension refuses new writes and drains admitted work; closing waits for quiescence.

The host supplies its app-owned storage roots and Keychain identity. iOS credentials are device-only, available after the first unlock and isolated by client/account. Private files reject unsafe ancestry and links. Attachments copied into a draft have independent ownership so closing another reader/editor cannot delete them. Account removal targets that account's credentials and private records, preserving siblings.

`engine.info` reports ABI, backend API, development version and the build's source identity. `magpie-ios/scripts/build-engine.sh` computes that identity from the engine source, builds both Apple architectures and writes the matching app resource. A mismatched native library fails before account access. The identity is a compatibility guard, not a signature or a substitute for release checks.

Gmail and Calendar operations use the same provider and durable state machinery as Linux. OAuth uses the phone's own Google iOS client with PKCE/state, not a copied desktop secret or refresh token. Sending, edits and calendar mutations retain ownership and retry identities through suspension and uncertain responses. Model output does not authorize sending.

Enterprise hosts AI, authoritative snooze mutations and APNs. The phone uses the narrow paired HTTPS API in `src/backend/phone`; it cannot send arbitrary backend methods to Enterprise. Pairing intersects device access with current account ownership, and revocation removes access. AI requests preserve their selected message/draft context and parent identity; changes are reviewed on the phone before application.

Unit and integration tests live with their Rust modules and the iPhone Core package. Native simulator checks additionally cover the actual C ABI, Keychain, private filesystem, lifecycle and WebKit/JavaScript sanitization boundaries with synthetic fixtures. File protection and operating-system lifecycle behaviour require physical-device evidence.
