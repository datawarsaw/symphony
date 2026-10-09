defmodule SymphonyElixir.WorkerEvent do
  @moduledoc """
  Harness-neutral worker activity and completion event contract.

  Normalizes activity, terminal events, timestamps, and available usage metadata
  from diverse execution harnesses (such as Codex and OpenCode) into a common
  representation and update payload format consumed by Symphony's Orchestrator.
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
          timestamp: DateTime.t(),
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

    %__MODULE__{
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
    }
  end

  @doc """
  Returns whether an event represents terminal completion or failure of a turn or session.
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
  Returns whether an event represents observable worker activity for liveness tracking.
  """
  @spec activity?(t() | map()) :: boolean()
  def activity?(%__MODULE__{}), do: true
  def activity?(%{timestamp: _}), do: true
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
  def from_codex(%__MODULE__{} = event, _opts), do: event

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
    case Jason.decode(String.trim(binary)) do
      {:ok, %{} = map} ->
        from_opencode(map, Keyword.put(opts, :raw, binary))

      {:error, reason} ->
        new(%{
          event: :raw,
          event_type: :raw,
          harness: :opencode,
          timestamp: DateTime.utc_now(),
          payload: %{error: :json_decode_error, reason: inspect(reason)},
          terminal?: false,
          raw: binary,
          metadata: Keyword.get(opts, :metadata, %{})
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
        new(%{
          event: :step_start,
          event_type: :step_start,
          harness: :opencode,
          timestamp: timestamp,
          session_id: session_id,
          payload: map,
          terminal?: false,
          raw: raw
        })

      "step_finish" ->
        part = Map.get(map, "part") || Map.get(map, :part) || %{}
        tokens = Map.get(part, "tokens") || Map.get(part, :tokens) || %{}
        cost = Map.get(part, "cost") || Map.get(part, :cost) || 0.0
        message_id = Map.get(part, "messageID") || Map.get(part, :messageID)

        usage =
          Keyword.get(opts, :cumulative_usage) ||
            normalize_opencode_tokens(tokens, cost)

        new(%{
          event: :step_finish,
          event_type: :step_finish,
          harness: :opencode,
          timestamp: timestamp,
          session_id: session_id,
          message_id: message_id,
          payload: map,
          usage: usage,
          terminal?: false,
          raw: raw
        })

      "tool_use" ->
        part = Map.get(map, "part") || Map.get(map, :part) || %{}
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
          message_id: Map.get(part, "messageID") || Map.get(part, :messageID),
          payload: payload,
          terminal?: false,
          raw: raw,
          metadata: %{tool_error?: tool_error?}
        })

      "text" ->
        part = Map.get(map, "part") || Map.get(map, :part) || %{}

        new(%{
          event: :text,
          event_type: :text,
          harness: :opencode,
          timestamp: timestamp,
          session_id: session_id,
          message_id: Map.get(part, "messageID") || Map.get(part, :messageID),
          payload: %{text: Map.get(part, "text") || Map.get(part, :text)},
          terminal?: false,
          raw: raw
        })

      "reasoning" ->
        part = Map.get(map, "part") || Map.get(map, :part) || %{}

        new(%{
          event: :reasoning,
          event_type: :reasoning,
          harness: :opencode,
          timestamp: timestamp,
          session_id: session_id,
          message_id: Map.get(part, "messageID") || Map.get(part, :messageID),
          payload: %{text: Map.get(part, "text") || Map.get(part, :text)},
          terminal?: false,
          raw: raw
        })

      "session.status" ->
        status_type =
          get_in(map, ["properties", "status", "type"]) ||
            get_in(map, [:properties, :status, :type]) ||
            get_in(map, ["status", "type"]) ||
            get_in(map, [:status, :type])

        case status_type do
          "idle" ->
            new(%{
              event: :turn_completed,
              event_type: :turn_completed,
              harness: :opencode,
              timestamp: timestamp,
              session_id: session_id,
              payload: map,
              terminal?: true,
              raw: raw
            })

          "error" ->
            new(%{
              event: :failed,
              event_type: :failed,
              harness: :opencode,
              timestamp: timestamp,
              session_id: session_id,
              payload: map,
              terminal?: true,
              raw: raw
            })

          _ ->
            new(%{
              event: :activity,
              event_type: :session_status,
              harness: :opencode,
              timestamp: timestamp,
              session_id: session_id,
              payload: map,
              terminal?: false,
              raw: raw
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
          raw: raw
        })

      other ->
        event_name =
          cond do
            is_atom(other) ->
              other

            is_binary(other) and other != "" ->
              try do
                String.to_existing_atom(other)
              rescue
                ArgumentError -> :activity
              end

            true ->
              :activity
          end

        new(%{
          event: event_name,
          event_type: other || :activity,
          harness: :opencode,
          timestamp: timestamp,
          session_id: session_id,
          payload: map,
          terminal?: false,
          raw: raw
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

  @doc """
  Converts a WorkerEvent into an update map compatible with Symphony's update channel
  and orchestrator event ingestion.
  """
  @spec to_update(t() | map()) :: map()
  def to_update(%__MODULE__{} = event) do
    update = %{
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
        Map.merge(update, event.metadata)
      else
        update
      end

    if is_map(event.usage) do
      in_tokens =
        Map.get(event.usage, :input_tokens) || Map.get(event.usage, "input_tokens") || 0

      out_tokens =
        Map.get(event.usage, :output_tokens) || Map.get(event.usage, "output_tokens") || 0

      total_tokens =
        Map.get(event.usage, :total_tokens) ||
          Map.get(event.usage, "total_tokens") || in_tokens + out_tokens

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
  When called with any worker event (JSONL string, map, or WorkerEvent), it:
  1. Normalizes the event into a WorkerEvent
  2. Formats it into the update channel payload
  3. Dispatches it to recipient as {channel, issue_id, update}

  Default channel is :codex_worker_update (also supports :worker_update).
  """
  @spec callback(pid() | nil, term(), keyword()) :: (term() -> :ok)
  def callback(recipient, issue_or_id, opts \\ []) do
    issue_id = extract_issue_id(issue_or_id)
    channel = Keyword.get(opts, :channel, :codex_worker_update)
    harness = Keyword.get(opts, :harness, :generic)

    fn raw_event ->
      if is_pid(recipient) and is_binary(issue_id) do
        event = normalize(raw_event, Keyword.put(opts, :harness, harness))
        update = to_update(event)
        send(recipient, {channel, issue_id, update})
        :ok
      else
        :ok
      end
    end
  end

  @doc """
  Normalizes various timestamp formats (DateTime, unix millisecond/second integer,
  ISO8601 string) to UTC DateTime.
  """
  @spec normalize_timestamp(term()) :: DateTime.t()
  def normalize_timestamp(%DateTime{} = dt), do: DateTime.shift_zone!(dt, "Etc/UTC")
  def normalize_timestamp(%NaiveDateTime{} = ndt), do: DateTime.from_naive!(ndt, "Etc/UTC")

  def normalize_timestamp(ts) when is_integer(ts) and ts > 1_000_000_000_000 do
    case DateTime.from_unix(ts, :millisecond) do
      {:ok, dt} -> dt
      _ -> DateTime.utc_now()
    end
  end

  def normalize_timestamp(ts) when is_integer(ts) and ts > 0 do
    case DateTime.from_unix(ts, :second) do
      {:ok, dt} -> dt
      _ -> DateTime.utc_now()
    end
  end

  def normalize_timestamp(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      _ -> DateTime.utc_now()
    end
  end

  def normalize_timestamp(_), do: DateTime.utc_now()

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

  defp normalize_opencode_tokens(tokens, cost) when is_map(tokens) do
    in_tokens = Map.get(tokens, "input") || Map.get(tokens, :input) || 0
    out_tokens = Map.get(tokens, "output") || Map.get(tokens, :output) || 0
    reasoning_tokens = Map.get(tokens, "reasoning") || Map.get(tokens, :reasoning) || 0
    cache = Map.get(tokens, "cache") || Map.get(tokens, :cache) || %{}
    cache_read = Map.get(cache, "read") || Map.get(cache, :read) || 0
    cache_write = Map.get(cache, "write") || Map.get(cache, :write) || 0

    %{
      input_tokens: in_tokens,
      output_tokens: out_tokens,
      reasoning_tokens: reasoning_tokens,
      cache_read_tokens: cache_read,
      cache_write_tokens: cache_write,
      total_tokens: in_tokens + out_tokens,
      cost: cost
    }
  end

  defp normalize_opencode_tokens(_tokens, _cost), do: nil

  defp normalize_usage(%{} = usage) do
    in_tokens =
      Map.get(usage, :input_tokens) ||
        Map.get(usage, "input_tokens") ||
        Map.get(usage, :input) ||
        Map.get(usage, "input") ||
        Map.get(usage, :prompt_tokens) ||
        Map.get(usage, "prompt_tokens")

    out_tokens =
      Map.get(usage, :output_tokens) ||
        Map.get(usage, "output_tokens") ||
        Map.get(usage, :output) ||
        Map.get(usage, "output") ||
        Map.get(usage, :completion_tokens) ||
        Map.get(usage, "completion_tokens")

    total_tokens =
      Map.get(usage, :total_tokens) ||
        Map.get(usage, "total_tokens") ||
        Map.get(usage, :total) ||
        Map.get(usage, "total")

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

  defp integer_or_nil(val) when is_integer(val), do: val

  defp integer_or_nil(val) when is_binary(val) do
    case Integer.parse(val) do
      {num, ""} -> num
      _ -> nil
    end
  end

  defp integer_or_nil(_), do: nil
end
