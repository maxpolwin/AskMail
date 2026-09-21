# Security Baseline Review (2026-09-21)

One-off, full-codebase baseline at commit `0887fdb`. Read-only review; no
code was changed. Companion to [SECURITY.md](../SECURITY.md) and
[hardening.md](hardening.md): this document records what the H-numbered
posture actually delivers today, where the code and the claims diverge, and
what the next hardening pass should take up. Line numbers refer to `0887fdb`.

Method: every `URLSession`, `sqlite3_*`, `Process`, `NSWorkspace.open`,
`NSPasteboard` and XPC call site was enumerated and read; every regex in
`HtmlText`/`MailHeader` was inspected for backtracking shapes; the packaging
scripts, entitlements, `Info.plist`, CI workflow and pre-commit config were
read in full. Each finding below was re-verified against the source before
being recorded.

Severity scale: **High** = reachable by an unauthenticated remote sender or
by an unprivileged local process and affects the data boundary or code
execution; **Medium** = needs a precondition (admin-writable path, user
click, Draft-Modus on) or is a bounded resource/integrity issue;
**Low** = defense-in-depth gap or doc/code drift with no direct exploit.

## Summary

| Severity | Count | Themes |
|---|---|---|
| Critical | 0 | |
| High | 2 | Ollama launch trust (H-20 only half-implemented); spoofable `Message-ID` overwrites indexed mail |
| Medium | 14 | Redirect escape of the egress allowlist; prompt-injection blast radius in Draft-Modus; Services IPC surface; host-side resource bounds; Envelope Index locking; CI/signing hygiene |
| Low | 15 | Scheme/redaction/key-presence checks; file-hardening races; pinning; log content |

The core claims hold: **every outbound request is fronted by the compiled-in
egress allowlist, embeddings are structurally loopback-only, the XPC parser
receives bytes (not paths) under an App Sandbox with no other entitlement,
there is no in-process parsing fallback, no SQL injection exists (every
mail-derived value is bound), no AppleScript/shell/URL-scheme sink exists for
model output, and API keys never reach UserDefaults, logs or error text.**
The gaps are at the edges of those boundaries, listed below.

## High

### S-1. Ollama launch trust: `/Applications/Ollama.app` is launched unchecked, automatically; the CLI requirement accepts any Developer ID
`Sources/AskMailApp/OllamaEngine.swift:74-77` (app branch, no check),
`:83-100` (CLI branch), `Sources/AskMailCore/BinarySignature.swift:16-17`,
`Sources/AskMailCore/OllamaControl.swift:312-326`.

`startOllama()` tries `/Applications/Ollama.app` first and opens it with
`NSWorkspace.openApplication` with no signature check. `NSWorkspace` does
not run a Gatekeeper assessment on a non-quarantined bundle already on disk,
and `/Applications` is admin-group-writable on a default Mac. The call is
unattended: `ensureRunning()` fires at every app launch
(`AppDelegate.swift:67`), before every Draft-Modus tick
(`DraftEngine.swift:91`) and from the Services path
(`DraftServiceProvider.swift:143`). A planted bundle therefore runs without
a click and then serves `/api/embed` and `/api/chat` for the whole mailbox.

The CLI branch is gated, but the requirement
`anchor apple or (anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13])`
passes for any Apple-shipped binary (the unit test asserts `/bin/ls` passes,
`Tests/AskMailAppTests/OllamaEngineLaunchTests.swift:33`) and for any of the
Developer ID certificates in circulation. Additional weaknesses on the same
path: the check and `Process.run()` both resolve the path separately
(TOCTOU, symlink not resolved), and `process.environment` is never set, so
`OLLAMA_HOST=0.0.0.0` or `OLLAMA_ORIGINS` in the launchd environment make
the auto-started daemon LAN-reachable with no warning.

Fix: run the check on both branches; pin the requirement to Ollama's Team
ID (`certificate leaf[subject.OU] = "<TEAMID>"`) and drop the bare
`anchor apple` alternative; resolve `realpath` and refuse symlinks before
checking; set a minimal `process.environment` with
`OLLAMA_HOST=127.0.0.1:11434`. Downgrade H-20 in hardening.md to partial
until done.

### S-2. Spoofable `Message-ID` lets any inbound mail overwrite the indexed copy of an existing message
`Sources/AskMailCore/SQLiteStore.swift:225-250`, `EmlxParser.swift:95-98`.

