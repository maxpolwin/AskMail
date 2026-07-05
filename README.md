# AskMail

Local-first, hotkey-triggered natural-language Q&A over a vectorized Apple
Mail account. A global hotkey (default Control+Option+Space) opens a floating
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

The requirements & technical spec (Sections A/B) lives outside the repo for
now; docs/ carries the build-relevant contracts. Add it as
`docs/requirements.md` when finalized.

## Build & test

```sh
swift build          # library + app
swift test           # 36 headless tests against Tests/Fixtures
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

Open (tracked against docs/definition-of-done.md):
- Envelope-index column names must be validated against a real V10 index
  (spike B11 #1); ingestion currently scans the account directory for .emlx
- sqlite-vec swap-in for vector search (brute-force exact scan today)
- Scheduled vectorization via launchd with AC-power gate (FR-5)
- Hotkey re-registration on settings change; hotkey recorder UI
- Eval runners for Tests/Evals (Recall@8 gate and generation assertions,
  including `expect_not_matches` regexes)
- Fill Tests/Evals/retrieval.jsonl with real Message-IDs from the target
  mailbox

## Development

Pre-commit hooks (Gitleaks, Socket, hygiene): `pipx install pre-commit &&
pre-commit install`. The repo is treated as public; no secret ever lands in
code, config, or logs.
