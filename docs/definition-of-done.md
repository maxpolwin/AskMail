# Definition of Done, per Functional Requirement

One unambiguous acceptance line per FR. A task is done only when its check
passes. Maps to the FRs in Section A7 of the requirements document.

| FR | Done when |
|---|---|
| FR-1 Hotkey activation | Pressing the configured hotkey toggles the floating panel open and closed with focus in the input; verified on a German keyboard layout; default is Control+Shift+Space and it does not intercept Cmd+B or collide with VoiceOver's own Control+Option modifier keys. |
| FR-2 Ask a question | A typed question returns a streamed answer containing at least one superscript citation whose tap opens the correct source email in Mail via `message://`; the numbered source list matches the in-text superscripts. |
| FR-3 Multi-turn session | A follow-up that refers to the prior turn ("the attachment on that one") resolves correctly using the in-memory buffer; closing the panel clears the buffer, verified by a fresh session not recalling the prior question. |
| FR-4 Cloud fallback | With a deliberately invalid cloud key, the query still returns an answer from the local model, a non-blocking warning is shown, and the full error body appears in the 12 h log. |
| FR-5 Scheduled vectorization | On AC power, a scheduled run ingests only messages newer than the watermark and upserts without duplicates; off power, the run is skipped (not queued), verified in the log. |
| FR-6 Manual vectorization | The settings trigger runs regardless of power state, shows a live progress bar, and refreshes the last-vectorized timestamp on completion. |
| FR-7 Mailbox selection | Selecting an account at setup, and later changing it in settings, scopes ingestion to that account only; changing it does not silently mix accounts in the DB. |
| FR-8 Delete & rebuild | The settings action wipes the DB and resets the watermark after a confirmation prompt; the next run rebuilds from scratch. |
| FR-9 Provider & generation config | Changing provider, context limit, answer limit, system prompt, or hotkey in settings takes effect on the next query with no app restart. |
| FR-10 Vectorization status | Settings shows the correct last-vectorized timestamp and a live progress bar during an active run. |
| FR-11 Debug log export | "Copy logs" shows the content warning first, then copies the last 12 h to the clipboard on confirmation; nothing is copied if the user cancels. |

## Cross-cutting done criteria (all FRs)
- No secret ever written to code, config, or log (Gitleaks passes).
- Retrieval eval Recall@8 >= 0.85 on the user's filled retrieval.jsonl.
- Generation eval passes all assertion cases in generation.jsonl once the
  prompt contract is wired in.
- Dark mode and color-blind-inclusive rendering verified on the panel and
  settings.
- Every new interactive control carries a clear accessibility label (so
  VoiceOver and Voice Control both name it correctly) and is reachable
  without a mouse; a new global shortcut or keyboard-swallowing control is
  checked against VoiceOver's own Control+Option command space before it
  ships. Settings ▸ Accessibility features (Speak answer aloud,
  Higher-contrast panel) are exercised manually at least once per release.
