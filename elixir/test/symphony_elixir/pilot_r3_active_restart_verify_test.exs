defmodule SymphonyElixir.PilotR3ActiveRestartVerifyTest do
  @moduledoc """
  PILOT-R3-ACTIVE-RESTART-VERIFY: independent, deterministic, offline evidence
  for the mission question — can an armed pilot issue with a previously
  persisted `active` attempt record be automatically dispatched again after a
  Symphony restart?

  Each test first materializes the mission's seven-condition precondition
  (armed pilot, MIC-306 previously dispatched, durable record `active`,
  in-memory claim absent, queue label present, launch fence ALLOWED, no retry
  timer) as on-disk residue identical to what the production dispatch path
  writes, then drives the REAL restart-recovery path (`Orchestrator.start_link`
  → `init/1` → `recover_retry_records/1`) and probes the second-dispatch gates:
  poller admission (`should_dispatch_issue?` — the only gate `choose_issues`
  consults) and, in the unarmed counterfactual, the worker-launch primitive
  (`Task.Supervisor` children).

  These tests never touch Linear, never start a real worker, never call a
  provider: the spawned probe task fails fast against the mock provider and is
  waited out before the test process exits.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Control
  alias SymphonyElixir.LaunchMarker
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.PilotGuard
  alias SymphonyElixir.RetryStore
  alias SymphonyElixir.WorkerContainment

  @fence_grace_ms 100
  @fence_hard_budget_ms 300

  # ---------------------------------------------------------------------------
  # Scenario 1: runtime stops before any durable parked transition; the old
  # worker drained and its wrapper receipt proves death (launch fence ALLOWED
  # by positive termination evidence).
  # ---------------------------------------------------------------------------

  test "armed restart of a durable active record with a fence-ALLOWED drained marker cannot reach a second dispatch", %{
    root: root
  } do
    {issue, fixture} = materialize_residue!("drained", root, marker: :drained)
    arm_pilot!()

    # Seven-condition precondition, asserted literally before the restart:
    assert PilotGuard.armed?(), "pilot must be armed"
    assert {:ok, record} = RetryStore.read_record(root, issue.id)
    assert record["status"] == "active", "durable record must still be active"
    refute MapSet.member?(%Orchestrator.State{}.claimed, issue.id), "in-memory claim absent"
    assert issue.labels == ["repo:symphony-runtime"], "queue label still present"
    assert LaunchMarker.reuse_gate(issue.id, root: fixture.launch_root) == :allowed, "launch fence ALLOWED"
    assert record["next_retry_at"] == nil, "no retry timer scheduled on the active record"

    # Restart: a REAL orchestrator process, full init/1 recovery.
    pid = start_orchestrator("drained-restart")
    state = :sys.get_state(pid)

    try do
      # The validated harness pin is restored (unchanged behavior)...
      assert Map.fetch!(state.harness_pins, issue.id).harness == :opencode

      # ...but the restart-recovery guard parks the issue fail-closed:
      assert Map.fetch!(state.parked, issue.id).stop_reason == :pilot_single_attempt
      assert MapSet.member?(state.claimed, issue.id)
      assert state.retry_attempts == %{}, "no retry timer armed"

      # Poller admission — the only gate choose_issues consults — refuses.
      refute Orchestrator.should_dispatch_issue_for_test(issue, state)

      # The durable record now carries the terminal park.
      assert {:ok, record} = RetryStore.read_record(root, issue.id)
      assert record["status"] == "parked"
      assert record["stop_reason"] == "pilot_single_attempt"
      assert record["harness"] == "opencode"
    after
      Process.exit(pid, :normal)
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 2: the fence is ALLOWED purely by marker absence (the residue a
  # confirmed CONTROL terminate leaves: marker cleared, durable record never
  # transitioned out of "active").
  # ---------------------------------------------------------------------------

  test "armed restart of an active record with no launch marker parks; the absent-marker fence cannot reopen dispatch", %{
    root: root
  } do
    {issue, fixture} = materialize_residue!("terminate-cleared", root, marker: :none)
    arm_pilot!()

    assert LaunchMarker.reuse_gate(issue.id, root: fixture.launch_root) == :allowed, "fence ALLOWED (no marker)"
    assert {:ok, %{"status" => "active"}} = RetryStore.read_record(root, issue.id)

    pid = start_orchestrator("terminate-cleared-restart")
    state = :sys.get_state(pid)

    try do
      assert Map.fetch!(state.parked, issue.id).stop_reason == :pilot_single_attempt
      assert MapSet.member?(state.claimed, issue.id)
      assert state.retry_attempts == %{}
      refute Orchestrator.should_dispatch_issue_for_test(issue, state)
      assert {:ok, %{"status" => "parked", "stop_reason" => "pilot_single_attempt"}} = RetryStore.read_record(root, issue.id)
    after
      Process.exit(pid, :normal)
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 3: the full CONTROL terminate + restart chain, live. Orchestrator
  # #1 holds the first attempt as its running worker; a confirmed terminate
  # clears the launch marker and leaves the durable record "active"; #1 stops;
  # orchestrator #2 recovers the still-"active" record through real init.
  # ---------------------------------------------------------------------------

  test "live CONTROL terminate then restart parks the still-active record; no second dispatch fires", %{
    root: root
  } do
    {issue, fixture} = materialize_residue!("live-terminate", root, marker: :live)
    issue_id = issue.id

    # Orchestrator #1 starts while the node is not yet armed — the arm flag is
    # only consulted by dispatch/recovery paths, none of which run before the
    # inject below restores the mid-first-attempt state.
    pid1 = start_orchestrator("live-terminate-first")
    worker = inject_running!(pid1, issue)
    arm_pilot!()

    state1 = :sys.get_state(pid1)
    assert MapSet.member?(state1.claimed, issue_id), "first attempt holds the claim"
    assert {:ok, %{"status" => "active"}} = RetryStore.read_record(root, issue_id)

    assert {:ok, terminate_receipt} = Control.request(:terminate, %{issue_id: issue_id}, server: pid1)
    finalized = await_finalized!(pid1, terminate_receipt.control_id)
    assert finalized.outcome == :terminated

    # Confirmed terminate clears the marker (fence ALLOWED by absence)...
    assert LaunchMarker.reuse_gate(issue_id, root: fixture.launch_root) == :allowed

    # ...and never transitions the durable record: still "active".
    assert {:ok, %{"status" => "active"}} = RetryStore.read_record(root, issue_id)

    # Terminate alone never implies relaunch: the issue is blocked (held).
    state1_after = :sys.get_state(pid1)
    assert Map.has_key?(state1_after.blocked, issue_id)
    refute Orchestrator.should_dispatch_issue_for_test(issue, state1_after)

    Process.exit(worker, :kill)
    GenServer.stop(pid1, :normal)

    # Restart: orchestrator #2 recovers through real init while armed.
    pid2 = start_orchestrator("live-terminate-restart")
    state2 = :sys.get_state(pid2)

    try do
      assert Map.fetch!(state2.parked, issue_id).stop_reason == :pilot_single_attempt
      assert MapSet.member?(state2.claimed, issue_id)
      assert state2.retry_attempts == %{}
      refute Orchestrator.should_dispatch_issue_for_test(issue, state2)
      assert {:ok, %{"status" => "parked", "stop_reason" => "pilot_single_attempt"}} = RetryStore.read_record(root, issue_id)
    after
      Process.exit(pid2, :normal)
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 4: the counterfactual. IDENTICAL residue with the pilot unarmed:
  # the same restart leaves the issue poller-admissible and the worker-launch
  # primitive IS reached. This isolates PilotGuard.armed?() — evaluated inside
  # recover_active_lifecycle_record — as the authoritative condition.
  # ---------------------------------------------------------------------------

  test "unarmed restart of the identical residue is poller-admissible and reaches the launch primitive", %{
    root: root
  } do
    {issue, _fixture} = materialize_residue!("unarmed-counterfactual", root, marker: :none)
    refute PilotGuard.armed?()

    pid = start_orchestrator("unarmed-restart")
    state = :sys.get_state(pid)

    try do
      # Pin-only recovery: no park, no claim — the behavior the guard replaces.
      assert state.parked == %{}
      refute MapSet.member?(state.claimed, issue.id)
      assert Map.fetch!(state.harness_pins, issue.id).harness == :opencode
      assert Orchestrator.should_dispatch_issue_for_test(issue, state), "poller admits the same issue"

      # The launch primitive is reached: a worker task spawns.
      {:ok, sup} = start_test_task_supervisor("unarmed-launch")
      launched = Orchestrator.dispatch_issue_for_test(%{state | task_supervisor: sup, codex_totals: codex_totals()}, issue)

      try do
        assert Map.has_key?(launched.running, issue.id), "second dispatch reached running"
        wait_until(fn -> Task.Supervisor.children(sup) != [] end)
      after
        wait_out_spawned_tasks(sup)
      end
    after
      cancel_timers(state)
      Process.exit(pid, :normal)
    end
  end

  # ---------------------------------------------------------------------------
  # Fixtures — residue identical to what production writes.
  # ---------------------------------------------------------------------------

  setup do
    root = create_temp_fixture_root!("pilot-r3-active-restart-verify")
    previous = Application.get_env(:symphony_elixir, :retry_store_root)
    Application.put_env(:symphony_elixir, :retry_store_root, root)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:symphony_elixir, :retry_store_root)
      else
        Application.put_env(:symphony_elixir, :retry_store_root, previous)
      end

      remove_temp_fixture_root!(root)
    end)

    {:ok, root: root}
  end

  # Materializes the precondition as durable residue: the exact `active`
  # lifecycle pin the dispatch path commits (commit_harness_pin →
  # RetryStore.merge_harness_pin when no record exists yet) plus the launch
  # marker AppServer records before a contained launch (with the wrapper's
  # TERMINATED_CONFIRMED receipt when the scenario calls for a drained
  # worker). Does NOT arm the pilot; scenarios arm explicitly.
  defp materialize_residue!(name, root, marker: marker_kind) do
    issue = %Issue{
      id: "issue-mic-306-#{String.replace(name, "_", "-")}",
      identifier: "MIC-306",
      title: "Active-restart verify " <> name,
      state: "In Progress",
      labels: ["repo:symphony-runtime"],
      url: "https://example.test/issues/MIC-306",
      dispatchable: true
    }

    fixture = fence_fixture!(name)
    identity = write_marker!(fixture, issue, marker_kind)

    :ok =
      RetryStore.write_lifecycle_pin(root, %{
        issue_id: issue.id,
        identifier: issue.identifier,
        status: "active",
        harness: :opencode,
        harness_authority: :pinned,
        harness_evidence: "dispatch:opencode_selected",
        worker_host: nil,
        workspace_path: nil,
        workspace_root: root,
        route: :primary,
        primary_failure_count: 0
      })

    {issue, Map.put(fixture, :identity, identity)}
  end

  defp fence_fixture!(name) do
    test_root = create_temp_fixture_root!("pilot-r3-verify-fence-#{name}")
    on_exit(fn -> remove_temp_fixture_root!(test_root) end)

    fixture = setup_source_fixture!(test_root)
    state_root = Path.join(test_root, "state")
    launch_root = Path.join(state_root, "launches")
    receipt_root = Path.join(state_root, "receipts")

    previous_launch_root = Application.get_env(:symphony_elixir, :launch_marker_root)
    previous_receipt_root = Application.get_env(:symphony_elixir, :worker_termination_receipt_root)
    previous_hard_budget = Application.get_env(:symphony_elixir, :worker_termination_hard_budget_ms)

    Application.put_env(:symphony_elixir, :launch_marker_root, launch_root)
    Application.put_env(:symphony_elixir, :worker_termination_receipt_root, receipt_root)
    Application.put_env(:symphony_elixir, :worker_termination_hard_budget_ms, @fence_hard_budget_ms)

    on_exit(fn ->
      restore_fixture_env(:launch_marker_root, previous_launch_root)
      restore_fixture_env(:worker_termination_receipt_root, previous_receipt_root)
      restore_fixture_env(:worker_termination_hard_budget_ms, previous_hard_budget)
    end)

    defaults = [
      tracker_kind: "memory",
      workspace_root: fixture.workspace_root,
      codex_stall_timeout_ms: 50,
      codex_read_timeout_ms: 300,
      codex_worker_containment_enabled: false,
      codex_worker_termination_grace_ms: @fence_grace_ms,
      routing: %{
        target_label_prefix: "repo:",
        default_branch: "main",
        targets: %{
          "symphony-runtime" => %{source_path: fixture.source_repo, remote: fixture.remote_repo}
        }
      },
      opencode_enabled: true,
      opencode_provider: "mockprovider",
      opencode_model: "mock-model",
      opencode_allowed_tools: ["read"],
      opencode_allowed_issues: ["MIC-306"]
    ]

    write_workflow_file!(Workflow.workflow_file_path(), defaults)
    File.mkdir_p!(fixture.workspace_root)

    Map.merge(fixture, %{test_root: test_root, launch_root: launch_root, receipt_root: receipt_root})
  end

  defp restore_fixture_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_fixture_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp setup_source_fixture!(test_root) do
    File.mkdir_p!(test_root)

    remote_repo = Path.join(test_root, "remote.git") |> String.replace("\\", "/")
    source_repo = Path.join(test_root, "source") |> String.replace("\\", "/")
    workspace_root = Path.join(test_root, "workspaces") |> String.replace("\\", "/")

    git!(["init", "--bare", remote_repo])
    git!(["init", "-b", "main", source_repo])
    git!(["-C", source_repo, "config", "user.name", "Test User"])
    git!(["-C", source_repo, "config", "user.email", "test@example.com"])
    File.write!(Path.join(source_repo, "README.md"), "initial content\n")
    git!(["-C", source_repo, "add", "README.md"])
    git!(["-C", source_repo, "commit", "-m", "initial commit"])
    git!(["-C", source_repo, "remote", "add", "origin", remote_repo])
    git!(["-C", source_repo, "push", "-u", "origin", "main"])

    %{remote_repo: remote_repo, source_repo: source_repo, workspace_root: workspace_root}
  end

  defp git!(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, code} -> flunk("git #{Enum.join(args, " ")} failed (#{code}): #{output}")
    end
  end

  # marker_kind:
  #   :drained — marker + TERMINATED_CONFIRMED receipt (worker death proven).
  #   :live    — marker only (launch residue; death not yet proven).
  #   :none    — no marker (cleared by a confirmed CONTROL terminate).
  defp write_marker!(_fixture, _issue, :none), do: nil

  defp write_marker!(fixture, issue, marker_kind) do
    workspace = Path.join(fixture.workspace_root, Workspace.workspace_key(issue))
    git!(["-C", fixture.source_repo, "worktree", "add", workspace, "-b", "symphony/#{issue.identifier}"])
    File.write!(Path.join(workspace, "workpad.md"), "active-restart-verify sentinel\n")

    identity =
      WorkerContainment.new_identity(
        issue_id: issue.id,
        attempt_id: 1,
        workspace: workspace,
        worker_host: nil
      )

    assert :ok = LaunchMarker.record(identity, identifier: issue.identifier, attempt_id: 1)

    if marker_kind == :drained do
      File.mkdir_p!(Path.dirname(identity["receipt_path"]))

      receipt = %{
        "schema_version" => 1,
        "launch_id" => identity["launch_id"],
        "tree_drained" => true,
        "terminal_reason" => "HARD_JOB_TERMINATION",
        "termination_mode" => "hard",
        "child_exit_code" => 1
      }

      File.write!(identity["receipt_path"], Jason.encode!(receipt))
    end

    identity
  end

  defp arm_pilot! do
    :ok = PilotGuard.arm(workflow_path: Workflow.workflow_file_path())
  end

  defp start_orchestrator(tag) do
    {:ok, pid} = Orchestrator.start_link(name: :"pilot-r3-verify-#{tag}-#{:erlang.unique_integer([:positive])}")

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    pid
  end

  # Brings orchestrator #1 into the state a live first dispatch would have:
  # the worker task running and the issue claimed.
  defp inject_running!(pid, issue) do
    worker = spawn(fn -> Process.sleep(:infinity) end)

    entry = %{
      pid: worker,
      ref: nil,
      identifier: issue.identifier,
      issue: issue,
      worker_host: nil,
      workspace_path: nil,
      workspace_root: nil,
      termination_expectation: :NOT_APPLICABLE,
      worker_identity: nil,
      worker_termination: nil,
      session_id: nil,
      route: :primary,
      resumed: false,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_app_server_pid: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      turn_count: 0,
      retry_attempt: 0,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn state ->
      ref = Process.monitor(worker)
      entry = Map.put(entry, :ref, ref)
      %{state | running: Map.put(state.running, issue.id, entry), claimed: MapSet.put(state.claimed, issue.id)}
    end)

    worker
  end

  defp await_finalized!(server, control_id, attempts \\ 200)

  defp await_finalized!(_server, _control_id, 0), do: flunk("control receipt was never finalized")

  defp await_finalized!(server, control_id, attempts) do
    receipt = Enum.find(Control.receipts(server), &(&1.control_id == control_id))

    cond do
      receipt == nil ->
        flunk("control receipt #{control_id} missing from the ledger")

      receipt.outcome != :termination_pending ->
        receipt

      true ->
        Process.sleep(25)
        await_finalized!(server, control_id, attempts - 1)
    end
  end

  defp wait_until(fun, attempts \\ 200)

  defp wait_until(_fun, 0), do: flunk("condition was never met")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      wait_until(fun, attempts - 1)
    end
  end

  defp cancel_timers(%Orchestrator.State{retry_attempts: attempts}) do
    Enum.each(attempts, fn {_id, entry} ->
      case Map.get(entry, :timer_ref) do
        ref when is_reference(ref) -> Process.cancel_timer(ref)
        _other -> :ok
      end
    end)
  end

  defp start_test_task_supervisor(suffix) do
    name = Module.concat(__MODULE__, :"VerifyTaskSup_#{suffix}_#{System.unique_integer([:positive])}")
    {:ok, sup} = Task.Supervisor.start_link(name: name)

    on_exit(fn ->
      if Process.whereis(name) do
        try do
          GenServer.stop(name)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    {:ok, sup}
  end

  defp codex_totals do
    %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
  end

  defp wait_out_spawned_tasks(sup, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    while_children_alive(sup, deadline)
  end

  defp while_children_alive(sup, deadline) do
    if Task.Supervisor.children(sup) == [] do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("spawned probe tasks never exited")
      end

      Process.sleep(25)
      while_children_alive(sup, deadline)
    end
  end
end
