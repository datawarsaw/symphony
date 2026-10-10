# M1-D Dispatch Wiring Record

Task: one bounded production dispatch path from an explicitly authorized
Symphony issue to the existing OpenCode adapter, preserving every safety and
containment invariant. No live pilot, no real provider execution, no Codex
worker execution; redactor (be77946) and configuration-hardening (80028c4)
candidates were NOT imported.

## Assembly identity

- Worktree: `C:/AI/symphony-workspaces/m1-integration-assembly`
- Branch: `integration/m1-candidate-assembly`
- Base: `8b329e4` (M1-I0 assembly record tip), verified clean at start
- Implementation commit: see `git log -1` in the worktree

## Design

The harness decision lives at the orchestrator's dispatch boundary, exactly
where the MIC-195 route intent is decided. `HarnessSelection` stays the pure
production selector (its contract reserves wiring to the caller):

- `Orchestrator.spawn_issue_on_worker_host/6` calls `dispatch_harness/1` ONCE
  per dispatch attempt, on the same refreshed issue the route intent used.
  `{:opencode, pilot}` snapshots the validated pilot section (provider, model,
  tool allowlist, timeout) into the dispatch opts; every other outcome
  (`:codex`, reason) keeps the pre-existing Codex path byte-for-byte,
  including `DispatchRouter.materialize/3` and `Selection` (no `worker_type`
  field was added).
- `AgentRunner` branches on the pinned `harness: :opencode` opt after
  workspace preparation, hooks, and provenance capture. The OpenCode branch
  reuses the first-turn prompt contract, forwards `issue_id`/`attempt_id`/
  `identifier`/boot-pinned `authority_root` into the adapter, and connects
  streaming events through the existing `worker_event_callback/3` seam
  (WorkerEvent accumulator: order-preserving, duplicate-step dedupe,
  cumulative usage, `successful_completion?: false`).
- Termination evidence follows MIC-223 ordering: the adapter's confirmation
  is published to the orchestrator's `{:worker_termination, _, _}` channel
  from the task process before it exits, on success and failure alike.
  Completion authority stays with the adapter's `run_result`
  (`completion_state` + exit 0 + no failure evidence + `TERMINATED_CONFIRMED`);
  streaming events alone never mark success.
- Failures classify through `OpenCode.Failure` (never the Codex AppServer
  reason mapper) and raise the same `AgentRunner.FailureError`, so the retry/
  park envelope, reconciliation boundaries, and fallback latching are
  unchanged. A latched `:fallback` route cannot hijack an authorized issue:
  the harness decision is re-evaluated per dispatch attempt from
  configuration and never silently degrades to Codex.
- Same-issue concurrency prevention is structural and harness-agnostic: the
  running map and claim set are keyed by issue id.
- The durable LaunchMarker identity now carries `"harness": "opencode"` for
  OpenCode launches (additive key; Codex identities stay byte-identical,
  fence verdicts still read only receipt evidence — marker compatibility
  unchanged, `schema_version` still 1).
- `LaunchMarker.reuse_gate` before launch and `cleanup_gate` before
  destructive cleanup were already wired issue-keyed at the orchestrator;
  the OpenCode path funnels into the same gates through the adapter's
  pre-launch marker record and fence-accepted-only clearing.
- New test seam: `:opencode_executable` app env (mirrors `:jobrun_helper_path`)
  so dispatch-level tests target the offline mock without a production
  config surface for commands.

OpenCode remains disabled by default: no shipped `config/*.exs` carries an
`opencode` section, the schema defaults `enabled: false`, and authorization
requires the per-issue allowlist plus pinned provider/model/tools.

## Changed files

- `elixir/lib/symphony_elixir/orchestrator.ex` — dispatch-time harness
  selection, pinned pilot snapshot into dispatch opts, `harness` in the
  running entry and dispatch logs, `dispatch_harness_for_test/1` seam.
- `elixir/lib/symphony_elixir/agent_runner.ex` — OpenCode worker branch,
  snapshot fail-closed validation, termination-evidence publication,
  harness-aware failure classification.
