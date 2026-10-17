# M1-INT-F — Symphony M1 Final Candidate Assembly Record

Date: 2026-10-11. Worktree `C:/AI/symphony-workspaces/m1-integration-assembly`,
branch `integration/m1-candidate-assembly`. Baseline `9ce11fd3a9db817d1930e372749fd13ce4b08951`
(M1-D), verified exact HEAD, clean worktree at start. The protected source checkout
and dirty runtime were not modified. No push, PR, merge to main, deployment, pilot,
or live provider call was performed. Human Acceptance remains a separate gate.

**M1-CLOSEOUT-F amendment (2026-10-11).** After the independent reviews
(M1-INT-R2, M1-E2E-R2, M1-EVID-R — all PASS_WITH_NOTES on Final Assembly
`2801201cb883f9be5a3a05a4330f26ec4b721dd2`), this record was amended to correct
the Credo evidence, make the runs reproducible, add evidence-integrity
references, and record the removal of the three stale "pending 4f1dc51"
acceptance tests. Reviewer verdicts are preserved verbatim and were not
altered. Production behavior is unchanged by the closeout commit.

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
| CP7 | (this commit) | M1-CLOSEOUT-F: stale pending-test removal, evidence corrections and integrity references |

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

**"17 accepted candidates" counting rule.** The inventory above lists 17
bullets — one per accepted candidate line (source branch), which is also 17
distinct source branches. The count is of candidate lines, not commits: four
lines contributed two revisions each (M1-C `6a3c020`+`4f1dc51`, T2
`887597f`+`9def8a1`, P-N `4f74649`+`a5378cc`, WIRE-F `6459a2d` plus the
bundle-transfer follow-up `4286912` fast-forwarded onto this branch), for 21
incorporated source revisions in total, and U-F/U-F2 (`6c14953`, `dc3a74b`)
are two branches sharing one bullet — which is why bullet count and branch
count coincide at 17. The obsolete `db1350c` line (superseded M1-E acceptance
tests) is the one reviewed candidate line that was NOT accepted.

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

All full-suite and focused runs are offline (mocks/fixtures); live e2e modules
self-skip without their env gates. Seeds and totals below are **recorded**
(quoted from the committed logs) unless explicitly marked **reconstructed**
(inferred after the fact — the shell command line itself was not captured in
the logs; only the ExUnit banner line was).

- CP0 baseline (full offline, this host, `9ce11fd`): **1188 tests, 55
  failures, 10 skipped** (recorded; seed `99809`, `max_cases: 32`).
  Failure clusters: AppServerTest `:epipe` (codex binary pipe), FallbackRouting
  `ISS-FB-*` KeyError, BeforeRemoveTest gh-auth env, CoreTest timing. No
  OpenCode-lane failures. Logs: `_cp0_baseline_tests.log`,
  `_cp0_failure_names.txt`.
- CP6 final, before closeout (full offline, `2801201`): **1441 tests, 55
  failures, 15 skipped** (recorded; seed `203150`, `max_cases: 32`). The 55
  failure identities match CP0 exactly after failure-name normalization (see
  "Evidence integrity"); sampled signatures unchanged (`:epipe`, KeyError
  `%{}`, `assert log =~ "auth status"`, timing). +253 tests all passing. The
  +5 skips over CP0 are: two opt-in BEAM-death scenarios
  (`SYMPHONY_RUN_BEAM_DEATH_E2E` unset in the ungated run) and the three now
  stale "pending 4f1dc51" acceptance tests (removed by CP7 below). No new
  regression. Logs: `_cp6_full_tests.log`, `_cp6_failure_names.txt`.
- Independent M1-E2E-R2 reproduction (reviewer worktree, trace runs with
  `max_cases: 1`; seeds recorded `72296` at CP0 and `497075` at `2801201`):
  same totals (1188/55/10 and 1441/55/15), **55/55 matching failure
  identities**, and **54/55 matching normalized signatures** — the one drift
  is `app server blocks freeform tool input prompts (AppServerTest)`, which
  failed as `:epipe` at CP0 and as an assert-match in the final run: an
  environmental timing-mode change of the same underlying codex-pipe
  condition, not a production-behavior change. Five formerly expected-red
  wire-protocol gates are active and passing, and the opt-in BEAM-death
  scenarios were executed successfully under
  `SYMPHONY_RUN_BEAM_DEATH_E2E=1` (after the native jobrun rebuild below).
  Evidence: `_m1e2e-r2-evidence/` (untracked, local review artifacts —
  see "Evidence integrity").
