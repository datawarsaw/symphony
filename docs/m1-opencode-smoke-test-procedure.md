# M1 OpenCode Worker Smoke Test & Acceptance Procedure

## 1. Overview and Purpose

This document specifies the deterministic offline smoke test harness and the smallest offline and live acceptance procedures for Symphony's first OpenCode worker integration (Milestone M1).

Symphony integrates the OpenCode execution engine as an alternative worker implementation while maintaining strict parity with existing Codex lifecycle, containment, and safety guarantees:
- Windows Job Object containment (`KILL_ON_JOB_CLOSE`, breakaway denied)
- Positive termination receipt verification (`tree_drained: true`, conclusive terminal reason)
- Zero orphaned processes
- Issue-keyed durable `LaunchMarker` pre-launch gating and fail-closed resume/cleanup fences
- Harness-neutral `WorkerEvent` normalization with cumulative multi-step token and cost accounting
- Deny-by-default tool execution and credential allowlisting
- Seamless fallback and rollback to Codex when OpenCode is disabled or unconfigured

---

## 2. Baseline and Reference Revisions

- **Accepted Baseline:** `c90e2ad71a70310e6d71b94777f6cbaca081b6c5` (`datawarsaw/symphony` main)
- **Reference Candidate (OpenCode Adapter):** `5df80de937816352ffaebdf125a978eb9f15c85e` / `da78cbf45cbcb0175b0e9124683b41b45e04b6fb`
- **Reference Candidate (WorkerEvent):** `c89905c1117edc8ccf18f75ebca097b8b4a87714`

---

## 3. Test Harness Architecture

The M1 smoke test infrastructure consists of four isolated modules:

1. **Deterministic Mock Worker Executable Source (`elixir/test/support/windows/mock_opencode.cs`):**
   - In-box C# source compiled deterministically via `csc.exe` into `test/support/windows/bin/mock_opencode.exe`.
   - Supports CLI flags (`--mock-mode`, `--mock-sleep`, `--mock-tokens-in`, `--mock-tokens-out`, `--mock-tokens-reasoning`, `--mock-cost`, `--mock-exit-code`, `--mock-grandchild-exe`) and control file (`opencode-mock-control.txt`).
   - Simulates:
     - `single-turn` / `success`: Emits valid `step_start`, `tool_use`, and `step_finish` (reason: `stop`).
     - `multi-step`: Emits intermediate `step_finish` (reason: `tool-calls`), intermediate tool calls, and final terminal `step_finish` (reason: `stop`).
     - `tool-failure` / `tool-error`: Emits `tool_use` with `state: {"status":"error", "error":"..."}`.
     - `malformed` / `malformed-secret`: Emits unparseable lines and embedded secrets to test redactor and parser resilience.
     - `stalled` / `hang`: Flushes `step_start` and stalls to test bounded containment timeouts.
     - `interrupted`: Emits partial text and exits abruptly with exit code 130 without a terminal event.
     - `grandchild-orphan`: Spawns background process to test Job tree containment.

2. **Test Support Fixture (`elixir/test/support/opencode_worker_fixture.exs` & `mock_opencode.exs`):**
   - Reusable Elixir helper `SymphonyElixir.TestSupport.OpenCodeWorkerFixture` providing event streams, cumulative token calculations, Windows Job containment invocation via `WorkerContainment`, OS process death probes via `tasklist`, and LaunchMarker lifecycle verifications.

3. **Standalone Smoke Test Suite (`elixir/test/symphony_elixir/opencode_smoke_harness_test.exs`):**
   - 13 comprehensive checks executable against the accepted baseline without any production changes.
   - Covers all simulation modes, Job containment death receipts, LaunchMarker gates, cumulative accounting, zero orphaned processes, and Codex rollback.

4. **Integration-Dependent Smoke Test Suite (`elixir/test/symphony_elixir/opencode_integration_smoke_test.exs`):**
   - Tagged with `@moduletag :opencode_integration`.
   - Verifies the wiring between production `OpenCode.Adapter`, `WorkerEvent`, and the mock worker.
   - Fails visibly on the baseline identifying missing integration commits, and passes once the integration branch is wired.

---

## 4. Smallest Offline Acceptance Procedure

