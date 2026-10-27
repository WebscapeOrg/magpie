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

**Ask Harmony via hobnob to write and send email.** When work needs an email written or sent, or a check made with someone outside, draft the content and ask @harmony on hobnob to create or send it. Say which account she should use and who to copy. Outgoing mail in this household goes through Harmony, so a draft left in chat is one Dave has to chase or send himself.

**A rename covers every trace, not just the code.** When an app or repo is renamed, change the name everywhere it appears: code, service and unit names, git remotes, GitHub, docs, AGENTS.md, memory, data and the Caboodle suite. A leftover old name keeps services, pushes and docs pointing at something that no longer exists and leaves Dave hunting for it, so list anything you cannot change instead of leaving it quietly.

**Give Dave a button or a fixed URL, not a command to remember.** For any tool or app Dave runs, provide an in-app control (Relaunch, Restart, Uninstall) and a stable bookmarkable address. A terminal command or a changing port is something he has to ask an agent for again each time he needs it.

**Finished work is committed, pushed and running on Enterprise.** When a change to an app Dave uses is done, commit and push it, install the new build on Enterprise, and say in the recap whether the running app is now the new version. Dave judges the work by the app he opens, so merged code that is not installed looks to him like work that is not done.

**Every finished task leaves a Peacock note, even a small one.** When you finish any task, including a small one like installing something, publish a short Peacock artifact for it, with a screenshot where that makes sense. Dave opening it is what clears the agent's 'celebrating' status in Caboodle.

**iPhone apps follow Caboodle iOS and code/standards/mobile-app.** When building or polishing any of Dave's iPhone apps, copy Caboodle for iOS's patterns and check code/standards/mobile-app, since they already hold the polish Dave has approved and a from-scratch design has to earn it again. When Dave calls something a new standard, record it there so every app picks it up, and propose further standards through a Pickle question.

**Say on hobnob when you are blocked instead of going quiet.** If you are stalled or waiting on something, such as a limit, a session that is not running, or input from Dave, post one short line on hobnob saying what you are waiting for. A silent stop looks the same as work in progress, so Dave finds out only by pinging you.

**Ask Dave in plain words, with what each choice means for him.** Write a question to Dave in everyday terms: what happens to him under each option, without harness, hook or code internals. A question in internal terms is one he cannot answer, so it comes back to be asked again and the decision waits. When the trade-offs need more than a few lines, publish them in Peacock and link to it from the question.

**Prefer the complete, long-term fix over the quick partial one.** When the options are a narrow or deferred fix and a complete one that costs more effort, such as covering old records too, building every missing piece, or fixing the tool upstream, recommend the complete one. Dave wants what is best for the longer term even at more effort, and a partial fix leaves the old records or the tool to be redone later.

**A UI fix or pattern in one app is carried to its sibling apps.** Before solving a UI problem, check whether another Caboodle app has already solved it and reuse that solution. When you settle a new pattern, tell the agents of the sibling apps so they apply it too. Otherwise the same problem gets fixed again in each app and the apps drift apart in look and feel.

**Use Apple's iOS emoji artwork everywhere, including app icons.** Use the iOS version of an emoji on every platform, as an image when the platform would render a different one, and use the latest official iOS emoji as an app's icon. That way an emoji or icon looks the same on every device Dave uses instead of changing with each platform's emoji font.

**A Peacock note about an iPhone build carries an install link.** When a publication covers a new iPhone app build, include the Install now link, so Dave can try that build on his phone straight from the note instead of hunting for the install address.

**Check the live thing before you say it is done.** Before reporting that something is installed, fixed, running or still pending, read its current state from the device listing, the running process or the installed binary. A script's last line, a ticked task, a config file or an earlier report can say success while what Dave actually has is still the old state, so a claim built on them is often wrong.

**Report what was seen and label what was inferred.** In reports, recaps and messages, state as fact only what you verified. Mark causes and conclusions you have not confirmed as inferences, and say where your evidence stops, including which test suites actually ran. An unconfirmed claim stated as fact spreads into other agents' reports and emails to clients, where it is hard to take back.

**Dave prefers less: remove chrome, keep it plain.** When designing a screen, report or control, remove anything that repeats what is already visible, and prefer the plain version over a clever one. Add a control or note only when it is needed. Dave cuts extra buttons, notes and labels, so each one costs a round of edits, and he decides faster when the thing is plain.

**Keep Dave's chats for conversation, not automated notices.** Do not send Dave messages that only announce that something started, ran, finished or was published; Caboodle's counters already show him that, and extra notices bury the messages he must answer. Interrupt him only for something he must know or act on, and a monitor speaks only once a fault has lasted, so a passing blip never reaches him.

