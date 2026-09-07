# Dedicated Discovery worker lane

Discovery is an opt-in, local Symphony lane. It reuses the existing Codex app-server and the host's configured OpenCodex provider gateway. It does not add a provider framework or change implementation, independent review, Human Acceptance, delivery or merge policy.

## Configuration

```yaml
discovery:
  enabled: true
  skill_path: C:/AI/code-skills/discovery-gate/SKILL.md
```

The skill and its sibling `references/discovery-contract.md` must be readable on the Symphony host. They are loaded into a single immutable input with the issue id/title/description, labels, parent/project context, allowlisted repository routing and explicit lifecycle/security constraints. Repository routing must resolve a canonical source path. Discovery adds `Discovery` to the configured active states when enabled. The default is disabled.

The fixed routes are `xai/grok-4.6` with medium reasoning, followed only on technical failure by `google-antigravity/gemini-3.8-flash` with medium reasoning. The existing gateway owns provider authentication. The returned app-server model must match the requested route. Successful verdicts and malformed successful output never cause fallback. A structured rate-limit failure gets one retry after one second, then technical fallback; other recognized availability/authentication/quota/transport failures go directly to fallback. The fallback gets the exact original input bytes in a fresh session. Outputs from attempts are never combined.

## Read-only boundary

Discovery branches before implementation workspace preparation and hooks. The host creates an empty scratch directory under the configured workspace root; the worker inspects the routed repository from this scratch directory. It never runs in the source checkout. No implementation before/after hooks run in this lane. SSH Discovery sessions are currently rejected explicitly; existing implementation SSH behavior is unchanged.

The session requests and verifies a read-only sandbox with network access disabled and approval policy `never`. Symphony disables automatic approval handling for Discovery, clears dynamic tools, rejects every client-side tool call, disables configured MCP servers, apps, plugins, subagents, memories and web search, and does not inherit the shell environment. The project instruction file budget is zero: the immutable skill/contract and issue input define the Discovery task. The existing tracker credential stripping remains active at process launch.

## Output and lifecycle

The validator consumes one Discovery Brief. READY additionally requires a full Todo Handoff, matching issue identity, the configured destination repository, consistent declared scope (LARGE + BROAD is rejected) and `SPLIT REQUIRED: NO`. SPLIT requires a proposal with at least two complete child entries and never exposes a handoff. All other successful verdicts retain their output and cannot start implementation. Invalid output is retained as INVALID rather than being repaired by a second model.

The host atomically writes result evidence below:

`workspace.root/.discovery-results/<issue-id-sha256>/<input-sha256>.json`

Evidence includes the output, input hash, primary/fallback lane, requested provider/model/reasoning and fallback reason. No credential or raw provider-error payload is stored. A completed Discovery run parks the existing issue claim without a continuation retry. Its tracker state remains Discovery, including after READY. An external lifecycle action is required to move the issue to Todo; the Discovery worker never performs that action.

On a later implementation run, a matching READY receipt supplies only its Todo Handoff as the issue description to the existing implementation workflow. The full Discovery transcript is not injected. Previously gated issues with changed input or non-READY evidence fail closed. Todo issues without prior Discovery evidence retain their existing behavior. The evidence cache prevents repeated model runs after process restart. Changes to the issue's relevant input produce a new input identity; the existing block is released when the issue leaves Discovery or its task context changes.

For an intentional rerun of unchanged input after an infrastructure repair, an operator must archive the exact evidence file outside the result store and restart the scheduler. Do not edit a receipt to manufacture READY. Live workflow enablement and delivery of this candidate are separate operations.

## Verification

`mix test test/symphony_elixir/discovery_test.exs test/symphony_elixir/discovery_integration_test.exs` covers routing, bounded retry, immutable fallback input, all verdicts, malformed handoffs, inherited integration restrictions, restart/cache behavior, stale/destination binding, default behavior and real orchestrator completion without continuation.

Run the repository's format, lint, full coverage and type gates before delivery. Session setup can also be probed against the installed app-server without a model turn; this proves accepted model/sandbox settings, not successful provider execution or end-to-end issue processing.