- CP7 closeout, after removing the three stale pending tests (measured on the
  affected files this date): `opencode_offline_acceptance_test.exs` went from
  38 tests / 3 skipped (pre-change run, seed `27436`) to **35 tests / 0
  skipped**, and together with `opencode_config_test.exs` (which holds the
  active `OpenCode.validate/1` null-rejection coverage) both files pass:
  **62 tests, 0 failures, 0 skipped** (post-change run, seed `53036`).
  Suite-level arithmetic — **not** a rerun of the full suite and **not** a
  replacement CP6 measurement: 1441 − 3 = **1438 tests**, 15 − 3 = **12
  skipped**, failures unchanged at the 55 environmental baseline. The +2
  skips over CP0 that remain are the two opt-in BEAM-death scenarios.
- Focused lanes (all 0 failures): wire protocol+gap 19 (five former expected-red
  gates now genuinely green), parser safety/session/worker_event 92, opencode/
  dispatch/smoke 108, host eligibility + containment + fences 69, harness
  authority + completion + terminal + failure + retry store 79, ordering 11,
  acceptance + BEAM + negative contract 61, Windows lease/BEAM/host/authority 27.
- Windows-only behavior validated natively on win32 (fault-injection suite 3/3
  after rebuilding the per-checkout jobrun.exe artifact; stale `_build` exe was
  the cause of two apparent failures, not a code regression).

### Static gates and Credo

- `mix compile --warnings-as-errors` 0 warnings; `mix format
  --check-formatted` clean; `mix specs.check` clean.
- **Credo, corrected (supersedes the earlier "all inherited" claim, which was
  wrong and is withdrawn).** Two sources, kept distinct:
  - *Independently reproduced in this closeout* (`mix credo --strict` on
    `2801201`, JSON format): **191 total findings** across 51 files (23
    warnings, 65 refactoring, 92 readability, 11 design — credo's own
    summary). Credo's top urgency tier in this tree comprises 7 findings: two
    `MapJoin` refactor suggestions (`lib/symphony_elixir/steering.ex:253` —
    a file the integration did not touch — and
    `test/support/opencode_worker_fixture.exs:362`) and five
    `ExpensiveEmptyEnumCheck` `length/1` warnings in OpenCode test files.
  - *Reviewer findings (M1-E2E-R2, blame-based attribution, not re-derived
    line-by-line in this closeout)*: of the 191, **29 sit on integration-era
    lines — 9 in production source and 20 in test source — and none of those
    29 were confirmed as high-priority** after review (the top-urgency items
    above are efficiency suggestions; the reviewer's confirmation pass judged
    none of the 29 confirmed-high). The earlier statement that project-wide
    findings were "inherited (none on integration-authored lines)" was
    incorrect: 29 findings are on integration-era lines.
- No production code was refactored to silence Credo in this integration or
  closeout; Credo debt is tracked separately.

## Offline safety

All suites run with mocks/fixtures; live e2e modules self-skip without env
gates (`SYMPHONY_RUN_*_LIVE_E2E` unset). No real provider was invoked.

## Reproducibility

Recorded facts below are quoted from committed logs or git metadata;
reconstructed items are marked and are command shapes inferred from the
recorded ExUnit banners, not captured shell history.

- **Revisions.** CP0 baseline: `9ce11fd3a9db817d1930e372749fd13ce4b08951`
  (M1-D). Final Assembly under review: `2801201cb883f9be5a3a05a4330f26ec4b721dd2`.
  Candidate source SHAs: the inventory above (17 lines / 21 revisions).
- **Branch and worktree.** Branch `integration/m1-candidate-assembly`,
  worktree `C:/AI/symphony-workspaces/m1-integration-assembly` (isolated; the
  protected source checkout at `C:/Users/micha/symphony-source` and the dirty
  runtime were never touched). Independent reviews ran in detached worktrees
  `m1-int-r2-review`, `m1e2e-r2-cp0` (`9ce11fd`) and `m1e2e-r2-final`
  (`2801201`).
