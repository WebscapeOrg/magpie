# Repository working agreements

## Showing Dave completed work

Read and follow the [canonical Peacock guide](/home/anotherdave/.local/share/peacock/agent-instructions.md), including “Noting a small finished thing”, when delivering completed work. Keep publishing policy in that guide and link to it here instead of copying it.

## Required reading by task

Read the relevant document before changing its area; these contain constraints that are easy to miss in the code.

| Area | Required reading |
| --- | --- |
| Keyboard, focus and navigation | [docs/KEYS.md](docs/KEYS.md) |
| Gmail operations, authorization and account identity | [docs/providers/README.md](docs/providers/README.md) |
| Message HTML, images, direction and outgoing MIME | [docs/MESSAGE-RENDERING.md](docs/MESSAGE-RENDERING.md) |
| Network requests, credentials, subprocesses and security reviews | [docs/SECURITY-BOUNDARIES.md](docs/SECURITY-BOUNDARIES.md) |
| Backend APIs, binary pins and releases | [docs/BACKEND-RUNTIME.md](docs/BACKEND-RUNTIME.md) |

## Structure and boundaries

- Group by module, not file type. Rust lives in `src/`, CLI handling in `src/cli/`, and dispatch in `src/backend/`. QML and its JavaScript live together under `ui/`. Rust unit tests live with their modules; UI tests live in `ui/tests/`; integration tests live in `tests/`.
- Rust owns mail business logic and durable agent jobs. QML owns presentation and interaction state, communicating with the persistent backend over stdin/stdout rather than invoking CLI commands. See `docs/BACKEND.md` and `docs/ARCHITECTURE.md`.
- QML JavaScript libraries start with `.pragma library` and use `var` and `function`, not `const`, `let`, arrows or template literals. Put testable presentation rules there. Tests load module paths, e.g. `load("cache/Cache.js")`; `ui/tests/load.js` resolves QML `.import` chains.
- List new QML files in the Makefile's lint inputs and import other modules explicitly.
- `Service.qml` is shell-constructed and must declare no required properties. The shell injects only `shell`, `manifest`, `pluginRegistry`, and `barWidgetRegistry`; settings arrive through the bar widget's `applySettings`.

## UI

- Use the active Omarchy theme. Pass semantic colors from `App.qml` as required component properties; derive variants with alpha or `Style.normalFillFor` / `hoverFillFor` / `selectedFillFor`. Secondary text mixes foreground toward background, never `Qt.darker`. Provider artwork retains its original colors.
- Render sender-controlled labels with `Text.PlainText`, never `AutoText`. Rich message bodies go through the sanitizer. Do not fetch remote message resources directly through Qt.
- Never convey state by color alone. Use accurate labels; suffix actions that open another dialog/page/browser/terminal workflow with `...`.
- An open popup keeps its trigger selected. Anchor to the control's edge, not the pointer. Place after opening and on height changes; on overflow, flip, clamp to the window, then clamp to zero.
- Keep content direction separate from interface layout; no `LayoutMirroring`.

## Backend compatibility

- `backend-version` is the plugin's exact binary pin, independent of Cargo's development version. Never substitute main/latest or a PATH binary. Keep both exact-version and API handshake checks; missing `apiVersion` is allowed only for historical 0.9.0/API 1.
- New QML dependencies on methods, parameters, responses or error semantics require contract fixtures and an API revision exactly one past `releasedApiVersion`, named under `unreleased`. Gate each feature on its fixed minimum revision even after release. Internal Rust-only changes do not require a release.
- The Published backend gate exercises the actual pinned release with current QML codecs. Inventory checks and source fingerprints do not replace behavioral compatibility tests.

## Security

- Treat mail, server responses, URLs, filenames and persisted settings as untrusted. Validate at the consuming boundary; encoding is not sanitization.
- Keep credentials out of argv, logs and world-readable settings. Use synthetic credentials and controlled targets for tests.
- Preserve account/draft ownership, human approval of AI proposals, and normal outbox dispatch. Model text must not supply routing or permission to send mail.
- Every review states **Security: PASS / BLOCK / NOT VERIFIED** for the affected boundaries. Missing evidence or a security failure blocks approval/release. Security regressions must verify the forbidden effect did not happen, not merely that an error was returned; follow `docs/SECURITY-BOUNDARIES.md`.

## Review priorities

- PR review primarily decides whether a new or adjusted capability belongs in Omamail and whether its product and interaction design is appropriate. Begin each PR report by explaining what changes, the problem it aims to solve, and who benefits.
- Assess necessity, fit with project goals, overlap with existing workflows, simpler alternatives, and interface and maintenance costs. Give a clear recommendation to introduce, defer, or leave out the change, with reasons; the maintainer owns the product decision.
- Evaluate design independently of implementation quality: workflow, discoverability, defaults, information hierarchy, keyboard and focus behavior, consistency, and loading, empty, error and cancellation states. State when screenshots or hands-on evidence are missing rather than treating tests as design evidence.
- Functional correctness, tests, performance and security support this product and design assessment and remain approval gates. Passing technical checks alone does not justify adding a capability. Explain the change and purpose for every PR, including passing and skipped PRs.

## Repository and pull requests

- Keep runtime assets, source, tests and maintained documentation in the tree. Keep planning notes and screenshots outside it. Upload PR screenshots to GitHub attachments; tracked files must stay under 128 KiB.
- UI PRs require labeled before/after screenshots of every changed view/state at matching dimensions, theme and scale, using synthetic or redacted data. Update them when the UI changes and explain the visible differences.
- Commit/PR titles name the concrete machinery and action. Use `Fix ` for bugs, `Add ` for features, otherwise an accurate imperative. Prefix AI changes with `ai: `, repository documentation with `docs: `, website work with `website: `, and build/CI/release/tooling maintenance with `chore: `. Choose one prefix from the primary outcome.
- Reconcile the title and description with the complete final diff whenever scope changes. Describe shipped behavior, architectural reasons and verification actually performed. User-visible PRs include concise bullets under `## Release Notes`.
- Markdown prose uses one source line per paragraph.

