## BOOTSTRAP
TASK: Implement and validate the specified Symphony P1/P2 safety and lifecycle remediation.
CANDIDATE: C:/Users/micha/symphony-source; main; dcd1f7eaa3a9e10e8ab9454319e0fda43bee463b plus disclosed uncommitted changes.
RESULT: PASS_WITH_CONDITIONS; independent review found no remaining confirmed P0/P1 in the changed supported scope.
STATE: Source candidate only. Human Acceptance is not granted; production launch remains unauthorized.
GUARDRAILS: No commit/push/PR/deploy; no production runtime/Linear/credentials/security-policy changes; no MIC-309 recovery.
NEXT ACTION: Operator: review this source candidate and its conditions for a separate Human Acceptance decision.

## RESULT / VERDICT

STATUS: WAITING_FOR_USER

ROLE: worker

SYMPHONY_REMEDIATION: PASS_WITH_CONDITIONS

Observed on 2026-10-17, Europe/Warsaw. The authorized result is an uncommitted,
reviewable source candidate with offline regression evidence and independent
assessment. It does not establish production readiness or global suite health. The final cross-component run has 164 passes and one measured baseline transport failure.

```text
Orchestrator -> durable intent -> issue generation lock -> AgentRunner preparation
    -> Discovery -> AppServer -> launch marker -> jobrun -> provider session
    -> identity-bound stop receipt -> local retry/fallback OR safe park
    -> RetryPolicy -> durable retry/poll intent -> bounded restart recovery
cleanup(A) -> proof(A) -> same issue lock -> exact current generation -> delete
```

## EXECUTION METADATA

MODEL: UNAVAILABLE (exact parent runtime model identifier is not exposed).

REASONING / THINKING EFFORT: UNAVAILABLE.

HARNESS: Codex Desktop, Windows PowerShell, local Elixir/OTP and in-box C# compiler.

SESSION TYPE: implementation

SUBAGENTS USED: 5

| Child / role | Model | Reasoning effort | Active duration | Bounded scope |
| --- | --- | --- | --- | --- |
| Herschel / implementation | UNAVAILABLE | UNAVAILABLE | UNAVAILABLE | Discovery, AppServer, AgentRunner; P1-A/P2-B and focused tests |
| Boyle / implementation | UNAVAILABLE | UNAVAILABLE | UNAVAILABLE | jobrun partial-start termination, private fault-build tests, crash-window assessment |
| Planck / implementation | UNAVAILABLE | UNAVAILABLE | UNAVAILABLE | RetryStore trust/write/list contracts and tests |
| Zeno / early adversarial review | UNAVAILABLE | UNAVAILABLE | UNAVAILABLE | Generation/persistence/recovery interactions and queue topology; read-only |
| Averroes / fresh-context final review | GPT-6 (reviewer-reported) | UNAVAILABLE | UNAVAILABLE | All changed safety paths and documentation; read-only, then confirmed-correction review |

The tool exposes child identities but not independently measured active durations
or exact inherited model identifiers. No timing or provider provenance is invented.
Reviewers did not run tests; all measured test evidence below was run by the parent.
No trusted clean-head review receipt was created for this deliberately dirty candidate.

## TARGET / CANDIDATE

- Canonical repository: `C:/Users/micha/symphony-source`.
- Starting branch: `main`; HEAD: `dcd1f7eaa3a9e10e8ab9454319e0fda43bee463b`.
- Starting tree: clean, verified before edits. No material baseline drift observed.
- Final branch/HEAD: unchanged; all task changes remain uncommitted.
- Source-only baseline comparison: `git archive HEAD` extracted inside this same
  repository's ignored `.tmp/safety-remediation`; no new repository or worktree.
- Accepted receipt preflight and receipt launch-id validation were preserved.
- Complete changed-file inventory and SHA-256 bindings are in the final inventory
  section and `.tmp/safety-remediation/candidate-files.sha256`.

## Acceptance source and outcome

Prompt OBJECTIVE, verbatim:

