defmodule SymphonyElixir.HarnessIsolationTest do
  @moduledoc """
  Guards the shared test-harness isolation contract (MIC-212).

  A test that takes shared supervisor/config state down must not contaminate
  unrelated later tests: the harness restores the configured application env
  and the application supervisor shape after every test, on both pass and fail.
  """

  defmodule DamageTest do
    use SymphonyElixir.TestSupport

    test "a test may take the shared workflow store down without restoring it itself" do
      assert is_pid(Process.whereis(WorkflowStore))
      assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
      refute Process.whereis(WorkflowStore)

      Application.put_env(:symphony_elixir, :workflow_file_path, "/nonexistent/mic212-workflow.md")

      # No on_exit here on purpose: the shared harness owns restoring this.
      :ok
    end
  end

  defmodule LaterTest do
    use ExUnit.Case, async: false

    test "unrelated later test sees the configured baseline restored" do
      workflow_path = Application.get_env(:symphony_elixir, :workflow_file_path)

      assert is_binary(workflow_path)
      assert File.exists?(workflow_path)
      assert Path.basename(workflow_path) == "startup_workflow.md"

      assert is_pid(Process.whereis(SymphonyElixir.WorkflowStore))
      assert is_pid(Process.whereis(SymphonyElixir.AgentRuntimeSupervisor))
      assert is_pid(Process.whereis(SymphonyElixir.PubSub))
      assert is_pid(Process.whereis(SymphonyElixir.StatusDashboard))

      assert {:ok, _settings} = SymphonyElixir.Config.settings()
      assert :ok = SymphonyElixir.Config.validate!()
    end
  end
end
