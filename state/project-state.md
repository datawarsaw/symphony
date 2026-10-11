# Symphony project state

## M1-WIRE-F2 OpenCode 1.18.28 Wire Fixture Provenance Remediation — 2026-10-11

Base: datawarsaw/symphony reference commit `9ce11fd3a9db817d1930e372749fd13ce4b08951` (M1-D).
Remediated candidate: `6459a2da4f1687bb346cb49737c317a20066c5d8` (branch `codex/m1-wire-f-authentic-fixtures`).
Remediation branch: `codex/m1-wire-f2-provenance-remediation`, isolated checkout `C:/AI/worktrees/m1-wire-f2-remediation`.
Scope: fixtures, manifest, fixture tests, provenance document and this record. Production modules are unchanged.

- Upstream tag `v1.18.28` resolves to `22006d97652839999596a34a48ff6be7dbb40c6e` (confirmed with git ls-remote). Source anchors are in `docs/m1-opencode-wire-fixtures-provenance.md`.
- No fixture is a captured CLI output. All values are synthetic. Labels are `cli-emission-shape` (3 fixtures), `schema-derived` (4), and `synthetic` (4, including two explicit-total fixtures). `live_capture_status` is `none`.
- `tokens.total` was removed from the upstream-shaped and schema-derived fixtures. Explicit-total coverage, including zero, moved to synthetic fixtures.
- The five expected-red gates keep their assertions. They are tagged as 3 `product_policy` (gap A1, A2, A3) and 2 `implementation_candidate` (gap A5 status and name). None is a demonstrated upstream defect.
- Two upstream observations are open and outside the gates: a mid-turn `unknown` step-finish is treated as terminal by the Parser, and provider failures in JSON mode appear as step-finish events rather than error records.
- Validation: protocol suite 14 passing; gap suite 5 expected red with unchanged received values. This is not a genuine wire-trace certification. Authorized live captures remain required.
- Constraints maintained: no provider calls, no private session stores or auth files read, no production module changes, no merge, push, PR or deployment.
## M1-P-F1 OpenCode parser safety candidate — 2026-10-11

Branch `codex/m1-p-f1-parser-safety`, exact dispatch base
`9ce11fd3a9db817d1930e372749fd13ce4b08951`, isolated worktree
`C:/AI/symphony-workspaces/m1-p-f1-parser-safety`. Local implementation candidate;
no provider calls, credential operations, push, PR, merge, integration or deployment.

- JSONL non-objects and invalid traversed event fields fail closed before session
  extraction, usage updates or callback event storage. Later valid records remain
  readable but cannot turn a failed run into success.
- Evidence reuses `{:malformed_json_line, line, %{reason: "invalid_event_shape: <field>"}}`.
  Invalid objects retain a fixed line, not their raw payload. String records are
  decoded before existing Redactor sanitization and its 4,096-byte UTF-8 bound.
  Evidence line/detail are JSON-encodable; the tuple follows existing Failure conventions.
- Arithmetic overflow is rejected transactionally using the prior state, with
  field marker `usage`. This covers huge integer costs and accumulated float overflow.
- Session-ID validation, usage deduplication, timeout policy, WorkerEvent and
  dispatch wiring remain untouched, as do the other M1 task worktrees.

Validation evidence lives under `C:/AI/reviews/m1-p-f1-*.log`:

- New safety suite: baseline 34 tests / 33 failures; candidate 34 / 0.
- Read-only negative candidate `a5378cc2660c4e86492c2a475d5f825da1659c78`:
  baseline 21 / 11 failures; candidate 21 / 3. All eight shape-safety red tests
  turn green. Remaining failures are two duplicate-accounting tests and one
  foreign-session test, deliberately outside this task. Timeout assertions passed
  in both measured runs; no timeout contract decision is inferred from that.
- Expanded OpenCode mock suites passed 150 / 0 before the final arithmetic
  correction; the correction is covered by the final 34-test safety suite.
  The final existing adapter/config suite passes 77 / 0, matching the exact base.
  An earlier run had three process-boundary timeouts with no JSONL events;
  these did not recur in the expanded or final runs.
- Compile with warnings as errors, specs.check, changed-file formatting and
  git diff whitespace checks pass. Whole-project formatting fails on the same
  three baseline files. Credo has identical baseline/candidate finding counts
  (18 warnings, 60 refactoring, 82 readability, 7 design). Dialyzer has the same
  34 baseline findings after normalizing shifted line numbers; no new finding.

