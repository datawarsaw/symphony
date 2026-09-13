defmodule SymphonyElixir.OperationalStatusTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RetryStore
  alias SymphonyElixirWeb.Presenter

  @moduletag :operational_status

  # ── MIC-195 Slice D: deterministic operational status projection ──────────
  #
  # Every test drives the same authoritative path the operator uses: the
  # orchestrator snapshot (or, for restart reconstruction, the existing
  # recovery helper). Synthetic state is injected through :sys.replace_state
  # exactly like orchestrator_status_test.exs; nothing in the projection
  # writes to or mutates that state.

  describe "required statuses" do
    test "active primary worker projects RUNNING" do
      issue = test_issue("issue-run-primary", "MT-9001")
      {:ok, pid} = start_orchestrator(:run_primary)

      inject_state(pid, %{
        running: %{"issue-run-primary" => running_entry(issue, :primary)}
      })

      assert_statuses(pid, %{"issue-run-primary" => :running})
      assert running_row_status(pid, "issue-run-primary") == :running
    end

    test "active fallback worker projects FALLBACK_RUNNING" do
      issue = test_issue("issue-run-fallback", "MT-9002")
      {:ok, pid} = start_orchestrator(:run_fallback)

      inject_state(pid, %{
        running: %{"issue-run-fallback" => running_entry(issue, :fallback)}
      })

      assert_statuses(pid, %{"issue-run-fallback" => :fallback_running})
    end

    test "ordinary transient retry wait projects WAITING_RETRY" do
      {:ok, pid} = start_orchestrator(:wait_transient)

      inject_state(pid, %{
        retry_attempts: %{"issue-wait-transient" => retry_entry("MT-9003")},
        retry_history: %{
          "issue-wait-transient" => %{
            last_failure_class: :transient_worker_failure,
            route: :primary,
            primary_failure_count: 0
          }
        }
      })

      assert_statuses(pid, %{"issue-wait-transient" => :waiting_retry})
    end

    test "continuation wait without failure history projects WAITING_RETRY" do
      {:ok, pid} = start_orchestrator(:wait_continuation)

      inject_state(pid, %{
        retry_attempts: %{"issue-wait-continuation" => retry_entry("MT-9004")}
      })

      assert_statuses(pid, %{"issue-wait-continuation" => :waiting_retry})
    end

    test "provider quota retry wait projects PROVIDER_UNAVAILABLE" do
      {:ok, pid} = start_orchestrator(:wait_quota)

      inject_state(pid, %{
        retry_attempts: %{"issue-wait-quota" => retry_entry("MT-9005", route: :primary)},
        retry_history: %{
          "issue-wait-quota" => %{
            last_failure_class: :provider_quota,
            route: :primary,
            primary_failure_count: 1
          }
        }
      })

      assert_statuses(pid, %{"issue-wait-quota" => :provider_unavailable})
    end

    test "model unavailable retry wait projects PROVIDER_UNAVAILABLE" do
      {:ok, pid} = start_orchestrator(:wait_model)

      inject_state(pid, %{
        retry_attempts: %{"issue-wait-model" => retry_entry("MT-9006", route: :primary)},
        retry_history: %{
          "issue-wait-model" => %{
            last_failure_class: :model_unavailable,
            route: :primary,
            primary_failure_count: 1
          }
        }
      })

      assert_statuses(pid, %{"issue-wait-model" => :provider_unavailable})
    end

    test "parked retry envelope projects PARKED" do
      {:ok, pid} = start_orchestrator(:parked)

      inject_state(pid, %{
        parked: %{"issue-parked" => parked_entry("MT-9007", :max_attempts)}
      })

      assert_statuses(pid, %{"issue-parked" => :parked})
    end

    test "reconciliation/safety block projects BLOCKED" do
      issue = test_issue("issue-blocked", "MT-9008")
      {:ok, pid} = start_orchestrator(:blocked)

      inject_state(pid, %{
        blocked: %{"issue-blocked" => blocked_entry(issue, "repository mismatch")}
      })

      assert_statuses(pid, %{"issue-blocked" => :blocked})
    end
  end

  describe "deterministic precedence" do
    test "blocked overrides a running worker" do
      issue = test_issue("issue-blocked-running", "MT-9010")
      {:ok, pid} = start_orchestrator(:blocked_over_running)

      inject_state(pid, %{
        running: %{"issue-blocked-running" => running_entry(issue, :primary)},
        blocked: %{"issue-blocked-running" => blocked_entry(issue, "reconciliation block")}
      })

      assert_statuses(pid, %{"issue-blocked-running" => :blocked})
    end

    test "parked overrides a scheduled retry" do
      {:ok, pid} = start_orchestrator(:parked_over_retry)

      inject_state(pid, %{
        retry_attempts: %{"issue-parked-retry" => retry_entry("MT-9011")},
        retry_history: %{
          "issue-parked-retry" => %{last_failure_class: :provider_quota, route: :primary}
        },
        parked: %{"issue-parked-retry" => parked_entry("MT-9011", :max_identical)}
      })

      assert_statuses(pid, %{"issue-parked-retry" => :parked})
    end

    test "fallback running overrides provider failure history" do
      issue = test_issue("issue-fallback-history", "MT-9012")
      {:ok, pid} = start_orchestrator(:fallback_over_history)

      inject_state(pid, %{
        running: %{"issue-fallback-history" => running_entry(issue, :fallback)},
        retry_history: %{
          "issue-fallback-history" => %{
            last_failure_class: :provider_outage,
            route: :fallback,
            primary_failure_count: 2
          }
        }
      })

      assert_statuses(pid, %{"issue-fallback-history" => :fallback_running})
    end

    test "primary running overrides stale provider/fallback history" do
      issue = test_issue("issue-stale-history", "MT-9013")
      {:ok, pid} = start_orchestrator(:running_over_history)

      inject_state(pid, %{
        running: %{"issue-stale-history" => running_entry(issue, :primary)},
        retry_history: %{
          "issue-stale-history" => %{
            last_failure_class: :provider_rate_limit,
            route: :fallback,
            primary_failure_count: 2
          }
        }
      })

      assert_statuses(pid, %{"issue-stale-history" => :running})
    end
  end

  describe "sequence reset and stall preservation" do
    test "ended failure sequence with a fresh primary run projects RUNNING" do
      # Emulates the post-completion lifecycle: complete_issue deletes the
      # history, so a fresh dispatch starts primary with no provider/fallback
      # state to leak.
      issue = test_issue("issue-fresh-sequence", "MT-9014")
      {:ok, pid} = start_orchestrator(:fresh_sequence)

      inject_state(pid, %{
        running: %{"issue-fresh-sequence" => running_entry(issue, :primary)}
      })

      assert_statuses(pid, %{"issue-fresh-sequence" => :running})
    end

    test "stall restart preserves the fallback/provider sequence in the projection" do
      # Stall restarts deliberately keep the failure sequence: history and the
      # scheduled retry both still carry the latched fallback route and the
      # provider class that drove it, so the wait must keep projecting from
      # that existing state.
      {:ok, pid} = start_orchestrator(:stall_preserved)

      inject_state(pid, %{
        retry_attempts: %{"issue-stalled" => retry_entry("MT-9015", route: :fallback)},
        retry_history: %{
          "issue-stalled" => %{
            last_failure_class: :provider_quota,
            route: :fallback,
            primary_failure_count: 2
          }
        }
      })

      assert_statuses(pid, %{"issue-stalled" => :provider_unavailable})
    end
  end

  describe "projection invariants" do
    test "projection is idempotent and does not mutate lifecycle state" do
      issue = test_issue("issue-invariant", "MT-9016")
      {:ok, pid} = start_orchestrator(:invariant)

      issue_id = "issue-invariant"

      inject_state(pid, %{
        running: %{issue_id => running_entry(issue, :primary)},
        retry_attempts: %{"issue-wait" => retry_entry("MT-9017", route: :fallback)},
        retry_history: %{
          "issue-wait" => %{last_failure_class: :provider_quota, route: :fallback}
        },
        parked: %{"issue-parked" => parked_entry("MT-9018", :max_age)},
        blocked: %{"issue-blocked" => blocked_entry(test_issue("issue-blocked-2", "MT-9019"), "blocked")}
      })

      lifecycle_maps = fn pid ->
        state = :sys.get_state(pid)
        Map.take(state, [:running, :retry_attempts, :retry_history, :parked, :blocked, :claimed])
      end

      before_maps = lifecycle_maps.(pid)
      first = GenServer.call(pid, :snapshot)
      second = GenServer.call(pid, :snapshot)

      assert first.operational_status == second.operational_status

      assert first.operational_status == %{
               issue_id => :running,
               "issue-wait" => :provider_unavailable,
               "issue-parked" => :parked,
               "issue-blocked" => :blocked
             }

      assert lifecycle_maps.(pid) == before_maps
    end

    test "issues in no lifecycle map get no fabricated status" do
      {:ok, pid} = start_orchestrator(:empty)

      assert GenServer.call(pid, :snapshot).operational_status == %{}
    end
  end

  describe "restart reconstruction" do
    @describetag :tmp_retry_store

    setup do
      root = Path.join(System.tmp_dir!(), "mic195-obs-#{:erlang.unique_integer([:positive])}")
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

    test "recovered parked record projects PARKED from the existing durable state", %{root: root} do
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      record =
        RetryStore.build_record(%{
          issue_id: "ISS-OBS-PARK",
          identifier: "MT-OBS-PARK",
          status: "parked",
          failure_class: "AUTH_UNAVAILABLE",
          attempt_count: 3,
          identical_failure_count: 3,
          first_failure_at: now,
          last_failure_at: now,
          last_error: "auth down",
          workspace_path: "/tmp/ws-obs-park",
          workspace_root: root
        })

      :ok = RetryStore.write_record(root, record)

      recovered = Orchestrator.recover_retry_records_for_test(fresh_state())

      try do
        assert Orchestrator.operational_statuses_for_test(recovered) == %{"ISS-OBS-PARK" => :parked}
      after
        cancel_timers(recovered)
      end
    end

    test "recovered fallback retry sequence projects PROVIDER_UNAVAILABLE without a second store", %{
      root: root
    } do
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      record =
        RetryStore.build_record(%{
          issue_id: "ISS-OBS-RETRY",
          identifier: "MT-OBS-RETRY",
          status: "retrying",
          failure_class: "PROVIDER_QUOTA",
          attempt_count: 2,
          identical_failure_count: 2,
          first_failure_at: now,
          last_failure_at: now,
          last_error: "quota exceeded",
          workspace_path: "/tmp/ws-obs-retry",
          workspace_root: root,
          route: :fallback,
          primary_failure_count: 2,
          worker_identity: "never_spawned"
        })

      :ok = RetryStore.write_record(root, record)

      recovered = Orchestrator.recover_retry_records_for_test(fresh_state())

      try do
        assert Map.has_key?(recovered.retry_attempts, "ISS-OBS-RETRY")
        assert Orchestrator.operational_statuses_for_test(recovered) == %{"ISS-OBS-RETRY" => :provider_unavailable}
      after
        cancel_timers(recovered)
      end
    end

    test "no recovered sequence fabricates no provider/fallback state" do
      assert Orchestrator.operational_statuses_for_test(fresh_state()) == %{}
    end
  end

  describe "observability API projection" do
    test "state payload exposes operational statuses and parked count" do
      running_issue = test_issue("issue-api-run", "MT-9020")
      fallback_issue = test_issue("issue-api-fallback", "MT-9021")
      {:ok, pid} = start_orchestrator(:api)
      name = Module.concat(__MODULE__, :api)

      inject_state(pid, %{
        running: %{
          "issue-api-run" => running_entry(running_issue, :primary),
          "issue-api-fallback" => running_entry(fallback_issue, :fallback)
        },
        retry_attempts: %{"issue-api-wait" => retry_entry("MT-9022")},
        retry_history: %{
          "issue-api-wait" => %{last_failure_class: :transient_worker_failure, route: :primary}
        },
        parked: %{"issue-api-parked" => parked_entry("MT-9023", :max_attempts)}
      })

      payload = Presenter.state_payload(name, 5_000)

      assert payload.counts.parked == 1

      assert payload.operational_status == %{
               "issue-api-run" => "RUNNING",
               "issue-api-fallback" => "FALLBACK_RUNNING",
               "issue-api-wait" => "WAITING_RETRY",
               "issue-api-parked" => "PARKED"
             }

      fallback_row = Enum.find(payload.running, &(&1.issue_id == "issue-api-fallback"))
      assert fallback_row.operational_status == "FALLBACK_RUNNING"
      retry_row = Enum.find(payload.retrying, &(&1.issue_id == "issue-api-wait"))
      assert retry_row.operational_status == "WAITING_RETRY"
    end

    test "issue payload reports a parked issue with its operational status" do
      {:ok, _pid} = start_orchestrator(:api_issue)
      name = Module.concat(__MODULE__, :api_issue)

      inject_state(name, %{
        parked: %{"issue-api-parked-2" => parked_entry("MT-9024", :auth_unavailable, "AUTH_UNAVAILABLE")}
      })

      assert {:ok, body} = Presenter.issue_payload("MT-9024", name, 5_000)
      assert body.status == "parked"
      assert body.operational_status == "PARKED"
      assert body.parked.stop_reason == :auth_unavailable
      assert body.parked.failure_class == "AUTH_UNAVAILABLE"
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp fresh_state, do: %Orchestrator.State{}

  defp test_issue(id, identifier) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Operational status " <> identifier,
      description: "MIC-195 Slice D projection",
      state: "In Progress",
      url: "https://example.org/issues/" <> identifier,
      dispatchable: true
    }
  end

  defp start_orchestrator(tag) do
    orchestrator_name = Module.concat(__MODULE__, tag)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    {:ok, pid}
  end

  defp inject_state(pid, overrides) do
    initial_state = :sys.get_state(pid)

    :sys.replace_state(pid, fn _ -> Map.merge(initial_state, overrides) end)

    :ok
  end

  defp running_entry(issue, route) do
    %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      worker_host: nil,
      workspace_path: nil,
      session_id: nil,
      route: route,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_app_server_pid: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      started_at: DateTime.utc_now()
    }
  end

  defp retry_entry(identifier, opts \\ []) do
    %{
      attempt: 2,
      timer_ref: nil,
      retry_token: nil,
      due_at_ms: System.monotonic_time(:millisecond) + 5_000,
      identifier: identifier,
      issue_url: "https://example.org/issues/" <> identifier,
      error: "agent exited: {:error, :boom}",
      worker_host: nil,
      workspace_path: nil,
      workspace_root: nil,
      route: Keyword.get(opts, :route, :primary),
      primary_failure_count: Keyword.get(opts, :primary_failure_count, 0)
    }
  end

  defp parked_entry(identifier, stop_reason, failure_class \\ "PROVIDER_QUOTA") do
    %{
      identifier: identifier,
      failure_class: failure_class,
      stop_reason: stop_reason,
      attempt_count: 3,
      identical_failure_count: 1,
      first_failure_at: DateTime.to_iso8601(DateTime.utc_now()),
      last_failure_at: DateTime.to_iso8601(DateTime.utc_now()),
      error: "agent exited: quota",
      worker_host: nil,
      workspace_path: "/tmp/ws-" <> String.downcase(identifier),
      route: :primary,
      primary_failure_count: 1,
      parked_at: DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  defp blocked_entry(issue, error) do
    %{
      identifier: issue.identifier,
      issue: issue,
      worker_host: nil,
      workspace_path: nil,
      session_id: nil,
      error: error,
      discovery_result: nil,
      blocked_at: DateTime.utc_now(),
      last_codex_message: nil,
      last_codex_event: nil,
      last_codex_timestamp: nil
    }
  end

  defp assert_statuses(pid, expected) do
    snapshot = GenServer.call(pid, :snapshot)
    assert snapshot.operational_status == expected

    for row <- snapshot.running ++ snapshot.retrying ++ snapshot.blocked ++ snapshot.parked do
      assert Map.get(row, :operational_status) == Map.fetch!(expected, row.issue_id)
    end
  end

  defp running_row_status(pid, issue_id) do
    snapshot = GenServer.call(pid, :snapshot)
    row = Enum.find(snapshot.running, &(&1.issue_id == issue_id))
    row.operational_status
  end

  defp cancel_timers(%Orchestrator.State{retry_attempts: attempts}) do
    Enum.each(attempts, fn {_id, entry} ->
      case Map.get(entry, :timer_ref) do
        ref when is_reference(ref) -> Process.cancel_timer(ref)
        _ -> :ok
      end
    end)
  end
end
