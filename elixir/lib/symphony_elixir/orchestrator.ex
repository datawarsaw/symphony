defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls the configured issue tracker and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{AgentRunner, Config, RepositoryRouter, StatusDashboard, Steering, Tracker, Workspace}
  alias SymphonyElixir.{DispatchRouter, FailureClass, LaunchMarker, RetryPolicy, RetryStore, WorkerContainment, WorkerFence}
  alias SymphonyElixir.Wake.Ledger
  alias SymphonyElixir.Codex.WorkerRouting
  alias SymphonyElixir.Tracker.Issue

  @continuation_retry_delay_ms 1_000
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  # MIC-10 STEER != CONTROL: bounded in-memory ledger of CONTROL receipts.
  # CONTROL is the host-owned lifecycle authority (SymphonyElixir.Control);
  # STEER is operator text for the running worker (SymphonyElixir.Steering)
  # delivered at turn boundaries. The ledger is not a durable store — restart
  # loses operator convenience state, never the MIC-223 fail-closed boundary.
  @control_ledger_limit 50
  # Bounded wait for a managed worker's termination receipt after a CONTROL
  # stop. Defaults to the MIC-223 stop budget (grace + hard-terminate drain);
  # the env seam mirrors WorkerContainment's own test seam so tests can
  # shrink the deadline without touching policy.
  @control_evidence_budget_env :control_termination_evidence_budget_ms
  @control_evidence_poll_ms 50
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      task_supervisor: SymphonyElixir.TaskSupervisor,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      blocked: %{},
      retry_attempts: %{},
      parked: %{},
      retry_history: %{},
      resumed_issues: MapSet.new(),
      orphaned_workspaces: [],
      startup_reconciled: false,
      wake_ledger: nil,
      codex_totals: nil,
      codex_rate_limits: nil,
      # MIC-10 STEER != CONTROL: bounded in-memory ledger of CONTROL receipts
      # (SymphonyElixir.Control). Operator convenience state, not a safety
      # store: losing it across a restart can only ever deny a relaunch
      # (fail closed), never grant one.
      control_ledger: []
    ]
  end

  @typedoc """
  Operator-visible status for one issue (MIC-195 Slice D projection).

  Derived read-only from the authoritative lifecycle maps — never persisted,
  never consulted by any retry, route, park, block, or tracker decision.
  """
  @type operational_status :: :running | :fallback_running | :waiting_retry | :provider_unavailable | :parked | :blocked

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    case Config.settings() do
      {:ok, config} ->
        now_ms = System.monotonic_time(:millisecond)

        state = %State{
          poll_interval_ms: config.polling.interval_ms,
          max_concurrent_agents: config.agent.max_concurrent_agents,
          next_poll_due_at_ms: now_ms,
          poll_check_in_progress: false,
          tick_timer_ref: nil,
          tick_token: nil,
          task_supervisor: Keyword.get(opts, :task_supervisor, SymphonyElixir.TaskSupervisor),
          codex_totals: @empty_codex_totals,
          codex_rate_limits: nil
        }

        run_terminal_workspace_cleanup()

        # MIC-10: the wake ledger must be attached before any wake-producing
        # startup path runs — reconciliation mismatches and retry-record fence
        # verdicts below observe wakes, and a nil ledger silently drops them.
        state = recover_wake_ledger(state)
        state = run_startup_reconciliation(state)
        state = recover_retry_records(state)
        state = schedule_tick(state, 0)

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    state = observe_wake(state, :poll_tick, nil, evidence: "cycle")
    state = maybe_dispatch(state)
    state = schedule_tick(state, state.poll_interval_ms)
    state = %{state | poll_check_in_progress: false}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        state = record_session_completion_totals(state, running_entry)
        session_id = running_entry_session_id(running_entry)

        state = handle_agent_down(reason, state, issue_id, running_entry, session_id)

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])
          |> maybe_put_runtime_value(:workspace_root, runtime_info[:workspace_root])

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  # MIC-223 termination evidence, sent by the agent task before its DOWN
  # message. Stored on the running entry so the retry/cleanup decisions below
  # can enforce: no workspace reuse until TERMINATED_CONFIRMED.
  def handle_info({:worker_termination, issue_id, termination_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(termination_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_identity, termination_info[:worker_identity])
          |> maybe_put_runtime_value(:worker_termination, summarize_termination(termination_info[:worker_termination]))
          |> maybe_put_runtime_value(:termination_expectation, normalize_expectation(termination_info[:termination_expectation]))

        case updated_running_entry[:worker_termination] do
          %{status: :TERMINATION_UNCONFIRMED} ->
            Logger.error("Worker termination UNCONFIRMED for issue_id=#{issue_id}; workspace reuse/cleanup will fail closed evidence=#{inspect(updated_running_entry[:worker_termination])}")

          _ ->
            :ok
        end

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  # MIC-10 STEER != CONTROL: asynchronous finalization of a CONTROL terminate
  # against the attempt's MIC-223 termination evidence. The watcher only
  # collects evidence; the fail-closed decision itself is made here, through
  # WorkerContainment.reuse_gate/2 — the single workspace-reuse authority.
  def handle_info({:control_termination_evidence, control_id, issue_id, attempt_id, confirmation}, state) do
    case find_pending_control_receipt(state, control_id, issue_id, attempt_id) do
      nil ->
        Logger.warning("Discarding stale CONTROL termination evidence: control_id=#{control_id} issue_id=#{inspect(issue_id)} attempt_id=#{inspect(attempt_id)}")

        {:noreply, state}

      receipt ->
        expectation = Map.get(receipt.evidence, :termination_expectation)
        verdict = WorkerContainment.reuse_gate(confirmation, expectation)
        outcome = if verdict == :allowed, do: :terminated, else: :termination_unconfirmed

        # Successful-completion semantics: once the gate accepts durable
        # termination evidence the marker's job is done; clear it so the next
        # dispatch starts from a clean fence. An unconfirmed outcome keeps the
        # marker as evidence and the resume/cleanup gates fail closed.
        if outcome == :terminated do
          LaunchMarker.clear(Map.get(receipt.evidence, :worker_identity))
        end

        finalized =
          receipt
          |> Map.put(:outcome, outcome)
          |> Map.put(:completed_at, DateTime.utc_now())
          |> Map.put(:evidence, Map.merge(receipt.evidence, %{worker_termination: summarize_termination(confirmation), reuse_gate: verdict}))

        Logger.info(
          "Control termination finalized: control_id=#{control_id} issue_id=#{issue_id} attempt_id=#{inspect(attempt_id)} " <>
            "outcome=#{inspect(outcome)} reuse_gate=#{inspect(verdict)}"
        )

        {:noreply, replace_control_receipt(state, finalized)}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:discovery_completed, issue_id, verdict}, %{running: running} = state) do
    case Map.fetch(running, issue_id) do
      {:ok, entry} ->
        {:noreply, %{state | running: Map.put(running, issue_id, Map.put(entry, :discovery_result, verdict))}}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp handle_agent_down(:normal, state, issue_id, %{discovery_result: verdict} = entry, _session_id) do
    state =
      observe_wake(state, :discovery_needs_decision, issue_id,
        evidence: "verdict:#{verdict}",
        attempt_id: running_entry_session_id(entry)
      )

    block_issue_from_entry(state, issue_id, entry, "Discovery #{verdict}; awaiting a separate lifecycle action")
  end

  defp handle_agent_down(:normal, state, issue_id, running_entry, session_id) do
    if input_required_blocker?(running_entry) do
      block_input_required_agent_down(state, issue_id, running_entry, session_id, :normal)
    else
      Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

      state
      |> complete_issue(issue_id)
      |> schedule_issue_retry(issue_id, 1, %{
        identifier: running_entry.identifier,
        issue_url: running_entry.issue.url,
        delay_type: :continuation,
        worker_host: Map.get(running_entry, :worker_host),
        workspace_path: Map.get(running_entry, :workspace_path),
        workspace_root: Map.get(running_entry, :workspace_root)
      })
    end
  end

  defp handle_agent_down(reason, state, issue_id, running_entry, session_id) do
    if input_required_blocker?(running_entry) do
      block_input_required_agent_down(state, issue_id, running_entry, session_id, reason)
    else
      retry_agent_down(state, issue_id, running_entry, session_id, reason)
    end
  end

  defp block_input_required_agent_down(state, issue_id, running_entry, session_id, reason) do
    error = blocker_error(running_entry, "agent exited: #{inspect(reason)}")

    state = observe_wake(state, :human_decision_required, issue_id, evidence: "input_required", attempt_id: session_id)

    Logger.warning("Agent task blocked for issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} session_id=#{session_id}: #{error}")

    block_issue_from_entry(state, issue_id, running_entry, error)
  end

  defp retry_agent_down(state, issue_id, running_entry, session_id, reason) do
    {decision, class, history, state} = note_failure(state, issue_id, reason)
    {decision, history, state} = apply_fallback_decision(state, issue_id, class, history, decision, running_entry)
    error = "agent exited: #{inspect(reason)}"
    Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)} failure_class=#{FailureClass.to_name(class)}")

    metadata = %{
      identifier: running_entry.identifier,
      issue_url: running_entry.issue.url,
      error: error,
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      workspace_root: Map.get(running_entry, :workspace_root),
      worker_identity: Map.get(running_entry, :worker_identity),
      termination_expectation: Map.get(running_entry, :termination_expectation),
      failure_class: FailureClass.to_name(class),
      attempt_count: Map.get(history, :attempt_count, 1),
      identical_failure_count: Map.get(history, :identical_failure_count, 1),
      first_failure_at: Map.get(history, :first_failure_at_dt),
      reset_in_ms: FailureClass.reset_in_ms(reason),
      route: Map.get(history, :route, :primary),
      primary_failure_count: Map.get(history, :primary_failure_count, 0)
    }

    state =
      observe_wake(state, :worker_failed, issue_id,
        evidence: "class:#{FailureClass.to_name(class)}:attempt:#{Map.get(metadata, :attempt_count)}",
        attempt_id: Map.get(metadata, :attempt_count)
      )

    case decision do
      {:park, stop_reason} ->
        park_issue(state, issue_id, running_entry, Map.put(metadata, :stop_reason, stop_reason))

      :retry ->
        # MIC-224/MIC-195 ordering: worker termination must be confirmed
        # before any retry/fallback worker is scheduled against the same
        # mutable workspace. Unconfirmed death parks fail-closed (claim, no
        # timer) and preserves the workspace and its receipt evidence. The
        # gate is expectation-aware: the running entry's PRE-LAUNCH
        # termination expectation decides whether nil evidence is compatible
        # (NOT_APPLICABLE/NEVER_STARTED) or fails closed
        # (MANAGED_CONFIRMATION_REQUIRED), independently of evidence the
        # shutdown path may have failed to emit.
        case WorkerContainment.reuse_gate(Map.get(running_entry, :worker_termination), Map.get(running_entry, :termination_expectation)) do
          :allowed ->
            next_attempt = next_retry_attempt_from_running(running_entry)
            schedule_issue_retry(state, issue_id, next_attempt, metadata)

          {:blocked, :worker_termination_unconfirmed} ->
            Logger.error("Failing closed for issue_id=#{issue_id}: previous worker termination unconfirmed; parking with claim, preserving workspace, no retry timer")

            park_issue(state, issue_id, running_entry, Map.put(metadata, :stop_reason, :worker_termination_unconfirmed))
        end
    end
  end

  # MIC-195 Slice C: after the envelope fold, decide whether the next attempt
  # stays on primary or switches to the configured fallback route. The pure
  # decision lives in RetryPolicy; the Orchestrator evaluates the gates it owns
  # (issue pins, the fallback label opt-in, and fallback seam availability,
  # probed through the DispatchRouter) and persists the outcome. Only reached
  # on :retry — a parked issue dispatches nothing, primary or fallback.
  defp apply_fallback_decision(state, _issue_id, _class, history, {:park, _stop_reason} = decision, _running_entry) do
    {decision, history, state}
  end

  defp apply_fallback_decision(%State{} = state, issue_id, class, history, :retry, running_entry) do
    route_state_before = route_state_from_history(history)
    {pinned, opt_in, fallback_available} = fallback_decision_gates(Map.get(running_entry, :issue))

    {route_decision, route_state} =
      RetryPolicy.fallback_route_decision(route_state_before, class,
        pinned: pinned,
        fallback_opt_in: opt_in,
        fallback_available: fallback_available
      )

    log_route_decision(issue_id, class, route_decision, route_state)

    history = Map.merge(history, %{route: route_state.route, primary_failure_count: route_state.primary_failure_count})
    {:retry, history, %{state | retry_history: Map.put(state.retry_history, issue_id, history)}}
  end

  defp log_route_decision(issue_id, class, route_decision, route_state) do
    case route_decision do
      {:switch_to_fallback, _switched} ->
        Logger.warning(
          "Fallback route selected for issue_id=#{issue_id} failure_class=#{FailureClass.to_name(class)} " <>
            "primary_failure_count=#{route_state.primary_failure_count}; next attempt uses the fallback route"
        )

      _stayed ->
        Logger.debug(
          "Route decision for issue_id=#{issue_id} failure_class=#{FailureClass.to_name(class)} " <>
            "decision=#{inspect(route_decision)} primary_failure_count=#{route_state.primary_failure_count}"
        )
    end
  end

  # Gate inputs for the pure fallback decision. Without an issue, every gate
  # fails closed. Pin detection reuses WorkerRouting's resolution rules — the
  # same authority DispatchRouter uses to set `Selection.pinned`. Fallback
  # availability is probed through DispatchRouter.materialize(:fallback, ...)
  # so the enabled/valid-model/valid-effort validation stays in exactly one
  # place; this reads config but decides nothing.
  defp fallback_decision_gates(%Issue{} = issue) do
    pinned = match?(:explicit_override, WorkerRouting.resolve([], issue).route_source)
    {pinned, RetryPolicy.fallback_opt_in(issue.labels), fallback_available?(issue)}
  end

  defp fallback_decision_gates(_issue), do: {false, :ambiguous, false}

  defp fallback_available?(%Issue{} = issue) do
    match?(%DispatchRouter.Selection{}, DispatchRouter.materialize(:fallback, issue, []))
  end

  # Persist only the bounded decision-relevant termination evidence.
  defp summarize_termination(%{status: status} = confirmation) when is_atom(status) do
    %{
      status: status,
      exit_code: Map.get(confirmation, :exit_code),
      reason: Map.get(confirmation, :reason)
    }
  end

  defp summarize_termination(_other), do: nil

  # Only the three canonical expectation states may refine the pre-launch
  # expectation; anything else is ignored. An unexpected value cannot silently
  # downgrade the gate because reuse_gate fails closed on unknown expectations.
  defp normalize_expectation(value) when value in [:NOT_APPLICABLE, :NEVER_STARTED, :MANAGED_CONFIRMATION_REQUIRED] do
    value
  end

  defp normalize_expectation(_other), do: nil

  defp maybe_dispatch(%State{} = state) do
    state =
      state
      |> ensure_startup_reconciled()
      |> reconcile_running_issues()
      |> reconcile_blocked_issues()
      |> reconcile_wake_ledger()

    with :ok <- Config.validate!(),
         {:ok, issues} <- Tracker.fetch_issues_by_states(Config.settings!().tracker.active_states),
         true <- available_slots(state) > 0 do
      choose_issues(issues, state)
    else
      {:error, :missing_linear_api_token} ->
        Logger.error("Tracker API token missing in WORKFLOW.md")
        state

      {:error, :missing_linear_project_slug} ->
        Logger.error("Tracker project scope missing in WORKFLOW.md")
        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")

        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

        state

      {:error, {:invalid_workflow_config, message}} ->
        Logger.error("Invalid WORKFLOW.md config: #{message}")
        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
        state

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.error("Failed to fetch from issue tracker: #{inspect(reason)}")
        state

      false ->
        state
    end
  end

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issues_by_ids(running_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_running_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_running_issue_ids(running_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  defp reconcile_blocked_issues(%State{} = state) do
    blocked_ids = Map.keys(state.blocked)

    if blocked_ids == [] do
      state
    else
      case Tracker.fetch_issues_by_ids(blocked_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_blocked_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_blocked_issue_ids(blocked_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh blocked issue states: #{inspect(reason)}; keeping blocked issues")

          state
      end
    end
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec reconcile_blocked_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_blocked_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_blocked_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec reconcile_missing_running_issue_ids_for_test(term(), [String.t()], [Issue.t()]) :: term()
  def reconcile_missing_running_issue_ids_for_test(%State{} = state, requested_issue_ids, issues)
      when is_list(requested_issue_ids) and is_list(issues) do
    reconcile_missing_running_issue_ids(state, requested_issue_ids, issues)
  end

  @doc false
  @spec reconcile_stalled_running_issues_for_test(term()) :: term()
  def reconcile_stalled_running_issues_for_test(%State{} = state) do
    reconcile_stalled_running_issues(state)
  end

  @doc false
  @spec handle_retry_issue_lookup_for_test(Issue.t(), term(), String.t(), non_neg_integer(), map()) ::
          term()
  def handle_retry_issue_lookup_for_test(%Issue{} = issue, %State{} = state, issue_id, attempt, metadata)
      when is_binary(issue_id) and is_integer(attempt) and attempt >= 0 and is_map(metadata) do
    {:noreply, updated_state} = handle_retry_issue_lookup(issue, state, issue_id, attempt, metadata)
    updated_state
  end

  @doc false
  @spec handle_retry_poll_failure_for_test(term(), String.t(), non_neg_integer(), map(), term()) ::
          term()
  def handle_retry_poll_failure_for_test(%State{} = state, issue_id, attempt, metadata, reason)
      when is_binary(issue_id) and is_integer(attempt) and attempt >= 0 and is_map(metadata) do
    handle_retry_poll_failure(state, issue_id, attempt, metadata, reason)
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec select_worker_host_for_test(term(), String.t() | nil) :: String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host)
  end

  @doc false
  @spec run_startup_reconciliation_for_test(term()) :: term()
  def run_startup_reconciliation_for_test(%State{} = state) do
    run_startup_reconciliation(state)
  end

  @doc false
  @spec orphaned_workspaces_for_test(term()) :: [Path.t()]
  def orphaned_workspaces_for_test(%State{orphaned_workspaces: orphans}), do: orphans

  @doc false
  @spec resumed_issues_for_test(term()) :: MapSet.t()
  def resumed_issues_for_test(%State{resumed_issues: resumed_issues}), do: resumed_issues

  @doc false
  @spec dispatch_issue_for_test(term(), Issue.t()) :: term()
  def dispatch_issue_for_test(%State{} = state, %Issue{} = issue) do
    do_dispatch_issue(state, issue, nil, nil)
  end

  @doc false
  @spec release_issue_claim_for_test(term(), String.t()) :: term()
  def release_issue_claim_for_test(%State{} = state, issue_id) do
    release_issue_claim(state, issue_id)
  end

  @spec orphaned_workspaces() :: [Path.t()] | :unavailable
  def orphaned_workspaces, do: orphaned_workspaces(__MODULE__)

  @spec orphaned_workspaces(GenServer.server()) :: [Path.t()] | :unavailable
  def orphaned_workspaces(server) do
    if Process.whereis(server) do
      GenServer.call(server, :orphaned_workspaces)
    else
      :unavailable
    end
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    state =
      observe_wake(state, :tracker_state_changed, issue.id,
        to_state: issue.state,
        evidence: "state:#{issue.state}:updated:#{tracker_updated_at(issue)}"
      )

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, true, clear_sequence?: true)

      !issue_routable?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false, clear_sequence?: true)

      active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false, clear_sequence?: true)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_blocked_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_blocked_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_blocked_issue_states(
      rest,
      reconcile_blocked_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_blocked_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    state =
      observe_wake(state, :tracker_state_changed, issue.id,
        to_state: issue.state,
        evidence: "state:#{issue.state}:updated:#{tracker_updated_at(issue)}"
      )

    cond do
      discovery_result_changed?(Map.get(state.blocked, issue.id), issue) ->
        release_issue_claim(state, issue.id)

      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Blocked issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; releasing block")
        fenced_workspace_cleanup(issue, Map.get(state.blocked, issue.id, %{}), issue.id)
        release_issue_claim(state, issue.id)

      !issue_routable?(issue) ->
        Logger.info("Blocked issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; releasing block")
        release_issue_claim(state, issue.id)

      active_issue_state?(issue.state, active_states) ->
        refresh_blocked_issue_state(state, issue)

      true ->
        Logger.info("Blocked issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; releasing block")
        release_issue_claim(state, issue.id)
    end
  end

  defp reconcile_blocked_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp discovery_result_changed?(%{discovery_result: result, issue: previous}, issue) when not is_nil(result) do
    fields = [:id, :title, :description, :labels, :parent, :project]
    not SymphonyElixir.Discovery.discovery?(issue) or Map.take(previous, fields) != Map.take(issue, fields)
  end

  defp discovery_result_changed?(_, _), do: false

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)
        terminate_running_issue(state_acc, issue_id, false, clear_sequence?: true)
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp reconcile_missing_blocked_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        Logger.info("Blocked issue no longer visible during state refresh: issue_id=#{issue_id}; releasing block")
        release_issue_claim(state_acc, issue_id)
      end
    end)
  end

  defp reconcile_missing_blocked_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp refresh_blocked_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.blocked, issue.id) do
      %{issue: _} = blocked_entry ->
        %{state | blocked: Map.put(state.blocked, issue.id, %{blocked_entry | issue: issue})}

      _ ->
        state
    end
  end

  # `clear_sequence?: true` marks a reconcile-driven lifecycle termination: the
  # issue's active failure sequence ends with the worker (see
  # `clear_failure_sequence/2`). Stall restarts deliberately omit the option —
  # a stall is part of the same active sequence and must preserve its route.
  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace, opts \\ []) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)

        stop_running_task(pid, ref, state.task_supervisor)

        if cleanup_workspace do
          fenced_workspace_cleanup(Map.get(running_entry, :issue, identifier), running_entry, issue_id)
        end

        state =
          if Keyword.get(opts, :clear_sequence?, false) do
            clear_failure_sequence(state, issue_id)
          else
            state
          end

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            blocked: Map.delete(state.blocked, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  # MIC-195 Slice C correction: a reconcile-driven lifecycle termination
  # (terminal, unroutable, non-active, or disappeared issue) ends the active
  # failure sequence. The latched route and the consecutive primary-failure
  # count describe one continuous sequence; once the lifecycle ends they must
  # not leak into a future dispatch, so the runtime route projection
  # (retry_history) and the durable RetryStore record are both cleared and the
  # next future dispatch starts from :primary with primary_failure_count 0.
  # Only reached with `clear_sequence?: true` — a stall restart is still part
  # of the same active sequence and keeps route, count, and envelope.
  @spec clear_failure_sequence(%State{}, String.t()) :: %State{}
  defp clear_failure_sequence(%State{} = state, issue_id) do
    state = cancel_retry_timer(state, issue_id)
    delete_retry_record_best_effort(issue_id)
    %{state | retry_history: Map.delete(state.retry_history, issue_id)}
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.settings!().codex.stall_timeout_ms

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          maybe_restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
        end)
    end
  end

  defp maybe_restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    if Map.has_key?(state.blocked, issue_id) do
      state
    else
      restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      if input_required_blocker?(running_entry) do
        error = blocker_error(running_entry, "stalled for #{elapsed_ms}ms after Codex requested operator input")

        Logger.warning("Issue blocked: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; #{error}")

        state =
          observe_wake(state, :human_decision_required, issue_id,
            evidence: "stalled_input_required",
            attempt_id: session_id
          )

        state
        |> record_session_completion_totals(running_entry)
        |> stop_and_block_issue(issue_id, running_entry, error)
      else
        Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

        next_attempt = next_retry_attempt_from_running(running_entry)

        state = observe_wake(state, :worker_stale, issue_id, evidence: "stall:#{elapsed_ms}", attempt_id: session_id)

        state
        |> terminate_running_issue(issue_id, false)
        |> schedule_issue_retry(issue_id, next_attempt, %{
          identifier: identifier,
          issue_url: running_entry.issue.url,
          error: "stalled for #{elapsed_ms}ms without codex activity"
        })
      end
    else
      state
    end
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
  end

  defp last_activity_timestamp(_running_entry), do: nil

  defp input_required_blocker?(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_event) in [:turn_input_required, :approval_required] or
      not is_nil(input_required_completion_outcome(Map.get(running_entry, :completion))) or
      codex_message_method(Map.get(running_entry, :last_codex_message)) ==
        "mcpServer/elicitation/request"
  end

  defp input_required_blocker?(_running_entry), do: false

  defp input_required_completion_outcome(completion) when is_map(completion) do
    outcome = Map.get(completion, :outcome) || Map.get(completion, "outcome")
    normalize_input_required_outcome(outcome)
  end

  defp input_required_completion_outcome(_completion), do: nil

  defp normalize_input_required_outcome(outcome)
       when outcome in [:input_required, :needs_input, :approval_required],
       do: outcome

  defp normalize_input_required_outcome(outcome) when is_binary(outcome) do
    case outcome do
      "input_required" -> :input_required
      "needs_input" -> :needs_input
      "approval_required" -> :approval_required
      _ -> nil
    end
  end

  defp normalize_input_required_outcome(_outcome), do: nil

  defp blocker_error(running_entry, fallback) when is_map(running_entry) do
    codex_event_blocker_error(Map.get(running_entry, :last_codex_event)) ||
      completion_blocker_error(Map.get(running_entry, :completion)) ||
      codex_message_blocker_error(Map.get(running_entry, :last_codex_message)) ||
      fallback
  end

  defp blocker_error(_running_entry, fallback), do: fallback

  defp codex_event_blocker_error(:turn_input_required), do: "codex turn requires operator input"
  defp codex_event_blocker_error(:approval_required), do: "codex turn requires approval"
  defp codex_event_blocker_error(_event), do: nil

  defp completion_blocker_error(completion) do
    case input_required_completion_outcome(completion) do
      outcome when outcome in [:input_required, :needs_input] -> "codex turn requires operator input"
      :approval_required -> "codex turn requires approval"
      nil -> nil
    end
  end

  defp codex_message_blocker_error(message) do
    if codex_message_method(message) == "mcpServer/elicitation/request" do
      "codex MCP elicitation requires operator input"
    end
  end

  defp codex_message_method(%{message: %{"method" => method}}) when is_binary(method), do: method
  defp codex_message_method(%{message: %{method: method}}) when is_binary(method), do: method
  defp codex_message_method(%{"method" => method}) when is_binary(method), do: method
  defp codex_message_method(%{method: method}) when is_binary(method), do: method
  defp codex_message_method(_message), do: nil

  defp terminate_task(pid, task_supervisor) when is_pid(pid) do
    case Task.Supervisor.terminate_child(task_supervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid, _task_supervisor), do: :ok

  defp stop_running_task(pid, ref, task_supervisor) do
    if is_pid(pid) do
      terminate_task(pid, task_supervisor)
    end

    if is_reference(ref) do
      Process.demonitor(ref, [:flush])
    end

    :ok
  end

  defp stop_and_block_issue(%State{} = state, issue_id, running_entry, error) do
    stop_running_task(
      Map.get(running_entry, :pid),
      Map.get(running_entry, :ref),
      state.task_supervisor
    )

    block_issue_from_entry(state, issue_id, running_entry, error)
  end

  defp block_issue_from_entry(%State{} = state, issue_id, running_entry, error) do
    blocked_entry = %{
      issue_id: issue_id,
      identifier: Map.get(running_entry, :identifier, issue_id),
      issue: Map.get(running_entry, :issue),
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      workspace_root: Map.get(running_entry, :workspace_root),
      # MIC-10 CONTROL: the attempt identity of the stopped worker, so a
      # blocked (operator-held or stalled) issue still resolves `:current`
      # to the exact attempt its evidence binds to.
      retry_attempt: Map.get(running_entry, :retry_attempt),
      session_id: running_entry_session_id(running_entry),
      error: error,
      discovery_result: Map.get(running_entry, :discovery_result),
      blocked_at: DateTime.utc_now(),
      last_codex_message: Map.get(running_entry, :last_codex_message),
      last_codex_event: Map.get(running_entry, :last_codex_event),
      last_codex_timestamp: Map.get(running_entry, :last_codex_timestamp)
    }

    %{
      state
      | running: Map.delete(state.running, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id),
        claimed: MapSet.put(state.claimed, issue_id),
        blocked: Map.put(state.blocked, issue_id, blocked_entry)
    }
  end

  defp choose_issues(issues, state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    issues
    |> sort_issues_for_dispatch()
    |> Enum.reduce(state, fn issue, state_acc ->
      if should_dispatch_issue?(issue, state_acc, active_states, terminal_states) do
        dispatch_issue(state_acc, issue)
      else
        state_acc
      end
    end)
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{running: running, claimed: claimed, blocked: blocked} = state,
         active_states,
         terminal_states
       ) do
    candidate_issue?(issue, active_states, terminal_states) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      !Map.has_key?(blocked, issue.id) and
      !Map.has_key?(state.parked, issue.id) and
      available_slots(state) > 0 and
      state_slots_available?(issue, running) and
      worker_slots_available?(state)
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    Enum.all?([id, identifier, title, state_name], &present_string?/1) and
      issue_routable?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels) and
      match?({:ok, _route}, RepositoryRouter.resolve(issue, Config.settings!().routing))
  end

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp dispatch_issue(%State{} = state, issue, attempt \\ nil, preferred_worker_host \\ nil) do
    case refresh_issue_for_dispatch(issue) do
      {:ok, %Issue{} = refreshed_issue} ->
        do_dispatch_issue(state, refreshed_issue, attempt, preferred_worker_host)

      {:skip, _reason} ->
        state

      {:error, _reason} ->
        state
    end
  end

  defp refresh_issue_for_dispatch(issue) do
    case revalidate_issue_for_dispatch(issue, &Tracker.fetch_issues_by_ids/1, terminal_state_set()) do
      {:ok, %Issue{} = refreshed_issue} ->
        {:ok, refreshed_issue}

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        {:skip, :missing}

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        {:skip, refreshed_issue}

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host) do
    recipient = self()

    case select_worker_host(state, preferred_worker_host) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")
        state

      worker_host ->
        # Hardening slice resume gate: before dispatching — and in particular
        # before resuming into an EXISTING workspace — a prior launch marker
        # for this issue must be absent or its worker death positively proven
        # through the WorkerFence (MIC-223 termination receipt). LIVE and
        # UNKNOWN fail closed; death is never inferred from a missing BEAM
        # process, a missing task, elapsed time, workspace presence, or the
        # restart itself.
        case LaunchMarker.reuse_gate(issue.id) do
          :allowed ->
            classify_candidate_and_spawn(state, issue, attempt, recipient, worker_host)

          {:blocked, reason} ->
            block_dispatch_on_unproven_launch(state, issue, reason)
        end
    end
  end

  # Resume gate admitted the dispatch: classify the workspace (resume vs
  # fresh) and spawn, preserving the pre-existing classification semantics.
  defp classify_candidate_and_spawn(%State{} = state, issue, attempt, recipient, worker_host) do
    case Workspace.classify_candidate(issue, worker_host) do
      {:error, {:workspace_repository_mismatch, target, details}} ->
        error = "workspace repository identity mismatch for target #{target}: #{inspect(details)}"
        Logger.error("Dispatch failed closed for #{issue_context(issue)}: #{error}")
        block_reconciliation_mismatch(state, issue, error)

      {:error, {:workspace_not_viable, _workspace, _reason}} = error ->
        Logger.error("Dispatch failed closed for #{issue_context(issue)}: #{format_workspace_viability_error(error)}")
        block_workspace_viability(state, issue, error)

      {:ok, :resume, _workspace, _route} ->
        resumed? = MapSet.member?(state.resumed_issues, issue.id) or is_nil(attempt)
        spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host, resumed?)

      _fresh_or_unreadable ->
        state = %{state | resumed_issues: MapSet.delete(state.resumed_issues, issue.id)}
        spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host, false)
    end
  end

  # Resume gate fail-closed outcome: the previous worker's death is LIVE or
  # UNKNOWN (or the marker itself is unreadable), so no second worker may be
  # launched and nothing is scheduled. Mirrors the retry-path reuse-gate park:
  # claim + durable parked record, no retry timer, workspace preserved. The
  # marker stays in place; once a receipt proves the drain (or an operator
  # resolves it through CONTROL), the same gate re-admits dispatch.
  defp block_dispatch_on_unproven_launch(%State{} = state, %Issue{} = issue, reason) do
    Logger.error(
      "Dispatch failed closed for #{issue_context(issue)}: previous worker launch not proven terminated " <>
        "reason=#{inspect(reason)}; parking with claim, preserving workspace, no retry timer"
    )

    state = %{state | resumed_issues: MapSet.delete(state.resumed_issues, issue.id)}

    state =
      observe_wake(state, :worker_termination_unconfirmed, issue.id, evidence: "launch_gate:#{inspect(reason)}")

    park_issue(state, issue.id, nil, %{
      identifier: issue.identifier,
      issue_url: issue.url,
      error: "previous worker launch not proven terminated: #{inspect(reason)}",
      stop_reason: :worker_launch_unproven,
      worker_identity: LaunchMarker.stored_identity(issue.id),
      worker_host: nil
    })
  end

  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host, resumed?) do
    # MIC-195: the route intent is decided here — :primary for a fresh failure
    # sequence, :fallback when the latched fallback route says so (Slice C).
    # DispatchRouter materializes the selection, AgentRunner forwards it, and
    # AppServer consumes it without re-resolving routing policy.
    dispatch_opts = [attempt: attempt, worker_host: worker_host, resumed: resumed?]
    route = current_dispatch_route(state, issue.id)

    case DispatchRouter.materialize(route, issue, dispatch_opts) do
      %DispatchRouter.Selection{} = dispatch_selection ->
        Logger.info(
          "Dispatch route materialized for #{issue_context(issue)} intent=#{route} model=#{dispatch_selection.model} " <>
            "reasoning_effort=#{dispatch_selection.reasoning_effort} route_source=#{dispatch_selection.route_source} " <>
            "pinned=#{dispatch_selection.pinned} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}"
        )

        spawn_with_selection(state, issue, attempt, recipient, worker_host, resumed?, route, dispatch_selection, dispatch_opts)

      {:error, reason} ->
        handle_dispatch_route_materialization_error(state, issue, attempt, worker_host, route, reason)
    end
  end

  # The runtime route projection for the next dispatch. A failure sequence
  # without a route projection is primary; the latched :fallback survives in
  # the same projection (and in the durable RetryStore record) until the
  # sequence ends.
  @spec current_dispatch_route(%State{}, String.t()) :: DispatchRouter.intent()
  defp current_dispatch_route(%State{} = state, issue_id) do
    case Map.get(state.retry_history, issue_id) do
      %{route: :fallback} -> :fallback
      _route -> :primary
    end
  end

  defp spawn_with_selection(%State{} = state, issue, attempt, recipient, worker_host, resumed?, route, dispatch_selection, dispatch_opts) do
    case Task.Supervisor.start_child(state.task_supervisor, fn ->
           AgentRunner.run(issue, recipient, dispatch_opts ++ [dispatch_selection: dispatch_selection])
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        resumed_log = if resumed?, do: " (resumed)", else: ""
        Logger.info("Dispatching issue to agent#{resumed_log}: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")

        running =
          Map.put(state.running, issue.id, %{
            pid: pid,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            worker_host: worker_host,
            workspace_path: nil,
            workspace_root: nil,
            # MIC-223: the pre-launch termination expectation. Set BEFORE risky
            # worker execution via the same canonical predicate AppServer uses
            # to create the worker identity, so a managed attempt whose
            # shutdown path crashes still fails closed at the reuse gate
            # (nil evidence + MANAGED_CONFIRMATION_REQUIRED is denied).
            termination_expectation: WorkerContainment.termination_expectation(worker_host),
            session_id: nil,
            route: route,
            resumed: resumed?,
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
            retry_attempt: normalize_retry_attempt(attempt),
            started_at: DateTime.utc_now()
          })

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            resumed_issues: MapSet.delete(state.resumed_issues, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        state = %{state | resumed_issues: MapSet.delete(state.resumed_issues, issue.id)}

        schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          issue_url: issue.url,
          error: "failed to spawn agent: #{inspect(reason)}",
          worker_host: worker_host
        })
    end
  end

  # MIC-195 Slice C precondition: a failed DispatchRouter.materialize/3 (in
  # practice a failed fallback materialization) must never spawn a worker, must
  # never fabricate a successful primary route, and must never lose the retry
  # envelope. The failure folds into the global envelope as a transient worker
  # failure (ineligible for fallback, so the latched route is preserved), a
  # durable record is written, and the bounded envelope either schedules the
  # next attempt on the still-decided route or parks.
  @spec handle_dispatch_route_materialization_error(%State{}, Issue.t(), integer() | nil, String.t() | nil, DispatchRouter.intent(), term()) :: %State{}
  defp handle_dispatch_route_materialization_error(%State{} = state, issue, attempt, worker_host, route, reason) do
    Logger.error(
      "Dispatch route materialization failed closed for #{issue_context(issue)} route=#{route} " <>
        "reason=#{inspect(reason)}; no worker spawned"
    )

    # Classification input deliberately omits the materialization reason: the
    # reason text must never be able to reclassify this as a provider failure.
    {decision, class, history, state} =
      note_failure(state, issue.id, {:dispatch_route_materialization_failed, route})

    metadata = %{
      identifier: issue.identifier,
      issue_url: issue.url,
      error: "dispatch route materialization failed: #{inspect(reason)}",
      worker_host: worker_host,
      failure_class: FailureClass.to_name(class),
      attempt_count: Map.get(history, :attempt_count, 1),
      identical_failure_count: Map.get(history, :identical_failure_count, 1),
      first_failure_at: Map.get(history, :first_failure_at_dt),
      reset_in_ms: nil,
      route: Map.get(history, :route, :primary),
      primary_failure_count: Map.get(history, :primary_failure_count, 0)
    }

    case decision do
      {:park, stop_reason} ->
        park_issue(state, issue.id, nil, Map.put(metadata, :stop_reason, stop_reason))

      :retry ->
        next_attempt = if is_integer(attempt), do: attempt + 1, else: 1
        schedule_issue_retry(state, issue.id, next_attempt, metadata)
    end
  end

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp complete_issue(%State{} = state, issue_id) do
    delete_retry_record_best_effort(issue_id)

    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id),
        parked: Map.delete(state.parked, issue_id),
        retry_history: Map.delete(state.retry_history, issue_id)
    }
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = retry_delay(next_attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    issue_url = pick_retry_issue_url(previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)
    workspace_root = pick_retry_workspace_root(previous_retry, metadata)
    # MIC-195 Slice C: the latched route and the consecutive eligible-primary
    # count ride with the retry entry so durable records, later reschedules,
    # and the snapshot all agree on one resolved value. The runtime route
    # projection (retry_history) is the dispatch authority, so it is the final
    # fallback when the metadata and the previous entry carry no route.
    route =
      metadata[:route] || Map.get(previous_retry, :route) ||
        history_route(Map.get(state.retry_history, issue_id)) || :primary

    primary_failure_count =
      metadata[:primary_failure_count] || Map.get(previous_retry, :primary_failure_count) ||
        history_primary_failure_count(Map.get(state.retry_history, issue_id)) || 0

    metadata = Map.merge(metadata, %{route: route, primary_failure_count: primary_failure_count})

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt}) route=#{route}#{error_suffix}")

    new_state = %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            retry_token: retry_token,
            due_at_ms: due_at_ms,
            identifier: identifier,
            issue_url: issue_url,
            error: error,
            worker_host: worker_host,
            workspace_path: workspace_path,
            workspace_root: workspace_root,
            route: route,
            primary_failure_count: primary_failure_count
          })
    }

    persist_failure_retry_record(new_state, issue_id, next_attempt, delay_ms, metadata)
    new_state
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          issue_url: Map.get(retry_entry, :issue_url),
          error: Map.get(retry_entry, :error),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path),
          workspace_root: Map.get(retry_entry, :workspace_root),
          route: Map.get(retry_entry, :route, :primary),
          primary_failure_count: Map.get(retry_entry, :primary_failure_count, 0)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Tracker.fetch_issues_by_ids([issue_id]) do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        {:noreply, handle_retry_poll_failure(state, issue_id, attempt, metadata, reason)}
    end
  end

  # MIC-195 Slice C correction: a tracker/retry-poll failure is an orchestrator
  # scheduling hiccup, not a worker or provider failure. It still folds into
  # the pre-existing global retry envelope, but it never participates in the
  # Slice C route-state fold (`fold_route_state?: false`): a provider-shaped
  # poll error must not increment primary_failure_count or latch fallback, and
  # an opaque one must not reset the count to 0. The reschedule takes the
  # authoritative route state from the current history — never the pre-poll
  # retry metadata — so the retry entry and the durable RetryStore record carry
  # exactly the in-memory route/count after the poll failure.
  defp handle_retry_poll_failure(%State{} = state, issue_id, attempt, metadata, reason) do
    Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

    {decision, class, history, state} = note_failure(state, issue_id, {:retry_poll_failed, reason}, fold_route_state?: false)

    case decision do
      {:park, stop_reason} ->
        park_metadata =
          metadata
          |> Map.merge(%{
            failure_class: FailureClass.to_name(class),
            stop_reason: stop_reason,
            error: "retry poll failed: #{inspect(reason)}",
            attempt_count: Map.get(history, :attempt_count, 1),
            identical_failure_count: Map.get(history, :identical_failure_count, 1),
            first_failure_at: Map.get(history, :first_failure_at_dt),
            reset_in_ms: nil
          })

        park_issue(state, issue_id, nil, park_metadata)

      :retry ->
        reschedule_metadata =
          Map.merge(metadata, %{
            error: "retry poll failed: #{inspect(reason)}",
            route: Map.get(history, :route, :primary),
            primary_failure_count: Map.get(history, :primary_failure_count, 0)
          })

        schedule_issue_retry(state, issue_id, attempt + 1, reschedule_metadata)
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        fenced_workspace_cleanup(issue, metadata, issue_id)
        {:noreply, release_issue_claim(state, issue_id)}

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(identifier, worker_host)

  defp cleanup_issue_workspace(issue_or_identifier, metadata) when is_map(metadata) do
    case workspace_gate_preserved?(metadata) do
      nil ->
        case Map.get(metadata, :workspace_path) do
          workspace_path when is_binary(workspace_path) and workspace_path != "" ->
            Workspace.remove_recorded(
              workspace_path,
              Map.get(metadata, :worker_host),
              Map.get(metadata, :workspace_root)
            )

          _ ->
            cleanup_issue_workspace(issue_or_identifier, Map.get(metadata, :worker_host))
        end

      gate_name ->
        Logger.warning("Preserving #{gate_name} workspace #{inspect(Map.get(metadata, :workspace_path))} for #{inspect(Map.get(metadata, :identifier))}; skipping recorded cleanup")

        :ok
    end
  end

  defp cleanup_issue_workspace(%Issue{} = issue, worker_host) do
    Workspace.remove_issue_workspaces(issue, worker_host)
  end

  defp cleanup_issue_workspace(identifier, worker_host) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, worker_host)
  end

  defp cleanup_issue_workspace(_issue_or_identifier, _worker_host), do: :ok

  # Second cleanup gate, composed UNDER the LaunchMarker/WorkerFence fence in
  # fenced_workspace_cleanup/3: the fence first proves the previous worker's
  # death (no destructive cleanup while a launch is LIVE/UNKNOWN), then this
  # policy preserves workspaces parked by a fail-closed dispatch gate as
  # evidence for the operator — identity mismatches may hold foreign work, and
  # non-viable worktrees may need `mix symphony.workspace_repair`. Neither is
  # removed merely because the issue transition or terminal reconciliation
  # asks for cleanup; both gates must allow before anything is deleted.
  defp workspace_gate_preserved?(metadata) do
    cond do
      Map.get(metadata, :reconciliation_mismatch) == true -> "reconciliation-mismatch"
      Map.get(metadata, :viability_error) == true -> "not-viable"
      true -> nil
    end
  end

  # ── Hardening slice: fenced destructive workspace cleanup ──────────────────
  #
  # Every path that destructively cleans a workspace after an asynchronous
  # worker termination must first prove TERMINATED_CONFIRMED for the launch
  # recorded in the durable launch marker. No marker keeps the legacy behavior
  # (no managed worker launch to prove); a proven marker clears before legacy
  # cleanup; an unproven marker waits a bounded interval for the wrapper
  # receipt (the worker was often just stopped and its tree drains
  # asynchronously) and cleans only on positive proof; a timeout or corrupt
  # marker preserves the workspace fail-closed. Existing receipt evidence and
  # the WorkerFence decide — death is never inferred from task death, elapsed
  # time, or workspace state.
  @fenced_cleanup_evidence_poll_ms 50

  defp fenced_workspace_cleanup(issue_or_identifier, metadata, issue_id) do
    case LaunchMarker.cleanup_gate(issue_id) do
      :allowed ->
        LaunchMarker.clear(issue_id)
        cleanup_issue_workspace(issue_or_identifier, metadata)

      {:blocked, :worker_termination_unproven} ->
        spawn_fenced_cleanup_wait(issue_or_identifier, metadata, issue_id)

      {:blocked, reason} ->
        Logger.error(
          "Destructive workspace cleanup failed closed for issue_id=#{inspect(issue_id)}: worker launch not " <>
            "proven terminated reason=#{inspect(reason)}; preserving workspace"
        )

        :ok
    end
  end

  # Bounded detached drain wait: polls the marker's fence verdict (positive
  # receipt proof only) and cleans only on {:ok, :dead}. Never touches
  # orchestrator state — by the time this runs the issue has already left the
  # lifecycle maps; the watcher only settles the workspace itself.
  defp spawn_fenced_cleanup_wait(issue_or_identifier, metadata, issue_id) do
    spawn(fn ->
      deadline = System.monotonic_time(:millisecond) + fenced_cleanup_evidence_budget_ms()

      case await_drain_proof(issue_id, deadline) do
        {:ok, :dead} ->
          LaunchMarker.clear(issue_id)
          cleanup_issue_workspace(issue_or_identifier, metadata)

        _verdict ->
          Logger.error(
            "Destructive workspace cleanup failed closed for issue_id=#{inspect(issue_id)}: worker drain not " <>
              "proven within the evidence budget; preserving workspace"
          )
      end
    end)

    :ok
  end

  defp await_drain_proof(issue_id, deadline) do
    cond do
      verdict = proven_drain_verdict(issue_id) ->
        verdict

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :unknown}

      true ->
        Process.sleep(@fenced_cleanup_evidence_poll_ms)
        await_drain_proof(issue_id, deadline)
    end
  end

  defp proven_drain_verdict(issue_id) do
    case LaunchMarker.fence_verdict(issue_id) do
      {:ok, :dead} = verdict -> verdict
      {:error, :alive} = verdict -> verdict
      _unproven -> nil
    end
  end

  # Same budget shape as the CONTROL evidence watcher (grace + hard-terminate
  # drain) and the same test seam, so one knob bounds every asynchronous
  # receipt wait.
  defp fenced_cleanup_evidence_budget_ms do
    hard_budget = Application.get_env(:symphony_elixir, :worker_termination_hard_budget_ms, 20_000)
    WorkerContainment.grace_ms() + hard_budget
  end

  defp run_terminal_workspace_cleanup do
    case Tracker.fetch_issues_by_states(Config.settings!().tracker.terminal_states) do
      {:ok, issues} ->
        issues
        |> Enum.each(fn
          %Issue{} = issue ->
            fenced_workspace_cleanup(issue, %{}, issue.id)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
    end
  end

  defp ensure_startup_reconciled(%State{startup_reconciled: true} = state), do: state
  defp ensure_startup_reconciled(%State{} = state), do: run_startup_reconciliation(state)

  defp run_startup_reconciliation(%State{} = state) do
    reconcile_steering_inbox()

    case Tracker.fetch_issues_by_states(Config.settings!().tracker.active_states) do
      {:ok, active_issues} ->
        state = reconcile_startup_candidates(state, active_issues)
        orphans = scan_orphaned_workspaces(active_issues)
        %{state | orphaned_workspaces: orphans, startup_reconciled: true}

      {:error, reason} ->
        Logger.warning("Skipping startup active issue reconciliation; failed to fetch active issues: #{inspect(reason)}")
        state
    end
  end

  # MIC-10 steering inbox: PENDING steers survive restart; DELIVERED-but-
  # unacknowledged steers are retained durably but invalidated (STALE) because
  # their delivery session is gone and must never be re-delivered.
  defp reconcile_steering_inbox do
    summary = Steering.reconcile_after_restart(Config.local_workspace_root())

    if Enum.any?(Map.values(summary), &(&1 > 0)) do
      Logger.info("Steering inbox reconciled after restart: #{inspect(summary)}")
    end

    :ok
  rescue
    error ->
      Logger.warning("Steering inbox reconciliation skipped: #{inspect(error)}")
      :ok
  end

  defp steering_snapshot do
    Steering.snapshot_summary(Config.local_workspace_root())
  rescue
    _ -> %{entries: [], counts: %{}}
  end

  defp reconcile_startup_candidates(state, active_issues) do
    Enum.reduce(active_issues, state, fn issue, state_acc ->
      reconcile_startup_candidate(state_acc, issue)
    end)
  end

  defp reconcile_startup_candidate(state, %Issue{} = issue) do
    if candidate_routable?(issue) do
      case Workspace.classify_candidate(issue) do
        {:ok, :resume, workspace, _route} ->
          Logger.info("Startup reconciliation identified resumable workspace for #{issue_context(issue)} workspace=#{workspace}")
          %{state | resumed_issues: MapSet.put(state.resumed_issues, issue.id)}

        {:ok, :fresh, _workspace, _route} ->
          state

        {:error, {:workspace_repository_mismatch, target, details}} ->
          error = "workspace repository identity mismatch for target #{target}: #{inspect(details)}"
          Logger.error("Startup reconciliation failed closed for #{issue_context(issue)}: #{error}")
          state = observe_wake(state, :eligibility_action_required, issue.id, evidence: "reconciliation_mismatch")
          block_reconciliation_mismatch(state, issue, error)

        {:error, {:workspace_not_viable, _workspace, _reason}} = error ->
          Logger.error("Startup reconciliation failed closed for #{issue_context(issue)}: #{format_workspace_viability_error(error)}")
          state = observe_wake(state, :eligibility_action_required, issue.id, evidence: "workspace_not_viable")
          block_workspace_viability(state, issue, error)

        {:error, reason} ->
          Logger.warning("Startup reconciliation check failed for #{issue_context(issue)}: #{inspect(reason)}")
          state
      end
    else
      state
    end
  end

  defp candidate_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels) and
      match?({:ok, _route}, RepositoryRouter.resolve(issue, Config.settings!().routing))
  end

  defp format_workspace_viability_error({:error, {:workspace_not_viable, workspace, reason}}) do
    "workspace is structurally not viable path=#{workspace} reason=#{inspect(reason)}"
  end

  # Fail-closed parking for issues whose workspace failed a dispatch-time gate
  # (repository identity or structural viability). The marker field drives both
  # the blocked-issue surface and the cleanup skip in cleanup_issue_workspace/2:
  # gated workspaces are preserved as evidence for the operator and the bounded
  # `mix symphony.workspace_repair` command instead of being removed silently.
  defp block_workspace_gate(state, issue, error, marker) do
    workspace_path =
      case Workspace.workspace_path(issue) do
        {:ok, path} -> path
        _ -> nil
      end

    base_entry = %{
      issue_id: issue.id,
      identifier: issue.identifier,
      issue: issue,
      worker_host: nil,
      workspace_path: workspace_path,
      workspace_root: Config.local_workspace_root(),
      session_id: nil,
      error: error,
      discovery_result: nil,
      blocked_at: DateTime.utc_now(),
      last_codex_message: nil,
      last_codex_event: nil,
      last_codex_timestamp: nil
    }

    blocked_entry = Map.put(base_entry, marker, true)

    %{
      state
      | blocked: Map.put(state.blocked, issue.id, blocked_entry),
        claimed: MapSet.put(state.claimed, issue.id),
        resumed_issues: MapSet.delete(state.resumed_issues, issue.id)
    }
  end

  defp block_reconciliation_mismatch(state, issue, error) do
    block_workspace_gate(state, issue, error, :reconciliation_mismatch)
  end

  defp block_workspace_viability(state, issue, error) do
    block_workspace_gate(state, issue, error, :viability_error)
  end

  defp scan_orphaned_workspaces(active_issues) do
    local_workspace_root = Config.local_workspace_root()

    active_workspace_names =
      active_issues
      |> Enum.map(&Workspace.workspace_key/1)
      |> MapSet.new()

    case File.ls(local_workspace_root) do
      {:ok, entries} ->
        entries
        |> Enum.filter(fn entry ->
          full_path = Path.join(local_workspace_root, entry)
          File.dir?(full_path) and not MapSet.member?(active_workspace_names, entry)
        end)
        |> Enum.map(fn entry ->
          orphan_path = Path.join(local_workspace_root, entry)
          Logger.warning("Surviving workspace unrecognized or unowned by active issues: path=#{orphan_path}")
          orphan_path
        end)

      _ ->
        []
    end
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  # --- MIC-10 wake ledger: event observation and wake eligibility ------------

  # Test seam mirroring the other *_for_test wrappers: drives the same observe
  # path the runtime callbacks use without booting the GenServer.
  @doc false
  @spec observe_wake_for_test(term(), atom(), String.t() | nil, keyword()) :: term()
  def observe_wake_for_test(%State{} = state, kind, issue_id, opts \\ []) when is_atom(kind) and is_list(opts) do
    observe_wake(state, kind, issue_id, opts)
  end

  @doc false
  @spec reconcile_wake_ledger_for_test(term(), [String.t()]) :: {term(), non_neg_integer()}
  def reconcile_wake_ledger_for_test(%State{} = state, live_issue_ids) do
    case state.wake_ledger do
      nil ->
        {state, 0}

      ledger ->
        {ledger, stale_count} = Ledger.reconcile(ledger, live_issue_ids)
        {%{state | wake_ledger: ledger}, stale_count}
    end
  end

  defp observe_wake(%State{wake_ledger: nil} = state, _kind, _issue_id, _opts), do: state

  defp observe_wake(%State{} = state, kind, issue_id, opts) do
    {ledger, verdict} = Ledger.observe(state.wake_ledger, kind, issue_id, opts)

    case verdict do
      {:wake, receipt} ->
        Logger.warning("Wake emitted: kind=#{kind} issue_id=#{inspect(issue_id)} event_id=#{receipt.event_id}")
        notify_dashboard()

      {:suppress, receipt, reason} ->
        Logger.debug("Wake suppressed: kind=#{kind} issue_id=#{inspect(issue_id)} event_id=#{receipt.event_id} reason=#{reason}")
    end

    %{state | wake_ledger: ledger}
  end

  defp recover_wake_ledger(%State{} = state) do
    %{state | wake_ledger: Ledger.recover(retry_store_root())}
  end

  # Pending receipts whose issue left every live set (running/blocked/parked/
  # retry/claimed) are stale evidence: the transition resolved them.
  defp reconcile_wake_ledger(%State{wake_ledger: nil} = state), do: state

  defp reconcile_wake_ledger(%State{} = state) do
    live_issue_ids =
      Enum.uniq(
        Map.keys(state.running) ++
          Map.keys(state.blocked) ++
          Map.keys(state.parked) ++
          Map.keys(state.retry_attempts) ++
          MapSet.to_list(state.claimed)
      )

    {ledger, _stale_count} = Ledger.reconcile(state.wake_ledger, live_issue_ids)
    %{state | wake_ledger: ledger}
  end

  # Releasing the claim resolves whatever the issue was waiting on: pending
  # receipts are handled so their identities dedup any repeat observation.
  defp handle_wake_release(%State{wake_ledger: nil} = state, _issue_id), do: state

  defp handle_wake_release(%State{} = state, issue_id) do
    {ledger, _count} = Ledger.mark_issue_handled(state.wake_ledger, issue_id)
    %{state | wake_ledger: ledger}
  end

  defp tracker_updated_at(%Issue{updated_at: %DateTime{} = updated_at}), do: DateTime.to_unix(updated_at)
  defp tracker_updated_at(_issue), do: "nil"

  defp handle_active_retry(state, issue, attempt, metadata) do
    if retry_candidate_issue?(issue, terminal_state_set()) and
         dispatch_slots_available?(issue, state) and
         worker_slots_available?(state, metadata[:worker_host]) do
      case refresh_issue_for_dispatch(issue) do
        {:ok, %Issue{} = refreshed_issue} ->
          {:noreply, do_dispatch_issue(state, refreshed_issue, attempt, metadata[:worker_host])}

        {:skip, :missing} ->
          {:noreply, release_issue_claim(state, issue.id)}

        {:skip, %Issue{} = refreshed_issue} ->
          handle_retry_issue_lookup(refreshed_issue, state, issue.id, attempt, metadata)

        {:error, reason} ->
          {:noreply,
           schedule_issue_retry(
             state,
             issue.id,
             attempt + 1,
             Map.merge(metadata, %{
               identifier: issue.identifier,
               error: "retry dispatch refresh failed: #{inspect(reason)}"
             })
           )}
      end
    else
      Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

      {:noreply,
       schedule_issue_retry(
         state,
         issue.id,
         attempt + 1,
         Map.merge(metadata, %{
           identifier: issue.identifier,
           error: "no available orchestrator slots"
         })
       )}
    end
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    state = handle_wake_release(state, issue_id)
    delete_retry_record_best_effort(issue_id)

    %{
      state
      | claimed: MapSet.delete(state.claimed, issue_id),
        blocked: Map.delete(state.blocked, issue_id),
        resumed_issues: MapSet.delete(state.resumed_issues, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id),
        parked: Map.delete(state.parked, issue_id),
        retry_history: Map.delete(state.retry_history, issue_id)
    }
  end

  # The continuation check delay is scheduling state, not failure policy.
  # Failure backoff (exponential schedule, cap, provider reset floor) is owned
  # by RetryPolicy.backoff_delay/3 — the single production authority.
  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    if metadata[:delay_type] == :continuation and attempt == 1 do
      @continuation_retry_delay_ms
    else
      RetryPolicy.backoff_delay(attempt, Config.settings!().agent.max_retry_backoff_ms, metadata[:reset_in_ms])
    end
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  @doc false
  @spec note_failure_for_test(term(), String.t(), term()) :: term()
  def note_failure_for_test(%State{} = state, issue_id, reason) when is_binary(issue_id) do
    note_failure(state, issue_id, reason)
  end

  @doc false
  @spec parked_for_test(term()) :: map()
  def parked_for_test(%State{parked: parked}), do: parked

  @doc false
  @spec retry_history_for_test(term()) :: map()
  def retry_history_for_test(%State{retry_history: history}), do: history

  @doc false
  @spec recover_retry_records_for_test(term()) :: term()
  def recover_retry_records_for_test(%State{} = state), do: recover_retry_records(state)

  @doc false
  @spec handle_failure_for_test(term(), String.t(), map(), String.t(), term()) :: term()
  def handle_failure_for_test(%State{} = state, issue_id, running_entry, session_id, reason) do
    retry_agent_down(state, issue_id, running_entry, session_id, reason)
  end

  @doc false
  @spec handle_route_materialization_error_for_test(term(), Issue.t(), integer() | nil, DispatchRouter.intent(), term()) :: term()
  def handle_route_materialization_error_for_test(%State{} = state, %Issue{} = issue, attempt, route, reason) do
    handle_dispatch_route_materialization_error(state, issue, attempt, nil, route, reason)
  end

  @doc false
  @spec next_dispatch_route_for_test(term(), String.t()) :: DispatchRouter.intent()
  def next_dispatch_route_for_test(%State{} = state, issue_id) when is_binary(issue_id) do
    current_dispatch_route(state, issue_id)
  end

  @spec note_failure(term(), String.t(), term()) ::
          {:retry | {:park, atom()}, atom(), map(), term()}
  defp note_failure(%State{} = state, issue_id, reason, opts \\ []) do
    class = AgentRunner.classify_failure(reason)
    now_ms = System.monotonic_time(:millisecond)
    now_dt = DateTime.utc_now()

    {decision, history} =
      case RetryPolicy.evaluate(%{
             failure_class: class,
             history: Map.get(state.retry_history, issue_id),
             now_ms: now_ms
           }) do
        {:retry, history} -> {:retry, history}
        {:park, stop_reason, history} -> {{:park, stop_reason}, history}
      end

    # MIC-195 Slice C: the same fold point also folds the consecutive
    # eligible-primary-failure count into the runtime route projection. The
    # envelope fields above are untouched by the route fold — a route switch
    # never resets the global retry budget. `fold_route_state?: false` skips
    # only the route fold: tracker/retry-poll failures are orchestrator
    # scheduling hiccups, not worker/provider failures, so they must neither
    # increment/reset primary_failure_count nor touch the latched route. The
    # pre-fold projection is still carried through verbatim — update_history/3
    # rebuilds the map without the route keys, and dropping them here would
    # silently un-latch a fallback route.
    history =
      history
      |> Map.put_new(:first_failure_at_dt, DateTime.to_iso8601(now_dt))
      |> Map.put(:last_failure_at_dt, DateTime.to_iso8601(now_dt))

    route_state_before = route_state_from_history(Map.get(state.retry_history, issue_id))

    history =
      if Keyword.get(opts, :fold_route_state?, true) do
        Map.merge(history, RetryPolicy.update_route_state(route_state_before, class))
      else
        Map.merge(history, route_state_before)
      end

    {decision, class, history, %{state | retry_history: Map.put(state.retry_history, issue_id, history)}}
  end

  # Runtime projection of the durable route state for one issue's failure
  # sequence. RetryPolicy owns the semantics; this only extracts the two
  # durable fields with legacy-safe defaults.
  @spec route_state_from_history(term()) :: RetryPolicy.route_state()
  defp route_state_from_history(history) when is_map(history) do
    %{
      route: Map.get(history, :route, :primary),
      primary_failure_count: Map.get(history, :primary_failure_count, 0)
    }
  end

  defp route_state_from_history(_history), do: RetryPolicy.new_route_state()

  defp history_route(history) when is_map(history), do: Map.get(history, :route)
  defp history_route(_history), do: nil

  defp history_primary_failure_count(history) when is_map(history), do: Map.get(history, :primary_failure_count)
  defp history_primary_failure_count(_history), do: nil

  @spec park_issue(term(), String.t(), map() | nil, map()) :: term()
  defp park_issue(%State{} = state, issue_id, running_entry, metadata) when is_map(metadata) do
    history = Map.get(state.retry_history, issue_id, %{})
    now_dt = DateTime.utc_now()
    runtime = running_entry || %{}
    class_name = metadata[:failure_class] || "TRANSIENT_WORKER_FAILURE"
    stop_reason = metadata[:stop_reason] || :max_attempts

    Logger.warning("Parking issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id} failure_class=#{class_name} stop_reason=#{inspect(stop_reason)}")

    # `:recovered_parked` is restart rehydration of a park whose receipt already
    # persisted; re-observing it must not displace the original pending wake.
    state =
      if stop_reason == :recovered_parked do
        state
      else
        observe_wake(state, :parked, issue_id,
          stop_reason: stop_reason,
          evidence: "stop:#{stop_reason}:attempt:#{metadata[:attempt_count] || Map.get(history, :attempt_count, 1)}",
          attempt_id: metadata[:attempt_count] || Map.get(history, :attempt_count, 1)
        )
      end

    entry = %{
      issue_id: issue_id,
      identifier: metadata[:identifier] || issue_id,
      issue_url: metadata[:issue_url],
      failure_class: class_name,
      stop_reason: stop_reason,
      attempt_count: metadata[:attempt_count] || Map.get(history, :attempt_count, 1),
      identical_failure_count: metadata[:identical_failure_count] || Map.get(history, :identical_failure_count, 1),
      first_failure_at: metadata[:first_failure_at] || Map.get(history, :first_failure_at_dt) || DateTime.to_iso8601(now_dt),
      last_failure_at: DateTime.to_iso8601(now_dt),
      error: metadata[:error],
      worker_host: metadata[:worker_host] || Map.get(runtime, :worker_host),
      workspace_path: metadata[:workspace_path] || Map.get(runtime, :workspace_path),
      workspace_root: metadata[:workspace_root] || Map.get(runtime, :workspace_root),
      route: metadata[:route] || Map.get(history, :route, :primary),
      primary_failure_count: metadata[:primary_failure_count] || Map.get(history, :primary_failure_count, 0),
      worker_identity: metadata[:worker_identity] || Map.get(runtime, :worker_identity),
      termination_expectation: metadata[:termination_expectation] || Map.get(runtime, :termination_expectation),
      parked_at: DateTime.to_iso8601(now_dt)
    }

    state = cancel_retry_timer(state, issue_id)
    write_retry_record_best_effort(issue_id, entry, "parked")

    %{state | parked: Map.put(state.parked, issue_id, entry), claimed: MapSet.put(state.claimed, issue_id)}
  end

  @spec cancel_retry_timer(term(), String.t()) :: term()
  defp cancel_retry_timer(%State{} = state, issue_id) do
    case Map.get(state.retry_attempts, issue_id) do
      %{timer_ref: ref} when is_reference(ref) -> Process.cancel_timer(ref)
      _ -> :ok
    end

    %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}
  end

  @spec persist_failure_retry_record(term(), String.t(), integer() | nil, integer(), map()) :: :ok
  defp persist_failure_retry_record(_state, issue_id, attempt, delay_ms, metadata) do
    if is_binary(metadata[:failure_class]) do
      now_dt = DateTime.utc_now()

      entry = %{
        issue_id: issue_id,
        identifier: metadata[:identifier] || issue_id,
        issue_url: metadata[:issue_url],
        failure_class: metadata[:failure_class],
        stop_reason: nil,
        attempt_count: metadata[:attempt_count] || attempt || 1,
        identical_failure_count: metadata[:identical_failure_count] || 1,
        first_failure_at: metadata[:first_failure_at] || DateTime.to_iso8601(now_dt),
        last_failure_at: DateTime.to_iso8601(now_dt),
        error: metadata[:error],
        worker_host: metadata[:worker_host],
        workspace_path: metadata[:workspace_path],
        workspace_root: metadata[:workspace_root],
        route: metadata[:route] || :primary,
        primary_failure_count: metadata[:primary_failure_count] || 0,
        worker_identity: metadata[:worker_identity],
        termination_expectation: metadata[:termination_expectation],
        next_retry_in_ms: delay_ms
      }

      write_retry_record_best_effort(issue_id, entry, "retrying")
    else
      :ok
    end
  end

  @spec write_retry_record_best_effort(String.t(), map(), String.t()) :: :ok
  defp write_retry_record_best_effort(issue_id, entry, status) do
    root = retry_store_root()

    record =
      RetryStore.build_record(%{
        issue_id: issue_id,
        identifier: entry.identifier || issue_id,
        status: status,
        failure_class: entry.failure_class || "TRANSIENT_WORKER_FAILURE",
        attempt_count: entry.attempt_count || 1,
        identical_failure_count: entry.identical_failure_count || 1,
        first_failure_at: entry.first_failure_at,
        last_failure_at: entry.last_failure_at,
        next_retry_at: next_retry_at_iso(entry),
        last_error: entry.error || "",
        worker_host: entry.worker_host || "",
        # MIC-223: persisted worker identity (with receipt_path) lets restart
        # reconciliation positively reconstruct worker death instead of
        # guessing from PIDs.
        worker_identity: entry.worker_identity,
        workspace_path: entry.workspace_path || "",
        workspace_root: entry.workspace_root || root,
        route: Map.get(entry, :route, :primary),
        primary_failure_count: Map.get(entry, :primary_failure_count, 0)
      })

    # MIC-223: the pre-launch termination expectation is persisted only when
    # known, so legacy records keep their exact minimum durable schema.
    record =
      case Map.get(entry, :termination_expectation) do
        nil -> record
        expectation -> Map.put(record, "termination_expectation", to_string(expectation))
      end

    # PARKED recovery: the park's stop reason is persisted only when known, so
    # an operator recovery can objectively classify the park (fence vs policy)
    # after a restart, when the in-memory reason is lost to :recovered_parked.
    # Retry records carry stop_reason nil and keep the minimum schema.
    record =
      case persisted_stop_reason(Map.get(entry, :stop_reason)) do
        nil -> record
        reason -> Map.put(record, "stop_reason", reason)
      end

    try do
      RetryStore.write_record(root, record)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  @spec next_retry_at_iso(map()) :: String.t() | nil
  defp next_retry_at_iso(%{next_retry_in_ms: delay_ms}) when is_integer(delay_ms) and delay_ms >= 0 do
    DateTime.utc_now() |> DateTime.add(delay_ms, :millisecond) |> DateTime.to_iso8601()
  end

  defp next_retry_at_iso(_entry), do: nil

  # nil is an atom too, so this clause must precede the generic atom clause or
  # a retrying record persists the literal string "nil" as its stop reason.
  defp persisted_stop_reason(nil), do: nil
  defp persisted_stop_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp persisted_stop_reason(reason) when is_binary(reason), do: reason
  defp persisted_stop_reason(_reason), do: nil

  @spec delete_retry_record_best_effort(String.t()) :: :ok
  defp delete_retry_record_best_effort(issue_id) do
    try do
      RetryStore.delete_record(retry_store_root(), issue_id)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  @spec retry_store_root() :: String.t()
  defp retry_store_root do
    Application.get_env(:symphony_elixir, :retry_store_root) || Config.local_workspace_root()
  end

  @spec recover_retry_records(term()) :: term()
  defp recover_retry_records(%State{} = state) do
    root = retry_store_root()

    Enum.reduce(RetryStore.list_records(root), state, fn {file_id, result}, acc ->
      case result do
        {:ok, record} ->
          recover_retry_record(acc, record, root)

        {:error, reason} ->
          Logger.warning("Ignoring corrupt retry record file_id=#{file_id}: #{inspect(reason)}; preserving workspaces")
          acc
      end
    end)
  end

  @spec recover_retry_record(term(), map(), String.t()) :: term()
  defp recover_retry_record(%State{} = state, record, root) do
    with issue_id when is_binary(issue_id) <- Map.get(record, "issue_id"),
         status when status in ["retrying", "parked"] <- Map.get(record, "status"),
         class_name when is_binary(class_name) <- Map.get(record, "failure_class"),
         {:ok, class} <- FailureClass.from_name(class_name),
         count when is_integer(count) <- Map.get(record, "attempt_count"),
         {:ok, first_dt} <- parse_record_time(Map.get(record, "first_failure_at")),
         # MIC-195 Slice C: legacy records carry no route fields and default to
         # primary/0; a present-but-invalid value is ambiguous state and fails
         # closed (claim, no timer) like any other unrecoverable record.
         route_name when route_name in ["primary", "fallback"] <- Map.get(record, "route", "primary"),
         pfc when is_integer(pfc) and pfc >= 0 <- Map.get(record, "primary_failure_count", 0) do
      route = if route_name == "fallback", do: :fallback, else: :primary
      recover_valid_retry_record(state, record, root, issue_id, status, class, count, first_dt, route, pfc)
    else
      _ ->
        issue_id = Map.get(record, "issue_id")
        Logger.warning("Ambiguous retry record #{inspect(issue_id)}; failing closed with claim and no timer")
        if is_binary(issue_id), do: %{state | claimed: MapSet.put(state.claimed, issue_id)}, else: state
    end
  end

  @spec parse_record_time(term()) :: {:ok, DateTime.t()} | :error
  defp parse_record_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> :error
    end
  end

  defp parse_record_time(_value), do: :error

  @spec recover_valid_retry_record(term(), map(), String.t(), String.t(), String.t(), atom(), integer(), DateTime.t(), RetryPolicy.route(), non_neg_integer()) :: term()
  defp recover_valid_retry_record(state, record, root, issue_id, status, class, count, first_dt, route, primary_failure_count) do
    now_dt = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)
    age_ms = max(0, DateTime.diff(now_dt, first_dt, :millisecond))
    identical = Map.get(record, "identical_failure_count", 1)
    identical = if is_integer(identical), do: identical, else: 1
    class_name = FailureClass.to_name(class)

    # Recovery restores the durable route state verbatim: the failure that
    # produced this record was already folded before it was written, so the
    # count is not incremented again and no new failure attempt is fabricated.
    history = %{
      attempt_count: count,
      identical_failure_count: identical,
      first_failure_at_ms: now_ms - age_ms,
      last_failure_at_ms: now_ms,
      last_failure_class: class,
      first_failure_at_dt: Map.get(record, "first_failure_at"),
      last_failure_at_dt: Map.get(record, "last_failure_at"),
      route: route,
      primary_failure_count: primary_failure_count
    }

    base_entry = %{
      issue_id: issue_id,
      identifier: Map.get(record, "identifier", issue_id),
      issue_url: nil,
      failure_class: class_name,
      stop_reason: nil,
      attempt_count: count,
      identical_failure_count: identical,
      first_failure_at: Map.get(record, "first_failure_at"),
      last_failure_at: Map.get(record, "last_failure_at"),
      error: Map.get(record, "last_error"),
      worker_host: Map.get(record, "worker_host"),
      workspace_path: Map.get(record, "workspace_path"),
      workspace_root: Map.get(record, "workspace_root", root),
      route: route,
      primary_failure_count: primary_failure_count,
      termination_expectation: expectation_from_record(Map.get(record, "termination_expectation"))
    }

    state = %{state | retry_history: Map.put(state.retry_history, issue_id, history)}

    case status do
      "parked" ->
        entry = Map.merge(base_entry, %{stop_reason: :recovered_parked, parked_at: DateTime.to_iso8601(now_dt)})
        %{state | parked: Map.put(state.parked, issue_id, entry), claimed: MapSet.put(state.claimed, issue_id)}

      "retrying" ->
        case recover_fence_verdict(Map.get(record, "termination_expectation"), Map.get(record, "worker_identity")) do
          {:ok, :dead} ->
            metadata = %{
              identifier: base_entry.identifier,
              issue_url: nil,
              error: base_entry.error,
              worker_host: base_entry.worker_host,
              workspace_path: base_entry.workspace_path,
              workspace_root: base_entry.workspace_root,
              worker_identity: Map.get(record, "worker_identity"),
              termination_expectation: Map.get(record, "termination_expectation"),
              failure_class: class_name,
              attempt_count: count,
              identical_failure_count: identical,
              first_failure_at: base_entry.first_failure_at,
              reset_in_ms: nil,
              route: route,
              primary_failure_count: primary_failure_count
            }

            state = %{state | claimed: MapSet.put(state.claimed, issue_id)}
            schedule_issue_retry(state, issue_id, count + 1, metadata)

          {:error, :alive} ->
            Logger.warning("Retry record worker still alive for issue_id=#{issue_id}; failing closed with claim and no timer")

            state = observe_wake(state, :worker_termination_unconfirmed, issue_id, evidence: "fence_alive")
            entry = Map.merge(base_entry, %{stop_reason: :fence_alive, parked_at: DateTime.to_iso8601(now_dt)})
            %{state | parked: Map.put(state.parked, issue_id, entry), claimed: MapSet.put(state.claimed, issue_id)}

          {:error, :unknown} ->
            Logger.warning("Retry record has no provable worker identity for issue_id=#{issue_id}; failing closed to PARKED with claim and no timer")

            state = observe_wake(state, :worker_termination_unconfirmed, issue_id, evidence: "fence_unknown")
            entry = Map.merge(base_entry, %{stop_reason: :fence_unknown, parked_at: DateTime.to_iso8601(now_dt)})
            %{state | parked: Map.put(state.parked, issue_id, entry), claimed: MapSet.put(state.claimed, issue_id)}
        end
    end
  end

  # MIC-223: UNKNOWN -> no cleanup + no redispatch; absence of identity is never
  # evidence of death. Only explicit never-spawned evidence (Port.open never
  # succeeded for the workspace) or a persisted termination receipt that
  # positively proves the tree drained is DEAD and safe to redispatch. After a
  # runtime restart the receipt file — not a PID — is the death evidence; a
  # missing/unproven receipt parks the issue fail-closed.
  #
  # MIC-223 termination expectation: a persisted NEVER_STARTED expectation is
  # explicit evidence that the launch never created a process/port, so
  # redispatch keeps the same semantics as the "never_spawned" token. A
  # persisted MANAGED_CONFIRMATION_REQUIRED expectation never downgrades just
  # because the in-memory worker identity is gone: the receipt (or its absence)
  # decides, and no receipt parks fail-closed.
  @spec recover_fence_verdict(term(), term()) :: WorkerFence.verdict()
  defp recover_fence_verdict("NEVER_STARTED", _identity), do: WorkerFence.confirm_never_spawned(:never_spawned)

  defp recover_fence_verdict(_expectation, "never_spawned"), do: WorkerFence.confirm_never_spawned(:never_spawned)

  defp recover_fence_verdict(_expectation, %{"receipt_path" => _} = identity),
    do: WorkerFence.confirm_termination_receipt(identity)

  defp recover_fence_verdict(_expectation, identity), do: WorkerFence.confirm_dead(identity)

  defp expectation_from_record(value) when value in ["NOT_APPLICABLE", "NEVER_STARTED", "MANAGED_CONFIRMATION_REQUIRED"] do
    String.to_existing_atom(value)
  end

  defp expectation_from_record(_other), do: nil

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_issue_url(previous_retry, metadata) do
    metadata[:issue_url] || Map.get(previous_retry, :issue_url)
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp pick_retry_workspace_root(previous_retry, metadata) do
    metadata[:workspace_root] || Map.get(previous_retry, :workspace_root)
  end

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp select_worker_host(%State{} = state, preferred_worker_host) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded_worker_host(state, available_hosts)
        end
    end
  end

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  defp running_worker_host_count(running, worker_host) when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp worker_slots_available?(%State{} = state) do
    select_worker_host(state, nil) != :no_worker_capacity
  end

  defp worker_slots_available?(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host) != :no_worker_capacity
  end

  defp worker_host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    case Config.settings!().worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents) -
        map_size(state.running),
      0
    )
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def handle_call(:wake_snapshot, _from, state) do
    {:reply, Ledger.snapshot(state.wake_ledger), state}
  end

  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)
    operational_status = operational_statuses(state)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          issue_url: metadata.issue.url,
          state: metadata.issue.state,
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: metadata.session_id,
          route: Map.get(metadata, :route),
          model: Map.get(metadata, :model),
          reasoning_effort: Map.get(metadata, :reasoning_effort),
          route_source: Map.get(metadata, :route_source),
          operational_status: Map.get(operational_status, issue_id),
          codex_app_server_pid: metadata.codex_app_server_pid,
          codex_input_tokens: metadata.codex_input_tokens,
          codex_output_tokens: metadata.codex_output_tokens,
          codex_total_tokens: metadata.codex_total_tokens,
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          last_codex_event: metadata.last_codex_event,
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          issue_url: Map.get(retry, :issue_url),
          error: Map.get(retry, :error),
          worker_host: Map.get(retry, :worker_host),
          workspace_path: Map.get(retry, :workspace_path),
          route: Map.get(retry, :route),
          operational_status: Map.get(operational_status, issue_id)
        }
      end)

    blocked =
      state.blocked
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: Map.get(metadata, :identifier),
          issue_url: blocked_issue_url(metadata),
          state: blocked_issue_state(metadata),
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: Map.get(metadata, :session_id),
          error: Map.get(metadata, :error),
          blocked_at: Map.get(metadata, :blocked_at),
          last_codex_timestamp: Map.get(metadata, :last_codex_timestamp),
          last_codex_message: Map.get(metadata, :last_codex_message),
          last_codex_event: Map.get(metadata, :last_codex_event),
          operational_status: Map.get(operational_status, issue_id)
        }
      end)

    parked =
      state.parked
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: Map.get(metadata, :identifier),
          failure_class: Map.get(metadata, :failure_class),
          stop_reason: Map.get(metadata, :stop_reason),
          attempt_count: Map.get(metadata, :attempt_count),
          error: Map.get(metadata, :error),
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          route: Map.get(metadata, :route),
          parked_at: Map.get(metadata, :parked_at),
          # PARKED recovery observability: which recovery category the park
          # falls into (:recovered_parked means the reason lives only in the
          # durable retry record — liveness itself is re-proven at recovery
          # time, never projected from this snapshot).
          recovery_class: recovery_category_from_reason(persisted_stop_reason(Map.get(metadata, :stop_reason))),
          operational_status: Map.get(operational_status, issue_id)
        }
      end)

    {:reply,
     %{
       running: running,
       retrying: retrying,
       blocked: blocked,
       parked: parked,
       steering: steering_snapshot(),
       operational_status: operational_status,
       codex_totals: state.codex_totals,
       rate_limits: Map.get(state, :codex_rate_limits),
       # MIC-10 STEER != CONTROL observability: what control was requested
       # against which attempt and how it completed.
       controls: Enum.take(state.control_ledger, 20),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call(:orphaned_workspaces, _from, state) do
    {:reply, state.orphaned_workspaces, state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  # ── MIC-10 STEER != CONTROL: host-owned lifecycle authority ────────────────
  #
  # CONTROL requests arrive only through SymphonyElixir.Control (trusted
  # host/operator code inside the BEAM). No worker/model output path reaches
  # these handlers: worker updates are handle_info messages that only feed
  # observability projections, and steering text is delivered to the worker
  # prompt by the durable steering inbox — the orchestrator never parses
  # steering or model text for lifecycle commands. Every request — executed
  # or rejected — is recorded in the bounded control ledger.
  def handle_call({:control_request, %{action: action} = request}, _from, state)
      when action in [:terminate, :relaunch, :recover_parked] do
    {reply, state} = execute_control_request(state, request)
    {:reply, reply, state}
  end

  def handle_call({:control_request, %{action: :interrupt} = request}, _from, state) do
    # Fail closed: the provider surface this runtime implements has no
    # host-initiated turn interruption, and interrupt is never mapped onto
    # terminate. Recorded so the operator sees what was requested.
    attempt_id = resolve_target_attempt_id(state, request)

    {receipt, state} =
      record_control(
        state,
        request,
        :rejected_interrupt_not_supported,
        %{reason: :no_host_initiated_turn_interrupt_on_provider_surface, running_attempt_id: attempt_id},
        attempt_id: attempt_id
      )

    {:reply, {:ok, receipt}, state}
  end

  def handle_call({:control_request, request}, _from, state) do
    {_receipt, state} = record_control(state, request, {:invalid_request, :unsupported_action}, %{})
    {:reply, {:error, {:invalid_request, :unsupported_action}}, state}
  end

  def handle_call(:control_receipts, _from, state) do
    {:reply, state.control_ledger, state}
  end

  # ── CONTROL execution ──────────────────────────────────────────────────────

  defp execute_control_request(state, %{action: :terminate} = request) do
    control_terminate(state, request)
  end

  defp execute_control_request(state, %{action: :relaunch} = request) do
    control_relaunch(state, request)
  end

  defp execute_control_request(state, %{action: :recover_parked} = request) do
    control_recover_parked(state, request)
  end

  # TERMINATE = the orchestrator's existing task-level stop, the same
  # primitive the stall/reconcile paths use: the task's death closes the
  # app-server port it owns (stdin EOF to the MIC-223 jobrun wrapper for
  # contained launches). Task death is never treated as the confirmation —
  # the wrapper's termination receipt, evaluated against the attempt's
  # predeclared termination expectation through WorkerContainment.reuse_gate/2,
  # decides between :terminated and :termination_unconfirmed (fail closed).
  defp control_terminate(state, request) do
    case Map.get(state.running, request.issue_id) do
      nil ->
        {receipt, state} =
          record_control(state, request, :rejected_worker_not_running, %{running?: false}, attempt_id: resolve_target_attempt_id(state, request))

        {{:ok, receipt}, state}

      entry ->
        running_attempt = Map.get(entry, :retry_attempt)

        if stale_attempt_request?(request.attempt_id, running_attempt) do
          {receipt, state} =
            record_control(state, request, :rejected_stale_attempt, %{running_attempt_id: running_attempt}, attempt_id: resolve_target_attempt_id(state, request))

          {{:ok, receipt}, state}
        else
          perform_control_terminate(state, request, entry, running_attempt)
        end
    end
  end

  defp perform_control_terminate(state, request, entry, attempt) do
    evidence = %{
      stop_primitive: :task_supervisor_stop,
      worker_task_stop_requested: true,
      identifier: Map.get(entry, :identifier),
      issue_url: issue_url_from_entry(entry),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      workspace_root: Map.get(entry, :workspace_root),
      # MIC-223 authoritative inputs, frozen at stop time: the reuse decision
      # is made from the attempt's predeclared expectation plus the wrapper
      # receipt evidence, never from task death alone. Hardening slice: an
      # abruptly stopped task never delivered its :worker_termination message,
      # so the in-memory identity is nil exactly when it is needed — the
      # durable launch marker supplies the same fenceable identity.
      termination_expectation: Map.get(entry, :termination_expectation),
      worker_identity: Map.get(entry, :worker_identity) || LaunchMarker.stored_identity(request.issue_id),
      worker_termination: nil,
      reuse_gate: nil
    }

    stop_running_task(Map.get(entry, :pid), Map.get(entry, :ref), state.task_supervisor)

    {receipt, state} = record_control(state, request, :termination_pending, evidence, attempt_id: attempt)

    # Operator-held: blocked (and still claimed) so the dispatch poller does
    # not silently redispatch — TERMINATE alone never implies RELAUNCH. This
    # runs synchronously with the stop, before the task's DOWN is processed,
    # so the DOWN finds no running entry and no retry/park decision fires.
    state = block_issue_from_entry(state, request.issue_id, entry, "terminated by operator control (control_id=#{receipt.control_id})")

    # The abrupt stop cannot run the agent task's shutdown path (the
    # after-block that publishes :worker_termination dies with the task), so
    # a detached watcher collects the attempt-bound termination evidence and
    # the receipt is finalized in handle_info. The GenServer never blocks.
    spawn_control_evidence_watch(self(), receipt.control_id, request.issue_id, attempt, evidence)

    {{:ok, receipt}, state}
  end

  # RELAUNCH = the orchestrator's existing "start replacement attempt"
  # semantic (the retry envelope with tracker revalidation), gated on
  # confirmed termination evidence bound to the CURRENT attempt. Duplicate
  # relaunches collapse on the existing retry schedule; a still-running
  # worker is never raced.
  defp control_relaunch(state, request) do
    cond do
      Map.has_key?(state.running, request.issue_id) ->
        running_attempt = state.running |> Map.get(request.issue_id) |> Map.get(:retry_attempt)

        {receipt, state} =
          record_control(state, request, :rejected_worker_still_running, %{running_attempt_id: running_attempt}, attempt_id: running_attempt)

        {{:ok, receipt}, state}

      Map.has_key?(state.retry_attempts, request.issue_id) ->
        # Idempotent bound: a replacement is already scheduled on the retry
        # envelope; relaunch collapses onto it.
        scheduled = Map.get(state.retry_attempts, request.issue_id)

        {receipt, state} =
          record_control(state, request, :already_scheduled, %{scheduled_retry_attempt: Map.get(scheduled, :attempt)}, attempt_id: resolve_current_attempt(state, request.issue_id))

        {{:ok, receipt}, state}

      true ->
        control_relaunch_after_termination(state, request)
    end
  end

  defp control_relaunch_after_termination(state, request) do
    issue_id = request.issue_id
    current_attempt = resolve_current_attempt(state, issue_id)

    cond do
      is_nil(current_attempt) ->
        deny_relaunch(state, request, nil, :rejected_no_terminated_attempt, %{
          requirement: :confirmed_terminate_receipt_for_current_attempt,
          current_attempt_id: nil
        })

      request.attempt_id != :current and request.attempt_id != current_attempt ->
        # An older attempt's receipt can never authorize a newer attempt, and
        # a superseded lineage must not be resurrected: only the current
        # attempt is relaunchable.
        deny_relaunch(state, request, current_attempt, :rejected_stale_attempt, %{
          current_attempt_id: current_attempt,
          requested_attempt_id: request.attempt_id
        })

      true ->
        case current_attempt_terminate_receipt(state, issue_id, current_attempt) do
          nil ->
            deny_relaunch(state, request, current_attempt, :rejected_no_terminated_attempt, %{
              requirement: :confirmed_terminate_receipt_for_current_attempt,
              current_attempt_id: current_attempt
            })

          prior_receipt when prior_receipt.outcome != :terminated ->
            # The current attempt's termination is unconfirmed (or still
            # pending): fail closed, preserving claim/workspace.
            deny_relaunch(state, request, current_attempt, :rejected_no_terminated_attempt, %{
              requirement: :confirmed_terminate_receipt_for_current_attempt,
              current_attempt_id: current_attempt,
              prior_terminate_control_id: prior_receipt.control_id,
              prior_outcome: prior_receipt.outcome,
              reason: :termination_unconfirmed
            })

          prior_receipt ->
            case control_relaunch_gate(prior_receipt) do
              {:denied, denial_reason} ->
                deny_relaunch(state, request, current_attempt, :rejected_no_terminated_attempt, %{
                  requirement: :confirmed_terminate_receipt_for_current_attempt,
                  current_attempt_id: current_attempt,
                  prior_terminate_control_id: prior_receipt.control_id,
                  reason: denial_reason
                })

              :allowed ->
                schedule_control_relaunch(state, request, prior_receipt, current_attempt)
            end
        end
    end
  end

  # F1 fail-closed ladder for a managed attempt's relaunch. The receipt-backed
  # fence verdict must positively prove the OS worker tree dead before the
  # MIC-223 gate is consulted: :alive and :unknown deny, {:ok, :dead} falls
  # through to the existing reuse_gate. (For receipt-verified identities the
  # fence returns dead/unknown only — the wrapper writes its receipt at exit —
  # the :alive branch is retained as fail-closed defense.) Non-managed
  # expectations have no containment obligation and skip the ladder.
  defp control_relaunch_gate(prior_receipt) do
    evidence = prior_receipt.evidence

    if Map.get(evidence, :termination_expectation) == :MANAGED_CONFIRMATION_REQUIRED do
      case WorkerFence.confirm_termination_receipt(Map.get(evidence, :worker_identity)) do
        {:ok, :dead} -> :allowed
        {:error, :alive} -> {:denied, :worker_fence_alive}
        {:error, :unknown} -> {:denied, :worker_fence_unknown}
      end
    else
      :allowed
    end
  end

  defp deny_relaunch(state, request, attempt_id, outcome, evidence) do
    {receipt, state} = record_control(state, request, outcome, evidence, attempt_id: attempt_id)
    {{:ok, receipt}, state}
  end

  defp schedule_control_relaunch(state, request, prior_receipt, current_attempt) do
    evidence = prior_receipt.evidence
    next_attempt = if is_integer(current_attempt) and current_attempt > 0, do: current_attempt + 1, else: nil

    # MIC-223 gate, re-evaluated at relaunch time from the receipt's
    # attempt-bound termination evidence: this is the only path to
    # schedule_issue_retry, and it fails closed on anything but the gate's
    # own :allowed — the operator hold is released only once the gate has
    # allowed workspace reuse.
    case WorkerContainment.reuse_gate(Map.get(evidence, :worker_termination), Map.get(evidence, :termination_expectation)) do
      :allowed ->
        metadata = %{
          identifier: Map.get(evidence, :identifier) || request.issue_id,
          issue_url: Map.get(evidence, :issue_url),
          error: "relaunched by operator control (control_id=#{prior_receipt.control_id})",
          worker_host: Map.get(evidence, :worker_host),
          workspace_path: Map.get(evidence, :workspace_path),
          workspace_root: Map.get(evidence, :workspace_root)
        }

        # Narrow hold release for operator relaunch: unlike release_issue_claim/2
        # it preserves the MIC-195 failure sequence, durable records, and
        # envelope — the scheduled retry rides the existing machinery untouched.
        state = release_control_hold(state, request.issue_id)
        state = schedule_issue_retry(state, request.issue_id, next_attempt, metadata)
        # The envelope resolved the replacement attempt (nil delegates to the
        # existing retry schedule); the receipt reports what was scheduled.
        replacement = state.retry_attempts |> Map.get(request.issue_id) |> Map.get(:attempt)

        {receipt, state} =
          record_control(
            state,
            request,
            :relaunch_scheduled,
            %{
              prior_terminate_control_id: prior_receipt.control_id,
              resolved_attempt_id: current_attempt,
              replacement_retry_attempt: replacement,
              reuse_gate: :allowed
            },
            attempt_id: current_attempt
          )

        {{:ok, receipt}, state}

      {:blocked, :worker_termination_unconfirmed} ->
        # Unreachable while the ledger is consistent (finalization marks a
        # receipt :terminated only under an :allowed gate) — kept fail closed:
        # the operator hold stays in place, claim and workspace untouched.
        deny_relaunch(state, request, current_attempt, :rejected_no_terminated_attempt, %{
          requirement: :confirmed_terminate_receipt_for_current_attempt,
          current_attempt_id: current_attempt,
          prior_terminate_control_id: prior_receipt.control_id,
          reason: :worker_termination_unconfirmed
        })
    end
  end

  # ── CONTROL :recover_parked ────────────────────────────────────────────────
  #
  # The operator unblock path for PARKED issues. Parking is never overridden:
  # the command re-reads the durable retry record as fresh evidence, re-runs
  # the WorkerFence against the receipt file as it exists NOW, and releases the
  # park only when the fence positively proves the previous worker tree
  # drained. UNKNOWN and LIVE refuse; corrupt or inconsistent evidence refuses;
  # policy parks (envelope exhaustion, auth) are refused — they are policy
  # decisions that need a different operator action, not a fence verdict.
  # Elapsed time is never consulted: only positive evidence changes the
  # verdict.

  @fence_park_reasons ["worker_termination_unconfirmed", "fence_unknown", "fence_alive"]
  @policy_park_reasons ["max_attempts", "max_age", "max_identical", "auth_unavailable"]

  defp control_recover_parked(state, request) do
    issue_id = request.issue_id

    case Map.get(state.parked, issue_id) do
      nil ->
        # Idempotent bound: a second recovery (or a recovery of an issue that
        # was never parked) observes and changes nothing.
        deny_recovery(state, request, :rejected_issue_not_parked, %{parked?: false}, nil)

      entry ->
        control_recover_parked_entry(state, request, issue_id, entry)
    end
  end

  # The durable retry record is the recovery evidence source, so a restart
  # (which rehydrates parks as :recovered_parked and loses the original
  # in-memory reason) recovers identically to a live park.
  defp control_recover_parked_entry(state, request, issue_id, entry) do
    case RetryStore.read_record(retry_store_root(), issue_id) do
      {:ok, record} ->
        cond do
          Map.get(record, "status") in ["parked", "retrying"] ->
            attempt_id = Map.get(record, "attempt_count")
            park_reason = recovery_park_reason(entry, record)

            case recovery_category_from_reason(park_reason) do
              :fence_recoverable ->
                control_recover_fence_check(state, request, entry, record, park_reason, attempt_id)

              category ->
                deny_recovery(
                  state,
                  request,
                  :rejected_not_fence_parked,
                  %{
                    requirement: :fence_related_park,
                    park_stop_reason: park_reason,
                    category: category,
                    operator_action_required: :different_recovery_path
                  },
                  attempt_id
                )
            end

          true ->
            deny_recovery(
              state,
              request,
              :rejected_corrupt_evidence,
              %{
                reason: {:unexpected_record_status, Map.get(record, "status")}
              },
              nil
            )
        end

      {:error, :not_found} ->
        deny_recovery(state, request, :rejected_corrupt_evidence, %{reason: :retry_record_missing}, nil)

      {:error, reason} ->
        deny_recovery(state, request, :rejected_corrupt_evidence, %{reason: inspect(reason)}, nil)
    end
  end

  defp control_recover_fence_check(state, request, entry, record, park_reason, attempt_id) do
    expectation = Map.get(record, "termination_expectation")
    identity = Map.get(record, "worker_identity")

    case recover_fence_verdict(expectation, identity) do
      {:ok, :dead} ->
        control_recover_tracker_check(state, request, entry, record, park_reason, attempt_id)

      {:error, :alive} ->
        deny_recovery(
          state,
          request,
          :rejected_worker_still_running,
          %{
            fence_verdict: :alive,
            worker_launch_id: recovery_launch_id(identity)
          },
          attempt_id
        )

      {:error, :unknown} ->
        deny_recovery(
          state,
          request,
          :rejected_fence_unknown,
          %{
            fence_verdict: :unknown,
            worker_identity_present: not is_nil(identity),
            worker_launch_id: recovery_launch_id(identity)
          },
          attempt_id
        )
    end
  end

  defp control_recover_tracker_check(state, request, entry, record, park_reason, attempt_id) do
    case Tracker.fetch_issues_by_ids([request.issue_id]) do
      {:error, reason} ->
        # The fence already proved death, but recovery must not resurrect
        # finished work and cannot verify the issue is still active; the park
        # stays until the tracker answers.
        deny_recovery(
          state,
          request,
          :rejected_tracker_unavailable,
          %{
            reason: inspect(reason),
            fence_verdict: :dead,
            park_stop_reason: park_reason
          },
          attempt_id
        )

      {:ok, issues} ->
        control_recover_tracker_state(state, request, entry, record, park_reason, attempt_id, issues)
    end
  end

  defp control_recover_tracker_state(state, request, entry, record, park_reason, attempt_id, issues) do
    issue_id = request.issue_id
    terminal_states = terminal_state_set()

    case find_issue_by_id(issues, issue_id) do
      nil ->
        # The tracker no longer knows the issue: the existing nil-lookup rule
        # applies (release the claim, no redispatch), now safe because the
        # fence proved the worker dead.
        recovery_release(state, request, issue_id, record, park_reason, :recovered_issue_gone, attempt_id, nil)

      %Issue{} = issue ->
        cond do
          terminal_issue_state?(issue.state, terminal_states) ->
            # Recovery must not resurrect finished work: normal terminal
            # reconciliation (workspace cleanup + claim release), safe because
            # the fence positively proved the previous worker tree drained
            # before any workspace was touched.
            evidence = recovery_evidence(record, park_reason, issue.state, :terminal_reconciliation)

            {receipt, state} =
              record_control(state, request, :recovered_terminal, evidence, attempt_id: attempt_id)

            cleanup_issue_workspace(issue, recovery_workspace_metadata(entry, record))
            state = release_issue_claim(state, issue_id)

            {{:ok, receipt}, state}

          retry_candidate_issue?(issue, terminal_states) ->
            evidence = recovery_evidence(record, park_reason, issue.state, :redispatch_scheduled)

            {receipt, state} =
              record_control(state, request, :recovery_scheduled, evidence, attempt_id: attempt_id)

            # Smallest safe transition: release the parked hold, resolve the
            # pending park wake, and let the existing retry envelope — with its
            # preserved failure history, route state, and tracker revalidation
            # at timer fire — redispatch through the normal scheduler. No
            # worker is launched from the recovery command, and the issue stays
            # claimed until the retry dispatches so the poller cannot race it.
            state = handle_wake_release(state, issue_id)
            state = %{state | parked: Map.delete(state.parked, issue_id)}
            state = schedule_issue_retry(state, issue_id, recovery_next_attempt(record), recovery_retry_metadata(record, issue_id, receipt))

            {{:ok, receipt}, state}

          true ->
            # The issue left every active tracker state without becoming
            # terminal: the existing rule releases the claim.
            recovery_release(state, request, issue_id, record, park_reason, :recovered_issue_inactive, attempt_id, issue.state)
        end
    end
  end

  defp recovery_release(state, request, issue_id, record, park_reason, outcome, attempt_id, tracker_state) do
    evidence = recovery_evidence(record, park_reason, tracker_state, :claim_released)
    {receipt, state} = record_control(state, request, outcome, evidence, attempt_id: attempt_id)
    state = release_issue_claim(state, issue_id)
    {{:ok, receipt}, state}
  end

  defp deny_recovery(state, request, outcome, evidence, attempt_id) do
    {receipt, state} = record_control(state, request, outcome, evidence, attempt_id: attempt_id)
    {{:ok, receipt}, state}
  end

  # The in-memory stop reason is authoritative for parks from this process
  # lifetime; :recovered_parked means the original reason only exists in the
  # durable record. Legacy records predating durable stop reasons cannot be
  # classified and require a manual decision.
  defp recovery_park_reason(entry, record) do
    if Map.get(entry, :stop_reason) == :recovered_parked do
      Map.get(record, "stop_reason")
    else
      persisted_stop_reason(Map.get(entry, :stop_reason))
    end
  end

  @spec recovery_category_from_reason(term()) :: :fence_recoverable | :policy_park | :unclassified
  defp recovery_category_from_reason(reason) do
    cond do
      reason in @fence_park_reasons -> :fence_recoverable
      reason in @policy_park_reasons -> :policy_park
      true -> :unclassified
    end
  end

  defp recovery_launch_id(identity) when is_map(identity), do: Map.get(identity, "launch_id")
  defp recovery_launch_id(_identity), do: nil

  defp recovery_evidence(record, park_reason, tracker_state, disposition) do
    %{
      park_stop_reason: park_reason,
      fence_verdict: :dead,
      worker_launch_id: recovery_launch_id(Map.get(record, "worker_identity")),
      tracker_state: tracker_state,
      disposition: disposition
    }
  end

  defp recovery_workspace_metadata(entry, record) do
    %{
      # Durable records store blank strings for absent fields; a blank worker
      # host must stay nil so cleanup takes the local-removal path.
      workspace_path: recovery_blank_to_nil(Map.get(record, "workspace_path")) || Map.get(entry, :workspace_path),
      worker_host: recovery_blank_to_nil(Map.get(record, "worker_host")) || Map.get(entry, :worker_host),
      workspace_root: recovery_blank_to_nil(Map.get(record, "workspace_root")) || Map.get(entry, :workspace_root)
    }
  end

  defp recovery_blank_to_nil(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp recovery_blank_to_nil(value), do: value

  defp recovery_next_attempt(record) do
    case Map.get(record, "attempt_count") do
      count when is_integer(count) and count >= 0 -> count + 1
      _ -> nil
    end
  end

  # The replacement attempt rides the existing retry envelope: the durable
  # record's envelope and route state are preserved verbatim (not re-folded),
  # the durable record transitions "parked" -> "retrying", and the error field
  # durably records who recovered the issue and why release was allowed.
  defp recovery_retry_metadata(record, issue_id, receipt) do
    %{
      identifier: Map.get(record, "identifier") || issue_id,
      issue_url: nil,
      error: "recovered from PARKED by operator control (control_id=#{receipt.control_id}): fence verdict dead",
      worker_host: recovery_blank_to_nil(Map.get(record, "worker_host")),
      workspace_path: recovery_blank_to_nil(Map.get(record, "workspace_path")),
      workspace_root: recovery_blank_to_nil(Map.get(record, "workspace_root")),
      worker_identity: Map.get(record, "worker_identity"),
      termination_expectation: expectation_from_record(Map.get(record, "termination_expectation")),
      failure_class: Map.get(record, "failure_class"),
      attempt_count: Map.get(record, "attempt_count"),
      identical_failure_count: Map.get(record, "identical_failure_count", 1),
      first_failure_at: Map.get(record, "first_failure_at"),
      reset_in_ms: nil,
      route: recovery_route(Map.get(record, "route")),
      primary_failure_count: Map.get(record, "primary_failure_count", 0)
    }
  end

  defp recovery_route("fallback"), do: :fallback
  defp recovery_route(_route), do: :primary

  # ── CONTROL receipt bookkeeping ────────────────────────────────────────────

  # F2 repair: `:current` resolves the current/latest authoritative attempt
  # and then binds evidence to THAT attempt only. It never searches the
  # ledger backwards for the newest successful receipt.
  defp resolve_current_attempt(state, issue_id) do
    cond do
      entry = Map.get(state.running, issue_id) ->
        Map.get(entry, :retry_attempt)

      entry = Map.get(state.blocked, issue_id) ->
        Map.get(entry, :retry_attempt)

      true ->
        nil
    end
  end

  # The current attempt's own terminate receipt — exact issue + attempt match,
  # no backwards search over other attempts' outcomes. Within the attempt the
  # ledger is newest-first, so the LATEST terminate record for this attempt is
  # authoritative: a later rejection never resurrects an earlier confirmation.
  defp current_attempt_terminate_receipt(state, issue_id, attempt_id) do
    Enum.find(state.control_ledger, fn receipt ->
      receipt.action == :terminate and receipt.issue_id == issue_id and receipt.attempt_id == attempt_id
    end)
  end

  defp find_pending_control_receipt(state, control_id, issue_id, attempt_id) do
    Enum.find(state.control_ledger, fn receipt ->
      receipt.action == :terminate and receipt.control_id == control_id and receipt.issue_id == issue_id and
        receipt.attempt_id == attempt_id and receipt.outcome == :termination_pending
    end)
  end

  defp replace_control_receipt(state, finalized) do
    ledger =
      Enum.map(state.control_ledger, fn receipt ->
        if receipt.control_id == finalized.control_id, do: finalized, else: receipt
      end)

    %{state | control_ledger: ledger}
  end

  defp stale_attempt_request?(:current, _running_attempt), do: false
  defp stale_attempt_request?(attempt_id, running_attempt), do: attempt_id != running_attempt

  # Observability binding for receipts: :current resolves against the running
  # worker when one exists; an explicit number is recorded verbatim.
  defp resolve_target_attempt_id(state, request) do
    case Map.get(state.running, request.issue_id) do
      %{retry_attempt: attempt_id} ->
        if request.attempt_id == :current, do: attempt_id, else: request.attempt_id

      _ ->
        if request.attempt_id == :current, do: nil, else: request.attempt_id
    end
  end

  # Bounded detached evidence watcher: waits for the MIC-223 wrapper receipt
  # of the stopped attempt (only for managed expectations), classifies it
  # through WorkerContainment's own parser/classifier, and reports the
  # confirmation back through handle_info. Never raises into the orchestrator;
  # any unexpected failure reports an unconfirmed verdict (fail closed).
  defp spawn_control_evidence_watch(server, control_id, issue_id, attempt_id, evidence) do
    spawn(fn ->
      confirmation =
        try do
          control_termination_confirmation(evidence)
        rescue
          _error -> %{status: :TERMINATION_UNCONFIRMED, receipt: nil, exit_code: nil, reason: :control_evidence_watch_error}
        end

      send(server, {:control_termination_evidence, control_id, issue_id, attempt_id, confirmation})
    end)

    :ok
  end

  # The confirmation for the stopped attempt, derived ONLY from the
  # attempt's MIC-223 evidence class:
  #   - managed: wait (bounded) for the wrapper receipt, then classify it;
  #   - NEVER_STARTED / NOT_APPLICABLE: no termination confirmation exists or
  #     is required (nil — the gate's accepted semantics for these classes);
  #   - anything else: fail closed.
  defp control_termination_confirmation(evidence) do
    case Map.get(evidence, :termination_expectation) do
      :MANAGED_CONFIRMATION_REQUIRED -> await_managed_receipt_confirmation(Map.get(evidence, :worker_identity))
      :NEVER_STARTED -> nil
      :NOT_APPLICABLE -> nil
      _other -> %{status: :TERMINATION_UNCONFIRMED, receipt: nil, exit_code: nil, reason: :unknown_termination_expectation}
    end
  end

  defp await_managed_receipt_confirmation(identity) do
    # The deadline is fixed once, before polling: recomputing it inside the
    # loop would push it forward every iteration and the bounded wait would
    # never end.
    await_managed_receipt_confirmation(identity, control_evidence_deadline())
  end

  defp await_managed_receipt_confirmation(identity, deadline) do
    cond do
      confirmation = managed_receipt_confirmation(identity) ->
        confirmation

      System.monotonic_time(:millisecond) >= deadline ->
        %{status: :TERMINATION_UNCONFIRMED, receipt: nil, exit_code: nil, reason: :control_termination_evidence_timeout}

      true ->
        Process.sleep(@control_evidence_poll_ms)
        await_managed_receipt_confirmation(identity, deadline)
    end
  end

  # Reuses WorkerContainment's own receipt parser and classifier — the same
  # evidence path the natural shutdown confirmation uses; no second
  # termination classifier exists.
  defp managed_receipt_confirmation(nil),
    do: %{status: :TERMINATION_UNCONFIRMED, receipt: nil, exit_code: nil, reason: :no_worker_identity}

  defp managed_receipt_confirmation(identity) do
    case WorkerContainment.parse_receipt(Map.get(identity, "receipt_path")) do
      {:ok, receipt} ->
        %{
          status: WorkerContainment.classify_receipt(receipt),
          receipt: receipt,
          exit_code: receipt["child_exit_code"],
          reason: receipt["terminal_reason"]
        }

      {:error, _reason} ->
        nil
    end
  end

  defp control_evidence_deadline do
    System.monotonic_time(:millisecond) + control_evidence_budget_ms()
  end

  defp control_evidence_budget_ms do
    case Application.get_env(:symphony_elixir, @control_evidence_budget_env) do
      ms when is_integer(ms) and ms >= 0 ->
        ms

      _other ->
        hard_budget = Application.get_env(:symphony_elixir, :worker_termination_hard_budget_ms, 20_000)
        WorkerContainment.grace_ms() + hard_budget
    end
  end

  # Narrow hold release for operator relaunch: unlike release_issue_claim/2 it
  # preserves the MIC-195 failure sequence, durable records, and envelope —
  # the scheduled retry rides the existing machinery untouched.
  defp release_control_hold(%State{} = state, issue_id) do
    %{state | claimed: MapSet.delete(state.claimed, issue_id), blocked: Map.delete(state.blocked, issue_id)}
  end

  defp issue_url_from_entry(entry) do
    case Map.get(entry, :issue) do
      %Issue{} = issue -> issue.url
      _other -> nil
    end
  end

  @spec record_control(%State{}, map(), term(), map(), keyword()) :: {map(), %State{}}
  defp record_control(state, request, outcome, evidence, overrides \\ []) do
    now = DateTime.utc_now()

    receipt = %{
      control_id: new_control_id(),
      action: Map.get(request, :action),
      issue_id: overrides[:issue_id] || Map.get(request, :issue_id),
      attempt_id: overrides[:attempt_id],
      requested_at: now,
      requested_by: Map.get(request, :requested_by, :host_operator),
      completed_at: now,
      outcome: outcome,
      evidence: evidence
    }

    Logger.info(
      "Control receipt: control_id=#{receipt.control_id} action=#{inspect(receipt.action)} outcome=#{inspect(outcome)} " <>
        "issue_id=#{inspect(receipt.issue_id)} attempt_id=#{inspect(receipt.attempt_id)} requested_by=#{inspect(receipt.requested_by)}"
    )

    {receipt, %{state | control_ledger: Enum.take([receipt | state.control_ledger], @control_ledger_limit)}}
  end

  defp new_control_id, do: "ctl-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  defp blocked_issue_state(%{issue: %Issue{state: state}}), do: state
  defp blocked_issue_state(_metadata), do: nil

  defp blocked_issue_url(%{issue: %Issue{url: url}}), do: url
  defp blocked_issue_url(_metadata), do: nil

  # ── MIC-195 Slice D: operational status projection ─────────────────────────
  #
  # Deterministic, read-only projection of the authoritative lifecycle maps
  # onto the six operator-visible statuses. Observability only: this cluster
  # never mutates state and has zero control-plane authority — no retry,
  # route, park, block, or tracker decision consults its output.
  #
  # Precedence (first match wins, evaluated per issue):
  #
  #   1. :blocked             — existing reconciliation/safety block
  #   2. :parked              — bounded retry envelope reached PARKED
  #   3. :fallback_running    — active worker on the route materialized at
  #                             dispatch (running entry's `route`, never
  #                             re-derived from current config)
  #   4. :running             — active worker on primary
  #   5. :provider_unavailable — no worker executing; a retry is scheduled and
  #                             the active failure sequence's already-classified
  #                             `last_failure_class` is a provider class
  #   6. :waiting_retry       — no worker executing; a retry is scheduled
  #
  # Provider-class membership is consumed through RetryPolicy's closed Slice C
  # class list (fallback_eligible_class?/1) and FailureClass normalization —
  # never redefined here and never re-derived from error strings. Sequence
  # resets (completion and reconcile-driven termination) delete the history,
  # so stale provider/fallback state cannot leak into a fresh lifecycle, and
  # issues present in none of the lifecycle maps get no fabricated status.

  @spec operational_statuses(%State{}) :: %{String.t() => operational_status()}
  defp operational_statuses(%State{} = state) do
    %State{running: running, retry_attempts: retry_attempts, parked: parked, blocked: blocked} = state

    running
    |> Map.merge(retry_attempts)
    |> Map.merge(parked)
    |> Map.merge(blocked)
    |> Map.keys()
    |> Map.new(fn issue_id -> {issue_id, operational_status(state, issue_id)} end)
  end

  @spec operational_status(%State{}, String.t()) :: operational_status()
  defp operational_status(%State{} = state, issue_id) do
    cond do
      Map.has_key?(state.blocked, issue_id) -> :blocked
      Map.has_key?(state.parked, issue_id) -> :parked
      true -> active_or_waiting_status(state, issue_id)
    end
  end

  defp active_or_waiting_status(%State{} = state, issue_id) do
    case Map.get(state.running, issue_id) do
      %{route: :fallback} -> :fallback_running
      entry when is_map(entry) -> :running
      _missing -> waiting_status(state, issue_id)
    end
  end

  defp waiting_status(%State{retry_attempts: retry_attempts, retry_history: retry_history}, issue_id) do
    if Map.has_key?(retry_attempts, issue_id) and provider_failure_sequence?(retry_history, issue_id) do
      :provider_unavailable
    else
      :waiting_retry
    end
  end

  defp provider_failure_sequence?(retry_history, issue_id) do
    case Map.get(retry_history, issue_id) do
      %{last_failure_class: class} -> class |> FailureClass.normalize_class() |> RetryPolicy.fallback_eligible_class?()
      _none -> false
    end
  end

  @doc false
  @spec operational_statuses_for_test(term()) :: %{String.t() => operational_status()}
  def operational_statuses_for_test(%State{} = state), do: operational_statuses(state)

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    codex_input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    codex_output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    codex_total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    last_reported_input = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :codex_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :codex_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    {
      Map.merge(running_entry, %{
        last_codex_timestamp: timestamp,
        last_codex_message: summarize_codex_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        model: model_for_update(Map.get(running_entry, :model), update),
        reasoning_effort: reasoning_effort_for_update(Map.get(running_entry, :reasoning_effort), update),
        route_source: route_source_for_update(Map.get(running_entry, :route_source), update),
        last_codex_event: event,
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        codex_input_tokens: codex_input_tokens + token_delta.input_tokens,
        codex_output_tokens: codex_output_tokens + token_delta.output_tokens,
        codex_total_tokens: codex_total_tokens + token_delta.total_tokens,
        codex_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        codex_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        codex_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update)
      }),
      token_delta
    }
  end

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp model_for_update(_existing, %{model: model}) when is_binary(model), do: model
  defp model_for_update(existing, _update), do: existing

  defp reasoning_effort_for_update(_existing, %{reasoning_effort: effort}) when is_binary(effort), do: effort
  defp reasoning_effort_for_update(existing, _update), do: existing

  defp route_source_for_update(_existing, %{route_source: source}) when not is_nil(source), do: source
  defp route_source_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    codex_totals =
      apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | codex_totals: codex_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    config = Config.settings!()

    %{
      state
      | poll_interval_ms: config.polling.interval_ms,
        max_concurrent_agents: config.agent.max_concurrent_agents
    }
  end

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states)
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running)
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_codex_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | codex_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_codex_rate_limits(state, _update), do: state

  defp apply_token_delta(codex_totals, token_delta) do
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :codex_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :codex_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :codex_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
