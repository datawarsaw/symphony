defmodule SymphonyElixir.WorkerEvent do
  @moduledoc """
  Harness-neutral worker activity and completion event contract.

  Normalizes activity, terminal observations, timestamps, and available usage
  metadata from diverse execution harnesses (such as Codex and OpenCode) into a
  common representation consumed by Symphony's Orchestrator.

  OpenCode completion follows the CLI 1.18.28 run --format json contract.
  step_finish reasons stop, length, content-filter, and unknown are observational
  terminal indicators. tool-calls, a missing reason, and error are not successful
  completions. CLI completion does not depend on session.status idle. A terminal
  WorkerEvent never grants completion authority; successful_completion? stays
  false for OpenCode observations.
  """

  @type harness :: :codex | :opencode | :generic

  @type event_name ::
          :activity
          | :step_start
          | :step_finish
          | :tool_use
          | :text
          | :reasoning
          | :notification
          | :session_started
          | :session_status
          | :turn_completed
          | :turn_input_required
          | :approval_required
          | :input_required
          | :completed
          | :failed
          | :error
          | :raw
          | atom()

  @type t :: %__MODULE__{
          event: event_name(),
          event_type: atom() | String.t(),
          harness: harness(),
          timestamp: DateTime.t() | nil,
          session_id: String.t() | nil,
          message_id: String.t() | nil,
          payload: map() | term(),
          usage: map() | nil,
          rate_limits: map() | nil,
          terminal?: boolean(),
          raw: term(),
          metadata: map()
        }

  defstruct [
    :event,
    :event_type,
    :harness,
    :timestamp,
    :session_id,
    :message_id,
    :payload,
    :usage,
    :rate_limits,
    :terminal?,
    :raw,
    :metadata
  ]

  @behaviour Access

  @terminal_step_reasons ~w(stop length content-filter unknown)
  @max_evidence_bytes 4_096
  @truncated "…[truncated]"
  @redacted "[redacted]"
  @identifier_pattern ~r/^[A-Za-z0-9][A-Za-z0-9._:-]*$/
  @channels [:codex_worker_update, :worker_update]
  @secret_patterns [
    ~r/(?i)\bauthorization\s*:\s*bearer\s+\S+/,
    ~r/(?i)\bbearer\s+[A-Za-z0-9\-._~+\/=]{8,}/,
    ~r/(?i)\b(?:api[_-]?key|access[_-]?token|refresh[_-]?token|secret|password|credential|auth[_-]?token)\b\s*[=:]\s*["']?[^\s"',}]+/,
    ~r/\bsk-ant-[A-Za-z0-9_\-]{8,}\b/,
    ~r/\bsk-[A-Za-z0-9_\-]{8,}\b/,
    ~r/\bgh[pousr]_[A-Za-z0-9]{20,}\b/,
    ~r/\bxox[baprs]-[A-Za-z0-9\-]{10,}\b/,
    ~r/\bAKIA[0-9A-Z]{16}\b/,
    ~r/\blin_api_[A-Za-z0-9_\-]{8,}\b/
  ]

  @impl Access
  def fetch(%__MODULE__{} = event, key) when is_atom(key) do
    case Map.fetch(Map.from_struct(event), key) do
      {:ok, val} -> {:ok, val}
      :error -> :error
    end
  end

  def fetch(%__MODULE__{} = event, key) when is_binary(key) do
    case key do
      "event" -> {:ok, event.event}
      "event_type" -> {:ok, event.event_type}
      "harness" -> {:ok, event.harness}
      "timestamp" -> {:ok, event.timestamp}
      "session_id" -> {:ok, event.session_id}
      "message_id" -> {:ok, event.message_id}
      "payload" -> {:ok, event.payload}
      "usage" -> {:ok, event.usage}
      "rate_limits" -> {:ok, event.rate_limits}
      "terminal?" -> {:ok, event.terminal?}
      "raw" -> {:ok, event.raw}
      "metadata" -> {:ok, event.metadata}
      _ -> :error
    end
  end

  def fetch(_event, _key), do: :error

  @impl Access
  def get_and_update(%__MODULE__{} = event, key, fun) do
    key_atom = if is_binary(key), do: String.to_existing_atom(key), else: key
    val = Map.get(event, key_atom)

    case fun.(val) do
      {current, next} -> {current, Map.put(event, key_atom, next)}
      :pop -> {val, Map.put(event, key_atom, nil)}
    end
  rescue
    ArgumentError -> {nil, event}
  end

  @impl Access
  def pop(%__MODULE__{} = event, key) do
    key_atom = if is_binary(key), do: String.to_existing_atom(key), else: key
    val = Map.get(event, key_atom)
    {val, Map.put(event, key_atom, nil)}
  rescue
    ArgumentError -> {nil, event}
  end

  @doc """
  Constructs a new WorkerEvent struct with normalized defaults.

  Missing or invalid timestamps stay nil. They are not replaced with the
  current time, so a constructed event cannot prove fresh liveness.
  """
  @spec new(map() | keyword()) :: t()
  def new(attrs \\ %{}) do
    attrs = if is_list(attrs), do: Map.new(attrs), else: attrs

    event = Map.get(attrs, :event) || Map.get(attrs, "event") || :activity
    event_type = Map.get(attrs, :event_type) || Map.get(attrs, "event_type") || event
    harness = Map.get(attrs, :harness) || Map.get(attrs, "harness") || :generic
    timestamp = normalize_timestamp(Map.get(attrs, :timestamp) || Map.get(attrs, "timestamp"))

    terminal? =
      case Map.get(attrs, :terminal?) || Map.get(attrs, "terminal?") do
        nil -> terminal_event?(event)
        val -> !!val
      end

    session_id = Map.get(attrs, :session_id) || Map.get(attrs, "session_id")
    message_id = Map.get(attrs, :message_id) || Map.get(attrs, "message_id")
    payload = Map.get(attrs, :payload) || Map.get(attrs, "payload") || %{}
    usage = normalize_usage(Map.get(attrs, :usage) || Map.get(attrs, "usage"))
    rate_limits = Map.get(attrs, :rate_limits) || Map.get(attrs, "rate_limits")
    raw = Map.get(attrs, :raw) || Map.get(attrs, "raw")
    metadata = Map.get(attrs, :metadata) || Map.get(attrs, "metadata") || %{}

    sanitize(%__MODULE__{
      event: event,
      event_type: event_type,
      harness: harness,
      timestamp: timestamp,
      session_id: session_id,
      message_id: message_id,
      payload: payload,
      usage: usage,
      rate_limits: rate_limits,
      terminal?: terminal?,
      raw: raw,
      metadata: metadata
    })
  end

  @doc """
  Returns whether an event is an observational terminal signal.

  For OpenCode this does not mean the worker execution succeeded.
  """
  @spec terminal?(t() | map()) :: boolean()
  def terminal?(%__MODULE__{terminal?: term}) when is_boolean(term), do: term
  def terminal?(%{terminal?: term}) when is_boolean(term), do: term
  def terminal?(%{event: event}), do: terminal_event?(event)
  def terminal?(_), do: false

  @doc """
  Returns whether an event represents intermediate activity (i.e. not terminal).
  """
  @spec intermediate?(t() | map()) :: boolean()
  def intermediate?(event), do: not terminal?(event)

  @doc """
  Returns whether an event has a usable timestamp for liveness tracking.

  Missing and invalid timestamps are not activity proof.
  """
  @spec activity?(t() | map()) :: boolean()
  def activity?(%__MODULE__{timestamp: %DateTime{}}), do: true
  def activity?(%{timestamp: %DateTime{}}), do: true
  def activity?(_), do: false

  defp terminal_event?(event)
       when event in [
              :turn_completed,
              :completed,
              :failed,
              :error,
              :turn_failed,
              :startup_failed
            ],
       do: true

  defp terminal_event?(_event), do: false

  @doc """
  Normalizes an existing Codex update message into a WorkerEvent.
  """
  @spec from_codex(map(), keyword()) :: t()
  def from_codex(message, opts \\ [])
  def from_codex(%__MODULE__{} = event, _opts), do: sanitize(event)

  def from_codex(%{} = message, opts) do
    event = Map.get(message, :event) || Map.get(message, "event") || :activity
    timestamp = normalize_timestamp(Map.get(message, :timestamp) || Map.get(message, "timestamp"))
    session_id = Map.get(message, :session_id) || Map.get(message, "session_id")
    payload = Map.get(message, :payload) || Map.get(message, "payload") || %{}
    usage = normalize_usage(Map.get(message, :usage) || Map.get(message, "usage") || payload)
    rate_limits = Map.get(message, :rate_limits) || Map.get(message, "rate_limits")

    metadata =
      %{
        model: Map.get(message, :model) || Map.get(message, "model"),
        reasoning_effort: Map.get(message, :reasoning_effort) || Map.get(message, "reasoning_effort"),
        route_source: Map.get(message, :route_source) || Map.get(message, "route_source"),
        codex_app_server_pid: Map.get(message, :codex_app_server_pid) || Map.get(message, "codex_app_server_pid")
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    new(%{
      event: event,
      event_type: event,
      harness: :codex,
      timestamp: timestamp,
      session_id: session_id,
      payload: payload,
      usage: usage,
      rate_limits: rate_limits,
      terminal?: terminal_event?(event),
      raw: Map.get(message, :raw) || Map.get(message, "raw") || message,
      metadata: Map.merge(metadata, Keyword.get(opts, :metadata, %{}))
    })
  end

  @doc """
  Parses and normalizes an OpenCode JSONL event into a WorkerEvent.
  Accepts a JSON string or a decoded map.
  """
  @spec from_opencode(binary() | map(), keyword()) :: t()
  def from_opencode(binary_or_map, opts \\ [])

  def from_opencode(binary, opts) when is_binary(binary) do
    trimmed = String.trim(binary)

    case Jason.decode(trimmed) do
      {:ok, %{} = map} ->
        from_opencode(map, Keyword.put(opts, :raw, trimmed))

      {:error, reason} ->
        new(%{
          event: :raw,
          event_type: :malformed_json,
          harness: :opencode,
          timestamp: nil,
          payload: %{error: :json_decode_error, detail: decode_error_detail(reason)},
          terminal?: false,
          raw: trimmed,
          metadata: opencode_metadata(Keyword.get(opts, :metadata, %{}), %{usage_accounting: :event})
        })
    end
  end

  def from_opencode(%{} = map, opts) do
    raw = Keyword.get(opts, :raw, map)
    type = Map.get(map, "type") || Map.get(map, :type)
    timestamp = normalize_timestamp(Map.get(map, "timestamp") || Map.get(map, :timestamp))
    session_id = extract_opencode_session_id(map)

    case type do
      "step_start" ->
        part = event_part(map)
        message_id = part_message_id(part)
        part_id = part_id(part)

        new(%{
          event: :step_start,
          event_type: :step_start,
          harness: :opencode,
          timestamp: timestamp,
          session_id: session_id,
          message_id: message_id,
          payload: map,
          terminal?: false,
          raw: raw,
          metadata:
            opencode_metadata(%{
              usage_accounting: :step,
              event_id: step_event_id(:step_start, session_id, message_id, part_id, nil, timestamp)
            })
        })

      "step_finish" ->
        part = event_part(map)
        tokens = Map.get(part, "tokens") || Map.get(part, :tokens) || %{}
        cost = Map.get(part, "cost") || Map.get(part, :cost) || 0.0
        message_id = part_message_id(part)
        part_id = part_id(part)
        reason = Map.get(part, "reason") || Map.get(part, :reason)
        usage = normalize_opencode_tokens(tokens, cost)

        new(%{
          event: :step_finish,
          event_type: :step_finish,
          harness: :opencode,
          timestamp: timestamp,
          session_id: session_id,
          message_id: message_id,
          payload: map,
          usage: usage,
          terminal?: terminal_step_reason?(reason),
          raw: raw,
          metadata:
            opencode_metadata(%{
              finish_reason: reason,
              usage_accounting: :step,
              event_id: step_event_id(:step_finish, session_id, message_id, part_id, reason, timestamp)
            })
        })

      "tool_use" ->
        part = event_part(map)
        state_map = Map.get(part, "state") || Map.get(part, :state) || %{}
        tool_status = Map.get(state_map, "status") || Map.get(state_map, :status)
        error = Map.get(state_map, "error") || Map.get(state_map, :error)
        tool_error? = tool_status == "error" or not is_nil(error)

        payload = %{
          tool: Map.get(part, "tool") || Map.get(part, :tool),
          call_id: Map.get(part, "callID") || Map.get(part, :callID) || Map.get(part, "id"),
          status: tool_status,
          error: error,
          output: Map.get(state_map, "output") || Map.get(state_map, :output)
        }

        new(%{
          event: :tool_use,
          event_type: :tool_use,
          harness: :opencode,
          timestamp: timestamp,
          session_id: session_id,
          message_id: part_message_id(part),
          payload: payload,
          terminal?: false,
          raw: raw,
          metadata: opencode_metadata(%{tool_error?: tool_error?, usage_accounting: :event})
        })

      "text" ->
        part = event_part(map)

        new(%{
          event: :text,
          event_type: :text,
          harness: :opencode,
          timestamp: timestamp,
          session_id: session_id,
          message_id: part_message_id(part),
          payload: %{text: Map.get(part, "text") || Map.get(part, :text)},
          terminal?: false,
          raw: raw,
          metadata: opencode_metadata(%{usage_accounting: :event})
        })

      "reasoning" ->
        part = event_part(map)

        new(%{
          event: :reasoning,
          event_type: :reasoning,
          harness: :opencode,
          timestamp: timestamp,
          session_id: session_id,
          message_id: part_message_id(part),
          payload: %{text: Map.get(part, "text") || Map.get(part, :text)},
          terminal?: false,
          raw: raw,
          metadata: opencode_metadata(%{usage_accounting: :event})
        })

      "session.status" ->
        status_type = session_status_type(map)

        case status_type do
          "error" ->
            new(%{
              event: :failed,
              event_type: :session_status,
              harness: :opencode,
              timestamp: timestamp,
              session_id: session_id,
              payload: map,
              terminal?: true,
              raw: raw,
              metadata: opencode_metadata(%{usage_accounting: :event, session_status: "error"})
            })

          _ ->
            new(%{
              event: if(status_type == "idle", do: :session_status, else: :activity),
              event_type: :session_status,
              harness: :opencode,
              timestamp: timestamp,
              session_id: session_id,
              payload: map,
              terminal?: false,
              raw: raw,
              metadata: opencode_metadata(%{usage_accounting: :event, session_status: status_type})
            })
        end

      type when type in ["error", "session.error"] ->
        new(%{
          event: :error,
          event_type: :error,
          harness: :opencode,
          timestamp: timestamp,
          session_id: session_id,
          payload: map,
          terminal?: true,
          raw: raw,
          metadata: opencode_metadata(%{usage_accounting: :event})
        })

      other ->
        new(%{
          event: :activity,
          event_type: other || :activity,
          harness: :opencode,
          timestamp: timestamp,
          session_id: session_id,
          payload: map,
          terminal?: false,
          raw: raw,
          metadata: opencode_metadata(%{usage_accounting: :event})
        })
    end
  end

  @doc """
  Convenience helper to parse a JSONL line from OpenCode.
  """
  @spec from_jsonl(binary(), keyword()) :: t()
  def from_jsonl(line, opts \\ []), do: from_opencode(line, opts)

  @doc """
  Normalizes any event (string JSONL, OpenCode map, Codex message, or WorkerEvent)
  into a WorkerEvent.
  """
  @spec normalize(term(), keyword()) :: t()
  def normalize(term, opts \\ [])

  def normalize(%__MODULE__{} = event, opts) do
    event = sanitize(event)

    if Keyword.has_key?(opts, :harness) do
      %{event | harness: Keyword.get(opts, :harness)}
    else
      event
    end
  end

  def normalize(binary, opts) when is_binary(binary) do
    from_opencode(binary, opts)
  end

  def normalize(%{} = map, opts) do
    cond do
      Map.has_key?(map, "type") or Map.has_key?(map, :type) ->
        from_opencode(map, opts)

      Map.has_key?(map, :event) or Map.has_key?(map, "event") ->
        from_codex(map, opts)

      true ->
        harness = Keyword.get(opts, :harness, :generic)
        new(Map.put(map, :harness, harness))
    end
  end

  def normalize(other, opts) do
    new(%{
      event: :raw,
      event_type: :raw,
      harness: Keyword.get(opts, :harness, :generic),
      timestamp: nil,
      payload: %{error: :unrecognized_event},
      terminal?: false,
      raw: inspect(other)
    })
  end

  @doc """
  Folds one worker event into an accumulator.

  OpenCode step_finish usage is per step. The returned event carries the
  cumulative snapshot. Repeated step identities are duplicates and do not add
  usage again. A session id that changes after the first accepted session is
  rejected instead of overwriting accumulator state.
  """
  @spec accumulate(map() | nil, term()) :: {:ok, map(), t()} | {:duplicate, map()} | {:rejected, map()}
  def accumulate(state, raw_event) do
    state = init_accumulator(state)
    event = normalize(raw_event)

    cond do
      not session_acceptable?(state, event) ->
        {:rejected, state}

      duplicate_step?(state, event) ->
        {:duplicate, state}

      true ->
        {state, event} = apply_step_usage(state, event)
        {:ok, lock_session(state, event), event}
    end
  end

  @doc """
  Classifies a candidate activity timestamp against the last accepted one.

  :invalid means the candidate is missing or unparseable and must not be
  treated as fresh liveness. :stale means it is older than the accepted clock.
  """
  @spec classify_activity_timestamp(DateTime.t() | nil, term()) ::
          {:fresh, DateTime.t()} | :stale | :invalid
  def classify_activity_timestamp(previous, candidate) do
    case normalize_timestamp(candidate) do
      %DateTime{} = dt ->
        case previous do
          %DateTime{} = prev ->
            if DateTime.compare(dt, prev) == :lt, do: :stale, else: {:fresh, dt}

          _ ->
            {:fresh, dt}
        end

      _ ->
        :invalid
    end
  end

  @doc """
  Converts a WorkerEvent into an update map compatible with Symphony's update channel.

  Payloads, raw evidence, and metadata are redacted and bounded first. OpenCode
  updates always carry successful_completion?: false.
  """
  @spec to_update(t() | map()) :: map()
  def to_update(%__MODULE__{} = event) do
    event = sanitize(event)

    update =
      %{
        event: event.event,
        timestamp: event.timestamp,
        session_id: event.session_id,
        message_id: event.message_id,
        payload: event.payload,
        usage: event.usage,
        rate_limits: event.rate_limits,
        terminal?: event.terminal?,
        raw: event.raw,
        harness: event.harness
      }

    update =
      if is_map(event.metadata) do
        Map.merge(event.metadata, update)
      else
        update
      end

    update =
      if event.harness == :opencode do
        Map.put(update, :successful_completion?, false)
      else
        update
      end

    update = redact(update)

    if is_map(event.usage) do
      in_tokens = usage_number(event.usage, :input_tokens)
      out_tokens = usage_number(event.usage, :output_tokens)
      explicit_total = usage_number(event.usage, :total_tokens)
      total_tokens = if explicit_total == 0 and (in_tokens != 0 or out_tokens != 0), do: in_tokens + out_tokens, else: explicit_total

      Map.put(update, :tokenUsage, %{
        total: %{
          inputTokens: in_tokens,
          outputTokens: out_tokens,
          totalTokens: total_tokens
        }
      })
    else
      update
    end
  end

  def to_update(%{} = map) do
    map
    |> normalize()
    |> to_update()
  end

  @doc """
  Builds a minimal event callback function for worker adapters (such as OpenCode).

  Malformed issue ids, dead recipients, unexpected session changes, and duplicate
  step events are dropped. The callback cannot reintroduce raw evidence that
  redaction removed, and it cannot mark an OpenCode execution successful.
  """
  @spec callback(pid() | nil, term(), keyword()) :: (term() -> :ok)
  def callback(recipient, issue_or_id, opts \\ []) do
    issue_id = extract_issue_id(issue_or_id)
    channel = normalize_channel(Keyword.get(opts, :channel, :codex_worker_update))
    bound_session = Keyword.get(opts, :session_id)

    if not valid_recipient?(recipient) or not valid_identifier?(issue_id) do
      fn _raw_event -> :ok end
    else
      {:ok, agent} =
        Agent.start_link(fn ->
          init_accumulator(%{
            session_id: if(valid_identifier?(bound_session), do: bound_session, else: nil)
          })
        end)

      fn raw_event ->
        if valid_recipient?(recipient) do
          result =
            Agent.get_and_update(agent, fn state ->
              case accumulate(state, raw_event) do
                {:ok, new_state, event} -> {{:ok, event}, new_state}
                {:duplicate, new_state} -> {:duplicate, new_state}
                {:rejected, new_state} -> {:rejected, new_state}
              end
            end)

          case result do
            {:ok, event} ->
              send(recipient, {channel, issue_id, to_update(event)})
              :ok

            _ ->
              :ok
          end
        else
          :ok
        end
      end
    end
  end

  @doc """
  Normalizes timestamps to UTC.

  Returns nil for missing or invalid values. Callers must not substitute the
  current time when they need liveness proof.
  """
  @spec normalize_timestamp(term()) :: DateTime.t() | nil
  def normalize_timestamp(nil), do: nil
  def normalize_timestamp(%DateTime{} = dt), do: DateTime.shift_zone!(dt, "Etc/UTC")
  def normalize_timestamp(%NaiveDateTime{} = ndt), do: DateTime.from_naive!(ndt, "Etc/UTC")

  def normalize_timestamp(ts) when is_integer(ts) and ts > 1_000_000_000_000 do
    case DateTime.from_unix(ts, :millisecond) do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  def normalize_timestamp(ts) when is_integer(ts) and ts > 0 do
    case DateTime.from_unix(ts, :second) do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  def normalize_timestamp(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  def normalize_timestamp(_), do: nil

  defp init_accumulator(nil), do: init_accumulator(%{})

  defp init_accumulator(%{} = state) do
    %{
      usage: state[:usage] || empty_usage(),
      seen: state[:seen] || MapSet.new(),
      session_id: state[:session_id]
    }
  end

  defp empty_usage do
    %{
      input_tokens: 0,
      output_tokens: 0,
      reasoning_tokens: 0,
      cache_read_tokens: 0,
      cache_write_tokens: 0,
      total_tokens: 0,
      cost: 0.0
    }
  end

  defp apply_step_usage(state, %__MODULE__{event: :step_finish} = event) do
    case event_id_of(event) do
      id when is_binary(id) ->
        usage = add_usage(state.usage, event.usage)

        event = %{
          event
          | usage: usage,
            metadata:
              Map.merge(event.metadata || %{}, %{
                event_id: id,
                usage_accounting: :cumulative,
                successful_completion?: false
              })
        }

        {%{state | usage: usage, seen: MapSet.put(state.seen, id)}, event}

      _ ->
        {state, event}
    end
  end

  defp apply_step_usage(state, %__MODULE__{event: :step_start} = event) do
    case event_id_of(event) do
      id when is_binary(id) ->
        {%{state | seen: MapSet.put(state.seen, id)}, event}

      _ ->
        {state, event}
    end
  end

  defp apply_step_usage(state, event), do: {state, event}

  defp duplicate_step?(state, event) do
    case event_id_of(event) do
      id when is_binary(id) and event.event in [:step_start, :step_finish] ->
        MapSet.member?(state.seen, id)

      _ ->
        false
    end
  end

  defp session_acceptable?(_state, %__MODULE__{session_id: nil}), do: true

  defp session_acceptable?(state, %__MODULE__{session_id: session_id}) do
    cond do
      not valid_identifier?(session_id) -> false
      is_nil(state.session_id) -> true
      state.session_id == session_id -> true
      true -> false
    end
  end

  defp lock_session(%{session_id: nil} = state, %__MODULE__{session_id: session_id}) do
    if valid_identifier?(session_id), do: %{state | session_id: session_id}, else: state
  end

  defp lock_session(state, _event), do: state

  defp add_usage(acc, nil), do: acc

  defp add_usage(acc, usage) when is_map(usage) do
    input = acc.input_tokens + usage_number(usage, :input_tokens)
    output = acc.output_tokens + usage_number(usage, :output_tokens)

    %{
      input_tokens: input,
      output_tokens: output,
      reasoning_tokens: acc.reasoning_tokens + usage_number(usage, :reasoning_tokens),
      cache_read_tokens: acc.cache_read_tokens + usage_number(usage, :cache_read_tokens),
      cache_write_tokens: acc.cache_write_tokens + usage_number(usage, :cache_write_tokens),
      total_tokens: input + output,
      cost: to_float(acc.cost) + to_float(usage_number(usage, :cost))
    }
  end

  defp add_usage(acc, _usage), do: acc

  defp event_id_of(%__MODULE__{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, :event_id) || Map.get(metadata, "event_id") do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp event_id_of(_), do: nil

  defp terminal_step_reason?(reason) when is_binary(reason), do: reason in @terminal_step_reasons
  defp terminal_step_reason?(_), do: false

  defp opencode_metadata(extra) when is_map(extra) do
    Map.put(extra, :successful_completion?, false)
  end

  defp opencode_metadata(base, extra) when is_map(base) do
    base
    |> Map.merge(extra)
    |> opencode_metadata()
  end

  defp step_event_id(type, session_id, message_id, part_id, reason, timestamp) do
    suffix =
      if blank?(message_id) and blank?(part_id) do
        ":" <> timestamp_token(timestamp)
      else
        ""
      end

    Enum.join(
      [
        "opencode",
        Atom.to_string(type),
        session_id || "",
        message_id || "",
        part_id || "",
        reason || ""
      ],
      ":"
    ) <> suffix
  end

  defp timestamp_token(%DateTime{} = dt), do: Integer.to_string(DateTime.to_unix(dt, :millisecond))
  defp timestamp_token(_), do: "missing"

  defp blank?(value), do: not is_binary(value) or value == ""

  defp event_part(map) when is_map(map) do
    Map.get(map, "part") || Map.get(map, :part) || %{}
  end

  defp part_message_id(part) when is_map(part) do
    Map.get(part, "messageID") || Map.get(part, :messageID)
  end

  defp part_message_id(_), do: nil

  defp part_id(part) when is_map(part) do
    Map.get(part, "id") || Map.get(part, :id)
  end

  defp part_id(_), do: nil

  defp session_status_type(map) do
    get_in(map, ["properties", "status", "type"]) ||
      get_in(map, [:properties, :status, :type]) ||
      get_in(map, ["status", "type"]) ||
      get_in(map, [:status, :type])
  end

  defp decode_error_detail(%Jason.DecodeError{} = error) do
    %{
      position: error.position,
      token: redact_token(error.token)
    }
  end

  defp decode_error_detail(reason) do
    %{reason: reason |> inspect() |> redact()}
  end

  defp redact_token(nil), do: nil

  defp redact_token(token) do
    token
    |> to_string()
    |> redact()
  end

  defp extract_issue_id(%{id: id}) when is_binary(id), do: id
  defp extract_issue_id(id) when is_binary(id), do: id
  defp extract_issue_id(_), do: nil

  defp extract_opencode_session_id(map) when is_map(map) do
    Map.get(map, "sessionID") ||
      Map.get(map, :sessionID) ||
      get_in(map, ["part", "sessionID"]) ||
      get_in(map, [:part, :sessionID]) ||
      get_in(map, ["properties", "sessionID"]) ||
      get_in(map, [:properties, :sessionID]) ||
      get_in(map, ["properties", "info", "id"]) ||
      get_in(map, [:properties, :info, :id])
  end

  defp extract_opencode_session_id(_), do: nil

  defp valid_identifier?(value) when is_binary(value) do
    size = byte_size(value)
    size in 1..200 and Regex.match?(@identifier_pattern, value)
  end

  defp valid_identifier?(_), do: false

  defp valid_recipient?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp valid_recipient?(_), do: false

  defp normalize_channel(channel) when channel in @channels, do: channel
  defp normalize_channel(_), do: :codex_worker_update

  defp normalize_opencode_tokens(tokens, cost) when is_map(tokens) do
    in_tokens = usage_number(tokens, :input, "input")
    out_tokens = usage_number(tokens, :output, "output")
    reasoning_tokens = usage_number(tokens, :reasoning, "reasoning")
    cache = Map.get(tokens, "cache") || Map.get(tokens, :cache) || %{}
    cache_read = usage_number(cache, :read, "read")
    cache_write = usage_number(cache, :write, "write")

    %{
      input_tokens: in_tokens,
      output_tokens: out_tokens,
      reasoning_tokens: reasoning_tokens,
      cache_read_tokens: cache_read,
      cache_write_tokens: cache_write,
      total_tokens: in_tokens + out_tokens,
      cost: to_float(cost)
    }
  end

  defp normalize_opencode_tokens(_tokens, _cost), do: nil

  defp normalize_usage(%{} = usage) do
    in_tokens =
      first_present(usage, [
        :input_tokens,
        "input_tokens",
        :input,
        "input",
        :prompt_tokens,
        "prompt_tokens"
      ])

    out_tokens =
      first_present(usage, [
        :output_tokens,
        "output_tokens",
        :output,
        "output",
        :completion_tokens,
        "completion_tokens"
      ])

    total_tokens = first_present(usage, [:total_tokens, "total_tokens", :total, "total"])

    in_val = integer_or_nil(in_tokens)
    out_val = integer_or_nil(out_tokens)
    tot_val = integer_or_nil(total_tokens) || if in_val && out_val, do: in_val + out_val, else: nil

    if in_val || out_val || tot_val do
      base = %{
        input_tokens: in_val || 0,
        output_tokens: out_val || 0,
        total_tokens: tot_val || (in_val || 0) + (out_val || 0)
      }

      cleaned_usage =
        usage
        |> Map.delete("input_tokens")
        |> Map.delete("output_tokens")
        |> Map.delete("total_tokens")
        |> Map.delete("input")
        |> Map.delete("output")
        |> Map.delete("total")
        |> Map.delete("prompt_tokens")
        |> Map.delete("completion_tokens")

      Map.merge(cleaned_usage, base)
    else
      nil
    end
  end

  defp normalize_usage(_), do: nil

  defp first_present(map, keys) do
    Enum.find_value(keys, fn key ->
      if is_map(map) and Map.has_key?(map, key), do: Map.get(map, key)
    end)
  end

  defp usage_number(map, key, alt \\ nil) do
    value =
      cond do
        not is_map(map) ->
          0

        Map.has_key?(map, key) ->
          Map.get(map, key)

        is_binary(alt) and Map.has_key?(map, alt) ->
          Map.get(map, alt)

        is_atom(key) and Map.has_key?(map, Atom.to_string(key)) ->
          Map.get(map, Atom.to_string(key))

        true ->
          0
      end

    cond do
      is_integer(value) and value >= 0 -> value
      is_float(value) and value >= 0 -> value
      true -> integer_or_nil(value) || 0
    end
  end

  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value * 1.0
  defp to_float(_), do: 0.0

  defp integer_or_nil(val) when is_integer(val) and val >= 0, do: val

  defp integer_or_nil(val) when is_binary(val) do
    case Integer.parse(val) do
      {num, ""} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_or_nil(val) when is_float(val) and val >= 0, do: trunc(val)
  defp integer_or_nil(_), do: nil

  defp sanitize(%__MODULE__{} = event) do
    %{
      event
      | payload: redact(event.payload),
        raw: redact(event.raw),
        metadata: redact(event.metadata || %{})
    }
  end

  defp redact(value) when is_binary(value) do
    value
    |> scrub()
    |> bound()
    |> scrub()
  end

  defp redact(value) when is_list(value), do: Enum.map(value, &redact/1)
  defp redact(%_{} = value), do: value

  defp redact(value) when is_map(value) do
    Map.new(value, fn {key, inner} -> {key, redact(inner)} end)
  end

  defp redact(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> redact()
    |> List.to_tuple()
  end

  defp redact(value), do: value

  defp scrub(value) do
    Enum.reduce(@secret_patterns, value, fn pattern, acc ->
      Regex.replace(pattern, acc, @redacted)
    end)
  end

  defp bound(value) when byte_size(value) <= @max_evidence_bytes, do: value

  defp bound(value) do
    value
    |> binary_part(0, @max_evidence_bytes)
    |> drop_partial_codepoint()
    |> Kernel.<>(@truncated)
  end

  defp drop_partial_codepoint(binary) do
    size = byte_size(binary)

    if String.valid?(binary) or size == 0 do
      binary
    else
      dangling = count_dangling_bytes(binary, min(size, 4), 0)
      binary_part(binary, 0, size - dangling)
    end
  end

  defp count_dangling_bytes(_binary, 0, count), do: count

  defp count_dangling_bytes(binary, left, count) do
    size = byte_size(binary)
    <<byte>> = binary_part(binary, size - 1, 1)

    if byte >= 0x80 do
      count_dangling_bytes(binary_part(binary, 0, size - 1), left - 1, count + 1)
    else
      count
    end
  end
end
