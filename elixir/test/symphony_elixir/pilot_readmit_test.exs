defmodule SymphonyElixir.PilotReadmitTest do
  @moduledoc """
  PILOT-R4-READMISSION: the operator re-admission procedure for an issue
  parked by the pilot single-attempt guard is explicit, bounded, and
  fail-closed, and every automatic redispatch path stays blocked.

  Offline only. No worker is launched, no provider is contacted, no tracker
  is called. The tests drive the offline `PilotReadmit` procedure (the same
  module `mix symphony.pilot_readmit` wraps) against real durable fixtures —
  parked retry record, worker-termination receipt, launch marker, runtime
  authority lease — and drive the orchestrator restart recovery and the
  single-attempt funnel through the existing test seams.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Control
  alias SymphonyElixir.LaunchMarker
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.PilotGuard
  alias SymphonyElixir.PilotReadmit
  alias SymphonyElixir.RetryStore
  alias SymphonyElixir.RuntimeLease
  alias SymphonyElixir.WorkerContainment

  @issue_id "a09c4fd4-7583-402d-9ad8-a63d597213eb"
  @identifier "MIC-R4"
  @launch_id "1791876498544-5764"
  @last_failure_at "2026-10-13T07:28:34.420000Z"
  @confirmation "operator GO: one further supervised attempt approved (authorization ref R4-READMIT-1)"

  # ── 1. correct authorized re-admission ──────────────────────────────────────

  test "an authorized re-admission enables exactly one new single-attempt-guarded attempt", %{} do
    fixture = fixture_context!("happy")

    assert {:ok, receipt} = readmit(fixture)

    assert receipt.dry_run == false
    assert receipt.identifier == @identifier

    assert receipt.previous_attempt == %{
             status: "parked",
             stop_reason: "pilot_single_attempt",
             attempt_count: 1,
             last_failure_at: @last_failure_at
           }

    # The record is readmitted with every original field preserved plus the
    # embedded readmission evidence.
    assert {:ok, record} = RetryStore.read_record(fixture.state_root, @issue_id)
    assert record["status"] == "readmitted"
    assert record["stop_reason"] == "pilot_single_attempt"
    assert record["attempt_count"] == 1
    assert record["harness"] == "opencode"
    assert record["harness_authority"] == "pinned"

    assert record["readmission"]["readmission_id"] == receipt.readmission_id
    assert record["readmission"]["from_stop_reason"] == "pilot_single_attempt"
    assert record["readmission"]["from_launch_id"] == @launch_id
    assert record["readmission"]["authorization"] == @confirmation

    # The audit record identifies the previous attempt and the authorization.
    readmission_id = receipt.readmission_id

    assert {:ok, audit} = read_audit(fixture.state_root, @issue_id)
    assert [%{"readmission_id" => ^readmission_id, "authorization" => @confirmation} = entry] = audit
    assert entry["previous_attempt"]["stop_reason"] == "pilot_single_attempt"
    assert entry["previous_attempt"]["launch_id"] == @launch_id
    assert entry["termination_receipt_path"] == receipt.termination_receipt_path

    # Restart recovery admits the issue to the poller exactly once: pin
    # restored, no claim, no park, no timer.
    arm_pilot!()
    recovered = Orchestrator.recover_retry_records_for_test(fresh_state())

    try do
      assert Map.fetch!(recovered.harness_pins, @issue_id).harness == :opencode
      assert Orchestrator.parked_for_test(recovered) == %{}
      refute MapSet.member?(recovered.claimed, @issue_id)
      assert recovered.retry_attempts == %{}
      assert Orchestrator.should_dispatch_issue_for_test(issue(), recovered)

      # The single-attempt funnel guards the new attempt: its completion or
      # failure parks the issue again with the same terminal park.
      issue = issue()
      next = Orchestrator.handle_failure_for_test(recovered, @issue_id, running_entry(issue), "sess-new", :provider_outage)

      assert Orchestrator.parked_for_test(next)[@issue_id].stop_reason == :pilot_single_attempt
      assert MapSet.member?(next.claimed, @issue_id)
      assert next.retry_attempts == %{}
      refute Orchestrator.should_dispatch_issue_for_test(issue, next)

      # The re-park rewrites the record as a plain parked record (the audit
      # file, not the record, carries the preserved re-admission history).
      assert {:ok, record} = RetryStore.read_record(fixture.state_root, @issue_id)
      assert record["status"] == "parked"
      assert record["stop_reason"] == "pilot_single_attempt"
      refute Map.has_key?(record, "readmission")

      # A stale replay of the SAME command cannot clear the newer attempt:
      # the new park carries a later last_failure_at.
      assert {:error, {:pilot_readmit_refused, :expected_record_mismatch, evidence}} = readmit(fixture)
      assert "last_failure_at" in evidence.fields

      assert {:ok, audit} = read_audit(fixture.state_root, @issue_id)
      assert length(audit) == 1
    after
      cancel_timers(recovered)
    end
  end

  test "a dry run proves every precondition without writing any durable state", %{} do
    fixture = fixture_context!("dry-run")
    before = raw_record!(fixture.state_root)

    assert {:ok, receipt} = readmit(fixture, dry_run: true)

    assert receipt.dry_run == true
    assert receipt.launch_fence == :allowed
    assert receipt.termination_verdict == :dead
    assert raw_record!(fixture.state_root) == before
    refute File.exists?(PilotReadmit.audit_path(fixture.state_root, @issue_id))
  end

  # ── 2. missing authorization ────────────────────────────────────────────────

  test "a re-admission without explicit operator confirmation is refused", %{} do
    fixture = fixture_context!("no-confirmation")
    before = raw_record!(fixture.state_root)

    assert {:error, {:pilot_readmit_refused, :missing_confirmation, evidence}} = readmit(fixture, confirmation: nil)
    assert evidence.field == :confirmation

    assert raw_record!(fixture.state_root) == before
    refute File.exists?(PilotReadmit.audit_path(fixture.state_root, @issue_id))
  end

  # ── 3. active runtime refusal ───────────────────────────────────────────────

  test "a re-admission is refused while a runtime authority lease exists", %{} do
    fixture = fixture_context!("lease-held")
    before = raw_record!(fixture.state_root)

    assert {:ok, _lease} = RuntimeLease.claim(fixture.state_root)

    assert {:error, {:pilot_readmit_refused, :runtime_authority_present, evidence}} = readmit(fixture)

    assert Path.expand(evidence.authority_path) == Path.expand(RuntimeLease.authority_path(fixture.state_root))

    assert raw_record!(fixture.state_root) == before
    refute File.exists?(PilotReadmit.audit_path(fixture.state_root, @issue_id))

    # The tool never mutates the lease; release stays the operator's runbook
    # §8 action. After the documented release the same command passes.
    File.rm!(RuntimeLease.authority_path(fixture.state_root))
    assert {:ok, _receipt} = readmit(fixture)
  end

  # ── 4. stale or mismatched record refusal ───────────────────────────────────

  test "a re-admission is refused unless the expected durable record matches exactly", %{} do
    fixture = fixture_context!("mismatch")

    assert {:error, {:pilot_readmit_refused, :expected_record_mismatch, evidence}} =
             readmit(fixture, expected_attempt_count: 2)

    assert evidence.fields == ["attempt_count"]

    assert {:error, {:pilot_readmit_refused, :expected_record_mismatch, evidence}} =
             readmit(fixture, expected_last_failure_at: "2020-01-01T00:00:00.000000Z")

    assert evidence.fields == ["last_failure_at"]

    assert {:error, {:pilot_readmit_refused, :expected_record_mismatch, evidence}} =
             readmit(fixture, expected_stop_reason: "max_attempts")

    assert evidence.fields == ["stop_reason"]

    assert parsed_record!(fixture.state_root)["status"] == "parked"
  end

  test "only the single-attempt park class is eligible for re-admission", %{} do
    fixture = fixture_context!("policy-park")

    now = @last_failure_at

    policy_record =
      RetryStore.build_record(%{
        issue_id: @issue_id,
        identifier: @identifier,
        status: "parked",
        failure_class: "TRANSIENT_WORKER_FAILURE",
        attempt_count: 3,
        first_failure_at: now,
        last_failure_at: now,
        next_retry_at: nil,
        workspace_root: fixture.state_root,
        harness: :opencode,
        harness_authority: :pinned,
        harness_evidence: "dispatch:opencode_selected"
      })
      |> Map.put("stop_reason", "max_attempts")

    :ok = RetryStore.write_record(fixture.state_root, policy_record)

    assert {:error, {:pilot_readmit_refused, :park_class_not_supported, evidence}} =
             readmit(fixture, expected_attempt_count: 3, expected_stop_reason: "max_attempts")

    assert evidence.stop_reason == "max_attempts"
    assert parsed_record!(fixture.state_root)["status"] == "parked"
  end

  test "an already-readmitted issue refuses a second re-admission of the same authorization", %{} do
    fixture = fixture_context!("double")

    assert {:ok, _receipt} = readmit(fixture)
    assert {:error, {:pilot_readmit_refused, :parked_record_not_found, _evidence}} = readmit(fixture)

    assert {:ok, audit} = read_audit(fixture.state_root, @issue_id)
    assert length(audit) == 1
  end

  # ── interrupted audit/write sequence ────────────────────────────────────────

  test "an interrupted re-admission (audit written, record still parked) authorizes nothing and the operator retry is additive", %{} do
    fixture = fixture_context!("interrupted")

    # Simulate the crash between the two durable writes: the audit entry is on
    # disk, the record rewrite never happened.
    orphan = %{
      "readmission_id" => "readmit-orphan0000001",
      "issue_id" => @issue_id,
      "identifier" => @identifier,
      "authorized_at" => @last_failure_at,
      "authorization" => @confirmation,
      "previous_attempt" => %{
        "status" => "parked",
        "stop_reason" => "pilot_single_attempt",
        "attempt_count" => 1,
        "last_failure_at" => @last_failure_at,
        "launch_id" => @launch_id
      },
      "termination_receipt_path" => receipt_path(fixture.state_root, @launch_id),
      "new_status" => "readmitted"
    }

    File.mkdir_p!(Path.dirname(PilotReadmit.audit_path(fixture.state_root, @issue_id)))

    File.write!(
      PilotReadmit.audit_path(fixture.state_root, @issue_id),
      Jason.encode!(%{"schema_version" => 1, "issue_id" => @issue_id, "identifier" => @identifier, "entries" => [orphan]})
    )

    # The orphan audit authorizes nothing: the record is still parked, so the
    # armed restart rehydrates it with claim, no timer, and no dispatch.
    arm_pilot!()
    recovered = Orchestrator.recover_retry_records_for_test(fresh_state())

    try do
      assert Orchestrator.parked_for_test(recovered)[@issue_id].stop_reason == :recovered_parked
      assert MapSet.member?(recovered.claimed, @issue_id)
      assert recovered.retry_attempts == %{}
      refute Orchestrator.should_dispatch_issue_for_test(issue(), recovered)
    after
      cancel_timers(recovered)
    end

    # The operator re-runs the documented command: the durable record still
    # carries the same expected fingerprint (restart recovery never rewrote
    # it), the re-admission is admitted, and the aborted attempt's audit entry
    # is preserved ahead of the new one.
    assert {:ok, receipt} = readmit(fixture)

    assert {:ok, audit} = read_audit(fixture.state_root, @issue_id)
    assert [%{"readmission_id" => "readmit-orphan0000001"}, %{"readmission_id" => new_id}] = audit
    assert new_id == receipt.readmission_id

    assert {:ok, record} = RetryStore.read_record(fixture.state_root, @issue_id)
    assert record["status"] == "readmitted"
    assert record["readmission"]["readmission_id"] == receipt.readmission_id
  end

  # ── 5. missing or invalid termination evidence ──────────────────────────────

  test "a re-admission is refused when the consumed attempt has no valid termination receipt", %{} do
    fixture = fixture_context!("receipt-missing")
    File.rm!(receipt_path(fixture.state_root, @launch_id))
    before = raw_record!(fixture.state_root)

    assert {:error, {:pilot_readmit_refused, :termination_evidence_invalid, evidence}} = readmit(fixture)
    assert evidence.fence_verdict == :unknown
    assert raw_record!(fixture.state_root) == before
  end

  test "a re-admission is refused when the receipt does not prove the tree drained", %{} do
    fixture = fixture_context!("receipt-unproven")

    unproven = %{
      "schema_version" => 1,
      "launch_id" => @launch_id,
      "tree_drained" => false,
      "terminal_reason" => "TERMINATION_UNCONFIRMED",
      "termination_mode" => "hard",
      "child_exit_code" => 1
    }

    File.write!(receipt_path(fixture.state_root, @launch_id), Jason.encode!(unproven))
    before = raw_record!(fixture.state_root)

    assert {:error, {:pilot_readmit_refused, :termination_evidence_invalid, evidence}} = readmit(fixture)
    assert evidence.fence_verdict == :unknown
    assert raw_record!(fixture.state_root) == before
  end

  test "a receipt whose content names a different launch id cannot authorize the re-admission", %{} do
    fixture = fixture_context!("receipt-foreign-launch")

    # The receipt file exists under the stated launch id's name but records a
    # different launch: renamed, copied, or simply not this attempt's receipt.
    foreign = %{
      "schema_version" => 1,
      "launch_id" => "1791999999999-0001",
      "tree_drained" => true,
      "terminal_reason" => "NATURAL_EXIT",
      "termination_mode" => "natural_exit",
      "child_exit_code" => 0
    }

    File.write!(receipt_path(fixture.state_root, @launch_id), Jason.encode!(foreign))
    before = raw_record!(fixture.state_root)

    assert {:error, {:pilot_readmit_refused, :termination_evidence_invalid, evidence}} = readmit(fixture)
    assert evidence.launch_id == @launch_id
    assert evidence.fence_verdict == :unknown
    assert raw_record!(fixture.state_root) == before
    refute File.exists?(PilotReadmit.audit_path(fixture.state_root, @issue_id))
  end

  test "a launch id that escapes the managed receipt directory cannot smuggle unrelated evidence", %{} do
    fixture = fixture_context!("receipt-escape")

    # A drained-looking receipt placed OUTSIDE the managed worker-terminations
    # directory: the stated launch id is a path escape aiming at it.
    outside = Path.join(fixture.state_root, "outside-receipt.json")

    drained = %{
      "schema_version" => 1,
      "launch_id" => "../../outside-receipt",
      "tree_drained" => true,
      "terminal_reason" => "NATURAL_EXIT",
      "termination_mode" => "natural_exit",
      "child_exit_code" => 0
    }

    File.write!(outside, Jason.encode!(drained))
    before = raw_record!(fixture.state_root)

    assert {:error, {:pilot_readmit_refused, :termination_evidence_invalid, evidence}} =
             readmit(fixture, expected_launch_id: "../../outside-receipt")

    assert evidence.fence_verdict == :unknown
    assert raw_record!(fixture.state_root) == before
    refute File.exists?(PilotReadmit.audit_path(fixture.state_root, @issue_id))
  end

  # ── 6. unresolved fence refusal ─────────────────────────────────────────────

  test "a re-admission is refused while the launch fence is unresolved", %{} do
    fixture = fixture_context!("fence-live")

    identity =
      WorkerContainment.new_identity(
        issue_id: @issue_id,
        attempt_id: 1,
        workspace: Path.join(fixture.state_root, @identifier),
        worker_host: nil,
        authority_root: fixture.state_root
      )

    assert :ok = LaunchMarker.record(identity, root: fixture.state_root, identifier: @identifier, attempt_id: 1)
    before = raw_record!(fixture.state_root)

    # No receipt file: the marker's worker death is UNKNOWN, so the fence
    # refuses even though the other preconditions hold.
    assert {:error, {:pilot_readmit_refused, :launch_fence_unresolved, evidence}} = readmit(fixture)
    assert evidence.verdict == :worker_termination_unproven
    assert raw_record!(fixture.state_root) == before

    # Once the wrapper receipt proves the drain, the same command passes.
    File.mkdir_p!(Path.dirname(identity["receipt_path"]))

    drained = %{
      "schema_version" => 1,
      "launch_id" => identity["launch_id"],
      "tree_drained" => true,
      "terminal_reason" => "HARD_JOB_TERMINATION",
      "termination_mode" => "hard",
      "child_exit_code" => 1
    }

    File.write!(identity["receipt_path"], Jason.encode!(drained))

    assert {:ok, _receipt} = readmit(fixture, expected_launch_id: identity["launch_id"])
  end

  # ── 7. no automatic second dispatch after restart ───────────────────────────

  test "after the re-admitted attempt parks again, a restart cannot redispatch and recovery still refuses", %{} do
    fixture = fixture_context!("no-second-dispatch")
    issue = issue()

    assert {:ok, _receipt} = readmit(fixture)
    arm_pilot!()

    recovered = Orchestrator.recover_retry_records_for_test(fresh_state())

    try do
      # The new attempt runs and its failure parks the issue again.
      next = Orchestrator.handle_failure_for_test(recovered, @issue_id, running_entry(issue), "sess-2", :provider_outage)
      assert Orchestrator.parked_for_test(next)[@issue_id].stop_reason == :pilot_single_attempt

      # Restart of orchestrator #2: the re-parked issue rehydrates as parked
      # with claim and no timer, closed to the poller.
      second = Orchestrator.recover_retry_records_for_test(fresh_state())

      try do
        assert Orchestrator.parked_for_test(second)[@issue_id].stop_reason == :recovered_parked
        assert MapSet.member?(second.claimed, @issue_id)
        assert second.retry_attempts == %{}
        refute Orchestrator.should_dispatch_issue_for_test(issue, second)

        # CONTROL recover_parked still refuses the park class, exactly as it
        # did before any re-admission machinery existed.
        live = start_orchestrator()

        assert {:ok, recovery_receipt} = Control.request(:recover_parked, %{issue_id: @issue_id}, server: live)
        assert recovery_receipt.outcome == :rejected_not_fence_parked
        assert recovery_receipt.evidence.category == :unclassified

        state = :sys.get_state(live)
        assert MapSet.member?(state.claimed, @issue_id)
        assert state.retry_attempts == %{}
      after
        cancel_timers(second)
      end
    after
      cancel_timers(recovered)
    end
  end

  # ── scope: the mechanism is pilot-scoped and fails closed at recovery ───────

  test "an issue outside the armed pilot's OpenCode allowlist is not re-admissible", %{} do
    fixture = fixture_context!("not-allowed")
    before = raw_record!(fixture.state_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      opencode_enabled: true,
      opencode_provider: "mockprovider",
      opencode_model: "mock-model",
      opencode_allowed_tools: ["read"],
      opencode_allowed_issues: ["MIC-OTHER"]
    )

    assert {:error, {:pilot_readmit_refused, :pilot_issue_not_authorized, evidence}} = readmit(fixture)
    assert evidence.identifier == @identifier
    assert raw_record!(fixture.state_root) == before
  end

  test "a readmitted record with missing readmission evidence fails closed at recovery", %{} do
    fixture = fixture_context!("evidence-stripped")

    assert {:ok, _receipt} = readmit(fixture)

    {:ok, record} = RetryStore.read_record(fixture.state_root, @issue_id)
    :ok = RetryStore.write_record(fixture.state_root, Map.delete(record, "readmission"))

    arm_pilot!()
    recovered = Orchestrator.recover_retry_records_for_test(fresh_state())

    try do
      assert Orchestrator.parked_for_test(recovered) == %{}
      assert MapSet.member?(recovered.claimed, @issue_id)
      assert recovered.retry_attempts == %{}
      refute Orchestrator.should_dispatch_issue_for_test(issue(), recovered)
    after
      cancel_timers(recovered)
    end
  end

  test "a readmitted record with individually invalid readmission evidence fails closed at recovery", %{} do
    fixture = fixture_context!("evidence-invalid")

    assert {:ok, _receipt} = readmit(fixture)
    {:ok, record} = RetryStore.read_record(fixture.state_root, @issue_id)
    valid_evidence = record["readmission"]

    invalid_shapes = [
      {:blank_authorization, %{"authorization" => "   "}, "authorization"},
      {:unparseable_authorized_at, %{"authorized_at" => "yesterday-ish"}, "authorized_at"},
      {:ineligible_from_stop_reason, %{"from_stop_reason" => "max_attempts"}, "from_stop_reason"},
      {:non_positive_from_attempt_count, %{"from_attempt_count" => 0}, "from_attempt_count"}
    ]

    for {shape, patch, field} <- invalid_shapes do
      evidence = Map.merge(valid_evidence, patch)
      assert {:error, {:readmission_evidence_invalid, %{field: ^field}}} = PilotReadmit.validate_readmission_evidence(evidence)

      :ok = RetryStore.write_record(fixture.state_root, Map.put(record, "readmission", evidence))

      arm_pilot!()
      recovered = Orchestrator.recover_retry_records_for_test(fresh_state())

      try do
        assert Orchestrator.parked_for_test(recovered) == %{}, "expected fail-closed recovery for #{inspect(shape)}"
        assert MapSet.member?(recovered.claimed, @issue_id), "expected claim for #{inspect(shape)}"
        assert recovered.retry_attempts == %{}
        refute Orchestrator.should_dispatch_issue_for_test(issue(), recovered), "expected poller refusal for #{inspect(shape)}"
      after
        cancel_timers(recovered)
      end
    end
  end

  test "a readmitted record recovered outside an armed pilot fails closed", %{} do
    fixture = fixture_context!("unarmed")

    assert {:ok, _receipt} = readmit(fixture)
    refute PilotGuard.armed?()

    recovered = Orchestrator.recover_retry_records_for_test(fresh_state())

    try do
      assert Orchestrator.parked_for_test(recovered) == %{}
      assert MapSet.member?(recovered.claimed, @issue_id)
      assert Orchestrator.should_dispatch_issue_for_test(issue(), recovered) == false
    after
      cancel_timers(recovered)
    end
  end

  # ── dispatch-time promotion keeps restart safety intact ─────────────────────

  test "dispatching the re-admitted attempt promotes the durable record to active and a crash restart parks", %{} do
    fixture = fence_fixture!("promotion")
    write_parked_record!(fixture.state_root, @last_failure_at)
    write_receipt!(fixture.state_root, @launch_id)

    assert {:ok, receipt} = readmit(fixture)
    arm_pilot!()

    recovered = Orchestrator.recover_retry_records_for_test(fresh_state())
    assert Orchestrator.should_dispatch_issue_for_test(fixture.issue, recovered)

    {:ok, sup} = start_test_task_supervisor("promotion")
    state = %{recovered | task_supervisor: sup, codex_totals: codex_totals()}

    try do
      dispatched = Orchestrator.dispatch_issue_for_test(state, fixture.issue)
      assert Map.has_key?(dispatched.running, fixture.issue.id)
      wait_until(fn -> Task.Supervisor.children(sup) != [] end, 5_000)

      # The pin commit at dispatch promoted the record readmitted -> active
      # (the re-admitted attempt is now in flight); the readmission evidence
      # survives inside the record.
      assert {:ok, record} = RetryStore.read_record(fixture.state_root, fixture.issue.id)
      assert record["status"] == "active"
      assert record["readmission"]["readmission_id"] == receipt.readmission_id

      # PILOT-R3 restart safety is untouched: a restart while the re-admitted
      # attempt is in flight parks the issue instead of redispatching.
      crashed = Orchestrator.recover_retry_records_for_test(fresh_state())

      try do
        assert Orchestrator.parked_for_test(crashed)[fixture.issue.id].stop_reason == :pilot_single_attempt
        assert MapSet.member?(crashed.claimed, fixture.issue.id)
        assert crashed.retry_attempts == %{}
        refute Orchestrator.should_dispatch_issue_for_test(fixture.issue, crashed)
      after
        cancel_timers(crashed)
      end
    after
      wait_out_spawned_tasks(sup)
      cancel_timers(recovered)
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────────

  defp readmit(fixture, overrides \\ []) do
    defaults = [
      manifest: fixture.manifest_path,
      issue: @identifier,
      expected_attempt_count: 1,
      expected_stop_reason: "pilot_single_attempt",
      expected_last_failure_at: fixture.last_failure_at,
      expected_launch_id: @launch_id,
      confirmation: @confirmation
    ]

    PilotReadmit.readmit(fixture.manifest_path, Keyword.merge(defaults, overrides))
  end

  defp fresh_state, do: %Orchestrator.State{}

  defp issue do
    %Issue{
      id: @issue_id,
      identifier: @identifier,
      title: "Pilot re-admission " <> @identifier,
      description: "PILOT-R4-READMISSION",
      state: "Todo",
      url: "https://example.test/issues/" <> @identifier,
      dispatchable: true
    }
  end

  defp running_entry(issue) do
    %{
      identifier: issue.identifier,
      issue: issue,
      harness: :opencode,
      worker_host: nil,
      workspace_path: Path.join(Application.fetch_env!(:symphony_elixir, :retry_store_root), "ws-" <> issue.id),
      workspace_root: Application.fetch_env!(:symphony_elixir, :retry_store_root),
      termination_expectation: :NOT_APPLICABLE,
      retry_attempt: 0,
      started_at: DateTime.utc_now()
    }
  end

  defp arm_pilot!, do: :ok = PilotGuard.arm(workflow_path: Workflow.workflow_file_path())

  defp start_orchestrator do
    {:ok, pid} = Orchestrator.start_link(name: :"pilot-readmit-#{:erlang.unique_integer([:positive])}")

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    pid
  end

  # The durable fixture: the exact shape of a real single-attempt park
  # (opencode pin, no worker_identity, no retry timer).
  defp write_parked_record!(state_root, last_failure_at) do
    record =
      RetryStore.build_record(%{
        issue_id: @issue_id,
        identifier: @identifier,
        status: "parked",
        failure_class: "TRANSIENT_WORKER_FAILURE",
        attempt_count: 1,
        identical_failure_count: 1,
        first_failure_at: last_failure_at,
        last_failure_at: last_failure_at,
        next_retry_at: nil,
        last_error: "pilot single-attempt policy: automatic rescheduling suppressed after the first attempt",
        worker_host: "",
        worker_identity: nil,
        workspace_path: Path.join(state_root, @identifier),
        workspace_root: state_root,
        route: :primary,
        primary_failure_count: 0,
        harness: :opencode,
        harness_authority: :pinned,
        harness_evidence: "dispatch:opencode_selected"
      })
      |> Map.put("stop_reason", "pilot_single_attempt")

    :ok = RetryStore.write_record(state_root, record)
    record
  end

  defp write_receipt!(state_root, launch_id) do
    path = receipt_path(state_root, launch_id)
    File.mkdir_p!(Path.dirname(path))

    receipt = %{
      "schema_version" => 1,
      "launch_id" => launch_id,
      "tree_drained" => true,
      "terminal_reason" => "NATURAL_EXIT",
      "termination_mode" => "natural_exit",
      "child_exit_code" => 0,
      "wrapper_status" => "ok"
    }

    File.write!(path, Jason.encode!(receipt))
    path
  end

  defp receipt_path(state_root, launch_id) do
    Path.join(WorkerContainment.receipt_dir(state_root), launch_id <> ".json")
  end

  defp raw_record!(state_root) do
    path = RetryStore.record_path(state_root, @issue_id)
    assert File.regular?(path)
    File.read!(path)
  end

  defp parsed_record!(state_root) do
    assert {:ok, record} = RetryStore.read_record(state_root, @issue_id)
    record
  end

  defp read_audit(state_root, issue_id) do
    case File.read(PilotReadmit.audit_path(state_root, issue_id)) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, %{"entries" => entries}} -> {:ok, entries}
          other -> flunk("unreadable audit fixture: #{inspect(other)}")
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── the offline manifest + workflow fixture ─────────────────────────────────

  defp fixture_context!(name, workflow_overrides \\ []) do
    state_root = create_temp_fixture_root!("pilot-readmit-#{name}")

    on_exit(fn ->
      remove_temp_fixture_root!(state_root)
    end)

    previous_retry_root = Application.get_env(:symphony_elixir, :retry_store_root)
    Application.put_env(:symphony_elixir, :retry_store_root, state_root)

    on_exit(fn ->
      if is_nil(previous_retry_root) do
        Application.delete_env(:symphony_elixir, :retry_store_root)
      else
        Application.put_env(:symphony_elixir, :retry_store_root, previous_retry_root)
      end
    end)

    workflow_path = Workflow.workflow_file_path()

    write_workflow_file!(
      workflow_path,
      Keyword.merge(
        [
          tracker_kind: "memory",
          workspace_root: state_root,
          opencode_enabled: true,
          opencode_provider: "mockprovider",
          opencode_model: "mock-model",
          opencode_allowed_tools: ["read"],
          opencode_allowed_issues: [@identifier]
        ],
        workflow_overrides
      )
    )

    manifest_path = write_manifest!(state_root, workflow_path)
    write_parked_record!(state_root, @last_failure_at)
    write_receipt!(state_root, @launch_id)

    %{state_root: state_root, manifest_path: manifest_path, last_failure_at: @last_failure_at}
  end

  defp write_manifest!(state_root, workflow_path) do
    manifest_path = Path.join(state_root, "pilot-manifest.yml")

    yaml =
      Enum.map_join(
        [
          pilot_id: "pilot-readmit-test",
          pilot_root: state_root,
          source_root: state_root,
          expected_source_sha: String.duplicate("a", 40),
          workflow_path: workflow_path,
          workspace_root: state_root,
          logs_root: state_root
        ],
        "\n",
        fn {key, value} -> ~s(#{key}: "#{to_yaml_path(value)}") end
      )

    File.write!(manifest_path, yaml <> "\n")
    manifest_path
  end

  defp to_yaml_path(value) when is_binary(value), do: String.replace(value, "\\", "/")
  defp to_yaml_path(value), do: to_string(value)

  # ── dispatch fixtures (mirroring the single-attempt restart-safety suite) ───

  @fence_grace_ms 100
  @fence_hard_budget_ms 300

  defp fence_fixture!(name) do
    test_root = create_temp_fixture_root!("pilot-readmit-dispatch-#{name}")

    on_exit(fn ->
      remove_temp_fixture_root!(test_root)
    end)

    fixture = setup_source_fixture!(test_root)
    state_root = Path.join(test_root, "state")
    File.mkdir_p!(state_root)

    previous_retry_root = Application.get_env(:symphony_elixir, :retry_store_root)
    Application.put_env(:symphony_elixir, :retry_store_root, state_root)

    on_exit(fn ->
      if is_nil(previous_retry_root) do
        Application.delete_env(:symphony_elixir, :retry_store_root)
      else
        Application.put_env(:symphony_elixir, :retry_store_root, previous_retry_root)
      end
    end)

    previous_receipt_root = Application.get_env(:symphony_elixir, :worker_termination_receipt_root)
    previous_hard_budget = Application.get_env(:symphony_elixir, :worker_termination_hard_budget_ms)

    Application.put_env(:symphony_elixir, :worker_termination_receipt_root, Path.join([state_root, ".symphony-state", "receipts"]))
    Application.put_env(:symphony_elixir, :worker_termination_hard_budget_ms, @fence_hard_budget_ms)

    on_exit(fn ->
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

    issue = %Issue{
      id: @issue_id,
      identifier: @identifier,
      title: "Pilot re-admission dispatch " <> @identifier,
      state: "In Progress",
      labels: ["repo:symphony-runtime"],
      url: "https://example.test/issues/" <> @identifier,
      dispatchable: true
    }

    workflow_path = Workflow.workflow_file_path()

    write_workflow_file!(workflow_path,
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
      opencode_allowed_issues: [@identifier]
    )

    manifest_path = write_manifest!(state_root, workflow_path)

    %{
      state_root: state_root,
      manifest_path: manifest_path,
      last_failure_at: @last_failure_at,
      issue: issue
    }
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

  defp start_test_task_supervisor(suffix) do
    name = Module.concat(__MODULE__, :"ReadmitTaskSup_#{suffix}_#{System.unique_integer([:positive])}")
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

  defp wait_until(_fun, 0), do: flunk("condition was never met")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      wait_until(fun, attempts - 1)
    end
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

  defp cancel_timers(%Orchestrator.State{retry_attempts: attempts}) do
    Enum.each(attempts, fn {_id, entry} ->
      case Map.get(entry, :timer_ref) do
        ref when is_reference(ref) -> Process.cancel_timer(ref)
        _other -> :ok
      end
    end)
  end
end
