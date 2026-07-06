# Implementation spec: Ollama setup guidance + swappable local models

**Audience:** an implementing agent (Fable) working in this repo.
**Goal:** make Ollama setup self-guided in-app, let users pick and one-click
download suitable local chat *and* embedding models, and make the embedding
model safely swappable (no silent index corruption).

Ship as **three independent phases**, each its own commit, tests green, pushed
to `main` (see the repo's git workflow: commit + push to main, then the user
pulls). Phases 1–2 are pure UX; Phase 3 is the correctness-critical piece.

---

## Diagnostic background — why this feature exists

A real user's run surfaced the problems this spec addresses. Ground truth, read
from AskMail's own database (`~/Library/Application Support/AskMail/askmail.db`)
after the run:

| Table | Rows | Meaning |
|---|---:|---|
| `chunks` | **0** | Nothing embedded — search fully non-functional |
| `ingest_failures` | 13,200 | Every message failed and is queued for retry |
| `ingest_state` | 662 | Empty-body files marked "done" (no chunks) |
| `messages` | 657 | 662 minus 5 duplicate Message-IDs (same mail in two folders) |

**Root cause:** the embedding model `nomic-embed-text` was not pulled, so every
`/api/embed` returned `HTTP 404 "model not found, try pulling it first"` →
**zero vectors, every query 404s.** This is the friction Phases 1–3 remove: an
in-app path to install/start Ollama and pull the model, so a new user never
touches the Terminal.

**Scope finding (reconciliation).** The visible account
`curiousmind@posteo.com` shows ~1,237 Inbox messages, but the run attempted
**13,862** files (`662 + 13,200`). The failure rows store each file's path, so
the breakdown is exact — all one account (`C1A3CD87…`):

| Mailbox | Count | Share |
|---|---:|---:|
| **Trash** | **11,926** | **90%** |
| INBOX | 1,246 | 9% |
| Junk | 27 | <1% |
| Sent | 1 | — |

INBOX (1,246) matches the screenshot; the "extra ~12,600" was the **Trash
folder**. `EmlxLocator.scan` walked the whole account tree with no mailbox
filter, so it treated ~11,900 deleted emails and 27 spam messages as fair game
to embed and later cite — a correctness problem, and ~90% wasted work.

### Already fixed on `main` — DO NOT re-implement
- **Mailbox scoping (`c54e419`).** `EmlxLocator.scan` now uses an **allowlist:
  only Inbox and Sent are vectorized** (Trash, Junk, Archive, Drafts excluded) —
  stricter than "skip Trash/Junk". See `isIndexed` / `topLevelMailbox` /
  `indexedMailboxNames` in `Sources/AskMailCore/EnvelopeIndex.swift` and
  `Tests/AskMailCoreTests/EmlxLocatorTests.swift`. Nothing to add here.
- **Model-not-found handling (`601dd08`).** A 404 "model not found" is mapped to
  `ProviderError.ollamaModelMissing(model:)` and surfaced as an actionable
  "run `ollama pull …`" message in `Vectorizer`/`AskView` (a 404 is not a
  `URLError`, so it bypassed the unreachable-abort guard). Phase 1 replaces the
  Terminal instruction with the in-app download; do not re-add the message
  plumbing.

### Adjacent open cleanups — small, do alongside the phases
1. **`ingest_state` = 662 "new" overstates progress.** Those are empty-body
   messages (zero chunks) counted as ingested (see `MailboxIngestor.ingest` —
   the embed loop is skipped when there are no chunks). Either don't count a
   zero-chunk message as "new" or report it separately (e.g. "N new, M empty"),
   so the Settings status doesn't imply searchable content that isn't there.
   Add a test. *(Fits naturally with Phase 3.)*
2. **Stale failure rows for now-excluded mailboxes.** After `c54e419`, the
   ~11,953 Trash/Junk failure rows already in a user's DB can no longer be
   re-scanned (scan excludes them) or cleared, so "Retry N failed…" stays
   inflated forever. On a run, prune `ingest_failures` rows whose `path` is no
   longer an indexed mailbox (or whose file no longer scans), making Retry
   self-healing. "Delete & rebuild" already clears them; this handles the
   incremental path. Add a store-level test. *(Fits with Phase 3.)*

---

## 0. Background — current state (read these first)

