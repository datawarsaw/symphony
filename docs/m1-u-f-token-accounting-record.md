# M1-U-F — OpenCode Token Usage Accounting Correction

Reference commit: `9ce11fd3a9db817d1930e372749fd13ce4b08951`
Candidate commit: `6c14953ba6459c86d8c910cfaeec0329e6b24e22`
Remediation branch: `m1-u-f2/token-accounting-remediation` (M1-U-F2, corrects
the M1-U-R `CHANGES_REQUIRED` findings against the candidate)

## Wire contract (verified against the exact upstream tag)

Upstream: `anomalyco/opencode` (`github.com/sst/opencode` redirects there),
tag `v1.18.28` = commit `22006d97652839999596a34a48ff6be7dbb40c6e`
(blob identifiers below are `git ls-tree` hashes at that commit).

Emitted CLI fields — what `opencode run --format json` writes for
`step_finish`:

- `packages/opencode/src/cli/cmd/run.ts`
  (blob `cccc2550179f87bb74763004910028f79ade60c9`) — `emit("step_finish",
  { part })` stringifies `{type, timestamp, sessionID, part}` and passes the
  session part through verbatim.
- `packages/core/src/session/runner/publish-llm-event.ts`
  (blob `33652a618c93ebc6edd1a54410983d361e8f5e48`) — the `tokens()` helper
  builds the step settlement strictly as `{input: nonCachedInputTokens,
  output: visibleOutputTokens, reasoning, cache: {read, write}}`. Any
  provider total is discarded here; **no `total` key is emitted on the
  v1.18.28 CLI step-finish wire** (verified, not inferred).
- `packages/schema/src/session-event.ts`
  (blob `3a559c3e38a401218ac36e3f79051172df4dbe3d`) — the internal
  `Step.Ended` schema's `tokens` struct has no `total` field at all, and
  `packages/core/src/session/message-updater.ts`
  (blob `46118a89fe4bea5aa13ef585b154626cc069980f`) copies it verbatim into
  the assistant message part that the CLI re-emits.

Optional schema fields — legal on the wire even though v1.18.28 never
produces them:

- `packages/schema/src/v1/session.ts`
  (blob `75e9282f117cb25078b087661434fcf5e6660620`) — `StepFinishPart.tokens`
  declares `total: Schema.optional(Schema.Finite)` (and the message-level
  `tokens` struct likewise). A decoder must therefore still accept and honor
  a `total` if some other producer, plugin, or future version supplies one.

Provider-side semantics:

- `packages/llm/src/schema/events.ts` (`LLM.Usage`,
  blob `98fcc9a24d417e70589e529fa1a1dd21ef35769c`) documents the five
  categories as non-overlapping:
  `nonCachedInputTokens + cacheReadInputTokens + cacheWriteInputTokens = inputTokens`
  and `reasoningTokens ≤ outputTokens` (wire `output` is the visible output,
  i.e. output minus reasoning).
- `packages/llm/src/protocols/shared.ts` (`totalTokens` policy,
  blob `173dc511bb034c52647d8f61faec4ab9826ecb18`) — `if (total !==
  undefined) return total`: a provider-supplied total (including 0) is the
  source of truth; the input+output fallback "under-counts cache and
  reasoning by design".

Reconstructed fixtures: every Symphony test fixture or mock event that
includes a `tokens.total` key is a reconstruction of the optional-schema
case, not a capture of v1.18.28 CLI output. Fixtures without `total`
(`OpenCodeWorkerFixture.single_turn_jsonl/1`, `multi_step_jsonl/1`, …)
match the emitted CLI field set.

## Accounting contract (single contract, all consumers)

1. **Per-step total**: an explicitly supplied valid non-negative integer
   `part.tokens.total` — **including an explicit `0`** — takes precedence
   and is honored as-is (it is inclusive of every category and must never be
   added on top of them). A missing **or malformed** total (absent, `nil`,
   string, negative, non-integer) uses the additive sum
   `input + output + reasoning + cache.read + cache.write`, because the five
   wire categories are non-overlapping by construction. The same guard
   (`is_integer and >= 0`) is applied in `Parser.step_total/6`,
   `WorkerEvent.opencode_total/6`, and `Orchestrator.step_token_delta/2`.
2. **Cumulative total**: the sum of per-step totals over accepted
   `step_finish` events. A repeated step identity is rejected by the
   `WorkerEvent` accumulator (`event_id`/`seen`) and never adds usage again.
3. **Missing totals / empty categories**: a step without a `tokens` object
   (or with all categories absent/zero) contributes 0; totals default to 0.
