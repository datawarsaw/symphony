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

  # Production init seeds the token totals with an empty map; the bare struct
  # leaves it nil, which only the completion/termination paths read.
  @empty_codex_totals %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}

  defp fresh_state, do: %Orchestrator.State{codex_totals: @empty_codex_totals}

  defp enable_fallback(opts \\ []) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
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

  # Lifecycle cleanup treats the entry's workspace_root as the trusted deletion
  # boundary, so it must be this test's owned per-test retry-store root and can
  # never be the shared system TEMP root itself.
  defp running_entry(%Issue{} = issue) do
    workspace_root = Application.fetch_env!(:symphony_elixir, :retry_store_root)

    %{
      identifier: issue.identifier,
      issue: issue,
      worker_host: nil,
      workspace_path: Path.join(workspace_root, "ws-" <> issue.id),
      workspace_root: workspace_root
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

  # MIC-195 correction regression coverage: seed one failure sequence onto the
  # latched fallback route (threshold 1 for MODEL_UNAVAILABLE) with the durable
  # retrying record already written.
  defp latched_state(issue) do
    switched = fail(fresh_state(), issue, :model_unavailable)
    assert Map.fetch!(switched.retry_attempts, issue.id).route == :fallback
    switched
  end

  # A running entry whose worker is a real alive process, so a reconcile-driven
  # termination demonstrably stops it.
  defp terminate_test_entry(issue) do
    %{
      pid: spawn(fn -> Process.sleep(:infinity) end),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      worker_host: nil,
      workspace_path: nil,
      workspace_root: nil,
      started_at: DateTime.utc_now()
    }
  end

  describe "reconcile-driven termination ends the failure sequence" do
    test "terminal issue: the latched fallback sequence is cleared and the next dispatch starts primary", %{root: root} do
      enable_fallback()
      issue = test_issue("ISS-FB-TERM", "MT-FB-TERM")

      latched = latched_state(issue)
      assert {:ok, record} = RetryStore.read_record(root, issue.id)
      assert record["route"] == "fallback"

      entry = terminate_test_entry(issue)
      state = %{latched | running: Map.put(latched.running, issue.id, entry)}
      assert Map.has_key?(state.retry_attempts, issue.id)

      next = Orchestrator.reconcile_issue_states_for_test([%{issue | state: "Closed"}], state)

      try do
        # The running worker is terminated and the claim released.
        refute Process.alive?(entry.pid)
        refute MapSet.member?(next.claimed, issue.id)
        # Stale retry attempt/timer state is gone with it.
        assert next.retry_attempts == %{}
        # The failure sequence ended: runtime projection and durable record gone.
        refute Map.has_key?(Orchestrator.retry_history_for_test(next), issue.id)
        assert {:error, :not_found} = RetryStore.read_record(root, issue.id)
        assert Orchestrator.next_dispatch_route_for_test(next, issue.id) == :primary

        # The issue is active/routable again: the new sequence starts from a
        # zeroed count, so one quota failure must NOT reach the threshold.
        again = fail(%{next | retry_attempts: %{}}, issue, :provider_quota)

        try do
          retry = Map.fetch!(again.retry_attempts, issue.id)
          assert retry.route == :primary
          assert retry.primary_failure_count == 1
          assert Orchestrator.retry_history_for_test(again)[issue.id].primary_failure_count == 1
        after
          cancel_timers(again)
        end
      after
        cancel_timers(next)
      end
    end

    test "unroutable issue: the latched fallback sequence is cleared", %{root: root} do
      enable_fallback(tracker_required_labels: ["repo:symphony-runtime"])
      issue = test_issue("ISS-FB-UNROUTABLE", "MT-FB-UNROUTABLE")

      latched = latched_state(issue)
      assert {:ok, _record} = RetryStore.read_record(root, issue.id)

      entry = terminate_test_entry(issue)
      state = %{latched | running: Map.put(latched.running, issue.id, entry)}

      next = Orchestrator.reconcile_issue_states_for_test([issue], state)

      try do
        refute Map.has_key?(Orchestrator.retry_history_for_test(next), issue.id)
        assert {:error, :not_found} = RetryStore.read_record(root, issue.id)
        assert Orchestrator.next_dispatch_route_for_test(next, issue.id) == :primary
      after
        cancel_timers(next)
      end
    end

    test "disappeared issue: the latched fallback sequence is cleared", %{root: root} do
      enable_fallback()
      issue = test_issue("ISS-FB-MISSING", "MT-FB-MISSING")

      latched = latched_state(issue)
      assert {:ok, _record} = RetryStore.read_record(root, issue.id)

      entry = terminate_test_entry(issue)
      state = %{latched | running: Map.put(latched.running, issue.id, entry)}

      next = Orchestrator.reconcile_missing_running_issue_ids_for_test(state, [issue.id], [])

      try do
        refute Process.alive?(entry.pid)
        refute Map.has_key?(Orchestrator.retry_history_for_test(next), issue.id)
        assert {:error, :not_found} = RetryStore.read_record(root, issue.id)
        assert Orchestrator.next_dispatch_route_for_test(next, issue.id) == :primary
      after
        cancel_timers(next)
      end
    end

    test "stall restart preserves the latched fallback route, count, and envelope", %{root: root} do
      enable_fallback(codex_stall_timeout_ms: 1_000)
      issue = test_issue("ISS-FB-STALL", "MT-FB-STALL")

      latched = latched_state(issue)

      stale = DateTime.add(DateTime.utc_now(), -5, :second)

      entry =
        terminate_test_entry(issue)
        |> Map.put(:last_codex_timestamp, stale)
        |> Map.put(:last_codex_event, nil)
        |> Map.put(:started_at, stale)

      state = %{latched | running: Map.put(latched.running, issue.id, entry)}

      next = Orchestrator.reconcile_stalled_running_issues_for_test(state)

      try do
        # The stalled worker was stopped for the restart...
        refute Process.alive?(entry.pid)
        # ...but the sequence survived: the restart stays on the latched route.
        retry = Map.fetch!(next.retry_attempts, issue.id)
        assert retry.route == :fallback
        assert retry.primary_failure_count == 1
        assert retry.error =~ "stalled for"

        history = Orchestrator.retry_history_for_test(next)[issue.id]
        assert history.route == :fallback
        assert history.primary_failure_count == 1
        assert Orchestrator.next_dispatch_route_for_test(next, issue.id) == :fallback

        assert {:ok, record} = RetryStore.read_record(root, issue.id)
        assert record["status"] == "retrying"
        assert record["route"] == "fallback"
        assert record["primary_failure_count"] == 1
      after
        cancel_timers(next)
      end
    end
  end

  describe "retry-poll failures never fold route state" do
    # Mirrors the metadata shape pop_retry_attempt_state/3 hands to
    # handle_retry_issue/4 when a retry timer fires.
    defp retry_entry_metadata(state, issue_id) do
      entry = Map.fetch!(state.retry_attempts, issue_id)

      %{
        identifier: Map.get(entry, :identifier),
        issue_url: Map.get(entry, :issue_url),
        error: Map.get(entry, :error),
        worker_host: Map.get(entry, :worker_host),
        workspace_path: Map.get(entry, :workspace_path),
        workspace_root: Map.get(entry, :workspace_root),
        route: Map.get(entry, :route, :primary),
        primary_failure_count: Map.get(entry, :primary_failure_count, 0)
      }
    end

    defp poll_failure(state, issue_id, attempt, metadata, reason) do
      Orchestrator.handle_retry_poll_failure_for_test(state, issue_id, attempt, metadata, reason)
    end

    test "a provider-shaped poll error does not increment primary_failure_count or latch fallback", %{root: root} do
      enable_fallback()
      issue = test_issue("ISS-FB-POLL429", "MT-FB-POLL429")

      first = fail(fresh_state(), issue, :provider_quota)
      assert Orchestrator.retry_history_for_test(first)[issue.id].primary_failure_count == 1

      metadata = retry_entry_metadata(first, issue.id)

      next =
        poll_failure(first, issue.id, 1, metadata, {:retry_poll_failed, "tracker HTTP 429: too many requests"})

      try do
        # Route state untouched: not incremented to 2, not latched to fallback.
        history = Orchestrator.retry_history_for_test(next)[issue.id]
        assert history.route == :primary
        assert history.primary_failure_count == 1

        retry = Map.fetch!(next.retry_attempts, issue.id)
        assert retry.route == :primary
        assert retry.primary_failure_count == 1

        # The durable record agrees with the authoritative in-memory state.
        assert {:ok, record} = RetryStore.read_record(root, issue.id)
        assert record["route"] == "primary"
        assert record["primary_failure_count"] == 1
      after
        cancel_timers(next)
      end
    end

    test "an opaque poll error does not reset primary_failure_count" do
      enable_fallback()
      issue = test_issue("ISS-FB-POLLOPAQUE", "MT-FB-POLLOPAQUE")

      first = fail(fresh_state(), issue, :provider_quota)
      assert Orchestrator.retry_history_for_test(first)[issue.id].primary_failure_count == 1

      metadata = retry_entry_metadata(first, issue.id)
      next = poll_failure(first, issue.id, 1, metadata, {:retry_poll_failed, :nxdomain})

      try do
        history = Orchestrator.retry_history_for_test(next)[issue.id]
        assert history.route == :primary
        assert history.primary_failure_count == 1

        retry = Map.fetch!(next.retry_attempts, issue.id)
        assert retry.route == :primary
        assert retry.primary_failure_count == 1
      after
        cancel_timers(next)
      end
    end

    test "a poll error on a latched fallback sequence preserves the latch and the durable record", %{root: root} do
      enable_fallback()
      issue = test_issue("ISS-FB-POLLLATCH", "MT-FB-POLLLATCH")

      latched = latched_state(issue)
      metadata = retry_entry_metadata(latched, issue.id)
      next = poll_failure(latched, issue.id, 1, metadata, {:retry_poll_failed, :timeout})

      try do
        assert Orchestrator.next_dispatch_route_for_test(next, issue.id) == :fallback

        retry = Map.fetch!(next.retry_attempts, issue.id)
        assert retry.route == :fallback
        assert retry.primary_failure_count == 1

        assert {:ok, record} = RetryStore.read_record(root, issue.id)
        assert record["route"] == "fallback"
        assert record["primary_failure_count"] == 1
      after
        cancel_timers(next)
      end
    end

    test "the next eligible worker failure after a poll hiccup still switches at the exact threshold" do
      enable_fallback()
      issue = test_issue("ISS-FB-POLLSEQ", "MT-FB-POLLSEQ")

      # Quota worker failure #1 → count 1.
      first = fail(fresh_state(), issue, :provider_quota)
      assert Orchestrator.retry_history_for_test(first)[issue.id].primary_failure_count == 1

      # Poll failure → count stays 1.
      metadata = retry_entry_metadata(first, issue.id)
      polled = poll_failure(first, issue.id, 1, metadata, {:retry_poll_failed, :timeout})
      assert Orchestrator.retry_history_for_test(polled)[issue.id].primary_failure_count == 1

      # Quota worker failure #2 → count 2 → fallback.
      second = fail(%{polled | retry_attempts: %{}}, issue, :provider_quota)

      try do
        retry = Map.fetch!(second.retry_attempts, issue.id)
        assert retry.route == :fallback
        assert retry.primary_failure_count == 2
      after
        cancel_timers(polled)
        cancel_timers(second)
      end
    end
  end

  describe "success and continuation semantics" do
    test "normal completion resets the route state so the next sequence starts primary", %{root: root} do
      enable_fallback()
      issue = test_issue("ISS-FB-DONE", "MT-FB-DONE")

      latched = latched_state(issue)

      ref = make_ref()

      state = %{
        latched
        | running:
            Map.put(latched.running, issue.id, %{
              pid: self(),
              ref: ref,
              identifier: issue.identifier,
              issue: issue,
              started_at: DateTime.utc_now()
            })
      }

      assert {:noreply, next} = Orchestrator.handle_info({:DOWN, ref, :process, self(), :normal}, state)

      try do
        retry = Map.fetch!(next.retry_attempts, issue.id)
        assert retry.route == :primary
        assert retry.primary_failure_count == 0

        refute Map.has_key?(Orchestrator.retry_history_for_test(next), issue.id)
        assert Orchestrator.next_dispatch_route_for_test(next, issue.id) == :primary
        assert {:error, :not_found} = RetryStore.read_record(root, issue.id)
      after
        cancel_timers(next)
      end
    end
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
