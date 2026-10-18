defmodule SymphonyElixir.LifecycleRemediationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{LaunchMarker, RetryPolicy, RetryStore, WorkerContainment}

  setup do
    root = Application.fetch_env!(:symphony_elixir, :retry_store_root)
    Application.put_env(:symphony_elixir, :launch_marker_root, Path.join(root, "launches"))
    Application.put_env(:symphony_elixir, :worker_termination_receipt_root, Path.join(root, "receipts"))

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :launch_marker_root)
      Application.delete_env(:symphony_elixir, :worker_termination_receipt_root)
    end)

    %{root: root}
  end

  defp issue do
    %Issue{id: "remediation-fixture", identifier: "TEST-1", title: "Offline safety fixture", state: "Todo", labels: [], dispatchable: true}
  end

  defp generation(root) do
    workspace = Path.join(root, "TEST-1")
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "work.txt"), "preserve")
    identity = WorkerContainment.new_identity(issue_id: issue().id, workspace: workspace, worker_host: nil)
    assert :ok = LaunchMarker.record(identity)
    assert {:ok, marker} = LaunchMarker.read(issue().id)
    {marker, %{workspace_path: workspace, workspace_root: root, worker_host: nil}}
  end

  defp prove(marker) do
    identity = marker["worker_identity"]
    File.mkdir_p!(Path.dirname(identity["receipt_path"]))

    File.write!(
      identity["receipt_path"],
      Jason.encode!(%{
        "schema_version" => 1,
        "launch_id" => identity["launch_id"],
        "tree_drained" => true,
        "terminal_reason" => "NATURAL_EXIT",
        "termination_mode" => "natural_exit",
        "child_exit_code" => 0
      })
    )
  end

  test "preparation lock excludes cleanup; stale A cannot consume B or its marker", %{root: root} do
    {marker_a, metadata} = generation(root)
    owner = self()

    {preparer, ref} =
      spawn_monitor(fn ->
        LaunchMarker.with_issue_lock(issue().id, [], fn ->
          send(owner, :preparation_locked)

          receive do
            :prepare_b -> :ok
          end

          # Reentrant marker calls use exactly the same critical section.
          prove(marker_a)
          identity_b = WorkerContainment.new_identity(issue_id: issue().id, workspace: metadata.workspace_path)
          assert :ok = LaunchMarker.record(identity_b)
          send(owner, {:prepared_b, identity_b})

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :preparation_locked

    cleaner =
      Task.async(fn ->
        send(owner, :cleanup_requested)
        Orchestrator.cleanup_generation_for_test(issue(), metadata, issue().id, marker_a, [])
      end)

    assert_receive :cleanup_requested
    refute Task.yield(cleaner, 50)
    send(preparer, :prepare_b)
    assert_receive {:prepared_b, identity_b}
    send(preparer, :release)
    assert_receive {:DOWN, ^ref, :process, ^preparer, :normal}
    Task.await(cleaner, 5_000)
    assert {:ok, %{"launch_id" => current}} = LaunchMarker.read(issue().id)
    assert current == identity_b["launch_id"]
    assert File.read!(Path.join(metadata.workspace_path, "work.txt")) == "preserve"
    # A late session stop also cannot clear B.
    assert :ok = LaunchMarker.clear(marker_a["worker_identity"])
    assert {:ok, %{"launch_id" => ^current}} = LaunchMarker.read(issue().id)
  end

  test "concurrent cleanup consumes a matching generation at most once", %{root: root} do
    {marker, metadata} = generation(root)
    prove(marker)

    1..2
    |> Enum.map(fn _ -> Task.async(fn -> Orchestrator.cleanup_generation_for_test(issue(), metadata, issue().id, marker, []) end) end)
    |> Enum.each(&Task.await(&1, 5_000))

    refute File.exists?(metadata.workspace_path)
    assert {:error, :not_found} = LaunchMarker.read(issue().id)
    File.mkdir_p!(metadata.workspace_path)
    File.write!(Path.join(metadata.workspace_path, "successor.txt"), "new preparation")
    Orchestrator.cleanup_generation_for_test(issue(), metadata, issue().id, marker, [])
    assert File.exists?(Path.join(metadata.workspace_path, "successor.txt"))
  end

  test "corrupt marker blocks cleanup and reuse", %{root: root} do
    {marker, metadata} = generation(root)
    prove(marker)
    File.write!(LaunchMarker.marker_path(issue().id), "corrupt")
    Orchestrator.cleanup_generation_for_test(issue(), metadata, issue().id, marker, [])
    assert File.exists?(metadata.workspace_path)
    assert {:blocked, :launch_marker_unreadable} = LaunchMarker.reuse_gate(issue().id)
  end

  test "malformed or unreadable retry record blocks actual dispatch without overwriting evidence", %{root: root} do
    path = RetryStore.record_path(root, issue().id)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "{invalid")
    state = Orchestrator.dispatch_issue_for_test(%Orchestrator.State{}, issue())
    assert state.running == %{}
    assert state.retry_state_error
    assert File.read!(path) == "{invalid"
    File.rm!(path)
    File.mkdir_p!(path)
    state = Orchestrator.dispatch_issue_for_test(%Orchestrator.State{}, issue())
    assert state.running == %{}
    assert state.retry_state_error
    assert File.dir?(path)
  end

  test "retry directory read error blocks startup recovery and dispatch", %{root: root} do
    File.mkdir_p!(Path.dirname(RetryStore.retries_dir(root)))
    File.write!(RetryStore.retries_dir(root), "not a directory")
    state = Orchestrator.recover_retry_records_for_test(%Orchestrator.State{})
    assert state.retry_state_error
    state = Orchestrator.dispatch_issue_for_test(state, issue())
    assert state.running == %{}
    assert File.read!(RetryStore.retries_dir(root)) == "not a directory"
  end

  test "parking persistence failure is explicit and restart cannot dispatch", %{root: root} do
    path = RetryStore.record_path(root, issue().id)
    File.mkdir_p!(path)
    entry = %{identifier: issue().identifier, issue: issue(), termination_expectation: :NOT_APPLICABLE}
    state = Orchestrator.handle_failure_for_test(%Orchestrator.State{}, issue().id, entry, "fixture", :unauthorized)
    assert state.parked[issue().id].persistence_error
    assert state.retry_state_error
    assert state.retry_attempts == %{}
    restarted = Orchestrator.recover_retry_records_for_test(%Orchestrator.State{})
    assert restarted.retry_state_error
    assert Orchestrator.dispatch_issue_for_test(restarted, issue()).running == %{}
  end

  test "restart enforces attempt and age limits before creating timers", %{root: root} do
    for {id, count, first, expected} <- [
          {"exhausted-attempts", RetryPolicy.max_attempts(), DateTime.utc_now(), :max_attempts},
          {"exhausted-age", 1, DateTime.add(DateTime.utc_now(), -RetryPolicy.max_age_ms(), :millisecond), :max_age}
        ] do
      record =
        RetryStore.build_record(%{
          issue_id: id,
          status: "retrying",
          failure_class: "PROVIDER_OUTAGE",
          attempt_count: count,
          identical_failure_count: 1,
          first_failure_at: DateTime.to_iso8601(first),
          worker_identity: "never_spawned"
        })

      assert :ok = RetryStore.write_record(root, record)
      state = Orchestrator.recover_retry_records_for_test(%Orchestrator.State{})
      assert state.retry_attempts == %{}
      assert state.parked[id].stop_reason == expected
      assert {:ok, persisted} = RetryStore.read_record(root, id)
      assert persisted["status"] == "parked"
      assert persisted["first_failure_at"] == record["first_failure_at"]
    end
  end

  test "transient parking write failure leaves the previous inflight intent parked after storage heals", %{root: root} do
    record = RetryStore.build_record(%{issue_id: issue().id, status: "retrying", failure_class: "PROVIDER_OUTAGE", attempt_count: 2, identical_failure_count: 2, worker_identity: "never_spawned"})
    assert :ok = RetryStore.write_record(root, record)
    assert :ok = Orchestrator.persist_retry_poll_intent_for_test(%Orchestrator.State{}, issue().id, %{})
    path = RetryStore.record_path(root, issue().id)
    durable_before_failure = File.read!(path)
    # Simulate an inaccessible record during the failed atomic update, then
    # restore the last durable bytes exactly as storage recovery would expose.
    File.rename!(path, path <> ".fixture-backup")
    File.mkdir_p!(path)
    entry = %{identifier: issue().identifier, issue: issue(), termination_expectation: :NEVER_STARTED}
    state = Orchestrator.handle_failure_for_test(%Orchestrator.State{}, issue().id, entry, "fixture", :unauthorized)
    assert state.parked[issue().id].persistence_error
    File.rmdir!(path)
    File.rename!(path <> ".fixture-backup", path)
    assert File.read!(path) == durable_before_failure
    restarted = Orchestrator.recover_retry_records_for_test(%Orchestrator.State{})
    assert restarted.retry_attempts == %{}
    assert restarted.parked[issue().id].stop_reason == :recovered_parked
    assert Orchestrator.dispatch_issue_for_test(restarted, issue()).running == %{}
  end

  test "failure timestamp survives subsequent failures and restart", %{root: root} do
    entry = %{identifier: issue().identifier, issue: issue(), termination_expectation: :NEVER_STARTED}
    first = Orchestrator.handle_failure_for_test(%Orchestrator.State{}, issue().id, entry, "fixture", :provider_outage)
    Process.cancel_timer(first.retry_attempts[issue().id].timer_ref)
    original = first.retry_history[issue().id].first_failure_at_dt
    second = Orchestrator.handle_failure_for_test(first, issue().id, entry, "fixture", :quota)
    Process.cancel_timer(second.retry_attempts[issue().id].timer_ref)
    assert second.retry_history[issue().id].first_failure_at_dt == original
    assert {:ok, record} = RetryStore.read_record(root, issue().id)
    assert record["first_failure_at"] == original
    recovered = Orchestrator.recover_retry_records_for_test(%Orchestrator.State{})
    Process.cancel_timer(recovered.retry_attempts[issue().id].timer_ref)
    assert recovered.retry_history[issue().id].attempt_count == 2
    assert recovered.retry_history[issue().id].first_failure_at_dt == original
  end

  test "repeated watchdog stalls consume the durable policy budget and retain workspace metadata", %{root: root} do
    write_workflow_file!(Workflow.workflow_file_path(), codex_stall_timeout_ms: 1)
    {:ok, supervisor} = Task.Supervisor.start_link()
    on_exit(fn -> if Process.alive?(supervisor), do: Supervisor.stop(supervisor) end)
    initial = %Orchestrator.State{task_supervisor: supervisor, codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}}

    states =
      Enum.scan(1..3, initial, fn _attempt, state ->
        {:ok, pid} = Task.Supervisor.start_child(supervisor, fn -> Process.sleep(:infinity) end)

        entry = %{
          pid: pid,
          ref: Process.monitor(pid),
          identifier: issue().identifier,
          issue: issue(),
          worker_host: "offline-host",
          workspace_root: root,
          workspace_path: Path.join(root, "TEST-1"),
          last_codex_timestamp: DateTime.add(DateTime.utc_now(), -60, :second),
          started_at: DateTime.utc_now(),
          termination_expectation: :NEVER_STARTED
        }

        next = Orchestrator.reconcile_stalled_running_issues_for_test(%{state | running: %{issue().id => entry}})
        if retry = next.retry_attempts[issue().id], do: Process.cancel_timer(retry.timer_ref)
        next
      end)

    [first, second, third] = states
    assert first.retry_history[issue().id].attempt_count == 1
    assert second.retry_history[issue().id].attempt_count == 2
    assert third.parked[issue().id].stop_reason == :max_identical
    assert third.retry_attempts == %{}
    assert first.retry_history[issue().id].first_failure_at_dt == third.retry_history[issue().id].first_failure_at_dt
    assert {:ok, record} = RetryStore.read_record(root, issue().id)
    assert record["attempt_count"] == 3
    assert record["worker_host"] == "offline-host"
    assert record["workspace_path"] == Path.join(root, "TEST-1")
    restarted = Orchestrator.recover_retry_records_for_test(initial)
    assert restarted.parked[issue().id].attempt_count == 3
    assert restarted.retry_attempts == %{}
  end

  test "CONTROL refuses recovery while any required durable retry state is untrusted", %{root: root} do
    {marker, _metadata} = generation(root)
    prove(marker)

    record =
      RetryStore.build_record(%{issue_id: issue().id, status: "parked", failure_class: "PROVIDER_OUTAGE", attempt_count: 1, worker_identity: marker["worker_identity"]})
      |> Map.put("stop_reason", "worker_termination_unconfirmed")

    assert :ok = RetryStore.write_record(root, record)
    original = File.read!(RetryStore.record_path(root, issue().id))
    state = Orchestrator.recover_retry_records_for_test(%Orchestrator.State{})
    state = %{state | retry_state_error: {:untrusted_retry_record, "other-issue"}}
    request = %{action: :recover_parked, issue_id: issue().id, attempt_id: :current, requested_by: :test_operator}

    assert {:reply, {:ok, %{outcome: :rejected_corrupt_evidence}}, next} =
             Orchestrator.handle_call({:control_request, request}, {self(), make_ref()}, state)

    assert next.retry_attempts == %{}
    assert Map.has_key?(next.parked, issue().id)
    assert File.read!(RetryStore.record_path(root, issue().id)) == original
  end

  test "retry poll failure persists its failure count and original time across restart", %{root: root} do
    entry = %{identifier: issue().identifier, issue: issue(), termination_expectation: :NEVER_STARTED, worker_host: "offline-host", workspace_path: Path.join(root, "TEST-1"), workspace_root: root}
    first = Orchestrator.handle_failure_for_test(%Orchestrator.State{}, issue().id, entry, "fixture", :provider_outage)
    Process.cancel_timer(first.retry_attempts[issue().id].timer_ref)
    metadata = Map.merge(entry, %{first_failure_at: first.retry_history[issue().id].first_failure_at_dt})
    second = Orchestrator.handle_retry_poll_failure_for_test(first, issue().id, 1, metadata, :offline_tracker_failure)
    Process.cancel_timer(second.retry_attempts[issue().id].timer_ref)
    assert {:ok, record} = RetryStore.read_record(root, issue().id)
    assert record["attempt_count"] == 2
    assert record["first_failure_at"] == first.retry_history[issue().id].first_failure_at_dt
    assert record["worker_host"] == "offline-host"
    recovered = Orchestrator.recover_retry_records_for_test(%Orchestrator.State{})
    Process.cancel_timer(recovered.retry_attempts[issue().id].timer_ref)
    assert recovered.retry_history[issue().id].attempt_count == 2
    assert recovered.retry_history[issue().id].first_failure_at_dt == record["first_failure_at"]
  end
end