> Implement and validate a coordinated remediation of the confirmed P1 and P2 findings from the Symphony Deep Architecture, Reliability & Safety Review.
>
> The goal is to restore consistent fail-closed behavior across worker sessions, launch generations, containment, cleanup, recovery and retry.
>
> Deliver a reviewable, uncommitted source candidate with regression evidence and an independent safety assessment.
>
> Do not deploy, publish, start production Symphony or perform MIC-309 recovery.

There is no separately named DELIVERABLE or DONE WHEN / ACCEPTANCE CRITERIA field
in the prompt. Its Required behavior, Required tests, phases and closeout fields
are the acceptance source; the following mapping reports their measured limits.
Original request: `C:/Users/micha/.codex/attachments/7369607b-dd3c-40f7-8018-c2da754cc8ad/Pasted text.txt`.

| Finding | Resolution | Acceptance evidence / limit |
| --- | --- | --- |
| P1-A | RESOLVED | Actual AppServer result preserves uncertain stop even when provider failure was captured earlier. Primary/rate-limit/fallback unit scenarios and native protocol mismatch regression start zero later sessions and preserve original marker bytes. Confirmed drain still permits normal retry/fallback. |
| P1-B | RESOLVED for the supported single-runtime authority | One per-store/per-issue lock covers dispatch, AgentRunner preparation/session lifetime, marker mutation and cleanup. Watcher captures A, polls A, then validates and deletes inside the same lock. Missing/replaced generation rejects stale cleanup. Concurrent and preparation-overlap tests pass. |
| P1-C | RESOLVED WITH RESIDUAL CONDITION | Assignment and resume failure call TerminateProcess, retain handles and await a signaled child. Failure receipts stay WRAPPER_FAILURE/tree_drained:false. Both injected failures and production-option rejection pass. Abrupt wrapper death before assignment remains UNVERIFIED and documented below. |
| P1-D | RESOLVED | Store distinguishes absence from corruption, identity mismatch, unreadability and directory error. Writes sync temporary payload before rename and refuse untrusted replacement. Durable dispatch/poll intent survives failed parking update; restart remains parked after storage heals. Errors are explicit; CONTROL cannot bypass a latched trust error. |
| P2-A | RESOLVED within measured paths | Watchdog, worker, task-spawn and retry-poll technical failures share RetryPolicy. Original first_failure_at, counters, route and workspace/host metadata survive restart. Recovery checks limits before scheduling; repeated-stall, age/attempt exhaustion and poll restart tests pass. Broad fallback fixtures retain their measured baseline failures. |
| P2-B | RESOLVED | TECHNICAL_FAILURE remains retained evidence but returns an AgentRunner lifecycle error, never discovery_completed or READY. Native failed-provider protocol test traverses AgentRunner -> termination messages -> DOWN -> Orchestrator retry and verifies persisted identity-bound proof. |
| P2-C | LIMITATION DOCUMENTED / OPERATIONAL GATE | Supported rollout: one Windows workstation, one runtime per overlapping tracker queue selection. Root leases do not establish global exclusivity. No reliable shared queue authority exists; no misleading local enforcement was added. Operator inventory and STOP/GO contract are in elixir/docs/runtime_authority.md. |

### Architecture and dependency assessment

The original baseline defects were verified against source before editing each
owned slice. The actual result artifact of the earlier Deep Review was not found
in the bounded evidence search; its task prompt was found. A request for its path
was left pending. This candidate therefore relies on the supplied finding list,
current baseline code, existing tests/docs/handoffs and new independent review;
it does not claim to have inspected an unavailable historical report.

The common root causes were loss of termination truth at an API boundary,
cleanup authority bound to mutable issue state rather than a launch generation,
and persistence errors treated as missing/successful state. Stall/recovery paths
also bypassed the already-existing pure RetryPolicy envelope.

Orchestrator owns scheduling and maps; AgentRunner owns preparation and worker
lifetime; Discovery owns bounded same-input sessions; AppServer owns transport
and stop reporting; jobrun owns the OS Job and conservative receipt. WorkerFence
remains the receipt authority. No service, database or orchestration framework
was introduced. Cross-runtime queue exclusion remains outside local-file authority.