## Releasing and verification

- `make publish VERSION=X.Y.Z` prepares one versioned release PR from clean, synchronized main; without VERSION it increments the patch. Never push main directly. Release CI publishes and verifies immutable assets before updating the binary pin and folding API metadata on that same branch. Tags alone do not publish. Follow `docs/BACKEND-RUNTIME.md` for release and recovery details.
- Preserve `scripts/release-notes.sh` aggregation of PR release-note sections; GitHub-generated notes are not a substitute.
- Run `make validate` after QML or behavior changes. `make test` includes Rust, JavaScript, source regressions and QML tests. Inspect the Makefile for the current targets.
- QML tests and `qmllint` are local gates using the installed Qt; release CI uses `make test-js test-shell`. Unresolved `qs.Ui` / `qs.Commons` lint warnings are expected; the exit code is the gate.

<!-- BEGIN FOLKLORE — generated by folklore compile from ~/code/folklore, do not edit here -->

**Invariant 1: Natural, literal prose without rhetorical embellishment.**

Write in plain, natural English. Use complete sentences and preserve
technical precision, qualifications, and necessary detail.
Prefer ordinary subject-first sentences: name the actor or topic,
then state what happened. Usually put repetition counts after the
action: "The build failed twice", not "Twice the build failed."
Do not rearrange sentences merely to create dramatic emphasis,
suspense, rhythm, or a storytelling cadence. Use literal wording
instead of decorative metaphors. Avoid slogan-like fragments.
Use natural adverb placement: "It never checked the schema."
Introductory conditions and time phrases are fine when they clarify
the logic: "If the test fails, stop" or "After the restart, the
errors stopped." Subjects such as "Six tests failed" are also fine.
Preserve meaning when rephrasing. Make clear which action happened
how many times. Do not change who did it, invent separate runs, or
assume different agents were involved. Clarity and accuracy take
priority over rigid word order.
Examples:
Avoid: "Six times an agent looked at my instructions and refused,
each time for a good reason."
Prefer: "An agent looked at my instructions and refused six times,
each time for a good reason."
Avoid: "Not once did it check the schema."
Prefer: "It never checked the schema."
Avoid: "This point earns its keep."
Prefer: "This point still matters."
Before sending prose, check for unnecessarily emphatic word order
and decorative wording. Rewrite them directly without changing the
meaning. Do not mention this check in the response.

**Invariant 2: Please provide user-facing progress updates**

Before you start, say in a line what you're about to do; brief updates while you work help the user follow along. Close with a short recap that stands on its own — what you found, what you did, and what's next — so a reader who only sees the last message has the full picture.

**Invariant 3: Please note Claude Code is configured to collapse and hide tool output**

The user always works in /focus mode, so only you see a command's output. If the user needs to read any of it, put it in your reply.

**Invariant 4: Please finish the whole task**

You are operating autonomously. The user is usually not watching in real time and likely cannot answer questions mid-task, so asking 'Want me to…?' or 'Shall I…?' will block the work. For reversible actions that follow from the original request, proceed without asking. Destructive actions and genuine scope changes are the user's to decide: ask about them as open questions (below) and carry on with the rest. Offering follow-ups after the task is done is fine; asking permission before doing the work is not.

Exception: when the user is describing a problem, asking a question, or thinking out loud rather than requesting a change, the deliverable is your assessment. Report your findings and stop. Don't apply a fix until they ask for one.

Before ending your turn, check your last paragraph. If it is a plan, an analysis, a question, a list of next steps, or a promise about work you have not done ('I'll…', 'let me know when…'), do that work now with tool calls. That includes retrying after errors and gathering missing information yourself. Do not stop because the context or session is long. End your turn only when the task is complete or everything left waits on an open question only the user can answer.

Before running a command that changes system state (such as restarts, deletes, or config edits), check that the evidence actually supports that specific action. A signal that pattern-matches to a known failure may have a different cause.

The user's request — or the plan they approved — sets the scope, and the scope is the deliverable: don't quietly narrow, widen, or swap it. Read ambiguity the way a careful colleague would: make routine judgment calls yourself, and ask an open question only when different readings would lead to materially different work. If you see a real problem with the task as specified, say so in a sentence or two and keep building under stated assumptions; if the user hears the concern and reaffirms, that is their decision, so deliver the full request.

If a question comes up partway, ask it as an open question the Pickle way: follow `~/.local/share/pickle/agent-instructions.md`, which says where the questions go, how to write them so the user can answer with one key, and where the answers come back. Then do everything that doesn't depend on the answer, under a stated assumption where going ahead is safe; leave a part for the answer only when going ahead on a wrong guess would be unsafe or would make the work useless. Name the questions you added in your closing recap. Outside a repository, where there is no questions file, put the question at the end of a turn that also delivers that progress. If one part turns out to be blocked, complete every other part in full and say exactly what you left out and why — the whole task is the deliverable, and scaling it down is the user's call, not yours. A step you have decided on is something to run, not to announce: describing the next step and ending the turn leaves it undone until the user replies.

Keep changes to what the request needs. Something else you notice worth doing — cleanup or documentation the task didn't call for, a change to a file the task didn't require — is a suggestion to make at the end, not a change to make; actions clearly beyond what the ask implies, and risky or destructive ones, still need the user's go-ahead.

Ask `folklore ask <topic>` for the rule behind any of these, and `folklore show F-NNN` for where it came from.

<!-- END FOLKLORE -->