- `elixir/lib/symphony_elixir/opencode/adapter.ex` — `harness: :opencode`
  launch-identity metadata; `:opencode_executable` app-env seam.
- `elixir/lib/symphony_elixir/worker_containment.ex` — optional `:harness`
  identity key (additive).
- `elixir/test/symphony_elixir/opencode_integration_smoke_test.exs` — m1-t
  assertions reconciled to the assembled contracts (see below).
- `elixir/test/symphony_elixir/opencode_dispatch_test.exs` — NEW focused
  dispatch-wiring suite (15 tests).

## m1-t assertion reconciliation (M1-I0 blockers 1–3)

1. Authored flunk gate "production OpenCode worker selection is not the
   fixture router" replaced with real assertions against the assembled
   production selector (`HarnessSelection.select/2`) and the orchestrator
   dispatch seam, including the Codex default and the no-`worker_type`
   invariant on `DispatchRouter.Selection`.
2. `summary.status` corrected to `summary.completion_state` — the i1
   `run_result` contract is authoritative; no redundant public field added.
3. `identity:`/pre-built-identity opts corrected to the adapter's
   `issue_id:`/`attempt_id:`/`identifier:`/`authority_root:` contract; the
   test now also asserts the marker's OpenCode harness metadata.

## Validation (offline, local mocks only)

Environment: Windows, Elixir 1.19.5-otp-28 / Erlang OTP 28, csc.exe mock and
jobrun Job-Object containment; no network, provider, credential, or Codex
worker access.

Passing:

- `opencode_dispatch_test.exs` (NEW, 15): authorized dispatch end-to-end
  (events, ordering, cumulative usage, termination evidence, marker
  lifecycle), harness metadata in the durable marker, live-marker blocking
  of reuse AND cleanup, provider-error classification (:model_unavailable),
  timeout (:runtime_unavailable), missing-snapshot fail-closed with
  NEVER_STARTED evidence and no stranded marker, harness-marked updates,
  latched-fallback never replaces a selected OpenCode harness, same-issue
  concurrency prevention, interrupted-run fencing.
- `opencode_test.exs` (64), `worker_event_test.exs` + `orchestrator_status_test.exs`
  (87), `harness_selection_test.exs` + `opencode_config_test.exs` +
  `dispatch_router_test.exs` (45), `opencode_integration_smoke_test.exs` (8,
  previously 3 authored/contract failures) + `opencode_smoke_harness_test.exs`
  (18), `retry_envelope_test.exs` (23), `launch_marker_test.exs` +
  `launch_fence_test.exs` + `launch_diagnostics_test.exs` +
  `parked_recovery_test.exs` (59), `restart_reconciliation_test.exs` +
  `source_canonicality_test.exs` (17 of 18; see below).
- `mix compile` clean for all changed modules (only the pre-existing known
  warnings: Phoenix colocated-JS `:eperm` and the candidate-inherited
  duplicate `containment_yaml/1` clauses in test support).

Still failing — all verified IDENTICAL at clean HEAD 8b329e4 (stash-compare),
i.e. pre-existing assembly/baseline conditions, not introduced by M1-D:

- `core_test.exs`: 11 failures (fake-Codex shell/app-server fixtures and
  retry fixtures that omit `termination_expectation`, which the
  expectation-aware MIC-223 reuse gate parks instead of retrying).
- `fallback_routing_test.exs`: 21 failures, same fixture mechanism.
- `discovery_integration_test.exs`: 1 failure (expects bare `RuntimeError`;
  `AgentRunner.run/3` wraps errors in `FailureError` on this assembly).
- One seed-dependent flake observed once across the launch suites; 59/59
  pass with a fixed seed.

Unresolved review dependencies (not imported, per task constraints):

- Redactor F2 remediation candidate `be77946` (i1-utf8 redaction).
- OpenCode configuration-hardening candidate `80028c4`.
- The core/fallback fixture modernization (`termination_expectation`) and
  the discovery RuntimeError expectation live on separate test-branch
  changes that are pending against the same baseline.

## Verdict

READY_FOR_INDEPENDENT_REVIEW