### Exact enforced invariants

1. A managed successor session cannot start without authoritative predecessor
   termination. Missing/unreadable/mismatched receipts remain uncertainty.
2. An unresolved marker cannot be overwritten; stale identity refresh/clear
   cannot consume another launch. Marker fields must bind to their stored identity.
3. Cleanup's proof, generation validation and deletion are serialized with
   dispatch/preparation/marker mutation for that issue. A missing generation is
   stale too. Cleanup never removes retry state.
4. Dispatch consumes a proven predecessor marker inside that critical section
   before successor preparation, invalidating detached predecessor cleanup.
5. Assignment/resume failure cannot release the child handle until OS termination
   is proven; failure cannot emit a successful tree-drained receipt.
6. Untrusted required retry state stops dispatch. Questionable records are not
   automatically replaced; structurally invalid/unreadable records resist deletion.
7. Dispatch and retry-poll persist blocking intent before risky operations.
   Failed persistence is visible and prevents timers/dispatch; a prior durable
   intent survives a later failed park update and restart.
8. Stalls count as failures; retry age/attempt/identical limits and original
   failure time survive recovery. Zero-count successful-continuation scheduling
   does not fabricate a failure sequence.
9. Exhausted Discovery providers are technical lifecycle failures, not completed
   Discovery. Publication and Human Acceptance boundaries remain separate.
10. CONTROL recovery rejects global durable-state distrust and rechecks both
    current launch fencing and retry budgets before scheduling.

## EVIDENCE

Evidence directory: `C:/Users/micha/symphony-source/.tmp/safety-remediation`.
Commands, exits, summaries and log hashes are also captured in `validation.json`
and `SHA256SUMS.txt` there. Counts below overlap; they must not be added together.

All candidate commands run from `C:/Users/micha/symphony-source/elixir`.
`mix.bat` resolves to the installed Elixir 1.19.5 / OTP 28.5 distribution.
Test shells prefix PATH with `C:/Program Files/Git/bin`. Tests boot only the
source test configuration (`tracker.kind: memory`) and use isolated synthetic
fixtures. Python peers emulate providers; no authenticated provider turn or
production Linear operation is performed.

