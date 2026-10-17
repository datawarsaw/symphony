# M1-E Offline End-to-End Acceptance Test Record (Reconciled)

Task: reconcile the M1-E offline acceptance suite with the committed M1-D
dispatch implementation, so every acceptance assertion measures actual
production dispatch behavior and no independently reviewed misleading
assertion survives.

## 1. Executive Summary

- Worktree: `C:/AI/symphony-workspaces/m1-e-acceptance-reconciliation`
- Branch: `codex/m1-e-acceptance-reconciliation`
- Base: `9ce11fd` on `integration/m1-candidate-assembly` (committed M1-D
  dispatch implementation), branched directly — verified exact parent
- Suite provenance: ported from `db1350c` on `codex/m1-e-acceptance-tests`
  (authored against pre-assembly merge-base `8b329e4`); the original M1-E
  review worktree was not modified
- Deliverables:
  - Reconciled acceptance test suite:
    `elixir/test/symphony_elixir/opencode_offline_acceptance_test.exs`
  - This acceptance documentation record:
    `docs/m1-e-offline-acceptance-test-record.md`
- Verdict: `TEST_CANDIDATE_READY`

No production dispatch, adapter, configuration or redactor module was
modified. The pending configuration remediation `4f1dc51` and the approved
redactor remediation `be77946` were deliberately NOT imported (both verified
absent from `9ce11fd`'s ancestry); the smoke-test delta in `db1350c` was
superseded by `9ce11fd`'s stricter reconciliation and therefore not ported.

## 2. Reconciliation of the Reviewed Findings

Every finding from the independent M1-E review is addressed:

1. **Port onto the committed baseline.** The suite was re-authored in a fresh
   worktree branched from `9ce11fd`, reusing the dispatch-test scaffolding
   (fixture roots, WORKFLOW-file pilot configuration, mock control files,
   `:opencode_executable` seam). No unfinished revision was imported.

2. **All three `integration_gate` flunks replaced with behavioral
   assertions.** No gate flunks or delegates to a fixture router anymore:
   - *Authorized selection gate* — configures a real pilot section through
     the WORKFLOW file, asserts `Orchestrator.dispatch_harness_for_test/1`
     (the seam of the per-attempt `dispatch_harness/1` decision inside
     `spawn_issue_on_worker_host/6`) returns the pinned snapshot, then
     dispatches through `AgentRunner.run/3` and proves the mock worker
     executed (streamed `[:step_start, :tool_use, :step_finish]`, runtime
     workspace info). It also pins the committed design boundary:
     `DispatchRouter.Selection` stays Codex-shaped with no `worker_type`.
   - *Authoritative completion gate* — dispatches through `AgentRunner` with
     a sentinel `attempt: 2`, reads the durable marker mid-run, and asserts
     completion authority: every streamed update denies completion
     (`successful_completion? == false`), the adapter's
     `TERMINATED_CONFIRMED` termination evidence reaches the recipient
     before task exit, and the fence re-admits the issue afterwards.
   - *No-silent-Codex gate* — fails a worker (mock provider error), asserts
     classification through the `OpenCode.Failure` taxonomy
     (`:model_unavailable` — a class the Codex AppServer reason mapper
     cannot produce), latches the retry envelope's `:fallback` route, and
     proves the harness decision stays `{:opencode, _}` and the retried
     dispatch runs OpenCode again with only `harness: :opencode` updates.

3. **Authorized selection, mocked execution, no substitution.** Covered by
   the gates above plus the standalone selection tests; every dispatch-level
   test asserts the events are OpenCode-marked and the durable marker names
   `"harness": "opencode"`.

4. **Exact option names pinned.** A dedicated adapter contract test passes
   sentinel values for `issue_id:`, `identifier:`, `attempt_id:`,
   `provider:`, `model:`, `allowed_tools:`, `timeout_ms:` and
   `authority_root:` and verifies each lands where production consumes it
   (session provider/model, per-launch `opencode.json` permission map, and
   the durable marker fields). The AgentRunner gate pins the same names
   end-to-end through a real dispatch (`attempt: 2` survives into the
   marker), and the bounded-timeout test pins the `timeout_ms:` effect.

5. **Permissive alternatives removed.** The timeout classification is pinned
   to `:runtime_unavailable` (was a 3-way membership), malformed-stream
   evidence is pinned to the `{:malformed_json_line, _, _}` shape (was a
   3-shape `Enum.any?`), the interrupted worker is pinned to
   `{{:process_exit, 130}, _}` with class `:transient_worker_failure`, the
   nonzero-exit classification is pinned to `:model_unavailable`, and the
   session-lock test now also proves the lock survives a conflicting event
   (a later matching event is still delivered). The smoke suite's
   `summary[:completion_state] || summary[:status]` alternative from
   db1350c was superseded by 9ce11fd's `summary.completion_state` pin.

6. **Vacuous zero-orphan assertion replaced.** The old test called
   `assert_no_orphaned_processes([])` — an empty PID list that cannot fail.
   The reconciled test spawns a contained stalled worker WITH a grandchild
   process, proves the grandchild is alive in the OS process table, stops
   through the containment path (`TERMINATED_CONFIRMED`,
   `tree_drained: true`), and then proves BOTH the wrapper PID and the
   grandchild PID are positively gone.

7. **Cold-restart claim corrected.** The old test only re-read the marker in
   the same BEAM process. The reconciled `restart_required` test spawns a
   genuinely separate BEAM VM (`MIX_ENV=test mix run <probe.exs>`) with no
   in-memory state and no marker-override app env, and asserts from the
   probe's stdout that the fresh VM recovers the marker identity and answers
   both fences `{:blocked, :worker_termination_unproven}` from disk alone.
   (The probe is file-based because the Windows argv layer silently
   truncates multiline `mix run -e` scripts at the first newline.)

8. **Root-pinning unmasked.** `LaunchMarker.root/1` resolves the
   `:launch_marker_root` app env BEFORE the `:root`/`:authority_root`
   option, so the old suite's setup (app env == authority root) made every
   root assertion pass even if production ignored `authority_root`. The
   reconciled suite never sets that app env: marker paths resolve through
   the explicit root option, the identity/marker tests refute marker
   existence under the live-configuration default root, and the restart
   probe runs in a VM that has no override at all.

9. **Fail-closed configuration expectations.** What the committed baseline
   already enforces is asserted and passes: a null `enabled` never selects
   OpenCode, and the AgentRunner launch boundary refuses an unbounded
   (null-timeout) snapshot with `{:opencode_launch_settings_invalid, _}`,
   `NEVER_STARTED` termination evidence and no stranded marker. The
   explicit-null schema rejection from the pending M1-C remediation
   (`4f1dc51`) is recorded as three explicitly skipped tests whose bodies
   assert that contract; their skip tags are removed when `4f1dc51` is
   reviewed and integrated.

10. **Formatting and documentation.** The suite is `mix format`-clean and
    this record documents the evidence actually measured (below), replacing
    the pre-assembly record's expected-red narrative.

## 3. Test Matrix and Measured Results

Environment: Windows, Elixir 1.19.5-otp-28 / Erlang OTP 28; in-box csc.exe
mock, jobrun Job-Object containment; no network, provider, credential or
Codex worker access. Command base:
`mix test test/symphony_elixir/opencode_offline_acceptance_test.exs`.

### 3.1. Standalone suite (`--exclude integration_gate --exclude restart_required`)

- Tests: 34, Failures: 0, Skipped: 3 (pending `4f1dc51`), Excluded: 4
- Status: **PASS**

### 3.2. Integration-gated suite (`--only integration_gate`)

- Tests: 3, Failures: 0, Excluded: 35
- Status: **PASS** — all three gates now assert real production dispatch
  and pass against the committed M1-D implementation. No expected reds.

### 3.3. Restart-boundary suite (`--only restart_required`)

- Tests: 1, Failures: 0, Excluded: 37
- Status: **PASS** — genuine separate BEAM VM, disk-only fence recovery.

### 3.4. Full acceptance file (no filters)

- Tests: 38, Failures: 0, Skipped: 3
- Status: **PASS**

### 3.5. Neighboring suites (unmodified by this change)

- `opencode_integration_smoke_test.exs` (9ce11fd version): 8 tests, 0
  failures — its db1350c delta was superseded by the stricter committed
  reconciliation.
- `opencode_dispatch_test.exs` (M1-D suite, unmodified): 15 tests, 0
  failures.

### 3.6. Full-repository run (baseline classification)

`mix test` across the whole suite: 1226 tests, 55 failures, 13 skipped.
Every failure was classified by re-running the failing suites at a clean
9ce11fd throwaway worktree (this change stashed aside); counts are identical
with and without this revision, so none of the 55 is attributable to it:

- `fallback_routing_test.exs` 21 and `core_test.exs` 11 — the pre-existing
  fixture-modernization baseline documented in the M1-D record
  (fake-Codex fixtures omitting `termination_expectation`).
- `app_server_test.exs` 16 — same fake-Codex app-server fixture family;
  identical at clean 9ce11fd (present but unlisted in the M1-D inventory).
- `workspace_before_remove_test.exs` 5 — `gh` CLI authentication/PR-list
  environment dependencies; identical at clean 9ce11fd and consistent with
  this task's no-credentials constraint.
- `workspace_and_config_test.exs` 1 and `discovery_integration_test.exs` 1 —
  pre-existing baseline conditions; identical at clean 9ce11fd (the
  discovery failure is the bare-RuntimeError expectation from the M1-D
  record).

No expected reds remain in the acceptance suite itself, and no genuine
defect was introduced: the reconciled file contributes 38 passing tests and
3 explicitly skipped (pending 4f1dc51) tests to the full run.

## 4. Unresolved Dependencies

1. **`4f1dc51` (M1-C explicit-null fail-closed) — pending review.** Not in
   `9ce11fd`'s ancestry (verified). Three skipped tests in section 12 carry
   its contract (`must not be null: explicit true or false required` /
   `must not be null` for maps and structs). The committed baseline fails
   closed at selection and at the launch boundary, but the schema still
   accepts the nulls themselves.
2. **`be77946` (redactor UTF-8 remediation) — approved, not integrated.**
   Not in `9ce11fd`'s ancestry (verified). The redaction assertions in this
   suite measure the committed redactor; they do not encode be77946's
   behavior.
3. **Pre-existing full-suite baseline failures** are unchanged by this
   test-only revision: all 55 full-run failures reproduce identically at a
   clean 9ce11fd worktree (measured inventory in section 3.6).

## 5. Verdict

`TEST_CANDIDATE_READY` — as a test-only candidate. The acceptance suite now
proves production dispatch behavior against the committed M1-D
implementation. This is not pilot authorization: the pending remediations
above remain unintegrated, and no integration, push, PR, merge or deployment
was performed.
