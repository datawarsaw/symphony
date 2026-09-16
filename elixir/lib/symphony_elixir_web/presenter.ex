defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, StatusDashboard, Workspace}

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying),
            blocked: length(Map.get(snapshot, :blocked, [])),
            parked: length(Map.get(snapshot, :parked, []))
          },
          # MIC-195 Slice D: read-only projection of the authoritative
          # orchestrator state (issue_id => operator status). Display-only.
          operational_status:
            snapshot
            |> Map.get(:operational_status, %{})
            |> Map.new(fn {issue_id, status} -> {issue_id, operational_status_name(status)} end),
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          blocked: Enum.map(Map.get(snapshot, :blocked, []), &blocked_entry_payload/1),
          steering: steering_payload(Map.get(snapshot, :steering, %{entries: [], counts: %{}})),
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))
        blocked = Enum.find(Map.get(snapshot, :blocked, []), &(&1.identifier == issue_identifier))
        parked = Enum.find(Map.get(snapshot, :parked, []), &(&1.identifier == issue_identifier))
        operational_status = Map.get(Map.get(snapshot, :operational_status, %{}), issue_id_from_entries(running, retry, blocked, parked))

        if is_nil(running) and is_nil(retry) and is_nil(blocked) and is_nil(parked) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry, blocked, parked, operational_status)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry, blocked, parked, operational_status) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry, blocked, parked),
      status: issue_status(running, retry, blocked, parked),
      operational_status: operational_status_name(operational_status),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry, blocked, parked),
        host: workspace_host(running, retry, blocked, parked)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      blocked: blocked && blocked_issue_payload(blocked),
      parked: parked && parked_issue_payload(parked),
      logs: %{
        codex_session_logs: []
      },
      recent_events: recent_events_payload(running || blocked),
      last_error: (blocked && blocked.error) || (retry && retry.error),
      tracked: %{}
    }
  end

  defp issue_id_from_entries(running, retry, blocked, parked) do
    (running && running.issue_id) || (retry && retry.issue_id) || (blocked && blocked.issue_id) ||
      (parked && parked.issue_id)
  end

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  # Legacy coarse status, kept for API compatibility. The deterministic
  # MIC-195 operational projection is `operational_status`.
  defp issue_status(running, _retry, _blocked, _parked) when not is_nil(running), do: "running"
  defp issue_status(nil, retry, _blocked, _parked) when not is_nil(retry), do: "retrying"
  defp issue_status(nil, nil, blocked, _parked) when not is_nil(blocked), do: "blocked"
  defp issue_status(nil, nil, nil, parked) when not is_nil(parked), do: "parked"

  # MIC-195 Slice D: stable serialized name for the orchestrator's projected
  # status atom (e.g. :waiting_retry -> "WAITING_RETRY").
  defp operational_status_name(nil), do: nil

  defp operational_status_name(status) when is_atom(status) do
    status |> to_string() |> String.upcase()
  end

  defp operational_status_name(status) when is_binary(status), do: String.upcase(status)

  # MIC-10: read-only projection of the durable steering inbox. Instruction
  # text never leaves workspace-owned state.
  defp steering_payload(%{entries: entries, counts: counts}) do
    %{counts: counts, entries: Enum.map(entries || [], &steering_entry_payload/1)}
  end

  defp steering_payload(_other), do: %{counts: %{}, entries: []}

  defp steering_entry_payload(entry) when is_map(entry) do
    %{
      steer_id: entry[:steer_id],
      issue_id: entry[:issue_id],
      issue_identifier: entry[:issue_identifier],
      attempt_id: entry[:attempt_id],
      sequence: entry[:sequence],
      status: entry[:status],
      delivery_attempts: entry[:delivery_attempts],
      worker_host: entry[:worker_host],
      thread_id: entry[:thread_id],
      created_at: entry[:created_at],
      delivered_at: entry[:delivered_at],
      acknowledged_at: entry[:acknowledged_at],
      handled_at: entry[:handled_at],
      failure_reason: entry[:failure_reason],
      unreadable: Map.get(entry, :unreadable, false)
    }
  end

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      state: entry.state,
      operational_status: operational_status_name(Map.get(entry, :operational_status)),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      operational_status: operational_status_name(Map.get(entry, :operational_status)),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
  end

  defp blocked_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      state: entry.state,
      operational_status: operational_status_name(Map.get(entry, :operational_status)),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      blocked_at: iso8601(entry.blocked_at),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      last_event_at: iso8601(entry.last_codex_timestamp)
    }
  end

  defp parked_issue_payload(entry) do
    %{
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      failure_class: Map.get(entry, :failure_class),
      stop_reason: Map.get(entry, :stop_reason),
      attempt_count: Map.get(entry, :attempt_count),
      error: entry.error,
      parked_at: iso8601(Map.get(entry, :parked_at))
    }
  end

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp blocked_issue_payload(blocked) do
    %{
      worker_host: Map.get(blocked, :worker_host),
      workspace_path: Map.get(blocked, :workspace_path),
      session_id: blocked.session_id,
      state: blocked.state,
      error: blocked.error,
      blocked_at: iso8601(blocked.blocked_at),
      last_event: blocked.last_codex_event,
      last_message: summarize_message(blocked.last_codex_message),
      last_event_at: iso8601(blocked.last_codex_timestamp)
    }
  end

  defp workspace_path(issue_identifier, running, retry, blocked, parked) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      (blocked && Map.get(blocked, :workspace_path)) ||
      (parked && Map.get(parked, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, Workspace.workspace_key(issue_identifier))
  end

  defp workspace_host(running, retry, blocked, parked) do
    (running && Map.get(running, :worker_host)) ||
      (retry && Map.get(retry, :worker_host)) ||
      (blocked && Map.get(blocked, :worker_host)) ||
      (parked && Map.get(parked, :worker_host))
  end

  defp recent_events_payload(nil), do: []

  defp recent_events_payload(entry) do
    [
      %{
        at: iso8601(entry.last_codex_timestamp),
        event: entry.last_codex_event,
        message: summarize_message(entry.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