| Evidence / exact command | Exit | Passed / failed / skipped / excluded |
| --- | --- | --- |
| [final-focused-complete.log](../.tmp/safety-remediation/final-focused-complete.log)<br>`mix.bat test test/symphony_elixir/lifecycle_remediation_test.exs test/symphony_elixir/retry_store_test.exs test/symphony_elixir/retry_envelope_test.exs test/symphony_elixir/launch_marker_test.exs test/symphony_elixir/worker_containment_partial_start_test.exs test/symphony_elixir/discovery_test.exs test/symphony_elixir/discovery_launch_fence_test.exs test/symphony_elixir/retry_policy_test.exs --seed 424242` | 0 | 112 / 0 / 0 / 0 |
| [final-recovery-green.log](../.tmp/safety-remediation/final-recovery-green.log)<br>`mix.bat test test/symphony_elixir/lifecycle_remediation_test.exs test/symphony_elixir/parked_recovery_test.exs test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/dispatch_router_test.exs test/symphony_elixir/restart_reconciliation_test.exs --seed 424242` | 0 | 105 / 0 / 0 / 0 |
| [final-protocol.log](../.tmp/safety-remediation/final-protocol.log)<br>`mix.bat test test/symphony_elixir/discovery_integration_test.exs:105 test/symphony_elixir/discovery_integration_test.exs:138 --seed 424242` | 0 | 2 / 0 / 0 / 31 |
| [final-root-pinning.log](../.tmp/safety-remediation/final-root-pinning.log)<br>`mix.bat test test/symphony_elixir/runtime_root_pinning_test.exs --seed 424242` | 0 | 12 / 0 / 0 / 0 |
| [final-discovery.log](../.tmp/safety-remediation/final-discovery.log)<br>`mix.bat test test/symphony_elixir/discovery_integration_test.exs test/symphony_elixir/app_server_failure_info_test.exs test/symphony_elixir/worker_containment_receipt_identity_test.exs --seed 424242` | 2 | 35 / 7 / 0 / 0 |
| [final-fallback.log](../.tmp/safety-remediation/final-fallback.log)<br>`mix.bat test test/symphony_elixir/fallback_routing_test.exs --seed 424242` | 2 | 14 / 21 / 0 / 0 |
| [baseline-fallback.log](../.tmp/safety-remediation/baseline-fallback.log)<br>`mix.bat test test/symphony_elixir/fallback_routing_test.exs --seed 424242` | 2 | 14 / 21 / 0 / 0 |
| [baseline-comparison.log](../.tmp/safety-remediation/baseline-comparison.log)<br>`mix.bat test test/symphony_elixir/runtime_authority_v3_test.exs:391 test/symphony_elixir/runtime_root_pinning_test.exs:88 test/symphony_elixir/launch_fence_test.exs:306 test/symphony_elixir/discovery_integration_test.exs test/symphony_elixir/worker_containment_test.exs:469 --force --seed 424242` | 2 | 25 / 10 / 0 / 57 |
| [compile-final.log](../.tmp/safety-remediation/compile-final.log)<br>`mix.bat compile --warnings-as-errors` | 0 | N/A (non-test check) |
| [jobrun-build.log](../.tmp/safety-remediation/jobrun-build.log)<br>`mix.bat jobrun.build` | 0 | N/A (non-test check) |
| [specs-final.log](../.tmp/safety-remediation/specs-final.log)<br>`mix.bat specs.check` | 0 | N/A (non-test check) |
| [format-final.log](../.tmp/safety-remediation/format-final.log)<br>`mix.bat format --check-formatted lib/symphony_elixir/agent_runner.ex lib/symphony_elixir/codex/app_server.ex lib/symphony_elixir/discovery.ex lib/symphony_elixir/launch_marker.ex lib/symphony_elixir/orchestrator.ex lib/symphony_elixir/retry_store.ex test/symphony_elixir/discovery_integration_test.exs test/symphony_elixir/discovery_launch_fence_test.exs test/symphony_elixir/discovery_test.exs test/symphony_elixir/fallback_routing_test.exs test/symphony_elixir/launch_fence_test.exs test/symphony_elixir/launch_marker_test.exs test/symphony_elixir/retry_store_test.exs test/symphony_elixir/runtime_authority_v3_test.exs test/symphony_elixir/runtime_root_pinning_test.exs test/symphony_elixir/lifecycle_remediation_test.exs test/symphony_elixir/worker_containment_partial_start_test.exs` | 0 | N/A (non-test check) |
| [final-generation-integration.log](../.tmp/safety-remediation/final-generation-integration.log)<br>`mix.bat test test/symphony_elixir/runtime_authority_v3_test.exs test/symphony_elixir/runtime_root_pinning_test.exs test/symphony_elixir/lifecycle_remediation_test.exs --seed 424242` | 0 | 34 / 0 / 0 / 0 |
| [final-cross-component.log](../.tmp/safety-remediation/final-cross-component.log)<br>`mix.bat test test/symphony_elixir/lifecycle_remediation_test.exs test/symphony_elixir/retry_store_test.exs test/symphony_elixir/retry_envelope_test.exs test/symphony_elixir/launch_marker_test.exs test/symphony_elixir/worker_containment_partial_start_test.exs test/symphony_elixir/discovery_test.exs test/symphony_elixir/discovery_launch_fence_test.exs test/symphony_elixir/launch_fence_test.exs test/symphony_elixir/runtime_root_pinning_test.exs test/symphony_elixir/runtime_authority_v3_test.exs test/symphony_elixir/parked_recovery_test.exs test/symphony_elixir/retry_policy_test.exs --seed 424242` | 2 | 164 / 1 / 0 / 0 |

