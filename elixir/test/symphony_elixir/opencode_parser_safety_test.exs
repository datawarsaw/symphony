defmodule SymphonyElixir.OpenCodeParserSafetyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.OpenCode.{Failure, Parser}

  @secret "sk-ant-api03-abcdefghijklmnopqrstuvwxyz"
  @terminal %{"type" => "step_finish", "sessionID" => "ses_ok", "part" => %{"reason" => "stop", "tokens" => %{"input" => 3, "output" => 4}, "cost" => 0.5}}

  for {name, value} <- [{"number", 123}, {"string", "hi"}, {"array", [1, 2]}, {"null", nil}, {"boolean", true}] do
    test "#{name} record fails closed without crashing" do
      assert_failed(unquote(Macro.escape(value)))
    end
  end

  for {name, event} <- [
        {"part", %{"type" => "step_finish", "part" => nil}},
        {"tokens", %{"type" => "step_finish", "part" => %{"tokens" => 1}}},
        {"cost", %{"type" => "step_finish", "part" => %{"cost" => "1"}}},
        {"cache", %{"type" => "step_finish", "part" => %{"tokens" => %{"cache" => []}}}},
        {"input", %{"type" => "step_finish", "part" => %{"tokens" => %{"input" => "1"}}}},
        {"output", %{"type" => "step_finish", "part" => %{"tokens" => %{"output" => []}}}},
        {"reasoning", %{"type" => "step_finish", "part" => %{"tokens" => %{"reasoning" => %{}}}}},
        {"cache read", %{"type" => "step_finish", "part" => %{"tokens" => %{"cache" => %{"read" => false}}}}},
        {"cache write", %{"type" => "step_finish", "part" => %{"tokens" => %{"cache" => %{"write" => "1"}}}}},
        {"tool state", %{"type" => "tool_use", "part" => %{"state" => []}}},
        {"tool name", %{"type" => "tool_use", "part" => %{"tool" => %{}, "state" => %{"status" => "error"}}}},
        {"tool status", %{"type" => "tool_use", "part" => %{"state" => %{"status" => []}}}},
        {"tool error", %{"type" => "tool_use", "part" => %{"state" => %{"error" => List.duplicate("secret", 5_000)}}}},
        {"tool output", %{"type" => "tool_use", "part" => %{"state" => %{"output" => %{}}}}},
        {"text part", %{"type" => "text", "part" => 1}},
        {"reasoning part", %{"type" => "reasoning", "part" => "x"}},
        {"properties", %{"type" => "text", "properties" => []}},
        {"info", %{"type" => "text", "properties" => %{"info" => 1}}},
        {"nested status", %{"type" => "session.status", "properties" => %{"status" => "error"}}},
        {"status", %{"type" => "session.status", "status" => 1}},
        {"error data", %{"type" => "error", "error" => %{"data" => []}}},
        {"nested error data", %{"type" => "session.error", "properties" => %{"error" => %{"data" => 1}}}}
      ] do
    test "invalid #{name} fails closed without partial event effects" do
      assert_failed(unquote(Macro.escape(event)))
    end
  end

  test "invalid object evidence omits large containers, keys and secret-bearing values" do
    invalid = %{"type" => "step_finish", "part" => nil, @secret => List.duplicate(%{"password" => "opaque-secret"}, 20_000)}
    result = assert_failed(invalid)
    [{:malformed_json_line, line, detail}] = result.failure_evidence
    assert byte_size(Jason.encode!([line, detail])) < 4_200
    refute inspect(result) =~ @secret
    refute inspect(result) =~ "opaque-secret"
  end

  test "a cost too large for float arithmetic fails closed without partial effects" do
    assert_failed(put_in(@terminal, ["part", "cost"], Integer.pow(10, 400)))
  end

  test "overflow while accumulating individually valid costs preserves the prior state" do
    first = @terminal |> put_in(["part", "reason"], "tool-calls") |> put_in(["part", "cost"], 1.0e308)
    second = put_in(@terminal, ["part", "cost"], 1.0e308)
    state = Parser.feed(Parser.new(), Jason.encode!(first) <> "\n")
    failed = Parser.feed(state, Jason.encode!(second) <> "\n")
    assert failed.completion_state == :failed
    assert failed.events == state.events
    assert failed.usage == state.usage
    assert [{:malformed_json_line, _, %{reason: "invalid_event_shape: usage"}}] = failed.failure_evidence
    result = failed |> Parser.feed(Jason.encode!(@terminal) <> "\n") |> Parser.finish(0) |> Parser.to_result()
    assert result.completion_state == :failed
    assert result.event_count == 2
  end

  test "decoded escaped strings are redacted and bounded" do
    line = ~s("\\u0073k-ant-api03-abcdefghijklmnopqrstuvwxyz) <> String.duplicate("a", 20_000) <> ~s(")
    result = parse(line <> "\n")
    [{:malformed_json_line, evidence, detail}] = result.failure_evidence
    assert evidence =~ "[redacted]"
    refute evidence =~ @secret
    assert byte_size(evidence) <= 4_096
    assert {:ok, _} = Jason.encode([evidence, detail])
  end

  test "oversized string evidence retains valid UTF-8 within the existing byte bound" do
    result = assert_failed(String.duplicate("ż", 20_000))
    [{:malformed_json_line, line, _}] = result.failure_evidence
    assert String.valid?(line)
    assert byte_size(line) <= 4_096
  end

  test "fragmented invalid trailing record fails after an earlier terminal event" do
    state = Parser.feed(Parser.new(), Jason.encode!(@terminal) <> "\n[1,")
    state = Parser.feed(state, "2]")
    result = state |> Parser.finish(0) |> Parser.to_result()
    assert result.completion_state == :failed
    assert result.event_count == 1
    assert result.failure_evidence != []
  end

  test "valid 1.18.28 events retain usage, null numeric defaults and future event compatibility" do
    terminal = put_in(@terminal, ["part", "tokens"], %{"input" => 3, "output" => 4, "reasoning" => nil, "cache" => %{"read" => nil, "write" => 2}})
    result = parse(Jason.encode!(%{"type" => "future_event"}) <> "\r\n" <> Jason.encode!(terminal))
    assert result.completion_state == :completed
    assert result.failure_evidence == []
    assert result.event_count == 2
    assert result.usage.total_tokens == 9
    assert result.usage.cache_write_tokens == 2
    assert result.usage.reasoning_tokens == 0
    assert result.usage.cost == 0.5
  end

  defp assert_failed(value) do
    state = Parser.feed(Parser.new(), Jason.encode!(value) <> "\n")
    assert state.completion_state == :failed
    assert is_nil(state.session_id)
    assert state.events == []
    assert state.tool_events == []
    assert state.usage == Parser.new().usage
    result = state |> Parser.feed(Jason.encode!(@terminal) <> "\n") |> Parser.finish(0) |> Parser.to_result()
    assert result.completion_state == :failed
    assert result.session_id == "ses_ok"
    assert result.event_count == 1
    assert result.usage.total_tokens == 7
    assert [{:malformed_json_line, line, detail}] = result.failure_evidence
    assert is_binary(line) and String.valid?(line) and byte_size(line) <= 4_096
    assert {:ok, _} = Jason.encode([line, detail])
    assert %{failure_class: :persistent_worker_failure} = Failure.failure_info(hd(result.failure_evidence))
    result
  end

  defp parse(stream), do: Parser.new() |> Parser.feed(stream) |> Parser.finish(0) |> Parser.to_result()
end