`messages.message_id` is `UNIQUE` and `upsertMessage` does
`ON CONFLICT(message_id) DO UPDATE SET subject, sender, thread_id,
body_text, ...`, then `replaceChunks` re-chunks under the same `pk`. The
`Message-ID` header is attacker-chosen; target IDs are visible in
`References`/`In-Reply-To` of any thread the attacker was on. A crafted mail
silently replaces the stored body, sender and thread membership of a real
email, so later answers and citations present attacker text as the genuine
message, and the Services "Insert" thread resolution can be redirected.

Fix: key on `(account, source_id)` or refuse the update when the existing
row's account/source differs; log the collision.

## Medium

### S-3. HTTP redirects are followed, escaping the egress allowlist
`Providers.swift:223, 309, 395, 431`, `OllamaControl.swift:100, 109, 121, 144`,
`EgressPolicy.swift:30-44`. All calls use `URLSession.shared` with no
delegate; `EgressPolicy.check` runs once on the original URL and there is no
`willPerformHTTPRedirection`. A 307/308 from an allowlisted host, or from
whatever answers on `127.0.0.1:11434`, re-sends the POST body (question plus
mail excerpts; for `/api/embed` the raw chunk batch) to an unchecked host,
and `EgressLog` records only the original host. Fix: one dedicated
`URLSession` whose task delegate refuses redirects (or re-runs the check).

### S-4. `message:` scheme is trusted unconditionally, but model output can emit it
`LinkPolicy.swift:28-40`, `AskView.swift:524-528`. The comment says only
`CitationRenderer.messageURL` can produce a `message:` URL; the answer body
is rendered as Markdown, so an injected `[text](message://...)` opens with
no confirmation (case-insensitive, per `LinkPolicyTests`). Fix: `.open`
only when the URL matches one the app built for the current source map,
else `.confirmThenOpen`.

### S-5. Display-name spoofing counts an attacker's mail as the user's own Sent reply
`DraftJobProcessor.swift:263-270`, `StyleLearner.swift:129-133`. Both use
`sender.localizedCaseInsensitiveContains(accountEmail)` on the raw header.
`From: "victim@corp.com" <attacker@evil.tld>` trips
`hasPriorSentCorrespondence` (short-circuiting newsletter classification to
`.personal`) and is selected by `StyleLearner` as the real reply. Fix:
compare `MailHeader.address(fromSender:)` for equality.

### S-6. Stored prompt injection: learned style profile enters the draft *system* prompt at global scope
`StyleLearner.swift:145-183`, `DraftAssembler.swift:44-47`. The merge
output (derived from a draft shaped by a hostile mail plus the user's reply,
which quotes it) is persisted verbatim and appended to `system` for every
later draft. One surviving instruction becomes a durable foothold. Fix:
length-cap and validate before persisting; place it in the user block under
a data delimiter, never in the system role.

### S-7. H-15 delimiters are forgeable; the draft prompt has none
`PromptAssembler.swift:81-97`, `DraftAssembler.swift:38-40`. `BEGIN EMAIL
[N]`/`END EMAIL [N]` are not escaped inside chunk text, and the draft
THREAD block (the higher blast-radius path per draft-contract.md) uses only
`--- sender | date ---`. Fix: neutralise the tokens in body text and apply
the same wrapper in `DraftAssembler`.

### S-8. Services verbs are an unauthenticated local IPC surface that returns mail-derived text and bypasses every Draft-Modus gate
`Packaging/Info.plist` (NSServices), `DraftServiceProvider.swift:37-105,
168-177`. Any local process can invoke `insertDraft` via `NSPerformService`
with a crafted "On ..., X <known@corp.com> wrote:" selection and read the
stored draft back from the pasteboard; `regenerateDraft` starts FDA-backed
thread resolution plus an LLM run with no caller validation, and both verbs
intentionally bypass `draftModeEnabled`, sender exclusion and newsletter
gates. `public.rtf` in `NSSendTypes` means arbitrary RTF is parsed by
AppKit inside the FDA-holding process, the class of surface H-6 moved out.
Fix: require `draftModeEnabled` for on-demand generation, confirm the
correspondent before writing to the pasteboard, drop `public.rtf`.

### S-9. Finished answers are auto-copied to the general pasteboard
`AskView.swift:634-637`. On stream end the answer plus source excerpts are
written to `NSPasteboard.general` with no user action; any app can read it.
Fix: make auto-copy opt-in, or exclude excerpts.