Final native protocol regressions are deliberately bounded fixture processes.
The mismatched-receipt helper is a private test copy built from the same
containment source with only its receipt launch-id field changed; production
helper/source and production authority are not modified by that fixture.
Windows assignment/resume fault injection is compile-time-only (`JOBRUN_TEST`);
the production binary rejects its option. Normal scratch-process containment
tests in the broad run retain their existing receipt checks.

Baseline comparison uses pristine source from the exact baseline archive and a
separate build directory inside the canonical repository. Baseline and its
built helper C# input matched SHA-256
`dc476c43cc9e389bcb272989c3a3ded84b5862635e8eeddf46a1dbaed412bbc3`.
The final fallback suite has exactly the same 21 failing test names as baseline,
with no added failing name. Native :epipe/port-command failures also reproduce
on baseline; the final broader Discovery set is not claimed green.

The earlier mixed cross-component run produced 163 tests / 4 failures. Its
durable-recovery assertion exposed and led to correction of the missing
worker_launch_unproven recovery category. The v3 retry test initially had a
race between timer delivery and test-side receipt removal. The final test freezes
the test lifecycle owner, captures/cancels its actual timer, removes the receipt,
then drives the real retry callback with the actual retry_token and state.
No safety assertion was weakened. Independent review accepted this correction.
The generation/root/lifecycle group now passes 34/0. The final broad cross-component
run is 165 tests / 1 failure, solely the native Windows :epipe normal-execution
fixture also measured on the pristine baseline. There is no new failing name in
that final set. Earlier superseded failures remain in validation.json and logs;
no globally green full application suite is claimed.

Full `make all`, global coverage and a full application suite were not run.
They are not represented as green. Existing test-helper clause warnings and
the Phoenix colocated-JS symlink :eperm warning were observed without changing
host permissions or security policy.

## Independent review and corrections

Early read-only review identified the persistence-after-storage-recovery case;
the implementation extended blocking intent to retry-poll and tested restored
last-durable bytes. The parent's actual contract audit found that captured
provider failure could mask AppServer termination uncertainty; this was fixed
and proved with a real local protocol peer. Cross-component validation exposed
the missing fence-recoverable launch-park category and tightened recovery's
current-marker check and terminal cleanup path.

Fresh-context final review found no P0/P1 and one confirmed P2: CONTROL recovery
could claim scheduling despite a global durable-state STOP. The entry gate now
rejects it before mutation/timer creation; regression verifies unchanged durable
bytes, retained park and zero retry timers. The independent reviewer re-read
that correction and returned PASS_WITH_CONDITIONS, with no remaining confirmed
material P2 in the changed scope. The same fresh-context reviewer also reviewed
and accepted the deterministic v3 retry-boundary test correction. This is a read-only code assessment, not an
independent rerun of the parent's tests or Human Acceptance.

## RISKS / BLOCKERS

- Abrupt wrapper death between suspended creation and Job assignment can leave
  an unassigned suspended child. It cannot execute its user code while suspended;
  missing drained evidence still blocks lifecycle reuse. Crash-window injection
  and atomic STARTUPINFOEX/job-list creation are UNVERIFIED. The bounded mitigation
  is issue STOP plus exact OS/launch investigation and termination proof before
  recovery, not marker removal or inference from wrapper death.
- If direct termination or its wait itself fails, the helper retains handles
  and can remain waiting. It emits no successful receipt; runtime uncertainty
  remains fail-closed. These OS-error paths were reviewed, not fault-injected.
- Global queue exclusivity is not automatically enforced across roots/hosts.
  The operational one-owner gate is a prerequisite, not an accomplished check.
- Tests do not establish production launch parity or live provider/Linear
  behavior. Broader native Windows transport tests retain the baseline failures
  described above; the corrected generation/root/lifecycle integration is green.
- Hostile external state mutation and active operator force-release during
  mutation are outside the supported single-owner rollout. The queue gate
  requires stopping the old owner before authority transfer.
- Original Deep Review result artifact remains unavailable unless separately
  supplied. No additional historical findings are assumed absent.

