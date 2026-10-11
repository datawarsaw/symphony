defmodule SymphonyElixir.PilotGuard do
  @moduledoc """
  Armed-state holder for the OpenCode-only pilot dispatch guard.

  `PilotBootstrap.start/2` proves, offline and before the runtime starts, that
  a checkout is an armed OpenCode-only pilot. `arm/1` records that verdict in
  the application environment and `armed?/0` is the only read side. The flag
  lives outside `WORKFLOW.md`, so no workflow reload — disabling OpenCode,
  emptying the allowlist, corrupting the section — can disarm it, and nothing
  outside the bootstrap gate can set it: dispatch-time code reads the flag and
  never writes it.

  While the pilot is armed, the orchestrator refuses every Codex dispatch.
  The only launch an armed pilot performs is an OpenCode dispatch
  `HarnessSelection` authorized for that issue; unauthorized, disabled,
  invalid, or unreadable configurations park instead of rescuing into Codex.

  The guard is a decision input, not an actor: it starts no process, mutates
  no worker or orchestrator state, and owns no retry, pinning, or containment
  policy. Those gates keep their existing semantics for every non-pilot run,
  where `armed?/0` is false and the guard is inert.
  """

  @app :symphony_elixir
  @key :pilot_guard

  @doc """
  Records the armed pilot verdict for this node.

  Only `PilotBootstrap.start/2` calls this, after the `:armed` gate passes and
  before the runtime starts, so no poll or dispatch can outrun the guard.
  `info` carries operator-facing correlation fields (for example
  `workflow_path` and `source_sha`) into the stored record; nothing reads them
  for the dispatch decision itself.
  """
  @spec arm(keyword() | map()) :: :ok
  def arm(info \\ []) do
    info
    |> Map.new()
    |> Map.put(:armed, true)
    |> then(&Application.put_env(@app, @key, &1))

    :ok
  end

  @doc """
  True only while the bootstrap-armed OpenCode pilot is running on this node.

  Fail-closed for the dispatch direction: a missing or malformed record reads
  as unarmed, which is ordinary non-pilot routing, never a silent arming.
  """
  @spec armed?() :: boolean()
  def armed? do
    match?(%{armed: true}, Application.get_env(@app, @key))
  end
end
