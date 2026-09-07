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
