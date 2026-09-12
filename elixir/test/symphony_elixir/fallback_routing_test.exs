defmodule SymphonyElixir.FallbackRoutingTest do
  # MIC-195 Slice C: Orchestrator-level fallback routing — route decisions on
  # classified failures, config/pin gates, the dispatch route projection, the
  # fail-closed materialization error path, and durable route recovery.
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RetryStore
  alias SymphonyElixir.Tracker.Issue

  setup do
    root =
      Path.join(System.tmp_dir!(), "mic195-fallback-#{:erlang.unique_integer([:positive])}")

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

  defp enable_fallback(opts \\ []) do
    write_workflow_file!(Workflow.workflow_file_path(),
      Keyword.merge(
        [
          codex_fallback_enabled: true,
          codex_fallback_model: "gpt-5.6-sol",
          codex_fallback_reasoning_effort: "high"
        ],
        opts
      )
    )
  end

  defp disable_fallback do
    write_workflow_file!(Workflow.workflow_file_path())
  end

  defp test_issue(id, identifier, labels \\ []) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Fallback routing " <> identifier,
      description: "MIC-195 Slice C",
      state: "Todo",
      url: "https://example.org/issues/" <> identifier,
      labels: labels,
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

  defp fail(state, issue, reason) do
    Orchestrator.handle_failure_for_test(state, issue.id, running_entry(issue), "sess-" <> issue.id, reason)
  end

  describe "route decision on classified failures" do
    test "MODEL_UNAVAILABLE switches the next attempt to fallback after the first failure", %{root: root} do
      enable_fallback()
      issue = test_issue("ISS-FB-MODEL", "MT-FB-MODEL")

      next = fail(fresh_state(), issue, :model_unavailable)

      try do
        retry = Map.fetch!(next.retry_attempts, issue.id)
        assert retry.route == :fallback
        assert retry.primary_failure_count == 1

        history = Orchestrator.retry_history_for_test(next)[issue.id]
        assert history.route == :fallback
        assert history.primary_failure_count == 1

        assert {:ok, record} = RetryStore.read_record(root, issue.id)
        assert record["route"] == "fallback"
        assert record["primary_failure_count"] == 1
        assert Orchestrator.next_dispatch_route_for_test(next, issue.id) == :fallback
      after
        cancel_timers(next)
      end
    end

    test "PROVIDER_QUOTA stays primary after failure #1 and switches after the second consecutive failure", %{root: root} do
      enable_fallback()
      issue = test_issue("ISS-FB-QUOTA", "MT-FB-QUOTA")
      state = fresh_state()

      first = fail(state, issue, :provider_quota)

      try do
        assert Map.fetch!(first.retry_attempts, issue.id).route == :primary
        assert Orchestrator.retry_history_for_test(first)[issue.id].primary_failure_count == 1

        second = fail(%{first | retry_attempts: %{}}, issue, :provider_quota)

        retry = Map.fetch!(second.retry_attempts, issue.id)
        assert retry.route == :fallback
        assert retry.primary_failure_count == 2

        assert {:ok, record} = RetryStore.read_record(root, issue.id)
        assert record["route"] == "fallback"
      after
        cancel_timers(first)
      end
    end

    test "PROVIDER_RATE_LIMIT switches only after the second consecutive eligible failure" do
      enable_fallback()
      issue = test_issue("ISS-FB-RATE", "MT-FB-RATE")

      first = fail(fresh_state(), issue, :provider_rate_limit)
      assert Map.fetch!(first.retry_attempts, issue.id).route == :primary

      second = fail(%{first | retry_attempts: %{}}, issue, :provider_rate_limit)
      assert Map.fetch!(second.retry_attempts, issue.id).route == :fallback

      cancel_timers(first)
      cancel_timers(second)
    end

    test "PROVIDER_OUTAGE switches only after the second consecutive eligible failure" do
      enable_fallback()
      issue = test_issue("ISS-FB-OUTAGE", "MT-FB-OUTAGE")

      first = fail(fresh_state(), issue, :provider_outage)
      assert Map.fetch!(first.retry_attempts, issue.id).route == :primary

      second = fail(%{first | retry_attempts: %{}}, issue, :provider_outage)
      assert Map.fetch!(second.retry_attempts, issue.id).route == :fallback

      cancel_timers(first)
      cancel_timers(second)
    end

    test "ineligible failures never switch and reset the consecutive eligible count" do
      enable_fallback()
      issue = test_issue("ISS-FB-RESET", "MT-FB-RESET")

      first = fail(fresh_state(), issue, :provider_quota)
      assert Orchestrator.retry_history_for_test(first)[issue.id].primary_failure_count == 1

      broken = fail(%{first | retry_attempts: %{}}, issue, :runtime_unavailable)
      history = Orchestrator.retry_history_for_test(broken)[issue.id]
      assert history.route == :primary
      assert history.primary_failure_count == 0

      again = fail(%{broken | retry_attempts: %{}}, issue, :provider_quota)
      assert Map.fetch!(again.retry_attempts, issue.id).route == :primary
      assert Orchestrator.retry_history_for_test(again)[issue.id].primary_failure_count == 1

      cancel_timers(first)
      cancel_timers(broken)
      cancel_timers(again)
    end

    test "fallback failures do not increment primary_failure_count and the route stays latched" do
      enable_fallback()
      issue = test_issue("ISS-FB-LATCH", "MT-FB-LATCH")

      first = fail(fresh_state(), issue, :model_unavailable)
      assert Map.fetch!(first.retry_attempts, issue.id).route == :fallback

      second = fail(%{first | retry_attempts: %{}}, issue, :provider_quota)
      retry = Map.fetch!(second.retry_attempts, issue.id)
      assert retry.route == :fallback
      assert retry.primary_failure_count == 1

      history = Orchestrator.retry_history_for_test(second)[issue.id]
      assert history.route == :fallback
      assert history.primary_failure_count == 1
      # The envelope still folded the fallback failure.
      assert history.attempt_count == 2

      cancel_timers(first)
      cancel_timers(second)
    end

    test "the route switch does not reset the global attempt count or the identical streak" do
      enable_fallback()
      issue = test_issue("ISS-FB-ENVELOPE", "MT-FB-ENVELOPE")

      first = fail(fresh_state(), issue, :model_unavailable)
      second = fail(%{first | retry_attempts: %{}}, issue, :model_unavailable)

      history = Orchestrator.retry_history_for_test(second)[issue.id]
      assert history.attempt_count == 2
      assert history.identical_failure_count == 2
      assert history.route == :fallback

      cancel_timers(first)
      cancel_timers(second)
    end

    test "the route switch preserves the failure-sequence age budget" do
      enable_fallback()
      issue = test_issue("ISS-FB-AGE", "MT-FB-AGE")
      now_ms = System.monotonic_time(:millisecond)

      seeded =
        Map.put(fresh_state(), :retry_history, %{
          issue.id => %{
            attempt_count: 3,
            identical_failure_count: 1,
            first_failure_at_ms: now_ms - 1_800_000,
            last_failure_at_ms: now_ms - 1_000,
            last_failure_class: :provider_quota,
            route: :primary,
            primary_failure_count: 1
          }
        })

      next = fail(seeded, issue, :provider_quota)

      history = Orchestrator.retry_history_for_test(next)[issue.id]
      assert history.attempt_count == 4
      assert history.first_failure_at_ms == now_ms - 1_800_000
      assert history.route == :fallback
      assert history.primary_failure_count == 2

      cancel_timers(next)
    end

    test "AUTH_UNAVAILABLE parks immediately and never selects fallback", %{root: root} do
      enable_fallback()
      issue = test_issue("ISS-FB-AUTH", "MT-FB-AUTH")

      next = fail(fresh_state(), issue, :unauthorized)

      try do
        assert Map.has_key?(Orchestrator.parked_for_test(next), issue.id)
        assert next.retry_attempts == %{}
        assert Orchestrator.retry_history_for_test(next)[issue.id].route == :primary

        assert {:ok, record} = RetryStore.read_record(root, issue.id)
        assert record["status"] == "parked"
        assert record["route"] == "primary"
      after
        cancel_timers(next)
      end
    end
  end

  describe "config and pin gates" do
    test "fallback disabled in config never switches" do
      disable_fallback()
      issue = test_issue("ISS-FB-DISABLED", "MT-FB-DISABLED")

      next = fail(fresh_state(), issue, :model_unavailable)

      try do
        assert Map.fetch!(next.retry_attempts, issue.id).route == :primary
        assert Orchestrator.retry_history_for_test(next)[issue.id].primary_failure_count == 1
      after
        cancel_timers(next)
      end
    end

    test "missing fallback model never switches" do
      write_workflow_file!(Workflow.workflow_file_path(), codex_fallback_enabled: true)
      issue = test_issue("ISS-FB-NOMODEL", "MT-FB-NOMODEL")

      next = fail(fresh_state(), issue, :model_unavailable)

      try do
        assert Map.fetch!(next.retry_attempts, issue.id).route == :primary
      after
        cancel_timers(next)
      end
    end

    test "invalid fallback reasoning effort never switches" do
      enable_fallback(codex_fallback_reasoning_effort: "bogus")
      issue = test_issue("ISS-FB-BADEFFORT", "MT-FB-BADEFFORT")

      next = fail(fresh_state(), issue, :model_unavailable)

      try do
        assert Map.fetch!(next.retry_attempts, issue.id).route == :primary
      after
        cancel_timers(next)
      end
    end

    test "an explicit model pin blocks fallback" do
      enable_fallback()
      issue = test_issue("ISS-FB-PIN", "MT-FB-PIN", ["model:gpt-5.6-sol"])

      next = fail(fresh_state(), issue, :model_unavailable)

      try do
        assert Map.fetch!(next.retry_attempts, issue.id).route == :primary
        assert Orchestrator.retry_history_for_test(next)[issue.id].primary_failure_count == 1
      after
        cancel_timers(next)
      end
    end

    test "an explicit fallback:true opt-in permits threshold-based fallback despite the pin" do
      enable_fallback()
      issue = test_issue("ISS-FB-OPTIN", "MT-FB-OPTIN", ["model:gpt-5.6-sol", "fallback:true"])

      next = fail(fresh_state(), issue, :model_unavailable)

      try do
        assert Map.fetch!(next.retry_attempts, issue.id).route == :fallback
      after
        cancel_timers(next)
      end
    end

    test "an ambiguous fallback label fails closed for a pinned issue" do
      enable_fallback()
      issue = test_issue("ISS-FB-AMBIG", "MT-FB-AMBIG", ["model:gpt-5.6-sol", "fallback:maybe"])

      next = fail(fresh_state(), issue, :model_unavailable)

      try do
        assert Map.fetch!(next.retry_attempts, issue.id).route == :primary
      after
        cancel_timers(next)
      end
    end
  end

  describe "materialization error path" do
    test "a failed fallback materialization spawns no worker and preserves the latched route", %{root: root} do
      enable_fallback()
      issue = test_issue("ISS-FB-MAT", "MT-FB-MAT")

      # Drive the sequence onto the latched fallback route, then take the
      # fallback seam away before the retry dispatches.
      switched = fail(fresh_state(), issue, :model_unavailable)
      disable_fallback()
      state = %{switched | retry_attempts: %{}, claimed: MapSet.put(switched.claimed, issue.id)}

      next =
        Orchestrator.handle_route_materialization_error_for_test(state, issue, 2, :fallback, :fallback_disabled)

      try do
        assert next.running == %{}
        assert MapSet.member?(next.claimed, issue.id)

        retry = Map.fetch!(next.retry_attempts, issue.id)
        assert retry.route == :fallback
        assert retry.attempt == 3

        history = Orchestrator.retry_history_for_test(next)[issue.id]
        assert history.route == :fallback
        assert history.primary_failure_count == 1
        assert history.attempt_count == 2

        assert {:ok, record} = RetryStore.read_record(root, issue.id)
        assert record["status"] == "retrying"
        assert record["failure_class"] == "TRANSIENT_WORKER_FAILURE"
        assert record["route"] == "fallback"
        assert record["primary_failure_count"] == 1
      after
        cancel_timers(next)
      end
    end

    test "repeated materialization failures park within the bounded envelope", %{root: root} do
      enable_fallback()
      issue = test_issue("ISS-FB-MATPARK", "MT-FB-MATPARK")
      now_ms = System.monotonic_time(:millisecond)

      state =
        Map.put(fresh_state(), :retry_history, %{
          issue.id => %{
            attempt_count: 9,
            identical_failure_count: 1,
            first_failure_at_ms: now_ms - 60_000,
            last_failure_at_ms: now_ms,
            last_failure_class: :provider_quota,
            route: :fallback,
            primary_failure_count: 2
          }
        })

      next = Orchestrator.handle_route_materialization_error_for_test(state, issue, 9, :fallback, :fallback_disabled)

      try do
        parked = Orchestrator.parked_for_test(next)
        assert Map.has_key?(parked, issue.id)
        assert next.retry_attempts == %{}
        assert MapSet.member?(next.claimed, issue.id)

        assert {:ok, record} = RetryStore.read_record(root, issue.id)
        assert record["status"] == "parked"
        assert record["route"] == "fallback"
        assert record["primary_failure_count"] == 2
      after
        cancel_timers(next)
      end
    end

    test "a primary materialization never produces the error path" do
      disable_fallback()
      issue = test_issue("ISS-FB-PRIM", "MT-FB-PRIM")

      state = %{fresh_state() | claimed: MapSet.put(fresh_state().claimed, issue.id)}
      next = Orchestrator.handle_route_materialization_error_for_test(state, issue, 1, :primary, :fallback_disabled)

      try do
        # :primary materialization cannot fail; the hook only records the
        # defensive fold — no route change, transient class, bounded retry.
        assert Map.fetch!(next.retry_attempts, issue.id).route == :primary
        assert Orchestrator.retry_history_for_test(next)[issue.id].route == :primary
      after
        cancel_timers(next)
      end
    end
  end

  describe "restart recovery" do
    defp write_raw_record!(root, record) do
      :ok = RetryStore.write_record(root, record)
      record
    end

    defp base_record(root, issue_id, overrides) do
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      RetryStore.build_record(
        %{
          issue_id: issue_id,
          identifier: issue_id,
          status: "retrying",
          failure_class: "MODEL_UNAVAILABLE",
          attempt_count: 2,
          identical_failure_count: 2,
          first_failure_at: now,
          last_failure_at: now,
          last_error: "model down",
          workspace_root: root,
          worker_identity: "never_spawned"
        }
        |> Map.merge(Map.new(overrides))
      )
    end

    test "route fallback persists and the next permitted retry remains fallback", %{root: root} do
      record = base_record(root, "ISS-FB-REC-FB", route: :fallback, primary_failure_count: 2)
      write_raw_record!(root, record)

      recovered = Orchestrator.recover_retry_records_for_test(fresh_state())

      try do
        retry = Map.fetch!(recovered.retry_attempts, "ISS-FB-REC-FB")
        assert retry.route == :fallback
        assert retry.primary_failure_count == 2
        assert retry.attempt == 3

        history = Orchestrator.retry_history_for_test(recovered)["ISS-FB-REC-FB"]
        assert history.route == :fallback
        assert history.primary_failure_count == 2
        assert Orchestrator.next_dispatch_route_for_test(recovered, "ISS-FB-REC-FB") == :fallback
      after
        cancel_timers(recovered)
      end
    end

    test "route primary persists", %{root: root} do
      record = base_record(root, "ISS-FB-REC-PRIM", route: :primary, primary_failure_count: 1)
      write_raw_record!(root, record)

      recovered = Orchestrator.recover_retry_records_for_test(fresh_state())

      try do
        retry = Map.fetch!(recovered.retry_attempts, "ISS-FB-REC-PRIM")
        assert retry.route == :primary
        assert retry.primary_failure_count == 1
        assert Orchestrator.next_dispatch_route_for_test(recovered, "ISS-FB-REC-PRIM") == :primary
      after
        cancel_timers(recovered)
      end
    end

    test "legacy records without route fields default safely to primary/0", %{root: root} do
      record = base_record(root, "ISS-FB-REC-LEGACY", []) |> Map.drop(["route", "primary_failure_count"])
      write_raw_record!(root, record)

      recovered = Orchestrator.recover_retry_records_for_test(fresh_state())

      try do
        retry = Map.fetch!(recovered.retry_attempts, "ISS-FB-REC-LEGACY")
        assert retry.route == :primary
        assert retry.primary_failure_count == 0
        assert retry.attempt == 3
      after
        cancel_timers(recovered)
      end
    end

    test "an invalid route value fails closed with claim and no timer", %{root: root} do
      record = base_record(root, "ISS-FB-REC-SIDEWAYS", []) |> Map.put("route", "sideways")
      write_raw_record!(root, record)

      recovered = Orchestrator.recover_retry_records_for_test(fresh_state())

      try do
        assert MapSet.member?(recovered.claimed, "ISS-FB-REC-SIDEWAYS")
        assert recovered.retry_attempts == %{}
        assert Orchestrator.parked_for_test(recovered) == %{}
        refute Map.has_key?(Orchestrator.retry_history_for_test(recovered), "ISS-FB-REC-SIDEWAYS")
      after
        cancel_timers(recovered)
      end
    end

    test "an invalid primary_failure_count fails closed with claim and no timer", %{root: root} do
      record = base_record(root, "ISS-FB-REC-BADCOUNT", []) |> Map.put("primary_failure_count", "two")
      write_raw_record!(root, record)

      recovered = Orchestrator.recover_retry_records_for_test(fresh_state())

      try do
        assert MapSet.member?(recovered.claimed, "ISS-FB-REC-BADCOUNT")
        assert recovered.retry_attempts == %{}
      after
        cancel_timers(recovered)
      end
    end

    test "recovery never double-increments the counters and never duplicates the timer", %{root: root} do
      record = base_record(root, "ISS-FB-REC-ONCE", route: :fallback, primary_failure_count: 2)
      write_raw_record!(root, record)

      first = Orchestrator.recover_retry_records_for_test(fresh_state())
      second = Orchestrator.recover_retry_records_for_test(first)

      try do
        assert map_size(second.retry_attempts) == 1
        retry = Map.fetch!(second.retry_attempts, "ISS-FB-REC-ONCE")
        assert retry.route == :fallback
        assert retry.primary_failure_count == 2
        assert retry.attempt == 3
      after
        cancel_timers(first)
        cancel_timers(second)
      end
    end

    test "a parked fallback record preserves the route for diagnostics", %{root: root} do
      record = base_record(root, "ISS-FB-REC-PARK", status: "parked", route: :fallback, primary_failure_count: 2)
      write_raw_record!(root, record)

      recovered = Orchestrator.recover_retry_records_for_test(fresh_state())

      try do
        parked = Orchestrator.parked_for_test(recovered)
        entry = Map.fetch!(parked, "ISS-FB-REC-PARK")
        assert entry.route == :fallback
        assert entry.primary_failure_count == 2
        assert MapSet.member?(recovered.claimed, "ISS-FB-REC-PARK")
        assert recovered.retry_attempts == %{}
      after
        cancel_timers(recovered)
      end
    end

    test "a fence-UNKNOWN fallback record stays fail-closed and preserves the route", %{root: root} do
      record = base_record(root, "ISS-FB-REC-FENCE", route: :fallback) |> Map.put("worker_identity", nil)
      write_raw_record!(root, record)

      recovered = Orchestrator.recover_retry_records_for_test(fresh_state())

      try do
        parked = Orchestrator.parked_for_test(recovered)
        entry = Map.fetch!(parked, "ISS-FB-REC-FENCE")
        assert entry.stop_reason == :fence_unknown
        assert entry.route == :fallback
        assert recovered.retry_attempts == %{}
      after
        cancel_timers(recovered)
      end
    end
  end
end
