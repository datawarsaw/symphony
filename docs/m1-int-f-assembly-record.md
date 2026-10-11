# M1-INT-F — Symphony M1 Final Candidate Assembly Record

Date: 2026-10-11. Worktree `C:/AI/symphony-workspaces/m1-integration-assembly`,
branch `integration/m1-candidate-assembly`. Baseline `9ce11fd3a9db817d1930e372749fd13ce4b08951`
(M1-D), verified exact HEAD, clean worktree at start. The protected source checkout
and dirty runtime were not modified. No push, PR, merge to main, deployment, pilot,
or live provider call was performed. Human Acceptance remains a separate gate.

## Checkpoint commits (this integration, in order)

| Checkpoint | Commit | Content |
| --- | --- | --- |
| CP1 | `6459a2d` + `4286912` (exact identity, bundle transfer + ff) | M1-WIRE-F fixtures + F2 provenance remediation |
| CP1 | `8adcffa` | M1-I1 redactor UTF-8/bounded-resource remediation (from be77946) |
| CP1 | `91a434c` | M1-C config-contract hardening prerequisite (from 6a3c020) |
| CP1 | `6298a4b` | M1-C-F2 null-bypass remediation (from 4f1dc51) |
| CP2 | `92346c8`, `dfce84c`, `b0cc39c`, `5001415` | parser safety, session integrity, token accounting U-F/U-F2 |
| CP2 | `31529e5` | additive-contract test reconciliation (see below) |
| CP3 | `7b636d4`, `651b158` | M1-H-F remote-host refusal, M1-JOB-F atomic Job containment |
| CP4 | `3bf0e43`, `bedabf4`, `fa28cca`, `2bb51e6` | M1-SEM-F, M1-TERM-F, M1-API-F, M1-HARNESS-F (dispatch fusion) |
| CP5 | `03a1345`, `4b9b955` | M1-T2 ordering regression transplant + fix (timeout fusion `:timeout`) |
| CP5 | `26057f6` | ordering expectation reconciliation (session integrity, additive totals) |
| CP5 | `bbcc1fb`, `d788221`, `11c0201`, `fe7f4b2` | acceptance reconciliation, BEAM death recovery, negative contract x2 |
| CP5 | `6612dbb` | acceptance + wire-protocol documentation reconciliation |
| CP6 | `7c6f691`, `d85047c` | formatting gate, `@spec` gate — `mix format --check-formatted`, `mix specs.check` pass |

## Incorporated candidate inventory (source SHA -> integration)

- Redactor be77946 -> 8adcffa (clean)
- Config hardening prerequisite 6a3c020 -> 91a434c (clean; prerequisite of 4f1dc51)
- Configuration 4f1dc51 -> 6298a4b (state-file conflict, both records kept)
- Remote-host eligibility f684cb5 -> 7b636d4 (clean)
- Parser safety 625c8c1 -> 92346c8 (state conflict, both records kept)
- Session integrity a71b3bf -> dfce84c (clean)
- Token accounting 6c14953 -> b0cc39c (clean); dc3a74b -> 5001415 (clean)
- Windows atomic containment 43c1c9a -> 651b158 (clean; helper exe rebuilt per-checkout)
- Completion semantics 4406df8 -> 3bf0e43 (parser.ex conflict: kept P-F1 shape validation)
- Terminal safety a91ede8 -> bedabf4 (parser moduledoc conflict: TERM-F semantics + P-F2 lines)
- API failure classification f0b6ee4 -> fa28cca (state conflict, both records kept)
- Harness authority c088b57 -> 2bb51e6 (dispatch-site fusion, below)
- Event ordering 887597f -> 03a1345 + 9def8a1 -> 4b9b955 (selective transplant; db1350c NOT imported)
- Wire fixtures 6459a2d + 4286912 -> exact identity via local bundle + ff merge
- Acceptance reconciliation c232b9c -> bbcc1fb (clean)
- BEAM recovery 99b10b7 -> d788221 (clean)
- Negative contract 4f74649 -> 11c0201 + a5378cc -> fe7f4b2 (clean)

Obsolete db1350c was not imported; no historical T2 branch merge occurred.

## Manual semantic reconciliations

