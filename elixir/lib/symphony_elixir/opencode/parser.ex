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

  Resilience invariants:
  - Fragmented streams across arbitrary byte boundaries are safely buffered.
  - Windows CRLF and standard LF line endings are supported.
  - Malformed or corrupt JSON lines do not crash the stream parser; they are
    captured into failure_evidence so the run fails closed with deterministic evidence.
  """

  alias SymphonyElixir.OpenCode.Redactor

  defmodule State do
    @moduledoc false
    defstruct buffer: "",
              session_id: nil,
              message_ids: MapSet.new(),
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
        {:ok, %{} = event} ->
          process_event(state, event)

        {:error, reason} ->
          evidence = {:malformed_json_line, Redactor.redact(trimmed), reason}

          %{
            state
            | completion_state: :failed,
              failure_evidence: [evidence | state.failure_evidence]
          }
      end
    end
  end

  defp process_event(state, event) do
    event = Redactor.redact(event)

    state =
      state
      |> maybe_extract_session_id(event)
      |> record_event(event)

    event_type = Map.get(event, "type")

    case event_type do
      "step_finish" ->
        process_step_finish(state, event)

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
    session_id =
      Map.get(event, "sessionID") ||
        get_in(event, ["part", "sessionID"]) ||
        get_in(event, ["properties", "sessionID"]) ||
        get_in(event, ["properties", "info", "id"])

    if is_binary(session_id) and session_id != "" and is_nil(state.session_id) do
      %{state | session_id: session_id}
    else
      state
    end
  end

  defp record_event(state, event) do
    %{state | events: [event | state.events]}
  end

  defp process_step_finish(state, event) do
    part = Map.get(event, "part", %{})
    state = maybe_extract_message_id(state, part)

    tokens = Map.get(part, "tokens", %{})
    cost = Map.get(part, "cost", 0.0) || 0.0

    in_tokens = Map.get(tokens, "input", 0) || 0
    out_tokens = Map.get(tokens, "output", 0) || 0
    reasoning_tokens = Map.get(tokens, "reasoning", 0) || 0
    cache = Map.get(tokens, "cache", %{})
    cache_read = Map.get(cache, "read", 0) || 0
    cache_write = Map.get(cache, "write", 0) || 0

    cur_usage = state.usage

    new_usage = %{
      input_tokens: cur_usage.input_tokens + in_tokens,
      output_tokens: cur_usage.output_tokens + out_tokens,
      reasoning_tokens: cur_usage.reasoning_tokens + reasoning_tokens,
      cache_read_tokens: cur_usage.cache_read_tokens + cache_read,
      cache_write_tokens: cur_usage.cache_write_tokens + cache_write,
      total_tokens: cur_usage.total_tokens + in_tokens + out_tokens,
      cost: cur_usage.cost + cost
    }

    %{state | usage: new_usage}
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
      "idle" ->
        if state.completion_state == :running do
          %{state | completion_state: :completed}
        else
          state
        end

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
