# BEAM Death and Recovery Tests (M1-BEAM-T)

`test/symphony_elixir/beam_death_recovery_test.exs` produces deterministic
offline evidence that the launch marker and the termination-receipt fence keep
working after an *actual* parent BEAM process dies. The existing containment
suites simulate interruption and prove the wrapper against a helper crash, but
they never halt the BEAM that owns a worker; this suite does.

## How it runs

The ExUnit process is only a bounded controller. It boots a *separate* OS BEAM
per phase through `test/support/beam_death/beam_child.exs`:

- plain `elixir` (never `mix`), with `ERL_LIBS` pointing at `_build/test/lib`,
- driven entirely by environment variables and an isolated temp authority root,
- terminated by its own recorded OS pid, never by process name or tree guess.

The `launch` phase records the durable marker for a contained mock worker
(`WorkerContainment.new_identity/1` + `LaunchMarker.record/2`, in the same order
the production AppServer uses) and then starts that worker through the real
`jobrun` wrapper with `scratch_proc.exe` as the harmless child tree. The
`recover` phase re-reads the same root after the launch BEAM is gone and
recomputes the fence verdict plus the reuse/cleanup gates with the production
modules (`LaunchMarker`, `WorkerFence`, `WorkerContainment`).

## What is proven

1. **Confirmed death.** Only the launch BEAM is killed (no `/T`). The `jobrun`
   wrapper survives its parent, sees stdin EOF, drains the job, and writes the
   termination receipt post-mortem. The recovery BEAM reports
   `marker VALID`, matching `launch_id`, `verdict DEAD`, and both gates
   `ALLOWED`; an authorized continuation launch then runs and drains to
   `TERMINATED_CONFIRMED`, clearing the marker on proof.
2. **Uncertain termination stays blocked.** The launch BEAM tree is destroyed,
   taking the wrapper with it before it can record proof. No receipt is written,
   so the recovery BEAM reports `verdict UNKNOWN` and both gates
   `BLOCKED:worker_termination_unproven`.
3. **OS evidence, not inference.** Every observed worker pid (root and
   descendant) is checked with `tasklist` before and after termination, and the
   evidence record marks the cleanup `evidence_source: OS_TASKLIST`,
   `inferred: false`. In scenario 2 the tree is genuinely gone per the OS, yet
   the fence still blocks: observed cleanup is never substituted for positive
   termination proof.

## Running it

Windows-only and gated like the other multi-BEAM suites:

```bash
SYMPHONY_RUN_BEAM_DEATH_E2E=1 mix test test/symphony_elixir/beam_death_recovery_test.exs
```

Without the gate the two tests are reported as skipped and the default suite is
unchanged. Related suites to run alongside: `launch_marker_test.exs`,
`worker_containment_test.exs`, `worker_containment_helper_test.exs`.

## Safety and cleanup

The suite never touches the development runtime or production Symphony. Each
child runs against a unique temp authority root; the controller records every
spawned pid (BEAM, wrapper, mock worker tree) and, on `on_exit` — pass or fail —
force-kills the recorded trees before removing the temp root. Each child also
self-halts on a bounded deadline, so a leaked child cannot outlive the run.

## Not covered

This is a test candidate for the marker/receipt fence under real BEAM death. It
does not exercise a live Codex app-server, remote/SSH workers, or the
Orchestrator's dispatch loop, and it does not authorize any pilot integration.
