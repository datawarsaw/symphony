# M1 OpenCode Worker Smoke Test & Acceptance Procedure

## 1. Overview and Purpose

This document specifies the deterministic offline smoke test harness and the smallest offline and live acceptance procedures for Symphony's first OpenCode worker integration (Milestone M1).

The production integration is intended to keep Codex lifecycle, containment, and safety behavior:

- Windows Job Object containment (`KILL_ON_JOB_CLOSE`, breakaway denied)
- Positive termination receipt verification (`tree_drained: true`, conclusive terminal reason)
- Zero orphaned processes
- Issue-keyed durable `LaunchMarker` pre-launch gating and fail-closed resume/cleanup fences
- Harness-neutral `WorkerEvent` normalization with cumulative multi-step token and cost accounting
- Deny-by-default tool execution and credential allowlisting
- No automatic provider fallback, and rollback to Codex only through the production router when OpenCode is disabled or unconfigured

The offline harness does not prove that whole list. A standalone PASS means the mock, the fixture, and the production utilities already on this baseline behaved as asserted. It does not mean secret redaction, production `DispatchRouter` selection, the no-fallback guarantee, JSONL wire compatibility, or BEAM restart recovery passed.

## 2. Baseline and Reference Revisions

- **Accepted Baseline:** `c90e2ad71a70310e6d71b94777f6cbaca081b6c5` (`datawarsaw/symphony` main)
- **Reference Candidate (OpenCode Adapter):** `5df80de937816352ffaebdf125a978eb9f15c85e` / `da78cbf45cbcb0175b0e9124683b41b45e04b6fb`
- **Reference Candidate (WorkerEvent):** `c89905c1117edc8ccf18f75ebca097b8b4a87714`

## 3. Test Harness Architecture

The M1 smoke test infrastructure consists of four isolated modules:

1. **Deterministic Mock Worker Executable Source (`elixir/test/support/windows/mock_opencode.cs`):**
   - In-box C# source compiled deterministically via `csc.exe` into `test/support/windows/bin/mock_opencode.exe`.
   - Supports CLI flags (`--mock-mode`, `--mock-sleep`, `--mock-tokens-in`, `--mock-tokens-out`, `--mock-tokens-reasoning`, `--mock-cost`, `--mock-exit-code`, `--mock-grandchild-exe`) and control file (`opencode-mock-control.txt`).
   - Simulates:
     - `single-turn` / `success`: Emits valid `step_start`, `tool_use`, and `step_finish` (reason: `stop`).
     - `multi-step`: Emits intermediate `step_finish` (reason: `tool-calls`), intermediate tool calls, and final terminal `step_finish` (reason: `stop`).
     - `tool-failure` / `tool-error`: Emits `tool_use` with `state: {"status":"error", "error":"..."}`.
     - `malformed` / `malformed-secret`: Emits an unparseable line. `malformed-secret` embeds raw secret bytes in that line. The mock does not redact them.
     - `secret`: Emits a valid `tool_use` whose output contains the same raw secret, then writes the raw secret to stderr. The mock does not redact either stream.
     - `error`: Emits a JSON `error` event (`ModelNotFoundError`) and exits nonzero. This is observed process failure only. It does not apply a no-fallback policy.
     - `stalled` / `hang`: Flushes `step_start` and stalls to test bounded containment timeouts.
     - `interrupted`: Emits partial text and exits abruptly with exit code 130 without a terminal event.
     - `grandchild-orphan`: Spawns a background process to test Job tree containment.

2. **Test Support Fixture (`elixir/test/support/opencode_worker_fixture.exs` & `mock_opencode.exs`):**
   - Reusable Elixir helper `SymphonyElixir.TestSupport.OpenCodeWorkerFixture`.
   - Event streams and cumulative token calculations are fixture accounting, not `WorkerEvent`.
   - Windows Job containment goes through the existing `WorkerContainment` helper.
   - OS PID probing is tri-state (`:alive`, `:gone`, `:unknown`) and follows `WorkerContainment.wrapper_liveness/1`. A failed or untrustworthy `tasklist` answer is `:unknown` and is not treated as death or as a clean tree.
   - `LaunchMarker` checks call the production `record/2`, `record_wrapper_identity/2`, `read/2`, `fence_verdict/2`, `reuse_gate/2`, `cleanup_gate/2`, and `clear/2` utilities.
   - `resolve_worker_route/2` is fixture-only. It does not call `DispatchRouter`.

3. **Standalone Smoke Test Suite (`elixir/test/symphony_elixir/opencode_smoke_harness_test.exs`):**
   - 18 checks executable against the accepted baseline without production changes.
   - Covers the mock modes above, Job containment death receipts, LaunchMarker gates, cumulative fixture accounting, positive orphan checks, tri-state probe failure, and the distinction between fixture routing and `DispatchRouter.materialize/3`.

