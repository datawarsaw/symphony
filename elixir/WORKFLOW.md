---
tracker:
  kind: linear
  provider:
    project_slug: "symphony-0c79b11b75ea"
  required_labels: []
  active_states:
    - Todo
    - In Progress
    - Rework
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces
routing:
  # Every dispatched issue must have one `repo:<target>` label. Targets are an explicit
  # allowlist: no repository is inferred from issue text or discovered dynamically.
  target_label_prefix: "repo:"
  default_branch: "main"
  targets:
    wup:
      source_path: "C:/AI/wup"
      remote: "https://github.com/datawarsaw/wup.git"
    agent-platform-code-skills:
      source_path: "C:/AI/code-skills"
    agent-platform-workstation-ops:
      source_path: "C:/AI/workstation-ops-mcp"
    symphony-runtime:
      source_path: "C:/Users/micha/symphony"
hooks:
  after_create: |
    set -eu
    : "${SYMPHONY_REPOSITORY_TARGET:?missing repository target}"
    : "${SYMPHONY_REPOSITORY_SOURCE_PATH:?missing repository source path}"
    : "${SYMPHONY_REPOSITORY_DEFAULT_BRANCH:?missing repository default branch}"
    source_path="$SYMPHONY_REPOSITORY_SOURCE_PATH"
    default_branch="$SYMPHONY_REPOSITORY_DEFAULT_BRANCH"
    task_branch="symphony/$SYMPHONY_ISSUE_IDENTIFIER"
    test -d "$source_path/.git"
    git -C "$source_path" diff --quiet
    git -C "$source_path" diff --cached --quiet
    test -z "$(git -C "$source_path" ls-files --unmerged)"
    if [ -n "${SYMPHONY_REPOSITORY_REMOTE:-}" ]; then
      test "$(git -C "$source_path" remote get-url origin)" = "$SYMPHONY_REPOSITORY_REMOTE"
    fi
    git -C "$source_path" fetch --prune origin
    git -C "$source_path" show-ref --verify --quiet "refs/remotes/origin/$default_branch"
    if git -C "$source_path" show-ref --verify --quiet "refs/heads/$task_branch"; then
      exit 1
    fi
    if git -C "$source_path" show-ref --verify --quiet "refs/remotes/origin/$task_branch"; then
      exit 1
    fi
    git -C "$source_path" worktree add --no-checkout -b "$task_branch" "$PWD" "refs/remotes/origin/$default_branch"
    git -C "$PWD" checkout "$task_branch"
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: true
---

You are working on a Linear ticket `{{ issue.identifier }}`

{% if attempt %}
Follow-up context:

