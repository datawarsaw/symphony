defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @doc """
  Start the agent runtime in the current BEAM node.
  """
  @spec start_link() :: Supervisor.on_start()
  def start_link do
    SymphonyElixir.AgentRuntimeSupervisor.start_link([])
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  require Logger

  @dialyzer {:nowarn_function, start_burrito_cli: 0}

  @impl true
  def start(_type, _args) do
    if burrito_runtime?() do
      start_burrito_cli()
    else
      start_runtime()
    end
  end

  @doc false
  @spec start_runtime() :: Supervisor.on_start() | {:error, term()}
  def start_runtime do
    :ok = SymphonyElixir.LogFile.configure()

    # Runtime authority before any lifecycle-capable child exists: the holder
    # process (linked to this boot) claims the durable single-instance lease for
    # the configured state root, and a held or unusable root fails the whole
    # application start — fail-start before the Orchestrator can run at all.
    #
    # Mutation-root pinning: the root the holder claimed is read back and
    # injected into the supervisor tree, so every lifecycle mutation path
    # (workspaces, retries, steering, cleanup) mutates exactly the root the
    # lease protects for the lifetime of this runtime. A later WORKFLOW.md
    # `workspace.root` change cannot move the mutation root; it takes effect at
    # the next runtime start.
    #
    # The acquisition can be disabled for boots that are deliberately NOT
    # production runtime boots (`:runtime_authority_app_boot`, default true).
    # The test VM sets this false: its application boot is a direct entry path
    # of the documented unpinned kind — tests build runtime trees themselves on
    # fixture roots — and the suite's shared fixture machinery owns the
    # run-scoped state root, which must never be load-bearing for a lease.
    # Lease coverage lives in the runtime-authority suites plus the env-gated
    # multi-BEAM startup e2e, whose child BEAMs boot through this same
    # function with the flag unset (acquiring, as in production).
    if Application.get_env(:symphony_elixir, :runtime_authority_app_boot, true) do
      with {:ok, _holder} <- SymphonyElixir.RuntimeLease.acquire_and_hold(),
           {:ok, authority_root} <- SymphonyElixir.RuntimeLease.authority_root() do
        Logger.info("Runtime mutation root pinned to authority root=#{authority_root}")

        Supervisor.start_link(
          children(authority_root),
          strategy: :one_for_one,
          name: SymphonyElixir.Supervisor
        )
      end
    else
      Supervisor.start_link(
        children(nil),
        strategy: :one_for_one,
        name: SymphonyElixir.Supervisor
      )
    end
  end

  defp children(authority_root) do
    [
      {Phoenix.PubSub, name: SymphonyElixir.PubSub},
      SymphonyElixir.WorkflowStore,
      {SymphonyElixir.AgentRuntimeSupervisor, authority_root: authority_root},
      SymphonyElixir.HttpServer,
      SymphonyElixir.StatusDashboard
    ]
  end

  @impl true
  def stop(_state) do
    SymphonyElixir.RuntimeLease.release_held()
    SymphonyElixir.StatusDashboard.render_offline_status()
    :ok
  end

  defp start_burrito_cli do
    Task.start_link(fn ->
      SymphonyElixir.CLI.main(
        plain_arguments(),
        &start_runtime/0
      )
    end)
  end

  defp burrito_runtime?, do: System.get_env("__BURRITO") == "1"

  defp plain_arguments, do: Enum.map(:init.get_plain_arguments(), &to_string/1)
end
