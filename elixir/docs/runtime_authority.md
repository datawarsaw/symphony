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
owner liveness cannot be positively proven from another BEAM. That refusal is
bound to the physical root, not to one spelling of it: a lease claimed as
`C:\state\symphony` is refused just the same when recovery is invoked with
`C:/state/symphony`, another drive-letter case, a trailing separator, or a
junction path, because lease reads compare roots with
`RuntimeLease.roots_match?/2`. An unreadable or ambiguous record that still
looks active is refused the same way, whatever root it names: domain separation
cannot be proven from a spelling, because Windows resolves trailing dots and
spaces, extended-length prefixes, and mapped drives to the same directory, and a
relative stored path resolves against the reading BEAM's current directory. Only
stale, releasable, or liveness-unknown state recovers without the override.

Recovery is serialized against claim/renew/release by the state-root op lock
(`authority.op-lock`), preserves the prior state to `authority.recovery.json`,
and re-reads after removal: success is returned only when the lease is verifiably
gone. A surviving lease (same, replacement, or corrupt) fails closed. The
artifact is durable evidence for humans, so it keeps every field that identifies
the recovered lease (`state_root`, `instance_id`, `node`, `os_pid`,
`hostname`, timestamps, `prior_class`) and drops the prior `owner_token`,
marking it with `"owner_token_redacted": true`. The record is a projection onto
those contract fields: a field outside the contract is reported by name only, so
a hand-crafted record cannot smuggle a token copy into the artifact, and a
verbatim copy of the token value inside the projection is replaced. When the
prior state is unparseable bytes, the bytes are preserved with the token field
and token-shaped hex runs cut out, so torn-state evidence survives without the
token.

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

## Graceful runtime stop (`RuntimeShutdown`)

The release path above needs a trigger an operator can actually reach. The
foreground entry points (`mix symphony.pilot_bootstrap`, the `symphony` CLI)
therefore wait via `SymphonyElixir.RuntimeShutdown.wait_for_shutdown/1`: they
block on the runtime supervisor as before and additionally poll the durable
stop request file `<state_root>/.symphony-state/runtime/stop.request`
(`mix symphony.stop_request` writes an attributable one; the runtime log and
`RuntimeLease.status/0` show the `instance_id` a request must name).

A request is honored only when it is valid and names the exact runtime
instance (`instance_id` is minted once per BEAM boot). Requests naming another
instance — stale residue from an earlier run, a wrong target — are ignored,
logged once, and never consumed; they can never stop a later runtime, and they
never release anything. The guarded stop itself
(`RuntimeShutdown.stop/1`, also callable in-BEAM) is:

1. **Preconditions, fail-closed.** A live holder holds authority; the durable
   lease file still names this instance (`holds_authority_for?/1`, re-read
   from disk — a successor's lease refuses the stop); and the worker-drain
   requirement holds: the Orchestrator snapshot reports no `running` workers.
   A snapshot that cannot be obtained while the runtime supervisor is still up
   is a refused stop — an unverifiable drain is not a drained drain.
2. **Supervised termination.** The application is stopped: the supervision
   tree terminates through supervision, and only then does the application
   stop callback release the lease through the owner-token-checked
   `RuntimeLease.release/2`. A lease that stopped belonging to this instance
   between the preconditions and the release is refused and left intact.
3. **Verified outcome.** The durable lease is re-read after the stop; success
   is reported only when the lease is verifiably gone. A lease that survived
   (a successor's, or recovery racing the stop) is reported as
   `{:error, {:lease_not_released, evidence}}`, never smoothed over.

A valid request is consumed before the guarded stop runs, so a refused stop
(for example a worker still running) never re-triggers; the operator clears
the blocker and re-requests. Stale and foreign leases are still released only
by explicit operator recovery (`force_release/2`) — this path adds a clean
normal stop, it does not replace recovery.

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
rejected at startup, different roots are isolated domains.

Fail-closed: `authority_root/0` returns `{:error, :no_runtime_authority}`
before the lease is claimed, after a normal release, and after authority loss —
the pinned root can never outlive the authority that justifies it, and retry
paths without a resolvable record root skip their mutation instead of guessing.

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
