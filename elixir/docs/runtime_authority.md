# Runtime Authority (Single-Instance Lease)

Durable single-instance authority for one Symphony state root
(`SymphonyElixir.RuntimeLease`). At most one Symphony runtime may possess
lifecycle mutation authority — Orchestrator dispatch, worker spawn, cleanup,
retry mutation — for one state/workspace root at any moment.

## What the lease protects

One file under `<state_root>/.symphony-state/runtime/authority.json`, where the
state root resolves exactly like the Orchestrator's durable record root: the
`:retry_store_root` app env seam, else the configured local workspace root.

A second accidental Symphony runtime cannot become a second lifecycle authority
over the same workspace root, `.symphony-state`, tracker project, workspaces,
and retry records. Because the holder starts before any supervisor child, a
second runtime fails **before its Orchestrator exists** — fail-start, with
evidence: `{:error, {:runtime_authority_held, evidence}}`. The initial create is
atomic (`:exclusive`), so two simultaneous startups produce exactly one owner
and one rejection. That acquisition **is** the production authority gate: the
holder starts strictly before any supervisor child, and a held or unusable root
fails the whole application start, so the Orchestrator never exists without
authority through the production entry path. Entry paths that build a runtime
tree directly (tests, tools) run without a holder and resolve roots from live
configuration; `RuntimeLease.authoritative?/0` stays available to them as a
read-only evidence check, and destructive detached cleanup additionally
re-proves durable ownership per action (see the watcher guard below).

The lease binds: `state_root`, `instance_id` (random per BEAM boot),
`owner_token` (random per claim), `os_pid`, `node`, `hostname`, `started_at`,
`heartbeat_at`, and `schema_version`. It binds no task or Git state.

## What the lease does NOT protect

- Processes that ignore the lease entirely. The lease is structural against
  racing *honest* runtimes; it is not security against a hostile writer that
  deletes or rewrites state files.
- Storage without coherent rename/exclusive-create semantics (e.g. some network
  mounts). Local-disk semantics are assumed.
- Time-based automatic takeover. There is none — see below.

## Heartbeat: evidence, never authority

The holder renews the lease periodically (default every 60s,
`:runtime_lease_heartbeat_ms` app env). Renewal is owner-token-only and exists
for two reasons:

1. Operator evidence: `classify/3` labels a lease `:active`
   (heartbeat < 15 min), `:stale_unconfirmed`, or `:releasable` (> 12 h). The
   labels inform humans; they never grant takeover — a fresh runtime refuses to
   start against a stale or corrupt lease exactly like an active one.
2. Liveness of the filesystem itself: a renew failure fails closed. The holder
   logs critical, marks the instance lost, stops the runtime supervisor, and
   terminates. The lost instance can never re-acquire in the same BEAM; the
   state root is unblocked only by a fresh runtime plus operator recovery (if
   residue remains).

## Crash behavior

A hard crash leaves the lease on disk. The next startup fails closed with the
crashed owner's evidence. There is no automatic takeover based on age.

## Operator recovery

```elixir
SymphonyElixir.RuntimeLease.force_release(state_root,
  confirm: true,
  reason: "operator: owner host lost mid-run",
  forced_by: "operator-console",
  force_active: true   # required while the lease classifies :active
)
```

Recovery requires explicit confirmation (`confirm: true`) and a non-empty
`reason`. A lease that still classifies `:active` is refused unless
`force_active: true` is also passed — decide with the heartbeat evidence, since
owner liveness cannot be positively proven from another BEAM. Recovery is
serialized against claim/renew/release by the state-root op lock
(`authority.op-lock`), preserves the prior state to `authority.recovery.json`,
and re-reads after removal: success is returned only when the lease is verifiably
gone. A surviving lease (same, replacement, or corrupt) fails closed.

Never delete `authority.json` by hand while a runtime may be alive: that makes
the holder fail closed and stop the runtime (by design), and leaves the restart
path blocked until the loss is acknowledged by starting a fresh runtime.

A residual `authority.op-lock` (host crash mid-operation) can be removed by
hand while no runtime is starting.

## Normal shutdown

