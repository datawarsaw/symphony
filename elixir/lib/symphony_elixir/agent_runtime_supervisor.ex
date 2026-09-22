defmodule SymphonyElixir.AgentRuntimeSupervisor do
  @moduledoc """
  Supervises the scheduler authority together with its agent tasks.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    task_supervisor_name =
      Keyword.get(opts, :task_supervisor_name, SymphonyElixir.TaskSupervisor)

    orchestrator_name = Keyword.get(opts, :orchestrator_name, SymphonyElixir.Orchestrator)

    # Boot-pinned mutation roots injected by Application.start_runtime: the
    # authority root the runtime lease protects (local workspace/state paths)
    # and the raw configured workspace root as read at boot (remote worker hosts
    # resolve it on their own filesystem). When absent — test trees, direct API
    # use — the Orchestrator resolves configuration live, exactly as before.
    orchestrator_opts = Keyword.take(opts, [:authority_root, :configured_workspace_root])

    orchestrator_child =
      Supervisor.child_spec(
        {SymphonyElixir.Orchestrator, [name: orchestrator_name, task_supervisor: task_supervisor_name] ++ orchestrator_opts},
        id: orchestrator_name
      )

    children = [
      Supervisor.child_spec(
        {Task.Supervisor, name: task_supervisor_name},
        id: task_supervisor_name
      ),
      orchestrator_child
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