### Phase A: Validate Standalone Harness on Baseline
Run the standalone harness in the worktree:
```bash
cd elixir
mix test --exclude opencode_integration test/symphony_elixir/opencode_smoke_harness_test.exs
```
**Expected Result:**
- 13 tests passing, 0 failures.
- Verifies deterministic mock binary compilation, single-turn and multi-step JSONL output, cumulative token accounting, tool failure handling, malformed JSON stream handling, confirmed and unconfirmed containment receipts, zero orphaned processes, LaunchMarker lifecycle, and Codex rollback.

### Phase B: Verify Integration Readiness Gate
Run the integration-dependent suite before merging adapter branches:
```bash
mix test --only opencode_integration test/symphony_elixir/opencode_integration_smoke_test.exs
```
**Expected Result:**
- Exactly 5 failures explicitly identifying that `SymphonyElixir.OpenCode.Adapter` (`5df80de` / `da78cbf`) and `SymphonyElixir.WorkerEvent` (`c89905c`) are pending merge.

### Phase C: Post-Merge Verification (Once Integration Branch is Wired)
After merging the OpenCode adapter and WorkerEvent commits:
```bash
mix test test/symphony_elixir/opencode_smoke_harness_test.exs test/symphony_elixir/opencode_integration_smoke_test.exs
```
**Expected Result:**
- 18 tests passing, 0 failures.

---

## 5. Smallest Live M1 Acceptance Procedure

Do not execute this live test until the offline integration passes completely and approval is granted.

### Prerequisites:
1. OpenCode CLI binary (`opencode.exe` or `opencode`) installed on host and verified via `opencode --version`.
2. Valid provider credentials available (e.g. `ANTHROPIC_API_KEY` or `OPENAI_API_KEY`).
3. Symphony configured with `worker_containment_enabled: true` on Windows host.

### Execution Steps:
1. **Prepare Synthetic Test Issue:**
   - Create an issue with label `worker:opencode` and `model:claude-3-5-sonnet`.
   - Description containing a simple bounded task (e.g., "Write HELLO into test_smoke.txt").
2. **Launch Worker Under Symphony:**
   - Trigger worker dispatch for the test issue.
   - Verify log shows `DispatchRouter` selecting OpenCode worker (`worker_type: :opencode`).
3. **Verify Pre-Launch Fence:**
   - Verify that `<workspace_root>/.symphony-state/launches/<issue_id>.json` exists with non-empty `launch_id` and `wrapper_pid` before task completes.
4. **Observe Streaming Events:**
   - Verify delivery of `step_start`, `tool_use`, and terminal `step_finish` events.
   - Verify token usage is reported and recorded in the orchestrator status ledger.
5. **Verify Process Termination & Cleanup:**
   - Observe worker completion (exit code 0).
   - Verify `<workspace_root>/.symphony-state/receipts/<launch_id>.json` contains `"tree_drained": true` and terminal reason `"NATURAL_EXIT"`.
   - Verify `<workspace_root>/.symphony-state/launches/<issue_id>.json` is deleted on confirmed exit.
   - Run `tasklist /FI "IMAGENAME eq opencode*"` to verify 0 residual processes.
6. **Verify Rollback to Codex:**
   - Remove the `worker:opencode` label or set `opencode.enabled: false` in Symphony configuration.
   - Re-dispatch issue and verify `DispatchRouter` cleanly selects the default Codex route (`gpt-6-astra`, medium reasoning).

---

## 6. M1 Exact Acceptance Criteria Matrix

| Criterion | Verification Method | Offline Smoke Test | Live M1 Verification |
|---|---|:---:|:---:|
| **Deterministic Mock Fixture** | Compiles via in-box csc.exe, produces predictable output across all 7 required modes | PASS | N/A |
| **LaunchMarker Pre-Launch Gate** | Marker recorded before child exists; unconfirmed receipt blocks reuse | PASS | Required |
| **Windows Job Containment** | Runs under jobrun wrapper, KILL_ON_JOB_CLOSE prevents breakaway | PASS | Required |
| **Zero Orphaned Processes** | Grandchild process killed along with worker on job termination | PASS | Required |
| **Token & Cost Accounting** | Cumulative input/output/reasoning/cache tokens accurately aggregated across multi-step turns | PASS | Required |
| **Fail-Closed Malformed Stream** | Corrupt JSON and secrets handled without parser crash or secret leakage | PASS | Required |
| **Issue-to-Worker Routing** | Explicit label/opts routes to OpenCode; disabled setting rolls back to Codex | PASS | Required |
| **End-to-End Adapter Wiring** | OpenCode.Adapter & WorkerEvent normalize live execution | Awaiting Integration Branch | Required |

