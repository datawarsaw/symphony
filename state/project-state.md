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
