defmodule SymphonyElixir.WakeTest do
  @moduledoc """
  MIC-10 focused wake-eligibility tests: non-actionable updates never wake,
  actionable events wake once per domain identity, dedup holds across
  restarts, unhandled actionable events survive restarts, deterministic and
  human-owned events stay non-waking, and independent issues stay isolated.
  """

  use ExUnit.Case, async: false

  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Wake.{Event, Ledger, Receipt, Store}

  @failed_opts [evidence: "class:TRANSIENT_WORKER_FAILURE:attempt:1", attempt_id: "1"]

  defp tmp_root do
    path = Path.join([System.tmp_dir!(), "wake-test", Integer.to_string(System.unique_integer([:positive]))])
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  describe "classification (deterministic vs actionable vs human vs observed)" do
    test "every declared kind classifies to exactly one class" do
      classifications = Enum.map(Event.kinds(), &{&1, Event.classify(&1)})

      for {kind, classification} <- classifications do
        assert classification in [:actionable, :deterministic, :human, :observed],
               "kind #{inspect(kind)} classified #{inspect(classification)}"
      end

      kinds = Event.kinds()
      assert length(Enum.uniq(kinds)) == length(kinds)
    end

    test "poll tick and worker completion never wake" do
      assert Event.classify(:poll_tick) == :observed
      assert Event.classify(:worker_completed) == :deterministic
      assert Event.classify(:worker_stale) == :deterministic
    end

    test "parked policy: retry exhaustion actionable, timer reset deterministic" do
      assert Event.classify(:parked, stop_reason: :max_attempts) == :actionable
      assert Event.classify(:parked, stop_reason: :max_identical) == :actionable
      assert Event.classify(:parked, stop_reason: :max_age) == :actionable
      assert Event.classify(:parked, stop_reason: :fence_unknown) == :actionable
      assert Event.classify(:parked, stop_reason: :auth_unavailable) == :deterministic
      assert Event.classify(:parked, stop_reason: :recovered_parked) == :deterministic
    end

    test "identity is stable for identical evidence and distinct otherwise" do
      a = Event.identity(:worker_failed, "ISS-1", @failed_opts)
      b = Event.identity(:worker_failed, "ISS-1", @failed_opts)
      c = Event.identity(:worker_failed, "ISS-1", evidence: "class:TRANSIENT_WORKER_FAILURE:attempt:2", attempt_id: "2")

      assert a == b
      assert a != c
    end
  end

  describe "wake contract" do
    # Required scenario 1
    test "non-actionable poll update does not wake" do
      {ledger, verdict} = Ledger.new() |> Ledger.observe(:poll_tick, nil, evidence: "cycle")

      assert {:suppress, receipt, :non_actionable} = verdict
      refute receipt.actionable

      snapshot = Ledger.snapshot(ledger)
      assert snapshot.pending_actionable == []
      assert snapshot.last_event.reason == :non_actionable
      assert snapshot.suppressed.non_actionable == 1
      assert snapshot.last_wake == nil
    end

    # Required scenarios 2 and 3
    test "actionable event produces one wake; duplicate observation dedups" do
      ledger = Ledger.new()

      {ledger, {:wake, receipt}} = Ledger.observe(ledger, :worker_failed, "ISS-1", @failed_opts)
      assert receipt.actionable and receipt.status == :pending and receipt.event_id != ""

      first_snapshot = Ledger.snapshot(ledger)
      assert first_snapshot.last_event.reason == :actionable
      assert first_snapshot.last_wake.kind == :worker_failed

      {ledger, {:suppress, duplicate, :duplicate}} = Ledger.observe(ledger, :worker_failed, "ISS-1", @failed_opts)
      assert duplicate.event_id == receipt.event_id

      snapshot = Ledger.snapshot(ledger)
      assert [%{event_id: event_id, kind: :worker_failed}] = snapshot.pending_actionable
      assert event_id == receipt.event_id
      assert snapshot.suppressed.duplicate == 1
    end

    # Required scenario 6
    test "deterministic continuation after worker completion does not wake" do
      {ledger, verdict} =
        Ledger.observe(Ledger.new(), :worker_completed, "ISS-1", evidence: "continuation", attempt_id: "sess-1")

      assert {:suppress, receipt, :deterministic} = verdict
      refute receipt.actionable
      assert Ledger.snapshot(ledger).pending_actionable == []
    end
  end

  describe "human decision boundary" do
    # Required scenario 11
    test "human decision required surfaces for the operator but never wakes" do
      ledger = Ledger.new()

      {ledger, {:suppress, receipt, :human_owned}} =
        Ledger.observe(ledger, :human_decision_required, "ISS-1", evidence: "input_required", attempt_id: "sess-1")

      assert receipt.decision_required
      refute receipt.actionable

      {ledger, {:suppress, discovery, :human_owned}} =
        Ledger.observe(ledger, :discovery_needs_decision, "ISS-2", evidence: "verdict:NEEDS_DECISION")

      assert discovery.decision_required

      snapshot = Ledger.snapshot(ledger)
      assert length(snapshot.pending_decisions) == 2
      assert snapshot.pending_actionable == []
      assert snapshot.suppressed.human_owned == 2
    end
  end

  describe "tracker transition policy" do
    # Required scenarios 7 and 8
    test "review-shaped transitions follow the actionable-state policy" do
      on_exit(fn -> Application.delete_env(:symphony_elixir, :wake_actionable_tracker_states) end)

      # Default policy: tracker transitions are deterministic (baseline behavior).
      {ledger, {:suppress, _, :deterministic}} =
        Ledger.observe(Ledger.new(), :tracker_state_changed, "ISS-1", to_state: "In Review", evidence: "state:In Review:updated:100")

      assert Ledger.snapshot(ledger).pending_actionable == []

      # Policy on: a "Changes Requested" state is an actionable wake.
      Application.put_env(:symphony_elixir, :wake_actionable_tracker_states, ["Changes Requested"])

      {ledger, {:wake, receipt}} =
        Ledger.observe(ledger, :tracker_state_changed, "ISS-1",
          to_state: "Changes Requested",
          evidence: "state:Changes Requested:updated:200"
        )

      assert receipt.actionable
      assert [%{kind: :tracker_state_changed}] = Ledger.snapshot(ledger).pending_actionable
    end
  end

  describe "parked and fence problems" do
    # Required scenario 9
    test "retry-exhausted park and unconfirmed termination surface actionable" do
      ledger = Ledger.new()

      {ledger, {:wake, _}} =
        Ledger.observe(ledger, :parked, "ISS-1", stop_reason: :max_attempts, evidence: "stop:max_attempts:attempt:10", attempt_id: "10")

      {ledger, {:wake, _}} =
        Ledger.observe(ledger, :worker_termination_unconfirmed, "ISS-2", evidence: "fence_unknown")

      assert length(Ledger.snapshot(ledger).pending_actionable) == 2

      # Fence-unconfirmed park must not be swallowed by the parked receipt:
      # the two problems stay distinct pending events on the same issue.
      {ledger, {:wake, fence}} =
        Ledger.observe(ledger, :worker_termination_unconfirmed, "ISS-1", evidence: "fence_alive")

      assert fence.kind == :worker_termination_unconfirmed
      assert length(Ledger.snapshot(ledger).pending_actionable) == 3
    end
  end

  describe "deduplication, supersede, and staleness" do
    test "a newer observation of the same kind supersedes the older pending one" do
      ledger = Ledger.new()

      {ledger, {:wake, first}} = Ledger.observe(ledger, :worker_failed, "ISS-1", @failed_opts)

      {ledger, {:wake, second}} =
        Ledger.observe(ledger, :worker_failed, "ISS-1", evidence: "class:TRANSIENT_WORKER_FAILURE:attempt:2", attempt_id: "2")

      refute first.event_id == second.event_id

      snapshot = Ledger.snapshot(ledger)
      assert [%{event_id: superseding_event_id}] = snapshot.pending_actionable
      assert superseding_event_id == second.event_id
      assert snapshot.superseded_count == 1
    end

    # Required scenario 10
    test "stale superseded evidence does not wake, fresh evidence still does" do
      ledger = Ledger.new()
      {ledger, {:wake, _}} = Ledger.observe(ledger, :parked, "ISS-1", stop_reason: :max_attempts, evidence: "stop:max_attempts:attempt:10", attempt_id: "10")

      # Issue leaves every live set: its pending receipts go stale.
      {ledger, 1} = Ledger.reconcile(ledger, [])
      assert Ledger.snapshot(ledger).stale_count == 1

      # The obsolete fact cannot wake again...
      {ledger, {:suppress, _, :stale}} =
        Ledger.observe(ledger, :parked, "ISS-1", stop_reason: :max_attempts, evidence: "stop:max_attempts:attempt:10", attempt_id: "10")

      # ...but a genuinely new problem on the same issue still can.
      {ledger, {:wake, _}} =
        Ledger.observe(ledger, :worker_failed, "ISS-1", evidence: "class:PROVIDER_AUTH:attempt:11", attempt_id: "11")

      assert [%{kind: :worker_failed}] = Ledger.snapshot(ledger).pending_actionable
    end
  end

  describe "restart reconciliation" do
    # Required scenario 4
    test "restart does not duplicate an already handled event" do
      root = tmp_root()
      ledger = Ledger.new(root)

      {ledger, {:wake, receipt}} = Ledger.observe(ledger, :worker_failed, "ISS-1", @failed_opts)
      {ledger, :ok} = Ledger.mark_handled(ledger, receipt.event_id)

      recovered = Ledger.recover(root)
      assert {:suppress, _, :duplicate} = Ledger.observe(recovered, :worker_failed, "ISS-1", @failed_opts) |> elem(1)

      snapshot = Ledger.snapshot(recovered)
      assert snapshot.pending_actionable == []
      assert File.exists?(Store.issue_path(root, "ISS-1"))
    end

    # Required scenario 5
    test "unhandled actionable event survives restart and stays recoverable" do
      root = tmp_root()
      ledger = Ledger.new(root)

      {ledger, {:wake, receipt}} = Ledger.observe(ledger, :worker_failed, "ISS-1", @failed_opts)

      recovered = Ledger.recover(root)
      snapshot = Ledger.snapshot(recovered)
      assert [%{event_id: recovered_event_id, actionable: true}] = snapshot.pending_actionable
      assert recovered_event_id == receipt.event_id
      assert snapshot.last_wake == nil

      # Handling after recovery persists, so a second restart dedups too.
      {_recovered, :ok} = Ledger.mark_handled(recovered, receipt.event_id)
      assert {:suppress, _, :duplicate} = Ledger.recover(root) |> Ledger.observe(:worker_failed, "ISS-1", @failed_opts) |> elem(1)
    end

    test "restart rehydration does not displace a pending wake, and cross-kind events stay distinct" do
      root = tmp_root()
      ledger = Ledger.new(root)

      {ledger, {:wake, parked}} =
        Ledger.observe(ledger, :parked, "ISS-1", stop_reason: :max_attempts, evidence: "stop:max_attempts:attempt:10", attempt_id: "10")

      # Restart: the persisted parked receipt is still pending (recoverable).
      recovered = Ledger.recover(root)
      assert [%{event_id: recovered_event_id, kind: :parked}] = Ledger.snapshot(recovered).pending_actionable
      assert recovered_event_id == parked.event_id

      # A deterministic observation of a different kind never displaces the
      # pending actionable wake (in the runtime, `:recovered_parked` parks skip
      # observation entirely — see Orchestrator.park_issue/4).
      {recovered, {:suppress, _, :deterministic}} =
        Ledger.observe(recovered, :worker_stale, "ISS-1", evidence: "stall:45000", attempt_id: "sess-1")

      assert [%{event_id: remaining_event_id}] = Ledger.snapshot(recovered).pending_actionable
      assert remaining_event_id == parked.event_id
    end
  end

  describe "issue isolation" do
    # Required scenario 12
    test "multiple independent issues remain isolated" do
      ledger = Ledger.new(root = tmp_root())

      {ledger, {:wake, iss1}} = Ledger.observe(ledger, :worker_failed, "ISS-1", @failed_opts)

      {ledger, {:wake, _}} =
        Ledger.observe(ledger, :worker_failed, "ISS-2", evidence: "class:TRANSIENT_WORKER_FAILURE:attempt:1", attempt_id: "1")

      {ledger, :ok} = Ledger.mark_handled(ledger, iss1.event_id)

      {ledger, {:wake, _}} =
        Ledger.observe(ledger, :worker_failed, "ISS-2", evidence: "class:TRANSIENT_WORKER_FAILURE:attempt:2", attempt_id: "2")

      snapshot = Ledger.snapshot(ledger)
      assert [%{issue_id: "ISS-2"}] = snapshot.pending_actionable
      assert snapshot.handled_count == 1

      # Handling every pending event of one issue leaves the other untouched.
      {ledger, 1} = Ledger.mark_issue_handled(ledger, "ISS-2")
      assert Ledger.snapshot(ledger).pending_actionable == []
      assert File.exists?(Store.issue_path(root, "ISS-1"))
    end
  end

  describe "orchestrator wiring" do
    test "observe_wake_for_test records wakes and persists receipts; nil ledger is a safe no-op" do
      root = tmp_root()

      empty_state = %Orchestrator.State{}
      assert %Orchestrator.State{wake_ledger: nil} = Orchestrator.observe_wake_for_test(empty_state, :worker_failed, "ISS-1", @failed_opts)

      state = %{empty_state | wake_ledger: Ledger.new(root)}
      state = Orchestrator.observe_wake_for_test(state, :worker_failed, "ISS-1", @failed_opts)
      state = Orchestrator.observe_wake_for_test(state, :poll_tick, nil, evidence: "cycle")
      state = Orchestrator.observe_wake_for_test(state, :human_decision_required, "ISS-1", evidence: "input_required", attempt_id: "sess-1")

      snapshot = Ledger.snapshot(state.wake_ledger)
      assert [%{kind: :worker_failed}] = snapshot.pending_actionable
      assert [%{kind: :human_decision_required}] = snapshot.pending_decisions
      assert snapshot.suppressed.non_actionable == 1
      assert File.exists?(Store.issue_path(root, "ISS-1"))

      # Reconcile drops pending receipts once the issue leaves the live sets.
      {state, 0} = Orchestrator.reconcile_wake_ledger_for_test(state, ["ISS-1"])
      assert length(Ledger.snapshot(state.wake_ledger).pending_actionable) == 1

      {state, 2} = Orchestrator.reconcile_wake_ledger_for_test(state, [])
      snapshot = Ledger.snapshot(state.wake_ledger)
      assert snapshot.stale_count == 2
      assert snapshot.pending_actionable == []
    end

    test "wake receipts round-trip through the durable store" do
      root = tmp_root()
      ledger = Ledger.new(root)

      {ledger, {:wake, receipt}} = Ledger.observe(ledger, :worker_failed, "ISS/1", @failed_opts)
      {ledger, {:suppress, decision, :human_owned}} = Ledger.observe(ledger, :human_decision_required, "ISS/1", evidence: "input_required")
      assert decision.decision_required

      {:ok, %{pending: pending, handled: handled}} = Store.read_issue(root, "ISS/1")
      assert length(pending) == 2

      persisted_failure = Enum.find(pending, &(&1.kind == :worker_failed))
      assert %Receipt{kind: :worker_failed, actionable: true} = persisted_failure
      assert persisted_failure.event_id == receipt.event_id

      persisted_decision = Enum.find(pending, &(&1.kind == :human_decision_required))
      assert %Receipt{decision_required: true} = persisted_decision
      assert persisted_decision.event_id == decision.event_id
      assert handled == %{}

      {_ledger, :ok} = Ledger.mark_handled(ledger, receipt.event_id)
      {:ok, %{pending: pending, handled: handled}} = Store.read_issue(root, "ISS/1")
      assert Enum.map(pending, & &1.event_id) == [decision.event_id]
      assert map_size(handled) == 1
      assert Enum.any?(Map.values(handled), &is_struct(&1, DateTime))
    end
  end
end