- Providers live in `Sources/AskMailCore/Providers.swift`:
  - `OllamaClient` (chat, `/api/chat`) and `OllamaEmbedder` (`/api/embed`).
  - `ProviderError.ollamaModelMissing(model:)` and
    `ProviderError.isOllamaModelMissing(status:body:)` already detect the
    "model not found, try pulling it first" 404. Reuse these; do not reinvent.
  - `Retry` helper and `OllamaClient.ensureOK(response:bytes:)` show the
    house style for streaming + error handling.
- Model names are hardcoded in `Sources/AskMailCore/Defaults.swift`:
  `embeddingModel = "nomic-embed-text"`, `localChatModel = "qwen2.5:7b"`,
  `ollamaLocalHost = http://localhost:11434`.
- Chat model path: `QueryService` builds providers from `QuerySettings` in
  `Sources/AskMailCore/QueryService.swift:167`
  (`OllamaClient(host: settings.ollamaHost, model: settings.localModel)`), but
  `SettingsStore.querySettings()` (`Sources/AskMailApp/SettingsStore.swift`)
  never passes `localModel`, so it is stuck at the default. `ProviderChoice`
  (ollamaLocal / ollamaCloud / mistral) is defined at `QueryService.swift:3`.
- Embedding path: three hardcoded `OllamaEmbedder()` constructions —
  `Sources/AskMailApp/AskView.swift:79`, `Sources/AskMailApp/Vectorizer.swift:82`
  and `:149`.
- Settings UI: `Sources/AskMailApp/SettingsView.swift`, a `Form` with sections
  Mailbox / Shortcut / Startup / Vectorization / Generation / API keys /
  System prompt / Diagnostics. **Reuse two existing patterns:**
  - the **Full Disk Access pattern** (Mailbox section): a status enum
    (`MailAccessStatus`) drives guidance text + a one-click fix button
    (`openFullDiskAccessSettings`). Mirror this for Ollama.
  - the **rebuild confirmation** pattern (`showRebuildConfirmation` +
    `.confirmationDialog` + `deleteAndRebuild()`). Reuse for embedding swaps.
- Settings persistence: `SettingsStore` is `UserDefaults`-backed with the
  `@Published var x { didSet { defaults.set(...) } }` idiom, read fresh per
  query (FR-9). Add new settings the same way.
- Store: `Sources/AskMailCore/SQLiteStore.swift` has a `meta(key)` /
  `setMeta(key:value:)`-style key/value table (already used for the watermark),
  `deleteAll()` (clears messages/chunks/ingest_state/ingest_failures/meta), and
  a brute-force `vectorSearch` whose `guard stored.count == embedding.count`
  (`SQLiteStore.swift:210`) **silently drops** dimension-mismatched vectors.

## 1. Constraints & conventions (must follow)

- **Tests stay headless — no live Ollama.** Everything network-touching must be
  injectable and stubbed in tests, exactly like `EmbeddingProvider` +
  `StubEmbedder`/`UnreachableEmbedder` in
  `Tests/AskMailCoreTests/IncrementalIngestTests.swift`. Define a protocol for
  the new Ollama control client and stub it; parse logic (NDJSON pull progress,
  `/api/tags`, `/api/show`) must be pure functions with direct unit tests.
- **Embeddings never leave the device** (SECURITY.md). All embedding + `/api/*`
  calls target the local host only. Never send mailbox content to a cloud host.
- **App is not sandboxed** (it needs Full Disk Access) — spawning processes and
  launching apps is allowed. Do not add an App Sandbox entitlement.
- **Never silently download multi-GB models.** Every pull is user-initiated,
  shows model size up front, and streams progress. The embedding model
  (~275 MB) may be offered prominently; the chat model (~4.7 GB) must be
  explicit.
- **Honest status.** Never report success that didn't happen (see `saveKeys` /
  `setLaunchAtLogin` for the tone). Surface real errors.
- **Put logic in `AskMailCore`, keep SwiftUI thin.** Views aren't unit-tested
  here; testable logic (status derivation, registry, parsers, stamp/mismatch)
  belongs in the library.
- Match surrounding comment density and naming. Keep unicode-escaped strings
  consistent with the existing files if that's the local idiom.
- **Verify the Ollama API shapes below against the installed Ollama version**
  before relying on them; they evolve.

## 2. Ollama HTTP API used here

- `GET /api/version` → `{"version":"x.y.z"}`. 200 ⇒ daemon reachable.
- `GET /api/tags` → `{"models":[{"name":"nomic-embed-text:latest","size":<bytes>,
  "details":{"family":"...","parameter_size":"..."}}, ...]}`. Source of truth
  for **what's installed** (drives the pickers).
