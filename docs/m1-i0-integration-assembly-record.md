# M1-I0 Integration Assembly Record

Task: isolated assembly of pinned M1 candidate revisions into one technical
integration worktree, with a reproducible offline compilation and focused-test
baseline. No production dispatch wiring, no live workers, no OpenCode enablement.

## Assembly identity

- Worktree: `C:/AI/symphony-workspaces/m1-integration-assembly`
- Branch: `integration/m1-candidate-assembly`
- Canonical baseline: `c90e2ad71a70310e6d71b94777f6cbaca081b6c5`
  (verified equal to the source worktrees' merge base for all four candidates)
- Assembly tip after this record: see `git log -1` in the worktree
  (mock-union refinement: `37ad045`; final merge commit: `f67b241`)

Pre-merge verification performed:

- All four pinned heads matched their branch refs exactly; every candidate
  descends from `c90e2ad`; all source worktrees were clean (`status --porcelain`
  empty). No dependency changes vs baseline (`mix.exs` / `mix.lock` untouched
  by any candidate).

## Imported revisions (full ancestry, applied via `--no-ff` merges in dependency order)

Merge 1 — `d009bc7` — i1 OpenCode adapter / LaunchMarker gating / redactor (`b5cbd2b`):

| SHA     | Subject |
|---------|---------|
| `58cd85c` | Implement bounded OpenCode worker adapter with P0 safety remediations |
| `01d2bb8` | Fail closed the OpenCode worker launch boundary |
| `5df80de` | Fix OpenCode completion semantics and malformed-line redaction |
| `da78cbf` | Gate OpenCode worker launches behind the durable LaunchMarker |
| `b5cbd2b` | Fix OpenCode evidence redaction UTF-8 truncation and byte bounding |

Merge 2 — `aa9394e` — fm1-a WorkerEvent contract (`ef2aacf`):

| SHA     | Subject |
|---------|---------|
| `ba7a97b` | FM1-A: Introduce harness-neutral worker event contract and activity normalization |
| `c89905c` | FM1-A: Correct WorkerEvent terminal, token, and redaction semantics |
| `beb592e` | FM1-A: Bound UTF-8 evidence safely and keep stale messages out of status |
| `ef2aacf` | FM1-A: Release callback helpers after the final event |

Merge 3 — `0a8d541` — m1-c config / HarnessSelection (`2bdfefd`):

| SHA     | Subject |
|---------|---------|
| `371687c` | Add OpenCode pilot configuration and harness-selection policy |
| `2bdfefd` | Record M1-C OpenCode routing-gate candidate in project state |

Merge 4 — `f67b241` — m1-t offline smoke harness (`4e1e5f9`):

| SHA     | Subject |
|---------|---------|
| `15eb773` | M1-T: Implement deterministic offline OpenCode smoke test harness |
| `4e1e5f9` | test(m1): correct offline OpenCode smoke harness claims |

Merge order was forced by cross-candidate dependencies established before
merging: m1-t's integration smoke test calls `SymphonyElixir.OpenCode`,
`SymphonyElixir.OpenCode.Adapter`, `SymphonyElixir.LaunchMarker` (i1), and
`SymphonyElixir.WorkerEvent.from_opencode/1` (fm1-a). i1, fm1-a and m1-c are
pairwise file-disjoint; the only overlapping files are the two mock support
files shared by i1 and m1-t.

## Conflict resolutions

Both conflicts were add/add on test-support files, resolved during merge 4:

- `elixir/test/support/mock_opencode.exs` — took the m1-t version verbatim.
  Bodies are identical between candidates; only the moduledoc differs and the
  m1-t text is the informative superset.
- `elixir/test/support/windows/mock_opencode.cs` — took the m1-t version as
  the strict superset (all i1 modes retained: `stdin`, `env`, `argv`,
  `partial`, `malformed`, `malformed-secret`, `tool-calls-only`, `multi-step`,
  `tool-error`, `secret`, `success`, `error`, `hang`; harness additions:
  `single-turn`, `stalled`, `interrupted`, `tool-failure` alias, grandchild
  spawn, stop-file, exit-code/token/session argv and control-file overrides).
  Adapter-suite compatibility was verified against the exact assertions:
  stderr marker string unchanged, `not-json-at-all` retained as a prefix,
  `tool-error` exit code 0 retained, default token/cost values unchanged.
- Post-merge refinement (`37ad045`): `hang`/`stalled` without
  `--mock-stop-file` now sleeps a bounded 60s instead of looping forever.
  Reason: the i1 adapter suite includes remote/uncontained launches whose
  `stop_session` is `:NOT_APPLICABLE` (never killed locally); with the pure
  m1-t loop those mocks became permanent orphans (one observed holding the
  suite's stdout pipe open after the BEAM exited). The refinement restores
  the i1 candidate's self-exit bound while keeping m1-t's stop-file
  determinism. Adapter suite re-run after the change: 64/64 pass; the
  escaped mock self-terminated within the 60s bound.

## Compilation and focused-test baseline (offline)

Environment: Windows, Elixir 1.19.5-otp-28 / Erlang OTP 28, .NET Framework 4
`csc.exe` for the C# test doubles. Dependencies resolved from the local Hex
cache; no network provider, credential, Codex or worker access.

- `mix compile` — success ("Generated symphony_elixir app"). Only warnings:
  the known Windows Phoenix.LiveView colocated-JS symlink `:eperm` warning
  (environment; present across worktrees on this host) and the
  `containment_yaml/1` unreachable-clause warning in `test_support.exs`
  (candidate-inherited: the duplicated clauses already exist in the m1-c
  source worktree; cosmetic, not assembly-introduced).
- `mix test test/symphony_elixir/opencode_test.exs` (i1 adapter):
  64 tests, 0 failures (~48s; mock built via csc, Job-Object containment,
  LaunchMarker lifecycle paths exercised).
- `mix test test/symphony_elixir/worker_event_test.exs test/symphony_elixir/orchestrator_status_test.exs`
  (fm1-a): 87 tests, 0 failures.
- `mix test test/symphony_elixir/harness_selection_test.exs test/symphony_elixir/opencode_config_test.exs`
  (m1-c): 27 tests, 0 failures.
- `mix test test/symphony_elixir/opencode_integration_smoke_test.exs test/symphony_elixir/opencode_smoke_harness_test.exs`
  (m1-t against the assembled tree): 26 tests, 3 failures, 23 pass.

Failure classification for the m1-t suites (introduced vs pre-existing):

1. `production OpenCode worker selection is not the fixture router` — an
   authored `flunk/1` integration gate. The message itself states production
   `DispatchRouter` selection of OpenCode workers is not assembled. Expected
   under M1-I0 constraints (no DispatchRouter integration). Not a defect.
2. `production OpenCode.run executes mock worker with deny-by-default config`
   — interface mismatch: the test asserts `summary.status == :completed`, but
   the i1 adapter's `run_result` contract has `:completion_state` (required)
   and no `:status` key. The run itself succeeded (worker executed, natural
   exit, `TERMINATED_CONFIRMED`, usage parsed) — only the summary-key naming
   differs between the m1-t expectations and the i1 implementation.
3. `production OpenCode.Adapter gates launches behind durable LaunchMarker`
   — interface mismatch: the test passes a pre-built `identity:` opt (plus
   `authority_root:`) and expects a marker keyed by that identity's issue id;
   the i1 adapter ignores `identity:`, derives its identity from
   `issue_id:`/`attempt_id:` opts, and launches unfenced (no marker) when no
   `issue_id:` is given. The test provides none, so no marker is recorded.

All three failures are candidate-contract divergences or authored gates, not
regressions introduced by the assembly: none involves mock behavior, and each
assertion targets a module contract that only exists in the integrated tree.
The integration-gated suite has NOT passed and must not be reported as
passing.

## OpenCode disabled — dispatch-path audit

- No shipped config file (`config/*.exs`) contains an `opencode` section;
  the m1-c schema defaults `enabled: false` and fails closed (an enabled
  section must name provider, model and allowed tools, must not grant
  unrestricted tools, and authorizes no issue with an empty allowlist).
- `SymphonyElixir.HarnessSelection` is a pure policy module; it launches
  nothing and is not referenced by dispatch. Codex is the default and the
  fail-closed answer.
- `DispatchRouter.materialize/3` accepts only `:primary` and `:fallback`
  (guard clause); no OpenCode intent exists.
- No module outside `lib/symphony_elixir/opencode*` references
  `SymphonyElixir.OpenCode.*`; the only other lib mentions are the fm1-a
  WorkerEvent docstring/normalizer (`from_opencode/1`, a pure mapper) and
  orchestrator event-contract guards that treat `harness: :opencode`
  observations fail-closed (terminal events must not grant completion).
  `AgentRunner` mentions OpenCode in a docstring only.
- No live workers, provider calls, or credential access occurred during this
  assembly; every executed OpenCode path used the locally compiled mock or
  C# stdio host test double.

## Remaining interface blockers (reconciliation, not assembly)

1. Production dispatch wiring: `DispatchRouter`/`AgentRunner` cannot select
   or launch an OpenCode worker (authored gate, intentionally unassembled).
2. Run-summary contract: m1-t expects `summary.status`; i1 provides
   `:completion_state`. Reconcile to one naming before the gated suite can
   pass.
3. Session-identity contract: m1-t passes a pre-built `identity:` opt;
   i1's `Adapter.start_session` accepts only `issue_id:`/`attempt_id:`/
   `identifier:` and self-derives identity (unfenced when `issue_id` is
   absent). Reconcile the identity/marker-root contract.
4. Redactor F2 remediation and config hardening are under independent
   development and are not part of this assembly; nothing here may be read
   as evidence that those candidate reviews passed.
5. Cosmetic: duplicate `containment_yaml/1` clauses in `test_support.exs`
   inherited from the m1-c candidate produce an unreachable-clause warning.

## Verdict

ASSEMBLED_PENDING_RECONCILIATION
