defmodule SymphonyElixir.SteeringTest do
  use ExUnit.Case, async: true

  # MIC-10 durable steering inbox: deterministic coverage of the 17 slice
  # scenarios. The durable record is authoritative; text transport is not.

  alias SymphonyElixir.Steering
  alias SymphonyElixir.SteeringStore

  setup do
    root = Path.join(System.tmp_dir!(), "mic10-steering-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  defp create_steer(root, attrs \\ []) do
    Steering.create(root, Keyword.merge([issue_id: "ISS-1", instruction: "prefer smaller diffs"], attrs))
  end

  defp deliver(root, steer_id, opts \\ []) do
    delivery =
      Keyword.merge([thread_id: "thread-1", turn_id: "turn-1", session_id: "thread-1-turn-1"], opts)

    Steering.mark_delivered(root, steer_id, delivery)
  end

  defp run_ladder(root, attrs \\ []) do
    {:ok, record} = create_steer(root, attrs)
    {:ok, _} = deliver(root, record["steer_id"])
    {:ok, _} = Steering.acknowledge(root, record["steer_id"])
    record
  end

  # --- Scenario 1: create PENDING steer --------------------------------------

  test "create/2 records a PENDING steer durably before any delivery", %{root: root} do
    {:ok, record} = create_steer(root)

    assert record["status"] == "PENDING"
    assert record["issue_id"] == "ISS-1"
    assert record["attempt_id"] == 0
    assert record["sequence"] == 1
    assert record["steer_id"] =~ "steer-"
    assert record["created_at"]
    assert record["delivered_at"] == nil
    assert {:ok, persisted} = SteeringStore.read_record(root, record["steer_id"])
    assert persisted["status"] == "PENDING"
  end

  # --- Scenario 2: durable write before delivery ------------------------------

  test "steer survives an emulated crash between create and delivery", %{root: root} do
    {:ok, record} = create_steer(root)
    steer_id = record["steer_id"]

    # A fresh reader (post-crash process) sees the persisted PENDING steer and
    # the delivery boundary claims it for the exact attempt.
    inbox = Steering.prepare_turn_inbox(root, "ISS-1", 0)
    assert Enum.map(inbox.deliverable, & &1["steer_id"]) == [steer_id]
    assert inbox.prompt_section =~ steer_id
    assert inbox.prompt_section =~ "prefer smaller diffs"
  end

  test "create/2 rejects blank, oversized instructions and missing issue ids", %{root: root} do
    assert {:error, :invalid_instruction} = Steering.create(root, issue_id: "ISS-1", instruction: "   ")
    assert {:error, :invalid_issue_id} = Steering.create(root, instruction: "x")
    assert {:error, :instruction_too_long} = Steering.create(root, issue_id: "ISS-1", instruction: String.duplicate("a", 9_000))
  end

  # --- Scenario 3: successful delivery ----------------------------------------

  test "mark_delivered/3 records the proven delivery facts once", %{root: root} do
    {:ok, record} = create_steer(root)

    {:ok, delivered} = deliver(root, record["steer_id"])

    assert delivered["status"] == "DELIVERED"
    assert delivered["delivered_at"]
    assert delivered["delivery_thread_id"] == "thread-1"
    assert delivered["delivery_turn_id"] == "turn-1"
    assert delivered["delivery_session_id"] == "thread-1-turn-1"
  end

  test "mark_delivered/3 is idempotent: delivery facts are never rewritten", %{root: root} do
    {:ok, record} = create_steer(root)
    {:ok, first} = deliver(root, record["steer_id"])

    {:ok, second} = deliver(root, record["steer_id"], turn_id: "turn-2")

    assert second["status"] == "DELIVERED"
    assert second["delivered_at"] == first["delivered_at"]
    assert second["delivery_turn_id"] == "turn-1"
  end

  test "mark_delivered/3 rejects a steer whose bound attempt was superseded", %{root: root} do
    {:ok, record} = create_steer(root, attempt_id: 0)

    assert {:error, :identity_mismatch} =
             Steering.mark_delivered(root, record["steer_id"], %{issue_id: "ISS-1", attempt_id: 1})
  end

  # --- Scenario 4: acknowledgement --------------------------------------------

  test "acknowledge/3 moves DELIVERED to ACKNOWLEDGED via the deterministic contract", %{root: root} do
    {:ok, record} = create_steer(root)
    {:ok, _} = deliver(root, record["steer_id"])

    {:ok, acked} = Steering.acknowledge(root, record["steer_id"], thread_id: "thread-1")

    assert acked["status"] == "ACKNOWLEDGED"
    assert acked["acknowledged_at"]
  end

  test "acknowledge/3 rejects identity mismatches and undelivered steers", %{root: root} do
    {:ok, record} = create_steer(root)
    {:ok, _} = deliver(root, record["steer_id"])

    # Wrong thread: a session that never received the steer cannot ack it.
    assert {:error, :identity_mismatch} = Steering.acknowledge(root, record["steer_id"], thread_id: "thread-9")
    # Wrong attempt: a replacement worker cannot ack a prior attempt's steer.
    assert {:error, :identity_mismatch} = Steering.acknowledge(root, record["steer_id"], attempt_id: 3)

    {:ok, pending} = create_steer(root)
    assert {:error, {:not_acknowledgeable, "PENDING"}} = Steering.acknowledge(root, pending["steer_id"])
  end

  test "ack_tool_response/3 implements the worker-emittable tool contract", %{root: root} do
    {:ok, record} = create_steer(root)
    {:ok, _} = deliver(root, record["steer_id"])

    context = %{workspace_root: root, issue_id: "ISS-1", attempt_id: 0}
    result = Steering.ack_tool_response(context, "thread-1", %{"steer_id" => record["steer_id"]})
    assert result["success"] == true

    # Acknowledging through the tool contract made the state durable.
    {:ok, persisted} = SteeringStore.read_record(root, record["steer_id"])
    assert persisted["status"] == "ACKNOWLEDGED"

    rejected = Steering.ack_tool_response(context, "wrong-thread", %{"steer_id" => record["steer_id"]})
    assert rejected["success"] == false

    unavailable = Steering.ack_tool_response(nil, "thread-1", %{"steer_id" => record["steer_id"]})
    assert unavailable["success"] == false

    malformed = Steering.ack_tool_response(context, "thread-1", %{})
    assert malformed["success"] == false
  end

  # --- Scenario 5: handled state -----------------------------------------------

  test "mark_handled/2 completes the ladder ACKNOWLEDGED -> HANDLED", %{root: root} do
    record = run_ladder(root)

    {:ok, handled} = Steering.mark_handled(root, record["steer_id"])

    assert handled["status"] == "HANDLED"
    assert handled["handled_at"]

    {:ok, merely_delivered} = create_steer(root)
    {:ok, _} = deliver(root, merely_delivered["steer_id"])
    assert {:error, {:not_handledable, "DELIVERED"}} = Steering.mark_handled(root, merely_delivered["steer_id"])
  end

  # --- Scenario 6: duplicate send idempotency ----------------------------------

  test "repeated send of the same steer id never creates a second instruction", %{root: root} do
    {:ok, first} = create_steer(root, steer_id: "steer-fixed-1")

    {:ok, second} = create_steer(root, steer_id: "steer-fixed-1", instruction: "a completely different instruction")

    assert second["steer_id"] == first["steer_id"]
    assert second["instruction"] == first["instruction"]
    assert second["created_at"] == first["created_at"]

    assert length(Steering.prepare_turn_inbox(root, "ISS-1", 0).deliverable) == 1
  end

  # --- Scenario 7: duplicate acknowledgement -----------------------------------

  test "duplicate acknowledgement is an idempotent no-op with no state rewind", %{root: root} do
    record = run_ladder(root)
    {:ok, handled} = Steering.mark_handled(root, record["steer_id"])
    {:ok, first} = Steering.acknowledge(root, record["steer_id"])

    {:ok, again} = Steering.acknowledge(root, record["steer_id"])
    {:ok, still} = Steering.mark_handled(root, record["steer_id"])

    # Ack-after-handle must not rewind the record to ACKNOWLEDGED.
    assert again["status"] == "HANDLED"
    assert again["acknowledged_at"] == first["acknowledged_at"]
    assert still["status"] == "HANDLED"
    assert still["handled_at"] == handled["handled_at"]
  end

  # --- Scenario 8: stale attempt rejection --------------------------------------

  test "steers bound to a superseded attempt are staled and never delivered", %{root: root} do
    {:ok, old} = create_steer(root, attempt_id: 0)
    {:ok, current} = create_steer(root, attempt_id: 1)

    inbox = Steering.prepare_turn_inbox(root, "ISS-1", 1)

    assert inbox.staled == [old["steer_id"]]
    assert Enum.map(inbox.deliverable, & &1["steer_id"]) == [current["steer_id"]]

    {:ok, staled} = SteeringStore.read_record(root, old["steer_id"])
    assert staled["status"] == "STALE"
    assert staled["failure_reason"] == "attempt_superseded"
  end

  # --- Scenario 9: replacement worker never receives a prior steer --------------

  test "a delivered-but-unacked steer does not reach the replacement attempt", %{root: root} do
    {:ok, record} = create_steer(root, attempt_id: 0)
    {:ok, _} = deliver(root, record["steer_id"], thread_id: "old-thread")

    inbox = Steering.prepare_turn_inbox(root, "ISS-1", 1)

    assert inbox.deliverable == []
    assert inbox.staled == [record["steer_id"]]

    {:ok, staled} = SteeringStore.read_record(root, record["steer_id"])
    assert staled["status"] == "STALE"
    # The delivery fact is retained even though the steer is now stale.
    assert staled["delivery_thread_id"] == "old-thread"
  end

  # --- Scenario 10: worker exit before delivery ---------------------------------

  test "a PENDING steer whose worker exits is retained as STALE, not discarded", %{root: root} do
    {:ok, record} = create_steer(root, attempt_id: 0)

    # Worker exit -> orchestrator schedules attempt 1 -> next turn boundary.
    Steering.prepare_turn_inbox(root, "ISS-1", 1)

    {:ok, retained} = SteeringStore.read_record(root, record["steer_id"])
    assert retained["status"] == "STALE"
    assert retained["instruction"] == "prefer smaller diffs"
    assert retained["delivered_at"] == nil
  end

  # --- Scenario 11: worker exit after delivery before ack ------------------------

  test "a DELIVERED-unacked steer whose worker exits keeps its delivery facts", %{root: root} do
    {:ok, record} = create_steer(root, attempt_id: 0)
    {:ok, delivered} = deliver(root, record["steer_id"])

    Steering.prepare_turn_inbox(root, "ISS-1", 1)

    {:ok, retained} = SteeringStore.read_record(root, record["steer_id"])
    assert retained["status"] == "STALE"
    assert retained["delivered_at"] == delivered["delivered_at"]
    assert retained["acknowledged_at"] == nil
  end

  # --- Scenario 12: restart with pending steer ------------------------------------

  test "restart reconciliation keeps PENDING steers deliverable", %{root: root} do
    {:ok, record} = create_steer(root, attempt_id: 0)

    summary = Steering.reconcile_after_restart(root)

    assert summary.pending == 1
    assert summary.staled == 0
    {:ok, after_restart} = SteeringStore.read_record(root, record["steer_id"])
    assert after_restart["status"] == "PENDING"
    assert Steering.prepare_turn_inbox(root, "ISS-1", 0).deliverable != []
  end

  # --- Scenario 13: restart with delivered steer -----------------------------------

  test "restart reconciliation retains delivered-unacked steers as STALE", %{root: root} do
    {:ok, record} = create_steer(root, attempt_id: 0)
    {:ok, delivered} = deliver(root, record["steer_id"])

    summary = Steering.reconcile_after_restart(root)

    assert summary.staled == 1
    {:ok, staled} = SteeringStore.read_record(root, record["steer_id"])
    assert staled["status"] == "STALE"
    assert staled["failure_reason"] == "runtime_restart_delivery_unverified"
    assert staled["delivered_at"] == delivered["delivered_at"]
    # Never re-delivered to a replacement worker.
    assert Steering.prepare_turn_inbox(root, "ISS-1", 0).deliverable == []
  end

  # --- Scenario 14: restart after handled steer -------------------------------------

  test "restart reconciliation does not resend or alter handled steers", %{root: root} do
    record = run_ladder(root)
    {:ok, handled} = Steering.mark_handled(root, record["steer_id"])

    summary = Steering.reconcile_after_restart(root)

    assert summary.retained == 1
    {:ok, after_restart} = SteeringStore.read_record(root, record["steer_id"])
    assert after_restart["status"] == "HANDLED"
    assert after_restart["handled_at"] == handled["handled_at"]
    assert Steering.prepare_turn_inbox(root, "ISS-1", 0).deliverable == []
  end

  # --- Scenario 15: bounded resend ----------------------------------------------------

  test "delivery failures stay PENDING until the bounded cap, then FAILED", %{root: root} do
    {:ok, record} = create_steer(root)
    steer_id = record["steer_id"]

    {:ok, after_first} = Steering.record_delivery_failure(root, steer_id, :turn_timeout)
    assert after_first["status"] == "PENDING"
    assert after_first["delivery_attempts"] == 1

    {:ok, after_second} = Steering.record_delivery_failure(root, steer_id, :port_exit)
    assert after_second["status"] == "PENDING"
    assert after_second["delivery_attempts"] == 2

    {:ok, failed} = Steering.record_delivery_failure(root, steer_id, :turn_timeout)
    assert failed["status"] == "FAILED"
    assert failed["failure_reason"] =~ "delivery_failed"
    assert Steering.max_delivery_attempts() == 3
  end

  test "a DELIVERED steer is never demoted by delivery-failure bookkeeping", %{root: root} do
    {:ok, record} = create_steer(root)
    {:ok, _} = deliver(root, record["steer_id"])

    {:ok, untouched} = Steering.record_delivery_failure(root, record["steer_id"], :turn_timeout)

    assert untouched["status"] == "DELIVERED"
    assert untouched["delivery_attempts"] == 0
  end

  # --- Scenario 16: corrupt durable state ----------------------------------------------

  test "corrupt records are reported and never delivered or fabricated", %{root: root} do
    {:ok, good} = create_steer(root)
    {:ok, bad} = create_steer(root, instruction: "second steer")
    File.write!(SteeringStore.record_path(root, bad["steer_id"]), "{corrupt")

    inbox = Steering.prepare_turn_inbox(root, "ISS-1", 0)

    assert Enum.map(inbox.deliverable, & &1["steer_id"]) == [good["steer_id"]]
    assert length(inbox.unreadable) == 1

    assert {:error, :corrupt_state} = deliver(root, bad["steer_id"])

    summary = Steering.snapshot_summary(root)
    assert Enum.any?(summary.entries, & &1.unreadable)
    assert summary.counts["UNREADABLE"] == 1
  end

  # --- Scenario 17: exact issue/attempt binding ------------------------------------------

  test "delivery claims bind to exactly one issue and attempt", %{root: root} do
    {:ok, steer_a} = create_steer(root, issue_id: "ISS-A", instruction: "for A", attempt_id: 0)

    # A different issue never claims it.
    assert Steering.prepare_turn_inbox(root, "ISS-B", 0).deliverable == []

    # The exact issue+attempt claims it.
    inbox = Steering.prepare_turn_inbox(root, "ISS-A", 0)
    assert Enum.map(inbox.deliverable, & &1["steer_id"]) == [steer_a["steer_id"]]

    # When the attempt advances, the prior steer is staled fail-closed and
    # only the attempt-1 steer is claimable.
    {:ok, newer} = create_steer(root, issue_id: "ISS-A", instruction: "for A attempt 1", attempt_id: 1)
    next_inbox = Steering.prepare_turn_inbox(root, "ISS-A", 1)

    assert Enum.map(next_inbox.deliverable, & &1["steer_id"]) == [newer["steer_id"]]
    assert steer_a["steer_id"] in next_inbox.staled
  end

  test "sequences are per-issue and delivery order follows them", %{root: root} do
    {:ok, first} = create_steer(root, issue_id: "ISS-S", instruction: "first")
    {:ok, second} = create_steer(root, issue_id: "ISS-S", instruction: "second")
    {:ok, other} = create_steer(root, issue_id: "ISS-T", instruction: "other issue")

    assert first["sequence"] == 1
    assert second["sequence"] == 2
    assert other["sequence"] == 1

    inbox = Steering.prepare_turn_inbox(root, "ISS-S", 0)
    assert Enum.map(inbox.deliverable, & &1["instruction"]) == ["first", "second"]
  end

  test "prompt_section/1 renders operator guidance as data, empty when no steers", %{root: root} do
    assert Steering.prompt_section([]) == ""

    {:ok, _} = create_steer(root, instruction: "check the failing spec first")

    section = Steering.prompt_section(Steering.prepare_turn_inbox(root, "ISS-1", 0).deliverable)
    assert section =~ "Operator steering"
    assert section =~ "check the failing spec first"
  end

  test "normalize_attempt/1 matches the orchestrator attempt convention" do
    assert Steering.normalize_attempt(nil) == 0
    assert Steering.normalize_attempt(0) == 0
    assert Steering.normalize_attempt(3) == 3
  end

  test "snapshot_summary/1 exposes state without instruction text", %{root: root} do
    {:ok, pending} = create_steer(root, instruction: "sensitive operator context")
    {:ok, other} = create_steer(root, instruction: "second steer for delivery")
    {:ok, _} = deliver(root, other["steer_id"])

    summary = Steering.snapshot_summary(root)

    assert summary.counts["PENDING"] == 1
    assert summary.counts["DELIVERED"] == 1
    assert length(summary.entries) == 2
    assert Enum.find(summary.entries, &(&1.steer_id == pending["steer_id"]))[:status] == "PENDING"
    refute Jason.encode!(summary) =~ "sensitive operator context"
  end

  test "stale_for_attempt/3 leaves records of the current attempt untouched", %{root: root} do
    {:ok, record} = create_steer(root, attempt_id: 1)
    {:ok, _} = deliver(root, record["steer_id"])

    assert Steering.stale_for_attempt(root, "ISS-1", 1) == []

    {:ok, retained} = SteeringStore.read_record(root, record["steer_id"])
    assert retained["status"] == "DELIVERED"
  end
end
