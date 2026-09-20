defmodule SymphonyElixir.ParkedRecoveryTest do
  use SymphonyElixir.TestSupport

  @moduledoc """
  PARKED recovery + operator unblock path (`Control.request(:recover_parked, ...)`).

  Central invariant: parking stays fail-closed, and the recovery command may
  release a parked issue only after the fence — re-run against the durable
  worker evidence as it exists NOW — positively proves the previous worker tree
  drained. UNKNOWN, LIVE, corrupt evidence, and policy parks are refused; no
  elapsed-time assumption ever substitutes for positive evidence.
  """

  alias SymphonyElixir.Control
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.RetryStore
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.WorkerContainment

  setup do
    workflow_file =
      Path.join(System.tmp_dir!(), "parked-recovery-workflow-#{:erlang.unique_integer([:positive])}.md")

    write_workflow_file!(workflow_file,
      tracker_kind: "memory",
      poll_interval_ms: 3_600_000
    )

    Workflow.set_workflow_file_path(workflow_file)
    on_exit(fn -> File.rm_rf(workflow_file) end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Refusals: fence UNKNOWN, LIVE, corrupt evidence
  # ---------------------------------------------------------------------------

  test "fence UNKNOWN refuses recovery and preserves park, claim, record, and workspace" do
    receipts = receipt_dir()
    pid = start_orchestrator()
    issue_id = "issue-fence-unknown"

    inject_parked(pid, issue_id,
      worker_identity: identity("launch-unknown"),
      workspace_path: workspace_fixture("fence-unknown-ws")
    )

    park_record(issue_id, worker_identity: identity("launch-unknown"))

    assert {:ok, receipt} = Control.request(:recover_parked, %{issue_id: issue_id}, server: pid)
    assert receipt.outcome == :rejected_fence_unknown
    assert receipt.evidence.fence_verdict == :unknown
    assert receipt.evidence.worker_identity_present == true

    # Fail closed: nothing moved.
    state = :sys.get_state(pid)
    assert Map.has_key?(state.parked, issue_id)
    assert MapSet.member?(state.claimed, issue_id)
    assert state.retry_attempts == %{}
    assert {:ok, record} = RetryStore.read_record(retry_root(), issue_id)
    assert record["status"] == "parked"
    assert File.exists?(Path.join(receipts, "launch-unknown.json")) == false
  end

  test "late receipt unlocks recovery: refused before, released after positive proof" do
    _receipts = receipt_dir()
    pid = start_orchestrator()
    issue_id = "issue-late-receipt"

    identity = identity("launch-late")
    inject_parked(pid, issue_id, worker_identity: identity)
    park_record(issue_id, worker_identity: identity)
    set_tracker_issues([tracker_issue(issue_id)])

    # The receipt has not appeared yet: refused.
    assert {:ok, %{outcome: :rejected_fence_unknown}} =
             Control.request(:recover_parked, %{issue_id: issue_id}, server: pid)

    # The wrapper's receipt appears later — the evidence that was missing at
    # park time now positively proves the tree drained.
    write_receipt("launch-late")

    assert {:ok, receipt} = Control.request(:recover_parked, %{issue_id: issue_id}, server: pid)
    assert receipt.outcome == :recovery_scheduled
    assert receipt.evidence.fence_verdict == :dead
    assert receipt.evidence.park_stop_reason == "worker_termination_unconfirmed"
    assert receipt.evidence.worker_launch_id == "launch-late"
    assert receipt.attempt_id == 1

    state = :sys.get_state(pid)
    refute Map.has_key?(state.parked, issue_id)
    # Exactly one replacement attempt on the existing envelope; the claim is
    # held by the retry entry so the poller cannot race a second dispatch.
    assert map_size(state.retry_attempts) == 1
    retry = Map.fetch!(state.retry_attempts, issue_id)
    assert retry.attempt == 2
    assert MapSet.member?(state.claimed, issue_id)

    # The durable record transitioned parked -> retrying with the recovery
    # audit trail; the receipt file itself is preserved as evidence.
    assert {:ok, record} = RetryStore.read_record(retry_root(), issue_id)
    assert record["status"] == "retrying"
    assert record["last_error"] =~ "recovered from PARKED by operator control"
    assert record["last_error"] =~ receipt.control_id
    assert File.exists?(identity["receipt_path"])
  end

  test "still-running worker (receipt present, tree not drained) refuses and touches nothing" do
    _receipts = receipt_dir()
    pid = start_orchestrator()
    issue_id = "issue-still-live"

    workspace = workspace_fixture("still-live-ws")
    identity = identity("launch-live")

    inject_parked(pid, issue_id, worker_identity: identity, workspace_path: workspace)
    park_record(issue_id, worker_identity: identity)

    # The wrapper wrote a receipt, but it does not prove the tree drained.
    write_receipt("launch-live", %{"tree_drained" => false, "terminal_reason" => "ROOT_EXITED"})

    assert {:ok, receipt} = Control.request(:recover_parked, %{issue_id: issue_id}, server: pid)
    assert receipt.outcome == :rejected_fence_unknown

    state = :sys.get_state(pid)
    assert Map.has_key?(state.parked, issue_id)
    assert MapSet.member?(state.claimed, issue_id)
    assert state.retry_attempts == %{}
    assert File.read!(Path.join(workspace, "sentinel.txt")) == "in-progress work\n"
    assert {:ok, record} = RetryStore.read_record(retry_root(), issue_id)
    assert record["status"] == "parked"
  end

  test "receipt bound to a different launch id refuses" do
    _receipts = receipt_dir()
    pid = start_orchestrator()
    issue_id = "issue-wrong-launch"

    inject_parked(pid, issue_id, worker_identity: identity("launch-mine"))
    park_record(issue_id, worker_identity: identity("launch-mine"))
    write_receipt("launch-theirs")

    assert {:ok, receipt} = Control.request(:recover_parked, %{issue_id: issue_id}, server: pid)
    assert receipt.outcome == :rejected_fence_unknown
    assert Map.has_key?(:sys.get_state(pid).parked, issue_id)
  end

  test "malformed receipt refuses" do
    receipts = receipt_dir()
    pid = start_orchestrator()
    issue_id = "issue-malformed-receipt"

    inject_parked(pid, issue_id, worker_identity: identity("launch-broken"))
    park_record(issue_id, worker_identity: identity("launch-broken"))
    File.write!(Path.join(receipts, "launch-broken.json"), "not json {{{")

    assert {:ok, receipt} = Control.request(:recover_parked, %{issue_id: issue_id}, server: pid)
    assert receipt.outcome == :rejected_fence_unknown
    assert Map.has_key?(:sys.get_state(pid).parked, issue_id)
    assert MapSet.member?(:sys.get_state(pid).claimed, issue_id)
  end

  test "missing worker identity refuses: absence of identity is never evidence of death" do
    _receipts = receipt_dir()
    pid = start_orchestrator()
    issue_id = "issue-no-identity"

    inject_parked(pid, issue_id, worker_identity: nil)

    # A legacy record without any worker identity.
    record = park_record(issue_id, worker_identity: nil)
    :ok = RetryStore.write_record(retry_root(), Map.delete(record, "worker_identity"))

    assert {:ok, receipt} = Control.request(:recover_parked, %{issue_id: issue_id}, server: pid)
    assert receipt.outcome == :rejected_fence_unknown
    assert receipt.evidence.worker_identity_present == false
    assert Map.has_key?(:sys.get_state(pid).parked, issue_id)
  end

  test "corrupt retry record refuses and deletes nothing" do
    pid = start_orchestrator()
    issue_id = "issue-corrupt-record"

    inject_parked(pid, issue_id)
    park_record(issue_id)
    File.write!(RetryStore.record_path(retry_root(), issue_id), "corrupt {{{")

    assert {:ok, receipt} = Control.request(:recover_parked, %{issue_id: issue_id}, server: pid)
    assert receipt.outcome == :rejected_corrupt_evidence

    state = :sys.get_state(pid)
    assert Map.has_key?(state.parked, issue_id)
    assert MapSet.member?(state.claimed, issue_id)
    assert state.retry_attempts == %{}
    # No automatic repair: the corrupt evidence is left exactly as found.
    assert File.read!(RetryStore.record_path(retry_root(), issue_id)) == "corrupt {{{"
  end

  test "missing retry record refuses: the evidence that caused the park must survive recovery" do
    pid = start_orchestrator()
    issue_id = "issue-no-record"

    inject_parked(pid, issue_id)

    assert {:ok, receipt} = Control.request(:recover_parked, %{issue_id: issue_id}, server: pid)
    assert receipt.outcome == :rejected_corrupt_evidence
    assert receipt.evidence.reason == :retry_record_missing
    assert Map.has_key?(:sys.get_state(pid).parked, issue_id)
  end

  test "retrying record with an in-memory fence park re-proves death from fresh evidence" do
    _receipts = receipt_dir()
    pid = start_orchestrator()
    issue_id = "issue-fence-alive"

    # :fence_alive parks rehydrate from a record that is still "retrying"; the
    # recovery classification must work from the in-memory fence reason.
    identity = identity("launch-fence-alive")
    inject_parked(pid, issue_id, stop_reason: :fence_alive, worker_identity: identity)
    park_record(issue_id, status: "retrying", stop_reason: nil, worker_identity: identity)
    set_tracker_issues([tracker_issue(issue_id)])

    assert {:ok, %{outcome: :rejected_fence_unknown}} =
             Control.request(:recover_parked, %{issue_id: issue_id}, server: pid)

    write_receipt("launch-fence-alive")

    assert {:ok, receipt} = Control.request(:recover_parked, %{issue_id: issue_id}, server: pid)
    assert receipt.outcome == :recovery_scheduled
    assert receipt.evidence.park_stop_reason == "fence_alive"
    assert map_size(:sys.get_state(pid).retry_attempts) == 1
  end

  # ---------------------------------------------------------------------------
  # Policy parks stay policy parks
  # ---------------------------------------------------------------------------

  test "policy parks are not silently unparked: a different operator action is required" do
    pid = start_orchestrator()
    issue_id = "issue-policy-park"

    inject_parked(pid, issue_id, stop_reason: :max_attempts, failure_class: "PROVIDER_OUTAGE")
    park_record(issue_id, stop_reason: "max_attempts")

    assert {:ok, receipt} = Control.request(:recover_parked, %{issue_id: issue_id}, server: pid)
    assert receipt.outcome == :rejected_not_fence_parked
    assert receipt.evidence.category == :policy_park
    assert receipt.evidence.park_stop_reason == "max_attempts"
    assert receipt.evidence.operator_action_required == :different_recovery_path

    state = :sys.get_state(pid)
    assert Map.has_key?(state.parked, issue_id)
    assert MapSet.member?(state.claimed, issue_id)
    assert state.retry_attempts == %{}
    assert {:ok, record} = RetryStore.read_record(retry_root(), issue_id)
    assert record["status"] == "parked"
  end

  test "legacy parked record without a durable stop reason requires a manual decision" do
    pid = start_orchestrator()
    issue_id = "issue-legacy-park"

    # After a restart the in-memory reason is :recovered_parked and a legacy
    # record carries no stop_reason, so the park cannot be objectively
    # classified: refuse instead of guessing.
    inject_parked(pid, issue_id, stop_reason: :recovered_parked)
    record = park_record(issue_id, stop_reason: nil)
    :ok = RetryStore.write_record(retry_root(), Map.delete(record, "stop_reason"))

    assert {:ok, receipt} = Control.request(:recover_parked, %{issue_id: issue_id}, server: pid)
    assert receipt.outcome == :rejected_not_fence_parked
    assert receipt.evidence.category == :unclassified
    assert Map.has_key?(:sys.get_state(pid).parked, issue_id)
  end

  # ---------------------------------------------------------------------------
  # Tracker reconciliation before release
  # ---------------------------------------------------------------------------

  test "terminal tracker issue: terminal reconciliation without redispatch" do
    _receipts = receipt_dir()
    pid = start_orchestrator()
    issue_id = "issue-terminal"

    workspace_root = workspace_root_fixture()
    workspace = Path.join(workspace_root, "terminal-ws")
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "work.txt"), "done work")

    identity = identity("launch-terminal")
    write_receipt("launch-terminal")

    inject_parked(pid, issue_id, worker_identity: identity, workspace_path: workspace, workspace_root: workspace_root)
    park_record(issue_id, worker_identity: identity, workspace_path: workspace, workspace_root: workspace_root)

    set_tracker_issues([tracker_issue(issue_id, "Done")])

    assert {:ok, receipt} = Control.request(:recover_parked, %{issue_id: issue_id}, server: pid)
    assert receipt.outcome == :recovered_terminal
    assert receipt.evidence.tracker_state == "Done"
    assert receipt.evidence.disposition == :terminal_reconciliation

    wait_until(fn -> :sys.get_state(pid).parked == %{} end)
    state = :sys.get_state(pid)
    assert state.parked == %{}
    assert state.retry_attempts == %{}
    refute MapSet.member?(state.claimed, issue_id)
    # Terminal reconciliation cleaned the workspace under proven death and the
    # finished issue was not resurrected (no retry record, no timer).
    refute File.exists?(workspace)
    assert match?({:error, :not_found}, RetryStore.read_record(retry_root(), issue_id))
  end

  test "issue no longer visible in the tracker releases the claim without redispatch" do
    _receipts = receipt_dir()
    pid = start_orchestrator()
    issue_id = "issue-gone"

    identity = identity("launch-gone")
    write_receipt("launch-gone")
    inject_parked(pid, issue_id, worker_identity: identity)
    park_record(issue_id, worker_identity: identity)
    set_tracker_issues([])

    assert {:ok, receipt} = Control.request(:recover_parked, %{issue_id: issue_id}, server: pid)
    assert receipt.outcome == :recovered_issue_gone
    assert receipt.evidence.disposition == :claim_released

    wait_until(fn -> :sys.get_state(pid).parked == %{} end)
    state = :sys.get_state(pid)
    assert state.retry_attempts == %{}
    refute MapSet.member?(state.claimed, issue_id)
    assert match?({:error, :not_found}, RetryStore.read_record(retry_root(), issue_id))
  end

  test "tracker unavailable refuses recovery and keeps the park" do
    _receipts = receipt_dir()
    pid = start_orchestrator()
    issue_id = "issue-tracker-down"

    identity = identity("launch-tracker-down")
    write_receipt("launch-tracker-down")
    inject_parked(pid, issue_id, worker_identity: identity)
    park_record(issue_id, worker_identity: identity)

    # Point the tracker at a port that refuses connections so the re-fetch fails.
    workflow_file =
      Path.join(System.tmp_dir!(), "parked-recovery-unreachable-#{:erlang.unique_integer([:positive])}.md")

    write_workflow_file!(workflow_file,
      tracker_kind: "linear",
      tracker_endpoint: "http://127.0.0.1:1/graphql"
    )

    Workflow.set_workflow_file_path(workflow_file)

    assert {:ok, receipt} = Control.request(:recover_parked, %{issue_id: issue_id}, server: pid)
    assert receipt.outcome == :rejected_tracker_unavailable
    assert receipt.evidence.fence_verdict == :dead

    state = :sys.get_state(pid)
    assert Map.has_key?(state.parked, issue_id)
    assert MapSet.member?(state.claimed, issue_id)
    assert {:ok, record} = RetryStore.read_record(retry_root(), issue_id)
    assert record["status"] == "parked"
  end

  # ---------------------------------------------------------------------------
  # Idempotence and restart
  # ---------------------------------------------------------------------------

  test "double recovery is idempotent: the second call is a harmless no-op" do
    _receipts = receipt_dir()
    pid = start_orchestrator()
    issue_id = "issue-double"

    identity = identity("launch-double")
    write_receipt("launch-double")
    inject_parked(pid, issue_id, worker_identity: identity)
    park_record(issue_id, worker_identity: identity)
    set_tracker_issues([tracker_issue(issue_id)])

    assert {:ok, first} = Control.request(:recover_parked, %{issue_id: issue_id}, server: pid)
    assert first.outcome == :recovery_scheduled

    state_after_first = :sys.get_state(pid)

    assert {:ok, second} = Control.request(:recover_parked, %{issue_id: issue_id}, server: pid)
    assert second.outcome == :rejected_issue_not_parked

    # No duplicate retry timer, no duplicate dispatch, no state change.
    state_after_second = :sys.get_state(pid)
    assert state_after_second.retry_attempts == state_after_first.retry_attempts
    assert map_size(state_after_second.retry_attempts) == 1
    assert state_after_second.parked == state_after_first.parked
    assert length(Control.receipts(pid)) == 2
  end

  test "restart keeps the park classifiable, then recovery releases it" do
    root = retry_root()
    _receipts = receipt_dir()
    issue_id = "issue-restart"

    identity = identity("launch-restart")

    # Durable park from a previous process lifetime: fence-related stop reason
    # persisted, receipt not yet written.
    park_record(issue_id, worker_identity: identity)
    set_tracker_issues([tracker_issue(issue_id)])

    # A real restart: startup recovery rehydrates the park (the in-memory
    # reason becomes :recovered_parked) and the operator recovery still
    # classifies it from the durable record — and refuses while the fence
    # cannot prove death.
    first = start_orchestrator()
    assert map_size(:sys.get_state(first).parked) == 1
    assert MapSet.member?(:sys.get_state(first).claimed, issue_id)

    assert {:ok, %{outcome: :rejected_fence_unknown}} =
             Control.request(:recover_parked, %{issue_id: issue_id}, server: first)

    Process.exit(first, :normal)

    # The receipt appears while nobody is running; a fresh process still sees
    # the park and the operator recovery works without touching any files.
    write_receipt("launch-restart")

    second = start_orchestrator()
    assert map_size(:sys.get_state(second).parked) == 1

    assert {:ok, receipt} = Control.request(:recover_parked, %{issue_id: issue_id}, server: second)
    assert receipt.outcome == :recovery_scheduled
    assert receipt.evidence.park_stop_reason == "worker_termination_unconfirmed"
    assert map_size(:sys.get_state(second).retry_attempts) == 1
    assert {:ok, record} = RetryStore.read_record(root, issue_id)
    assert record["status"] == "retrying"
  end

  # ---------------------------------------------------------------------------
  # Adversarial redispatch
  # ---------------------------------------------------------------------------

  test "exactly one redispatch: single token consumed once, no stale park or claim blocks the scheduler" do
    _receipts = receipt_dir()
    pid = start_orchestrator()
    issue_id = "issue-redispatch"

    workspace_root = workspace_root_fixture()
    workspace = Path.join(workspace_root, "redispatch-ws")
    File.mkdir_p!(workspace)

    identity = identity("launch-redispatch")
    write_receipt("launch-redispatch")

    inject_parked(pid, issue_id,
      worker_identity: identity,
      workspace_path: workspace,
      workspace_root: workspace_root
    )

    park_record(issue_id,
      worker_identity: identity,
      workspace_path: workspace,
      workspace_root: workspace_root
    )

    set_tracker_issues([tracker_issue(issue_id)])

    assert {:ok, %{outcome: :recovery_scheduled}} =
             Control.request(:recover_parked, %{issue_id: issue_id}, server: pid)

    state = :sys.get_state(pid)
    assert map_size(state.retry_attempts) == 1
    retry = Map.fetch!(state.retry_attempts, issue_id)
    token = retry.retry_token

    # While the replacement attempt is armed, the parked hold is gone but the
    # claim is held: the poller cannot redispatch behind the timer's back.
    assert MapSet.member?(state.claimed, issue_id)
    assert state.parked == %{}

    # Deterministically consume the single armed dispatch: the issue went
    # terminal, so the one fire performs terminal reconciliation.
    set_tracker_issues([tracker_issue(issue_id, "Done")])
    Process.cancel_timer(retry.timer_ref)
    send(pid, {:retry_issue, issue_id, token})

    wait_until(fn -> :sys.get_state(pid).retry_attempts == %{} end)
    state_after_fire = :sys.get_state(pid)
    assert state_after_fire.parked == %{}
    refute MapSet.member?(state_after_fire.claimed, issue_id)
    refute File.exists?(workspace)
    assert match?({:error, :not_found}, RetryStore.read_record(retry_root(), issue_id))

    # A replayed token is a no-op: no second dispatch decision exists.
    send(pid, {:retry_issue, issue_id, token})
    Process.sleep(50)
    state_after_replay = :sys.get_state(pid)

    lifecycle = fn state ->
      {state.running, state.parked, state.retry_attempts, state.claimed, state.blocked, state.completed}
    end

    assert lifecycle.(state_after_replay) == lifecycle.(state_after_fire)
  end

  # ---------------------------------------------------------------------------
  # Observability
  # ---------------------------------------------------------------------------

  test "snapshot exposes the recovery class of every parked issue" do
    pid = start_orchestrator()

    inject_parked(pid, "issue-obs-fence", stop_reason: :worker_termination_unconfirmed)
    inject_parked(pid, "issue-obs-policy", stop_reason: :max_identical)
    inject_parked(pid, "issue-obs-recovered", stop_reason: :recovered_parked)

    snapshot = GenServer.call(pid, :snapshot)
    classes = Map.new(snapshot.parked, fn entry -> {entry.issue_id, entry.recovery_class} end)

    assert classes["issue-obs-fence"] == :fence_recoverable
    assert classes["issue-obs-policy"] == :policy_park
    # :recovered_parked means the original reason lives only in the durable
    # record; the snapshot never projects a verdict it did not re-prove.
    assert classes["issue-obs-recovered"] == :unclassified
  end

  test "unknown issue is reported as not parked" do
    pid = start_orchestrator()

    assert {:ok, receipt} = Control.request(:recover_parked, %{issue_id: "issue-never-parked"}, server: pid)
    assert receipt.outcome == :rejected_issue_not_parked
    assert receipt.evidence.parked? == false
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp start_orchestrator do
    name = String.to_atom("parked_recovery_orch_#{:erlang.unique_integer([:positive])}")
    {:ok, pid} = Orchestrator.start_link(name: name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    pid
  end

  defp retry_root, do: Application.fetch_env!(:symphony_elixir, :retry_store_root)

  defp inject_parked(pid, issue_id, overrides \\ []) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    entry =
      Map.merge(
        %{
          issue_id: issue_id,
          identifier: overrides[:identifier] || issue_id,
          issue_url: nil,
          failure_class: overrides[:failure_class] || "PROVIDER_OUTAGE",
          stop_reason: overrides[:stop_reason] || :worker_termination_unconfirmed,
          attempt_count: 1,
          identical_failure_count: 1,
          first_failure_at: now,
          last_failure_at: now,
          error: "worker death could not be proven",
          worker_host: nil,
          workspace_path: nil,
          workspace_root: nil,
          route: :primary,
          primary_failure_count: 0,
          worker_identity: overrides[:worker_identity],
          termination_expectation: :MANAGED_CONFIRMATION_REQUIRED,
          parked_at: now
        },
        Map.new(overrides)
      )

    :sys.replace_state(pid, fn state ->
      %{state | parked: Map.put(state.parked, issue_id, entry), claimed: MapSet.put(state.claimed, issue_id)}
    end)

    entry
  end

  defp park_record(issue_id, overrides \\ []) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    record =
      RetryStore.build_record(%{
        issue_id: issue_id,
        identifier: issue_id,
        status: Keyword.get(overrides, :status, "parked"),
        failure_class: "PROVIDER_OUTAGE",
        attempt_count: 1,
        identical_failure_count: 1,
        first_failure_at: now,
        last_failure_at: now,
        last_error: "worker death could not be proven",
        worker_host: "",
        workspace_path: Keyword.get(overrides, :workspace_path, ""),
        workspace_root: Keyword.get(overrides, :workspace_root, retry_root()),
        worker_identity: Keyword.get(overrides, :worker_identity)
      })

    record =
      case Keyword.get(overrides, :stop_reason, "worker_termination_unconfirmed") do
        nil -> Map.delete(record, "stop_reason")
        reason -> Map.put(record, "stop_reason", reason)
      end

    record = Map.put(record, "termination_expectation", "MANAGED_CONFIRMATION_REQUIRED")
    :ok = RetryStore.write_record(retry_root(), record)
    record
  end

  defp receipt_dir do
    root =
      Path.join(System.tmp_dir!(), "parked-recovery-receipts-#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(root)
    Application.put_env(:symphony_elixir, :worker_termination_receipt_root, root)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :worker_termination_receipt_root) end)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp identity(launch_id) do
    %{
      "schema_version" => 1,
      "launch_id" => launch_id,
      "issue_id" => "irrelevant",
      "attempt_id" => nil,
      "workspace" => nil,
      "worker_host" => nil,
      "root_pid" => nil,
      "root_creation_time" => nil,
      "receipt_path" => Path.join(WorkerContainment.receipt_dir(), launch_id <> ".json")
    }
  end

  defp write_receipt(launch_id, attrs \\ %{}) do
    path = Path.join(WorkerContainment.receipt_dir(), launch_id <> ".json")

    payload =
      Jason.encode!(
        Map.merge(
          %{
            "schema_version" => 1,
            "launch_id" => launch_id,
            "tree_drained" => true,
            "terminal_reason" => "NATURAL_EXIT",
            "termination_mode" => "graceful"
          },
          Map.new(attrs)
        )
      )

    File.write!(path, payload)
    path
  end

  defp tracker_issue(issue_id, state \\ "In Progress") do
    %Issue{
      id: issue_id,
      identifier: "MT-" <> String.upcase(issue_id),
      title: "Parked recovery " <> issue_id,
      description: "Operator recovery scenario",
      state: state,
      url: "https://example.org/issues/" <> issue_id,
      dispatchable: true
    }
  end

  defp set_tracker_issues(issues) do
    Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)
    :ok
  end

  defp workspace_fixture(name) do
    root = workspace_root_fixture()
    workspace = Path.join(root, name)
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "sentinel.txt"), "in-progress work\n")
    workspace
  end

  defp workspace_root_fixture do
    root = Path.join(System.tmp_dir!(), "parked-recovery-ws-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp wait_until(fun, tries \\ 200)

  defp wait_until(fun, tries) when tries > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      wait_until(fun, tries - 1)
    end
  end

  defp wait_until(_fun, _tries), do: flunk("condition was not met in time")
end