- This is follow-up attempt #{{ attempt }}. It may be a normal continuation or a retry after a failure.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
- Do not end the turn while the work item remains in an active state unless you are blocked by missing required access.
  {% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. This is an unattended orchestration session. Do not ask a human to perform follow-up actions.
2. Only stop early for a true external blocker (missing required tools, auth, permissions, or secrets). If blocked, record it in the workpad and move the issue according to the workflow.
3. Final message must report completed actions and blockers only. Do not include "next steps for user".

Work only in the provided repository copy. Do not touch any other path.

## Repository preparation and delivery boundary

Host-side `RepositoryRouter`, `SourceSync`, and configured workspace hooks select the explicitly
labelled repository target, verify and prepare its source baseline, and materialize the workspace
before Codex starts. They are the single repository-preparation flow. Do not recreate their
routing, source sync, worktree creation, or base-reference logic from the Codex session.

Before editing, inspect the supplied preparation evidence and record the selected target/source,
configured origin or remote when present, and prepared base commit in the `## Codex Workpad`.
You may use `git status`, `git diff`, `git log`, and `git rev-parse` as read-only evidence.

Treat `.git` as read-only. Do not run `git config`, `git fetch`, `git pull`, `git branch`, `git
checkout`, `git switch`, `git worktree`, `git add`, `git commit`, `git push`, or any other Git
metadata mutation. Do not create or update a PR, merge, deploy, or perform delivery. Leave source
edits intact in the workspace. Delivery is a separate host or human-approved phase.

## Prerequisite: Linear MCP or `linear_graphql` tool is available

The agent should be able to talk to Linear, either via a configured Linear MCP server or injected `linear_graphql` tool. If neither is present, treat that as blocked access: record it in the workpad and move the issue according to the workflow instead of asking a user to configure Linear.

## Default posture

- Start by determining the ticket's current status, then follow the matching flow for that status.
- Start every task by opening the tracking workpad comment and bringing it up to date before doing new implementation work.
- Spend extra effort up front on planning and verification design before implementation.
- Reproduce first: always confirm the current behavior/issue signal before changing code so the fix target is explicit.
- Keep ticket metadata current (state, checklist, acceptance criteria, links).
- Treat a single persistent Linear comment as the source of truth for progress.
- Use that single workpad comment for all progress and handoff notes; do not post separate "done"/summary comments.
- Treat any ticket-authored `Validation`, `Test Plan`, or `Testing` section as non-negotiable acceptance input: mirror it in the workpad and execute it before considering the work complete.
- When meaningful out-of-scope improvements are discovered during execution,
  file a separate Linear issue instead of expanding scope. The follow-up issue
  must include a clear title, description, and acceptance criteria, be placed in
  `Backlog`, be assigned to the same project as the current issue, link the
  current issue as `related`, and use `blockedBy` when the follow-up depends on
  the current issue.
- Move status only when the matching quality bar is met.
- Operate autonomously end-to-end unless blocked by missing requirements, secrets, or permissions.
- Use the blocked-access escape hatch only for true external blockers (missing required tools/auth) after exhausting documented fallbacks.

## Related skills

- `linear`: interact with Linear.

## Status map

- `Backlog` -> out of scope for this workflow; do not modify.
- `Todo` -> queued; immediately transition to `In Progress` before active work.
  - Do not inspect an attached PR; it belongs to the separate delivery phase.
- `In Progress` -> implementation actively underway.
- `In Review` -> implementation and validation are complete; the workspace diff is preserved for review.
- `Merging` -> host or human delivery phase; Codex must not perform delivery work.
- `Rework` -> reviewer requested changes; planning + implementation required.
- `Done` -> terminal state; no further action required.

## Step 0: Determine current ticket state and route

1. Fetch the issue by explicit ticket ID.
2. Read the current state.
3. Route to the matching flow:
   - `Backlog` -> do not modify issue content/state; stop and wait for human to move it to `Todo`.
   - `Todo` -> immediately move to `In Progress`, then ensure bootstrap workpad comment exists (create if missing), then start execution flow.
   - `In Progress` -> continue execution flow from current scratchpad comment.
   - `In Review` -> preserve the workspace and source diff; do not deliver or clean up.
   - `Merging` -> host or human delivery phase; do not perform delivery work.
   - `Rework` -> run rework flow.
   - `Done` -> do nothing and shut down.
4. For `Todo` tickets, do startup sequencing in this exact order:
   - `update_issue(..., state: "In Progress")`
   - find/create `## Codex Workpad` bootstrap comment
   - only then begin analysis/planning/implementation work.
5. Do not inspect, create, update, or close a PR. Host-side preparation already selected the source
   and base commit; do not create a branch or synchronize a remote.

## Step 1: Start/continue execution (Todo or In Progress)

1.  Find or create a single persistent scratchpad comment for the issue:
    - Search existing comments for a marker header: `## Codex Workpad`.
    - Ignore resolved comments while searching; only active/unresolved comments are eligible to be reused as the live workpad.
    - If found, reuse that comment; do not create a new workpad comment.
    - If not found, create one workpad comment and use it for all updates.
    - Persist the workpad comment ID and only write progress updates to that ID.
2.  If arriving from `Todo`, do not delay on additional status transitions: the issue should already be `In Progress` before this step begins.
3.  Immediately reconcile the workpad before new edits:
    - Check off items that are already done.
    - Expand/fix the plan so it is comprehensive for current scope.
    - Ensure `Acceptance Criteria` and `Validation` are current and still make sense for the task.
4.  Start work by writing/updating a hierarchical plan in the workpad comment.
5.  Ensure the workpad includes a compact environment stamp at the top as a code fence line:
    - Format: `<host>:<abs-workdir>@<short-sha>`
    - Example: `devbox-01:/home/dev-user/code/symphony-workspaces/MT-32@7bdde33bc`
    - Do not include metadata already inferable from Linear issue fields (`issue ID`, `status`, `branch`, `PR link`).
6.  Add explicit acceptance criteria and TODOs in checklist form in the same comment.
    - If changes are user-facing, include a UI walkthrough acceptance criterion that describes the end-to-end user path to validate.
    - If changes touch app files or app behavior, add explicit app-specific flow checks to `Acceptance Criteria` in the workpad (for example: launch path, changed interaction path, and expected result path).
    - If the ticket description/comment context includes `Validation`, `Test Plan`, or `Testing` sections, copy those requirements into the workpad `Acceptance Criteria` and `Validation` sections as required checkboxes (no optional downgrade).
7.  Run a principal-style self-review of the plan and refine it in the comment.
8.  Before implementing, capture a concrete reproduction signal and record it in the workpad `Notes` section (command/output, screenshot, or deterministic UI behavior).
9.  Record the repository preparation evidence before editing: selected target/source, configured
    remote when present, and prepared base commit. Compact context and proceed to execution.


## Blocked-access escape hatch (required behavior)

Use this only when completion is blocked by missing required tools or missing auth/permissions that cannot be resolved in-session.

- Do not attempt GitHub authentication or delivery fallback strategies; those actions are outside the
  Codex implementation role.
- If a required implementation tool or non-GitHub auth is unavailable, record a short blocker
  brief in the workpad that includes:
  - what is missing,
  - why it blocks required acceptance/validation,
  - exact human action needed to unblock.
- Keep the brief concise and action-oriented; do not add extra top-level comments outside the workpad.

## Step 2: Execution phase (Todo -> In Progress -> In Review)

1.  Determine the prepared repository state with read-only `git status`, `git diff`, `git log`, or
    `git rev-parse` evidence; record the supplied provenance before implementation continues.
2.  If current issue state is `Todo`, move it to `In Progress`; otherwise leave the current state unchanged.
3.  Load the existing workpad comment and treat it as the active execution checklist.
    - Edit it liberally whenever reality changes (scope, risks, validation approach, discovered tasks).
4.  Implement against the hierarchical TODOs and keep the comment current:
    - Check off completed items.
    - Add newly discovered items in the appropriate section.
    - Keep parent/child structure intact as scope evolves.
    - Update the workpad immediately after each meaningful milestone (for example: reproduction complete, code change landed, validation run, review feedback addressed).
    - Never leave completed work unchecked in the plan.
5.  Run validation/tests required for the scope.
    - Mandatory gate: execute all ticket-provided `Validation`/`Test Plan`/ `Testing` requirements when present; treat unmet items as incomplete work.
    - Prefer a targeted proof that directly demonstrates the behavior you changed.
    - You may make temporary local proof edits to validate assumptions (for example: tweak a local build input for `make`, or hardcode a UI account / response path) when this increases confidence.
    - Revert every temporary proof edit that is not part of the intended source change.
    - Document these temporary proof steps and outcomes in the workpad `Validation`/`Notes` sections so reviewers can follow the evidence.
    - If app-touching, run local runtime validation when available; do not upload media.
6.  Re-check all acceptance criteria and close any gaps.
7.  Use read-only Git status/diff evidence to summarize source changes. Do not stage, commit, push,
    create a PR, merge, or sync a remote.
8. Update the workpad comment with final checklist status, provenance, and validation notes.
    - Mark completed plan/acceptance/validation checklist items as checked.
    - Add final handoff notes (prepared base commit, source diff, and validation summary) in the same workpad comment.
    - Add a short `### Confusions` section at the bottom when any part of task execution was unclear/confusing, with concise bullets.
    - Do not post any additional completion summary comment.
9. Confirm every required ticket-provided validation/test-plan item is complete, refresh the workpad,
   and move the ticket to `In Review`. Preserve the workspace and source diff.

## Step 3: In Review and delivery

1. `In Review` preserves the workspace and its uncommitted source diff for reviewers.
2. If feedback requires code changes, move the ticket to `Rework` and continue the implementation
   flow in the same prepared workspace.
3. Commit, push, PR creation, merge, deploy, and cleanup belong to a separate host or
   human-approved delivery phase. Do not execute or poll that phase from Codex.

## Step 4: Rework handling

1. Treat `Rework` as a full approach reset, not incremental patching.
2. Re-read the full issue body and all human comments; explicitly identify what will be done differently this attempt.
3. Preserve the existing `## Codex Workpad`, workspace, source diff, and preparation evidence.
4. Continue the normal implementation flow without creating a branch or changing repository
   metadata.

## Completion bar before In Review

- Step 1/2 checklist is fully complete and accurately reflected in the single workpad comment.
- Acceptance criteria and required ticket-provided validation items are complete.
- Validation/tests are green for the prepared source changes.
- The workpad records selected target/source, configured remote when present, prepared base commit,
  source diff evidence, and validation results.
- The workspace and source diff remain available for review.
- If app-touching, runtime validation/media requirements from `App runtime validation (required)` are complete.

## Guardrails

- Do not inspect, create, update, close, or reuse a branch or PR from Codex.
- If issue state is `Backlog`, do not modify it; wait for human to move to `Todo`.
- Do not edit the issue body/description for planning or progress tracking.
- Use exactly one persistent workpad comment (`## Codex Workpad`) per issue.
- If comment editing is unavailable in-session, use the update script. Only report blocked if both MCP editing and script-based editing are unavailable.
- Temporary proof edits are allowed only for local verification and must be reverted before handoff.
- If out-of-scope improvements are found, create a separate Backlog issue rather
  than expanding current scope, and include a clear
  title/description/acceptance criteria, same-project assignment, a `related`
  link to the current issue, and `blockedBy` when the follow-up depends on the
  current issue.
- Do not move to `In Review` unless the `Completion bar before In Review` is satisfied.
- In `In Review`, preserve the workspace and source diff; do not clean or remove either.
- If state is terminal (`Done`), do nothing and shut down.
- Keep issue text concise, specific, and reviewer-oriented.
- If blocked and no workpad exists yet, add one blocker comment describing blocker, impact, and next unblock action.

## Workpad template

The separate post-review owner may use `mix human_acceptance --input evidence.json --publish ISSUE_ID`
to upsert the dedicated `[HUMAN ACCEPTANCE]` evidence comment after independent review. The
implementation worker still maintains only its workpad and stops at `In Review`. The evidence
command neither dispatches a reviewer nor moves the issue. Without a structured independent PASS
matching the entire current acceptance target, the pack is a draft and must not be used to move
the issue to Human Acceptance. See `docs/human-acceptance.md` for the versioned snapshot contract.

Use this exact structure for the persistent workpad comment and keep it updated in place throughout execution:

````md
## Codex Workpad

```text
<hostname>:<abs-path>@<short-sha>
```

### Plan

- [ ] 1\. Parent task
  - [ ] 1.1 Child task
  - [ ] 1.2 Child task
- [ ] 2\. Parent task

### Acceptance Criteria

- [ ] Criterion 1
- [ ] Criterion 2

### Validation

- [ ] targeted tests: `<command>`

### Notes

- <short progress note with timestamp>

### Confusions

- <only include when something was confusing during execution>
````