### S-10. Symlinked `.emlx` bypasses the H-7 size cap
`XPCEmailParser.swift:44-51`, `EmlxParser.swift:36-48`,
`EnvelopeIndex.swift:148-170`. `attributesOfItem(atPath:)` does not follow
symlinks; `Data(contentsOf:)` does. A symlink named `<rowid>.emlx` reports
its own size, passes the cap, and the full target is read into the FDA
process (unbounded allocation; arbitrary file indexed and later sent to the
LLM). `EmlxLocator` requests `.isRegularFileKey` but never reads it.
Precondition: writing under `~/Library/Mail` already needs FDA, so this is
defense-in-depth. Fix: check `isRegularFile`, size with `open(O_NOFOLLOW)`
+ `fstat`.

### S-11. Envelope Index opened `READONLY` but not immutable: shared locks and possible `-shm` creation next to Mail's live DB
`EnvelopeIndex.swift:24-33`. hardening.md line 110 promises "no WAL/shm
created there". `SQLITE_OPEN_READONLY` on a WAL database still builds the
wal-index and takes shared locks; if `Envelope Index-shm` is absent it is
created by AskMail (FDA grants write). Fix: snapshot to a temp copy and read
that, or open via `file:...?immutable=1` (with the caveat that immutable on
a live DB can return inconsistent reads; the snapshot is safer).

### S-12. Host-side resource bounds: PDF, aggregate body, header decode, `References`
`PdfText.swift:11-17` (no page cap, per-page cap or deadline; a 25 MB
Flate-compressed PDF can expand to GBs in the child and the client's 30 s
budget only abandons the reply), `EmlxParser.swift:116-121` +
`Chunker.swift:19` (no cap on joined `bodyText`; `Array(trimmed)` as
`[Character]` costs ~16 B/grapheme in the host, so a 100 MB plain-text
mail is ~1.6 GB resident), `MailHeader.swift:13-43` (quadratic
`replaceSubrange` loop run on the main actor at `AskView.swift:9-10` over an
uncapped subject that crossed XPC raw), `EmlxParser.swift:105-108` +
`ThreadResolver.swift:38-47` (one SELECT and one insert per `References`
token, uncapped). Fix: `Defaults.maxBodyTextChars`, cap subject/sender at
the XPC boundary, page/char/time caps in `PdfText`, cap `references` at
~100, rewrite `MailHeader.decode` as a single forward pass.

### S-13. Draft path builds an uncapped FTS5 MATCH from the whole inbound body
`DraftJobProcessor.swift:397`, `SQLiteStore.swift:439-458`. `keywordSearch`
ORs every alphanumeric token with no cap or dedup, under `SQLiteStore.lock`,
and a failure re-runs up to 5 attempts. Anyone who can send mail to a
Draft-Modus user can stall the store. Injection is not possible (tokens are
alphanumeric only). Fix: dedup and cap terms (~64), truncate the body first.

### S-14. Unbounded per-connection embedding cache
`SQLiteStore.swift:36-41, 478-489`. `vectorSearch` loads every embedding
into memory for the connection's lifetime; `AskView`, `DraftEngine`,
`Vectorizer` and `DraftServiceProvider` each hold their own connection, so
several copies can be resident. The Ask panel's copy is also never
invalidated by ingestion on other connections (stale vector retrieval until
restart). Fix: share one store or bound/invalidate via `data_version`.

### S-15. CI: no `permissions:` block, floating action tags, unpinned `pipx install pre-commit`, Socket never runs
`.github/workflows/ci.yml:17-45`. `GITHUB_TOKEN` gets the repository
default; `actions/checkout@v4` is a mutable tag; pre-commit is installed at
latest; `SKIP=socket-scan` means the dependency scan runs nowhere
automated. No `pull_request_target`, no secrets, no cache: PR code never
runs with a write token. Fix: `permissions: {contents: read}`, SHA-pin
actions, `pre-commit==<ver>`, run Socket with a repo secret or drop the hook.

### S-16. `setup-signing.sh`: passphrase in argv, cleartext key on disk, key imported extractable
`Packaging/setup-signing.sh:46-58`. `-passout pass:` and `security import
-P` expose the passphrase to `ps` for the call's lifetime; `key.pem` is
written with `-nodes`; no `-x` on import. A local attacker winning that race
obtains the identity that carries the Full Disk Access grant, the attack
H-5 exists to prevent. The ACL (`-T /usr/bin/codesign`) and `mktemp -d` +
EXIT trap are correct. Fix: `-passout env:`, pass `-P` via fd, add `-x`.

## Low