**Keep long multi-agent work recoverable across usage walls.** In a long task with background agents, keep a plan file listing every agent id, output path and next step, and have agents write results to files as they go. A usage wall stops every background agent at once and nothing resumes by itself, so unwritten results are lost. After an interruption, check each item against the code, because a batch where every file has changes may still be half done.

**Use Dave's names for things, not a source's or an id.** In anything Dave reads, call people, rooms, todos and sessions what he calls them, not what a document, vendor or ID number calls them, because a name he doesn't use leaves him unable to tell which thing is meant. Keep the source's label only on the artefact's own record.

**Leave whitespace between adjacent UI elements.** Before shipping a UI change, check that every heading, row, button group and icon has clear space around it and nothing touches or crowds its neighbour, at narrow widths too. Dave sends back layouts that look squashed even when they work, so a missed check costs another round.

**Name the exact permission switch when the sandbox blocks you.** When a session's sandbox blocks work, tell Dave in your first report which setting to change (for example /permissions → Full access), because an approval recorded in Pickle or chat does not change it and he cannot unblock you without knowing the control. Retry the blocked command before you report it as still blocked, since the setting may already have changed.

**A status check or inbox read must advance the pending work.** When you answer a status question, read the inbox or fix your identity, also check your assigned carrots and pending deliverables, then do the next step. Acknowledging without acting counts as a miss, because the assigned work sits idle while the agent looks busy and Dave has to chase it.

**Read the test exit code before you commit; never pipe it away.** Run the test suite or build without piping it through tail or grep, or capture its exit status separately, and commit, push or install only after reading a passing result. A pipe reports the filter's exit status rather than the suite's, so a red suite looks green and broken code gets committed or installed.

**Fix > Mention: fix stale or broken things in the same pass.** When you find something broken or stale, such as a doc line, a double binding, an outdated install or leftover processes, fix or clean it in the same turn and report it as done instead of offering it as a suggestion, since a diagnosis left as a suggestion makes Dave ask a second time for the fix. Still ask first about destructive changes and real scope changes, and check that nothing live uses a leftover before you remove it.

**Check a claim against its source before it goes in a letter.** Before a citation, deadline, technical claim or cause goes into a letter or memory, check it against the primary source or the full thread, even when Dave or another agent supplied it. If it is not proven, say so, because a wrong claim in a signed letter goes out in Dave's name and travels on.

**Isolate test runs from Dave's live apps and other agents.** Other agents and Dave's running apps share this machine. Test against copies (a copied hobnob.db, private TMPDIR, scratch ports), kill only by a PID you recorded, and refuse to clean an empty or unchecked path. A pattern kill stops other agents' processes, a scratch server on live data acts as Dave, and an unset path can resolve to the current directory and delete a working tree.

**Commands for Dave are self-contained and say what good looks like.** When Dave has to run commands himself, give the complete block again in the current message, with no dependence on an earlier window, printing only what he needs to read and stating the expected good output for each step. Otherwise he scrolls back, pastes extra output and asks which step comes next.

**Run an independent hostile verifier pass on every change.** After each server or app change, have an independent verifier read it adversarially before shipping, and if the verifier subagent is unavailable, do the hostile read yourself. Green tests miss bugs that a hostile read finds; in Atlas such a read found a real bug on almost every pass.

**Keep the phone app and the website at parity.** Where an app has both a website and an iPhone app, as Atlas does, whatever one can do the other should do too. When you add an action or a guard on one surface, carry it to the other and make it look the same on every device, because a surface left behind lacks features or safeguards Dave expects to find there.

**Show times in friendly relative words.** Show times as relative, natural phrases: today, tonight or tomorrow 'at' a time, full weekday names, and 'in X hours' or 'in Y minutes', not bare timestamps or abbreviations. That way Dave can see at a glance how far off something is without working it out from a timestamp.

**Compare old and new as the same page, side by side, with data.** A legacy-vs-new comparison, such as the JSE rebuild, shows one page per section, old left and new right, at one phone and one desktop width, captioned with each site's page name, and with realistic data seeded on every page. Dave judges the new site against the old one, and extra widths, empty pages or mismatched pages leave him nothing he can compare.

**Performance work reports before/after numbers against the old build.** For any performance claim, measure the original build and the new build with the same fixtures and timing boundaries, and show the comparison, including any results that got worse. Timings for the new build alone do not show Dave whether anything got faster.

Ask `folklore ask <topic>` for the rule behind any of these, and `folklore show F-NNN` for where it came from.

<!-- END FOLKLORE -->
