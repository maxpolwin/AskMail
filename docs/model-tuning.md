# Model tuning: memory, context and excerpts

How AskMail's recommended budgets (excerpts per answer, context tokens, answer
tokens) and the Settings memory gauge were derived. Measured, not assumed.

**Setup.** Apple M2, 24 GB; Ollama 0.40.16 (`llama-server` runner, flash
attention auto, f16 KV cache); models `llama3.2:3b` (Q4_K_M), `qwen2.5:7b`,
`qwen2.5:14b`. Memory and long-context tests used synthetic mail-style
excerpts in AskMail's real prompt format. Answer tests used AskMail's own
retrieval and prompt (`QueryService`) against a copy of a ~54,000-chunk
personal mailbox index, with 8 current-affairs questions. Results recorded
numbers only, never email text or answers.

## 1. Memory: the context window costs `layers × kv_heads × (key + value) × 2` bytes per token

Ollama's reported size equals the model weights plus that KV cache, plus a
fixed ~0.25 GB and a few percent that grows with the window. The estimate used
by the app is `(weights + KV) × 1.05 + 0.3 GB`.

| Model | KV per token | Window | Ollama reported | App estimate |
|---|---|---|---|---|
| llama3.2:3b (28 layers, 8 KV heads) | 112 KiB | 4,096 | 2.56 GB | 2.91 GB |
| | | 16,384 | 4.08 GB | 4.39 GB |
| | | 65,536 | 10.01 GB | 10.31 GB |
| qwen2.5:7b (28 layers, 4 KV heads) | 56 KiB | 4,096 | 4.76 GB | 5.46 GB |
| | | 32,768 | 6.61 GB | 7.19 GB |
| qwen2.5:14b (48 layers, 8 KV heads) | 192 KiB | 4,096 | 9.48 GB | 10.59 GB |
| | | 32,768 | 15.23 GB | 16.50 GB |

The estimate never fell below a measurement and stayed within 3% to 15%
above it across all 16 measured points (the high end is small windows, where
the fixed margin dominates). `ContextBudgetTests` pins every measured point. Process footprint (the
Activity Monitor Memory column) shows only the KV and compute part, since model
weights are memory-mapped; Ollama's reported size is the whole-model figure.

The earlier rule of thumb (1 GB per 1,000 tokens) overstated a 23,000-token
window on `llama3.2:3b` by about 9 times (23 GB against 4.9 GB measured) and
was removed.

**GPU limit.** On Apple silicon the GPU may address only part of RAM
(`MTLDevice.recommendedMaxWorkingSetSize`: 17.76 GiB of 24 GB on this M2). The
gauge compares against that figure and warns above 90% of it. Past it, Ollama
moves layers to the CPU, which is far slower; it does not fail.

## 2. Long context: small models lose accuracy past ~8k prompt tokens

One planted fact ("vault access code") among synthetic excerpts, with a decoy
code for another project; prompts filled about 65-70% of the window. Correct
answers out of runs (paired prompts across models):

| Window | llama3.2:3b | qwen2.5:7b | qwen2.5:14b |
|---|---|---|---|
| 4,096 | 6 / 6 | 5 / 6 | 6 / 6 |
| 8,192 | 5 / 6 | 6 / 6 | 3 / 6 |
| 16,384 | 1 / 6 | 6 / 6 | 5 / 6 |
| 32,768 | 0 / 3 | 3 / 3 | 2 / 3 |

`llama3.2:3b` collapses between 8k and 16k; `qwen2.5:7b` held through 32k. The
14b result is mixed (it picked the decoy three times at 8k); with these sample
sizes it cannot be ranked against the 7b.

Speed (prompt processing / generation, tokens per second, averaged):
3b 439 to 124 / 37 to 18; 7b 157 to 90 / 17 to 11; 14b 70 to 40 / 7.5 to 5, from
4k to 32k windows.

## 3. Real questions: citations track model size, not excerpt count

