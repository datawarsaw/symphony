# Launch Diagnostics (Hardening State Projection)

Read-only operator visibility into the durable launch state behind the
resume/cleanup fence (`SymphonyElixir.LaunchDiagnostics`): the per-issue
launch marker, the termination receipt its stored identity points at, and the
fence verdict over that evidence. The authoritative implementations remain
`LaunchMarker`, `WorkerFence`, and `WorkerContainment`; diagnostics only
re-ask them at read time.

## Where to inspect

- `GET /api/v1/state` — a `launch_diagnostics` map keyed by issue id, one
  entry per issue the runtime currently tracks (running, retrying, blocked,
  parked).
- `GET /api/v1/:issue_identifier` — a `launch_diagnostics` object for that
  issue.

Both projections are read-only file reads under the launch-marker and
termination-receipt stores. Requesting diagnostics never mutates durable
state.

## Fields

| Field | Meaning |
| --- | --- |
| `marker.status` | Durable launch marker classification: `ABSENT`, `VALID`, `INVALID`, `UNREADABLE` |
| `marker.launch_id` / `identifier` / `attempt_id` / `workspace_key` / `started_at` | Bounded identity fields of the stored launch (when `VALID`) |
| `marker.identity_authority_root` | The authority root the launch identity was created under; differs from `store_root` after a root A→B move |
| `receipt.status` | Termination-receipt classification for the receipt the marker names: `ABSENT` (none written yet / none named), `VALID`, `INVALID` (malformed), `UNREADABLE` |
| `receipt.launch_id` / `tree_drained` / `terminal_reason` | Receipt evidence fields (when `VALID`) |
| `receipt.launch_id_matches_marker` | Whether the receipt's launch id matches the marker's stored identity |
| `receipt.verdict` | The fence's death verdict over the stored identity: `DEAD`, `ALIVE`, `UNKNOWN` |
| `fence.decision` | The resume/cleanup gate verdict recomputed by `LaunchMarker.reuse_gate/2`: `ALLOWED` or `BLOCKED` |
| `fence.reason` | Refusal reason when blocked: `worker_alive`, `worker_termination_unproven`, or `launch_marker_unreadable` |
| `store_root` | The launch-marker store directory the read resolved against |

Root resolution mirrors the runtime's own fences: the `:launch_marker_root`
override, else the boot-pinned runtime authority root, else live
configuration. The store root is also shown by `runtime_authority.state_root`
in the same `/api/v1/state` payload.

## What the statuses mean

- `marker ABSENT` + `fence ALLOWED` — no managed launch on record for the
  issue; the legacy behavior applies (nothing to fence).
- `marker VALID` + `receipt ABSENT` — a launch owned this workspace and its
  death is not yet proven: the fence blocks redispatch and cleanup.
- `marker VALID` + `receipt VALID` + `verdict DEAD` — the termination receipt
  positively proves the worker tree drained; the fence admits reuse and
  cleanup.
- `marker VALID` + `receipt.launch_id_matches_marker: false` or `verdict
  UNKNOWN` — evidence exists but does not prove death; the fence blocks.
- `marker INVALID` / `marker UNREADABLE` — the marker file is corrupt or
  unreadable; the fence blocks (`launch_marker_unreadable`). A hand-corrupted
  marker is never read as "no launch happened".
- `receipt INVALID` / `receipt UNREADABLE` — the receipt file is malformed or
  unreadable; the fence stays blocked. Invalid evidence never renders as safe.
- `fence.decision: UNKNOWN` — the diagnostic projection itself failed
  (`reason: diagnostic_unavailable`); treated as not allowed. This is the
  only fence value diagnostics can produce that the gates cannot.

## What diagnostics do NOT authorize

Diagnostics are display-only. They are not a source of authority:

- Reading diagnostics never clears a marker, rewrites or repairs a receipt,
  or changes any reconciliation/fence outcome.
- A projected `ALLOWED` is a point-in-time re-evaluation of the same
  authoritative gate, not a permission; dispatch and cleanup decisions are
  still made exclusively by the runtime's fences.
- A projected `BLOCKED` means the operator should look at the receipt
  evidence (or resolve the launch through the existing CONTROL paths); it
  never times out or self-heals, and no diagnostic action lifts it.
- Root truth stays with `RuntimeLease`: `store_root` shows which store was
  read, `runtime_authority.root_drift` / `restart_required` (same payload)
  show that a restart is needed to adopt a moved root. A stale marker left
  under a previous root is visible only by reading that root explicitly; the
  runtime correctly fences over the root it owns.
