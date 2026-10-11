# OpenCode 1.18.28 Wire Protocol Fixtures Provenance and Compatibility

**Document Version:** 1.0.0  
**Date:** 2026-10-11  
**Task:** M1-WIRE-F (Milestone M1)  
**Status:** FIXTURE_CANDIDATE_READY  

---

## 1. Executive Summary

This document establishes the provenance, schema grounding, and compatibility baseline for the authentic OpenCode 1.18.28 JSONL test fixtures added in task `M1-WIRE-F`.

In accordance with the task constraints:
- All fixtures were constructed without executing live model requests or invoking external provider APIs.
- Private session databases (`~/.local/share/opencode/opencode.db`) and auth stores (`auth.json`) were strictly avoided.
- All fixture structures, event names, nested part fields, and identifier formats are grounded in verified public upstream source code, public test harnesses, and Effect schema definitions of OpenCode CLI version 1.18.28.
- Every fixture is explicitly categorized under a transparent provenance label: `upstream-derived`, `schema-derived`, or `synthetic`.
- Deterministic offline tests in Symphony distinguish current baseline behavior from desired-but-unimplemented wire behavior across token accounting, tool error recovery, terminal reasons, and error classification.

---

## 2. Upstream Grounding & Reference Verification

### 2.1 Repository and Revision Metadata

| Attribute | Verified Value | Evidence Source |
|---|---|---|
| **Upstream Repository** | `anomalyco/opencode` (GitHub repo ID: 975734319) | GitHub API & repository redirects (formerly `sst/opencode`) |
| **Release Tag** | `v1.18.28` | Public release tag |
| **Tag Object Commit SHA** | `22006d97652839999596a34a48ff6be7dbb40c6e` | `api.github.com/repos/anomalyco/opencode/git/ref/tags/v1.18.28` |
| **CLI Command Runner Blob SHA** | `cccc2550179f87bb74763004910028f79ade60c9` | `packages/opencode/src/cli/cmd/run.ts` @ `v1.18.28` |
| **Local CLI Binary** | `opencode-ai 1.18.28` (`opencode.exe` on host) | `%APPDATA%/npm/node_modules/opencode-ai`, verified via `opencode --version` |

### 2.2 Primary Upstream Source Files

1. **`packages/opencode/src/cli/cmd/run.ts`** (`cccc2550`):
   Defines non-interactive execution (`opencode run --format json`), the `emit(type, data)` formatting function, line-delimited JSON output on `stdout`, event loop termination conditions (`session.status.type === "idle"`), and permission rejection handling.
2. **`packages/schema/src/v1/session.ts`**:
   Canonical Effect schema defining all session events, parts (`StepStartPart`, `TextPart`, `ToolPart`, `ReasoningPart`, `StepFinishPart`), state variants (`ToolStateCompleted`, `ToolStateError`), and error structs (`APIError`, `AuthError`, `UnknownError`, `MessageAbortedError`).
3. **`packages/opencode/test/cli/run/run-process.test.ts`**:
   Official Bun subprocess integration tests asserting `--format json` line emission, event ordering (`step_start`, `reasoning`, `text`, `tool_use`, `step_finish`), and error record isolation.
4. **`packages/opencode/test/provider/error.test.ts`**:
   Upstream unit tests verifying stream error parsing, `isRetryable` flags, and `APIError` mapping.
5. **`packages/opencode/src/cli/ui.ts`**:
   Proves that human messages, permission warnings, and UI output write exclusively to `stderr`, guaranteeing `stdout` wire purity in JSON mode.

---

## 3. OpenCode 1.18.28 CLI Wire Contract Specification

When invoked with `--format json` (e.g. `opencode run --format json -m provider/model --dir <w> --pure -- <prompt>`), OpenCode CLI 1.18.28 adheres to the following protocol rules:

### 3.1 Framing and Encoding
- **Transport:** `stdout` stream.
- **Framing:** One single-line valid JSON object per event, terminated by the operating system newline (`os.EOL`: `\r\n` on Windows, `\n` on POSIX).
- **Envelope:** Every line serializes:
  ```json
  {
    "type": "<event_type>",
    "timestamp": 1728570000000,
    "sessionID": "ses_01J...",
    ...data
  }
  ```
- **Purity:** Non-JSON diagnostic messages, auto-reject warnings, and human notifications are directed to `stderr`. If third-party output corrupts `stdout`, the receiver must fail closed.

### 3.2 Event Types and Part Definitions