- `POST /api/show` `{"model":"<id>"}` → includes `model_info` with
  `"<arch>.embedding_length": <int>` (the **embedding dimension**) and, on
  recent versions, a `capabilities` array (`["embedding"]` vs
  `["completion",...]`) to tell embedding vs chat models apart.
- `POST /api/pull` `{"model":"<id>","stream":true}` → streams NDJSON:
  `{"status":"pulling manifest"}` … `{"status":"downloading","total":N,
  "completed":M}` … `{"status":"success"}`. Progress = completed/total.

---

## Phase 1 — Ollama runtime + one-click model download

**Outcome:** a new user never opens Terminal. Settings shows Ollama health and
downloads the required embedding model in-app.

### Tasks

1. **`OllamaControl` (new, `AskMailCore`).** A protocol + concrete impl over the
   local host:
   - `func reachable() async -> Bool` (GET `/api/version`, short timeout).
   - `func installedModels() async throws -> [InstalledModel]` (GET `/api/tags`).
   - `func showModel(_ id: String) async throws -> ModelInfo` (POST `/api/show`;
     expose `embeddingLength: Int?` and `capabilities: [String]`).
   - `func pull(_ id: String) -> AsyncThrowingStream<PullProgress, Error>`
     (POST `/api/pull`, stream=true; reuse the `URLSession.bytes` + `.lines`
     pattern from `OllamaClient.stream`). `PullProgress { status, completed,
     total }`.
   - Keep the JSON/NDJSON decoding in pure static funcs so they're unit-testable
     without a socket.
2. **Runtime detection.** An `OllamaStatus` enum:
   `notInstalled` / `stopped` / `runningModelMissing(model:)` / `ready(modelCount:)`.
   Derivation logic (a pure function of: reachable?, binary present?, installed
   models, required embedding model) lives in `AskMailCore` and is unit-tested.
   - Binary/app presence check (for `notInstalled` vs `stopped`): look for
     `/Applications/Ollama.app`, `/opt/homebrew/bin/ollama`,
     `/usr/local/bin/ollama`, `~/.ollama`.
3. **Auto-start (`stopped`).** "Start Ollama" launches `Ollama.app` via
   `NSWorkspace`, falling back to spawning the located CLI with `serve` via
   `Process`. After launch, poll `reachable()` briefly and refresh status.
