# OpenCode 1.18.28 Wire Fixtures: Provenance and Contract Baseline

**Document version:** 1.1.0
**Date:** 2026-10-11
**Task:** M1-WIRE-F2 (remediation of the M1-WIRE-F candidate 6459a2da4f1687bb346cb49737c317a20066c5d8)
**Status:** FIXTURE_CONTRACT_BASELINE_REMEDIATED. Not wire-trace certified.

---

## 1. Scope and claims

The fixtures in elixir/test/fixtures/opencode_wire/ are hand-written. Their event order and field names follow upstream OpenCode source and tests at tag v1.18.28. Every value in them is synthetic. No fixture is a captured OpenCode CLI output, and the manifest records captured_from_live_cli false for each one.

The fixtures let the Symphony parser and failure classifier be tested against those shapes. They do not show what a real provider run emits. This document makes no genuine wire-trace certification claim. Authorized live provider captures are still required for that. None were recorded or used here.

This remediation did not call any model or provider, did not read private OpenCode session databases or auth stores, and did not change any production module.

## 2. Upstream verification

| Item | Value | How it was verified |
|---|---|---|
| Upstream repository | anomalyco/opencode | git ls-remote against the public GitHub repository |
| Release tag | v1.18.28 | git ls-remote refs/tags/v1.18.28 returns commit 22006d97652839999596a34a48ff6be7dbb40c6e (lightweight tag) |
| packages/opencode/src/cli/cmd/run.ts | blob cccc2550179f87bb74763004910028f79ade60c9 | Downloaded at the commit and hashed with git hash-object; matches the earlier record |
| packages/schema/src/v1/session.ts | blob 75e9282f117cb25078b087661434fcf5e6660620 | Same method |
| packages/opencode/src/cli/ui.ts | blob 6ad6495cf10bfe604bff172359d682b3fe9d4dee | Same method |
| packages/opencode/test/cli/run/run-process.test.ts | blob d2d4bae879216be6fb79840bea83d2a4054e6bec | Same method |
| packages/opencode/test/provider/error.test.ts | blob 49db2806623dc92c99376111c191f456c28b4a63 | Same method |

Tree-wide searches used a shallow clone of the tag. The other packages cited below (packages/llm and the ID generator) were read at the same tag through that clone.

## 3. Source anchors for the wire contract

Paths are relative to the upstream repository at v1.18.28.

- Envelope and framing. packages/opencode/src/cli/cmd/run.ts lines 678-688: emit() writes a JSON object with type, timestamp, sessionID and the event data, followed by os.EOL. On Windows, Node reports os.EOL as CRLF. That value is read from source. It was not observed in captured output.
- Event mapping. step_start at run.ts 745-746, step_finish at 749-750, text at 754. tool_use at line 725 for tool parts whose state status is completed or error. reasoning at 766-767, only when the part has time.end set and the thinking flag is on. Error records at 788-789 and at the prompt-rejection paths at 855 and 872.
- Part and error schemas. packages/schema/src/v1/session.ts: named errors use the shape name plus data (lines 29-35). AuthError is named ProviderAuthError with providerID and message (lines 38-41). APIError has message, statusCode (optional), isRetryable (boolean), responseHeaders, responseBody and metadata (lines 48-55). step-finish has reason as an open string (Schema.String, line 243), cost, and tokens with total optional (line 247), input, output, reasoning, and cache read and write. ToolStateError has status error, input, error text, optional metadata, and time.
- Finish reason. packages/llm/src/schema/ids.ts line 39 defines FinishReason as stop, length, tool-calls, content-filter, error and unknown. packages/opencode/src/session/llm/ai-sdk.ts lines 22-23 return the reported value only when it is in that union, and return unknown otherwise.
- Token total. packages/llm/src/protocols/shared.ts lines 39-60: a provider-supplied total is the source of truth when present. The fallback is input plus output. The file describes that fallback as under-counting cache and reasoning by design. The file does not state a formula that adds cache and reasoning to the total.
- Identifiers. packages/opencode/src/id/id.ts line 16 sets LENGTH to 26. Line 69 builds a value from the prefix, an underscore, 12 hex characters of time, and base62 characters that fill the rest. Session IDs use the ses prefix, message IDs use msg, and part IDs use prt. In session.ts, lines 17-25 define the msg and prt prefixes. At this tag, the search found no call prefix for tool call IDs. The callID value is supplied by the model SDK.
- Upstream tests. run-process.test.ts line 124 expects step_start, text, step_finish. Lines 155-156 expect a rejected prompt to produce one error record and a nonzero exit code. The test "--format json preserves reasoning, tool, and continuation ordering" expects the sequence at lines 186-194. The test "--format json records an unknown stream finish and continuation" (lines 232-246) expects a step-finish with reason unknown in the middle of a turn, then recovered text and a final stop, with exit code 0. error.test.ts lines 5-22 show that parseStreamError returns type api_error with isRetryable and responseBody, and no statusCode.

