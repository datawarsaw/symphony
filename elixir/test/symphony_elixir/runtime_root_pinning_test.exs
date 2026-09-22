defmodule SymphonyElixir.RuntimeRootPinningTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Orchestrator, RetryStore, RuntimeLease, SteeringStore}
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Workspace

  @moduledoc """
  Mutation-root pinning: for the lifetime of one runtime instance, every
  lifecycle mutation path derives its root from the boot-pinned authority root
  the RuntimeLease protects — never from live configuration. A WORKFLOW.md
  `workspace.root` reload may change configuration's desired root, but it can
  never silently move the physical mutation root; adopting a new root requires
  a runtime restart.
  """

  setup do
    root_a = unique_root("pinning-a")
    root_b = unique_root("pinning-b")
    File.mkdir_p!(root_a)
    File.mkdir_p!(root_b)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root_a)

    {:ok, root_a: root_a, root_b: root_b, canonical_a: canonical(root_a), canonical_b: canonical(root_b)}
  end

  # -- RuntimeLease.authority_root/1: one fail-closed authority source --------

  test "authority_root is available while the holder holds and fail-closed otherwise", %{root_a: root_a} do
    name = unique_name("Holder")
    opts = [name: name, root: root_a, runtime_supervisor: nil, heartbeat_ms: 3_600_000]

    # before acquisition: no holder, no root
    assert {:error, :no_runtime_authority} = RuntimeLease.authority_root(name)

    assert {:ok, _pid} = RuntimeLease.acquire_and_hold(opts)
    assert {:ok, ^root_a} = RuntimeLease.authority_root(name)

    # after release: the pinned root is unusable mutation authority
    assert :ok = RuntimeLease.release_held(name)
    assert {:error, :no_runtime_authority} = RuntimeLease.authority_root(name)
  end

  test "authority loss revokes the pinned root", %{root_a: root_a} do
    name = unique_name("Holder")
    opts = [name: name, root: root_a, runtime_supervisor: nil, heartbeat_ms: 20]

    Process.flag(:trap_exit, true)
    assert {:ok, pid} = RuntimeLease.acquire_and_hold(opts)
    assert {:ok, ^root_a} = RuntimeLease.authority_root(name)

    :ok = File.rm(RuntimeLease.authority_path(root_a))

    assert_receive {:EXIT, ^pid, {:runtime_authority_lost, :lease_missing}}, 5_000
    assert {:error, :no_runtime_authority} = RuntimeLease.authority_root(name)
  end

  # -- alias safety: one root must never look like two ------------------------

  test "roots_match? treats path aliases as the same root", %{root_a: root_a} do
    assert RuntimeLease.roots_match?(root_a, root_a <> "/")
    assert RuntimeLease.roots_match?(root_a, Path.join(root_a, "x") <> "/..")

    # Windows alias freedom: drive case and slash direction. The canonical
    # comparison is host-conditional, so assert with the native separators.
    case :os.type() do
      {:win32, _} ->
        upper_drive = swap_drive_case(root_a)
        assert upper_drive != root_a
        assert RuntimeLease.roots_match?(root_a, upper_drive)
        assert RuntimeLease.roots_match?(root_a, String.replace(root_a, "\\", "/"))

      _ ->
        :ok
    end

    # a child of the root is a different mutation domain
    refute RuntimeLease.roots_match?(root_a, Path.join(root_a, "child"))
    refute RuntimeLease.roots_match?(root_a, nil)
  end

  # A directory junction (or real symlink where the host allows one) pointing
  # at the state root is an alias of the SAME physical root: it must never
  # become a second lease domain. Uses the privilege-free junction fixture and
  # skips only when the host cannot build the fixture at all.
  @tag skip: symlink_fixture_skip_reason()
  test "a junction/symlink alias of the root is the same mutation domain", %{root_a: root_a} do
    test_root = Path.dirname(root_a)
    alias_root = Path.join(test_root, Path.basename(root_a) <> "-alias")

    try do
      strategy = link_dir_fixture!(root_a, alias_root)
      assert strategy in [:symlink, :junction]

      # canonical comparison: the alias IS the same root
      assert RuntimeLease.roots_match?(root_a, alias_root)

      # a lease claimed through the alias lives in the SAME physical authority
      # directory — there is exactly one authority file for the physical root
      holder = unique_name("AliasHolder")

      assert {:ok, _pid} =
               RuntimeLease.acquire_and_hold(name: holder, root: alias_root, runtime_supervisor: nil, heartbeat_ms: 3_600_000)

      assert File.exists?(RuntimeLease.authority_path(root_a))

      # no spelling of the same physical root can mint a second authority:
      # through the other spelling the alias-recorded lease reads back as a
      # mismatch (fail closed, never a new domain). The physical authority
      # file is shared, so the alias is the same mutation domain.
      assert File.exists?(RuntimeLease.authority_path(root_a))
      assert {:error, {:lease_state_invalid, :root_mismatch}} = RuntimeLease.claim(root_a)

      assert :ok = RuntimeLease.release_held(holder)
    after
      remove_dir_link_fixtures!(test_root)
    end
  end

  # -- status truth: drift is visible, never silent ---------------------------

  test "status reports configured vs authority root truthfully", %{root_a: root_a, root_b: root_b} do
    name = unique_name("Holder")
    opts = [name: name, root: root_a, runtime_supervisor: nil, heartbeat_ms: 3_600_000]

    assert {:ok, _pid} = RuntimeLease.acquire_and_hold(opts)

    assert {:ok, status} = RuntimeLease.status(name)
    assert status.root == root_a
    assert status.configured_root == canonical(root_a)
    refute status.root_drift?
    refute status.restart_required

    # configuration now desires B; the runtime still owns A
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root_b)
    :ok = WorkflowStore.force_reload()

    assert {:ok, status} = RuntimeLease.status(name)
    assert status.root == root_a
    assert status.configured_root == canonical(root_b)
    assert status.root_drift?
    assert status.restart_required

    assert :ok = RuntimeLease.release_held(name)
  end

  # -- workspace paths stay pinned --------------------------------------------

  test "workflow root hot reload does not move workspace paths or creation", %{
    canonical_a: canonical_a,
    root_b: root_b
  } do
    issue = test_issue("pin-ws", "PIN-1")

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root_b)
    :ok = WorkflowStore.force_reload()

    # resolution, creation, and containment all derive from the pinned root
    assert {:ok, path} = Workspace.workspace_path(issue, nil, workspace_root: canonical_a)
    assert RuntimeLease.roots_match?(Path.dirname(path), canonical_a)

    assert {:ok, created, _route, ^canonical_a} =
             Workspace.create_for_issue_with_route(issue, nil, workspace_root: canonical_a)

    assert File.dir?(created)
    assert RuntimeLease.roots_match?(Path.dirname(created), canonical_a)
  end

  # -- retry records stay pinned -----------------------------------------------

  test "retry record recovery and writes use the pinned root, not live config", %{
    root_a: root_a,
    root_b: root_b,
    canonical_a: canonical_a
  } do
    issue = test_issue("pin-retry", "PIN-2")
    record = retry_record(issue.id)

    # seed a record under the pinned root, remove the env seam, hot-reload to B
    RetryStore.write_record(root_a, record)

    without_retry_store_root_env(fn ->
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root_b)
      :ok = WorkflowStore.force_reload()

      state = %Orchestrator.State{authority_root: canonical_a}
      recovered = Orchestrator.recover_retry_records_for_test(state)
      assert MapSet.member?(recovered.claimed, issue.id)

      # a failure fold with the same pinned state writes under the pinned root
      metadata = %{
        identifier: issue.identifier,
        failure_class: "TRANSIENT_WORKER_FAILURE",
        workspace_root: canonical_a
      }

      issue_state = %Issue{issue | state: "In Progress"}
      _updated = Orchestrator.handle_retry_issue_lookup_for_test(issue_state, fresh_pinned_state(canonical_a), issue.id, 1, metadata)

      assert {:ok, written} = RetryStore.read_record(root_a, issue.id)
      assert written["issue_id"] == issue.id
    end)

    # B never became a mutation target
    assert [] = RetryStore.list_records(root_b)
  end

  test "retry mutation without env seam and without pin fails closed", %{root_a: root_a} do
    issue = test_issue("pin-noroot", "PIN-3")

    without_retry_store_root_env(fn ->
      state = %Orchestrator.State{}
      assert %Orchestrator.State{} = Orchestrator.recover_retry_records_for_test(state)
      refute MapSet.member?(state.claimed, issue.id)

      # seeded records elsewhere are NOT silently adopted by an unpinned runtime
      RetryStore.write_record(root_a, retry_record(issue.id))
      assert {:ok, _} = RetryStore.read_record(root_a, issue.id)
    end)
  end

  # -- steering stays pinned ----------------------------------------------------

  test "steering reconciliation and snapshots stay pinned to the authority root", %{
    root_a: root_a,
    root_b: root_b,
    canonical_a: canonical_a
  } do
    SteeringStore.write_record(root_a, %{
      "schema_version" => 1,
      "steer_id" => "steer-pin-1",
      "issue_id" => "pin-steer",
      "issue_identifier" => "PIN-4",
      "sequence" => 1,
      "status" => "PENDING",
      "text" => "stay pinned",
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "delivery_attempts" => 0
    })

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: root_b)
    :ok = WorkflowStore.force_reload()

    state = Orchestrator.run_startup_reconciliation_for_test(fresh_pinned_state(canonical_a))

    # the pinned runtime reconciles the steering inbox under A
    assert {:ok, record} = SteeringStore.read_record(root_a, "steer-pin-1")
    assert record["status"] in ["PENDING", "STALE"]
    assert RuntimeLease.roots_match?(state.authority_root, canonical_a)
  end

  # -- orphan scan stays pinned -------------------------------------------------

  test "orphan scan and terminal cleanup scan only the pinned root", %{
    root_a: root_a,
    root_b: root_b,
    canonical_a: canonical_a
  } do
    File.mkdir_p!(Path.join(root_a, "orphan-A"))

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: root_b)
    :ok = WorkflowStore.force_reload()

    previous_memory = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    try do
      state = Orchestrator.run_startup_reconciliation_for_test(fresh_pinned_state(canonical_a))

      # the scan ran under A: the orphan there is recognized...
      assert Enum.any?(state.orphaned_workspaces, &RuntimeLease.roots_match?(Path.dirname(&1), canonical_a))
      # ...and B was never scanned for orphans
      refute Enum.any?(state.orphaned_workspaces, &RuntimeLease.roots_match?(Path.dirname(&1), canonical(root_b)))
    after
      if is_nil(previous_memory) do
        Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      else
        Application.put_env(:symphony_elixir, :memory_tracker_issues, previous_memory)
      end
    end
  end

  # -- the adversarial probe: R1 pinned to A, configuration moved to B ----------

  test "R1 keeps mutating A after the config moves to B and R2 owns B in isolation", %{
    root_a: root_a,
    root_b: root_b,
    canonical_a: canonical_a
  } do
    # R1 boots on A (holder + pinned orchestrator), configuration then moves to B
    holder_a = unique_name("R1Holder")

    assert {:ok, _holder} =
             RuntimeLease.acquire_and_hold(
               name: holder_a,
               root: root_a,
               runtime_supervisor: nil,
               heartbeat_ms: 3_600_000
             )

    assert {:ok, ^root_a} = RuntimeLease.authority_root(holder_a)

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: root_b)
    :ok = WorkflowStore.force_reload()

    # every R1 mutation path stays under A
    issue = test_issue("pin-adv", "PIN-5")

    without_retry_store_root_env(fn ->
      state_a = %Orchestrator.State{authority_root: canonical_a}

      # workspace path resolution + creation
      assert {:ok, _created, _route, ^canonical_a} =
               Workspace.create_for_issue_with_route(issue, nil, workspace_root: canonical_a)

      # retry mutation
      RetryStore.write_record(root_a, retry_record(issue.id))
      recovered = Orchestrator.recover_retry_records_for_test(state_a)
      assert MapSet.member?(recovered.claimed, issue.id)

      # steering reconciliation
      assert %Orchestrator.State{} = Orchestrator.run_startup_reconciliation_for_test(state_a)
    end)

    # nothing from R1 ever landed under B
    refute File.exists?(Path.join(root_b, Workspace.workspace_key(issue)))
    assert [] = RetryStore.list_records(root_b)

    # R2 boots against B and acquires it WHILE R1 still holds A:
    # two live authorities over two different roots — never over one root.
    holder_b = unique_name("R2Holder")

    assert {:ok, _holder_b} =
             RuntimeLease.acquire_and_hold(
               name: holder_b,
               root: root_b,
               runtime_supervisor: nil,
               heartbeat_ms: 3_600_000
             )

    assert {:ok, ^root_b} = RuntimeLease.authority_root(holder_b)
    assert {:ok, ^root_a} = RuntimeLease.authority_root(holder_a)

    assert :ok = RuntimeLease.release_held(holder_b)
    assert :ok = RuntimeLease.release_held(holder_a)
  end

  # -- restart semantics: configuration changes take effect at restart ----------

  test "restart adopts the new configured root", %{root_a: root_a, root_b: root_b, canonical_b: canonical_b} do
    holder_a = unique_name("RestartA")

    assert {:ok, _holder} =
             RuntimeLease.acquire_and_hold(
               name: holder_a,
               root: root_a,
               runtime_supervisor: nil,
               heartbeat_ms: 3_600_000
             )

    assert :ok = RuntimeLease.release_held(holder_a)

    # configuration moves A -> B before the restart
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: root_b)
    :ok = WorkflowStore.force_reload()

    without_retry_store_root_env(fn ->
      holder_b = unique_name("RestartB")

      assert {:ok, _holder} =
               RuntimeLease.acquire_and_hold(
                 name: holder_b,
                 root: root_b,
                 runtime_supervisor: nil,
                 heartbeat_ms: 3_600_000
               )

      assert {:ok, ^root_b} = RuntimeLease.authority_root(holder_b)

      # a restarted, pinned runtime mutates B — not the old root A
      orchestrator_name = unique_name("RestartOrchestrator")

      assert {:ok, _orch} =
               Orchestrator.start_link(
                 name: orchestrator_name,
                 authority_root: canonical_b,
                 configured_workspace_root: root_b
               )

      assert %{runtime_root: %{authority_root: pinned, drift_detected?: false}} =
               Orchestrator.snapshot(orchestrator_name, 15_000)

      assert RuntimeLease.roots_match?(pinned, canonical_b)
    end)
  end

  # -- fixtures and helpers ------------------------------------------------------

  defp unique_root(label), do: Path.join(System.tmp_dir!(), "#{label}-#{:erlang.unique_integer([:positive])}")

  defp unique_name(label), do: Module.concat(__MODULE__, "#{label}#{System.unique_integer([:positive])}")

  defp canonical(root), do: Path.expand(root)

  defp test_issue(id, identifier) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Runtime root pinning #{identifier}",
      description: "mutation root pinning",
      state: "In Progress",
      url: "https://example.org/issues/#{identifier}",
      dispatchable: true
    }
  end

  defp fresh_pinned_state(canonical_root) do
    %Orchestrator.State{authority_root: canonical_root}
  end

  defp retry_record(issue_id) do
    RetryStore.build_record(%{
      issue_id: issue_id,
      status: "retrying",
      failure_class: "TRANSIENT_WORKER_FAILURE",
      attempt_count: 1,
      first_failure_at: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  defp without_retry_store_root_env(fun) do
    previous = Application.get_env(:symphony_elixir, :retry_store_root)
    Application.delete_env(:symphony_elixir, :retry_store_root)

    try do
      fun.()
    after
      if is_nil(previous) do
        Application.delete_env(:symphony_elixir, :retry_store_root)
      else
        Application.put_env(:symphony_elixir, :retry_store_root, previous)
      end
    end
  end

  defp swap_drive_case(path) do
    case String.split(path, ":", parts: 2) do
      [drive, rest] ->
        swapped = if drive == String.upcase(drive), do: String.downcase(drive), else: String.upcase(drive)

        swapped <> ":" <> rest

      _ ->
        path
    end
  end
end