Application stop terminates the supervisor tree first; the holder releases the
lease only if it still belongs to this exact runtime instance (owner token
match). A stale shutdown path can never delete a successor's lease, and release
is idempotent.

## Mutation-root pinning

For the lifetime of one runtime instance, the root the lease protects is the
only lifecycle mutation root: workspaces, retry records, wake records, steering
records, termination receipts, cleanup, and orphan scans all derive their root
from the holder via `RuntimeLease.authority_root/0`, which the boot injects
into the supervisor tree (`Application.start_runtime/0` reads it back after the
holder claims and fails the boot if it is unavailable).

A `WORKFLOW.md` reload may change other settings freely; if it changes
`workspace.root`, the runtime keeps mutating the authority root it owns. The
drift is reported — a log warning on the tick that first observes it, and
truthful status:

- `RuntimeLease.status/0` gains `configured_root`, `root_drift?`, and
  `restart_required` (canonical, alias-safe comparison via
  `RuntimeLease.roots_match?/2`: slash direction, trailing separators, drive
  letter case, and junction/symlink aliases are one root, not two).
- `GET /api/v1/state` projects `configured_root`, `root_drift`, and
  `restart_required` inside `runtime_authority`, and the Orchestrator snapshot
  carries the same `runtime_root` truth.

Configuration's new root takes effect exactly at the next runtime start: a
fresh runtime resolves it, leases it, and mutates it — while the previous
runtime (if still alive) keeps mutating only the root it still owns. Two
runtimes therefore can never mutate one root concurrently: same root is
rejected at startup. Different roots isolate filesystem mutation only; they
do not isolate a shared tracker queue. See the queue ownership gate below.

Fail-closed: `authority_root/0` returns `{:error, :no_runtime_authority}`
before the lease is claimed, after a normal release, and after authority loss —
the pinned root can never outlive the authority that justifies it, and retry
paths without a resolvable record root stop dispatch instead of guessing.

### Queue ownership gate

The supported current rollout is one Windows workstation, one active Symphony
runtime, and one tracker queue (tracker service/account/team/project together
with its active-state and routing selection). There must be exactly one runtime
owner for every issue that selection can admit. Overlapping selections count as
the same queue for this rule, even if their project filters differ.

`RuntimeLease` enforces exclusivity for a canonical local filesystem root only.
Two roots can both claim valid leases while targeting the same Linear queue.
It is not a global queue lease. A process scan, a second file in an arbitrary
local directory, or matching configuration text cannot establish exclusivity
across other hosts, users, roots, and independently configured installations.
No shared queue-claim authority is available in this implementation; adding a
local check would not reliably enforce the required invariant.

Before any instrumented launch, the operator must identify the queue selection
and its single runtime owner, inventory all managed installations/launchers for
that queue, and establish that every competing runtime is stopped and disabled
for the launch interval. A root change requires stopping the previous owner
before starting its successor. This is an operational gate, not an automated
exclusivity claim. **STOP** if the inventory or ownership is incomplete, another
owner is active, or a host cannot be accounted for. **GO for consideration of a
separately authorized launch** only with a recorded single-owner inventory and
the other safety/acceptance gates satisfied. This source candidate grants no
launch or Human Acceptance authority. Multi-host or unattended multi-root use
of an overlapping queue is unsupported pending shared queue authority.

### Issue generation and durable retry state

Within the owning runtime, dispatch, AgentRunner preparation/session lifetime,
marker writes/refreshes/clears and destructive cleanup use the same reentrant
per-store/per-issue lock. The filesystem lease supplies the single-runtime
assumption. A cleanup watcher captures its original marker and identity; it
waits for that identity's receipt and compares the generation again inside the
critical section that includes deletion. It never follows the current marker
to a successor. Dispatch consumes a proven predecessor marker under that lock
before classifying or preparing a successor; missing or changed generations
reject a late cleanup. Cleanup never deletes retry records. Failed deletion
retains the marker. Corrupt marker bindings block cleanup and reuse.

