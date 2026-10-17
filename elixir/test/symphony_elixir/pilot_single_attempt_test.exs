defmodule SymphonyElixir.PilotSingleAttemptTest do
  @moduledoc """
  PILOT-SINGLE-ATTEMPT: an armed OpenCode-only pilot never automatically
  dispatches a second worker attempt for an issue pinned to the authorized
  OpenCode harness.

  Offline only. These tests never start a worker and never call a provider:
  they drive the retry-scheduling funnel directly (`schedule_issue_retry` is
  the single admission point for every automatic rescheduling path), the
  restart recovery rehydration, and the CONTROL relaunch/recovery verbs
  against a live orchestrator process with injected fixtures.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Control
  alias SymphonyElixir.LaunchMarker
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.PilotGuard
  alias SymphonyElixir.RetryStore
  alias SymphonyElixir.WorkerContainment

  setup do
    root = create_temp_fixture_root!("pilot-single-attempt")
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

  # -- armed pilot + OpenCode pin: one attempt, then park ----------------------

  test "an armed pilot parks a failed OpenCode-pinned issue instead of scheduling a retry", %{
    root: root
  } do
    issue = test_issue("ISS-PSA-FAIL", "MIC-PSA-FAIL")
    enable_pilot!(issue)
    arm_pilot!()

    next = Orchestrator.handle_failure_for_test(fresh_state(), issue.id, running_entry(issue), "sess-fail", :provider_outage)

    try do
      parked = Orchestrator.parked_for_test(next)
      assert parked[issue.id].stop_reason == :pilot_single_attempt
      assert parked[issue.id].harness == :opencode
      assert MapSet.member?(next.claimed, issue.id)
      assert next.retry_attempts == %{}

      assert {:ok, record} = RetryStore.read_record(root, issue.id)
      assert record["status"] == "parked"
      assert record["stop_reason"] == "pilot_single_attempt"
      assert record["harness"] == "opencode"
      assert record["harness_authority"] == "pinned"

      # The parked issue is not re-admitted by the dispatch poller.
      refute Orchestrator.should_dispatch_issue_for_test(issue, next)
    after
      cancel_timers(next)
    end
  end

  test "an armed pilot suppresses the post-completion continuation for an OpenCode-pinned issue", %{
    root: root
  } do
    issue = test_issue("ISS-PSA-CONT", "MIC-PSA-CONT")
    enable_pilot!(issue)
    arm_pilot!()

    next = Orchestrator.continue_running_issue_for_test(fresh_state(), issue.id, running_entry(issue))

    try do
      assert next.retry_attempts == %{}
      assert Orchestrator.parked_for_test(next)[issue.id].stop_reason == :pilot_single_attempt
      assert MapSet.member?(next.claimed, issue.id)

      assert {:ok, record} = RetryStore.read_record(root, issue.id)
      assert record["status"] == "parked"
      assert record["stop_reason"] == "pilot_single_attempt"

      refute Orchestrator.should_dispatch_issue_for_test(issue, next)
    after
      cancel_timers(next)
    end
  end

  test "an armed pilot parks a stalled OpenCode attempt instead of restarting it" do
    issue = test_issue("ISS-PSA-STALL", "MIC-PSA-STALL")
    enable_pilot!(issue)
    arm_pilot!()

    worker = spawn(fn -> Process.sleep(:infinity) end)

    entry =
      running_entry(issue)
      |> Map.merge(%{pid: worker, ref: nil, started_at: DateTime.add(DateTime.utc_now(), -3_600_000, :millisecond)})

    # The live orchestrator initializes the token totals at boot; the offline
    # state fixture must carry the same shape for the completion bookkeeping.
    # The stall restart reads the harness pin committed at dispatch time (the
    # stall path itself never re-derives it), so the fixture pins it too.
    totals = %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    pin = %{harness: :opencode, authority: :pinned, evidence: "dispatch:opencode_selected"}

    state = %{fresh_state() | running: %{issue.id => entry}, codex_totals: totals, harness_pins: %{issue.id => pin}}

    next = Orchestrator.reconcile_stalled_running_issues_for_test(state)

    try do
      assert Orchestrator.parked_for_test(next)[issue.id].stop_reason == :pilot_single_attempt
      assert next.retry_attempts == %{}
      assert MapSet.member?(next.claimed, issue.id)
    after
      Process.exit(worker, :kill)
      cancel_timers(next)
    end
  end

  # -- restart recovery ---------------------------------------------------------

  test "restart recovery of a retrying OpenCode record parks instead of re-arming the retry timer", %{
    root: root
  } do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    record =
      RetryStore.build_record(%{
        issue_id: "ISS-PSA-REC",
        identifier: "MIC-PSA-REC",
        status: "retrying",
        failure_class: "TRANSIENT_WORKER_FAILURE",
        attempt_count: 1,
        identical_failure_count: 1,
        first_failure_at: now,
        last_failure_at: now,
        last_error: "provider outage",
        workspace_root: root,
        worker_identity: "never_spawned",
        harness: :opencode,
        harness_authority: :pinned,
        harness_evidence: "dispatch:opencode_selected"
      })

    :ok = RetryStore.write_record(root, record)
    arm_pilot!()

    next = Orchestrator.recover_retry_records_for_test(fresh_state())

    try do
      assert Orchestrator.parked_for_test(next)["ISS-PSA-REC"].stop_reason == :pilot_single_attempt
      assert MapSet.member?(next.claimed, "ISS-PSA-REC")
      assert next.retry_attempts == %{}
    after
      cancel_timers(next)
    end
  end

  test "restart recovery of a continuing OpenCode record parks instead of arming the continuation timer", %{
    root: root
  } do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    record =
      RetryStore.build_record(%{
        issue_id: "ISS-PSA-CONT-REC",
        identifier: "MIC-PSA-CONT-REC",
        status: "continuing",
        failure_class: "TRANSIENT_WORKER_FAILURE",
        attempt_count: 1,
        first_failure_at: now,
        last_failure_at: now,
        workspace_root: root,
        harness: :opencode,
        harness_authority: :pinned,
        harness_evidence: "continuation:opencode"
      })

    :ok = RetryStore.write_record(root, record)
    arm_pilot!()

    next = Orchestrator.recover_retry_records_for_test(fresh_state())

    try do
      assert Orchestrator.parked_for_test(next)["ISS-PSA-CONT-REC"].stop_reason == :pilot_single_attempt
      assert MapSet.member?(next.claimed, "ISS-PSA-CONT-REC")
      assert next.retry_attempts == %{}
    after
      cancel_timers(next)
    end
  end

  test "a parked single-attempt issue survives restart recovery as parked with claim and no timer", %{
    root: _root
  } do
    issue = test_issue("ISS-PSA-POLL", "MIC-PSA-POLL")
    enable_pilot!(issue)
    arm_pilot!()

    next = Orchestrator.handle_failure_for_test(fresh_state(), issue.id, running_entry(issue), "sess-poll", :provider_outage)

    try do
      refute Orchestrator.should_dispatch_issue_for_test(issue, next)

      # A restart rehydrates the durable parked record: parked + claimed, no
      # timer, and still closed to the poller.
      recovered = Orchestrator.recover_retry_records_for_test(fresh_state())

      try do
        assert Orchestrator.parked_for_test(recovered)[issue.id].stop_reason == :recovered_parked
        assert MapSet.member?(recovered.claimed, issue.id)
        assert recovered.retry_attempts == %{}
        refute Orchestrator.should_dispatch_issue_for_test(issue, recovered)
      after
        cancel_timers(recovered)
      end
    after
      cancel_timers(next)
    end
  end

  # -- restart safety: durable "active" records (PILOT-R3) ----------------------
  #
  # A durable "active" lifecycle record is durable evidence of a previous
  # authorized attempt: dispatch commits it (merge_harness_pin -> active pin)
  # before the worker spawns, and it survives every restart scenario that
  # loses the in-memory claim — crash during execution, a drain whose DOWN
  # handling never ran, CONTROL terminate followed by a restart. Restart
  # recovery must never leave such an issue poller-admissible: with a
  # fence-ALLOWED marker (drain receipt, or no marker at all) the poller
  # would otherwise launch a second worker without ever passing through
  # schedule_issue_retry/4.

  test "restart recovery of a durable active OpenCode record parks fail-closed with claim and no timer", %{
    root: root
  } do
    issue = fence_issue("ISS-PSA-ACT", "MIC-PSA-ACT")
    fixture = fence_fixture!("active-recovery", issue)
    write_drained_marker!(fixture, issue)

    # The lifecycle pin dispatch commits at spawn time (RetryStore
    # merge_harness_pin writes an "active" record when none exists).
    :ok = write_active_lifecycle_pin!(root, issue)

    arm_pilot!()

    recovered = Orchestrator.recover_retry_records_for_test(fresh_state())

    try do
      # The validated harness pin is restored (unchanged behavior)…
      assert Map.fetch!(recovered.harness_pins, issue.id).harness == :opencode

      # …but the issue is no longer poller-admissible: single-attempt park.
      assert Orchestrator.parked_for_test(recovered)[issue.id].stop_reason == :pilot_single_attempt
      assert MapSet.member?(recovered.claimed, issue.id)
      assert recovered.retry_attempts == %{}
      refute Orchestrator.should_dispatch_issue_for_test(issue, recovered)

      # The durable record now carries the same terminal park the scheduling
      # funnel writes, with the validated harness authority preserved.
      assert {:ok, record} = RetryStore.read_record(root, issue.id)
      assert record["status"] == "parked"
      assert record["stop_reason"] == "pilot_single_attempt"
      assert record["harness"] == "opencode"
      assert record["harness_authority"] == "pinned"
    after
      cancel_timers(recovered)
    end
  end

  test "a fence-ALLOWED restart of an active OpenCode attempt cannot reach a second worker launch", %{
    root: root
  } do
    issue = fence_issue("ISS-PSA-DRAIN", "MIC-PSA-DRAIN")
    fixture = fence_fixture!("active-drain-race", issue)
    identity = write_drained_marker!(fixture, issue)

    # Drain/DOWN race residue: the worker drained and its receipt proves
    # death (the same durable state a CONTROL terminate + drain leaves), but
    # the DOWN handling that would rewrite the retry record never ran, so the
    # record is still "active".
    :ok = write_active_lifecycle_pin!(root, issue)
    assert {:ok, :opencode, :pinned, _} = RetryStore.harness_authority(RetryStore.read_record(root, issue.id) |> elem(1))

    arm_pilot!()

    recovered = Orchestrator.recover_retry_records_for_test(fresh_state())

    # The launch fence alone is ALLOWED here — it is not the mechanism that
    # blocks the second worker; poller admission is.
    assert LaunchMarker.reuse_gate(issue.id, root: fixture.launch_root) == :allowed

    {:ok, sup} = start_test_task_supervisor("drain-race")
    poller_view = %{recovered | task_supervisor: sup, codex_totals: codex_totals()}

    try do
      # The poller (choose_issues' only admission gate) must refuse.
      refute Orchestrator.should_dispatch_issue_for_test(issue, poller_view)
      assert Orchestrator.parked_for_test(poller_view)[issue.id].stop_reason == :pilot_single_attempt
      assert MapSet.member?(poller_view.claimed, issue.id)

      # No second worker ever reaches the spawn primitive.
      assert Task.Supervisor.children(sup) == []
    after
      wait_out_spawned_tasks(sup)
      cancel_timers(poller_view)
      _ = identity
      :ok
    end
  end

  test "a genuinely fresh authorized pilot issue remains dispatchable after recovery", %{root: _root} do
    issue = fence_issue("ISS-PSA-FRESH", "MIC-PSA-FRESH")
    fixture = fence_fixture!("fresh-dispatchable", issue)
    arm_pilot!()

    # No durable record, no marker: recovery of an empty store is a no-op.
    recovered = Orchestrator.recover_retry_records_for_test(fresh_state())
    assert Orchestrator.parked_for_test(recovered) == %{}
    assert Orchestrator.should_dispatch_issue_for_test(issue, recovered)

    # And the same machinery still launches exactly one first worker.
    {:ok, sup} = start_test_task_supervisor("fresh-dispatch")
    state = %{recovered | task_supervisor: sup, codex_totals: codex_totals()}

    try do
      dispatched = Orchestrator.dispatch_issue_for_test(state, issue)

      assert Map.has_key?(dispatched.running, issue.id)
      wait_until(fn -> Task.Supervisor.children(sup) != [] end, 5_000)
    after
      wait_out_spawned_tasks(sup)
      cancel_timers(recovered)
      _ = fixture
      :ok
    end
  end

  test "an unarmed restart keeps the existing pin-only recovery of an active record", %{root: root} do
    issue = fence_issue("ISS-PSA-ACT-UNARMED", "MIC-PSA-ACT-UNARMED")
    fixture = fence_fixture!("active-unarmed", issue)
    write_drained_marker!(fixture, issue)
    :ok = write_active_lifecycle_pin!(root, issue)

    refute PilotGuard.armed?()

    recovered = Orchestrator.recover_retry_records_for_test(fresh_state())

    try do
      assert Map.fetch!(recovered.harness_pins, issue.id).harness == :opencode
      assert Orchestrator.parked_for_test(recovered) == %{}
      refute MapSet.member?(recovered.claimed, issue.id)
      assert Orchestrator.should_dispatch_issue_for_test(issue, recovered)
    after
      cancel_timers(recovered)
    end
  end

  test "an armed pilot does not single-attempt park a Codex active record at recovery; F1 owns its dispatch admission", %{
    root: root
  } do
    issue = fence_issue("ISS-PSA-ACT-CODEX", "MIC-PSA-ACT-CODEX")
    fixture = fence_fixture!("active-codex", issue)
    write_drained_marker!(fixture, issue)

    :ok =
      RetryStore.write_lifecycle_pin(root, %{
        issue_id: issue.id,
        identifier: issue.identifier,
        status: "active",
        harness: :codex,
        harness_authority: :pinned,
        harness_evidence: "dispatch:codex_selected",
        worker_host: nil,
        workspace_path: nil,
        workspace_root: root,
        route: :primary,
        primary_failure_count: 0
      })

    arm_pilot!()

    recovered = Orchestrator.recover_retry_records_for_test(fresh_state())

    try do
      # Recovery restores the Codex pin but does not apply the OpenCode
      # single-attempt gate; an armed-node redispatch is still refused at
      # dispatch admission by the PILOT-GUARD-F1 codex refusal.
      assert Map.fetch!(recovered.harness_pins, issue.id).harness == :codex
      assert Orchestrator.parked_for_test(recovered) == %{}
      refute MapSet.member?(recovered.claimed, issue.id)
      assert Orchestrator.should_dispatch_issue_for_test(issue, recovered)
    after
      cancel_timers(recovered)
    end
  end

  test "CONTROL terminate followed by a restart blocks redispatch through the single-attempt funnel", %{
    root: root
  } do
    issue_id = "issue-psa-term-restart"
    identifier = "MIC-PSA-TERM-RESTART"
    issue = fence_issue(issue_id, identifier)
    fixture = fence_fixture!("terminate-restart", issue)

    # Durable residue of [authorized dispatch -> CONTROL terminate -> restart]:
    # the active lifecycle pin written at dispatch time and the launch marker
    # (no receipt — the terminate evidence watcher never confirmed a drain).
    # The terminate's in-memory blocked map and claim die with the old BEAM.
    :ok = write_active_lifecycle_pin!(root, issue)
    write_marker!(fixture, issue)
    arm_pilot!()

    # Restart: recovery of orchestrator #2.
    recovered = Orchestrator.recover_retry_records_for_test(fresh_state())

    try do
      assert Orchestrator.parked_for_test(recovered)[issue_id].stop_reason == :pilot_single_attempt
      assert MapSet.member?(recovered.claimed, issue_id)
      assert recovered.retry_attempts == %{}
      refute Orchestrator.should_dispatch_issue_for_test(issue, recovered)

      assert {:ok, record} = RetryStore.read_record(root, issue_id)
      assert record["status"] == "parked"
      assert record["stop_reason"] == "pilot_single_attempt"

      # The recovery park refuses CONTROL recovery exactly like a funnel park:
      # the rehydrated entry reads the durable stop reason (:recovered_parked
      # -> "pilot_single_attempt" -> :unclassified).
      live = start_orchestrator()

      assert {:ok, recovery_receipt} = Control.request(:recover_parked, %{issue_id: issue_id}, server: live)
      assert recovery_receipt.outcome == :rejected_not_fence_parked
      assert recovery_receipt.evidence.category == :unclassified
    after
      cancel_timers(recovered)
    end
  end

  # -- CONTROL ------------------------------------------------------------------

  test "CONTROL relaunch of an armed-pilot OpenCode attempt parks instead of scheduling a replacement", %{
    root: root
  } do
    pid = start_orchestrator()
    issue_id = "issue-psa-relaunch"
    arm_pilot!()

    inject_running(pid, issue_id, identifier: "PSA-RL", termination_expectation: :NOT_APPLICABLE, worker_identity: nil, retry_attempt: 0)
    inject_harness_pin(pid, issue_id)

    assert {:ok, terminate_receipt} = Control.request(:terminate, %{issue_id: issue_id}, server: pid)
    finalized = await_finalized(pid, terminate_receipt.control_id)
    assert finalized.outcome == :terminated

    assert {:ok, relaunch_receipt} = Control.request(:relaunch, %{issue_id: issue_id, attempt_id: :current}, server: pid)
    assert relaunch_receipt.outcome == :relaunch_scheduled
    assert relaunch_receipt.evidence.replacement_retry_attempt == nil

    state = :sys.get_state(pid)
    assert state.retry_attempts == %{}
    assert state.blocked == %{}
    assert state.parked[issue_id].stop_reason == :pilot_single_attempt
    assert MapSet.member?(state.claimed, issue_id)

    assert {:ok, record} = RetryStore.read_record(root, issue_id)
    assert record["status"] == "parked"
    assert record["stop_reason"] == "pilot_single_attempt"
  end

  test "CONTROL recover_parked refuses a pilot single-attempt park", %{root: _root} do
    pid = start_orchestrator()
    issue_id = "issue-psa-recover"
    arm_pilot!()

    worker =
      inject_running(pid, issue_id, identifier: "PSA-REC", termination_expectation: :NOT_APPLICABLE, worker_identity: nil, retry_attempt: 0)

    inject_harness_pin(pid, issue_id)

    # The live failure path: killing the worker drives the real funnel into
    # the suppression park.
    Process.exit(worker, :kill)

    wait_until(fn ->
      case :sys.get_state(pid).parked[issue_id] do
        nil -> false
        entry -> entry.stop_reason == :pilot_single_attempt
      end
    end)

    assert {:ok, recovery_receipt} = Control.request(:recover_parked, %{issue_id: issue_id}, server: pid)
    assert recovery_receipt.outcome == :rejected_not_fence_parked
    assert recovery_receipt.evidence.park_stop_reason == "pilot_single_attempt"
    assert recovery_receipt.evidence.category == :unclassified

    state = :sys.get_state(pid)
    assert state.parked[issue_id].stop_reason == :pilot_single_attempt
    assert MapSet.member?(state.claimed, issue_id)
    assert state.retry_attempts == %{}
  end

  # -- scope: unarmed and non-OpenCode lifecycles are unchanged ------------------

  test "an unarmed pilot keeps the existing failure retry envelope for the same lifecycle" do
    issue = test_issue("ISS-PSA-UNARMED", "MIC-PSA-UNARMED")
    enable_pilot!(issue)
    refute PilotGuard.armed?()

    next = Orchestrator.handle_failure_for_test(fresh_state(), issue.id, running_entry(issue), "sess-unarmed", :provider_outage)

    try do
      retry = Map.fetch!(next.retry_attempts, issue.id)
      assert retry.attempt == 1
      assert Orchestrator.parked_for_test(next) == %{}
    after
      cancel_timers(next)
    end
  end

  test "an armed pilot does not gate a Codex-pinned lifecycle at the scheduling funnel" do
    issue = test_issue("ISS-PSA-CODEX", "MIC-PSA-CODEX")
    arm_pilot!()

    entry = running_entry(issue) |> Map.put(:harness, :codex)

    next = Orchestrator.handle_failure_for_test(fresh_state(), issue.id, entry, "sess-codex", :provider_outage)

    try do
      assert Map.fetch!(next.retry_attempts, issue.id).attempt == 1
      assert Orchestrator.parked_for_test(next) == %{}
    after
      cancel_timers(next)
    end
  end

  test "the poller still admits an active unpinned issue while the pilot is armed" do
    issue = test_issue("ISS-PSA-OPEN", "MIC-PSA-OPEN")
    arm_pilot!()

    state = fresh_state()
    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  # -- helpers ------------------------------------------------------------------

  defp fresh_state, do: %Orchestrator.State{}

  defp test_issue(id, identifier) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Pilot single-attempt " <> identifier,
      description: "PILOT-SINGLE-ATTEMPT",
      state: "Todo",
      url: "https://example.test/issues/" <> identifier,
      dispatchable: true
    }
  end

  # The lifecycle fixture mirrors the retry-envelope suite: the workspace_root
  # is the test's owned retry-store root so lifecycle cleanup can never touch
  # the shared TEMP root, and NOT_APPLICABLE keeps the legacy reuse-gate
  # semantics for a non-managed attempt.
  defp running_entry(issue) do
    workspace_root = Application.fetch_env!(:symphony_elixir, :retry_store_root)

    %{
      identifier: issue.identifier,
      issue: issue,
      harness: :opencode,
      worker_host: nil,
      workspace_path: Path.join(workspace_root, "ws-" <> issue.id),
      workspace_root: workspace_root,
      termination_expectation: :NOT_APPLICABLE,
      retry_attempt: 0,
      started_at: DateTime.utc_now()
    }
  end

  defp arm_pilot! do
    :ok = PilotGuard.arm(workflow_path: Workflow.workflow_file_path())
  end

  defp enable_pilot!(issue, model \\ "mock-model") do
    write_workflow_file!(Workflow.workflow_file_path(),
      opencode_enabled: true,
      opencode_provider: "mockprovider",
      opencode_model: model,
      opencode_allowed_tools: ["read"],
      opencode_allowed_issues: [issue.identifier]
    )
  end

  defp start_orchestrator do
    {:ok, pid} = Orchestrator.start_link(name: :"pilot-single-attempt-#{:erlang.unique_integer([:positive])}")

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    pid
  end

  defp inject_running(pid, issue_id, overrides) do
    worker = spawn(fn -> Process.sleep(:infinity) end)
    identifier = overrides[:identifier] || issue_id

    entry =
      Map.merge(
        %{
          pid: worker,
          ref: nil,
          identifier: identifier,
          issue: test_issue(issue_id, identifier),
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
        },
        Map.new(overrides)
      )

    :sys.replace_state(pid, fn state ->
      ref = Process.monitor(worker)
      entry = Map.put(entry, :ref, ref)
      %{state | running: Map.put(state.running, issue_id, entry), claimed: MapSet.put(state.claimed, issue_id)}
    end)

    worker
  end

  defp inject_harness_pin(pid, issue_id) do
    :sys.replace_state(pid, fn state ->
      pin = %{harness: :opencode, authority: :pinned, evidence: "dispatch:opencode_selected"}
      %{state | harness_pins: Map.put(state.harness_pins, issue_id, pin)}
    end)

    :ok
  end

  defp await_finalized(server, control_id, attempts \\ 200)

  defp await_finalized(_server, _control_id, 0) do
    flunk("control receipt was never finalized")
  end

  defp await_finalized(server, control_id, attempts) do
    receipt = Enum.find(Control.receipts(server), &(&1.control_id == control_id))

    cond do
      receipt == nil ->
        flunk("control receipt #{control_id} missing from the ledger")

      receipt.outcome != :termination_pending ->
        receipt

      true ->
        Process.sleep(25)
        await_finalized(server, control_id, attempts - 1)
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

  # -- restart-safety fixtures (mirroring the launch-fence suite) ---------------

  @fence_grace_ms 100
  @fence_hard_budget_ms 300

  defp fence_issue(id, identifier) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Pilot restart safety " <> identifier,
      state: "In Progress",
      labels: ["repo:symphony-runtime"],
      url: "https://example.test/issues/" <> identifier,
      dispatchable: true
    }
  end

  # A dispatch-shaped workflow fixture: memory tracker, the source fixture's
  # routing, containment off (the spawned probe task fails fast with no
  # provider), and the issue's OpenCode authorization. `issue` may be nil to
  # skip the OpenCode allowlist entry.
  defp fence_fixture!(name, issue) do
    test_root = SymphonyElixir.TestSupport.create_temp_fixture_root!("pilot-restart-safety-#{name}")
    on_exit(fn -> SymphonyElixir.TestSupport.remove_temp_fixture_root!(test_root) end)

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
      if is_nil(previous_launch_root) do
        Application.delete_env(:symphony_elixir, :launch_marker_root)
      else
        Application.put_env(:symphony_elixir, :launch_marker_root, previous_launch_root)
      end

      if is_nil(previous_receipt_root) do
        Application.delete_env(:symphony_elixir, :worker_termination_receipt_root)
      else
        Application.put_env(:symphony_elixir, :worker_termination_receipt_root, previous_receipt_root)
      end

      if is_nil(previous_hard_budget) do
        Application.delete_env(:symphony_elixir, :worker_termination_hard_budget_ms)
      else
        Application.put_env(:symphony_elixir, :worker_termination_hard_budget_ms, previous_hard_budget)
      end
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
      }
    ]

    opencode =
      if issue do
        [
          opencode_enabled: true,
          opencode_provider: "mockprovider",
          opencode_model: "mock-model",
          opencode_allowed_tools: ["read"],
          opencode_allowed_issues: [issue.identifier]
        ]
      else
        []
      end

    write_workflow_file!(Workflow.workflow_file_path(), Keyword.merge(defaults, opencode))

    File.mkdir_p!(fixture.workspace_root)

    Map.merge(fixture, %{test_root: test_root, launch_root: launch_root, receipt_root: receipt_root})
  end

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

  # The workspace a previous attempt used, and the launch marker AppServer
  # records before a contained launch.
  defp write_marker!(fixture, issue) do
    workspace = Path.join(fixture.workspace_root, Workspace.workspace_key(issue))
    git!(["-C", fixture.source_repo, "worktree", "add", workspace, "-b", "symphony/#{issue.identifier}"])
    File.write!(Path.join(workspace, "workpad.md"), "restart-safety sentinel\n")

    identity =
      WorkerContainment.new_identity(
        issue_id: issue.id,
        attempt_id: 1,
        workspace: workspace,
        worker_host: nil
      )

    assert :ok = LaunchMarker.record(identity, identifier: issue.identifier, attempt_id: 1)
    identity
  end

  # The drain/DOWN race residue: the same marker, plus the wrapper's
  # TERMINATED_CONFIRMED receipt — proof of death, with the retry record
  # left untouched ("active").
  defp write_drained_marker!(fixture, issue) do
    identity = write_marker!(fixture, issue)
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
    identity
  end

  # The exact lifecycle pin a dispatch commits (RetryStore.merge_harness_pin
  # writes an "active" record when the issue has no record yet).
  defp write_active_lifecycle_pin!(root, issue) do
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
  end

  defp start_test_task_supervisor(suffix) do
    name = Module.concat(__MODULE__, :"RestartSafetyTaskSup_#{suffix}_#{System.unique_integer([:positive])}")
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

  # The probe task a permitted spawn launches fails fast (no provider in this
  # fixture); wait it out so the test process outlives its monitor.
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