- **S-17** `EgressPolicy.check` does not require `https` for cloud hosts (`EgressPolicy.swift:30-34`). Not exploitable today (all cloud URLs are `https` constants in `Defaults.swift:154-157`), but the allowlist is the stated single source of truth.
- **S-18** H-13 is truncation, not redaction: the first 300 chars of an echoed prompt still reach the log at `.error` and the panel (`Providers.swift:69-96, 693, 741`). Log only status plus a whitelisted error field.
- **S-19** Cloud provider selected with no key still sends the question and excerpts (`Authorization: Bearer ` empty), gets 401, then falls back (`QueryService.swift:238, 245`). `ProviderError.missingAPIKey` exists but is never thrown.
- **S-20** Anything bound to `127.0.0.1:11434` answering 2xx on `/api/version` is trusted as Ollama and receives every chunk (`OllamaControl.swift:93-103`). Inherent to Ollama's API; document it in SECURITY.md and block redirects (S-3).
- **S-21** `FileHardening.lockDown` runs after open, WAL pragma and migration, so the DB and `-wal`/`-shm` exist at umask permissions during first-run schema creation; `chmod` return values are discarded; the "file need not exist yet" comment is wrong (a missing file is a silent no-op); `-wal`/`-shm` recreated mid-session are never re-excluded from backup (`FileHardening.swift:12-33`, `SQLiteStore.swift:44-57`, `DraftStore.swift:117-131`). Create the directory `0700` first, `fchmod` the handle, check return codes.
- **S-22** `notarize.sh:58-59` appends `.zip` to a `mktemp` path, so the zip is written to an unreserved name and the reserved file leaks. Use `mktemp -d`.
- **S-23** `Package.resolved` is gitignored (`.gitignore:12`); harmless with zero dependencies, but contradicts SECURITY.md's "pin exact versions" the moment one is added.
- **S-24** Pre-commit `rev:` values are mutable tags with a "verify latest" comment (`.pre-commit-config.yaml:5, 21`); H-21's DoD asks for SHAs. Note gitleaks/large-files/private-keys do run in CI now, so hardening.md's "H-21 open" is partly stale.
- **S-25** `build-app.sh:48-55` selects the dev identity by common name across the whole keychain search list; `setup-signing.sh` scopes to `login.keychain-db`. Select by SHA-1 or pass `--keychain`.
- **S-26** XPC listener accepts any connection (`AskMailParserXPC/main.swift:26-33`) and the client never pins the service; mitigated by `ServiceType=Application` scoping the lookup to the bundle and by the empty sandbox. Add `setCodeSigningRequirement` on both sides so the posture survives a future entitlement.
- **S-27** `sender LIKE ?` pattern built from the Services selection does not escape `%`/`_` (`SQLiteStore.swift:346-364`); bound, so no injection, only a wider scan.
- **S-28** Newsletter verdict accepted on `contains("personal")` over an undelimited body prefix (`NewsletterClassifier.swift:147-165`). Require an exact one-word match and delimit.
- **S-29** The one `.info`-level line with user text logs the question (200-char cap, `QueryService.swift:89`); "Export logs" at `.debug` dumps full bodies and Message-IDs. Accepted per H-23; warn in the export dialog when level is `.debug`.
- **S-30** `Ingestor.init` defaults `parser` to `InProcessEmailParser()` (`Ingestor.swift:83`). Both production call sites pass `XPCEmailParser()`, so not a live fallback, but a footgun; make the parameter required.
- **S-31** `CitationRenderer.messageURL` leaves `@` unencoded, so a multi-`@` Message-ID controls what URL parsing sees as host (`CitationRenderer.swift:94-105`). Nothing reads `url.host`; cosmetic.

## Doc-vs-code drift to correct in hardening.md

| Row | Claimed | Actual |
|---|---|---|
| H-10 | Every request checked before bytes leave | True, but redirects are not re-checked (S-3) and scheme is not enforced (S-17) |
| H-11 | Signal and/or one-time consent | Signal only; switching to a cloud provider immediately sends the key for the model list and routes the next question with no confirmation |
| H-13 | Error bodies stripped of echoed prompt content, verified by test | Capped at 300 chars; the test asserts the cap only (S-18) |
| H-20 | Gates `startOllama()` | Gates the CLI branch only; requirement accepts any Apple or Developer ID signature (S-1) |
| H-21 | Open | gitleaks, large-files, private-keys run in CI; Socket does not (S-15, S-24) |
| H-26 | Services add no new grant | True, but the verbs are cross-process invocable and bypass Draft-Modus gates (S-8) |
| Invariant, line 110 | No WAL/shm created near `~/Library/Mail` | `SQLITE_OPEN_READONLY` alone does not guarantee this (S-11) |
| EgressPolicy comment | Ollama host is user-configurable in Settings | No such control exists; every call site uses `Defaults.ollamaLocalHost`/`ollamaCloudHost` (good, comment is stale) |

