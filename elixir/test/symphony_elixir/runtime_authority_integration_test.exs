defmodule SymphonyElixir.RuntimeAuthorityIntegrationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RuntimeLease

  @moduledoc """
  Startup-gating integration tests for the runtime authority lease.

  These tests assemble the exact same supervisor shape as
  `SymphonyElixir.Application.start_runtime/0` — the authority holder started
  before the agent runtime tree, under one supervisor — against isolated state
  roots, and prove the Phase-12 sequence: a runtime becomes authoritative, a
  second runtime fails closed before its Orchestrator exists, and after release
  a clean subsequent startup acquires.

  The fully end-to-end variant (two real BEAM processes racing
  `Application.start_runtime`) lives in
  `SymphonyElixir.RuntimeAuthorityStartupE2ETest` and runs with
  `SYMPHONY_RUN_RUNTIME_LEASE_E2E=1`.
  """

  defp foreign_instance_id, do: String.duplicate("e", 32)

  # TestSupport's setup configures a unique per-test retry store root; the runtime
  # authority lease binds the same root the test tree's Orchestrator mutates.
  defp per_test_root, do: Application.fetch_env!(:symphony_elixir, :retry_store_root)

  defp write_foreign_lease(root) do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    lease = %{
      "schema_version" => 1,
      "kind" => "runtime-authority",
      "state_root" => root,
      "instance_id" => foreign_instance_id(),
      "owner_token" => String.duplicate("c", 32),
      "os_pid" => "123456",
      "node" => "other@host",
      "hostname" => "other-host",
      "started_at" => now,
      "heartbeat_at" => now
    }

    File.mkdir_p!(RuntimeLease.authority_dir(root))
    File.write!(RuntimeLease.authority_path(root), Jason.encode!(lease, pretty: true))
    lease
  end

  defp tree_names(suffix) do
    uniq = System.unique_integer([:positive])

    %{
      tree: Module.concat(__MODULE__, "Tree#{suffix}#{uniq}"),
      holder: Module.concat(__MODULE__, "Holder#{suffix}#{uniq}"),
      agent_supervisor: Module.concat(__MODULE__, "AgentSup#{suffix}#{uniq}"),
      task_supervisor: Module.concat(__MODULE__, "TaskSup#{suffix}#{uniq}"),
      orchestrator: Module.concat(__MODULE__, "Orchestrator#{suffix}#{uniq}")
    }
  end

  # The same assembly Application.start_runtime/0 uses: authority holder strictly
  # before the runtime tree, one supervisor, no lifecycle child without authority.
  defp start_runtime_tree(names, root) do
    children = [
      {RuntimeLease, name: names.holder, root: root, runtime_supervisor: nil, heartbeat_ms: 3_600_000},
      {SymphonyElixir.AgentRuntimeSupervisor, name: names.agent_supervisor, task_supervisor_name: names.task_supervisor, orchestrator_name: names.orchestrator}
    ]

    previous_flag = Process.flag(:trap_exit, true)

    try do
      result = Supervisor.start_link(children, strategy: :one_for_all, name: names.tree)

      # a failed start exits the tree abnormally; consume the linked exit signal so
      # the assertion observes the {:error, _} return instead of a dead test process
      receive do
        {:EXIT, _pid, _reason} -> :ok
      after
        0 -> :ok
      end

      result
    after
      Process.flag(:trap_exit, previous_flag)
    end
  end

  # Normal shutdown: the supervisor terminates children in reverse start order, so
  # the Orchestrator stops before the holder's terminate/1 releases the lease.
  defp stop_tree(names) do
    case Process.whereis(names.tree) do
      pid when is_pid(pid) ->
        try do
          Supervisor.stop(names.tree)
        catch
          # the tree is linked to the test process and may already be shutting down
          :exit, _reason -> :ok
        end

      _ ->
        :ok
    end
  end

  test "a runtime becomes authoritative and its orchestrator starts" do
    retry_store_root = per_test_root()
    names = tree_names("A")

    on_exit(fn -> stop_tree(names) end)

    assert {:ok, _tree} = start_runtime_tree(names, retry_store_root)
    assert RuntimeLease.authoritative?(names.holder)
    assert is_pid(Process.whereis(names.orchestrator))
    assert is_pid(Process.whereis(names.task_supervisor))

    assert {:ok, status} = RuntimeLease.status(names.holder)
    assert status.held?
    assert status.root == retry_store_root

    stop_tree(names)
  end

  test "a foreign runtime's lease blocks the tree before its orchestrator becomes active" do
    retry_store_root = per_test_root()
    write_foreign_lease(retry_store_root)
    names_b = tree_names("B")

    on_exit(fn -> stop_tree(names_b) end)

    # A different runtime instance (another BEAM) owns the root: the tree must not
    # start at all — no holder, no TaskSupervisor, no Orchestrator.
    assert {:error, {:shutdown, {:failed_to_start_child, RuntimeLease, held_error}}} =
             start_runtime_tree(names_b, retry_store_root)

    assert {:runtime_authority_unavailable, {:runtime_authority_held, evidence}} = held_error
    assert evidence["instance_id"] == foreign_instance_id()

    refute Process.whereis(names_b.holder)
    refute Process.whereis(names_b.orchestrator)
    refute Process.whereis(names_b.task_supervisor)
    refute Process.whereis(names_b.tree)

    stop_tree(names_b)
  end

  test "after release, a clean subsequent startup can acquire" do
    retry_store_root = per_test_root()
    names_a = tree_names("C1")
    names_b = tree_names("C2")

    on_exit(fn ->
      stop_tree(names_a)
      stop_tree(names_b)
    end)

    assert {:ok, _tree_a} = start_runtime_tree(names_a, retry_store_root)
    assert is_pid(Process.whereis(names_a.orchestrator))

    # Runtime A releases (normal shutdown path) and its tree goes away.
    assert :ok = stop_tree(names_a)
    assert {:error, :not_found} = RuntimeLease.observe(retry_store_root)

    # Clean subsequent startup acquires.
    assert {:ok, _tree_b} = start_runtime_tree(names_b, retry_store_root)
    assert RuntimeLease.authoritative?(names_b.holder)
    assert is_pid(Process.whereis(names_b.orchestrator))

    stop_tree(names_b)
  end

  test "a crash residue from another runtime keeps fresh startups fail closed until recovery" do
    retry_store_root = per_test_root()
    write_foreign_lease(retry_store_root)
    names = tree_names("D")

    on_exit(fn -> stop_tree(names) end)

    assert {:error, {:shutdown, {:failed_to_start_child, RuntimeLease, held_error}}} =
             start_runtime_tree(names, retry_store_root)

    assert {:runtime_authority_unavailable, {:runtime_authority_held, evidence}} = held_error
    assert evidence["class"] == "active"
    refute Process.whereis(names.orchestrator)

    # explicit operator recovery unblocks the root
    assert {:ok, _record} =
             RuntimeLease.force_release(retry_store_root,
               confirm: true,
               reason: "operator: prior runtime crashed on lost host",
               forced_by: "operator-console",
               force_active: true
             )

    assert {:ok, _tree} = start_runtime_tree(names, retry_store_root)
    assert is_pid(Process.whereis(names.orchestrator))

    stop_tree(names)
  end

  test "holder fails cleanly when the state root cannot be resolved" do
    # The holder resolves configuration the way an application boot does — before
    # any WorkflowStore exists — so remove the suite's store to exercise the same
    # direct-load fallback; TestSupport restores the baseline child afterwards.
    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)

    root_env = Application.get_env(:symphony_elixir, :retry_store_root)
    workflow_env = Application.get_env(:symphony_elixir, :workflow_file_path)
    Application.delete_env(:symphony_elixir, :retry_store_root)

    Application.put_env(
      :symphony_elixir,
      :workflow_file_path,
      System.tmp_dir!()
      |> Path.join("missing-#{:erlang.unique_integer([:positive])}")
      |> Path.join("WORKFLOW.md")
    )

    # No :root override: the holder must resolve the state root from configuration,
    # exactly as it does during an application boot.
    opts = [name: Module.concat(__MODULE__, "HolderBadCfg#{System.unique_integer([:positive])}")]

    on_exit(fn ->
      Application.put_env(:symphony_elixir, :retry_store_root, root_env)
      Application.put_env(:symphony_elixir, :workflow_file_path, workflow_env)
    end)

    assert {:error, {:runtime_authority_unavailable, {:invalid_state_root, message}}} =
             RuntimeLease.acquire_and_hold(opts)

    assert message =~ "Missing WORKFLOW.md"
    refute Process.whereis(opts[:name])
  end

  test "state_root/0 raises when configuration is broken" do
    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)

    root_env = Application.get_env(:symphony_elixir, :retry_store_root)
    workflow_env = Application.get_env(:symphony_elixir, :workflow_file_path)
    Application.delete_env(:symphony_elixir, :retry_store_root)

    Application.put_env(
      :symphony_elixir,
      :workflow_file_path,
      System.tmp_dir!()
      |> Path.join("missing-#{:erlang.unique_integer([:positive])}")
      |> Path.join("WORKFLOW.md")
    )

    on_exit(fn ->
      Application.put_env(:symphony_elixir, :retry_store_root, root_env)
      Application.put_env(:symphony_elixir, :workflow_file_path, workflow_env)
    end)

    assert_raise ArgumentError, ~r/Missing WORKFLOW.md/, fn -> RuntimeLease.state_root() end
  end
end
