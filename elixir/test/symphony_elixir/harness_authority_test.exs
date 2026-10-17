defmodule SymphonyElixir.HarnessAuthorityTest do
  @moduledoc """
  M1-HARNESS-F: harness identity is pinned for an issue/workspace lifecycle.

  Offline only. These tests never start a worker. They drive the orchestrator
  decision and the durable retry record.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.LaunchMarker
  alias SymphonyElixir.RetryStore
  alias SymphonyElixir.WorkerContainment

  setup do
    root = create_temp_fixture_root!("harness-authority")
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

  test "an OpenCode failure retry persists the pinned harness", %{root: root} do
    issue = test_issue("ISS-OC-PERSIST", "MIC-OC-PERSIST")
    next = Orchestrator.handle_failure_for_test(%Orchestrator.State{}, issue.id, running_entry(issue, root, :opencode), "sess-oc", :provider_outage)

    try do
      assert {:ok, record} = RetryStore.read_record(root, issue.id)
      assert record["status"] == "retrying"
      assert record["schema_version"] == 1
      assert record["harness"] == "opencode"
      assert record["harness_authority"] == "pinned"
      assert record["harness_evidence"] =~ "opencode"
      assert next.harness_pins[issue.id].harness == :opencode
    after
      cancel_timers(next)
    end
  end

  test "revoked OpenCode authorization parks the next attempt instead of launching Codex", %{root: root} do
    issue = test_issue("ISS-OC-REVOKE", "MIC-OC-REVOKE")
    enable_pilot!(issue)

    {{:dispatch, :opencode, pilot}, pinned} = Orchestrator.decide_harness_for_test(%Orchestrator.State{}, issue)
    assert pilot.model == "mock-model"
    assert {:ok, %{"status" => "active", "harness" => "opencode"}} = RetryStore.read_record(root, issue.id)

    disable_opencode!()

    {{:park, :harness_authorization_revoked, evidence}, parked} = Orchestrator.decide_harness_for_test(pinned, issue)

    try do
      assert evidence =~ "pinned_harness=opencode"
      assert evidence =~ "opencode_disabled"
      assert parked.running == %{}
      assert Map.has_key?(Orchestrator.parked_for_test(parked), issue.id)
      assert parked.harness_pins[issue.id].harness == :opencode

      assert {:ok, record} = RetryStore.read_record(root, issue.id)
      assert record["status"] == "parked"
      assert record["harness"] == "opencode"
      assert record["harness_authority"] == "pinned"
      assert record["harness_evidence"] == evidence
      assert record["stop_reason"] == "harness_authorization_revoked"
      refute record["harness"] == "codex"
    after
      cancel_timers(parked)
    end
  end

  test "removing the issue from the OpenCode allowlist parks with the authorization reason", %{root: root} do
    issue = test_issue("ISS-OC-ALLOW", "MIC-OC-ALLOW")
    enable_pilot!(issue)
    {{:dispatch, :opencode, _pilot}, pinned} = Orchestrator.decide_harness_for_test(%Orchestrator.State{}, issue)

    write_workflow_file!(Workflow.workflow_file_path(),
      opencode_enabled: true,
      opencode_provider: "mockprovider",
      opencode_model: "mock-model",
      opencode_allowed_tools: ["read"],
      opencode_allowed_issues: ["MIC-OTHER"]
    )

    {{:park, :harness_authorization_revoked, evidence}, parked} = Orchestrator.decide_harness_for_test(pinned, issue)

    try do
      assert evidence =~ "issue_not_authorized"
      assert {:ok, %{"harness" => "opencode", "harness_evidence" => ^evidence}} = RetryStore.read_record(root, issue.id)
    after
      cancel_timers(parked)
    end
  end

  test "a valid OpenCode model change stays inside the pinned harness", %{root: _root} do
    issue = test_issue("ISS-OC-MODEL", "MIC-OC-MODEL")
    enable_pilot!(issue, "mock-model")
    {{:dispatch, :opencode, first}, pinned} = Orchestrator.decide_harness_for_test(%Orchestrator.State{}, issue)
    assert first.model == "mock-model"

    enable_pilot!(issue, "mock-model-b")
    {{:dispatch, :opencode, second}, parked} = Orchestrator.decide_harness_for_test(pinned, issue)

    try do
      assert second.provider == "mockprovider"
      assert second.model == "mock-model-b"
      assert parked.harness_pins[issue.id].harness == :opencode
    after
      cancel_timers(parked)
    end
  end

  test "an existing Codex lifecycle stays on Codex when OpenCode becomes eligible", %{root: root} do
    issue = test_issue("ISS-CDX-KEEP", "MIC-CDX-KEEP")
    {{:dispatch, :codex, _reason}, pinned} = Orchestrator.decide_harness_for_test(%Orchestrator.State{}, issue)
    assert {:ok, %{"status" => "active", "harness" => "codex"}} = RetryStore.read_record(root, issue.id)

    enable_pilot!(issue)
    {{:dispatch, :codex, evidence}, kept} = Orchestrator.decide_harness_for_test(pinned, issue)

    try do
      assert kept.harness_pins[issue.id].harness == :codex
      assert kept.running == %{}
      assert is_binary(evidence) or is_atom(evidence)
      assert {:ok, record} = RetryStore.read_record(root, issue.id)
      assert record["harness"] == "codex"
    after
      cancel_timers(kept)
    end
  end

  test "Codex provider fallback stays available inside the pinned harness", %{root: _root} do
    issue = test_issue("ISS-CDX-ROUTE", "MIC-CDX-ROUTE")
    {{:dispatch, :codex, _reason}, pinned} = Orchestrator.decide_harness_for_test(%Orchestrator.State{}, issue)

    pinned = %{
      pinned
      | retry_history: Map.put(pinned.retry_history, issue.id, %{route: :fallback, primary_failure_count: 2})
    }

    assert Orchestrator.next_dispatch_route_for_test(pinned, issue.id) == :fallback

    enable_pilot!(issue)
    {{:dispatch, :codex, _evidence}, kept} = Orchestrator.decide_harness_for_test(pinned, issue)

    try do
      assert Orchestrator.next_dispatch_route_for_test(kept, issue.id) == :fallback
      assert kept.harness_pins[issue.id].harness == :codex
    after
      cancel_timers(kept)
    end
  end

  test "normal continuation persists the harness and restart keeps it", %{root: root} do
    issue = test_issue("ISS-OC-CONT", "MIC-OC-CONT")
    enable_pilot!(issue)
    continued = Orchestrator.continue_running_issue_for_test(%Orchestrator.State{}, issue.id, running_entry(issue, root, :opencode))

    try do
      assert {:ok, record} = RetryStore.read_record(root, issue.id)
      assert record["status"] == "continuing"
      assert record["harness"] == "opencode"
      assert record["harness_authority"] == "pinned"
      assert record["harness_evidence"] =~ "continuation:opencode"
      assert continued.harness_pins[issue.id].harness == :opencode
    after
      cancel_timers(continued)
    end

    recovered = Orchestrator.recover_retry_records_for_test(%Orchestrator.State{})

    try do
      assert recovered.harness_pins[issue.id].harness == :opencode
      assert Map.fetch!(recovered.retry_attempts, issue.id).attempt == 1

      {{:dispatch, :opencode, _pilot}, _still} = Orchestrator.decide_harness_for_test(recovered, issue)

      disable_opencode!()
      {{:park, :harness_authorization_revoked, evidence}, parked} = Orchestrator.decide_harness_for_test(recovered, issue)
      assert evidence =~ "opencode_disabled"
      assert parked.running == %{}
    after
      cancel_timers(recovered)
    end
  end

  test "restart recovery of a pinned OpenCode retry does not substitute Codex", %{root: root} do
    issue = test_issue("ISS-OC-RESTART", "MIC-OC-RESTART")
    entry = running_entry(issue, root, :opencode) |> Map.put(:worker_identity, "never_spawned")
    failed = Orchestrator.handle_failure_for_test(%Orchestrator.State{}, issue.id, entry, "sess-r", :provider_outage)

    try do
      assert {:ok, %{"harness" => "opencode", "status" => "retrying"}} = RetryStore.read_record(root, issue.id)
    after
      cancel_timers(failed)
    end

    recovered = Orchestrator.recover_retry_records_for_test(%Orchestrator.State{})

    try do
      assert recovered.harness_pins[issue.id].harness == :opencode
      disable_opencode!()
      {{:park, :harness_authorization_revoked, _evidence}, parked} = Orchestrator.decide_harness_for_test(recovered, issue)
      assert parked.harness_pins[issue.id].harness == :opencode
      assert {:ok, %{"harness" => "opencode"}} = RetryStore.read_record(root, issue.id)
    after
      cancel_timers(recovered)
    end
  end

  test "a provably legacy Codex record stays Codex when OpenCode becomes eligible", %{root: root} do
    issue = test_issue("ISS-LEGACY", "MIC-LEGACY")
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    :ok =
      RetryStore.write_record(
        root,
        RetryStore.build_record(%{
          issue_id: issue.id,
          identifier: issue.identifier,
          status: "retrying",
          failure_class: "PROVIDER_OUTAGE",
          attempt_count: 1,
          first_failure_at: now,
          last_failure_at: now,
          workspace_root: root,
          worker_identity: "never_spawned"
        })
      )

    recovered = Orchestrator.recover_retry_records_for_test(%Orchestrator.State{})

    try do
      assert recovered.harness_pins[issue.id].harness == :codex
      assert recovered.harness_pins[issue.id].authority == :legacy_codex
      enable_pilot!(issue)
      {{:dispatch, :codex, evidence}, kept} = Orchestrator.decide_harness_for_test(recovered, issue)
      assert kept.harness_pins[issue.id].harness == :codex
      assert evidence =~ "legacy_codex"
    after
      cancel_timers(recovered)
    end
  end

  test "an OpenCode worker identity without a validated pin is not read as Codex", %{root: root} do
    issue = test_issue("ISS-AMBIG-OC", "MIC-AMBIG-OC")
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    record =
      RetryStore.build_record(%{
        issue_id: issue.id,
        identifier: issue.identifier,
        status: "retrying",
        failure_class: "PROVIDER_OUTAGE",
        attempt_count: 1,
        first_failure_at: now,
        last_failure_at: now,
        workspace_root: root,
        worker_identity: %{"launch_id" => "launch-oc", "harness" => "opencode", "issue_id" => issue.id}
      })

    :ok = RetryStore.write_record(root, record)
    recovered = Orchestrator.recover_retry_records_for_test(%Orchestrator.State{})

    try do
      assert recovered.retry_attempts == %{}
      assert Map.has_key?(Orchestrator.parked_for_test(recovered), issue.id)
      assert recovered.harness_pins[issue.id] == nil

      assert {:ok, saved} = RetryStore.read_record(root, issue.id)
      assert saved["status"] == "parked"
      assert saved["harness_authority"] == "missing"
      assert saved["harness_evidence"] =~ "worker_identity.harness=opencode"
      refute saved["harness"] == "codex"
    after
      cancel_timers(recovered)
    end
  end

  test "an invalid harness value parks without being coerced to Codex", %{root: root} do
    issue = test_issue("ISS-BAD-H", "MIC-BAD-H")
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    record =
      RetryStore.build_record(%{
        issue_id: issue.id,
        identifier: issue.identifier,
        status: "parked",
        failure_class: "PROVIDER_OUTAGE",
        attempt_count: 1,
        first_failure_at: now,
        last_failure_at: now,
        workspace_root: root
      })
      |> Map.put("harness", "claude")
      |> Map.put("harness_authority", "pinned")

    :ok = RetryStore.write_record(root, record)
    recovered = Orchestrator.recover_retry_records_for_test(%Orchestrator.State{})

    try do
      assert recovered.retry_attempts == %{}
      assert {:ok, saved} = RetryStore.read_record(root, issue.id)
      assert saved["harness"] == "claude"
      assert saved["harness_authority"] == "missing"
      assert saved["harness_evidence"] =~ "harness=claude"
      refute saved["harness"] == "codex"
    after
      cancel_timers(recovered)
    end
  end

  test "a legacy record plus a surviving OpenCode launch marker is not Codex", %{root: root} do
    issue = test_issue("ISS-MARKER", "MIC-MARKER")
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    workspace = Path.join(root, "ws-marker")
    File.mkdir_p!(workspace)

    identity =
      WorkerContainment.new_identity(
        issue_id: issue.id,
        workspace: workspace,
        authority_root: root,
        harness: :opencode
      )

    assert :ok = LaunchMarker.record(identity, root: root, identifier: issue.identifier)

    :ok =
      RetryStore.write_record(
        root,
        RetryStore.build_record(%{
          issue_id: issue.id,
          identifier: issue.identifier,
          status: "retrying",
          failure_class: "PROVIDER_OUTAGE",
          attempt_count: 1,
          first_failure_at: now,
          last_failure_at: now,
          workspace_root: root,
          worker_identity: "never_spawned"
        })
      )

    recovered = Orchestrator.recover_retry_records_for_test(%Orchestrator.State{authority_root: root})

    try do
      assert recovered.retry_attempts == %{}
      assert Map.has_key?(Orchestrator.parked_for_test(recovered), issue.id)
      assert {:ok, saved} = RetryStore.read_record(root, issue.id)
      assert saved["harness_evidence"] =~ "launch_marker.harness=opencode"
      refute saved["harness"] == "codex"
    after
      cancel_timers(recovered)
    end
  end

  test "a contradictory pin parks and records both sides", %{root: root} do
    issue = test_issue("ISS-MISMATCH", "MIC-MISMATCH")
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    record =
      RetryStore.build_record(%{
        issue_id: issue.id,
        identifier: issue.identifier,
        status: "retrying",
        failure_class: "PROVIDER_OUTAGE",
        attempt_count: 1,
        first_failure_at: now,
        last_failure_at: now,
        workspace_root: root,
        worker_identity: "never_spawned",
        harness: :codex,
        harness_evidence: "dispatch:default_harness"
      })
      |> Map.put("worker_identity", %{"harness" => "opencode", "launch_id" => "l-mismatch"})

    :ok = RetryStore.write_record(root, record)
    recovered = Orchestrator.recover_retry_records_for_test(%Orchestrator.State{})

    try do
      assert recovered.retry_attempts == %{}
      assert {:ok, saved} = RetryStore.read_record(root, issue.id)
      assert saved["status"] == "parked"
      assert saved["harness"] == "codex"
      assert saved["harness_authority"] == "mismatch"
      assert saved["stop_reason"] == "harness_authority_mismatch"
      assert saved["harness_evidence"] =~ "pinned_harness=codex"
      assert saved["harness_evidence"] =~ "worker_identity.harness=opencode"
    after
      cancel_timers(recovered)
    end
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
      title: "Harness authority " <> identifier,
      description: "M1-HARNESS-F",
      state: "Todo",
      url: "https://example.test/issues/" <> identifier,
      dispatchable: true
    }
  end

  defp running_entry(issue, root, harness) do
    %{
      identifier: issue.identifier,
      issue: issue,
      worker_host: nil,
      workspace_path: Path.join(root, "ws-" <> issue.id),
      workspace_root: root,
      termination_expectation: :NOT_APPLICABLE,
      harness: harness
    }
  end

  defp cancel_timers(%Orchestrator.State{retry_attempts: attempts}) do
    Enum.each(attempts, fn {_id, entry} ->
      case Map.get(entry, :timer_ref) do
        ref when is_reference(ref) -> Process.cancel_timer(ref)
        _ -> :ok
      end
    end)

    flush_retry_messages()
  end

  defp flush_retry_messages do
    receive do
      {:retry_issue, _issue_id, _token} -> flush_retry_messages()
    after
      0 -> :ok
    end
  end
end