1. **Dispatch-site fusion (M1-H-F x M1-HARNESS-F)** — `resolve_attempt_harness/2`
   now owns dispatch; the `{:dispatch, :opencode, pilot, pin}` branch retains the
   `worker_host != nil -> park_opencode_remote_host/3` refusal BEFORE pin commit
   and spawn. A pinned OpenCode lifecycle can never re-authorize a remote launch.
2. **Timeout fusion (M1-T2 x M1-SEM/TERM)** — `timeout_result/4` calls
   `finish_and_dispatch(parser, :timeout, on_event)`; never `nil` status.
3. **Parser moduledoc/code (M1-P-F1 x M1-SEM/TERM)** — P-F1's fail-closed shape
   validation kept; SEM/TERM completion semantics layered on top.
4. **Additive token contract (M1-U-F/U-F2 supersede older expectations)** —
   parser-safety (7->9), session-integrity (30->45, 60->90), ordering (250->300),
   acceptance (300->385) and wire-protocol (963->8643, 1650->2250) totals
   reconciled to the five-category additive sum; explicit wire totals honored.
5. **Malformed shapes** — session-integrity raise-expectations reconciled to
   P-F1's structured fail-closed evidence (`invalid_event_shape` reasons).
6. **Session conflict on ordering path** — mid-stream rogue session now asserts
   P-F2's fail-closed `conflicting_session_id` (chronological canonical lock
   preserved, rogue event never silently dropped).
7. **HarnessSelection fail-closed errors (M1-C-F2)** — acceptance suite updated:
   invalid allowlisted section -> `{:error, :invalid_opencode_config}`; same
   section without the issue -> `{:codex, :invalid_opencode_config}`.
8. **Recovered tool errors (M1-SEM)** — wire-protocol documentation test asserts
   protocol completion with `tool_failures` evidence retained (success still
   blocked downstream); finish reason "other" observationally terminal but
   never eligible; statusCode 403 persistent (M1-API-F).
9. **Formatting/spec gates** — five files formatted (whitespace only); two
   `@spec` declarations added to HARNESS-F test seams.

## Test evidence

- CP0 baseline (full offline, this host): 1188 tests, 55 failures, 10 skipped.
  Failure clusters: AppServerTest `:epipe` (codex binary pipe), FallbackRouting
  `ISS-FB-*` KeyError, BeforeRemoveTest gh-auth env, CoreTest timing. No
  OpenCode-lane failures. Logs: `_cp0_baseline_tests.log`, `_cp0_failure_names.txt`.
- CP6 final (full offline): **1441 tests, 55 failures, 15 skipped** — the 55
  failure identities are byte-identical to CP0 (diff clean), sampled signatures
  unchanged (`:epipe`, KeyError `%{}`, `assert log =~ "auth status"`, timing).
  +253 tests all passing; +5 skipped are env-gated variants in new suites.
  No new regression. Logs: `_cp6_full_tests.log`, `_cp6_failure_names.txt`.
- Focused lanes (all 0 failures): wire protocol+gap 19 (five former expected-red
  gates now genuinely green), parser safety/session/worker_event 92, opencode/
  dispatch/smoke 108, host eligibility + containment + fences 69, harness
  authority + completion + terminal + failure + retry store 79, ordering 11,
  acceptance + BEAM + negative contract 61, Windows lease/BEAM/host/authority 27.
- Gates: `mix compile --warnings-as-errors` 0 warnings; `mix format
  --check-formatted` clean; `mix specs.check` clean; `mix credo --strict`
  project-wide findings are inherited (191 issues, none on integration-authored
  lines, zero high-priority in touched production files).
- Windows-only behavior validated natively on win32 (fault-injection suite 3/3
  after rebuilding the per-checkout jobrun.exe artifact; stale `_build` exe was
  the cause of two apparent failures, not a code regression).

## Offline safety

All suites run with mocks/fixtures; live e2e modules self-skip without env
gates (`SYMPHONY_RUN_*_LIVE_E2E` unset). No real provider was invoked.

## Unresolved / notes for review

- 55 inherited baseline failures remain (environmental: codex-binary pipes,
  gh auth, timing) — identical to pre-integration baseline, tracked separately.
- Credo strict project-wide debt predates this integration.
- `_build` jobrun.exe staleness: any fresh checkout must run
  `MIX_ENV=test mix jobrun.build` before the fault-injection suite.
