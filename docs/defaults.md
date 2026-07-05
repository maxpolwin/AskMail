# Default Parameters

Single source of truth for concrete starting values. Everything here is a
starting point to validate during the B11 spikes, not a fixed constant.
Where a value affects answer quality, it is flagged. Verify current model
availability and package versions at build time; do not trust version
strings in a document.

## Models
| Purpose | Default | Notes |
|---|---|---|
| Embedding | `nomic-embed-text` (768-dim) | local Ollama only, never cloud. ~274 MB. Set `num_ctx` to use full 8192 window. |
| Local chat | `qwen2.5:7b` or `llama3.1:8b` (Q4) | fits 24 GB with headroom. Benchmark both for latency vs quality on real queries. |
| Ollama Cloud chat | `qwen3.5:cloud` (or current cloud model) | confirm available cloud model id at build time. |
| Mistral chat | `mistral-large-latest` | confirm current model id and pricing before wiring. |

## Retrieval (quality-critical, tune during spike B11 #3)
| Parameter | Default | Notes |
|---|---|---|
| Chunk size | ~512 tokens | validate against embedding window. |
| Chunk overlap | ~64 tokens | |
| Vector top-N (pre-fusion) | 30 | from sqlite-vec. |
| Keyword top-N (pre-fusion) | 30 | from FTS5. |
| Fusion | Reciprocal Rank Fusion (RRF) | |
| RRF k constant | 60 | standard RRF default; tune if fusion favors one side. |
| Final top-k (post-fusion) | 8 | user-configurable via context limit. |
| Relevance floor | tune empirically | below this, return the no-match message (empty-retrieval case). |

## Generation
| Parameter | Default | Notes |
|---|---|---|
| Context token limit | 4096 | user-configurable. Drop lowest-ranked chunks first if over. |
| Answer token limit | 800 | user-configurable ("shorter/longer"). |
| Temperature | 0.2 | grounded factual answers, low creativity. |
| Streaming | on | all providers. |
| Session buffer cap | 3 most recent turns | protects token budget. |

## Ingestion
| Parameter | Default | Notes |
|---|---|---|
| Envelope index path | `~/Library/Mail/V10/MailData/Envelope Index` | READ-ONLY. |
| Cocoa epoch offset | +978307200 | add to date_sent/date_received for Unix time. |
| Embed batch size | 16 | small on purpose: 128 × 8k-ctx OOM-killed the local daemon mid-run. |
| Embed num_ctx | 4096 | sized to ~512-token chunks; oversizing spikes memory. |
| Unreachable abort | 3 consecutive conn. failures | stop the run (don't fail every remaining message) if Ollama dies. |
| Attachment types (v1) | PDF only | |
| Max attachment size | 25 MB | skip larger; log skip. |
| Scheduled run gate | AC power only | manual trigger ignores; off-power runs are skipped, not queued. |
| Schedule interval | every 1 h | in-app timer while the app runs, + catch-up at launch and on plug-in. Only fires on AC power. |
| Ingest scope | new/changed only | per-file fingerprint (ROWID + mod-time/size); unchanged files are skipped. |

## UI
| Parameter | Default | Notes |
|---|---|---|
| Global hotkey | Control+Option+Space | user-configurable. Not Cmd+B (Bold conflict). |
| Panel open target | < 200 ms | |
| First token target | < 1 s local, < 200 ms cloud (stretch) | measure; relax cloud if unreachable. |
| Theme | dark primary | glass surfaces, color-blind-inclusive. |

## Logging
| Parameter | Default | Notes |
|---|---|---|
| Retention | 12 h rolling | |
| Level | retrieval scores, chunk ids, provider decisions, full error bodies | never secrets or clear-text Message-IDs. |
