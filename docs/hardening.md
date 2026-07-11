# Security Hardening Plan

Ready-to-implement hardening for making AskMail worthy of the trust it asks for:
**Full Disk Access (read-only), Keychain access, and a derived on-disk copy of
the Inbox/Sent mailbox.** That combination makes AskMail a high-value target —
if the process is subverted, the attacker inherits the mailbox *and* a process
that already holds the grants to read everything.

Framing (the "Wardle lens"): assume the machine is contested, take the least
privilege that works, **prove what you are** (signing + hardened runtime), and
**contain what you can't trust** (untrusted file parsing). Today the app's logic
is security-conscious but it is *packaged like a hobby binary while asking for
production-grade trust* — ad-hoc/self-signed, no hardened runtime, no
entitlements, no notarization. Everything below closes that gap.

Companion docs: [SECURITY.md](../SECURITY.md) (threat model),
[dev-signing.md](dev-signing.md) (why the FDA grant is signature-bound),
[definition-of-done.md](definition-of-done.md) (DoD style this file follows).

Each item has **one unambiguous, verifiable DoD**. An item is done only when its
check passes. Verification commands are collected in the
[Verification playbook](#verification-playbook) at the bottom.

## Implementation status

| Item | Status |
|---|---|
| H-1 Hardened runtime | ✅ Implemented. `codesign -dv` on `.build/AskMail.app` shows `flags=0x10000(runtime)`. Developer-ID signing + secure timestamp work when `ASKMAIL_SIGN_IDENTITY` is set (Packaging/build-app.sh) but weren't exercised here — no real Developer ID credentials in this environment. |
| H-2 Minimal entitlements | ✅ Implemented. [Packaging/AskMail.entitlements](../Packaging/AskMail.entitlements) — verified: only `get-task-allow=false`. |
| H-3 Notarize + staple | ⛔ Scaffolded only. [Packaging/notarize.sh](../Packaging/notarize.sh) is written and refuses non-Developer-ID input, but submitting to Apple's notary service needs the user's own paid Apple Developer Program membership + `notarytool` credentials — cannot be run without them. |
| H-4 No `--deep`, inside-out signing | ✅ Implemented. Packaging/build-app.sh signs the XPC service, then the app; `--deep` is gone. |
| H-5 Fix dev-signing key ACL | ✅ Implemented. Packaging/setup-signing.sh uses `-T /usr/bin/codesign` (not `-A`) and a random per-run passphrase. |
| H-6 XPC parser isolation | ✅ Implemented and end-to-end verified (see below) — new `Sources/AskMailParserXPC` target, sandboxed, embedded and inside-out signed. |
| H-7 Size caps before read/decode | ✅ Implemented. `Defaults.maxEmlxBytes` checked via `FileManager` attributes before `Data(contentsOf:)`; attachment cap enforced on the *encoded* size (`Mime.Part.maxDecodedByteEstimate`) before decode, with the old post-decode check kept as defense in depth. Tests in ParserHardeningTests. |
| H-8 MIME recursion depth limit | ✅ Implemented. `Defaults.maxMimeDepth` (32) threaded through `EmlxParser.collectContent`; exceeding it fails the parse closed. |
| H-9 Bounded regex passes | ✅ Implemented. `Defaults.maxHtmlBytes` (2 MB, UTF-8-boundary-safe truncation) before any pass; all `HtmlText` regexes precompiled; two real catastrophic-backtracking shapes found empirically and fixed (see HtmlText.swift's pattern notes). |
| H-10 Egress allowlist | ✅ Implemented. [EgressPolicy.swift](../Sources/AskMailCore/EgressPolicy.swift) — loopback + `ollama.com` + `api.mistral.ai`, checked before any bytes on every URLSession call in Providers.swift/OllamaControl.swift; `OllamaEmbedder` is loopback-only structurally. |
| H-11 Egress transparency | ✅ Implemented. `EgressLog` records at request *initiation* (survives a local race win); `ChatEvent.egress` drives a live indicator in the ask panel; Settings shows the session's auditable "what left, when, to whom" table. |
| H-13 Redact provider error bodies | ✅ Implemented. `ProviderError.description` caps `.http` bodies at 300 chars, single-line; the raw body stays in the associated value for programmatic use only. |
| H-14 Answer-link scheme allowlist | ✅ Implemented. [LinkPolicy.swift](../Sources/AskMailCore/LinkPolicy.swift) + wiring in AskView.swift; 8 unit tests. |
| H-15 Context/instruction separation | ✅ Implemented. `PromptAssembler.renderChunk` wraps each chunk in `BEGIN EMAIL [N]` / `END EMAIL [N]`; `Defaults.defaultSystemPrompt` rule 2 declares wrapped content data-not-instructions; contract §3 updated in lockstep. |
| H-16 Keychain device-bound + data-protection | ✅ Implemented with graceful fallback. Data-protection keychain (`WhenUnlockedThisDeviceOnly`) attempted first; `errSecMissingEntitlement` (dev-signed builds) falls back to the legacy keychain transparently, with verified-readback migration when DP becomes available. |
| H-18 Lock down the mailbox-mirror DB | ✅ Implemented (predates this pass). `FileHardening.lockDown` on both `askmail.db` and `drafts.db` at every open: 0600/0700, Time Machine + Spotlight excluded. An existing DB created by an older build self-heals on next open. |
| H-20 Verify the Ollama binary | ✅ Implemented. [BinarySignature.swift](../Sources/AskMailCore/BinarySignature.swift) (`anchor apple` or Developer ID) gates `OllamaEngine.startOllama()`; refusal is actionable and unit-tested. |
| H-23 Default log level | ✅ Implemented. `SettingsStore`/`RollingLog` both default to `.info`; the one `.info`-level line with user text is now capped at 200 chars. |
| H-24 Draft-Modus DB lockdown | ✅ Implemented. `drafts.db` gets the identical `FileHardening.lockDown` treatment as `askmail.db` at every open — see [Draft-Modus hardening posture](#draft-modus-dm-hardening-posture). |
| H-25 Draft-Modus stays local-only on every path | ✅ Implemented. Scheduled ticks, on-demand Services "Regenerate", and style learning all construct their `ChatProvider`/`EmbeddingProvider` from `Defaults.ollamaLocalHost` directly — never the user's configured (possibly cloud) Q&A provider. |
| H-26 Services-menu surface adds no new grant | ✅ Implemented. Phase 4's `DraftServiceProvider` is a standard, unprivileged `NSServices` provider reading/writing only local SQLite state; no FDA/Automation/Accessibility prompt at any point. |
| H-12, H-17, H-19, H-21, H-22 | Open. TLS pinning (H-12), code-signature Keychain ACL (H-17), FDA onboarding copy (H-19), CI-enforced scans (H-21), provenance doc (H-22). |

**H-6 in detail:** `Sources/AskMailParserXPC` is a new sandboxed executable
target (`com.apple.security.app-sandbox=true`, no other entitlement) that
does `EmlxParser.parse` + `PdfText.extract` (the PDFKit call) on raw bytes
handed to it and returns `IngestableEmail` (PDF text already extracted, never
raw PDF bytes) as JSON. `Ingestor` takes an injected `EmailParsing`:
`InProcessEmailParser` (default, used by tests — synthetic fixtures don't
need the isolation) or `XPCEmailParser` (production, wired in
`Vectorizer.swift`). `Packaging/build-app.sh` embeds the built service at
`Contents/XPCServices/com.askmail.app.parser.xpc` and signs it before the
outer app (H-4).

Verified for real, not just compiled: built the actual signed `.app`,
embedded the real signed `.xpc` in a throwaway host bundle, and drove a live
`NSXPCConnection` round-trip against the `msg-0003-pdf.emlx` fixture — the
sandboxed child correctly parsed the MIME/base64 PDF attachment and returned
`INV-2026-0473` / `1,340.00 EUR`, matching `Tests/Fixtures/README.md`'s
documented expectation, with `codesign --verify --strict --deep` passing on
the whole bundle. `swift test` (187 tests) passes unchanged. One correction
to this plan's original H-6 DoD: the isolation guarantee is which *process*
calls `PDFDocument`/PDFKit at runtime (`AskMailParserXPC`, never
`AskMailApp`), not which *module* imports PDFKit — `AskMailCore` still
contains `PdfText.swift`, imported by both the XPC service and (for tests)
the in-process path; that's expected, since both need the same parsing code,
they just run it in different processes.

---

## Delta vs `main` (baselined @ `d2c045c`)

This plan was first drafted at `75b8109`. `main` has since advanced 10 commits
(date-scoped queries, a provider race, a resizable panel, opt-in accessibility
incl. on-device speech). **None of them added any hardening item below — the
plan's substance is intact.** The review of that diff changed only these:

- **No new attack surface from dependencies:** `Package.swift` adds only a test
  target (`AskMailAppTests`) — the zero-third-party-dependency posture holds.
- **Injection guard still holds:** `DateFilter` (+524 lines) builds **no SQL** —
  it's pure date parsing — and the new `SQLiteStore.chunks(dateRange:limit:)` is
  fully parameterized. Both fold under the existing SQL regression guard.
- **H-11 gains a nuance:** the provider *race* (`Defaults.providerRaceTimeout`,
  the router in `Providers.swift`) sends mail content to the cloud when cloud is
  primary **even if a local answer ultimately wins the race and is displayed** —
  egress transparency must fire at request time, not at answer-source time.
- **H-14 widens:** citation links are now also opened programmatically via
  `NSWorkspace.open` for keyboard reach ([AskView.swift:98](../Sources/AskMailApp/AskView.swift)),
  and the answer is additionally consumed by on-device speech — so the "treat the
  answer body as untrusted" rule now has three sinks (render, open, speak).
- **New H-23:** `QueryService` now explicitly logs the full assembled prompt
  (retrieved mail text) and answer — correctly `.debug`-gated, but `logLevel`
  still defaults to `.debug`, so the default log holds mail excerpts.

Line numbers below are approximate against `main`; prefer the named symbol.

---

## Don't regress these (already correct)

These are Wardle-approved choices already in the code. Treat them as **regression
guards** — any change below must keep them true.

| Guard | Where | Invariant to protect |
|---|---|---|
| Envelope index opened `SQLITE_OPEN_READONLY` | [EnvelopeIndex.swift:26](../Sources/AskMailCore/EnvelopeIndex.swift) | Never write to / near `~/Library/Mail`; no WAL/shm created there. |
| Global hotkey via Carbon `RegisterEventHotKey` | [HotkeyManager.swift:40](../Sources/AskMailApp/HotkeyManager.swift) | No `CGEventTap`, no Accessibility grant — no keystroke-interception surface. |
| Persistence via `SMAppService` login item | [LoginItem.swift](../Sources/AskMailApp/LoginItem.swift) | Persistence stays transparent + user-visible in System Settings. |
| HTML→text is hand-rolled, no WebKit | [HtmlText.swift:4](../Sources/AskMailCore/HtmlText.swift) | Untrusted HTML never hits a JS/rendering engine and can't fetch remote resources. |
| Answer read-aloud is on-device only | [AskView.swift:171](../Sources/AskMailApp/AskView.swift) (`AVSpeechSynthesizer`) | Speech (added on `main`) never routes answer text to a network voice — keep it `AVSpeechSynthesizer`, never a cloud TTS. |
| All SQL parameterized incl. FTS5 MATCH, IN-lists, and the date-range query | [SQLiteStore.swift:176, :258](../Sources/AskMailCore/SQLiteStore.swift) | No string-built SQL from mail/query text, ever (incl. `chunks(dateRange:)` added on `main`). |
| Debug log is memory-only, 12h window | [RollingLog.swift:41](../Sources/AskMailCore/RollingLog.swift) | No silent on-disk log; disk write only on explicit user export. |
| Ingestion allowlisted to Inbox/Sent | [EnvelopeIndex.swift:117](../Sources/AskMailCore/EnvelopeIndex.swift) | Trash/Junk/Archive/Drafts never enter the index. |
| Secrets in Keychain, never in files | [Keychain.swift](../Sources/AskMailCore/Keychain.swift) | No key in code/config/log; repo treated as public. |

**DoD (regression suite):** a test asserts the envelope index handle is
read-only and no target imports `WebKit`. For H-6, the guard is *process*-
level, not import-level: `Ingestor.ingest(email:)` (which runs in the
`AskMailApp` process) never calls `PdfText.extract`/`PDFDocument` — it only
touches an already-extracted `String?` — only `Sources/AskMailParserXPC`'s
process does.

---

## P0 — Identity & runtime integrity

The foundation. An FDA app that isn't hardened can be code-injected, and its TCC
grant then belongs to the attacker.

| ID | Item | DoD |
|---|---|---|
| **H-1** ✅ | Sign release with **Developer ID + Hardened Runtime + secure timestamp**. | `codesign -dv --verbose=4 AskMail.app` reports `flags=0x10000(runtime)` and an `Authority=Developer ID Application: …`; `codesign --verify --strict --deep` exits 0. Hardened runtime confirmed on the built bundle; Developer-ID + timestamp path is implemented ([build-app.sh](../Packaging/build-app.sh), `ASKMAIL_SIGN_IDENTITY`) but untested here — no real Apple Developer credentials in this environment. |
| **H-2** ✅ | Ship a **minimal entitlements file** (no App Sandbox; nothing that weakens injection defenses). | `codesign -d --entitlements :- AskMail.app` shows a near-empty dict with **no** `get-task-allow`, `disable-library-validation`, `disable-executable-page-protection`, `allow-dyld-environment-variables`, or `com.apple.security.app-sandbox`. Confirmed on the built bundle — see [AskMail.entitlements](../Packaging/AskMail.entitlements). |
| **H-3** ⛔ | **Notarize + staple** the distributed bundle. | `spctl -a -vvv -t exec AskMail.app` prints `source=Notarized Developer ID`; `xcrun stapler validate AskMail.app` succeeds offline. Scaffolded in [notarize.sh](../Packaging/notarize.sh) (refuses non-Developer-ID input); cannot be run without the user's own Apple Developer Program membership and `notarytool` credentials. |
| **H-4** ✅ | Replace `codesign --deep` with **inside-out explicit signing** (sign the H-6 XPC helper first, then the app). | No `--deep` remains in [build-app.sh](../Packaging/build-app.sh); nested code (helper) has its own valid signature verified by `codesign --verify --strict --deep`. Confirmed: `--deep` removed, XPC service signed before the app, `--verify --strict --deep` passes. |
| **H-5** ✅ | Fix the dev-signing identity import: **drop `-A`, scope to codesign, random per-run passphrase**. | `grep -nE '(-A\b\|pass:askmaildev)' Packaging/setup-signing.sh` returns nothing; the imported key's ACL permits only `/usr/bin/codesign` (import uses `-T /usr/bin/codesign`); the passphrase is generated at runtime and never echoed. Confirmed — [setup-signing.sh](../Packaging/setup-signing.sh) uses `-T /usr/bin/codesign` and `openssl rand -base64 24`. |

**H-1 reference invocation** (release), replacing the ad-hoc/self-signed path in
[build-app.sh:29-39](../Packaging/build-app.sh):

```sh
codesign --force --timestamp --options runtime \
  --entitlements Packaging/AskMail.entitlements \
  --sign "Developer ID Application: <NAME> (<TEAMID>)" \
  "$APP/Contents/MacOS/askmail"        # sign nested code first (incl. H-6 helper)
codesign --force --timestamp --options runtime \
  --entitlements Packaging/AskMail.entitlements \
  --sign "Developer ID Application: <NAME> (<TEAMID>)" "$APP"
```

**H-2 `Packaging/AskMail.entitlements`** — deliberately near-empty. This app is
**not** sandboxed (FDA + scanning `~/Library/Mail` is incompatible with the App
Sandbox — see [ollama-onboarding-spec.md](ollama-onboarding-spec.md)). Keep
library validation ON: spawning `ollama` as a *child process* (H-17) needs no LV
relaxation, since LV only governs dylibs loaded *into* this process.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.get-task-allow</key><false/>
</dict></plist>
```

The self-signed "AskMail Dev Signing" identity stays a **dev-only** convenience
(it keeps the FDA grant stable across rebuilds, per [dev-signing.md](dev-signing.md));
release builds MUST use a real Developer ID. H-5 removes its local-attack footgun.

---

## P1 — Contain hostile input (privilege separation)

Highest-leverage architectural change. Today AskMail parses attacker-supplied
MIME/HTML/**PDF** in the *same process that holds Full Disk Access and the
Keychain items*. PDF text extraction runs through **PDFKit in-process**
([PdfText.swift:13](../Sources/AskMailCore/PdfText.swift)); PDFKit/CoreGraphics
have a long history of memory-corruption bugs. The kill chain is short:

> Malformed PDF arrives by email → hourly ingestion parses it in-process →
> parser exploit → **code execution inside a process that can read the whole
> mailbox, the Keychain API keys, and every file on disk.**

| ID | Item | DoD |
|---|---|---|
| **H-6** ✅ | Move all untrusted parsing (`EmlxParser`, `Mime`, `HtmlText`, `PdfText`) into a **sandboxed XPC service** with **no** FDA, network, or Keychain access. Main app sends bytes, gets back plain text. | `codesign -d --entitlements :-` on the helper shows `com.apple.security.app-sandbox=true` and no FDA/network entitlement; the main app process never calls `PDFDocument`/PDFKit at runtime. Confirmed: entitlements verified on the built `.xpc`; live `NSXPCConnection` round-trip against a real PDF fixture returned correctly-extracted text (see status section above). A formal fuzz/crash-containment integration test (kill the helper mid-request, confirm the host survives) is not yet written — `NSXPCConnection`'s invalidation handling is exercised by `XPCEmailParser`'s error paths but not adversarially in an automated test. |
| **H-7** | **Cap size before decode.** Reject the `.emlx` before fully reading it, and enforce the attachment cap *before* base64/quoted-printable expansion, not after. | Ingesting a 200 MB `.emlx` fixture and a base64 "decompression bomb" fixture returns a parse error with **peak process memory bounded** (< a set ceiling in the test), never OOM. |
| **H-8** | Add a **recursion-depth limit** to the MIME multipart walk. | A deeply-nested (`≥256`) `multipart/*` fixture returns a parse error; no stack overflow. |
| **H-9** | Bound the regex passes over attacker HTML/text (input length cap or timeout). | An adversarial HTML fixture (long ambiguous runs) completes `HtmlText.plainText` under a fixed time budget in the test. |

Move the size cap ahead of decode in
[EmlxParser.swift:109-117](../Sources/AskMailCore/EmlxParser.swift) (currently
checks `data.count > Defaults.maxAttachmentBytes` **after** `part.decodedBody`);
add the file-size guard before `Data(contentsOf:)` at
[EmlxParser.swift:21](../Sources/AskMailCore/EmlxParser.swift); add the depth
counter in `collectContent` at
[EmlxParser.swift:81](../Sources/AskMailCore/EmlxParser.swift). After H-6, an
OOM/DoS here is contained in the jailed helper.

---

## P1 — Egress control & data boundary (the LuLu lens)

The data boundary is well-*documented* in [SECURITY.md](../SECURITY.md) but not
*enforced in code*.

| ID | Item | DoD |
|---|---|---|
| **H-10** | Enforce a **compiled-in egress allowlist** (`localhost`, `api.mistral.ai`, `ollama.com`); reject any other host at the transport layer. | A unit test asserts a request to a non-allowlisted host is refused before any bytes are sent; the allowlist is the single source of truth for every `URLSession` call in [Providers.swift](../Sources/AskMailCore/Providers.swift) / [OllamaControl.swift](../Sources/AskMailCore/OllamaControl.swift). |
| **H-11** | Add **egress transparency**: an in-the-moment signal (and/or one-time consent) when a question + retrieved mail content is about to leave the device to a cloud provider, plus an auditable "what left, when, to whom" view. **Fire it when the cloud request is *initiated*, not when the answer is chosen** — the provider race ([Providers.swift](../Sources/AskMailCore/Providers.swift) router, `Defaults.providerRaceTimeout`) can send content to the cloud yet still display a local answer. | Selecting a cloud provider and asking a question surfaces a visible indicator the instant content leaves the device; a query where local *wins* the race still records the cloud send in the egress log (content already left). |
| **H-12** | **TLS pinning** for the two cloud hosts via a `URLSessionDelegate` (optional but recommended). | A test with a mismatched leaf cert fails the connection to `api.mistral.ai` / Ollama Cloud. |
| **H-13** | **Truncate/redact provider error bodies before logging** (cloud 4xx often echoes the submitted prompt → mail content). | Provider error lines in the log are capped to N chars and stripped of echoed prompt content; verified by a test feeding an error body containing a known context string. |

Belt-and-suspenders: embeddings are local-only today
([Providers.swift:184](../Sources/AskMailCore/Providers.swift)) — the H-10
allowlist structurally prevents a future edit from sending them out.

---

## P1 — LLM-specific: indirect prompt injection

A live chain exists: untrusted email text is concatenated into the prompt with
no data/instruction separation
([PromptAssembler.swift:74](../Sources/AskMailCore/PromptAssembler.swift)), and
the model's answer is rendered as **clickable Markdown**
([AskView.swift:21](../Sources/AskMailApp/AskView.swift)). So a malicious email
in the Inbox can induce a clickable, attacker-chosen link in the trusted panel.

| ID | Item | DoD |
|---|---|---|
| **H-14** ✅ | **URL-scheme allowlist on every answer-link sink.** Only `message:` opens directly; `https:` requires an explicit confirm; everything else is rendered inert. Applies to the rendered Markdown link *and* the programmatic `NSWorkspace.shared.open` path added on `main` for keyboard-reachable links ([AskView.swift:98](../Sources/AskMailApp/AskView.swift)). | An answer containing `[x](javascript:…)`, `[x](file:…)`, and `[x](https://evil.tld)` renders the first two inert and gates the third behind confirmation — via **both** mouse-click and the keyboard/VoiceOver open path; a `message://` citation still opens Mail. Confirmed: [LinkPolicy.swift](../Sources/AskMailCore/LinkPolicy.swift) gates a single `.environment(\.openURL, ...)` in AskView.swift that both sinks route through; 8 unit tests cover every scheme class. |
| **H-15** | **Context/instruction separation** in the prompt: clearly delimit retrieved content as data, and add a system-prompt instruction that context is reference material, not commands. | The assembled prompt wraps each chunk in an unambiguous data delimiter; the default system prompt in [Defaults.swift](../Sources/AskMailCore/Defaults.swift) states context is not to be treated as instructions. |

The citation renderer itself is safe — it emits only `message://` links from a
controlled source map, percent-encoded
([CitationRenderer.swift:95](../Sources/AskMailCore/CitationRenderer.swift)). The
risk is exclusively the free-form **answer body**, so H-14 targets
`answerMarkdown` ([AskView.swift:22](../Sources/AskMailApp/AskView.swift)) and
its link handling. Note `main` broadened how the answer is consumed — it is now
rendered, **opened programmatically** (`NSWorkspace.shared.open`, AskView.swift:98),
and **spoken** (`AVSpeechSynthesizer`, AskView.swift:171). Speech is benign
(on-device, no link-following), but the shared lesson is that the model's output
is untrusted at every sink; sanitize it once, centrally, before it fans out.

---

## P2 — Least privilege, secrets & data-at-rest

| ID | Item | DoD |
|---|---|---|
| **H-16** | Keychain items **device-bound + data-protection keychain**. | Items are created with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and `kSecUseDataProtectionKeychain=true` at [Keychain.swift:75](../Sources/AskMailCore/Keychain.swift); a re-read after a simulated iCloud sync shows the item did not migrate. |
| **H-17** | Bind the key to this app with a **`SecAccessControl` / code-signature ACL**. | A differently-signed test binary running as the same user **cannot** read the API key; the real app can. |
| **H-18** | Lock down the **cleartext mailbox-mirror DB** at [`~/Library/Application Support/askmail.db`](../Sources/AskMailApp/SettingsStore.swift). | `ls -le` shows `0600` on `askmail.db` (+ `-wal`/`-shm`) and `0700` on its dir; the file has `isExcludedFromBackup=true` and is Spotlight-excluded. (Stretch: opt-in encryption at rest so the derived copy is no weaker than Mail's store.) |
| **H-19** | **FDA onboarding transparency**: state plainly that access is read-only and scoped to Mail only. | The FDA request/onboarding copy names the exact read scope (`~/Library/Mail`, envelope index, `~/Library/Accounts/Accounts4.sqlite`) and "read-only"; verified in [OnboardingChecklist.swift](../Sources/AskMailCore/OnboardingChecklist.swift) / settings copy. |

Note the read scope is genuinely narrow — three well-known subtrees — but all
are TCC-protected, so FDA remains unavoidable. H-19 turns that narrowness into
stated, auditable scope rather than an open-ended grant.

---

## P2 — Process-launch integrity

`startOllama()` execs an `ollama` binary from `/opt/homebrew/bin` or
`/usr/local/bin` with **no signature check**
([OllamaEngine.swift:63-73](../Sources/AskMailApp/OllamaEngine.swift); paths at
[OllamaControl.swift:312-318](../Sources/AskMailCore/OllamaControl.swift)).
`/usr/local/bin` is admin-writable without root on many Macs → a planted binary
runs when the user clicks "Start Ollama."

| ID | Item | DoD |
|---|---|---|
| **H-20** | **Verify the Ollama binary** (`SecStaticCodeCheckValidity` against a Developer-ID/notarized requirement) before `process.run()`, or launch only the Gatekeeper-vetted `/Applications/Ollama.app` and refuse the raw-CLI fallback. | Pointing `cliURL` at an unsigned/ad-hoc binary makes `startOllama()` refuse to spawn and surface an actionable error; the signed CLI/app launches normally. Unit test with a fake binary. |

---

## P2 — Supply chain & build hygiene

| ID | Item | DoD |
|---|---|---|
| **H-21** | **Enforce the pre-commit scans in CI** and **pin** the hook revs. | CI fails if Gitleaks/Socket did not run and pass; no `# verify latest`/floating revs remain in [.pre-commit-config.yaml](../.pre-commit-config.yaml). |
| **H-22** | **Document model/daemon provenance.** The app pulls models via the local daemon and does not independently verify digests. | [SECURITY.md](../SECURITY.md) states the model/daemon trust boundary (integrity relies on Ollama's registry + the H-20 binary check); pulls happen only on explicit user action ([OllamaEngine.swift:99](../Sources/AskMailApp/OllamaEngine.swift), already true). |

Keep the existing strength: **zero third-party SwiftPM dependencies** (system
frameworks + `libsqlite3` only — [Package.swift](../Package.swift)). Treat
"adding any dependency" as a signing/review event.

---

## P2 — Logging hygiene (data minimization)

`main` made query logging explicit: `QueryService` now logs the full assembled
`prompt.system` + `prompt.user` (which contains the retrieved **email chunk
text**) and the full `llm answer`, plus per-dropped-chunk `subject`/`sender`/
`date`. These are correctly gated at `.debug`
([QueryService.swift:112-115, :139](../Sources/AskMailCore/QueryService.swift)) —
but `logLevel` **defaults to `.debug`**
([SettingsStore.swift:111](../Sources/AskMailApp/SettingsStore.swift)), so the
default in-memory log holds mail excerpts and answers.

| ID | Item | DoD |
|---|---|---|
| **H-23** ✅ | **Default `logLevel` to `.info`** so mail-excerpt-bearing lines are only captured when the user deliberately raises verbosity; keep the content-bearing lines `.debug`-gated (already true); consider truncating the raw question logged at `.info` ([QueryService.swift:86](../Sources/AskMailCore/QueryService.swift)). | Default `SettingsStore.logLevel == .info`; a test asserts an `.info` export contains no `prompt.user` / `llm answer` / chunk-`text` lines; the "Copy logs" content warning ([SettingsView.swift](../Sources/AskMailApp/SettingsView.swift)) stays. Pairs with H-13 (redact provider error bodies, still open). Confirmed: both `SettingsStore` and `RollingLog`'s own default now read `.info`; the empty-retrieval `.info` line caps the question at 200 chars (`QueryService.capped`); test in `QueryFlowTests.swift`. |

---

## Draft-Modus (DM) hardening posture

Draft-Modus (`docs/draft-modus-plan.md`) is opt-in and off by default
(`SettingsStore.draftModeEnabled`). These items are its own hardening
surface, called out separately from the P0–P2 items above since they're
feature-specific safety properties rather than app-wide ones — same rigor,
same one-unambiguous-DoD-per-item style.

| ID | Item | DoD |
|---|---|---|
| **H-24** ✅ | `drafts.db` gets the same lockdown as `askmail.db` — no weaker just because it's the newer, opt-in database. | `FileHardening.lockDown` is called at every `DraftStore.init` ([DraftStore.swift:127](../Sources/AskMailCore/DraftStore.swift)), identically to `SQLiteStore`: `ls -le` on `drafts.db` (+ `-wal`/`-shm`) shows `0600`, the containing directory `0700`, Time Machine + Spotlight excluded. |
| **H-25** ✅ | Every Draft-Modus generation path is local-only, regardless of the user's configured Q&A provider (H-11's egress-transparency posture would otherwise be silently bypassed for unattended background work). | Grep confirms: `DraftEngine.runTick` ([DraftEngine.swift](../Sources/AskMailApp/DraftEngine.swift)) and `DraftServiceProvider.regenerateDraft` ([DraftServiceProvider.swift](../Sources/AskMailApp/DraftServiceProvider.swift)) both construct `OllamaClient(host: Defaults.ollamaLocalHost, …)` directly — neither reads `SettingsStore.provider`. `StyleLearner`'s merge call takes the same locally-constructed provider as an explicit parameter, never resolves its own. |
| **H-26** ✅ | Phase 4's macOS Services-menu integration (`DraftServiceProvider`) adds no new OS permission and touches no new attack surface — a standard, unprivileged `NSServices` provider, reading/writing only `drafts.db`/`askmail.db` (already-granted FDA-derived local state) via the pasteboard AppKit already hands it. | `Packaging/AskMail.entitlements` is unchanged by Phase 4 (still the near-empty H-2 file); registration produces **no** FDA/Automation/Accessibility prompt at any point — confirmed live against Mail.app with a diagnostic provider using the identical `NSServices` mechanism (see the spike detail below). The real `insertDraft`/`regenerateDraft` methods are unit-tested (`DraftServiceMatcherTests`, `DraftJobProcessorTests`) but their live end-to-end behavior against a real Mail.app draft is a pending manual verification step — see the Draft-Modus verification playbook below. |
| **H-27** ⛔ | Phase 5's global-hotkey Mail Automation grant (AskMail's first-ever Automation grant) — scope and Accessibility decision, once it ships. | Not yet applicable: Phase 5 remains a stub in `docs/draft-modus-plan.md` pending its own live-Mac spikes (`sdef`, and whether insertion requires an Accessibility grant). This item gets a real DoD when that phase lands; the existing regression guard (`HotkeyManager.swift:40` — "no `CGEventTap`, no Accessibility grant") must stay true regardless of how Phase 5 resolves. |

**Identification mechanism (H-26 detail):** a live-Mac spike (`docs/draft-modus-plan.md`
Phase 4) established that a Mail.app Services invocation hands the provider
only the user's current selection (text/RTF) — never a message id or any
AppleScript-level identifier. `DraftServiceMatcher` ([DraftServiceMatcher.swift](../Sources/AskMailCore/DraftServiceMatcher.swift))
extracts the correspondent's address from Mail's standard quoted-reply
header and matches it against `drafts.db`'s `ready` rows, disambiguating
same-sender/multiple-thread cases via body overlap against `askmail.db`.
No data is sent anywhere; both stores are already-local, already-hardened
(H-18/H-24) SQLite files.

---

## Suggested implementation order

1. ~~**H-1 → H-5** (P0 signing/runtime)~~ ✅ Done — see Implementation status.
2. ~~**H-14** (answer-link scheme filter)~~ ✅ Done.
3. ~~**H-6** (XPC parser isolation)~~ ✅ Done. **H-7 → H-9** (input caps: size-before-decode,
   recursion depth, regex time bound) are the natural next slice — same file
   (`EmlxParser.swift`), same process (now the sandboxed one), still open.
4. **H-10 → H-13** (egress allowlist + transparency + error-body redaction) —
   next highest-value slice; ~~H-23~~ ✅ done.
5. **H-16 → H-22** (secrets, at-rest, launch integrity, supply chain) — open.

---

## Verification playbook

How to confirm the hardening on a built artifact (the checks the DoDs reference).
This is also the "how would you verify it" pass an external reviewer would run.

```sh
# Identity, hardened runtime, entitlements (H-1, H-2, H-4)
codesign -dv --verbose=4 AskMail.app          # expect flags=0x10000(runtime), Developer ID authority
codesign --verify --strict --deep AskMail.app # exit 0
codesign -d --entitlements :- AskMail.app     # near-empty; no get-task-allow / no disable-library-validation / no app-sandbox

# Notarization (H-3)
spctl -a -vvv -t exec AskMail.app             # expect: accepted, source=Notarized Developer ID
xcrun stapler validate AskMail.app            # ticket stapled, validates offline

# Dev-signing footgun removed (H-5)
grep -nE '(-A\b|pass:askmaildev)' Packaging/setup-signing.sh   # expect no matches

# Injection defenses (macho / dylib) (H-2)
otool -l AskMail.app/Contents/MacOS/askmail | grep -A4 LC_CODE_SIGNATURE

# Parser isolation (H-6)
codesign -d --entitlements :- AskMail.app/Contents/XPCServices/com.askmail.app.parser.xpc
# app-sandbox=true, get-task-allow=false, no FDA/network entitlement

# Data-at-rest (H-18)
ls -le "$HOME/Library/Application Support/askmail.db"   # expect 0600
xattr -p com.apple.metadata:com_apple_backup_excludeItem "$HOME/Library/Application Support/askmail.db"

# Egress (H-10/H-11) — with a cloud provider selected, capture and confirm only
# allowlisted hosts + top-k chunks leave, never the whole DB; confirm the send
# is recorded even when the provider race ends up showing a local answer.

# Log data-minimization (H-23) — default level is .info; an .info export holds
# no prompt.user / llm answer / chunk-text lines.

# Draft-Modus data-at-rest (H-24)
ls -le "$HOME/Library/Application Support/AskMail/drafts.db"   # expect 0600

# Draft-Modus local-only (H-25)
grep -n "OllamaClient(host: Defaults.ollamaLocalHost" \
  Sources/AskMailApp/DraftEngine.swift Sources/AskMailApp/DraftServiceProvider.swift
# both must match; neither file should read settings.provider before constructing a chat provider

# Draft-Modus Services menu (H-26) — with a drafted, ready thread open in Mail:
# select the quoted reply text, Mail ▸ Services shows "AskMail: Insert Draft" /
# "AskMail: Regenerate Draft"; invoking either produces no FDA/Automation/
# Accessibility prompt (System Settings ▸ Privacy & Security shows no new grant).
```

**Draft-Modus full verification playbook** (Phase 6 DoD, exercising every
surface together, same spirit as the playbook above):
1. Settings ▸ Draft-Modus: toggle on, confirm the status line ("Queued ·
   Drafted · Skipped[, Failed]") updates after a tick with no restart needed.
2. Add a sender/domain to "Never draft for", confirm a subsequent message
   from that sender lands in `newsletterSkipped` (Settings' "Skipped" count
   increments; regression test: `testClassifyPendingJobsSkipsExcludedSenderWithoutInvokingLLMFallback`).
3. Wait for a real draft; open it from the menu bar's "Drafts" window
   (Copy / Open thread in Mail / Discard all still read-only, per
   `docs/draft-contract.md`).
4. In Mail, open the same thread's reply, select the quoted text, invoke
   "AskMail: Insert Draft" — the selection is replaced with the exact
   `draft_text`; invoke "AskMail: Regenerate Draft" — the stored draft is
   replaced and a subsequent "Insert" reflects the new text.
5. Settings ▸ "Draft-Modus: learned style": after enough real Sent replies
   have been learned from, confirm per-scope "learned from N replies"
   rows appear; "Reset learned style…" empties them (regression test:
   `testDeleteStyleProfilesWithNilScopeDeletesEverything`) and a subsequent
   draft carries no style guidance until new samples accumulate.

External-tool equivalents (Objective-See): **What's Your Sign?** for the
signature/entitlements, **KnockKnock** to confirm the login item is the only
persistence, a **LuLu**-style capture for egress, and a fuzz corpus of malformed
`.emlx`/PDF for the H-6/H-7 parser containment.
