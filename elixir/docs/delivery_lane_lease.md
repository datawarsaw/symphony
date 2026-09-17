# Delivery Lane Lease

Durable single-owner semantics for Symphony delivery lanes (`SymphonyElixir.LaneLease`).
Motivated by the MIC-10 Event Wake duplicate-delivery incident and the MIC-286 operational
audit finding on delivery-lane ownership.

## What the lease protects

One file per lane under `<workspace_root>/.symphony-state/lanes/<safe-lane-id>.json`.
A lane is a logical delivery identity: `"<lane_kind>:<issue_id>"` (e.g. `delivery:MIC-10`).
At most one owner — an opaque invocation token — is ever valid for a lane.

Two executor sessions cannot simultaneously operate the same delivery lane. Because the
lease covers the whole delivery run (worktree, branch, accepted SHA, and validation in that
worktree's `_build`), holding the lane lease is also the exclusion that prevents two
validators from concurrently using the same worktree build tree. No second validation lock
is introduced.

`claim/2` is atomic (`:exclusive` file creation): concurrent claimants for the same lane
produce exactly one winner; every loser gets `{:error, {:lease_held, evidence}}` or an
equivalent fail-closed error. A lost claim is always visible, never silent.

The lease persists the full binding: `issue_id`, `lane_kind`, `owner_id`, `owner_token`,
`worktree_path`, `branch`, `accepted_sha`, `base_sha`, `created_at`, `heartbeat_at`.

## What the lease does NOT protect

- Processes that ignore the lease entirely. The lease is structural against racing
  *honest* executors; it is not security against a hostile writer that deletes or
  rewrites state files.
- A lane whose `.symphony-state` lives on storage without coherent rename semantics
  (e.g. some network mounts). Local-disk semantics are assumed.
- Stale-owner recovery. That is deliberately *not* automatic — see below.

## Why a stale heartbeat is not takeover authority

A stale heartbeat proves only that updates stopped. It does not distinguish an abandoned
lane from an executor that is mid-push, mid-validation, or temporarily suspended on a
loaded host. The MIC-10 incident showed two executors can operate one lane with
convention-only ownership; auto-stealing on timeout reintroduces exactly that failure with
extra steps.

So `classify/3` only *labels* liveness — `:active`, `:stale_unconfirmed`
(heartbeat older than 15 minutes by default), `:releasable` (older than 12 hours by
default) — and `claim/2` refuses while the lease file exists, whatever its class. The
classification informs humans and tooling; it never grants authority.

## Delivery executor protocol

1. `claim/2` before touching the worktree, branch, or `_build`. On
   `{:error, {:lease_held, evidence}}`, stop: the lane is owned; surface the evidence.
2. `renew/4` periodically as the heartbeat while the delivery run continues.
3. `verify_live_state/2` immediately before push/PR/merge: it re-reads live Git state
   (`observe_worktree/1`) and checks worktree path, branch, that the leased `base_sha`
   is still an ancestor of HEAD, and — with `require_accepted_in_head: true` — that the
   leased `accepted_sha` is actually in HEAD (the pre-push gate). `verify_binding/2` is the
   pure field-comparison helper underneath it.
4. `release/4` when done. Idempotent for the owner; a foreign token is always refused.

Binding fields are immutable while held: `renew/4` carries no binding arguments, and a
second `claim/2` on a held lane fails. Changing the accepted artifact (accepted SHA A → B)
or the base requires `release/4` (or operator recovery) plus a fresh claim.

## Operator recovery semantics

`force_release/4` is the only sanctioned way to clear a lease without the owner token, and
the only way through a corrupt lease file:

```elixir
LaneLease.force_release(root, "delivery", "MIC-10",
  confirm: true,
  reason: "operator: owner host lost mid-delivery",
  forced_by: "operator-console"
)
```

It requires explicit `confirm: true` and a non-empty `reason`, writes the pre-recovery
state (or the corrupt raw bytes) to `<safe-lane>.recovery.json` as evidence, then removes
the lease. Before forcing, the operator should classify the lane (`inspect/3`,
`classify/3`) and positively confirm abandonment (owner host gone, worktree untouched).
Forcing while an owner is live violates the single-owner contract and is on the operator,
by design. The lease never auto-deletes worktrees or branches — recovery clears ownership
only.

## Failure semantics (fail closed)

- Any read that is missing, corrupt (`:corrupt_state`), wrong schema version
  (`:ambiguous_state`), missing fields (`:schema_invalid`), or names a different lane
  (`:lane_mismatch`) fails closed: claims are refused, renew/release refuse, and operator
  `force_release/4` is the recovery path. A truncated partial write can never fabricate
  ownership.
- Persistence follows the `SymphonyElixir.RetryStore` conventions: bounded JSON with
  `schema_version`, atomic temp + rename for rewrites, local-disk durability. Restart
  reconstruction is inherent — ownership lives entirely in the file; no process holds it.

## Scope

Ownership infrastructure only: no delivery automation, no auto-push/PR/merge, no changes
to retry/fallback, WorkerFence, CONTROL, or Linear lifecycle. The delivery lease remains
outside the worker/runtime trust boundary.
