# AskMail

Local-first, hotkey-triggered natural-language Q&A over a vectorized Apple
Mail account. A global hotkey (default Control+Shift+Space) opens a floating
panel; questions are answered from the user's own mailbox via hybrid
retrieval (local embeddings + FTS5, RRF-fused), with streamed answers and
superscript citations that deep-link back to the source emails in Mail.

Swift-native, single repo, SwiftPM. See SECURITY.md for the threat model:
the mailbox and vector DB never leave the device; only the retrieved top-k
chunks for a single query go to a cloud provider, and only when one is
selected.

## Layout

| Path | Contents |
|---|---|
| `docs/` | prompt contract, default parameters, definition of done |
| `Sources/AskMailCore/` | library: parsing, chunking, store, retrieval, prompt assembly, providers |
| `Sources/AskMailApp/` | menu-bar app: hotkey, floating panel, settings |
| `Tests/AskMailCoreTests/` | unit tests (run headless, no Ollama needed) |
| `Tests/Fixtures/` | synthetic .emlx files, safe to commit (see its README) |
| `Tests/Evals/` | retrieval.jsonl (fill with real Message-IDs) and generation.jsonl |

The requirements & technical spec (Sections A/B) lives outside the repo;
docs/ carries the build-relevant contracts.

## Build & test

```sh
swift build          # library + app
swift test           # headless tests against Tests/Fixtures
swift run askmail    # menu-bar app (needs local Ollama for real queries)
```

`swift run askmail` launches a bare executable with no Info.plist and no
icon, so anything macOS registers for it (notably Full Disk Access in System
Settings) shows a blank icon. For day-to-day use, package it as a real app
bundle instead:

```sh
Packaging/build-app.sh   # builds a release binary, wraps it as .build/AskMail.app
open .build/AskMail.app  # or drag it to /Applications
```

The bundled app has its own icon and identity (`com.askmail.app`), separate
from the raw binary. If you already granted Full Disk Access to the raw
`askmail` binary, remove that (icon-less) entry from Privacy & Security >
Full Disk Access and re-grant it to `AskMail.app` once you launch the bundle.

Mailbox ingestion also needs the bundle: untrusted `.emlx`/MIME/HTML/PDF
parsing runs in a sandboxed XPC service (hardening H-6, see
[docs/hardening.md](docs/hardening.md)) that only exists inside
`AskMail.app/Contents/XPCServices` — `swift run askmail` has nowhere to load
it from, so real ingestion needs the packaged app, not the bare binary.

Runtime dependencies (not needed for tests): [Ollama](https://ollama.com)
with `nomic-embed-text` pulled for embeddings and a local chat model
(`qwen2.5:7b` default). Cloud providers are optional; keys go in the macOS
Keychain via Settings, never in files.

## Implementation status

Done and under test:
- .emlx parsing (byte-count framing, MIME multipart, base64/quoted-printable),
  HTML-to-text with newsletter boilerplate stripping, PDF text via PDFKit
- Chunking (~512 tokens, ~64 overlap), local Ollama embeddings interface
- SQLite store: messages/chunks, FTS5 keyword search, vector search,
  watermark, idempotent re-ingest, delete & rebuild
- RRF fusion, date-scoped query preprocessing (en/de month names)
- Prompt assembly exactly per docs/prompt-contract.md, including per-email
  citation numbering and token budgeting
- Citation post-processing: superscripts, source list, message:// links
- Providers: Ollama local, Ollama Cloud, Mistral (all streaming), with
  automatic local fallback and full-error-body logging (FR-4)
- Rolling 12 h in-memory debug log; Keychain-backed API keys
- App shell: global hotkey, floating dark panel, settings window with
  manual vectorization, provider/limits/system-prompt editing, log copy
  with content warning
- Scheduled vectorization (FR-5): hourly in-app timer gated on AC power, plus
  catch-up at launch and on plug-in. Incremental — a per-file fingerprint
  (ROWID + mod-time/size) skips unchanged messages, so runs process only new or
  changed mail and resume after a crash. Embedder retries transient failures.
- Fresh-mail fast path: an FSEvents watcher on the Inbox/Sent trees triggers a
  debounced incremental run, so new mail is searchable in about a minute on AC
  power (the hourly timer stays the backstop).
- Draft-Modus (docs/draft-modus-plan.md phases 1–4): background classification
  and local-only reply drafting for ordinary inbox mail, style learning from
  actually-sent replies, a Settings toggle, a read-only Drafts window
  (copy / open thread in Mail / discard — never auto-sent), and a best-effort
  notification when a draft is ready. A macOS Services menu ("AskMail: Insert
  Draft" / "AskMail: Regenerate Draft" — select the quoted reply text in Mail,
  right-click ▸ Services) prepends the draft above the kept quoted
  conversation; both verbs bypass every auto-draft eligibility rule
  (newsletter/no-reply classification, sender exclusion, the master toggle)
  when explicitly invoked, generating on demand if nothing was drafted yet —
  never auto-inserted without that click. Local Ollama auto-starts itself
  (app launch, every tick, every Services invocation) if it was quit
  separately from AskMail.
- Egress control (hardening H-10/H-11): a compiled-in host allowlist in front
  of every outbound request, embeddings structurally loopback-only, a live
  "sent to <host>" indicator in the panel, and a per-session egress audit
  table in Settings.
- Parser hardening (H-7/H-8/H-9): size caps before read and before decode,
  MIME recursion depth limit, bounded + precompiled HTML regex passes.
- Chat requests survive cold model loads (180 s idle timeout + one connect
  retry) instead of failing the first query after a model reload.

Open (tracked against docs/definition-of-done.md):
- Envelope-index column names must be validated against a real V10 index
  (spike B11 #1); ingestion currently scans the account directory for .emlx
- sqlite-vec swap-in for vector search (brute-force exact scan today)
- Hotkey re-registration on settings change; hotkey recorder UI
- Eval runners for Tests/Evals (Recall@8 gate and generation assertions,
  including `expect_not_matches` regexes)
- Fill Tests/Evals/retrieval.jsonl with real Message-IDs from the target
  mailbox

## Development

Pre-commit hooks (Gitleaks, Socket, hygiene): `pipx install pre-commit &&
pre-commit install`. The repo is treated as public; no secret ever lands in
code, config, or logs.