4. **Integration-Dependent Smoke Test Suite (`elixir/test/symphony_elixir/opencode_integration_smoke_test.exs`):**
   - Tagged with `@moduletag :opencode_integration`.
   - These tests are not skipped and are not marked passed on this baseline.
   - Run on the baseline, all 8 fail and name the missing production gate.
   - Module-load gates can pass when the named functions from the adapter and WorkerEvent candidates are present. The production OpenCode routing gate stays red until a real selector exists and that test is aimed at it. `resolve_worker_route/2` must not be used to turn it green.

## 4. Smallest Offline Acceptance Procedure

### Phase A: Validate Standalone Harness on Baseline

Run the standalone harness in the worktree:

```bash
cd elixir
mix test --exclude opencode_integration test/symphony_elixir/opencode_smoke_harness_test.exs
```

**Expected Result:**

- 18 tests, 0 failures.
- This verifies mock compilation, single-turn and multi-step fixture JSONL, cumulative fixture token accounting, tool failure, raw `malformed-secret` and `secret` output, the `error` mock's nonzero exit and error event, confirmed and unconfirmed containment receipts, zero orphans when `tasklist` positively reports the PIDs gone, LaunchMarker lifecycle, simulated interruption that leaves the marker blocked, and fixture routing.
- It does not verify secret redaction, the production no-fallback guarantee, production OpenCode worker selection, a live OpenCode 1.18.28 stream, or recovery after a BEAM restart.

### Phase B: Verify Integration Readiness Gate

Run the integration-dependent suite separately:

```bash
mix test --only opencode_integration test/symphony_elixir/opencode_integration_smoke_test.exs
```

**Expected Result on this baseline:**

- 8 tests, 8 failures, 0 passes.
- Those failures are the gate. Do not count them as passing tests and do not exclude them in order to report a green integration run.
- Each failure names the missing module or the unwired behavior. The exact gates are listed in section 8.

### Phase C: Post-Assembly Verification

After the production modules named in section 8 are actually present:

```bash
mix test test/symphony_elixir/opencode_smoke_harness_test.exs test/symphony_elixir/opencode_integration_smoke_test.exs
```

Re-run Phase A and Phase B as separate commands first. Phase A should stay at 18 tests, 0 failures. Phase B stays red for any gate whose production function is still absent. Do not add the two totals together and call the integration failures passes.

The routing test in Phase B does not go green merely because `OpenCode.Adapter` loads. It goes green only when it calls the assembled production selector and that selector distinguishes OpenCode from Codex.

## 5. Smallest Live M1 Acceptance Procedure

Do not execute this live test until the offline integration gates in section 8 pass and approval is granted. This procedure is not part of the offline harness run.

### Prerequisites

1. OpenCode CLI binary (`opencode.exe` or `opencode`) installed on the host and verified via `opencode --version`.
2. Valid provider credentials available only in the approved live run (for example `ANTHROPIC_API_KEY` or `OPENAI_API_KEY`).
3. Symphony configured with `worker_containment_enabled: true` on a Windows host.

### Execution Steps

1. **Prepare a synthetic test issue.**
   - Create an issue with label `worker:opencode` and an explicit provider/model.
   - Description containing a simple bounded task (for example, "Write HELLO into test_smoke.txt").
2. **Launch the worker under Symphony.**
   - Trigger worker dispatch for the test issue.
   - Read the production dispatch log and confirm the assembled router selected the OpenCode worker. The offline fixture route is not this check.
3. **Verify the pre-launch fence.**
   - Verify that `<workspace_root>/.symphony-state/launches/<issue_id>.json` exists with non-empty `launch_id` and `wrapper_pid` before the task completes.
4. **Observe streaming events.**
   - Verify delivery of `step_start`, `tool_use`, and terminal `step_finish` events from the real CLI.
   - Verify token usage is reported and recorded in the orchestrator status ledger.
   - This live capture is the first point at which wire compatibility can be claimed. The offline mock is not that capture.
5. **Verify process termination and cleanup.**
   - Observe worker completion (exit code 0).
   - Verify `<workspace_root>/.symphony-state/receipts/<launch_id>.json` contains `"tree_drained": true` and a conclusive terminal reason.
   - Verify `<workspace_root>/.symphony-state/launches/<issue_id>.json` is deleted on confirmed exit.
   - Run `tasklist /FI "IMAGENAME eq opencode*"` and require a healthy no-match answer before claiming zero residual processes. A failed `tasklist` is unknown, not zero.
6. **Verify rollback to Codex.**
   - Remove the `worker:opencode` label or disable OpenCode in Symphony configuration.
   - Re-dispatch the issue and verify the production router selects the Codex route. Do not use `OpenCodeWorkerFixture.resolve_worker_route/2` as that evidence.

## 6. M1 Acceptance Claims

