defmodule SymphonyElixir.RetryEnvelopeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RetryStore

  setup do
    root =
      Path.join(System.tmp_dir!(), "mic195-envelope-#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(root)
    previous = Application.get_env(:symphony_elixir, :retry_store_root)
    Application.put_env(:symphony_elixir, :retry_store_root, root)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:symphony_elixir, :retry_store_root)
      else
        Application.put_env(:symphony_elixir, :retry_store_root, previous)
      end

      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  defp fresh_state, do: %Orchestrator.State{}

  defp test_issue(id, identifier) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Retry envelope " <> identifier,
      description: "MIC-195 Slice A",
      state: "Todo",
      url: "https://example.org/issues/" <> identifier,
      dispatchable: true
    }
  end

  defp running_entry(%Issue{} = issue) do
    %{
      identifier: issue.identifier,
      issue: issue,
      worker_host: nil,
      workspace_path: Path.join(System.tmp_dir!(), "ws-" <> issue.id),
      workspace_root: System.tmp_dir!()
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

  test "auth failures park immediately with no retry timer", %{root: root} do
    state = fresh_state()
    issue = test_issue("ISS-AUTH-1", "MT-AUTH-1")
    entry = running_entry(issue)

    next = Orchestrator.handle_failure_for_test(state, issue.id, entry, "sess-1", :unauthorized)

    try do
      parked = Orchestrator.parked_for_test(next)
      assert Map.has_key?(parked, issue.id)
      assert next.retry_attempts == %{}
      assert MapSet.member?(next.claimed, issue.id)

      assert {:ok, record} = RetryStore.read_record(root, issue.id)
      assert record["status"] == "parked"
      assert record["failure_class"] == "AUTH_UNAVAILABLE"
    after
      cancel_timers(next)
    end
  end

  test "three identical consecutive failures park the issue" do
    state = fresh_state()

    {d1, _c1, h1, s1} = Orchestrator.note_failure_for_test(state, "ISS-IDEM", :provider_outage)
    assert d1 == :retry
    assert h1.attempt_count == 1

    {d2, _c2, h2, s2} = Orchestrator.note_failure_for_test(s1, "ISS-IDEM", :provider_outage)
    assert d2 == :retry
    assert h2.identical_failure_count == 2

    {d3, _c3, h3, _s3} = Orchestrator.note_failure_for_test(s2, "ISS-IDEM", :provider_outage)
    assert d3 == {:park, :max_identical}
    assert h3.attempt_count == 3
  end

  test "ten failure attempts park the issue" do
    state = fresh_state()
    reasons = Stream.cycle([:quota, :provider_outage]) |> Enum.take(10)

    {final_decision, final_state} =
      Enum.reduce(reasons, {nil, state}, fn reason, {_d, acc} ->
        {decision, _class, _history, next} =
          Orchestrator.note_failure_for_test(acc, "ISS-ATT", reason)

        {decision, next}
      end)

    assert final_decision == {:park, :max_attempts}
    history = Orchestrator.retry_history_for_test(final_state)["ISS-ATT"]
    assert history.attempt_count == 10
    assert history.identical_failure_count == 1
  end

  test "retry age beyond two hours parks the issue" do
    now_ms = System.monotonic_time(:millisecond)

    history = %{
      attempt_count: 5,
      identical_failure_count: 1,
      first_failure_at_ms: now_ms - 7_200_001,
      last_failure_at_ms: now_ms - 1_000,
      last_failure_class: :provider_outage
    }

    state = %{fresh_state() | retry_history: %{"ISS-AGE" => history}}

    {decision, _class, updated, _next} =
      Orchestrator.note_failure_for_test(state, "ISS-AGE", :quota)

    assert decision == {:park, :max_age}
    assert updated.attempt_count == 6
  end

  test "provider reset timing floors the retry delay" do
    state = fresh_state()
    issue = test_issue("ISS-RESET-1", "MT-RESET-1")
    entry = running_entry(issue)
    reason = %{code: "rate_limit_exceeded", reset_after_ms: 120_000}

    next = Orchestrator.handle_failure_for_test(state, issue.id, entry, "sess-r", reason)

    try do
      retry = Map.fetch!(next.retry_attempts, issue.id)
      assert retry.attempt == 1
      now_ms = System.monotonic_time(:millisecond)
      due_in = retry.due_at_ms - now_ms
      assert due_in >= 115_000
      assert due_in <= 125_000
    after
      cancel_timers(next)
    end
  end

  test "first failure without reset uses the ten second base backoff" do
    state = fresh_state()
    issue = test_issue("ISS-BASE-1", "MT-BASE-1")
    entry = running_entry(issue)

    next = Orchestrator.handle_failure_for_test(state, issue.id, entry, "sess-b", :provider_outage)

    try do
      retry = Map.fetch!(next.retry_attempts, issue.id)
      now_ms = System.monotonic_time(:millisecond)
      due_in = retry.due_at_ms - now_ms
      assert due_in >= 9_000
      assert due_in <= 11_000
    after
      cancel_timers(next)
    end
  end

  test "failure retry records carry the minimum durable schema", %{root: root} do
    state = fresh_state()
    issue = test_issue("ISS-SCHEMA-1", "MT-SCHEMA-1")
    entry = running_entry(issue)

    next = Orchestrator.handle_failure_for_test(state, issue.id, entry, "sess-s", :unauthorized)

    try do
      assert {:ok, record} = RetryStore.read_record(root, issue.id)

      expected_keys =
        ~w(schema_version issue_id identifier status failure_class attempt_count identical_failure_count first_failure_at last_failure_at next_retry_at last_error worker_host worker_identity workspace_path workspace_root)
        |> Enum.sort()

      assert Map.keys(record) |> Enum.sort() == expected_keys
      assert record["schema_version"] == 1
      assert record["issue_id"] == issue.id
      assert record["status"] == "parked"
      assert record["worker_identity"] == nil
      refute Map.has_key?(record, "route")
      refute Map.has_key?(record, "fallback")
      refute Map.has_key?(record, "lane")
    after
      cancel_timers(next)
    end
  end

  test "parked records recover with claim, preserved workspace, and no timer", %{root: root} do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    record =
      RetryStore.build_record(%{
        issue_id: "ISS-REC-PARK",
        identifier: "MT-REC-PARK",
        status: "parked",
        failure_class: "AUTH_UNAVAILABLE",
        attempt_count: 1,
        identical_failure_count: 1,
        first_failure_at: now,
        last_failure_at: now,
        last_error: "auth down",
        worker_host: "",
        workspace_path: "/tmp/ws-park",
        workspace_root: root
      })

    :ok = RetryStore.write_record(root, record)

    next = Orchestrator.recover_retry_records_for_test(fresh_state())

    try do
      parked = Orchestrator.parked_for_test(next)
      assert Map.has_key?(parked, "ISS-REC-PARK")
      assert parked["ISS-REC-PARK"].workspace_path == "/tmp/ws-park"
      assert MapSet.member?(next.claimed, "ISS-REC-PARK")
      assert next.retry_attempts == %{}
    after
      cancel_timers(next)
    end
  end

  test "retrying records with positively proven never-spawned evidence recover counters and arm a single retry timer", %{root: root} do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    record =
      RetryStore.build_record(%{
        issue_id: "ISS-REC-RETRY",
        identifier: "MT-REC-RETRY",
        status: "retrying",
        failure_class: "PROVIDER_OUTAGE",
        attempt_count: 2,
        identical_failure_count: 2,
        first_failure_at: now,
        last_failure_at: now,
        last_error: "outage",
        workspace_root: root,
        worker_identity: "never_spawned"
      })

    :ok = RetryStore.write_record(root, record)

    first = Orchestrator.recover_retry_records_for_test(fresh_state())

    try do
      history = Orchestrator.retry_history_for_test(first)["ISS-REC-RETRY"]
      assert history.attempt_count == 2
      assert history.identical_failure_count == 2
      assert MapSet.member?(first.claimed, "ISS-REC-RETRY")
      assert map_size(first.retry_attempts) == 1
      assert Map.fetch!(first.retry_attempts, "ISS-REC-RETRY").attempt == 3

      second = Orchestrator.recover_retry_records_for_test(first)
      assert map_size(second.retry_attempts) == 1
      cancel_timers(second)
    after
      cancel_timers(first)
    end
  end

  test "recovered retrying records without worker identity fail closed to PARKED and preserve the workspace", %{root: root} do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    record =
      RetryStore.build_record(%{
        issue_id: "ISS-REC-NOID",
        identifier: "MT-REC-NOID",
        status: "retrying",
        failure_class: "PROVIDER_OUTAGE",
        attempt_count: 2,
        identical_failure_count: 2,
        first_failure_at: now,
        last_failure_at: now,
        last_error: "outage",
        workspace_path: "/tmp/ws-noid",
        workspace_root: root
      })

    :ok = RetryStore.write_record(root, record)

    next = Orchestrator.recover_retry_records_for_test(fresh_state())

    try do
      parked = Orchestrator.parked_for_test(next)
      entry = Map.fetch!(parked, "ISS-REC-NOID")
      assert entry.stop_reason == :fence_unknown
      assert entry.workspace_path == "/tmp/ws-noid"
      assert MapSet.member?(next.claimed, "ISS-REC-NOID")
      assert next.retry_attempts == %{}

      history = Orchestrator.retry_history_for_test(next)["ISS-REC-NOID"]
      assert history.attempt_count == 2
    after
      cancel_timers(next)
    end
  end

  test "ambiguous records fail closed with claim and no timer", %{root: root} do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    record =
      RetryStore.build_record(%{
        issue_id: "ISS-AMBIG",
        identifier: "MT-AMBIG",
        status: "parked",
        failure_class: "AUTH_UNAVAILABLE",
        attempt_count: 1,
        first_failure_at: now,
        last_failure_at: now,
        workspace_root: root
      })
      |> Map.put("failure_class", "BOGUS_CLASS")

    :ok = RetryStore.write_record(root, record)

    next = Orchestrator.recover_retry_records_for_test(fresh_state())

    try do
      assert MapSet.member?(next.claimed, "ISS-AMBIG")
      assert next.retry_attempts == %{}
      assert Orchestrator.parked_for_test(next) == %{}
    after
      cancel_timers(next)
    end
  end

  test "corrupt records do not crash recovery", %{root: root} do
    File.mkdir_p!(RetryStore.retries_dir(root))
    File.write!(RetryStore.record_path(root, "ISS-CORRUPT"), "not json{{{")
    next = Orchestrator.recover_retry_records_for_test(fresh_state())

    try do
      assert next.retry_attempts == %{}
      assert Orchestrator.parked_for_test(next) == %{}
    after
      cancel_timers(next)
    end
  end

  test "unknown fence verdicts fail closed with no redispatch", %{root: root} do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    opaque_record =
      RetryStore.build_record(%{
        issue_id: "ISS-FENCE",
        identifier: "MT-FENCE",
        status: "retrying",
        failure_class: "PROVIDER_OUTAGE",
        attempt_count: 1,
        identical_failure_count: 1,
        first_failure_at: now,
        last_failure_at: now,
        workspace_root: root
      })
      |> Map.put("worker_identity", "remote-host-1")

    :ok = RetryStore.write_record(root, opaque_record)

    serialized_pid_record =
      RetryStore.build_record(%{
        issue_id: "ISS-FENCE-PID",
        identifier: "MT-FENCE-PID",
        status: "retrying",
        failure_class: "PROVIDER_OUTAGE",
        attempt_count: 1,
        identical_failure_count: 1,
        first_failure_at: now,
        last_failure_at: now,
        workspace_root: root
      })
      |> Map.put("worker_identity", "#PID<0.1234.0>")

    :ok = RetryStore.write_record(root, serialized_pid_record)

    next = Orchestrator.recover_retry_records_for_test(fresh_state())

    try do
      parked = Orchestrator.parked_for_test(next)
      assert Map.has_key?(parked, "ISS-FENCE")
      assert parked["ISS-FENCE"].stop_reason == :fence_unknown
      assert Map.has_key?(parked, "ISS-FENCE-PID")
      assert parked["ISS-FENCE-PID"].stop_reason == :fence_unknown
      assert MapSet.member?(next.claimed, "ISS-FENCE")
      assert MapSet.member?(next.claimed, "ISS-FENCE-PID")
      assert next.retry_attempts == %{}
    after
      cancel_timers(next)
    end
  end

  test "failures for one issue do not consume attempts for another" do
    state = fresh_state()
    {_d1, _, _, s1} = Orchestrator.note_failure_for_test(state, "ISS-ISO-A", :provider_outage)
    {_d2, _, _, s2} = Orchestrator.note_failure_for_test(s1, "ISS-ISO-A", :quota)
    {_d3, _, _, s3} = Orchestrator.note_failure_for_test(s2, "ISS-ISO-B", :quota)

    history = Orchestrator.retry_history_for_test(s3)
    assert history["ISS-ISO-A"].attempt_count == 2
    assert history["ISS-ISO-B"].attempt_count == 1
    assert history["ISS-ISO-B"].identical_failure_count == 1
  end
end