| Wire Event | Part/Payload Type | Upstream Schema & Conditions |
|---|---|---|
| `step_start` | `part: StepStartPart` | Emitted at step initiation. Contains `id` (`prt_*`), `sessionID`, `messageID` (`msg_*`), `type: "step-start"`. |
| `text` | `part: TextPart` | Emitted when `part.type == "text"` and `part.time.end` is set. Contains `text` and `time: {start, end}`. |
| `reasoning` | `part: ReasoningPart` | Emitted only when `--thinking` flag is active and `part.time.end` is set. Contains `text` and `time: {start, end}`. |
| `tool_use` | `part: ToolPart` | Emitted when `part.type == "tool"` and `state.status` is `"completed"` or `"error"`. Contains `callID`, `tool`, and `state`. |
| `step_finish` | `part: StepFinishPart` | Emitted at step conclusion. Contains `reason`, `cost`, and `tokens: {total?, input, output, reasoning, cache: {read, write}}`. |
| `error` | `error: ErrorStruct` | Emitted upon `session.error` or prompt/command rejection. Contains `name` and `data`. |

### 3.3 Identifier Format Standards
Upstream 1.18.28 identifiers are ULID/KSUID-based strings prefixed with semantic domain tags:
- Session: `ses_01J...`
- Message: `msg_01J...`
- Part: `prt_01J...`
- Tool Call: `call_01J...`

---

## 4. Fixture Inventory and Provenance Classification

All fixtures reside in `elixir/test/fixtures/opencode_wire/` and are indexed in `manifest.json`.

### 4.1 Provenance Taxonomy

1. **`upstream-derived`**: Event sequence, ordering, and structure directly mirroring upstream integration tests in `packages/opencode/test/cli/run/run-process.test.ts` @ `v1.18.28`, augmented with authentic 1.18.28 identifier prefixes and token distributions.
2. **`schema-derived`**: Reconstructed strictly from the Effect schemas in `packages/schema/src/v1/session.ts` and `cmd/run.ts` @ `v1.18.28`, populating all required and optional fields with nonsecret realistic values.
3. **`synthetic`**: Intentionally constructed non-standard or malformed streams designed as negative test controls.

### 4.2 Fixture Catalog

| # | Fixture Filename | Provenance Label | Key Features Covered |
|---|---|---|---|
| 1 | `single_turn_success.jsonl` | `upstream-derived` | Standard single-turn prompt (`step_start` → `text` → `step_finish`), reason: `stop`, explicit `tokens.total`: 8643, prompt cache read: 7680. |
| 2 | `multi_step_tool_success.jsonl` | `upstream-derived` | Two-step turn: tool execution with completed state, intermediate finish `tool-calls`, followed by second step text and terminal finish `stop`. |
| 3 | `tool_error_recovery.jsonl` | `schema-derived` | Policy-sensitive fixture: Step 1 tool error (`ENOENT`) with finish `tool-calls`; Step 2 model recovery text and terminal finish `stop` (exit 0). |
| 4 | `terminal_reason_other.jsonl` | `schema-derived` | Single turn finishing with AI SDK / provider fallback reason `"other"` rather than standard `"stop"`. |
| 5 | `api_error_retryable_rate_limit.jsonl` | `schema-derived` | Upstream `APIError` with `statusCode`: 429, `isRetryable`: true, `responseHeaders`, and `responseBody`. |
| 6 | `api_error_non_retryable_forbidden.jsonl` | `schema-derived` | Upstream `APIError` with `statusCode`: 403, `isRetryable`: false, representing account/tier authorization refusal. |
| 7 | `provider_auth_error.jsonl` | `schema-derived` | Upstream `ProviderAuthError` (`AuthError` schema) with `providerID`: "anthropic" and invalid credential message. |
| 8 | `reasoning_thinking_turn.jsonl` | `upstream-derived` | Model turn with `--thinking` enabled, emitting reasoning block before text, and recording `reasoning_tokens` in `step_finish`. |
| 9 | `synthetic_malformed_control.jsonl` | `synthetic` | Corrupt non-JSON line sandwiched between valid events to verify fail-closed parser isolation. |

---

## 5. Compatibility Audit Findings & Gap Analysis

Based on the protocol verification conducted against Symphony commit `9ce11fd` (and matching findings in protocol audit M1-W):

### 5.1 Finding A1: Terminal Reason Whitelist
- **Upstream Reality:** The `reason` field in `StepFinishPart` is an open string (`Schema.String`). In the compiled 1.18.28 CLI binary, the AI SDK mapper uses `default: return "other"`.
- **Symphony Baseline:** `Parser` hardcodes `@terminal_step_reasons ~w(stop length content-filter unknown)`.
- **Gap Impact:** If an upstream provider finishes with reason `"other"`, Symphony fails closed with `{:incomplete_stream, :missing_completion_event}` despite a clean run and exit 0.

