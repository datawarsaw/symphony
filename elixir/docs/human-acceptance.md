# Human Acceptance evidence pack (v1)

The post-review flow produces one structured Linear comment headed `[HUMAN ACCEPTANCE]`.
It is a deterministic summary of supplied evidence, not another agent, dashboard, or media service.
The implementation worker continues to stop at `In Review` and preserve the workspace.
MIC-166 owns reviewer dispatch. This entry point is available independently of that dispatch.

## Invocation and ownership

From `elixir/`, preview a trusted JSON snapshot:

```sh
mix human_acceptance --input evidence.json
```

The serialized post-review owner publishes with the existing Linear workflow credentials:

```sh
mix human_acceptance --input evidence.json --publish MIC-185 --workflow WORKFLOW.md
```

Programmatic callers use `SymphonyElixir.HumanAcceptance.publish(issue_id, evidence)`.
Publication is allowed in `In Review` or `Human Acceptance`. Repeated calls update the active
comment carrying `<!-- symphony-human-acceptance:v1 -->`; they never overwrite the workpad.
Ambiguous duplicate active comments and provider errors fail closed. Calls for each issue must
be serialized by the post-review owner: Linear comment creation is not an atomic upsert.
Do not blindly retry an ambiguous write timeout without rereading comments.

No call changes issue state, starts the scheduler, dispatches a reviewer, or performs delivery.
The caller must collect and verify the **current** target under its issue/workspace lock, invoke
the generator, and recheck that target before any separately owned Human Acceptance transition.
`ready: true` means the supplied current-target review gate passed; it is not a statement that
missing test evidence exists. `ready: false` must block that transition. A standalone JSON file
is a trusted input contract, not proof of authenticity or freshness by itself.

## Snapshot contract

All keys are strings. Unsupported or missing versions render as draft. This minimal example
deliberately lacks a reviewer and therefore cannot be ready:

```json
{
  "schema_version": 1,
  "task_type": "backend",
  "target": {
    "repository": "symphony-runtime",
    "workspace": "C:/work/MIC-185",
    "base_revision": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "revision": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "branch": "prepared-branch"
  },
  "summary": [
    {"text": "Reject stale reviewer receipts", "source": "workpad entry or diff reference"}
  ],
  "changed_files": [
    {"text": "lib/review.ex: validates the target", "source": "changed-file receipt"}
  ],
  "tests": [
    {
      "command": "mix test test/review_test.exs --seed 1",
      "result": "PASS",
      "phase": "regression",
      "revision": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "source": "validation run receipt",
      "detail": "1 test, 0 failures"
    }
  ],
  "risks": [{"text": "Concurrent writers require caller serialization", "source": "design review"}],
  "unchanged": [{"text": "Reviewer dispatch", "source": "diff inspection"}]
}
```

The producer must supply a full lowercase 40-character base commit SHA. `revision` is either
a full committed SHA representing the complete candidate, or `sha256:<64 lowercase hex>` for
an immutable workspace snapshot. For uncommitted work, never reuse the base HEAD as the candidate
revision. The producer must fingerprint the complete candidate, including tracked modifications,
deletions and untracked implementation files, and reuse that exact snapshot identity for validation
and review. The generator intentionally does not run Git, enumerate files, or invent a fingerprint.
`repository` and `workspace` must be nonempty; a missing branch is shown as `NOT AVAILABLE`.

The independent review producer supplies:

```json
{
  "schema_version": 1,
  "verdict": "PASS",
  "reviewer": "independent reviewer identity",
  "source": "structured reviewer receipt reference",
  "target": {"...": "the entire exact target object from the reviewed snapshot"},
  "findings": "Evidence-backed reviewer conclusion"
}
```

Place that object in `reviewer`. Only version 1, uppercase `PASS`, nonempty reviewer/source,
and exact target-object equality clear the gate. FAIL, malformed results, short SHAs, missing
receipts, and mismatched workspace/repository/base/revision/branch yield `DRAFT — NOT READY`.
The supplied verdict and reviewed target remain visible so stale evidence cannot masquerade
as current review. The generator trusts the post-review producer's identity and source checks;
implementation-agent prose is not a structured independent reviewer receipt.

## Proportional content

| Task type | Shape and evidence |
| --- | --- |
| `backend` | Supplied pseudocode/Mermaid when useful, otherwise sourced file map; exact tests |
| `frontend` | Supplied component tree or file map; tests; optional configured UI receipts |
| `infra` | Supplied before/after topology or execution flow; exact command/output evidence |
| `bugfix` | Supplied call stack/file map; reproduction, before, after and regression test phases |
| `trivial` | Short summary/file map and directly relevant validation |

`shape` accepts `{kind, content, source}` with kind `mermaid`, `component_tree`, `call_stack`,
`file_map`, `pseudocode`, or `topology`. Unsupported or unsourced shapes fall back to
`changed_files`; no diagram is inferred. A producer chooses the shape that helps the reviewer.
The summary retains up to six sourced bullets, with fewer for small tasks; no padding is invented.
Tests retain up to eight receipts; file maps twelve; omissions are explicitly counted.

`tests` includes exact commands and `PASS`, `FAIL`, or `NOT RUN` results, optional phase,
revision, and bounded output detail. No test is executed or its result inferred by the renderer.
For TDD, provide separate before/failing and after/passing receipts; never reconstruct a red run
from a green run. Unknown results and absent sources are explicitly unavailable.

For `frontend` only, `ui_evidence` is a list of `{text, source}` receipts. Text may contain an
existing configured Playwright screenshot, trace or video URL/path and its observed behavior.
The generator does not record or upload media. Absent UI evidence is `NOT AVAILABLE`; backend,
infra and trivial changes do not require media and omit that section entirely.

Missing risks, unchanged areas, findings, fields and evidence are explicit `NOT AVAILABLE` /
`NOT RUN` entries. Producers should keep individual entries concise and avoid raw unbounded logs
or secrets. The CLI accepts at most 256 KiB of JSON. Preview the result before publication.