- **Host and toolchain.** Windows 10 (10.0.26300 x64), 16 schedulers, Elixir
  1.19.5 / Erlang-OTP 28 (erts-16.4), Mix 1.19.5. `mix test` on this host
  defaults to `max_cases: 32` (twice the 16 schedulers).
- **MIX_ENV and commands.** All test runs under `MIX_ENV=test` (implied by
  `mix test`). Full-suite CP0/CP6 command, **reconstructed**: `mix test`
  (from `elixir/`) — the banners record seed and `max_cases: 32`, matching
  the host default, so no flags were passed; the seeds were auto-generated
  and are quoted from the banners (`99809`, `203150`). Independent E2E-R2
  trace runs, **reconstructed**: `mix test --trace --max-cases 1` (banners
  record `max_cases: 1` and `--trace`-verbose output; seeds auto-generated:
  `72296` CP0, `497075` final). Closeout focused runs, **recorded this
  date**: `mix test test/symphony_elixir/opencode_offline_acceptance_test.exs
  test/symphony_elixir/opencode_config_test.exs` → seeds `27436` (pre-change)
  and `53036` (post-change).
- **Native jobrun prerequisite.** Any fresh checkout must run `MIX_ENV=test
  mix jobrun.build` before the fault-injection and BEAM-death suites; the
  committed source builds a per-checkout `jobrun.exe` and a stale `_build`
  artifact produces spurious failures (observed and resolved during CP6).
- **Opt-in environment gates.** `SYMPHONY_RUN_BEAM_DEATH_E2E=1` enables the
  two-BEAM death/recovery scenarios (`beam_death_recovery_test.exs`); without
  it they count as the two opt-in skips. `SYMPHONY_RUN_RUNTIME_LEASE_E2E=1`
  enables the real runtime-lease scenarios. Live provider gates
  (`SYMPHONY_RUN_GITHUB_LIVE_E2E`, `..._GITLAB_...`, `..._JIRA_...`,
  `..._ASANA_...`, `..._LINEAR_...`) were unset in every cited run — the
  10 CP0-era skips include 6 live-provider and 4 runtime-lease scenarios.
- **Evidence sources.** Full-suite: the two committed logs below. Focused
  lanes: run in the assembly worktree during CP1–CP6 (outputs not retained
  verbatim; counts quoted above). Static gates: rerun in this closeout (see
  "M1-CLOSEOUT-F changes and validation"). Independent E2E: `_m1e2e-r2-evidence/`
  local review artifacts (see integrity note).

## Evidence integrity and hygiene

- **Tracked evidence artifacts** (unchanged by CP7; blob IDs therefore valid
  at both `2801201` and the closeout commit):

  | Artifact | Git blob | SHA-256 |
  | --- | --- | --- |
  | `_cp0_baseline_tests.log` | `d1828004c45f01bc9ede18aef2ae9fbe32458e18` | `0a80f3aaf495abd84704eb0588ed2abba38289a15e451efdc3b2c84ad7768262` |
  | `_cp0_failure_names.txt` | `955f2919132f6ecca9871c5630d3dc72e9ea2759` | `f2c3d9cc7d0be0df0aba79ddcffa20d306181b5a0ac83d307ad962b02c84d3ca` |
  | `_cp6_full_tests.log` | `aa7f6f0aa050a48d45a50b6553bfc69c39a2bfed` | `fd37d105a27a202522b35d4f8f98decd091faf24becc63b04e5147d7cdde9863` |
  | `_cp6_failure_names.txt` | `68c7dc54241692a9913b993dc750fa466b5707d4` | `cb9ad1866ce93b44f7e1dbd41c4a2012cccaad2964a9ac919d041f1dae86ed56` |