## 4. Corrections to the earlier version

Each item below replaces a claim in the earlier version of this document (version 1.0.0).

- The earlier document described identifiers as ULID or KSUID based. The source shows a prefix, an underscore, 12 hex characters, then base62. The fixture identifiers keep the correct prefixes. Their bodies are hand-written and do not follow the generator. They are synthetic.
- The earlier document said tool call IDs use a call prefix. No such prefix exists at v1.18.28 in the searched source. The callID values in the fixtures are synthetic.
- The earlier document gave an upstream formula for the total: input plus output plus reasoning plus cache read plus cache write. It cited the fixture's own total of 8643 as evidence, which is circular, because that total was hand-written. The source says a provider-supplied total is authoritative, and it does not state the formula above. The value 8643 now appears only in the synthetic explicit-total fixture.
- The earlier document said the AI SDK mapper falls back to other. At this tag, the bridge maps unrecognized values to unknown, and other is not in the FinishReason union. The terminal-reason fixture is therefore synthetic.
- The earlier document cited an M1-W protocol audit document and a file named m1-w-opencode-jsonl-protocol-audit.md. Neither is in the repository. Those references are removed. The labels A1, A2, A3 and A5 remain only as gap labels in the tests and in this document. Section 6 gives each one its source anchors.
- The earlier document cited 24 statusCode 403 records found in a local SQLite store. That observation came from a private session store, which this task forbids. It is removed and not used.
- The earlier document said the local OpenCode binary was verified with opencode --version under the APPDATA npm directory. That check was not repeated here, and the claim is removed.
- The earlier document labelled several fixtures as authentic upstream. The labels in section 5 replace that.
- The earlier document said the newline is the OS EOL, which is CRLF on Windows. The source confirms that emit() appends os.EOL. The CRLF value follows from Node's os.EOL on Windows and was not observed in output.

## 5. Provenance labels

Three labels apply to each fixture as a whole. The manifest records the field-level sources.

- cli-emission-shape. The envelope and event order follow emit() and the upstream CLI tests at v1.18.28. All values are synthetic.
- schema-derived. Field names and types follow the upstream Effect schemas at v1.18.28. The fixture combines them into event sequences that the upstream tests do not show, and the emitted presence of optional fields is not established.
- synthetic. A value or combination that the searched v1.18.28 source paths do not produce, or intentionally invalid input. Used as a contract input or a negative control.

| Fixture | Label | tokens.total | Basis |
|---|---|---|---|
| single_turn_success.jsonl | cli-emission-shape | removed | Order from run-process test line 124 |
| multi_step_tool_success.jsonl | cli-emission-shape | removed from both steps | Continuation order from the test at lines 186-194, without the leading reasoning and text events |
| reasoning_thinking_turn.jsonl | cli-emission-shape | removed | Reasoning emit condition at run.ts 766-767 |
| tool_error_recovery.jsonl | schema-derived | removed from both steps | ToolStateError shape. The recovery sequence is not in the upstream tests read |
| terminal_reason_other.jsonl | synthetic | removed | other is not in the FinishReason union at v1.18.28 |
| api_error_retryable_rate_limit.jsonl | schema-derived | not applicable | APIError fields. Presence of statusCode in emitted records is not established |
| api_error_non_retryable_forbidden.jsonl | schema-derived | not applicable | Same basis as the 429 fixture. The SQLite observation is removed |
| provider_auth_error.jsonl | schema-derived | not applicable | ProviderAuthError fields. Emission is not established by the upstream tests read |
| synthetic_malformed_control.jsonl | synthetic | synthetic value 100 kept | Non-JSON control line between valid events |
| synthetic_explicit_total.jsonl | synthetic | explicit synthetic value 8643 | Schema-optional total with a value chosen by the author. Not upstream-observed |
| synthetic_explicit_total_zero.jsonl | synthetic | explicit synthetic value 0 | Schema-optional explicit zero with all components zero |

