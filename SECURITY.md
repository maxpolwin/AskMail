# Security & Threat Model

## Posture
Local-first. The app runs entirely on one Mac. The vector database, the
embedding model, and all mailbox content stay on device. The only outbound
network traffic is to a cloud LLM provider, and only when the user has
selected one.

## Data boundary
- The full mailbox and the vector DB never leave the device.
- On cloud routing, only the retrieved top-k chunks for a single query are
  sent to the selected provider, plus the question and system prompt.
- Enforced in code, not just documented (hardening H-10/H-11): a compiled-in
  egress allowlist (loopback, `ollama.com`, `api.mistral.ai`) fronts every
  outbound request; embeddings are structurally loopback-only; every cloud
  send is recorded at request initiation in a session egress log, shown live
  in the panel and audited in Settings.
- Draft-Modus is local-only by construction: drafting, classification, and
  style learning never use the configured cloud provider, and a draft is
  never auto-sent or inserted into Mail.
- v1 has no PII redaction and no sender exclusion (both land in v1.1). This
  is an accepted, documented gap. Do not point v1 at a mailbox with highly
  sensitive correspondence.

## Secrets
- API keys live in the macOS Keychain, read at runtime via the Security
  framework. Never in code, config, or logs. Repo is treated as public.
- Keychain items:
  - service "askmail.ollama-cloud", account "api-key"
  - service "askmail.mistral", account "api-key"

## File processing
- The Mail envelope index is opened READ-ONLY. Never written. Corruption
  forces a multi-hour Mail rebuild.
- `.emlx` and PDF parsing operate on untrusted input. Fail closed on parse
  errors; never execute or follow embedded content. Caps are enforced before
  work is done (H-7/H-8/H-9): file size before read, attachment size before
  decode, MIME nesting depth, and HTML length before any regex pass.
- That parsing — including the PDFKit call, given PDF/CoreGraphics parsers'
  history of memory-corruption bugs — runs in a sandboxed, non-FDA,
  no-network XPC child process, not in the app holding Full Disk Access and
  the Keychain (hardening H-6; see docs/hardening.md).

## Logging
- Debug logs are capped at a 12-hour rolling window; the default verbosity
  is `.info`, which does not capture prompt/answer/mail-excerpt text — only
  raising it to Debug does (hardening H-23).
- At Debug verbosity, logs contain question and answer text (needed for
  tester bug reports), so the "Copy logs" action shows a content warning
  first regardless of the current level.
- Logs never contain Keychain values, full email bodies beyond the chunks
  already in a query, or raw `Message-ID` headers in clear text where
  avoidable.

## Supply chain
- Pin exact dependency versions. Run a Socket check before adding any
  package. Prefer system frameworks (Security, PDFKit) over third-party
  where feasible.
- Pre-commit hooks: Gitleaks (secret scanning) and Socket (dependency
  risk). See .pre-commit-config.yaml.

## Reporting
Personal project. Route issues through the private tracker; do not open
public issues containing log excerpts (they may include email content).