- **CP0 failure-name count-prefix normalization.** The two failure-name
  extracts are not byte-identical as files: `_cp0_failure_names.txt` lines
  carry ExUnit's recurring-failure count prefix (`      1 test <name>
  (<Module>)`, in first-occurrence order), while `_cp6_failure_names.txt`
  lines carry the numbered-list form (`test <name> (<Module>)`, sorted). The
  "55 matching failure identities" comparison therefore normalized both:
  strip `^\s*1 test ` from CP0 and `^test ` from CP6, then sort both and
  diff — the resulting 55-line sets are identical (re-verified in this
  closeout on the blob IDs above). The earlier phrasing "byte-identical
  (diff clean)" referred to this normalized comparison, not a raw file diff.
- **Committed-log hygiene scan (this closeout).** Both full-suite logs
  contain local absolute paths with the reviewing username — nine lines in
  `_cp0_baseline_tests.log` and ten in `_cp6_full_tests.log`, all of the
  shape `C:\Users\micha\AppData\Local\Temp\...` leaking from git
  push/pull fixture output inside test transcripts. A pattern scan for
  credential-like strings (token/secret/password/api-key/authorization/
  bearer, excluding token-accounting vocabulary) found **no plausible
  sensitive values** in either log. **Recommendation:** the raw logs should
  remain tracked — they are the only byte-stable record behind the CP0↔CP6
  identity claim, and the only exposure is a username and temp paths, which
  is acceptable for this private repository; future evidence logs should
  scrub local paths before committing, or stay untracked, if they ever
  capture credentials or non-temp working-tree paths.
- **Untracked review artifacts.** The independent E2E-R2 working evidence
  (`_m1e2e-r2-evidence/` in the parent workspaces directory: full trace logs,
  signature extracts, skip lists and the `sigs.py` normalizer) is not part of
  the repository. The facts quoted in "Test evidence" above were extracted
  from those files verbatim during this closeout; the files themselves remain
  local review artifacts with their original provenance (M1-E2E-R2 reviewer
  worktrees at `9ce11fd` and `2801201`), and nothing was published, deleted
  or rewritten.

## M1-CLOSEOUT-F changes and validation

Scope of the closeout commit (CP7): documentation and stale-test cleanup
only — no production Elixir module, no C# jobrun helper, no harness/dispatch
logic, no parser/adapter/WorkerEvent change.

- **Stale pending tests removed** (3): the "pending 4f1dc51" tests in
  `opencode_offline_acceptance_test.exs` asserted a raw
  `OpenCodeSchema.changeset(struct_with_null, %{})` rejection shape that the
  integrated remediation deliberately does NOT implement — production
  validates through `OpenCode.validate/1` (`91a434c` + `6298a4b`), which
  re-casts map and struct input through the changeset so explicit nulls are
  rejected while raw struct-to-struct changesets see no change. Rewriting
  them against `validate/1` would have produced exact duplicates of the
  active "opencode explicit null validation" tests already in
  `opencode_config_test.exs` (same inputs, both map and struct forms, same
  error messages, including the both-fields null-only case), so the stale
  tests, their `@null_base`/`@null_base_struct` attributes, the `null_errors/1`
  helper and the stale "remediation pending / validate/1 does not exist here"
  comments were removed instead. The acceptance suite keeps its behavioral
  dispatch-boundary null test (`HarnessSelection.select` fail-closed), and
  the moduledoc no longer claims pending coverage. No false coverage claims
  remain: before/after on the file is 38 tests / 3 skipped → 35 tests / 0
  skipped.
- **Validation run this date (all in the assembly worktree):**
  - `mix test test/symphony_elixir/opencode_offline_acceptance_test.exs
    test/symphony_elixir/opencode_config_test.exs` → 62 tests, 0 failures
    (pre-change control run: 38 tests, 0 failures, 3 skipped).
  - `mix compile --warnings-as-errors` → clean, exit 0.
  - `mix format --check-formatted` → clean, exit 0.
  - `mix specs.check` → "all public functions have @spec or exemption",
    exit 0.
  - `mix credo --strict` → 191 findings, matching the reviewer total (see
    "Static gates and Credo").
  - The full multi-hour suite was intentionally NOT rerun: nothing in the
    change invalidates the CP6 evidence, and the suite-level effect of the
    removal is exactly 3 fewer skipped tests (arithmetic above).

## Unresolved / notes for review

- 55 inherited baseline failures remain (environmental: codex-binary pipes,
  gh auth, timing) — identical to pre-integration baseline, tracked separately.
- Credo strict project-wide debt (191 findings, 29 on integration-era lines —
  9 production / 20 test, none confirmed high-priority) predates or accompanies
  this integration; repayment is tracked separately, not in this closeout.
- `_build` jobrun.exe staleness: any fresh checkout must run
  `MIX_ENV=test mix jobrun.build` before the fault-injection suite.