All identifiers in the fixtures are synthetic. The prefixes follow the upstream generator, and the bodies do not.

## 6. Gate taxonomy

The five expected-red gates in elixir/test/symphony_elixir/opencode_wire_contract_gap_test.exs keep their original assertions. They are now tagged by taxonomy. Neither tag means a demonstrated upstream defect. Each gate is red by design and does not measure product correctness.

Product-policy gates (tag product_policy):

- GATE 1, gap A2. Should total_tokens follow an explicit provider total? Upstream says a provider total is authoritative, but the Parser documents its input-plus-output fallback as intentional. The input is the synthetic fixture synthetic_explicit_total.jsonl. Observed value 963; gate expects 8643.
- GATE 2, gap A3. Should a recovered tool error be allowed to complete the turn? Parser.process_tool_use/2 latches :failed on any tool error, which is an explicit fail-closed design. Whether upstream exits 0 after a recovered tool error was not traced. Observed :failed; gate expects :completed.
- GATE 3, gap A1. Should the Parser accept the finish reason other? The v1.18.28 FinishReason union does not include it, so the input is synthetic. Accepting it would be a hardening choice, not a fix for an observed defect. Observed :failed; gate expects :completed.

Implementation-candidate gates (tag implementation_candidate):

- GATE 4, gap A5 (status). Failure.classify_error_map/1 reads status and does not read statusCode. This is a defect only if the CLI emits statusCode in error records. The schema makes it optional, and the upstream tests read do not show it emitted. Observed :transient_worker_failure; gate expects :persistent_worker_failure.
- GATE 5, gap A5 (name). The name list in Failure.classify_error_map/1 covers AuthError and UnauthorizedError, but not ProviderAuthError, which the schema declares. This is a defect only if the CLI emits that name in an error record, which the upstream tests read do not show. Observed :transient_worker_failure; gate expects :auth_unavailable.

Run one taxonomy with mix test --only product_policy or mix test --only implementation_candidate.

## 7. Upstream behavior outside the five gates

Two upstream observations are not covered by the gates, and this remediation changes nothing for them.

- Unknown finish in the middle of a turn. The upstream test records a step-finish with reason unknown, followed by continued output and a final stop, with exit code 0. The Parser treats any terminal reason, including unknown, as completion when the stream is still running (Parser.apply_step_finish_reason/2). If a stream ends after such a mid-turn unknown with no further completion event, finish/2 reports completed. This may be a fail-open case. It needs a separate decision.
- Provider failure in JSON mode. The same upstream test shows a provider failure appearing as a step-finish with reason unknown, not as an error record. The Parser's error path does not see that case.

Also, upstream error.test.ts shows that parseStreamError returns type api_error with no statusCode. That differs from the APIError schema. The api_error fixtures follow the schema, so they are not what that function returns.

## 8. Validation

- elixir/test/symphony_elixir/opencode_wire_protocol_test.exs: 14 tests, all passing. These cover the manifest, the fixture hygiene rules, the characterization of the current Parser and Failure behavior, framing and chunking invariance, the synthetic explicit total (including zero) and the malformed-line control.
- elixir/test/symphony_elixir/opencode_wire_contract_gap_test.exs: 5 tests, all failing with the same received values as the candidate (963, :failed, :failed, :transient_worker_failure, :transient_worker_failure). Tag split: 3 product_policy, 2 implementation_candidate.
- Formatting was checked with mix format --check-formatted on both test files.

## 9. Remaining limitations

- No live capture exists. Emitted field presence, the newline on Windows, and exit codes after recovered tool errors are not observed.
- Upstream source was read at one tag, and only the paths listed in section 3 were searched.
- Identifiers and values are hand-written. They test shapes, not generator output.
- Gate results are expected red by design. They do not measure whether the product behaves correctly.
- An authorized live provider trace is still required to certify the wire contract.
