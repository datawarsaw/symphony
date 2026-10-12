defmodule SymphonyElixir.PilotGuardTest do
  @moduledoc """
  PILOT-GUARD-F1: an armed OpenCode-only pilot launches no Codex worker.

  Offline only. These tests never start a worker: they drive the orchestrator
  harness decision, the durable retry record, and the bootstrap arming seam.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.PilotGuard
  alias SymphonyElixir.RetryStore
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Workflow

  setup do
    root = create_temp_fixture_root!("pilot-guard")
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

  # -- armed pilot: authorized OpenCode still dispatches ----------------------

  test "an armed pilot dispatches an authorized issue to OpenCode", %{root: root} do
    issue = test_issue("ISS-PG-OK", "MIC-PG-OK")
    enable_pilot!(issue)
    arm_pilot!()

    {{:dispatch, :opencode, pilot}, state} = Orchestrator.decide_harness_for_test(%Orchestrator.State{}, issue)

    try do
      assert pilot.provider == "mockprovider"
      assert pilot.model == "mock-model"
      assert state.harness_pins[issue.id].harness == :opencode
      assert state.running == %{}

      assert {:ok, record} = RetryStore.read_record(root, issue.id)
      assert record["status"] == "active"
      assert record["harness"] == "opencode"
    after
      cancel_timers(state)
    end
  end

  # -- armed pilot: no Codex dispatch, park instead ---------------------------

  test "an armed pilot parks an unauthorized issue instead of dispatching Codex", %{root: root} do
    issue = test_issue("ISS-PG-NO", "MIC-PG-NO")
    enable_pilot!(test_issue("ISS-PG-OTHER", "MIC-PG-OTHER"))
    arm_pilot!()

    {{:park, :pilot_guard_codex_refusal, evidence}, state} =
      Orchestrator.decide_harness_for_test(%Orchestrator.State{}, issue)

    try do
      assert evidence =~ "pilot_guard:armed"
      assert evidence =~ "issue_not_authorized"

      assert state.running == %{}
      assert state.retry_attempts == %{}
      assert MapSet.member?(state.claimed, issue.id)

      assert Map.has_key?(Orchestrator.parked_for_test(state), issue.id)
      parked = Orchestrator.parked_for_test(state)[issue.id]
      assert parked.stop_reason == :pilot_guard_codex_refusal
      assert parked.failure_class == "AUTH_UNAVAILABLE"
      assert parked.error == evidence

      # No Codex pin is committed for a refused dispatch: re-admission after
      # operator action re-evaluates the harness from scratch.
      refute Map.has_key?(state.harness_pins, issue.id)

      assert {:ok, record} = RetryStore.read_record(root, issue.id)
      assert record["status"] == "parked"
      assert record["stop_reason"] == "pilot_guard_codex_refusal"
      refute record["harness"] == "codex"
    after
      cancel_timers(state)
    end
  end

  test "an armed pilot parks when the OpenCode configuration fails validation", %{root: root} do
    issue = test_issue("ISS-PG-BAD", "MIC-PG-BAD")

    # With the store alive an invalid reload keeps serving last-known-good, so
    # the validation failure is only observable at dispatch with the store
    # gone (the same path a crashed store takes). The shared restore restarts
    # it after this test.
    without_workflow_store!()

    write_workflow_file!(Workflow.workflow_file_path(),
      opencode_enabled: true,
      opencode_provider: nil,
      opencode_model: nil,
      opencode_allowed_tools: nil,
      opencode_allowed_issues: [issue.identifier]
    )

    arm_pilot!()

    {{:park, :pilot_guard_codex_refusal, evidence}, state} =
      Orchestrator.decide_harness_for_test(%Orchestrator.State{}, issue)

    try do
      assert evidence =~ "settings_unavailable"
      assert state.running == %{}
      assert Map.has_key?(Orchestrator.parked_for_test(state), issue.id)
      assert Orchestrator.parked_for_test(state)[issue.id].stop_reason == :pilot_guard_codex_refusal

      assert {:ok, record} = RetryStore.read_record(root, issue.id)
      assert record["status"] == "parked"
      refute record["harness"] == "codex"
    after
      cancel_timers(state)
    end
  end

  test "a workflow reload cannot disarm the guard or rescue an issue into Codex", %{root: root} do
    issue = test_issue("ISS-PG-RELOAD", "MIC-PG-RELOAD")
    enable_pilot!(issue)
    arm_pilot!()

    # The post-reload workflow disables the OpenCode section entirely; the
    # unguarded selector would fail over to the default Codex harness.
    disable_opencode!()

    {{:park, :pilot_guard_codex_refusal, evidence}, state} =
      Orchestrator.decide_harness_for_test(%Orchestrator.State{}, issue)

    try do
      assert evidence =~ "opencode_disabled"
      assert state.running == %{}
      assert Map.has_key?(Orchestrator.parked_for_test(state), issue.id)

      assert {:ok, record} = RetryStore.read_record(root, issue.id)
      assert record["status"] == "parked"
      refute record["harness"] == "codex"
    after
      cancel_timers(state)
    end
  end

  test "a durable Codex pin cannot dispatch Codex while the pilot is armed", %{root: root} do
    issue = test_issue("ISS-PG-PIN", "MIC-PG-PIN")

    # Before arming, the same issue dispatched through the default Codex
    # harness and committed the durable pin.
    {{:dispatch, :codex, _reason}, pinned} = Orchestrator.decide_harness_for_test(%Orchestrator.State{}, issue)
    assert pinned.harness_pins[issue.id].harness == :codex

    arm_pilot!()

    {{:park, :pilot_guard_codex_refusal, evidence}, state} = Orchestrator.decide_harness_for_test(pinned, issue)

    try do
      assert evidence =~ "pilot_guard:armed"
      assert state.running == %{}
      assert Map.has_key?(Orchestrator.parked_for_test(state), issue.id)

      assert {:ok, record} = RetryStore.read_record(root, issue.id)
      assert record["status"] == "parked"
      assert record["stop_reason"] == "pilot_guard_codex_refusal"
    after
      cancel_timers(state)
    end
  end

  # -- non-pilot configurations: unchanged Codex routing ----------------------

  test "a non-pilot configuration keeps the default Codex dispatch", %{root: root} do
    issue = test_issue("ISS-PG-PLAIN", "MIC-PG-PLAIN")
    refute PilotGuard.armed?()

    {{:dispatch, :codex, :opencode_disabled}, state} =
      Orchestrator.decide_harness_for_test(%Orchestrator.State{}, issue)

    try do
      assert state.harness_pins[issue.id].harness == :codex
      assert Orchestrator.parked_for_test(state) == %{}

      assert {:ok, record} = RetryStore.read_record(root, issue.id)
      assert record["status"] == "active"
      assert record["harness"] == "codex"
    after
      cancel_timers(state)
    end
  end

  test "a non-pilot configuration keeps the unauthorized-issue Codex failover", %{root: _root} do
    issue = test_issue("ISS-PG-FAILOVER", "MIC-PG-FAILOVER")
    enable_pilot!(test_issue("ISS-PG-SOMEONE-ELSE", "MIC-PG-SOMEONE-ELSE"))
    refute PilotGuard.armed?()

    {{:dispatch, :codex, :issue_not_authorized}, state} =
      Orchestrator.decide_harness_for_test(%Orchestrator.State{}, issue)

    try do
      assert state.harness_pins[issue.id].harness == :codex
      assert Orchestrator.parked_for_test(state) == %{}
    after
      cancel_timers(state)
    end
  end

  test "a non-pilot configuration keeps the invalid-config Codex rescue", %{root: _root} do
    issue = test_issue("ISS-PG-RESCUE", "MIC-PG-RESCUE")

    without_workflow_store!()

    write_workflow_file!(Workflow.workflow_file_path(),
      opencode_enabled: true,
      opencode_provider: nil,
      opencode_model: nil,
      opencode_allowed_tools: nil,
      opencode_allowed_issues: [issue.identifier]
    )

    refute PilotGuard.armed?()

    {{:dispatch, :codex, :settings_unavailable}, state} =
      Orchestrator.decide_harness_for_test(%Orchestrator.State{}, issue)

    try do
      assert state.harness_pins[issue.id].harness == :codex
      assert Orchestrator.parked_for_test(state) == %{}
    after
      cancel_timers(state)
    end
  end

  # -- armed-flag semantics ---------------------------------------------------

  test "the guard is unarmed unless the bootstrap armed flag is set" do
    Application.delete_env(:symphony_elixir, :pilot_guard)
    refute PilotGuard.armed?()

    :ok = PilotGuard.arm(workflow_path: "C:/pilot/WORKFLOW.md", source_sha: "abc123")
    assert PilotGuard.armed?()

    Application.delete_env(:symphony_elixir, :pilot_guard)
    refute PilotGuard.armed?()
  end

  test "a malformed armed record reads as unarmed, never as silently armed" do
    Application.put_env(:symphony_elixir, :pilot_guard, true)
    refute PilotGuard.armed?()

    Application.put_env(:symphony_elixir, :pilot_guard, %{armed: false})
    refute PilotGuard.armed?()
  after
    Application.delete_env(:symphony_elixir, :pilot_guard)
  end

  # -- helpers ---------------------------------------------------------------

  defp without_workflow_store! do
    case Process.whereis(SymphonyElixir.WorkflowStore) do
      nil ->
        :ok

      _pid ->
        :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
    end
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

  defp disable_opencode! do
    write_workflow_file!(Workflow.workflow_file_path(), [])
  end

  defp test_issue(id, identifier) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Pilot guard " <> identifier,
      description: "PILOT-GUARD-F1",
      state: "Todo",
      url: "https://example.test/issues/" <> identifier,
      dispatchable: true
    }
  end

  defp cancel_timers(%Orchestrator.State{retry_attempts: attempts}) do
    Enum.each(attempts, fn {_id, entry} ->
      case Map.get(entry, :timer_ref) do
        ref when is_reference(ref) -> Process.cancel_timer(ref)
        _other -> :ok
      end
    end)
  end
end