Residual limits: bounds apply per diagnostic record, not to total stream memory
or evidence count. Full JSON parsing still precedes shape validation. Independent
candidate review is pending; this state records implementation, not acceptance.
Closeout and exact committed revision: `C:/AI/reviews/m1-p-f1-closeout.md`.

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

## M1-C OpenCode configuration and routing gate candidate — 2026-10-10

Branch `codex/m1-c-opencode-config-routing-gate`, base `c90e2ad71a70310e6d71b94777f6cbaca081b6c5` (the accepted
baseline, equal to `origin/main`), worktree `C:/AI/symphony-workspaces/m1-c-opencode-config-routing-gate`.
Implementation commit `371687c`. Implementation-only candidate; no push, PR, merge, deployment, or
Linear write was performed, and the deployed runtime configuration is unchanged.

- New optional `opencode` front-matter section in `Config.Schema`: `enabled` (default false), explicit
  `provider` and `model` identity, a bounded `timeout_ms` (default 900000), an explicit
  `allowed_tools` allowlist, and an optional `allowed_issues` pilot scope. The section carries no
  command, credential, environment, or provider-fallback field.
- Validation fails closed. While `enabled` is true, `provider` and `model` must be non-blank and
  `allowed_tools` must be non-empty. Wildcard or unrestricted tool grants (`*`, `all`, `any`, `auto`,
  `auto_approve`, `unrestricted`, case-insensitive) and blank allowlist entries are rejected whether
  or not the section is enabled; a non-positive or non-numeric `timeout_ms` is rejected. An empty
  `allowed_issues` list validates but authorizes no issue.
- `HarnessSelection.select/2` is the pure policy: `{:opencode, :opencode_selected}` only when the section
  is enabled, fully specified, and the issue identifier is listed; `{:codex, reason}` otherwise,
  with reason in `:opencode_disabled`, `:opencode_incomplete`, `:issue_not_authorized`, or
  `:invalid_opencode_config`. It reads only its two arguments, launches no process, writes no
  state, and leaves dispatch, retry, and containment gates untouched.
- Configuration and policy only. No dispatch integration was performed: AgentRunner,
  Orchestrator, WorkerContainment, LaunchMarker, DispatchRouter, the OpenCode adapter branches,
  `WORKFLOW.md`, and the deployed runtime configuration are untouched. OpenCode remains
  unreachable until a separate later step wires the decision in.

Validated on this host (Windows, Elixir 1.19.5 / OTP 28):

- `mix compile --warnings-as-errors` passes.
- `mix specs.check` passes and `mix format --check-formatted` (whole project) passes.
- New focused suites: 27 tests, 0 failures; `mix test --cover` reports 100% line coverage for
  `SymphonyElixir.HarnessSelection` and `SymphonyElixir.Config.Schema.OpenCode`.
- Focused routing regression at seed 424242 (the two new suites plus dispatch_router_test,
  worker_routing_test, fallback_routing_test, fallback_policy_test): 123 tests, 21 failures. The
  pristine `c90e2ad` baseline on this host gives 96 tests with the identical 21 failing
  FallbackRoutingTest names; no introduced failure.
- Config regression at seed 424242 (workspace_and_config_test, core_test, extensions_test,
  source_canonicality_test): 139 tests, 12 failures with a failure-name set identical to the
  pristine baseline at the same seed (pre-existing CoreTest and WorkspaceAndConfigTest host and
  sandbox failures).
- `mix lint` (credo --strict) exits 30 on both candidate and pristine baseline with identical
  finding counts (9 warnings, 37 refactoring, 76 readability, 4 design); no finding points at a
  changed file. `git diff --check` is clean.

The broad Windows test processes printed their complete ExUnit summaries and stayed open; they were
interrupted after results were captured, so their process exits are not claimed as successful.
Dispatch integration and independent exact-head review remain the next separate steps.

## M1-C OpenCode configuration contract hardening — 2026-10-10

Branch `codex/m1-c-opencode-config-routing-gate`, base `c90e2ad71a70310e6d71b94777f6cbaca081b6c5`, worktree
`C:/AI/symphony-workspaces/m1-c-opencode-config-routing-gate`. Hardening commit `6a3c020` on top of the
implementation candidate `371687c` / `2bdfefd`. Implementation-only candidate: no push, PR, merge, deployment, or
Linear write, and the deployed runtime configuration is unchanged.

