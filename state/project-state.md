# Symphony project state

## MIC-167 implementation candidate

Base: datawarsaw/symphony main, 54d9b9080262dcc328ed5aa68430583d1a1cdfe8.
This is an uncommitted implementation candidate, not a deployed runtime change.

- RepositoryRouter (MIC-129) remains the allowlisted repository selector.
- SourceSync (MIC-128) retains its existing host synchronization and fail-closed behavior.
- Existing host workspace hooks remain responsible for materializing the issue worktree.
- AgentRunner captures preparation provenance after the before_run hook and before Codex starts.
- The implementation workflow treats Git metadata as read-only, preserves source changes and
  workpad evidence, and exits to In Review. Review is neither active nor terminal in this workflow,
  so existing reconciliation and retry handling release the issue without deleting its workspace.
- Delivery requires a separate host/human-approved phase. Sandbox and path boundaries are unchanged.

The active local runtime checkout and its customized workflow are pre-existing dirty work, and are
not modified by this candidate. Adoption there is a separate host operation after review.
Windows launcher failures remain MIC-164; dependency advisories remain MIC-168.

## Validation and handoff

- Focused combined Workspace/routing/SourceSync/Core/provenance/review suite: 132 tests,
  117 passing, 15 failures. Failure test names exactly match the untouched-main Windows baseline
  (122 tests, 107 passing, the same 15 failures). No introduced failing test remains.
- The 11-test focused acceptance run passes, including real Windows ACL protection of `.git`
  against both new-file and existing-config writes while source edits and Git reads succeed.
- SourceSync tests also verify fresh preparation, fail-closed source errors, source refresh,
  and retention of the original implementation base plus uncommitted changes on workspace reuse.
- `mix specs.check` passes. SourceSync's spec annotation was moved next to its function clause;
  its synchronization implementation is unchanged.
- `git diff --check` passes.
- Independent read-only review found no introduced runtime/security blocker; documentation
  contradictions identified during review were corrected.

Native Windows still prevents a fully green suite: launcher `:epipe` (MIC-164), shell path fixtures,
symlink permissions, and SSH test shims. Live Codex/SSH end-to-end execution remains unverified here.
Test logs are retained at C:/tmp/mic167-final-tests.log and C:/tmp/mic167-baseline-tests.log;
focused acceptance results are at C:/tmp/mic167-acceptance.log.
No implementation commit, push, PR, merge, or deployment was performed. The uncommitted diff remains
in C:/tmp/symphony-mic167-rework for review and separate approved host delivery.
The broad Windows test processes stayed open after printing their complete ExUnit summaries and
were interrupted after results were captured; their process exits are not claimed as successful.
Linear MIC-167 was moved to In Review after validation. Host review/delivery remains pending.

## Dedicated Discovery lane candidate — 2026-09-07

Branch: `codex/discovery-worker-lane`, based on `e2c9ec8` in the isolated checkout
`C:/AI/worktrees/symphony-discovery-worker`. This is a local implementation candidate;
Discovery is disabled in the example workflow and the live runtime has not been changed.

- The authoritative behavior/output inputs are the installed
  `C:/AI/code-skills/discovery-gate/SKILL.md` and its `references/discovery-contract.md`.
  `discovery.enabled` and `discovery.skill_path` opt into the local lane. Existing implementation
  SSH behavior is unchanged; SSH Discovery is rejected rather than silently changing hosts.
- The existing Codex app-server/OpenCodex boundary selects `xai/grok-4.6` at medium reasoning.
  Only recognized technical failure permits `google-antigravity/gemini-3.8-flash` fallback,
  also at medium reasoning. Rate limits receive one bounded retry. Fallback uses the identical
  frozen skill/contract/issue/routing input in a fresh session and does not merge partial output.
- Discovery bypasses implementation hooks, denies dynamic tool execution, disables inherited
  MCP servers/apps/plugins/subagents, and verifies read-only, network-disabled session settings.
  The host retains output and model provenance under the workspace root's `.discovery-results`.
  Evidence writes use canonical path checks and atomic replacement; no worker lifecycle write occurs.
- READY requires the complete brief and handoff, unsplit scope per the installed contract, matching issue identity
  and routed destination. Other verdicts and invalid output park without implementation.
  A separate lifecycle action is required to enter Todo. The later worker receives only the
  validated Todo Handoff; changed or non-READY evidence fails closed. Ungated existing Todo
  work retains its prior behavior. Review, Human Acceptance and delivery/merge policy are unchanged.

Verified on this candidate:

- 15/15 focused Discovery tests pass. Real app-server protocol peers verify denied mutation calls,
  retry-exhausted Gemini fallback, byte-identical inputs, and discarded partial primary output.
- A real installed app-server setup probe selected `xai/grok-4.6` with approval `never`, read-only
  sandbox and network access false, with all nine configured MCP servers disabled. No live model
  turn was run; authenticated provider execution and real Linear lifecycle acceptance remain unverified.
