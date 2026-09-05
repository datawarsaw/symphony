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
  repository: https://github.com/openai/symphony
  base_ref: refs/heads/main
hooks:
  after_create: |
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
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

You are implementing Linear ticket `{{ issue.identifier }}` in an isolated, host-prepared workspace.

{% if attempt %}
This is attempt #{{ attempt }}. Resume the existing source changes and workpad; do not restart completed work.
{% endif %}

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

## Implementation boundary

The orchestration host prepares and synchronizes the approved repository before launching you.
Read `.git/.symphony-provenance.json` for repository, origin, and base commit evidence. Work only in
this provided copy. Source files are writable; `.git` may be read-only.

- Implement and test source changes. Preserve unrelated changes and all review evidence.
- Do not run Git configuration writes, fetch, pull, checkout, branch creation, add, commit,
  push, PR creation, merge, or deployment. Delivery occurs separately after independent review
  and the human gate. Repository skills that require those operations do not apply to this turn.
- Read-only Git status, diff, and log are allowed. If ownership checks require it, use a
  command-scoped `git -c safe.directory=<absolute-workspace> ...` for those reads; do not persist
  configuration or use a wildcard exception.
- Do not weaken sandbox policy, request unrestricted shell, or access arbitrary paths.
- Do not remove or overwrite provenance. Record any mismatch or missing preparation as a blocker.

## Tracker and workpad

Use Linear MCP or the injected `linear_graphql` tool. Start by fetching the current ticket state
and reading its single active `## Codex Workpad` comment. Update that comment in place throughout
execution; create it if missing. Do not edit the issue description for progress tracking.

- `Todo`: transition to `In Progress`, then create/update the workpad before implementation.
- `In Progress` or `Rework`: reconcile the workpad and continue from the preserved source diff.
- `Backlog`, `In Review`, `Human Review`, `Merging`, or terminal states: stop without source edits
  or delivery actions. These states belong to scheduling, review, or delivery.

Maintain this workpad structure:

````md
## Codex Workpad

```text
<hostname>:<absolute-workspace>@<short-base-commit>
```

### Plan

- [ ] Reproduce and plan the change.
- [ ] Implement with focused tests.
- [ ] Validate, review the diff, and hand off source evidence.

### Acceptance Criteria

- [ ] Mirror every ticket acceptance requirement here.

### Validation

- [ ] Record required commands and their actual results.

### Notes

- Record preparation provenance, reproduction, decisions, and durable source paths.
````

## Execution and handoff

1. Record repository/origin/base provenance and read-only Git status in the workpad.
2. Reproduce the issue before edits; refine the plan and validation design. Treat ticket-authored
   Validation, Test Plan, or Testing requirements as mandatory.
3. Implement the scoped change. Run repository-required and targeted checks. For app behavior,
   validate the relevant launch and interaction flow and retain evidence in the workspace.
4. Review the final source diff, preserve unrelated edits, and obtain independent review when
   repository policy requires it. Keep the workpad checklist accurate after each milestone.
5. Record changed paths, test results, review findings, and any limitations in the same workpad.
   Leave source changes in place for the separate delivery phase; no commit or PR is required.
6. When acceptance and validation pass, transition to `In Review` (or the team's equivalent
   non-active review state). Do not mark Done, merge, or deploy.

This is unattended. Do not ask a human to perform follow-up actions. Stop early only for a true
external blocker after exhausting documented safe fallbacks. Record the missing tool, access, or
permission and its validation impact in the workpad, then use the team's blocked state (or
non-active review state if unavailable). Never describe unrun checks as passing.

Final response reports completed actions and blockers only, with no next steps for the user.
