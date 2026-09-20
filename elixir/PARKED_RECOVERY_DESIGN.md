# PARKED recovery — working notes (hardening slice `hardening/parked-recovery`)

Working notes for the slice. Not part of the product docs; committed or dropped with the branch.

## Phase 1 — reconstructed PARKED state machine (source: `lib/symphony_elixir/orchestrator.ex` @ 214e3df)

### How PARKED is entered

Every park funnels through `Orchestrator.park_issue/4` (orchestrator.ex:2118), which:

1. observes a `:parked` wake event (except `:recovered_parked` rehydration),
2. builds a parked entry (identifier, failure_class, stop_reason, attempt counters,
   workspace_path/root/host, worker_identity, termination_expectation, parked_at),
3. cancels any retry timer, writes the durable retry record with `status: "parked"`
   (`write_retry_record_best_effort/3` → `RetryStore.write_record/2`),
4. adds the issue to `parked` AND to `claimed`.

Entry paths:

| path | location | stop_reason |
|---|---|---|
| worker down, envelope exhausted / auth | `retry_agent_down` → `RetryPolicy.evaluate` | `:max_attempts` `:max_age` `:max_identical` `:auth_unavailable` |
| worker down, envelope OK, reuse gate blocked | `retry_agent_down` → `WorkerContainment.reuse_gate/2` `{:blocked, :worker_termination_unconfirmed}` | `:worker_termination_unconfirmed` |
| dispatch route materialization failure + envelope exhausted | `handle_dispatch_route_materialization_error` | policy stop reasons |
| retry-poll failure + envelope exhausted | `handle_retry_poll_failure` | policy stop reasons |
| restart: durable record `status: "parked"` | `recover_retry_record` | `:recovered_parked` (in-memory; original reason NOT durably persisted today) |
| restart: durable record `"retrying"` + fence `{:error, :alive}` | `recover_retry_record` | `:fence_alive` |
| restart: durable record `"retrying"` + fence `{:error, :unknown}` | `recover_retry_record` | `:fence_unknown` |
| restart: ambiguous record | `recover_retry_record` else-branch | claim only, NO parked entry |

### Durable evidence that survives a restart

- Retry record `<workspace_root>/.symphony-state/retries/<safe_id>.json` (`RetryStore`):
  status, failure_class, attempt_count, identical_failure_count, first/last_failure_at,
  last_error, worker_host, **worker_identity** (`launch_id`, `receipt_path`,
  `schema_version`), workspace_path/root, route, primary_failure_count,
  **termination_expectation** (only when known).
- The worker's MIC-223 termination receipt
  `<workspace_root>/.symphony-state/worker-terminations/<launch_id>.json` — written by the
  `jobrun` wrapper, independent of the retry record. This is the evidence that "may appear later".

**Gap this slice closes:** the record does not persist `stop_reason`, so after a restart the
original park reason is lost (in-memory entry becomes `:recovered_parked`) and no operator
tooling can distinguish a fence park from a policy park. The slice persists `stop_reason`
additively (same pattern as `termination_expectation`; schema stays version 1).

### What prevents redispatch

`should_dispatch_issue?` requires the issue to be absent from `claimed`, `running`, `blocked`,
and `parked`. A parked issue is in `parked` AND `claimed`, has no retry timer (cancelled at
park), and is not reconciled against the tracker (only `running`/`blocked` issues are), so
nothing ever resolves it.

### What currently releases it

Nothing in the runtime. `complete_issue` / `release_issue_claim` remove parked entries but are
only reachable through paths a parked issue never takes. The practical escape is deleting the
retry record file and restarting: the record (the fence evidence) disappears, startup
reconciliation finds nothing, and the poller redispatches the workspace as a resume candidate
**without any fence check** — which is exactly the unsafe behavior parking exists to prevent.

## Phase 2 — parked reason taxonomy

| stop_reason (durable) | category | recoverable here? |
|---|---|---|
| `worker_termination_unconfirmed` | FENCE_RECOVERABLE | yes — re-run fence on fresh receipt evidence |
| `fence_unknown` | FENCE_RECOVERABLE | yes — same |
| `fence_alive` | FENCE_RECOVERABLE | yes — if the fence now positively proves death |
| `max_attempts` / `max_age` / `max_identical` | POLICY_PARK | no — different operator action required |
| `auth_unavailable` | POLICY_PARK | no — waits on provider reset policy |
| missing / unrecognized (legacy records) | MANUAL_DECISION_REQUIRED | no — cannot objectively classify |
| (no parked entry: ambiguous/corrupt record → claim-only) | CORRUPT_STATE | no — repair is out of scope |

`WorkerFence` truth semantics, the receipt format, and workspace identity are untouched.

## Operator surface

One CONTROL verb: `Control.request(:recover_parked, %{issue_id: id})` — CONTROL is the
host-owned lifecycle authority whose contract already states any future CLI/HTTP surface must
call exactly this API, and every request yields a bounded receipt (who/what/outcome/evidence).
No second surface (no mix task).

## Recovery decision (fence parks)

```
parked entry present?            no  → :rejected_issue_not_parked (idempotent no-op)
durable record readable
and status == "parked"?          no  → :rejected_inconsistent_state / :rejected_corrupt_evidence
durable stop_reason == fence?    no  → :rejected_not_fence_parked (category in evidence)
fence recheck on FRESH evidence:
  WorkerFence via recover_fence_verdict(record.expectation, record.identity)
  {:ok, :dead}    → proceed
  {:error, :alive}→ :rejected_worker_still_running
  {:error, :unknown} → :rejected_fence_unknown
tracker re-fetch:
  {:error, _}     → :rejected_tracker_unavailable (park preserved)
  terminal        → workspace cleanup under proven death + release claim (:recovered_terminal)
  not visible     → release claim (:recovered_issue_gone)   [existing nil-lookup rule]
  not active      → release claim (:recovered_issue_inactive)
  retry candidate → success transition (:recovery_scheduled)
```

Success transition (mirrors the CONTROL relaunch precedent):

- remove the parked entry (the parked hold is released),
- `handle_wake_release` (resolves the pending parked wake),
- `schedule_issue_retry/3` with the record's preserved envelope/route state — arms exactly one
  timer, rewrites the durable record as `"retrying"` (the retry-record transition), keeps the
  issue claimed so the poller cannot double-dispatch,
- no worker is launched from the recovery command; the normal scheduler redispatches,
  revalidating against the tracker again at timer fire.

The receipt file is never deleted; it remains durable audit evidence of why release was allowed.