| Claim | What the offline harness actually shows | Offline result on this baseline | Live M1 |
|---|---|---|---|
| Deterministic mock fixture | `csc.exe` build and predictable output for the modes in section 3, including `secret` and `error` | PASS | N/A |
| LaunchMarker pre-launch gate | Production `LaunchMarker` utilities record before the child exists; an unconfirmed receipt blocks reuse and cleanup | PASS | Required |
| Simulated interruption | Interrupted mock exits 130 with no `step_finish`. The marker stays blocked (`fence_verdict` unknown, reuse and cleanup blocked). This is not a BEAM restart | PASS as simulation only | BEAM restart recovery still required |
| Windows Job containment | Runs under the jobrun wrapper and returns a confirmed receipt for the exercised paths | PASS | Required |
| Zero orphaned processes | Grandchild is gone only when `tasklist` positively reports it gone. Probe failure is `{:probe_unknown, _}`, not PASS | PASS for the positive case | Required |
| Token and cost accounting | Fixture helper sums `step_finish` tokens and cost across the mock multi-step stream | PASS for fixture JSONL | Required |
| Malformed stream and secrets | `malformed-secret` and `secret` emit raw secrets. Nothing in the standalone suite redacts them | NOT a redaction PASS | Required after the redactor gate |
| Error path | `error` mode emits `ModelNotFoundError` and exits 1. No fallback decision is made | Process failure only | No-fallback gate required |
| Issue-to-worker routing | `resolve_worker_route/2` is fixture-only. `DispatchRouter.materialize(:primary, issue, [])` returns a Codex `Selection` with no `worker_type` | NOT a production routing PASS | Required |
| JSONL wire compatibility | No stored `opencode run --format json` capture. See section 7 | NOT CLAIMED | Required |
| End-to-end adapter wiring | `OpenCode.Adapter`, `OpenCode.Redactor`, and `WorkerEvent` are absent on this baseline | 8 integration failures, 0 passes | Required |

## 7. JSONL Compatibility Notes

The mock and `OpenCodeWorkerFixture` emit a synthetic JSONL dialect used only by this harness: `step_start`, `tool_use`, `step_finish`, `text`, and `error`, with `sessionID`, `part.reason`, `part.tokens`, and `part.cost`. Those shapes are whatever `mock_opencode.cs` and the Elixir generators write. Tests that decode them prove the mock, not the OpenCode CLI.

Evidence checked while writing this note:

- This worktree has no captured `opencode run --format json` transcript and no fixture file recorded from a live CLI.
- The adapter candidate `5df80de` documents completion semantics as grounded in the OpenCode 1.18.28 `run --format json` event contract, in `SymphonyElixir.OpenCode.Parser`. That statement is a code comment in another worktree. Its unit tests build the same kind of synthetic events this harness builds.
- The only `1.18.28` assertion found there is a live CLI version check in `elixir/test/symphony_elixir/opencode_test.exs` (`assert version =~ "1.18.28"`) for a permission-override test. It does not store stdout JSONL.

No wire compatibility with OpenCode 1.18.28 is claimed here. A later live capture can be attached and compared. Until that file exists, do not describe the mock dialect as the 1.18.28 wire format.

## 8. Integration Gates To Run After Assembly

Run Phase B. Do not weaken these assertions to make the baseline green.

1. `SymphonyElixir.OpenCode.Adapter` is loaded. Candidate commits: `5df80de` / `da78cbf`.
2. `SymphonyElixir.OpenCode.run/3` executes the mock with an explicit provider and model and returns a completed summary.
3. `SymphonyElixir.OpenCode.Adapter.start_session/3` records a durable `LaunchMarker` before the child exists, and `stop_session/1` clears it only after confirmed termination.
4. `SymphonyElixir.WorkerEvent` is loaded. Candidate commit: `c89905c`. `WorkerEvent.from_opencode/1` normalizes the multi-step fixture stream, including a non-terminal `tool-calls` finish and a terminal `stop` finish.
5. `SymphonyElixir.OpenCode.Redactor.redact/1` is loaded and applied to real output from both `--mock-mode=malformed-secret` and `--mock-mode=secret`. The redacted text must not contain the raw `sk-ant-api03-` or `lin_api_` markers. Standalone presence of those markers is not this gate.
6. `SymphonyElixir.OpenCode.Adapter.validate_model_selection/1` rejects a bare model such as `claude-3-5-sonnet` and reports that automatic fallback is forbidden. The `error` mock's exit code 1 is not this gate.
7. Production worker selection, not `OpenCodeWorkerFixture.resolve_worker_route/2`, chooses an OpenCode worker from an explicit label or config and returns the Codex default when OpenCode is disabled. On this baseline `DispatchRouter.materialize/3` accepts only `:primary` and `:fallback`. The current integration test fails closed with that gate text until the test calls the assembled selector.

`AgentRunner`, `DispatchRouter`, `Orchestrator`, `WorkerEvent`, the OpenCode adapter, and `Config.Schema` are not modified by this harness.