4. **Engine section in `SettingsView`** (mirror the FDA pattern), placed above
   or within Generation:
   - `notInstalled` → guidance + "Download Ollama…" (opens https://ollama.com/download)
     and/or "Install with Homebrew" (`brew install ollama` via `Process`).
   - `stopped` → "Start Ollama".
   - `runningModelMissing` → "Download <model> (275 MB)" → `pull` with a
     `ProgressView` (reuse the Vectorization progress UI idiom).
   - `ready` → "✓ Ollama ready · N models installed".
5. **Wire the download into existing model-missing surfaces.** Where
   `ProviderError.ollamaModelMissing` is shown today (`Vectorizer.status`,
   `AskView` warning), add an affordance/route to the Engine section download
   instead of only telling the user to run a Terminal command.

### Tests
- Pure decoders: `/api/tags`, `/api/show` (embedding_length + capabilities),
  and the NDJSON pull-progress parser (partial layers, final `success`).
- `OllamaStatus` derivation table: each (reachable, binaryPresent, models) input
  → expected status.
- `OllamaControl` protocol stub driving the status/download logic without a
  network.

### Done when
Fresh machine with Ollama installed-but-model-missing: opening Settings shows
"Download nomic-embed-text", clicking it streams progress and, on success,
flips to "ready" and lets vectorization proceed — no Terminal.

---

## Phase 2 — Chat + embedding model pickers (guidance + swappability)

**Outcome:** users pick suitable models from a curated, described list plus
whatever they already have installed; missing ones download in place.

### Tasks
1. **Model registry (`AskMailCore`).**
   ```swift
   public struct ModelOption: Sendable, Equatable {
       public let id: String        // "qwen2.5:7b" / "nomic-embed-text"
       public let kind: Kind        // .chat / .embedding
       public let approxSizeMB: Int
       public let blurb: String     // "Balanced quality · 4.7 GB · ~8 GB RAM"
   }
   public enum ModelCatalog {
       public static let chat: [ModelOption]
       public static let embedding: [ModelOption]  // includes nomic-embed-text
   }
   ```
   The blurbs are the "how to choose" guidance layer.
2. **Persist choices in `SettingsStore`** (UserDefaults idiom):
   `localChatModel` (default `Defaults.localChatModel`) and `embeddingModel`
   (default `Defaults.embeddingModel`).
3. **Inject the choices** — remove the hardcoding:
   - `SettingsStore.querySettings()` passes `localModel:` (and, if `QuerySettings`
     grows one, `embeddingModel:`).
   - Replace the three `OllamaEmbedder()` sites with
     `OllamaEmbedder(model: SettingsStore.shared.embeddingModel)`.
4. **Two pickers in the Generation section**, each populated by merging
   `ModelCatalog` with `OllamaControl.installedModels()`, grouped:
   - *Recommended & installed* → selectable;
   - *Recommended, not installed* → row with a "Download" button (`pull`);
   - *Other installed* (from `/api/tags`) → selectable (advanced).
   Chat picker categorization can trust the catalog; for "other" embedding
   models use `/api/show` `capabilities`/`embedding_length` to keep chat models
   out of the embedding picker.

### Tests
- Registry/merge logic: given catalog + installed set → correct grouping and
  download affordances (pure function, unit-tested).
- `querySettings()` now carries the selected chat model; embedder is constructed
  with the selected embedding model (assert via injection seam).

### Done when
Changing the chat model in Settings changes the model used for the next answer
with no restart (FR-9). Missing recommended models show a working Download.

---

## Phase 3 — Safe embedding swaps + onboarding checklist

**Outcome:** switching the embedding model can never silently corrupt the index;
first-run is a guided checklist.

### Tasks
1. **Stamp the index with its embedding model.** Write
   `meta['embedding_model'] = "<id>@<dimension>"` during ingest (in
   `MailboxIngestor`/`Vectorizer` at run start or first upsert). Get the
   authoritative `<dimension>` from `OllamaControl.showModel(id).embeddingLength`
   (fall back to the registry value).
2. **Mismatch → consented rebuild.** 
   - In the embedding **picker's** `onChange`, if the store is non-empty and the
     new model ≠ the stamp, present a `.confirmationDialog` (reuse the
     `showRebuildConfirmation` idiom): *"Switching to <model> re-indexes your N
     messages (~X min). Continue?"* On confirm: `deleteAll()` → set the model →
     `Vectorizer.run(.manual)` → new stamp. On cancel: revert the picker.
   - **Belt-and-suspenders in `Vectorizer.run`:** before an incremental run,
     compare configured model vs stamp; if they differ and the index is
     non-empty, refuse the incremental run with a clear status directing the
     user to rebuild (don't silently mix vectors).
3. **Make search loud (optional but recommended).** With a single-model index
   guaranteed, treat the `SQLiteStore.swift:210` dimension guard as an invariant:
   log/throw on mismatch rather than silently dropping, so a bug surfaces.
4. **Onboarding checklist** — a card (in Settings or a first-run window) shown
   until all green, each row self-healing with a button, reusing existing
   detection: (1) Full Disk Access, (2) pick account, (3) Ollama running,
   (4) embedding model installed, (5) first vectorization.

### Tests
- Store-level: after ingest, `meta['embedding_model']` equals the configured
  stamp; `deleteAll()` clears it.
- Mismatch detection: configured model ≠ stamp on a non-empty index ⇒ the
  rebuild-required path is taken (test the pure decision function, and that
  `Vectorizer.run` refuses/aborts incrementally).
- Dimension from `/api/show` parsing (already covered in Phase 1 decoder tests;
  assert it feeds the stamp).

### Done when
Selecting a different embedding model prompts a rebuild, re-indexes, and updates
the stamp; declining leaves the prior model selected; a stale stamp blocks a
silent incremental run.

---

## Non-goals (explicitly out of scope for this spec)
- **Bundling the Ollama runtime** inside the app (separate, larger decision:
  app size, signing/notarization with a hardened runtime).
- Adding document/query embedding **prefixes** (e.g. nomic's
  `search_document:` / `search_query:`). It's a related retrieval-quality change
  and the `ModelOption` struct should leave room for it, but implementing it is
  a separate task.
- Non-Ollama embedding backends.

## Suggested sequencing
Phase 1 → commit + push + user tests → Phase 2 → Phase 3. Each phase must build
(`swift build`) and pass `swift test` headless before pushing.