8 questions x excerpt counts, context budget sized to hold every excerpt.
"Cited" is the share of answers with at least one valid `[N]` citation;
"grounded" is the share of numbers in the answer that appear in the excerpts
sent to the model; time is to first token / total.

| Model | Excerpts | Cited | Valid sources per answer | Grounded | Time |
|---|---|---|---|---|---|
| llama3.2:3b | 8 | 12% | 0.1 | 100% | 11 s / 14 s |
| | 13 | 25% | 0.5 | 92% | 24 s / 28 s |
| | 30 | 0% | 0.0 | 100% | 74 s / 80 s |
| qwen2.5:7b | 4 | 88% | 1.6 | 92% | 14 s / 25 s |
| | 8 | 88% | 1.9 | 100% | 29 s / 41 s |
| | 13 | 100% | 2.4 | 100% | 50 s / 65 s |
| | 20 | 100% | 3.1 | 100% | 87 s / 107 s |
| | 30 | 88% | 2.9 | 100% | 146 s / 175 s |
| qwen2.5:14b | 8 | 75% | 1.8 | 100% | 61 s / 79 s |
| | 13 | 75% | 2.2 | 100% | 108 s / 129 s |
| | 20 | 88% | 3.4 | 100% | 190 s / 219 s |

Findings:

- `llama3.2:3b` rarely cites sources at any excerpt count, which is why its
  answers show no Sources list. Numbers it states are grounded, but the user
  cannot see where they came from.
- `qwen2.5:7b` cites reliably from 8 excerpts on and cites more distinct
  sources up to 20; 30 excerpts added time without more sources.
- `qwen2.5:14b` was no better than the 7b on these measures and about twice as
  slow.

## 4. A citation reminder at the end of the prompt fixes small-model citing

Same 8 questions on `llama3.2:3b`, two runs each (32 answers per row), before
and after adding one fixed line after the question
(`PromptAssembler.citationReminder`, docs/prompt-contract.md §5). The rule in
the system prompt was unchanged.

| Prompt | Excerpts | Cited | Valid sources per answer | Answer length | Time |
|---|---|---|---|---|---|
| without reminder | 8 | 0% | 0.0 | 407 chars | 8 s |
| | 13 | 0% | 0.0 | 425 chars | 13 s |
| with reminder | 8 | 87% | 1.8 | 648 chars | 13 s |
| | 13 | 93% | 3.1 | 1,110 chars | 32 s |

- The reminder took the 3b model from rarely citing (0% here, 12-25% in §3)
  to citing almost always, at the recommended 8 excerpts.
- Answers got longer, which is most of the added time. At 13 excerpts one
  answer ran on and emitted 23 markers for sources that don't exist; the panel
  drops those silently. 8 excerpts stays the small-model recommendation.
- Not re-measured on `qwen2.5:7b` or `14b` (they were removed after §3); they
  already cited reliably without the reminder.
- When an answer still cites nothing, the panel lists the emails the model was
  given under "Not cited by the model", so no answer is left without a way back
  to its material.

## What the app does with this

- `TokenAdvisor.recommendLocal`: 8 excerpts for models under 4.5B parameters
  (prompt kept under ~8k tokens), 13 for larger ones; context is the excerpts'
  tokens with 25% headroom, capped to what the Mac's GPU limit and the model's
  own window allow.
- Settings shows a memory gauge only when the model's architecture is known
  (read from `/api/show`); otherwise no memory figure, never a guess.
- A note appears for models under 4.5B parameters about citations and long
  prompts.
- Every prompt ends with the citation reminder from §4.

## Limits of these measurements

- One Mac, one Ollama version, three models from two families; the KV formula
  assumes f16 cache and ignores sliding-window savings (so it can overstate).
- 8 questions and one run per cell. "Cited" and "grounded" are proxies for
  answer quality, not correctness; no human ranking was done.
- The long-context test is synthetic and small (3 to 6 runs per cell); treat
  it as a signal, not a ranking.