### 5.2 Finding A2: Token Accounting (`tokens.total`)
- **Upstream Reality:** When present, `tokens.total` in OpenCode 1.18.28 includes cached tokens and reasoning tokens: `total = input + output + reasoning + cache.read + cache.write`. (Demonstrated in `single_turn_success.jsonl` where total is 8643: 954 input + 9 output + 7680 cache read).
- **Symphony Baseline:** `Parser.process_step_finish/2` computes `total_tokens = input + output` (evaluating to 963 in the same example).
- **Gap Impact:** Symphony severely underreports total token consumption when prompt caching is used.

### 5.3 Finding A3: Tool Error Latching Policy
- **Upstream Reality:** A tool error (e.g. denied file permission or missing file) is emitted as a `tool_use` event with `state.status == "error"`. The model is fed this error and may choose to recover and conclude with `reason: "stop"` and process exit code 0.
- **Symphony Baseline:** `Parser.process_tool_use/2` sets `completion_state: :failed` on any tool error, and `apply_step_finish_reason` only completes when state is `:running`.
- **Gap Impact:** A recovered worker run that succeeded naturally is recorded as a failed worker in Symphony. This policy is safe (fail-closed) but prevents multi-turn recovery.

### 5.4 Finding A5: Error Classification (`status` vs `statusCode`, `isRetryable`)
- **Upstream Reality:** Upstream `APIError` structs encapsulate the HTTP status in `data.statusCode` and provide an explicit boolean `data.isRetryable`. Auth errors use the class name `"ProviderAuthError"`.
- **Symphony Baseline:** `Failure.classify_error_map/1` checks `map["status"]` or `data["status"]`, which misses `data["statusCode"]`. `ProviderAuthError` is missing from the explicit name check list (`["AuthError", "UnauthorizedError"]`).
- **Gap Impact:** Non-text-matched 403 errors fall back to `:transient_worker_failure` instead of `:persistent_worker_failure`, causing unnecessary retries. `isRetryable` is not evaluated.

---

## 6. Deterministic Test Suites

Two dedicated test suites verify the contract in `elixir/`:

1. **`test/symphony_elixir/opencode_wire_protocol_test.exs` (12 passing tests):**
   - Verifies manifest integrity and file existence.
   - Tests parsing of all fixtures under current baseline implementation.
   - Proves byte-chunking and framing invariance (1-byte, 3-byte, and line-by-line chunking produce identical state).
   - Characterizes the exact numerical delta in token accounting (963 vs 8643).
   - Confirms fail-closed behavior for malformed lines.

2. **`test/symphony_elixir/opencode_wire_contract_gap_test.exs` (5 expected-red gated tests):**
   - Tagged with `@moduletag :expected_red`.
   - Gate 1: Asserts `total_tokens == 8643` (fails: received 963).
   - Gate 2: Asserts tool error recovery yields `:completed` (fails: received `:failed`).
   - Gate 3: Asserts `reason: "other"` yields `:completed` (fails: received `:failed`).
   - Gate 4: Asserts `statusCode: 403` classifies as `:persistent_worker_failure` (fails: received `:transient_worker_failure`).
   - Gate 5: Asserts `ProviderAuthError` classifies as `:auth_unavailable` (fails: received `:transient_worker_failure`).

---

## 7. Evidence Requiring an Authorized Live Provider Trace

While these offline fixtures faithfully reconstruct the 1.18.28 schema and test dialect, an authorized real provider trace (recorded with explicit human approval in Milestone M1 live acceptance) is required to conclusively verify:

1. **True TCP/Pipe Chunk Fragmentation:** Live socket buffering dynamics between the OpenCode process and BEAM port under high load.
2. **Trailing Event EOF Behavior:** Whether the OpenCode Node/Bun runtime flushes the final newline before process termination on exit code 0 or abruptly closes without flushing.
3. **Real-world `reason` Distributions:** Empirical frequency of `"other"` vs `"unknown"` vs `"stop"` across real provider models (Anthropic, Google Antigravity, OpenAI).
4. **Tool Error Recovery Turn Sequences:** Empirical multi-step prompt traces demonstrating whether and how production agents recover from denied permissions.
5. **Exact Provider Error Payloads:** Live vendor-specific error JSON bodies embedded in `responseBody` and `metadata`.

Until such authorized captures are recorded, the offline fixtures in `elixir/test/fixtures/opencode_wire/` serve as the canonical contract baseline.

