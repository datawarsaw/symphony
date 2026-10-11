# M1-U-F — OpenCode Token Usage Accounting Correction

Reference commit: `9ce11fd3a9db817d1930e372749fd13ce4b08951`
Branch: `m1-u-f/opencode-token-accounting`

## Wire contract (verified against OpenCode 1.18.28 source)

- `packages/core/src/session/runner/publish-llm-event.ts` builds the
  step-finish `part.tokens` strictly as
  `{input: nonCachedInputTokens, output: visibleOutputTokens, reasoning, cache: {read, write}}`.
  No `total` key is emitted on the v1.18.28 wire.
- `packages/llm/src/schema/events.ts` (`LLM.Usage`) documents the five
  categories as non-overlapping:
  `nonCachedInputTokens + cacheReadInputTokens + cacheWriteInputTokens = inputTokens`
  and `reasoningTokens ≤ outputTokens` (wire `output` is the visible output,
  i.e. output minus reasoning).
- `packages/llm/src/protocols/shared.ts` (`totalTokens` policy): a
  provider-supplied total is inclusive and is the source of truth when
  present; an input+output fallback "under-counts cache and reasoning by
  design".

## Accounting contract selected

1. **Per-step total**: an explicit non-negative integer `part.tokens.total`
   is honored as-is (it is inclusive of every category and must never be
   added on top of them). When absent, the total is the additive sum
   `input + output + reasoning + cache.read + cache.write`, because the five
   wire categories are non-overlapping by construction.
2. **Cumulative total**: the sum of per-step totals over accepted
   `step_finish` events. A repeated step identity is rejected by the
   `WorkerEvent` accumulator (`event_id`/`seen`) and never adds usage again.
3. **Missing totals / empty categories**: a step without a `tokens` object
   (or with all categories absent/zero) contributes 0; totals default to 0.
4. **Raw categories preserved**: `input_tokens`, `output_tokens`,
   `reasoning_tokens`, `cache_read_tokens`, `cache_write_tokens` are kept
   exactly as reported. Cost accounting is unchanged (per-step `cost` sum).

## Before / after for representative events

| Event (wire) | Before | After |
| --- | --- | --- |
| Single step: in=50, out=150, reas=20, cache r=10 w=5, no total | 200 | 235 |
| Multi-step: (40,60,r10,cr5,cw5) then (60,90,r15,cr10,cw5) | 250 | 300 (120 + 180) |
| Cached-heavy single turn: in=100, out=200, reas=25, cr=50, cw=10 | 300 | 385 |
| Explicit total: categories sum 235, wire total=240 | 200 (total ignored) | 240 (honored, not summed on top) |
| Fragmented stream: in=12, out=34, no other categories | 46 | 46 (unchanged) |

The `tokenUsage.total.totalTokens` update field, the parser result map, and
`codex_totals.total_tokens` (via the monotonic cumulative delta path in
`Orchestrator.extract_token_delta`) all follow the same contract.

## Changed modules

- `SymphonyElixir.OpenCode.Parser` — per-step `step_total/6` (explicit or
  additive); nil-safe `tokens` read.
- `SymphonyElixir.WorkerEvent` — `normalize_opencode_tokens/2` per-step
  total; `add_usage/2` cumulative total sums per-step totals instead of
  recomputing `input + output`; `to_update/1` fallback is additive across
  reported categories.
- `SymphonyElixir.Orchestrator` — `step_token_delta/2` fallback is additive
  across the five categories (only fires when a total is missing).
- Test support: `OpenCodeWorkerFixture.calculate_cumulative_usage/1` (the
  test oracle) implements the same contract.

## Focused validation

- `mix test test/symphony_elixir/opencode_test.exs` (69 tests) — includes
  the new "Token usage accounting (OpenCode wire contract)" describe:
  missing total, explicit total, caching, reasoning, multi-step cumulative.
- `mix test test/symphony_elixir/worker_event_test.exs` (37 tests) —
  includes the new "OpenCode token usage accounting contract" describe:
  additive per-step, explicit total, cumulative with cache/reasoning,
  repeated identity, `to_update` tokenUsage.
- `mix test test/symphony_elixir/opencode_smoke_harness_test.exs`,
  `opencode_dispatch_test.exs`, `orchestrator_status_test.exs`,
  `opencode_integration_smoke_test.exs`.
- `MIX_ENV=test mix compile --warnings-as-errors`; `mix format
  --check-formatted` on changed files; `mix credo --strict` on changed
  modules returns to baseline finding counts (one pre-existing long line in
  `to_update/1` is now fixed).

Note: `test/symphony_elixir/opencode_dispatch_test.exs` has a pre-existing
`mix format` diff at its setup block on the reference commit; it is
untouched by this change.

## Compatibility

- Codex paths are unchanged: `from_codex/2` normalization keeps an explicit
  total and falls back to input+output only when both are present, and the
  orchestrator's absolute/direct usage extraction paths are untouched.
- OpenCode totals rise for any stream with nonzero reasoning or cache
  categories; streams without them report identical totals.
- No parser error handling, session semantics, dispatch wiring, or retry
  behavior changed.