- `mix format --check-formatted`, `mix lint` (including specs), `mix dialyzer --format short`
  (zero errors), and `mix build` pass. Elixir files were normalized to the Git blobs' LF endings
  only in the isolated checkout for the formatter; this adds no unrelated Git content changes.
- Full runtime-PATH coverage run: 337 tests, 51 failures, 6 skipped, 93.86% coverage. The untouched
  `e2c9ec8` baseline under the same Git Bash PATH/line endings has 322 tests, the exact same 51
  failing test names, 6 skipped and 93.80% coverage. There are no introduced failing test names.
  Both remain below the configured 100% threshold. Test processes remained open after the final
  summaries and were interrupted after evidence capture; their exits are not claimed successful.
- Tests/protocol launch use the existing live launcher's `C:/Program Files/Git/bin` PATH prefix.
  The default Windows WSL-bash selection failure remains the separate MIC-164 prerequisite.

Delivery is blocked by the existing broad-gate failures and pending independent exact-head review
and live acceptance. No push, PR, merge, deployment, Linear status change or subagent run occurred.
No task-specific Linear issue ID was supplied or confidently identified for this implementation.
Detailed run evidence is retained at
`C:/AI/reviews/symphony-discovery-20260907-01a07d63`.
See `docs/discovery-worker-lane.md` for configuration, lifecycle and evidence recovery.


## MIC-221 recorded-workspace deletion boundary candidate — 2026-09-11