- `Config.Schema.OpenCode.validate/1` re-checks a hand-built `%OpenCode{}` struct from its own fields, so a struct
  can no longer bypass the unrestricted-tool, unknown-tool, or timeout validation for non-null values.
  `HarnessSelection.select/2` routes maps and structs through it. (Correction recorded with the M1-C-F2 entry
  below: an explicit `null` for `enabled` or `timeout_ms` still bypassed these checks at this commit — Ecto
  records a nil parameter as a change and `validate_number/3` skips nil changes — and `select/2` matched only
  `enabled: false`, so a null `enabled` still selected OpenCode without explicit consent. The blanket "no longer
  bypass" claim above was inaccurate until the M1-C-F2 remediation closed it.)
- `timeout_ms` gained a finite upper bound of `3600000` (one hour). The `900000` default remains the practical M1
  pilot budget; the cap keeps one run inside the `codex.turn_timeout_ms` default so the pilot cannot outlive the
  surrounding worker.
- Tool names are validated against the OpenCode adapter contract. The accepted set is declared once, in
  `OpenCode.known_tool_names/0`, rather than in a second free-standing allowlist; `unknown_tools/1` rejects anything
  outside it (case-sensitive, matching the adapter's trim-only normalization), while wildcard and unrestricted
  rejection stays case-insensitive and unchanged.
- Harness selection no longer collapses every non-selected outcome onto `{:codex, reason}`. An invalid section that
  still lists the issue returns `{:error, :invalid_opencode_config}`; an invalid section that does not list the issue
  returns `{:codex, :invalid_opencode_config}`; absent or disabled sections keep `{:codex, :opencode_disabled}` and a
  non-listed issue keeps `{:codex, :issue_not_authorized}`. An intended OpenCode pilot is therefore never silently
  replaced by Codex. The policy stays pure: `select/2` is still the only public function, and it launches no process,
  writes no state, and reads no runtime configuration.

Compatibility dependency on the OpenCode adapter source:

- The adapter candidate `5df80de` / `da78cbf` owns the accepted tool names in the private `@known_tools` of
  `SymphonyElixir.OpenCode.Config` and rejects unknown names through its public `build/1`. This branch does not
  contain that module, so `OpenCode.known_tool_names/0` mirrors its 15 names and is the single declared source here.
- Integration resolves the dependency in one step: land the adapter branch (or its successor) and remove the adapter's
  private list so `SymphonyElixir.OpenCode.Config` reads the contract from `OpenCode.known_tool_names/0`. The focused
  contract test compiles only when `SymphonyElixir.OpenCode.Config` is loadable and then asserts that the adapter's
  accepted tool map equals `OpenCode.known_tool_names/0` and that an unknown name is rejected, so the two sets cannot
  drift silently once both exist.

Validated on this host (Windows, Elixir 1.19.5 / OTP 28):

- `mix compile --warnings-as-errors` passes (only the benign Phoenix LiveView `:eperm` `node_modules` symlink
  warning).
- `mix specs.check` passes; `mix format --check-formatted` (whole project) passes; `git diff --check` is clean.
- Focused suites `opencode_config_test` + `harness_selection_test`: 35 tests, 0 failures at seed 424242.
- `mix lint`: exit 30 with 9 warnings, 37 refactoring opportunities, 76 readability issues, and 4 design suggestions -
  identical to the finding counts recorded for the previous candidate, and `mix credo --strict` on the four changed
  files reports no issues.
- Focused routing regression at seed 424242 (the two suites plus dispatch_router_test, worker_routing_test,
  fallback_routing_test, fallback_policy_test): 131 tests, 21 failures, all `FallbackRoutingTest`. A pristine
  `c90e2ad` worktree on this host at the same seed gives 96 tests with an identical failure-name set; no introduced
  failure.
- Config regression at seed 424242 (workspace_and_config_test, core_test, extensions_test, source_canonicality_test):
  139 tests, 12 failures with failure names identical to the pristine `c90e2ad` worktree at the same seed
  (pre-existing CoreTest and WorkspaceAndConfigTest host failures).
- The broad Windows test processes printed their complete ExUnit summaries and stayed open; they were interrupted
  after results were captured, so their process exits are not claimed as successful. The baseline comparison used a
  temporary detached worktree at `c90e2ad` (`C:/AI/symphony-workspaces/_m1c-baseline-c90e2ad`), removed after use.

Remaining work before dispatch: wire `HarnessSelection.select/2` into the dispatch path (AgentRunner, Orchestrator,
DispatchRouter), land the OpenCode adapter branch and reconcile the tool contract, and complete independent exact-head
review. `AgentRunner`, `Orchestrator`, `DispatchRouter`, `LaunchMarker`, the OpenCode adapter, `WORKFLOW.md`, and
the deployed runtime configuration are untouched.

## M1-C-F2 OpenCode config nil-bypass remediation — 2026-10-10

Branch `codex/m1-c-opencode-config-routing-gate`, on top of `80028c4` (implementation `371687c` / `2bdfefd`,
hardening `6a3c020`), worktree `C:/AI/symphony-workspaces/m1-c-opencode-config-routing-gate`. Bounded remediation of
the independent-review M1-C-R2 HIGH finding: no push, PR, merge, deployment, or Linear write, and no dispatch wiring,
AgentRunner, or OpenCode adapter change. No other worktree was modified.

- Finding, reproduced at `80028c4`: an explicit `null` for `opencode.enabled` or `opencode.timeout_ms` validated
  successfully in `Config.Schema.OpenCode.validate/1` for both plain maps and hand-built `%OpenCode{}` structs —
  Ecto's `cast/4` records a nil parameter as a change while `validate_number/3` and `validate_change/3` skip nil
  changes — and `HarnessSelection.select/2` matched only `enabled: false`, so a null `enabled` fell into the enabled
  clause and returned `{:opencode, :opencode_selected}` for an allowlisted issue with no explicit opt-in, no
  provider/model/tool identity check, and a null (unbounded) timeout likewise accepted.
- Fix: `OpenCode.changeset/2` rejects an explicit null for the security-critical fields by inspecting the cast
  changes directly — `enabled` with "must not be null: explicit true or false required" and `timeout_ms` with "must
  not be null". `HarnessSelection.select/2` now selects OpenCode only on the literal `%OpenCode{enabled: true}`;
  every other validated section keeps `{:codex, :opencode_disabled}`.
- `Schema.parse/1` YAML null semantics are deliberately preserved: `drop_nil_values/1` strips nulls before the
  OpenCode changeset runs, so a workflow-file null means "absent" and keeps the safe defaults (`enabled: false`,
  `timeout_ms: 900000`), and nulls never lift the enabled-identity requirements (an `enabled: true` section with
  null provider/model/tools still fails on all three). The direct-vs-parse distinction is documented in the
  `OpenCode` moduledoc: a null that reaches `validate/1` from a map or struct is an error.
- Fail-closed selection preserved and extended: an invalid section that still lists the issue returns
  `{:error, :invalid_opencode_config}` — never a silent Codex substitution and never OpenCode authorization — and
  the same invalid section without the issue keeps `{:codex, :invalid_opencode_config}`. Issue allowlisting, tool
  validation, the 3600000 timeout cap, and the provider/model requirements are unchanged. The inaccurate
  "no longer bypass" claim recorded by the previous hardening entry was corrected above.

Validated on this host (Windows, Elixir 1.19.5 / OTP 28):

- Focused suites `opencode_config_test` + `harness_selection_test`: 45 tests, 0 failures at seed 424242 (35 before
  this change). The six new null-rejection tests fail at `80028c4` — verified by running the new test files against
  stashed HEAD code (45 tests, 6 failures) — and pass after the fix. The four new preserved-behavior tests (absent
  defaults, valid map/struct equivalence, and the two YAML-null parse tests) pass unchanged on both, as intended.
- `mix compile --warnings-as-errors`, `mix specs.check`, and `mix format --check-formatted` (whole project) pass;
  `mix credo --strict` on the four changed files reports no issues; `git diff --check` is clean.
- Config regression at seed 424242 (workspace_and_config_test, core_test, extensions_test, source_canonicality_test):
  139 tests, 12 failures, matching the recorded baseline failure set for this host (the `$VAR` expansion failure and
  the pre-existing CoreTest MIC-164 `:epipe` / Git-Bash path-mangling failures).
- Routing regression at seed 424242 (both focused suites plus dispatch_router_test, worker_routing_test,
  fallback_routing_test, fallback_policy_test): 141 tests, 21 failures, all `FallbackRoutingTest` with the recorded
  pre-existing `ISS-FB-*` KeyError signature — the recorded baseline is 131 tests with the identical 21 failures,
  and the +10 are this change's new tests.
- Broad Windows suites were run with output redirected to log files and exited on their own; logs are retained at
  `C:/tmp/m1cf2-config-a.log`, `C:/tmp/m1cf2-config-b.log`, and `C:/tmp/m1cf2-routing.log`.

Scope remains configuration and policy only: dispatch integration, the adapter branch, `WORKFLOW.md`, and the
deployed runtime configuration are untouched, and OpenCode remains unreachable until dispatch wiring lands.