## Verified OK

- Allowlist matching is exact `Set.contains` on the lowercased host: `evil-ollama.com`, `ollama.com.evil`, userinfo tricks, `0.0.0.0`, `127.0.0.2` all blocked; `[::1]` covered and tested.
- `.ollamaLocal` builds `ProviderRouter(primary: local, fallback: nil)`; no cloud object exists. Draft-Modus builds `OllamaClient(host: Defaults.ollamaLocalHost)` on every path (H-25 holds). Egress is recorded at request initiation, so a local race win cannot hide a cloud send.
- Keychain: data-protection keychain with `WhenUnlockedThisDeviceOnly`, never synchronizable; migration is write, verified read-back, then delete-legacy. No key in UserDefaults, logs, `description`s or the egress log. No `print`/`dump`/`NSLog`/`os_log` anywhere in `Sources/`.
- XPC transfers `Data`, never paths; service entitlements are `app-sandbox=true` plus `get-task-allow=false` only; bundle ID `com.askmail.app.parser` matches the `.xpc` name and `ServiceType=Application`; no in-process fallback; reply/continuation handling (`ResumeOnce`, 30 s race, invalidate on interruption) is correct.
- H-7 attachment cap is a genuine pre-decode upper bound for base64, QP and identity; H-8 depth cap is checked on entry; `.emlx` byte-count framing is checked before `subdata` and cannot overflow.
- All regexes in `HtmlText` and `MailHeader` are precompiled with complement-class-bounded, non-nested quantifiers; no catastrophic shapes found.
- No SQL injection: two `sqlite3_exec` and six `sqlite3_prepare_v2` sites; every mail- or user-derived value is bound; the only interpolations are placeholder lists, an `Int` LIMIT, a compile-time constant and hardcoded table names. No `load_extension`. `DateFilter` binds `Int64` ranges.
- No `NSAppleScript`, `osascript`, `CFBundleURLTypes`, or ATS exception. The only `Process()` is the Ollama CLI launch with fixed `["serve"]` and no shell.
- `LinkPolicy` blocks `javascript:`, `file:`, `data:`, `ftp:`, custom and scheme-less URLs, logging only the scheme; `http(s)` shows the real destination in a confirmation alert. Model output is rendered inline-only Markdown, never HTML; excerpts and warnings go through `Text(variable)` which does not parse Markdown.
- Packaging: `set -euo pipefail` in all four scripts, all expansions quoted, no `eval`, no downloads; inside-out signing with hardened runtime and timestamp, `--deep` only on `--verify`; entitlements applied are the checked-in files; DMG and notarize scripts fail closed on non-Developer-ID identities.
- `LoginItem` uses `SMAppService.mainApp` (bundle identity, no path-based plist). `HotkeyManager` uses Carbon `RegisterEventHotKey`; no Accessibility or Input Monitoring grant.
- `.gitignore` covers build output, DBs, WAL/SHM, logs, models, `.env*`, PEM/P8/P12 and provisioning profiles; `.env.example` holds names only.
- `MailboxWatcher` discards FSEvents paths and only schedules a debounced rescan; no path reconstruction from untrusted names.
- `askmail.db` and `drafts.db` live under `~/Library/Application Support/AskMail/` at `0600`/`0700`, Time Machine and Spotlight excluded; logs are in-memory only unless exported.

## Suggested order for the next hardening pass

1. S-1 (both launch branches, Team ID pin, env pin) and S-3 (redirect delegate): they close the two paths by which the whole mailbox can leave the device without a user decision.
2. S-2 (Message-ID overwrite) and S-5 (sender equality): both are remote, unauthenticated, one email each.
3. S-4, S-6, S-7, S-28: shrink the prompt-injection blast radius in Draft-Modus before Phase 5 adds any Mail automation grant.
4. S-8, S-9: Services gating and pasteboard behaviour.
5. S-10 to S-14: resource and integrity bounds on the host side of the XPC boundary.
6. S-15, S-16, S-21 to S-25: CI and packaging hygiene, one PR.
7. Update hardening.md rows per the drift table.
