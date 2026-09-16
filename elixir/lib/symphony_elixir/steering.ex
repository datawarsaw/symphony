defmodule SymphonyElixir.Steering do
  @moduledoc """
  Durable steering inbox for operator guidance addressed to one exact worker
  attempt.

  Load-bearing rule: terminal/session text transport is NOT proof of delivery.
  The durable record in `.symphony-state/steering/` (via
  `SymphonyElixir.SteeringStore`) is authoritative.

  States: PENDING -> DELIVERED -> ACKNOWLEDGED -> HANDLED, plus FAILED
  (delivery attempt cap) and STALE (bound attempt superseded or restart
  invalidation). Transitions are one-way and guarded: duplicate delivery and
  duplicate acknowledgement are idempotent no-ops, and a steer bound to
  attempt N is never delivered to attempt N+1 (fail closed).

  Acknowledgement contract: there is no protocol-level ack in the Codex
  app-server surface, so the smallest explicit worker-emittable acknowledgement
  is a deterministic tool call named `symphony_steer_ack` carrying the
  `steer_id`, validated against the record's issue/attempt/thread identity.
  Worker prose is never parsed. Until that call arrives, a delivered steer
  stays DELIVERED — uncertainty is preserved, never fabricated from timing.
  """

  require Logger

  alias SymphonyElixir.SteeringStore

  @max_delivery_attempts 3
  @max_instruction_length 8_192
  @statuses ["PENDING", "DELIVERED", "ACKNOWLEDGED", "HANDLED", "FAILED", "STALE"]

  @type record :: map()

  # ---------------------------------------------------------------------------
  # Identity
  # ---------------------------------------------------------------------------

  @doc """
  Normalizes an orchestrator attempt value to the durable attempt_id.
  Matches Orchestrator.normalize_retry_attempt: first dispatch (nil/0) -> 0,
  retry N -> N. A steer never crosses an attempt boundary.
  """
  @spec normalize_attempt(term()) :: non_neg_integer()
  def normalize_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  def normalize_attempt(_attempt), do: 0

  @spec statuses() :: [String.t(), ...]
  def statuses, do: @statuses

  @spec max_delivery_attempts() :: pos_integer()
  def max_delivery_attempts, do: @max_delivery_attempts

  # ---------------------------------------------------------------------------
  # Creation (persist-before-delivery)
  # ---------------------------------------------------------------------------

  @doc """
  Durably records a new PENDING steer before any delivery is attempted.

  With an explicit `:steer_id` that already exists, returns the existing
  record unchanged — a repeated send of the same steer id can never create a
  second logical instruction.
  """
  @spec create(String.t(), keyword() | map()) :: {:ok, record()} | {:error, term()}
  def create(workspace_root, attrs) when is_list(attrs) or is_map(attrs) do
    attrs_map = if is_list(attrs), do: Map.new(attrs), else: attrs

    case Map.get(attrs_map, :steer_id) do
      nil ->
        create_new(workspace_root, attrs_map)

      steer_id ->
        case SteeringStore.read_record(workspace_root, steer_id) do
          {:ok, existing} -> {:ok, existing}
          {:error, :not_found} -> create_new(workspace_root, Map.put(attrs_map, :steer_id, steer_id))
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp create_new(workspace_root, attrs) do
    with {:ok, instruction} <- validate_instruction(Map.get(attrs, :instruction)),
         issue_id when is_binary(issue_id) and issue_id != "" <- Map.get(attrs, :issue_id) do
      steer_id = Map.get(attrs, :steer_id) || new_steer_id()
      now = now_iso()

      record =
        %{
          "schema_version" => SteeringStore.schema_version(),
          "steer_id" => steer_id,
          "issue_id" => issue_id,
          "issue_identifier" => Map.get(attrs, :issue_identifier, ""),
          "attempt_id" => normalize_attempt(Map.get(attrs, :attempt_id)),
          "worker_host" => Map.get(attrs, :worker_host),
          "thread_id" => nil,
          "sequence" => next_sequence(workspace_root, issue_id),
          "created_at" => now,
          "instruction" => instruction,
          "delivered_at" => nil,
          "delivery_thread_id" => nil,
          "delivery_turn_id" => nil,
          "delivery_session_id" => nil,
          "acknowledged_at" => nil,
          "handled_at" => nil,
          "failure_reason" => nil,
          "status" => "PENDING",
          "delivery_attempts" => 0
        }

      :ok = SteeringStore.write_record(workspace_root, record)
      {:ok, record}
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :invalid_issue_id}
      other when not is_binary(other) -> {:error, :invalid_issue_id}
      "" -> {:error, :invalid_issue_id}
    end
  end

  defp validate_instruction(instruction) when is_binary(instruction) do
    trimmed = String.trim(instruction)

    cond do
      trimmed == "" -> {:error, :invalid_instruction}
      String.length(trimmed) > @max_instruction_length -> {:error, :instruction_too_long}
      true -> {:ok, trimmed}
    end
  end

  defp validate_instruction(_other), do: {:error, :invalid_instruction}

  defp new_steer_id do
    "steer-" <>
      Integer.to_string(System.system_time(:native)) <>
      "-" <> Integer.to_string(:erlang.unique_integer([:positive]))
  end

  defp next_sequence(workspace_root, issue_id) do
    workspace_root
    |> SteeringStore.list_records()
    |> Enum.flat_map(fn {_id, result} ->
      case result do
        {:ok, %{"issue_id" => ^issue_id, "sequence" => seq}} when is_integer(seq) -> [seq]
        _ -> []
      end
    end)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  # ---------------------------------------------------------------------------
  # Turn-boundary delivery
  # ---------------------------------------------------------------------------

  @doc """
  Prepares the steering inbox for one turn of one exact worker attempt.

  Marks PENDING/DELIVERED steers bound to superseded attempts of this issue as
  STALE (fail closed — a replacement worker never receives them), then claims
  the PENDING steers bound to exactly this issue and attempt. Corrupt records
  are reported under `:unreadable` and are never delivered.
  """
  @spec prepare_turn_inbox(String.t(), String.t(), non_neg_integer()) :: %{
          deliverable: [record()],
          prompt_section: String.t(),
          unreadable: [{String.t(), atom()}],
          staled: [String.t()]
        }
  def prepare_turn_inbox(workspace_root, issue_id, attempt_id)
      when is_binary(issue_id) and is_integer(attempt_id) and attempt_id >= 0 do
    staled = stale_for_attempt(workspace_root, issue_id, attempt_id)

    {deliverable, unreadable} = deliverable_for_turn(workspace_root, issue_id, attempt_id)

    %{
      deliverable: deliverable,
      prompt_section: prompt_section(deliverable),
      unreadable: unreadable,
      staled: staled
    }
  end

  @doc """
  Marks PENDING/DELIVERED steers for `issue_id` bound to any attempt other
  than `current_attempt_id` as STALE. Retained durably; never deleted.
  """
  @spec stale_for_attempt(String.t(), String.t(), non_neg_integer()) :: [String.t()]
  def stale_for_attempt(workspace_root, issue_id, current_attempt_id) do
    workspace_root
    |> issue_records(issue_id)
    |> Enum.flat_map(fn record ->
      if record["attempt_id"] != current_attempt_id and staleable?(record) do
        {:ok, _updated} = mark_stale(workspace_root, record, "attempt_superseded")
        [record["steer_id"]]
      else
        []
      end
    end)
  end

  defp deliverable_for_turn(workspace_root, issue_id, attempt_id) do
    workspace_root
    |> SteeringStore.list_records()
    |> Enum.reduce({[], []}, fn {_id, result}, {ok_acc, unreadable_acc} ->
      case result do
        {:ok, %{"issue_id" => ^issue_id, "attempt_id" => ^attempt_id, "status" => "PENDING"} = record} ->
          {[record | ok_acc], unreadable_acc}

        {:ok, _} ->
          {ok_acc, unreadable_acc}

        {:error, reason} ->
          {ok_acc, [{"unknown", reason} | unreadable_acc]}
      end
    end)
    |> then(fn {ok, unreadable} -> {Enum.sort_by(ok, & &1["sequence"]), Enum.reverse(unreadable)} end)
  end

  defp issue_records(workspace_root, issue_id) do
    workspace_root
    |> SteeringStore.list_records()
    |> Enum.flat_map(fn {_id, result} ->
      case result do
        {:ok, %{"issue_id" => ^issue_id} = record} -> [record]
        _ -> []
      end
    end)
  end

  defp staleable?(%{"status" => status}), do: status in ["PENDING", "DELIVERED"]

  # ---------------------------------------------------------------------------
  # Prompt rendering
  # ---------------------------------------------------------------------------

  @doc """
  Renders claimed steers as a worker-facing prompt section. A steer is
  operator guidance for the worker, not shell semantics; it is delivered as
  plain prompt text with its durable identity attached.
  """
  @spec prompt_section([record()]) :: String.t()
  def prompt_section([]), do: ""

  def prompt_section(records) when is_list(records) do
    items =
      records
      |> Enum.map(fn record ->
        """
        [steer_id=#{record["steer_id"]} sequence=#{record["sequence"]} attempt=#{record["attempt_id"]}]
        #{record["instruction"]}\
        """
      end)
      |> Enum.join("\n\n")

    """
    \nOperator steering (recorded durably by the Symphony operator for this exact worker attempt; apply to the current work):

    #{items}
    """
  end

  # ---------------------------------------------------------------------------
  # Delivery state
  # ---------------------------------------------------------------------------

  @doc """
  Marks a PENDING steer DELIVERED. Must be called only when the runtime
  itself proved acceptance (the app-server accepted turn/start and returned a
  turn id) — never from timing or transport optimism. Duplicate calls are
  idempotent: an already-DELIVERED steer keeps its original delivery facts.
  """
  @spec mark_delivered(String.t(), String.t(), keyword() | map()) :: {:ok, record()} | {:error, term()}
  def mark_delivered(workspace_root, steer_id, delivery) when is_list(delivery) or is_map(delivery) do
    delivery = if is_list(delivery), do: Map.new(delivery), else: delivery

    update_record(workspace_root, steer_id, fn record ->
      case {record["status"], identity_matches?(record, delivery, false)} do
        {"PENDING", true} ->
          {:transition,
           record
           |> Map.put("status", "DELIVERED")
           |> Map.put("delivered_at", now_iso())
           |> Map.put("delivery_thread_id", delivery_value(delivery, :thread_id))
           |> Map.put("delivery_turn_id", delivery_value(delivery, :turn_id))
           |> Map.put("delivery_session_id", delivery_value(delivery, :session_id))
           |> Map.put("thread_id", delivery_value(delivery, :thread_id))}

        {"PENDING", false} ->
          {:error, :identity_mismatch}

        {"DELIVERED", _} ->
          {:ok, :no_op}

        {status, _} when status in ["ACKNOWLEDGED", "HANDLED"] ->
          {:ok, :no_op}

        {status, _} when status in ["FAILED", "STALE"] ->
          {:error, {:not_deliverable, status}}
      end
    end)
  end

  @doc """
  Records a failed delivery attempt for a steer still PENDING. Once the
  bounded attempt cap is reached the steer becomes FAILED. Steers already
  DELIVERED (the turn was accepted, then failed mid-turn) are untouched —
  their delivery is a proven fact and resending would duplicate instruction.
  """
  @spec record_delivery_failure(String.t(), String.t(), term()) :: {:ok, record()} | {:error, term()}
  def record_delivery_failure(workspace_root, steer_id, reason) do
    update_record(workspace_root, steer_id, fn record ->
      case record["status"] do
        "PENDING" ->
          attempts = record["delivery_attempts"] + 1

          if attempts >= @max_delivery_attempts do
            {:transition,
             record
             |> Map.put("status", "FAILED")
             |> Map.put("delivery_attempts", attempts)
             |> Map.put("failure_reason", "delivery_failed: #{inspect(reason)}")}
          else
            {:transition, Map.put(record, "delivery_attempts", attempts)}
          end

        _ ->
          {:ok, :no_op}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Acknowledgement / handling
  # ---------------------------------------------------------------------------

  @doc """
  Records a deterministic acknowledgement for a DELIVERED steer.

  `opts` may carry `:issue_id`, `:attempt_id`, and `:thread_id`; when present
  they must match the record's binding, so a superseded session cannot
  acknowledge a steer it never received. Duplicate acknowledgements are
  idempotent no-ops. Acknowledgement of a PENDING, FAILED, or STALE steer is
  rejected — only a delivered steer can be acknowledged.
  """
  @spec acknowledge(String.t(), String.t(), keyword() | map()) ::
          {:ok, record()} | {:error, term()}
  def acknowledge(workspace_root, steer_id, opts \\ []) do
    opts_map = if is_list(opts), do: Map.new(opts), else: opts

    update_record(workspace_root, steer_id, fn record ->
      case {record["status"], identity_matches?(record, opts_map)} do
        {"DELIVERED", true} ->
          {:transition,
           record
           |> Map.put("status", "ACKNOWLEDGED")
           |> Map.put("acknowledged_at", now_iso())}

        {"DELIVERED", false} ->
          {:error, :identity_mismatch}

        {status, true} when status in ["ACKNOWLEDGED", "HANDLED"] ->
          {:ok, :no_op}

        {status, _} ->
          {:error, {:not_acknowledgeable, status}}
      end
    end)
  end

  @doc """
  Acknowledgement entry point for the `symphony_steer_ack` worker tool call.
  Validates against the session's steering context and the delivering thread;
  returns a dynamic-tool result map.
  """
  @spec ack_tool_response(map() | nil, String.t() | nil, term()) :: map()
  def ack_tool_response(nil, _thread_id, _arguments) do
    %{"success" => false, "output" => "steering acknowledgement unavailable in this session"}
  end

  def ack_tool_response(context, thread_id, arguments) when is_map(context) do
    steer_id = steer_id_from_arguments(arguments)

    case steer_id do
      nil ->
        %{"success" => false, "output" => "symphony_steer_ack requires a steer_id argument"}

      steer_id ->
        opts = [
          issue_id: Map.get(context, :issue_id),
          attempt_id: Map.get(context, :attempt_id),
          thread_id: thread_id
        ]

        case acknowledge(Map.get(context, :workspace_root), steer_id, opts) do
          {:ok, record} ->
            %{"success" => true, "output" => "steer #{steer_id} acknowledged (status=#{record["status"]})"}

          {:error, reason} ->
            %{"success" => false, "output" => "steer acknowledgement rejected: #{inspect(reason)}"}
        end
    end
  end

  defp steer_id_from_arguments(arguments) when is_map(arguments) do
    case Map.get(arguments, "steer_id") || Map.get(arguments, :steer_id) do
      value when is_binary(value) and value != "" -> String.trim(value)
      _ -> nil
    end
  end

  defp steer_id_from_arguments(_other), do: nil

  @doc """
  Marks an ACKNOWLEDGED steer HANDLED. Duplicate calls are idempotent.
  """
  @spec mark_handled(String.t(), String.t()) :: {:ok, record()} | {:error, term()}
  def mark_handled(workspace_root, steer_id) do
    update_record(workspace_root, steer_id, fn record ->
      case record["status"] do
        "ACKNOWLEDGED" ->
          {:transition, record |> Map.put("status", "HANDLED") |> Map.put("handled_at", now_iso())}

        "HANDLED" ->
          {:ok, :no_op}

        status ->
          {:error, {:not_handledable, status}}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Restart reconciliation
  # ---------------------------------------------------------------------------

  @doc """
  Reconciles the steering store after a runtime restart.

  PENDING steers survive (they were never delivered). DELIVERED-but-
  unacknowledged steers survive durably but become STALE: the worker session
  that received them is gone, their acknowledgement can never be proven, and
  they must never be re-delivered to a replacement worker. ACKNOWLEDGED,
  HANDLED, FAILED, and STALE records are untouched.
  """
  @spec reconcile_after_restart(String.t()) :: %{
          pending: non_neg_integer(),
          staled: non_neg_integer(),
          retained: non_neg_integer(),
          unreadable: non_neg_integer()
        }
  def reconcile_after_restart(workspace_root) do
    workspace_root
    |> SteeringStore.list_records()
    |> Enum.reduce(%{pending: 0, staled: 0, retained: 0, unreadable: 0}, fn {_id, result}, acc ->
      case result do
        {:ok, %{"status" => "PENDING"}} ->
          Map.update!(acc, :pending, &(&1 + 1))

        {:ok, %{"status" => "DELIVERED"} = record} ->
          {:ok, _} = mark_stale(workspace_root, record, "runtime_restart_delivery_unverified")
          Map.update!(acc, :staled, &(&1 + 1))

        {:ok, _} ->
          Map.update!(acc, :retained, &(&1 + 1))

        {:error, _} ->
          Map.update!(acc, :unreadable, &(&1 + 1))
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Observability
  # ---------------------------------------------------------------------------

  @doc """
  Read-only steering summary for the observability snapshot. Never includes
  instruction text: operator steering content stays in workspace-owned state.
  """
  @spec snapshot_summary(String.t()) :: %{entries: [map()], counts: map()}
  def snapshot_summary(workspace_root) do
    results = SteeringStore.list_records(workspace_root)

    entries =
      results
      |> Enum.flat_map(fn {_id, result} ->
        case result do
          {:ok, record} ->
            [
              %{
                steer_id: record["steer_id"],
                issue_id: record["issue_id"],
                issue_identifier: record["issue_identifier"],
                attempt_id: record["attempt_id"],
                sequence: record["sequence"],
                status: record["status"],
                delivery_attempts: record["delivery_attempts"],
                worker_host: record["worker_host"],
                thread_id: record["thread_id"],
                created_at: record["created_at"],
                delivered_at: record["delivered_at"],
                acknowledged_at: record["acknowledged_at"],
                handled_at: record["handled_at"],
                failure_reason: record["failure_reason"],
                unreadable: false
              }
            ]

          {:error, reason} ->
            [%{steer_id: nil, status: "UNREADABLE", failure_reason: inspect(reason), unreadable: true}]
        end
      end)
      |> Enum.sort_by(&{&1[:issue_id] || "", &1[:sequence] || 0})

    counts = Enum.frequencies_by(entries, & &1.status)

    %{entries: entries, counts: counts}
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp identity_matches?(record, opts, include_thread \\ true) when is_map(opts) do
    issue_matches?(opts[:issue_id], record["issue_id"]) and
      attempt_matches?(opts[:attempt_id], record["attempt_id"]) and
      (not include_thread or thread_matches?(opts[:thread_id], record["delivery_thread_id"]))
  end

  defp issue_matches?(nil, _actual), do: true
  defp issue_matches?(expected, actual), do: expected == actual

  defp attempt_matches?(nil, _actual), do: true
  defp attempt_matches?(expected, actual), do: normalize_attempt(expected) == actual

  defp thread_matches?(nil, _actual), do: true
  defp thread_matches?(expected, actual), do: expected == actual

  defp delivery_value(delivery, key) do
    case Map.get(delivery, key) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp update_record(workspace_root, steer_id, transition_fn) do
    case SteeringStore.read_record(workspace_root, steer_id) do
      {:ok, record} ->
        case transition_fn.(record) do
          {:transition, updated} ->
            :ok = SteeringStore.write_record(workspace_root, updated)
            {:ok, updated}

          {:ok, :no_op} ->
            {:ok, record}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp mark_stale(workspace_root, record, reason) do
    updated =
      record
      |> Map.put("status", "STALE")
      |> Map.put("failure_reason", reason)

    :ok = SteeringStore.write_record(workspace_root, updated)
    {:ok, updated}
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