Every dispatch durably records a parked `dispatch_inflight` intent before a
worker can start. Each retry timer records a parked `retry_poll_inflight` intent
before tracker revalidation. Only that in-memory poll operation can advance its
own intent; restart leaves it parked. Successful scheduling replaces the intent
with a durable retry record. This preserves a blocking record if a later
parking write fails. Unreadable/corrupt records or failed enumeration latch a
dispatch STOP for the runtime without replacing questionable evidence. A
persistence error is logged explicitly and retained on the parked entry; it
is not successful persistence. Restoring storage alone does not release a
durable park. Inflight parks may use explicit fence recovery only with positive
termination evidence; an interrupted dispatch resolves its launch identity from
the validated issue marker. Missing identity/proof requires investigation.

Watchdog stalls, worker failures, task-spawn failures and retry-poll failures
use `RetryPolicy`. Original failure time, counters, route, host and workspace
metadata survive scheduling/recovery. Recovery checks age and attempt limits
before creating a retry timer. A successful continuation has zero failure
attempts; its scheduling record does not start a failure budget. A watchdog
backoff timer grants no launch authority: the durable launch fence must still
confirm termination before dispatch can prepare or start a replacement.

### Windows partial startup limitation

After `CreateProcessW(CREATE_SUSPENDED)`, assignment failure explicitly terminates
the unassigned child using its retained process handle and waits for Windows to
signal termination before releasing the child/thread/job handles. Failed
`ResumeThread` uses the same direct termination path. These failures publish only
`WRAPPER_FAILURE` with `tree_drained:false`; failure of termination/wait retains
the handles and cannot publish successful containment. The test-only assignment
and resume fault option is absent from a production build.

Abrupt wrapper death between suspended creation and Job Object assignment is
still a residual window. The child cannot execute its user code while suspended,
but may remain as an unassigned suspended process. The already-persisted launch
marker has no valid drained receipt and blocks replacement/reuse/cleanup. Atomic
assignment via a `STARTUPINFOEX` job-list attribute would require a separate
process-creation interop/capability change and crash-window validation; it is not
claimed by this two-step implementation. The bounded operational mitigation is
to keep the affected issue stopped, identify the exact suspended child using
launch/OS evidence, and require independent termination proof before recovery.
Do not infer termination from wrapper death or remove its marker to unblock it.
Wrapper-crash injection in this window is UNVERIFIED in this candidate.

### Detached cleanup watcher guard

The bounded drain watcher (fenced destructive cleanup after an asynchronous
worker stop) is spawned detached with the precomputed pinned roots. Before it
clears a launch marker or deletes a workspace, it re-proves — from the durable
lease file, not the holder's heartbeat-lagged memory — that this runtime
instance still owns the pinned root (`RuntimeLease.holds_authority_for?/1`).
A missing lease (released or operator-recovered), a corrupt one, or a
successor's lease all fail closed: the workspace and marker are preserved for
whoever provably holds the root. The same guard sits at the synchronous fenced
cleanup action point. A watcher can therefore never delete a root a successor
runtime acquired, even if an operator recovery lands between the watcher's
spawn and its drain proof.

## Observability

- `RuntimeLease.status/0` — held?, instance id, state root, os pid, hostname,
  started at, heartbeat at, last renewal, renewal error, liveness class, plus
  root truth (`root` = authority root, `configured_root`, `root_drift?`,
  `restart_required`). The owner token is never included.
- `RuntimeLease.observe/1` — read-only evidence from the authoritative file
  (owner token stripped).
- `GET /api/v1/state` — includes a read-only `runtime_authority` projection.
- `GET /api/v1/state` and `/api/v1/:issue_identifier` — include a read-only
  `launch_diagnostics` projection of the launch marker / termination receipt
  / fence state per issue; see [launch diagnostics](launch_diagnostics.md).
- The runtime log records acquisition, renewals failures, loss, and release with
  `state_root`, `instance_id`, and `os_pid`.

## Scope boundary

The authority binds the state root resolved at boot. Changing the configured
workspace/state root requires restarting the runtime so the lease can be
re-established over the new root; until then the runtime keeps mutating the
root its lease protects and reports the drift (`restart_required: true`).