4. **Raw categories preserved**: `input_tokens`, `output_tokens`,
   `reasoning_tokens`, `cache_read_tokens`, `cache_write_tokens` are kept
   exactly as reported. Cost accounting is unchanged (per-step `cost` sum).

## Before / after for representative events

"Before" is the reference commit `9ce11fd` (input + output only, explicit
wire total ignored); "Candidate" is `6c14953`; "After" is this remediation.

| Event (wire) | Before | Candidate | After |
| --- | --- | --- | --- |
| Single step: in=50, out=150, reas=20, cache r=10 w=5, no total | 200 | 235 | 235 |
| Multi-step: (40,60,r10,cr5,cw5) then (60,90,r15,cr10,cw5) | 250 | 300 (120 + 180) | 300 |
| Cached-heavy single turn: in=100, out=200, reas=25, cr=50, cw=10 | 300 | 385 | 385 |
| Explicit total: categories sum 235, wire total=240 | 200 (total ignored) | 240 (honored) | 240 |
| **Explicit total 0** with categories summing 235 | 200 | Parser 0, **WorkerEvent 235** (0 treated as missing) | 0 everywhere (explicit 0 wins) |
| **Malformed total** (`"240"`, `-5`, `12.5`) with categories summing 235 | 200 | 235 (additive fallback) | 235 (additive fallback, verified) |
| Fragmented stream: in=12, out=34, no other categories | 46 | 46 | 46 (unchanged) |

The `tokenUsage.total.totalTokens` update field, the parser result map, and
the cumulative delta path in `Orchestrator.step_token_delta/2` all follow
the same contract. The candidate's `to_update/1` recomputed the total
whenever it read `0` alongside non-zero input/output, which silently
replaced an honored explicit zero for OpenCode events; `to_update/1` now
trusts the already-normalized OpenCode contract total and keeps the legacy
zero-total heuristic only for Codex-shaped usage.

## Changed modules

- `SymphonyElixir.OpenCode.Parser` — per-step `step_total/6` (explicit or
  additive); nil-safe `tokens` read. (Unchanged by M1-U-F2; already honored
  explicit `0`.)
- `SymphonyElixir.WorkerEvent` — `normalize_opencode_tokens/2` per-step
  total; `add_usage/2` cumulative total sums per-step totals instead of
  recomputing `input + output`; `to_update/1` trusts the OpenCode contract
  total (M1-U-F2: `opencode_total/6` now honors an explicit `0` via the
  same integer guard as the Parser instead of requiring `> 0`; the codex
  zero-total heuristic is preserved unchanged).
- `SymphonyElixir.Orchestrator` — `step_token_delta/2` fallback is additive
  across the five categories (only fires when a total is missing).
  (Unchanged by M1-U-F2; already honored explicit `0`.)
- Test support: `OpenCodeWorkerFixture.calculate_cumulative_usage/1` (the
  test oracle) implements the same contract.

## Focused validation

- `mix test test/symphony_elixir/opencode_test.exs` (71 tests) — the
  "Token usage accounting (OpenCode wire contract)" describe covers missing,
  explicit (positive and **zero**), and **malformed** totals, caching,
  reasoning, and multi-step cumulative accounting.
- `mix test test/symphony_elixir/worker_event_test.exs` (43 tests) — the
  "OpenCode token usage accounting contract" describe covers additive
  per-step, explicit total (positive and zero), malformed totals, cumulative
  with cache/reasoning and explicit zeros, repeated identity, `to_update`
  tokenUsage (including explicit zero), a Parser/WorkerEvent agreement
  matrix over every total shape, and preserved Codex token accounting.
- `mix test test/symphony_elixir/opencode_smoke_harness_test.exs`,
  `opencode_dispatch_test.exs`, `orchestrator_status_test.exs`,
  `opencode_integration_smoke_test.exs`.
- `MIX_ENV=test mix compile --warnings-as-errors`; `mix format
  --check-formatted` on changed files; `mix credo --strict` on changed
  modules returns to baseline finding counts.

Note: `test/symphony_elixir/opencode_dispatch_test.exs` has a pre-existing
`mix format` diff at its setup block on the reference commit; it is
untouched by this change.

## Compatibility

- Codex paths are unchanged: `from_codex/2` normalization keeps an explicit
  total and falls back to input+output only when both are present, the
  legacy zero-total-with-usage heuristic in `to_update/1` still applies to
  Codex-shaped usage, and the orchestrator's absolute/direct usage
  extraction paths are untouched.
- OpenCode totals rise for any stream with nonzero reasoning or cache
  categories; streams without them report identical totals.
- No parser error handling, session semantics, dispatch wiring, or retry
  behavior changed.