CONFIRMED_P0_P1_REMAIN: No remaining confirmed P0/P1 in the reviewed, supported
single-runtime changed scope. This statement does not eliminate the explicitly
documented Windows residual or claim globally verified behavior.

HUMAN_ACCEPTANCE: NOT_GRANTED. Source review is ready with conditions;
production launch readiness is not granted.

Minimal STOP/GO prerequisites before a separately authorized instrumented launch:

- Human review/acceptance of this exact candidate and a separate promotion/start authorization.
- Recorded inventory establishing one stopped/active-owner transition for the exact queue.
- No unresolved worker identity/receipt or questionable retry state in the launch authority;
  historical state must be investigated through its own authorized procedure.
- Explicit handling of the suspended-child crash-window residual, plus bounded
  launch instrumentation for launch id, marker, receipt, worker tree and STOP.
- Treat broad native transport limitations as unresolved where they affect
  the proposed launch environment; do not extrapolate isolated success.

These are conditions for a later decision, not instructions to start Symphony
or recover MIC-309 in this task.

## Changed-file inventory

- `README.md`
- `SPEC.md`
- `docs/discovery-worker-lane.md`
- `docs/safety-lifecycle-remediation-20261017.md`
- `elixir/README.md`
- `elixir/docs/runtime_authority.md`
- `elixir/lib/symphony_elixir/agent_runner.ex`
- `elixir/lib/symphony_elixir/codex/app_server.ex`
- `elixir/lib/symphony_elixir/discovery.ex`
- `elixir/lib/symphony_elixir/launch_marker.ex`
- `elixir/lib/symphony_elixir/orchestrator.ex`
- `elixir/lib/symphony_elixir/retry_store.ex`
- `elixir/priv/windows/jobrun/jobrun.cs`
- `elixir/test/fixtures/discovery_app_server.py`
- `elixir/test/symphony_elixir/discovery_integration_test.exs`
- `elixir/test/symphony_elixir/discovery_launch_fence_test.exs`
- `elixir/test/symphony_elixir/discovery_test.exs`
- `elixir/test/symphony_elixir/fallback_routing_test.exs`
- `elixir/test/symphony_elixir/launch_fence_test.exs`
- `elixir/test/symphony_elixir/launch_marker_test.exs`
- `elixir/test/symphony_elixir/lifecycle_remediation_test.exs`
- `elixir/test/symphony_elixir/retry_store_test.exs`
- `elixir/test/symphony_elixir/runtime_authority_v3_test.exs`
- `elixir/test/symphony_elixir/runtime_root_pinning_test.exs`
- `elixir/test/symphony_elixir/worker_containment_partial_start_test.exs`
- `state/project-state.md`

Temporary baseline source/build snapshots remain inside the ignored evidence directory. Automatic approval review rejected the cleanup-containing command with "blocked by policy"; no deletion was performed. Logs and manifests were finalized through a separate non-destructive operation.

## Closeout

SOURCE_MODIFIED: YES

SOURCE_COMMITTED: NO

SOURCE_PUSHED: NO

PRODUCTION_RUNTIME_MODIFIED: NO

SYMPHONY_STARTED: NO

LINEAR_MUTATED: NO

MIC_309_RECOVERED: NO

GIT: main; HEAD remains dcd1f7eaa3a9e10e8ab9454319e0fda43bee463b; no commit/push/PR/merge.

PROJECT_STATE_UPDATED: YES Ă˘â‚¬â€ť state/project-state.md, candidate-only truth.

LINEAR_UPDATED: NOT_REQUIRED Ă˘â‚¬â€ť explicitly prohibited by this task.

MANUAL_ACTION_REQUIRED: Separate human candidate review/decision; no production action authorized.

CAN_ARCHIVE: NO

NEXT ACTION: Operator: review this source candidate and its conditions for a separate Human Acceptance decision.

HANDOFF SELF-CHECK: PASS Ă˘â‚¬â€ť BOOTSTRAP has six body lines; bounded task, baseline,
state, guards and one identical next action are present; worker acceptance source,
candidate/dirty disclosure, metadata, inventory, evidence and limits are explicit.