Branch: `symphony/MIC-221`, base `3121a51c3787cba2b59cdea9e881875555649b29` ("MIC-225 use Bearer
auth for GitLab requests"). Uncommitted implementation candidate in the issue worktree
`C:/AI/symphony-workspaces/MIC-221`; the live runtime and the shared source checkout are unchanged.

- Recorded-workspace cleanup now fails closed against an independently trusted deletion boundary
  instead of `Path.dirname(workspace)`. A recorded path `W` may run `before_remove` and recursive
  deletion only when it is strictly contained within trusted root `R`, where `R` is the root recorded
  when `W` was created, or the current configured root when no recorded root exists.
  `workspace == root` and out-of-root paths are rejected.
- `Workspace.create_for_issue_with_route/2` returns the resolved creation root; the remote prepare
  script reports a canonicalized (`pwd -P`) root as a fourth TAB field; the recorded root travels
  through AgentRunner worker runtime metadata and Orchestrator running/blocked/retry state into
  `Workspace.remove_recorded/3`. This is a metadata-only addition to existing lifecycle state.
- Local validation canonicalizes root and workspace, rejects equality, requires a strict
  `root <> "/"` prefix, and retains symlink/junction/reparse escape protection
  (`:workspace_symlink_escape`). Remote validation is lexical over POSIX path strings (empty,
  control-character and non-absolute paths rejected) and never treats shell escaping as containment.
  Validation precedes hook execution and `File.rm_rf`/`rm -rf`.
- Deliberate hardening: a recorded or configured root that is not an absolute, resolved path fails
  closed to `{:workspace_outside_root, ...}` rather than falling back to prefix/substring trust.
  The prepare script resolves a `~` root with `pwd -P`, so this only rejects metadata that lacks a
  resolved root.
- Unchanged and intentional: cleanup of old-root workspaces after a configuration reload,
  current-root cleanup, workspace reuse, canonicalization, Windows junction safety, SSH support,
  retry semantics beyond metadata propagation, Human Acceptance and review/delivery policy.
  `Workspace.remove/2`'s remote clause remains implicitly bound to the current configured root.

Verified on this candidate (Windows, Elixir 1.19.5 / OTP 28, unstaged worktree):

- `mix compile --warnings-as-errors` passes (only the benign Phoenix LiveView `:eperm`
  `node_modules` symlink warning).
- `mix specs.check` passes.
- `mix test test/symphony_elixir/workspace_and_config_test.exs` gives 65 tests, 2 failures. Both are
  the pre-existing Windows baseline failures for this file (baseline 61 tests, the same 2: `:1627`
  env-backed `$VAR` path expansion and `:14` after_create clone path mangling).
- `mix test test/symphony_elixir/core_test.exs:629 test/symphony_elixir/core_test.exs:552` gives 2
  tests, 0 failures (old-root terminal cleanup and cross-root proofs).
- `mix test test/symphony_elixir/ssh_test.exs` gives 8 tests, 0 failures.
- `mix test test/symphony_elixir/core_test.exs` gives 52 tests, 7 failures. An untouched-HEAD copy
  of the same tree on this host produces the identical 52 tests and the identical 7 failing test
  names (`workspace_hook_failed` Git-Bash `cp` path mangling, and MIC-164 `:epipe`); the
  only difference is a one-line offset from this candidate's single added test line.
- `mix format --check-formatted` on the touched files still reports only pre-existing unstaged
  deviations that are byte-identical to HEAD's changed-line text set, so this candidate adds no
  new formatter deviation.
- `git diff --check` passes.

No commit, push, PR, merge or deployment was performed; nothing in this entry is a deployed runtime
change. The uncommitted diff (5 Elixir files, +429/-34) remains for independent review. Windows
launcher failures remain MIC-164; Elixir test logs are retained under `%TEMP%/mic221-h-*.log` and
`%TEMP%/mic221-head-corefull.log`.

## MIC-224 implementation candidate — 2026-09-11

Branch: `symphony/MIC-224`, based on `6fb3963` in the isolated worktree
`C:/AI/symphony-workspaces/MIC-224`. This is an uncommitted implementation candidate,
not a deployed runtime change.

- Startup reconciliation and resumption ownership for active issues after a runtime restart.
- Authority hierarchy after restart:
  1. Tracker lifecycle eligibility and route resolution (`RepositoryRouter`).
  2. Deterministic workspace path presence on local filesystem (`Workspace.workspace_path`).
  3. Git repository identity matching routed source (`git rev-parse --git-common-dir`).
- Matching surviving workspaces are classified `:resume`, dispatched with `resumed: true`, receive
  continuation/resumption framing in the prompt, and preserve dirty working trees byte-for-byte.
- Mismatched workspaces fail closed: marked blocked in Orchestrator state (`state.blocked`),
  excluded from dispatch, and directories remain untouched on disk.
- Unowned surviving workspaces are logged as orphans and never automatically deleted.
- Terminal cleanup remains ordered ahead of active dispatch and never deletes active issue workspaces.
- Retry attempts are not fabricated (`attempt` remains `nil`).
- Bounded contract assumption: recovers workspace ownership semantics under the assumption that no
  old OS-level worker process overlaps the new dispatch (worker fencing owned by MIC-223).
- 10 focused restart/reconciliation tests added in `test/symphony_elixir/restart_reconciliation_test.exs`
  verifying all required recovery and fail-closed behaviors.
- One focused retry-metadata test was added to `test/symphony_elixir/orchestrator_status_test.exs` proving retry metadata keeps the MIC-221 `workspace_root` alongside the MIC-224 resumption state.

Integration with delivered MIC-221 (review candidate, 2026-09-11):

- The MIC-224 review candidate is integrated onto the MIC-221 recorded-workspace deletion boundary
  (c540a299a8e99586d9417e9778ad44a25d2fd01d, locally identical to origin/symphony/MIC-221).
  The MIC-224 implementation itself was based on 6fb3963.
- MIC-221 workspace_root and MIC-224 resumed coexist: running entries carry both, retry metadata
  keeps workspace_root, and a reconciliation mismatch blocks the issue without deleting the
  surviving workspace. The mismatch block records no workspace_root, so a later recorded cleanup
  for that issue falls back to the currently configured root as the trust boundary instead of the
  creation-time root.
- Workspace.verify_reused_workspace_repository/4 now delegates to the shared
  Workspace.verify_workspace_git_identity/3 that reconciliation classification uses; the MIC-221
  remove_recorded/3 trusted deletion boundary is unchanged.

Validated for the MIC-221 + MIC-224 integration (Windows, Elixir 1.19.5 / OTP 28, unstaged worktree):

- `mix compile --warnings-as-errors` passes (exit 0, no warnings emitted).
- `mix specs.check` passes (`specs.check: all public functions have @spec or exemption`).
- `mix test test/symphony_elixir/restart_reconciliation_test.exs --warnings-as-errors` gives 10 tests, 0 failures.
- `mix test test/symphony_elixir/orchestrator_status_test.exs --seed 424242` gives 44 tests, 11 failures; a pristine `c540a299` baseline on this host produces the identical 11 failing test names, all `default CA trust store not available` raised from `run_terminal_workspace_cleanup/0` inside `Orchestrator.init/1` in this offline sandbox. The candidate adds one passing test relative to that baseline.
- `mix test test/symphony_elixir/workspace_and_config_test.exs --seed 424242` gives 65 tests, 11 failures with a failure-name set identical to the `c540a299` baseline at the same seed (pre-existing Windows and sandbox failures: Git-Bash path mangling at `:14`, `$VAR` expansion at `:1627`, and cascading `Supervisor` liveness failures after the app process dies mid-suite).
- `mix test test/symphony_elixir/core_test.exs --seed 424242` gives 52 tests, 11 failures, identical count and failure names to the `c540a299` baseline at the same seed.
- `mix test test/symphony_elixir/core_test.exs:629 test/symphony_elixir/core_test.exs:552` gives 2 tests, 0 failures (MIC-221 old-root terminal cleanup and cross-root proofs).
- `mix test test/symphony_elixir/source_sync_test.exs --seed 424242` gives 14 tests, 7 failures, identical to the `c540a299` baseline at the same seed.
- `mix test test/symphony_elixir/workspace_provenance_test.exs` gives 6 tests, 0 failures.
- `mix test test/symphony_elixir/implementation_review_test.exs` gives 3 tests, 0 failures.
- `mix test test/symphony_elixir/ssh_test.exs` gives 8 tests, 0 failures.
- `git diff --check` and `git diff --cached --check` pass.

Baseline comparison ran in a separate clone of the same repository bundle checked out at `c540a299`, with the same TEMP override and the same seed. The integration introduces no new failure on this host.
