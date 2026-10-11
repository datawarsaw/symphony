defmodule SymphonyElixir.OpenCode.Parser do
  @moduledoc """
  Incremental JSONL parser and state accumulator for OpenCode worker event streams.

  Extracts:
  - session IDs
  - message IDs
  - tool events (tool, call_id, status, error, output)
  - completion state (:running, :completed, :failed)
  - token usage (input, output, reasoning, cache read/write, total, cost)
  - failure evidence (protocol errors, tool failures, malformed lines, process exits)

  Token accounting contract (OpenCode 1.18.28 wire): the five part.tokens
  categories are non-overlapping — input is non-cached input, output is
  visible output with reasoning excluded, cache read/write sit outside
  input — so a missing total is the additive sum of all five. An explicit
  wire total is inclusive of every category and is honored as-is; it is
  never added on top of the categories. Cost is accumulated per step,
  unchanged.

  Resilience invariants:
  - Fragmented streams across arbitrary byte boundaries are safely buffered.
  - Windows CRLF and standard LF line endings are supported.
  - Malformed or corrupt JSON lines do not crash the stream parser; they are
    captured into failure_evidence so the run fails closed with deterministic evidence.

  Completion semantics (grounded in the OpenCode 1.18.28 `run --format json`
  event contract):
  - The JSON CLI formatter never emits `session.status` on stdout, so completion
    never depends on it.
  - A `step_finish` event whose `part.reason` is `"tool-calls"` is intermediate:
    the model continues with tool calls and the turn is not complete.
  - A `step_finish` with a terminal reason (`"stop"`, `"length"`,
    `"content-filter"`, `"unknown"`) is valid terminal completion evidence.
  - Missing, unknown, or `"error"` finish reasons are not terminal; the stream
    fails closed as incomplete at finish.
  - Each step finish needs a nonblank session ID consistent with the first
    identified event. Conflicting session aliases or later foreign events fail
    closed, including events arriving after terminal completion. IDs changed by
    redaction or bounding cannot establish session authority.
  - Repeated WorkerEvent step identities contribute usage only once. Decoded
    records remain in events for Adapter delivery and observational deduplication
    by WorkerEvent; parser accounting does not suppress raw records.
  """

  alias SymphonyElixir.OpenCode.Redactor
  alias SymphonyElixir.WorkerEvent

  defmodule State do
    @moduledoc false
    defstruct buffer: "",
              session_id: nil,
              message_ids: MapSet.new(),
              seen_step_finishes: MapSet.new(),
              tool_events: [],
              completion_state: :running,
              usage: %{
                input_tokens: 0,
                output_tokens: 0,
                reasoning_tokens: 0,
                cache_read_tokens: 0,
                cache_write_tokens: 0,
                total_tokens: 0,
                cost: 0.0
              },
              failure_evidence: [],
              events: []
  end

  @intermediate_step_reason "tool-calls"
  @terminal_step_reasons ~w(stop length content-filter unknown)

  @doc """
  Initializes a new parser accumulator state.
  """
  @spec new() :: %State{}
  def new, do: %State{}

  @doc """
  Feeds a binary chunk of output from the process into the incremental parser.
  Processes any complete lines, buffers partial lines, and returns the updated state.
  """
  @spec feed(%State{}, binary()) :: %State{}
  def feed(%State{} = state, chunk) when is_binary(chunk) do
    combined = state.buffer <> chunk
    {lines, remaining_buffer} = split_lines(combined)

    Enum.reduce(lines, %{state | buffer: remaining_buffer}, fn line, acc ->
      parse_line(acc, line)
    end)
  end

  @doc """
  Finalizes parsing after process termination.
  Processes any trailing line in the buffer and applies the final process exit status.
  """
  @spec finish(%State{}, integer() | nil) :: %State{}
  def finish(%State{} = state, exit_status \\ 0) do
    state =
      if String.trim(state.buffer) != "" do
        parse_line(%{state | buffer: ""}, state.buffer)
      else
        state
      end

    cond do
      is_integer(exit_status) and exit_status != 0 ->
        %{
          state
          | completion_state: :failed,
            failure_evidence: [{:process_exit, exit_status} | state.failure_evidence]
        }

      state.completion_state == :completed ->
        state

      state.completion_state == :failed ->
        state

      true ->
        %{
          state
          | completion_state: :failed,
            failure_evidence: [
              {:incomplete_stream, :missing_completion_event} | state.failure_evidence
            ]
        }
    end
  end

  @doc """
  Converts the parser accumulator into a structured summary map.
  """
  @spec to_result(%State{}) :: map()
  def to_result(%State{} = state) do
    %{
      session_id: state.session_id,
      message_ids: state.message_ids |> MapSet.to_list() |> Enum.sort(),
      tool_events: Enum.reverse(state.tool_events),
      completion_state: state.completion_state,
      usage: state.usage,
      failure_evidence: Enum.reverse(state.failure_evidence),
      event_count: length(state.events)
    }
  end

  # ---------------------------------------------------------------------------
  # Line splitting
  # ---------------------------------------------------------------------------

  defp split_lines(binary) do
    case :binary.matches(binary, ["\r\n", "\n"]) do
      [] ->
        {[], binary}

      matches ->
        extract_lines(binary, matches, 0, [])
    end
  end

  defp extract_lines(binary, [], last_end, acc) do
    remainder = :binary.part(binary, last_end, byte_size(binary) - last_end)
    {Enum.reverse(acc), remainder}
  end

  defp extract_lines(binary, [{pos, len} | rest], last_end, acc) do
    line = :binary.part(binary, last_end, pos - last_end)
    extract_lines(binary, rest, pos + len, [line | acc])
  end

  # ---------------------------------------------------------------------------
  # Event decoding & extraction
  # ---------------------------------------------------------------------------

  defp parse_line(state, line) do
    trimmed = String.trim(line)

    if trimmed == "" do
      state
    else
      case Jason.decode(trimmed) do
        {:ok, value} ->
          process_record(state, value)

        {:error, reason} ->
          evidence = {:malformed_json_line, Redactor.redact(trimmed), decode_error_detail(reason)}

          %{
            state
            | completion_state: :failed,
              failure_evidence: [evidence | state.failure_evidence]
          }
      end
    end
  end

  defp process_record(state, %{} = event) do
    case invalid_event_field(event) do
      nil -> process_event(state, event)
      field -> invalid_record(state, "Invalid OpenCode event shape", "invalid_event_shape: " <> field)
    end
  rescue
    # JSON integers are unbounded and even finite floats can overflow when
    # summed. Keep arithmetic rejection transactional, including event storage.
    ArithmeticError -> invalid_record(state, "Invalid OpenCode event shape", "invalid_event_shape: usage")
  end

  defp process_record(state, value) do
    # Decode strings before redaction so JSON escapes cannot hide secrets.
    # Other non-objects need no raw payload in diagnostic evidence.
    line = if is_binary(value), do: value, else: "Non-object OpenCode JSON record"
    invalid_record(state, line, "invalid_event_shape: record")
  end

  defp invalid_record(state, line, reason) do
    evidence = {:malformed_json_line, Redactor.redact(line), %{reason: reason}}
    %{state | completion_state: :failed, failure_evidence: [evidence | state.failure_evidence]}
  end

  # Check only fields that are traversed or used in arithmetic. Missing fields
  # retain their existing defaults; unknown event types remain forward compatible.
  # Validation precedes session extraction, redaction and callback event storage,
  # so an invalid record has no partial effects and retains no raw containers.
  defp invalid_event_field(event) do
    cond do
      not is_binary(Map.get(event, "type")) -> "type"
      field = invalid_field(event, [["part"], ["properties"], ["properties", "info"]], &is_map/1) -> field
      true -> invalid_payload_field(event)
    end
  end

  defp invalid_payload_field(%{"type" => "step_finish"} = event) do
    invalid_field(event, [["part", "tokens"], ["part", "tokens", "cache"]], &is_map/1) ||
      invalid_field(
        event,
        [
          ["part", "cost"],
          ["part", "tokens", "input"],
          ["part", "tokens", "output"],
          ["part", "tokens", "reasoning"],
          ["part", "tokens", "cache", "read"],
          ["part", "tokens", "cache", "write"]
        ],
        &(is_nil(&1) or is_number(&1))
      )
  end

  defp invalid_payload_field(%{"type" => "tool_use"} = event) do
    invalid_field(event, [["part", "state"]], &is_map/1) ||
      invalid_field(event, [["part", "tool"], ["part", "state", "status"], ["part", "state", "error"], ["part", "state", "output"]], &(is_nil(&1) or is_binary(&1)))
  end

  defp invalid_payload_field(%{"type" => "session.status"} = event) do
    invalid_field(event, [["properties", "status"], ["status"]], &is_map/1)
  end

  defp invalid_payload_field(%{"type" => type} = event) when type in ["error", "session.error"] do
    # Failure.classify/1 dereferences data when the error payload is a map.
    invalid_field(event, [["data"], ["error", "data"], ["properties", "error", "data"]], &(is_nil(&1) or is_map(&1)))
  end

  defp invalid_payload_field(_event), do: nil

  defp invalid_field(event, paths, valid?) do
    Enum.find_value(paths, &invalid_path(event, &1, valid?))
  end

  defp invalid_path(event, path, valid?) do
    case fetch_field(event, path) do
      {:ok, value} -> if not valid?.(value), do: Enum.join(path, ".")
      :error -> nil
    end
  end

  defp fetch_field(value, []), do: {:ok, value}

  defp fetch_field(%{} = value, [key | rest]) do
    case Map.fetch(value, key) do
      {:ok, inner} -> fetch_field(inner, rest)
      :error -> :error
    end
  end

  defp fetch_field(_value, _path), do: :error

  # Sanitizes decoder failures into bounded, redacted evidence. The raw
  # Jason.DecodeError struct is never retained: its :data field carries the
  # complete unbounded source line, which can include secrets.
  defp decode_error_detail(%Jason.DecodeError{} = error) do
    %{
      position: error.position,
      token: error.token |> to_string() |> Redactor.redact()
    }
  end

  defp decode_error_detail(reason) do
    %{reason: reason |> inspect() |> Redactor.redact()}
  end

  defp process_event(state, raw_event) do
    event = Redactor.redact(raw_event)

    {state, session_accepted?} = state |> record_event(event) |> maybe_extract_session_id(raw_event)

    case {Map.get(event, "type"), session_accepted?} do
      {"step_finish", _} ->
        process_step_finish(state, event, session_accepted?)

      {_, false} ->
        state

      {_, true} ->
        process_session_event(state, event)
    end
  end

  defp process_session_event(state, event) do
    case Map.get(event, "type") do
      "tool_use" ->
        process_tool_use(state, event)

      "text" ->
        process_text(state, event)

      "reasoning" ->
        process_reasoning(state, event)

      "error" ->
        process_error(state, event)

      "session.error" ->
        process_error(state, event)

      "session.status" ->
        process_session_status(state, event)

      _ ->
        state
    end
  end

  defp maybe_extract_session_id(state, event) do
    session_id = extract_session_id(event)
    conflict = find_session_conflict(event, session_id)

    cond do
      is_nil(session_id) and Map.get(event, "type") != "step_finish" ->
        {state, true}

      blank_session_id?(session_id) ->
        reject_session(state, :missing_session_id)

      Redactor.redact(session_id) != session_id ->
        reject_session(state, :unusable_session_id)

      not is_nil(conflict) ->
        reject_session(state, {:conflicting_session_id, session_id, conflict})

      is_nil(state.session_id) ->
        {%{state | session_id: session_id}, true}

      state.session_id == session_id ->
        {state, true}

      true ->
        reject_session(state, {:conflicting_session_id, state.session_id, session_id})
    end
  end

  defp blank_session_id?(session_id) do
    not is_binary(session_id) or String.trim(session_id) == ""
  end

  defp extract_session_id(event) do
    Map.get(event, "sessionID") ||
      get_in(event, ["part", "sessionID"]) ||
      get_in(event, ["properties", "sessionID"]) ||
      get_in(event, ["properties", "info", "id"])
  end

  defp find_session_conflict(event, session_id) do
    Enum.find(session_aliases(event), fn id ->
      not is_nil(id) and id != session_id
    end)
  end

  defp session_aliases(event) do
    part = Map.get(event, "part")
    properties = Map.get(event, "properties")
    info = if is_map(properties), do: Map.get(properties, "info")

    [
      Map.get(event, "sessionID"),
      if(is_map(part), do: Map.get(part, "sessionID")),
      if(is_map(properties), do: Map.get(properties, "sessionID")),
      if(is_map(info), do: Map.get(info, "id"))
    ]
  end

  defp reject_session(state, reason) do
    {%{
       state
       | completion_state: :failed,
         failure_evidence: [{:incomplete_stream, Redactor.redact(reason)} | state.failure_evidence]
     }, false}
  end

  defp record_event(state, event) do
    %{state | events: [event | state.events]}
  end

  defp process_step_finish(state, event, session_accepted?) do
    part = Map.get(event, "part", %{})

    tokens = Map.get(part, "tokens") || %{}
    cost = Map.get(part, "cost", 0.0) || 0.0

    in_tokens = Map.get(tokens, "input", 0) || 0
    out_tokens = Map.get(tokens, "output", 0) || 0
    reasoning_tokens = Map.get(tokens, "reasoning", 0) || 0
    cache = Map.get(tokens, "cache", %{}) || %{}
    cache_read = Map.get(cache, "read", 0) || 0
    cache_write = Map.get(cache, "write", 0) || 0

    cur_usage = state.usage
    step_total = step_total(tokens, in_tokens, out_tokens, reasoning_tokens, cache_read, cache_write)

    new_usage = %{
      input_tokens: cur_usage.input_tokens + in_tokens,
      output_tokens: cur_usage.output_tokens + out_tokens,
      reasoning_tokens: cur_usage.reasoning_tokens + reasoning_tokens,
      cache_read_tokens: cur_usage.cache_read_tokens + cache_read,
      cache_write_tokens: cur_usage.cache_write_tokens + cache_write,
      total_tokens: cur_usage.total_tokens + step_total,
      cost: cur_usage.cost + cost
    }

    # Keep the existing shape/number handling above. Session rejection and
    # deduplication only gate accounting and completion, not shape validation.
    if session_accepted? do
      step_id = WorkerEvent.from_opencode(event).metadata.event_id

      if MapSet.member?(state.seen_step_finishes, step_id) do
        state
      else
        state
        |> maybe_extract_message_id(part)
        |> Map.put(:seen_step_finishes, MapSet.put(state.seen_step_finishes, step_id))
        |> Map.put(:usage, new_usage)
        |> apply_step_finish_reason(part)
      end
    else
      state
    end
  end

  # OpenCode 1.18.28 wire contract: part.tokens carries five non-overlapping
  # categories — input is the non-cached input, output is the visible output
  # with reasoning excluded, and cache read/write sit outside input. The wire
  # step-finish normally carries no total; an explicit total is inclusive of
  # all five categories and is the source of truth, never added on top of
  # them (that would double count).
  defp step_total(tokens, in_tokens, out_tokens, reasoning_tokens, cache_read, cache_write) do
    case Map.get(tokens, "total") do
      value when is_integer(value) and value >= 0 -> value
      _ -> in_tokens + out_tokens + reasoning_tokens + cache_read + cache_write
    end
  end

  # "tool-calls" is intermediate: the model continues the turn with tool calls,
  # so it must never be mistaken for final completion. Only terminal reasons
  # complete the turn, and only while the stream is still clean and running.
  defp apply_step_finish_reason(state, part) do
    reason = Map.get(part, "reason")

    cond do
      reason == @intermediate_step_reason ->
        state

      reason in @terminal_step_reasons and state.completion_state == :running ->
        %{state | completion_state: :completed}

      true ->
        state
    end
  end

  defp process_tool_use(state, event) do
    part = Map.get(event, "part", %{})
    state = maybe_extract_message_id(state, part)

    tool_name = Map.get(part, "tool")
    call_id = Map.get(part, "callID") || Map.get(part, "id")
    state_map = Map.get(part, "state", %{})
    status = Map.get(state_map, "status")
    error = Map.get(state_map, "error")
    output = Map.get(state_map, "output")
    message_id = Map.get(part, "messageID")

    tool_record = %{
      tool: tool_name,
      call_id: call_id,
      status: status,
      error: error,
      output: output,
      message_id: message_id,
      timestamp: Map.get(event, "timestamp")
    }

    new_tool_events = [tool_record | state.tool_events]

    failed? = status == "error" or not is_nil(error)

    new_failure_evidence =
      if failed? do
        [{:tool_error, tool_name, error} | state.failure_evidence]
      else
        state.failure_evidence
      end

    %{
      state
      | tool_events: new_tool_events,
        failure_evidence: new_failure_evidence,
        completion_state: if(failed?, do: :failed, else: state.completion_state)
    }
  end

  defp process_text(state, event) do
    part = Map.get(event, "part", %{})
    maybe_extract_message_id(state, part)
  end

  defp process_reasoning(state, event) do
    part = Map.get(event, "part", %{})
    maybe_extract_message_id(state, part)
  end

  defp process_error(state, event) do
    error_payload =
      Map.get(event, "error") ||
        get_in(event, ["properties", "error"]) ||
        event

    evidence = {:error_event, error_payload}

    %{
      state
      | completion_state: :failed,
        failure_evidence: [evidence | state.failure_evidence]
    }
  end

  defp process_session_status(state, event) do
    status_type =
      get_in(event, ["properties", "status", "type"]) ||
        get_in(event, ["status", "type"])

    case status_type do
      "error" ->
        %{state | completion_state: :failed}

      _ ->
        state
    end
  end

  defp maybe_extract_message_id(state, %{} = part) do
    msg_id = Map.get(part, "messageID")

    if is_binary(msg_id) and msg_id != "" do
      %{state | message_ids: MapSet.put(state.message_ids, msg_id)}
    else
      state
    end
  end

  defp maybe_extract_message_id(state, _), do: state
end
