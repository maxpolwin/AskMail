# Prompt Contract: Apple Mail Ask AI

Companion to the requirements & technical spec. This file pins the **default system prompt** and the **exact prompt-assembly template**. It is the single highest-leverage artifact for answer quality (the user's flagged accuracy risk). The assembly is implemented in `QueryService` (Section B6, step 6) exactly as specified here. The system prompt is user-editable at runtime (FR-9); the text below is the default shipped value.

---

## 1. Default system prompt

Store as a constant `defaultSystemPrompt`. This is the value pre-filled into the editable settings field.

```
You are an assistant that answers questions about the user's own email.

Rules:
1. Answer ONLY from the CONTEXT provided below. The context is a set of
   excerpts retrieved from the user's mailbox. Do not use outside knowledge.
2. If the answer is not in the context, say so plainly (in the user's
   language) and do not guess. Suggest what the user might search for
   instead. Never fabricate senders, dates, amounts, or quotes.
3. Answer in the SAME LANGUAGE as the QUESTION, regardless of the language
   of the emails.
4. Be concise and direct. Lead with the answer. Do not restate the question.
5. Every factual claim, figure, date, or quote must be traceable to a
   specific source. Immediately after each such claim, cite the source by
   its number in square brackets, e.g. [1] or [2]. The app renders these
   as superscript numbers linked to the source. Place the citation right
   after the claim it supports, not bunched at the end. Cite the minimum
   sources needed per claim.
6. When the context contains conflicting information (e.g. a plan changed
   across emails), surface the most recent and note the change, citing both.
7. Do not output source numbers as prose (never write "source 1 says").
   Only use them inside the bracketed citation markers.
8. Formatting: write in plain prose. You may use **bold** or *italic*
   sparingly and strategically to highlight a single key term, name, or
   figure, but never enough to clutter the answer. Do not use headings,
   tables, or bullet lists.
```

Notes for implementation:
- The `[N]` numbers are assigned at assembly time (Section 3 below): one number per **distinct source email**, in fused-rank order of first appearance. The app keeps a map `N -> message_id` and uses it for both the inline superscript link and the numbered source list (Section 6). The model never sees or emits the real `Message-ID`, so no header value leaves in clear text.
- Rule 3 (answer in the question's language) is enforced by prompt, not by a language classifier, in v1. If quality is poor on short questions, add explicit language detection as a v1.1 refinement.

---

## 2. Prompt-assembly variables

`QueryService` builds the final request from these inputs:

| Variable | Source | Notes |
|---|---|---|
| `systemPrompt` | settings (default in §1) | verbatim |
| `contextBlock` | fused top-k chunks (B6) | see §3 formatting |
| `sessionBlock` | in-memory session buffer (B8) | prior Q&A pairs this session, oldest first; empty on first turn |
| `question` | panel input | verbatim, untrimmed of meaning |
| `contextTokenLimit` | settings | drop lowest-ranked chunks first if over budget |
| `answerTokenLimit` | settings | passed as provider `max_tokens` / `num_predict` |

---

## 3. Context block format

Each fused chunk is rendered as a delimited unit. Numbers `[1], [2], ...` are assigned **per distinct source email**, in fused-rank order of first appearance: the first chunk gets `[1]`; a later chunk from that same email reuses `[1]`; the first chunk from a different email gets `[2]`, and so on. Keep an in-memory map `N -> message_id` used for both the inline superscript links and the numbered source list (Section 6).

```
--- [1] from: {sender} | date: {YYYY-MM-DD} | source: {body|pdf} ---
{chunk text}

--- [2] from: {sender} | date: {YYYY-MM-DD} | source: {body|pdf} ---
{chunk text}
```

Rules:
- Two chunks from the same email **share the same number**; the map `N -> message_id` is therefore one-to-one. These assembly numbers are what the model sees and cites; the panel renumbers the *cited* subset for display (Section 6).
- Assign numbers **after** the token-budget trim (Section 2), so dropped chunks never leave holes in the numbering.
- `date` is the converted Unix date rendered `YYYY-MM-DD` (Cocoa-epoch conversion already done at ingestion, Section B4).
- Order strictly by fused rank; do not re-sort by date. Recency is handled by the date-filter preprocessing (B6 step 5), not by context ordering.

---

## 4. Session block format

Included only when the session buffer is non-empty. Rendered above the current question so the model can resolve follow-ups ("what about the attachment on that one").

```
Earlier in this conversation:
Q: {previous question 1}
A: {previous answer 1}
Q: {previous question 2}
A: {previous answer 2}
```

Cap the session block at the 3 most recent turns to protect the token budget; older turns drop off silently.

---

## 5. Final message assembly

Chat-format providers (all three) receive:

- **system** role: `systemPrompt`
- **user** role: the assembled body below

```
{sessionBlock}          # omitted if empty

CONTEXT:
{contextBlock}

QUESTION:
{question}
```

Do not split context into a separate system message; keeping it in the user turn keeps behaviour consistent across Ollama, Ollama Cloud, and Mistral, which weight system messages differently.

---

## 6. Citation rendering (in-text superscript + linked source list)

The model outputs plain `[N]` markers. The panel post-processes the streamed answer before display:

The model's markers carry the assembly numbers (Section 3), but only a subset of sources end up cited, in an order that need not be `1, 2, 3`. So the panel first **renumbers the cited sources `1…M` by first appearance in the answer** (reading order), then renders both the superscripts and the list with those display numbers. Reading order is independent of relevance — a source cited third can still show the strongest relevance bar.

**In-text:** replace each marker with the renumbered superscript(s) (¹²³ ...) rendered as an `AttributedString` link. A marker may cite several sources — `[4,6]`, `[4, 6]` — and renders as a thin-spaced cluster (¹ ²); unknown numbers inside a marker drop while the valid ones stay. Tapping the superscript opens the mapped email directly via `message://<Message-ID>` (Section B8, URL-encoded angle brackets `%3C`/`%3E`). The superscript sits immediately after the word it follows, matching footnote-style citation so each statement or figure links to its exact source.

**Below the answer:** a numbered "Sources" list, one entry per distinct source email, each entry itself a tappable `message://` link showing subject, sender, and date:

```
Sources
1  {subject} — {sender}, {YYYY-MM-DD}
2  {subject} — {sender}, {YYYY-MM-DD}
```

Display numbers are contiguous `1…M` with no gaps, even when the model's assembly numbers skip (an uncited or dropped source leaves no number). ¹ in the answer and `1` in the list resolve to the same email; the list is ordered by first appearance. Both are live links; the user can jump from either.

Implementation notes:
- Do the `[N]` to superscript substitution on the completed answer, not mid-stream, to avoid partial-marker flicker while tokens arrive.
- If the model emits a `[N]` with no matching source in the map (rare, malformed output), drop the marker silently rather than rendering a dead link, and log it.
- UI copy is English-only in v1 (per A8); the list label is "Sources". Localization (e.g. German "Quellen") arrives with v1.1.

## 7. Empty-retrieval case

If hybrid retrieval returns zero chunks above the relevance floor, do not call the LLM with an empty context. Return a fixed, localized message directly ("No matching emails found. Try different terms or a wider date range."), matching the question's language via the same prompt path if you prefer a model-generated variant. Log the empty retrieval with the query terms.

---

## 8. Change control

This contract and the retrieval parameters in Section B6 must move together. If chunk size, `top-k`, or the fusion method changes, re-run the generation eval set (see eval guidance) before shipping, because a prompt tuned to one context shape can regress on another.
