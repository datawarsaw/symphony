defmodule SymphonyElixir.SteerControlTest do
  use SymphonyElixir.TestSupport

  @moduledoc """
  MIC-10 STEER != CONTROL on current main, repaired against the accepted
  MIC-223 worker-containment contract.

  Core invariant under regression here:

  ```
  NO WORKSPACE REUSE UNTIL TERMINATED_CONFIRMED
  ```

  for any attempt that may have created a managed contained worker. BEAM task
  death is not confirmation; receipt existence without a valid confirmation
  under the attempt's predeclared termination expectation is not confirmation;
  unknown or malformed evidence fails closed. `:current` resolves the current
  attempt and binds evidence to that attempt only — an older attempt's
  successful receipt never authorizes a newer attempt's relaunch. STEER text
  (durable steering inbox) never authorizes CONTROL.
  """

  alias SymphonyElixir.Control
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Steering
  alias SymphonyElixir.Tracker.Issue, as: IssueStruct
  alias SymphonyElixir.WorkerContainment

  @evidence_budget 200

  # ---------------------------------------------------------------------------
  # Control surface
  # ---------------------------------------------------------------------------

  test "control surface: recognized verbs, executable verbs, fail-closed shape validation" do
    assert Control.supported_actions() == [:interrupt, :relaunch, :terminate]
    assert Control.executable_actions() == [:relaunch, :terminate]

    assert {:error, {:invalid_request, :malformed_request}} = Control.request(:terminate, "not-a-map")
    assert {:error, {:invalid_request, :issue_id_must_not_be_empty}} = Control.request(:terminate, %{issue_id: "  "})

    assert {:error, {:invalid_request, :attempt_id_must_be_non_negative_integer_or_current}} =
             Control.request(:terminate, %{issue_id: "issue-x", attempt_id: -1})

    assert {:error, {:invalid_request, {:unsupported_action, :deploy}}} = Control.request(:deploy, %{issue_id: "issue-x"})
  end

  test "interrupt is recorded and rejected fail-closed, never mapped onto terminate" do
    pid = start_orchestrator(__MODULE__.InterruptOrch)

    assert {:ok, receipt} = Control.request(:interrupt, %{issue_id: "issue-int"}, server: pid)
    assert receipt.outcome == :rejected_interrupt_not_supported
    assert receipt.attempt_id == nil

    assert [%{action: :interrupt, outcome: :rejected_interrupt_not_supported}] = Control.receipts(pid)
  end

  # ---------------------------------------------------------------------------
  # TERMINATE: stop + operator hold + async MIC-223 finalization
  # ---------------------------------------------------------------------------

  test "terminate stops the worker and holds the issue without auto-retry; NOT_APPLICABLE finalizes :terminated" do
    pid = start_orchestrator(__MODULE__.TerminateOrch)
    issue_id = "issue-na"

    worker =
      inject_running(pid, issue_id, identifier: "NA-1", termination_expectation: :NOT_APPLICABLE, worker_identity: nil, retry_attempt: 0)

    assert {:ok, receipt} = Control.request(:terminate, %{issue_id: issue_id}, server: pid)
    assert receipt.outcome == :termination_pending
    assert receipt.attempt_id == 0
    refute Process.alive?(worker)

    finalized = await_finalized(pid, receipt.control_id)
    assert finalized.outcome == :terminated
    assert finalized.evidence.reuse_gate == :allowed
    assert finalized.evidence.worker_termination == nil

    state = :sys.get_state(pid)
    assert state.running == %{}
    assert MapSet.member?(state.claimed, issue_id)
    assert %{retry_attempt: 0} = state.blocked[issue_id]
    assert state.retry_attempts == %{}
  end

  test "terminate with a stale explicit attempt is rejected without stopping the worker" do
    pid = start_orchestrator(__MODULE__.StaleTerminateOrch)

    worker =
      inject_running(pid, "issue-stale", identifier: "ST-1", termination_expectation: :NOT_APPLICABLE, worker_identity: nil, retry_attempt: 0)

    assert {:ok, receipt} = Control.request(:terminate, %{issue_id: "issue-stale", attempt_id: 1}, server: pid)
    assert receipt.outcome == :rejected_stale_attempt
    wait_until(fn -> Process.alive?(worker) end)

    state = :sys.get_state(pid)
    assert Map.has_key?(state.running, "issue-stale")
    assert state.blocked == %{}
  end

  # ---------------------------------------------------------------------------
  # F1: relaunch is gated on the attempt's MIC-223 termination evidence
  # ---------------------------------------------------------------------------

  test "F1: managed attempt with BEAM task dead but OS termination unconfirmed denies relaunch" do
    pid = start_orchestrator(__MODULE__.F1UnconfirmedOrch)
    issue_id = "issue-f1"

    in_receipt_root(fn _receipts ->
      identity = new_managed_identity(issue_id)
      worker = inject_running(pid, issue_id, identifier: "F1-1", termination_expectation: :MANAGED_CONFIRMATION_REQUIRED, worker_identity: identity, retry_attempt: 0)

      assert {:ok, terminate_receipt} = Control.request(:terminate, %{issue_id: issue_id}, server: pid)
      # The BEAM task is dead — and that alone must not confirm anything.
      wait_until(fn -> not Process.alive?(worker) end)

      finalized = await_finalized(pid, terminate_receipt.control_id)
      assert finalized.outcome == :termination_unconfirmed
      assert finalized.evidence.reuse_gate == {:blocked, :worker_termination_unconfirmed}

      assert {:ok, relaunch_receipt} = Control.request(:relaunch, %{issue_id: issue_id, attempt_id: :current}, server: pid)
      assert relaunch_receipt.outcome == :rejected_no_terminated_attempt
      assert relaunch_receipt.evidence.reason == :termination_unconfirmed

      state = :sys.get_state(pid)
      assert MapSet.member?(state.claimed, issue_id)
      assert Map.has_key?(state.blocked, issue_id)
      assert state.retry_attempts == %{}
    end)
  end

  test "F1: managed attempt with receipt-backed TERMINATED_CONFIRMED passes fence and reuse_gate; relaunch schedules the existing retry envelope" do
    pid = start_orchestrator(__MODULE__.F1ConfirmedOrch)
    issue_id = "issue-f1-ok"

    in_receipt_root(fn _receipts ->
      identity = new_managed_identity(issue_id)
      write_receipt(identity, %{"tree_drained" => true, "terminal_reason" => "NATURAL_EXIT", "termination_mode" => "cooperative", "child_exit_code" => 0})

      inject_running(pid, issue_id, identifier: "F1-OK", termination_expectation: :MANAGED_CONFIRMATION_REQUIRED, worker_identity: identity, retry_attempt: 0)

      assert {:ok, terminate_receipt} = Control.request(:terminate, %{issue_id: issue_id}, server: pid)
      finalized = await_finalized(pid, terminate_receipt.control_id)
      assert finalized.outcome == :terminated
      assert finalized.evidence.worker_termination.status == :TERMINATED_CONFIRMED
      assert finalized.evidence.reuse_gate == :allowed

      assert {:ok, relaunch_receipt} = Control.request(:relaunch, %{issue_id: issue_id, attempt_id: :current}, server: pid)
      assert relaunch_receipt.outcome == :relaunch_scheduled
      assert relaunch_receipt.attempt_id == 0
      assert relaunch_receipt.evidence.replacement_retry_attempt == 1
      assert relaunch_receipt.evidence.prior_terminate_control_id == terminate_receipt.control_id

      state = :sys.get_state(pid)
      assert %{attempt: 1} = state.retry_attempts[issue_id]
      assert state.blocked == %{}
      refute MapSet.member?(state.claimed, issue_id)

      # Idempotent bound: a second relaunch collapses on the scheduled retry.
      assert {:ok, again} = Control.request(:relaunch, %{issue_id: issue_id}, server: pid)
      assert again.outcome == :already_scheduled
    end)
  end

  test "F1 ladder: managed WorkerFence :unknown denies relaunch even when the ledger receipt claims confirmed" do
    pid = start_orchestrator(__MODULE__.FenceUnknownOrch)
    issue_id = "issue-fence-unknown"

    in_receipt_root(fn _receipts ->
      identity = new_managed_identity(issue_id)

      inject_blocked(pid, issue_id, identifier: "FU-1", retry_attempt: 0)

      inject_ledger(pid, [
        control_receipt(
          action: :terminate,
          issue_id: issue_id,
          attempt_id: 0,
          outcome: :terminated,
          evidence: %{
            termination_expectation: :MANAGED_CONFIRMATION_REQUIRED,
            worker_identity: identity,
            # A confirmed-looking summary whose backing receipt cannot be
            # verified (missing file) — the relaunch fence must still deny.
            worker_termination: %{status: :TERMINATED_CONFIRMED, exit_code: 0, reason: "NATURAL_EXIT"}
          }
        )
      ])

      assert {:ok, relaunch_receipt} = Control.request(:relaunch, %{issue_id: issue_id}, server: pid)
      assert relaunch_receipt.outcome == :rejected_no_terminated_attempt
      assert relaunch_receipt.evidence.reason == :worker_fence_unknown

      state = :sys.get_state(pid)
      assert MapSet.member?(state.claimed, issue_id)
      assert state.retry_attempts == %{}
    end)
  end

  # ---------------------------------------------------------------------------
  # F2: `:current` binds evidence to the current attempt only
  # ---------------------------------------------------------------------------

  test "F2: older attempt confirmed, newer current attempt without evidence — :current relaunch denied" do
    pid = start_orchestrator(__MODULE__.F2MissingOrch)
    issue_id = "issue-f2-missing"

    inject_blocked(pid, issue_id, identifier: "F2-1", retry_attempt: 1)

    inject_ledger(pid, [
      control_receipt(
        action: :terminate,
        issue_id: issue_id,
        attempt_id: 0,
        outcome: :terminated,
        evidence: %{termination_expectation: :NOT_APPLICABLE, worker_termination: nil, reuse_gate: :allowed}
      )
    ])

    assert {:ok, relaunch_receipt} = Control.request(:relaunch, %{issue_id: issue_id, attempt_id: :current}, server: pid)
    assert relaunch_receipt.outcome == :rejected_no_terminated_attempt
    assert relaunch_receipt.evidence.current_attempt_id == 1

    # The older attempt cannot be explicitly resurrected either.
    assert {:ok, stale} = Control.request(:relaunch, %{issue_id: issue_id, attempt_id: 0}, server: pid)
    assert stale.outcome == :rejected_stale_attempt
    assert stale.evidence.current_attempt_id == 1

    state = :sys.get_state(pid)
    assert state.retry_attempts == %{}
    assert MapSet.member?(state.claimed, issue_id)
  end

  test "F2: current attempt TERMINATION_UNCONFIRMED denies relaunch even though an older attempt is confirmed" do
    pid = start_orchestrator(__MODULE__.F2UnconfirmedOrch)
    issue_id = "issue-f2-unconfirmed"

    inject_blocked(pid, issue_id, identifier: "F2-2", retry_attempt: 1)

    inject_ledger(pid, [
      control_receipt(
        action: :terminate,
        issue_id: issue_id,
        attempt_id: 1,
        outcome: :termination_unconfirmed,
        evidence: %{termination_expectation: :MANAGED_CONFIRMATION_REQUIRED, worker_termination: %{status: :TERMINATION_UNCONFIRMED, exit_code: nil, reason: :control_termination_evidence_timeout}}
      ),
      control_receipt(
        action: :terminate,
        issue_id: issue_id,
        attempt_id: 0,
        outcome: :terminated,
        evidence: %{termination_expectation: :NOT_APPLICABLE, worker_termination: nil, reuse_gate: :allowed}
      )
    ])

    assert {:ok, relaunch_receipt} = Control.request(:relaunch, %{issue_id: issue_id, attempt_id: :current}, server: pid)
    assert relaunch_receipt.outcome == :rejected_no_terminated_attempt
    assert relaunch_receipt.evidence.reason == :termination_unconfirmed
    assert relaunch_receipt.evidence.prior_outcome == :termination_unconfirmed
    assert relaunch_receipt.evidence.current_attempt_id == 1

    # Explicitly naming the unconfirmed current attempt denies identically.
    assert {:ok, explicit} = Control.request(:relaunch, %{issue_id: issue_id, attempt_id: 1}, server: pid)
    assert explicit.outcome == :rejected_no_terminated_attempt
    assert explicit.evidence.reason == :termination_unconfirmed
  end

  test "receipt bound to another attempt never authorizes the current attempt" do
    pid = start_orchestrator(__MODULE__.CrossAttemptOrch)
    issue_id = "issue-cross"

    inject_blocked(pid, issue_id, identifier: "XA-1", retry_attempt: 2)

    inject_ledger(pid, [
      control_receipt(
        action: :terminate,
        issue_id: "issue-other",
        attempt_id: 2,
        outcome: :terminated,
        evidence: %{termination_expectation: :NOT_APPLICABLE, worker_termination: nil, reuse_gate: :allowed}
      ),
      control_receipt(action: :terminate, issue_id: issue_id, attempt_id: 1, outcome: :terminated, evidence: %{termination_expectation: :NOT_APPLICABLE})
    ])

    assert {:ok, relaunch_receipt} = Control.request(:relaunch, %{issue_id: issue_id}, server: pid)
    assert relaunch_receipt.outcome == :rejected_no_terminated_attempt
    assert relaunch_receipt.evidence.current_attempt_id == 2
  end

  # ---------------------------------------------------------------------------
  # Accepted MIC-223 expectation semantics preserved end to end
  # ---------------------------------------------------------------------------

  test "NEVER_STARTED expectation keeps accepted MIC-223 semantics end to end" do
    pid = start_orchestrator(__MODULE__.NeverStartedOrch)
    issue_id = "issue-never-started"

    inject_running(pid, issue_id, identifier: "NS-1", termination_expectation: :NEVER_STARTED, worker_identity: nil, retry_attempt: 0)

    assert {:ok, terminate_receipt} = Control.request(:terminate, %{issue_id: issue_id}, server: pid)
    finalized = await_finalized(pid, terminate_receipt.control_id)
    assert finalized.outcome == :terminated
    assert finalized.evidence.worker_termination == nil
    assert finalized.evidence.reuse_gate == :allowed

    assert {:ok, relaunch_receipt} = Control.request(:relaunch, %{issue_id: issue_id, attempt_id: :current}, server: pid)
    assert relaunch_receipt.outcome == :relaunch_scheduled
  end

  test "NOT_APPLICABLE / remote expectation keeps accepted legacy semantics end to end" do
    pid = start_orchestrator(__MODULE__.NotApplicableOrch)
    issue_id = "issue-remote"

    inject_running(pid, issue_id, identifier: "RM-1", termination_expectation: :NOT_APPLICABLE, worker_identity: nil, worker_host: "some-remote-host", retry_attempt: 0)

    assert {:ok, terminate_receipt} = Control.request(:terminate, %{issue_id: issue_id}, server: pid)
    finalized = await_finalized(pid, terminate_receipt.control_id)
    assert finalized.outcome == :terminated

    assert {:ok, relaunch_receipt} = Control.request(:relaunch, %{issue_id: issue_id, attempt_id: :current}, server: pid)
    assert relaunch_receipt.outcome == :relaunch_scheduled
    assert relaunch_receipt.evidence.replacement_retry_attempt == 1
  end

  # ---------------------------------------------------------------------------
  # Fail-closed evidence
  # ---------------------------------------------------------------------------

  test "malformed termination evidence fails closed" do
    pid = start_orchestrator(__MODULE__.MalformedOrch)
    issue_id = "issue-malformed"

    in_receipt_root(fn _receipts ->
      identity = new_managed_identity(issue_id)
      File.mkdir_p!(Path.dirname(identity["receipt_path"]))

      # Structurally broken JSON: the parser must reject it, never read it as
      # evidence of death.
      File.write!(identity["receipt_path"], "{definitely not json")

      inject_running(pid, issue_id, identifier: "MF-1", termination_expectation: :MANAGED_CONFIRMATION_REQUIRED, worker_identity: identity, retry_attempt: 0)

      assert {:ok, terminate_receipt} = Control.request(:terminate, %{issue_id: issue_id}, server: pid)
      finalized = await_finalized(pid, terminate_receipt.control_id)
      assert finalized.outcome == :termination_unconfirmed

      assert {:ok, relaunch_receipt} = Control.request(:relaunch, %{issue_id: issue_id}, server: pid)
      assert relaunch_receipt.outcome == :rejected_no_terminated_attempt
      assert relaunch_receipt.evidence.reason == :termination_unconfirmed
    end)
  end

  test "structurally invalid but well-formed receipt fails closed" do
    pid = start_orchestrator(__MODULE__.InvalidShapeOrch)
    issue_id = "issue-invalid-shape"

    in_receipt_root(fn _receipts ->
      identity = new_managed_identity(issue_id)

      # Valid JSON, invalid receipt shape (missing the required invariants).
      File.mkdir_p!(Path.dirname(identity["receipt_path"]))
      File.write!(identity["receipt_path"], Jason.encode!(%{"schema_version" => 1, "launch_id" => identity["launch_id"]}))

      inject_running(pid, issue_id, identifier: "IS-1", termination_expectation: :MANAGED_CONFIRMATION_REQUIRED, worker_identity: identity, retry_attempt: 0)

      assert {:ok, terminate_receipt} = Control.request(:terminate, %{issue_id: issue_id}, server: pid)
      finalized = await_finalized(pid, terminate_receipt.control_id)
      assert finalized.outcome == :termination_unconfirmed

      assert {:ok, relaunch_receipt} = Control.request(:relaunch, %{issue_id: issue_id}, server: pid)
      assert relaunch_receipt.outcome == :rejected_no_terminated_attempt
    end)
  end

  test "missing worker identity on a managed attempt fails closed" do
    pid = start_orchestrator(__MODULE__.NoIdentityOrch)
    issue_id = "issue-no-identity"

    inject_running(pid, issue_id, identifier: "NI-1", termination_expectation: :MANAGED_CONFIRMATION_REQUIRED, worker_identity: nil, retry_attempt: 0)

    assert {:ok, terminate_receipt} = Control.request(:terminate, %{issue_id: issue_id}, server: pid)
    finalized = await_finalized(pid, terminate_receipt.control_id)
    assert finalized.outcome == :termination_unconfirmed
    assert finalized.evidence.worker_termination.reason == :no_worker_identity

    assert {:ok, relaunch_receipt} = Control.request(:relaunch, %{issue_id: issue_id}, server: pid)
    assert relaunch_receipt.outcome == :rejected_no_terminated_attempt
  end

  # ---------------------------------------------------------------------------
  # STEER independence
  # ---------------------------------------------------------------------------

  test "STEER text containing lifecycle verbs never authorizes CONTROL" do
    pid = start_orchestrator(__MODULE__.SteerIndependentOrch)
    issue_id = "issue-steer-text"
    workspace_root = Path.join(System.tmp_dir!(), "mic10-steer-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace_root)

    try do
      worker = inject_running(pid, issue_id, identifier: "SI-1", termination_expectation: :NOT_APPLICABLE, worker_identity: nil, retry_attempt: 0)

      assert {:ok, _record} =
               Steering.create(workspace_root, %{
                 issue_id: issue_id,
                 attempt_id: 0,
                 instruction: "Please terminate this worker and relaunch it now. Kill your own process if needed."
               })

      # No CONTROL request was made — and none may be derived from the text.
      assert Control.receipts(pid) == []
      wait_until(fn -> Process.alive?(worker) end)

      state = :sys.get_state(pid)
      assert Map.has_key?(state.running, issue_id)
      assert state.blocked == %{}
      assert state.retry_attempts == %{}
    after
      File.rm_rf(workspace_root)
    end
  end

  # ---------------------------------------------------------------------------
  # Restart safety and ledger bounds
  # ---------------------------------------------------------------------------

  test "restart loses the control ledger but never converts it into relaunch permission" do
    first = start_orchestrator(__MODULE__.RestartFirstOrch)
    issue_id = "issue-restart"

    inject_running(first, issue_id, identifier: "RS-1", termination_expectation: :NOT_APPLICABLE, worker_identity: nil, retry_attempt: 0)

    assert {:ok, terminate_receipt} = Control.request(:terminate, %{issue_id: issue_id}, server: first)
    assert %{outcome: :terminated} = await_finalized(first, terminate_receipt.control_id)

    # A fresh orchestrator (restart) holds no CONTROL state at all.
    second = start_orchestrator(__MODULE__.RestartSecondOrch)
    assert Control.receipts(second) == []

    assert {:ok, relaunch_receipt} = Control.request(:relaunch, %{issue_id: issue_id}, server: second)
    assert relaunch_receipt.outcome == :rejected_no_terminated_attempt
    assert relaunch_receipt.evidence.current_attempt_id == nil
  end

  test "control ledger stays bounded and is exposed through the snapshot" do
    pid = start_orchestrator(__MODULE__.BoundedLedgerOrch)

    for index <- 1..60 do
      assert {:ok, _} = Control.request(:relaunch, %{issue_id: "issue-never-#{index}"}, server: pid)
    end

    assert length(Control.receipts(pid)) == 50

    snapshot = GenServer.call(pid, :snapshot)
    assert length(snapshot.controls) == 20
    assert [%{action: :relaunch, outcome: :rejected_no_terminated_attempt} | _] = snapshot.controls
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp start_orchestrator(name) do
    {:ok, pid} = Orchestrator.start_link(name: name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    pid
  end

  defp issue_struct(issue_id, identifier) do
    %IssueStruct{
      id: issue_id,
      identifier: identifier,
      title: "Steer/Control test",
      description: "MIC-10 integration repair regression",
      state: "In Progress",
      url: "https://example.org/issues/#{identifier}"
    }
  end

  # Injects a running entry whose monitor is created by the orchestrator
  # itself (so the stop path's demonitor is legal) and returns the worker pid.
  defp inject_running(pid, issue_id, overrides) do
    worker = spawn(fn -> Process.sleep(:infinity) end)
    identifier = overrides[:identifier] || issue_id

    entry =
      Map.merge(
        %{
          pid: worker,
          ref: nil,
          identifier: identifier,
          issue: issue_struct(issue_id, identifier),
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

  defp inject_blocked(pid, issue_id, overrides) do
    identifier = overrides[:identifier] || issue_id

    blocked_entry =
      Map.merge(
        %{
          issue_id: issue_id,
          identifier: identifier,
          issue: issue_struct(issue_id, identifier),
          worker_host: nil,
          workspace_path: nil,
          workspace_root: nil,
          retry_attempt: 0,
          session_id: nil,
          error: "injected for test",
          discovery_result: nil,
          blocked_at: DateTime.utc_now(),
          last_codex_message: nil,
          last_codex_event: nil,
          last_codex_timestamp: nil
        },
        Map.new(overrides)
      )

    :sys.replace_state(pid, fn state ->
      %{state | blocked: Map.put(state.blocked, issue_id, blocked_entry), claimed: MapSet.put(state.claimed, issue_id)}
    end)

    :ok
  end

  defp inject_ledger(pid, receipts) do
    :sys.replace_state(pid, fn state -> %{state | control_ledger: receipts} end)
    :ok
  end

  defp control_receipt(fields) do
    now = DateTime.utc_now()

    %{
      control_id: fields[:control_id] || "ctl-injected-#{System.unique_integer([:positive])}",
      action: Keyword.fetch!(fields, :action),
      issue_id: Keyword.fetch!(fields, :issue_id),
      attempt_id: fields[:attempt_id],
      requested_at: now,
      requested_by: :host_operator,
      completed_at: now,
      outcome: Keyword.fetch!(fields, :outcome),
      evidence: Keyword.fetch!(fields, :evidence)
    }
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

  defp in_receipt_root(fun) do
    receipts = Path.join(System.tmp_dir!(), "mic10-control-receipts-#{System.unique_integer([:positive])}")
    File.mkdir_p!(receipts)
    Application.put_env(:symphony_elixir, :worker_termination_receipt_root, receipts)
    Application.put_env(:symphony_elixir, :control_termination_evidence_budget_ms, @evidence_budget)

    try do
      fun.(receipts)
    after
      Application.delete_env(:symphony_elixir, :worker_termination_receipt_root)
      Application.delete_env(:symphony_elixir, :control_termination_evidence_budget_ms)
      File.rm_rf(receipts)
    end
  end

  defp new_managed_identity(issue_id) do
    WorkerContainment.new_identity(
      issue_id: issue_id,
      attempt_id: 0,
      workspace: "C:/tmp/mic10-control-test-workspace",
      worker_host: nil
    )
  end

  defp write_receipt(identity, overrides) do
    receipt =
      Map.merge(
        %{
          "schema_version" => 1,
          "launch_id" => identity["launch_id"],
          "tree_drained" => false,
          "terminal_reason" => "UNKNOWN",
          "termination_mode" => "none",
          "root_pid" => nil,
          "root_creation_time" => nil,
          "child_exit_code" => nil
        },
        Map.new(overrides, fn {key, value} -> {key, value} end)
      )

    File.mkdir_p!(Path.dirname(identity["receipt_path"]))
    File.write!(identity["receipt_path"], Jason.encode!(receipt))
    :ok
  end
end
