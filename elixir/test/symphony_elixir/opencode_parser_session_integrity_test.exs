defmodule SymphonyElixir.OpenCodeParserSessionIntegrityTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.OpenCode
  alias SymphonyElixir.OpenCode.{Parser, Redactor}
  alias SymphonyElixir.TestSupport.MockOpenCode
  alias SymphonyElixir.WorkerEvent

  Code.require_file("../support/mock_opencode.exs", __DIR__)

  @tag :windows_only
  test "Adapter fails closed for empty fixture session identity with existing classification" do
    workspace = Path.join(System.tmp_dir!(), "m1pf2-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    assert {:error, {{:incomplete_stream, :missing_session_id}, result}} =
             OpenCode.run(workspace, "--mock-session-id=",
               provider: "anthropic",
               model: "claude-3-5-sonnet",
               executable: MockOpenCode.ensure_built!(),
               timeout_ms: 8_000
             )

    assert result.exit_code == 0
    assert result.completion_state == :failed
    assert result.session_id == nil
    assert result.failure_info.failure_class == :persistent_worker_failure
  end

  test "missing terminal identity cannot borrow an earlier or later session lock" do
    missing = Map.delete(step("m1", "p1"), "sessionID")

    for events <- [[text("ses_a"), missing], [missing, text("ses_a"), step("m2", "p2")]] do
      result = parse(events)
      assert result.session_id == "ses_a"
      assert result.completion_state == :failed
      assert {:incomplete_stream, :missing_session_id} in result.failure_evidence
    end
  end

  test "a foreign event after completion invalidates success permanently" do
    result = parse([step("m1", "p1"), text("ses_b"), step("m2", "p2")])
    assert result.session_id == "ses_a"
    assert result.completion_state == :failed

    assert result.failure_evidence == [
             {:incomplete_stream, {:conflicting_session_id, "ses_a", "ses_b"}}
           ]

    assert result.usage.total_tokens == 60
    assert result.usage.cost == 0.25
  end

  test "conflicting aliases within one event cannot authorize success" do
    event = put_in(step("m1", "p1"), ["part", "sessionID"], "ses_b")
    result = parse([event])
    assert result.completion_state == :failed

    assert result.failure_evidence == [
             {:incomplete_stream, {:conflicting_session_id, "ses_a", "ses_b"}}
           ]

    assert result.usage.total_tokens == 0
  end

  test "nested session identity is accepted and sessionless text does not lock a session" do
    for path <- [["part", "sessionID"], ["properties", "sessionID"], ["properties", "info", "id"]] do
      event = Map.delete(step("m1", "p1"), "sessionID")
      event = put_in(event, Enum.map(path, &Access.key(&1, %{})), "ses_a")
      result = parse([Map.delete(text("ses_a"), "sessionID"), event])
      assert result.session_id == "ses_a"
      assert result.completion_state == :completed
      assert result.failure_evidence == []
    end
  end

  test "stable step identity ignores timestamp and changed usage on retransmission" do
    first = step("m1", "p1")
    retransmission = first |> Map.put("timestamp", 1_728_490_099) |> put_in(["part", "cost"], 99.0)
    result = parse([first, retransmission])
    assert result.usage == parse([first]).usage
    assert {:ok, acc, _} = WorkerEvent.accumulate(nil, first)
    assert {:duplicate, acc} = WorkerEvent.accumulate(acc, retransmission)
    assert result.usage == acc.usage
  end

  test "timestamp fallback agrees with WorkerEvent when message and part ids are missing" do
    first = step("m1", "p1", "tool-calls") |> update_in(["part"], &Map.drop(&1, ["messageID", "id"]))
    later = Map.put(first, "timestamp", 1_728_490_099)
    assert parse([first, first, later]).usage.total_tokens == 60
    assert {:ok, acc, _} = WorkerEvent.accumulate(nil, first)
    assert {:duplicate, acc} = WorkerEvent.accumulate(acc, first)
    assert {:ok, acc, _} = WorkerEvent.accumulate(acc, later)
    assert parse([first, first, later]).usage == acc.usage
  end

  test "duplicate JSONL fragmented across byte boundaries is counted once" do
    line = Jason.encode!(step("m1", "p1")) <> "\r\n"

    state =
      Enum.reduce(:binary.bin_to_list(line <> line), Parser.new(), fn byte, state ->
        Parser.feed(state, <<byte>>)
      end)

    result = state |> Parser.finish(0) |> Parser.to_result()
    assert result.usage == parse([step("m1", "p1")]).usage
    assert result.event_count == 2
    assert result.completion_state == :completed
  end

  test "session gating preserves existing malformed step shape exceptions" do
    for {event, exception} <- [
          {%{"type" => "step_finish", "part" => nil}, BadMapError},
          {%{"type" => "step_finish", "part" => %{"tokens" => 1}}, BadMapError},
          {%{"type" => "step_finish", "part" => %{"cost" => "1"}}, ArithmeticError}
        ] do
      assert_raise exception, fn -> parse([event]) end
    end

    assert_raise CaseClauseError, fn -> Parser.feed(Parser.new(), "null\n") end
  end

  test "lossy sanitization cannot collapse distinct session identities into one lock" do
    prefix = "ses_" <> String.duplicate("a", 4_100)
    first = prefix <> "a"
    foreign = prefix <> "b"
    assert Redactor.redact(first) == Redactor.redact(foreign)
    result = parse([text(first), Map.put(step("m1", "p1"), "sessionID", foreign)])
    assert result.session_id == nil
    assert result.completion_state == :failed
    assert Enum.all?(result.failure_evidence, &(&1 == {:incomplete_stream, :unusable_session_id}))
    assert result.usage.total_tokens == 0
  end

  test "conflict rejects all counters and later matching events cannot clear its evidence" do
    first = step("m1", "p1", "tool-calls")
    foreign = Map.put(step("m2", "p2"), "sessionID", "ses_b")
    rejected = Parser.new() |> Parser.feed(Jason.encode!(first) <> "\n")
    after_foreign = Parser.feed(rejected, Jason.encode!(foreign) <> "\n")
    assert after_foreign.usage == rejected.usage
    assert after_foreign.message_ids == rejected.message_ids
    result = parse([first, foreign, step("m3", "p3")])
    assert result.completion_state == :failed

    assert result.failure_evidence == [
             {:incomplete_stream, {:conflicting_session_id, "ses_a", "ses_b"}}
           ]

    assert result.usage.total_tokens == 60
  end

  test "a terminal event without session identity cannot authorize success" do
    for session <- [nil, "", "   "] do
      event = step("m1", "p1") |> Map.put("sessionID", session)
      result = parse([event])
      assert result.session_id == nil
      assert result.completion_state == :failed
      assert result.failure_evidence == [{:incomplete_stream, :missing_session_id}]
      assert result.usage.total_tokens == 0
      assert result.usage.cost == 0.0
    end
  end

  test "a foreign terminal event cannot complete or bill the locked session" do
    result = parse([text("ses_a"), Map.put(step("m1", "p1"), "sessionID", "ses_b")])
    assert result.session_id == "ses_a"
    assert result.completion_state == :failed

    assert result.failure_evidence == [
             {:incomplete_stream, {:conflicting_session_id, "ses_a", "ses_b"}}
           ]

    assert result.usage.total_tokens == 0
    assert result.usage.cost == 0.0
    assert result.message_ids == []
    assert result.event_count == 2
  end

  test "duplicates across chunks preserve every usage counter and raw records" do
    event = step("m1", "p1")
    line = Jason.encode!(event) <> "\n"
    first = Parser.feed(Parser.new(), line)
    duplicate = Parser.feed(first, line)
    assert duplicate.usage == first.usage
    assert length(duplicate.events) == 2
    assert Parser.to_result(Parser.finish(duplicate, 0)).completion_state == :completed

    assert first.usage == %{
             input_tokens: 10,
             output_tokens: 20,
             total_tokens: 30,
             reasoning_tokens: 4,
             cache_read_tokens: 5,
             cache_write_tokens: 6,
             cost: 0.125
           }

    assert {:ok, acc, _} = WorkerEvent.accumulate(nil, event)
    assert {:duplicate, same} = WorkerEvent.accumulate(acc, event)
    assert duplicate.usage == same.usage
  end

  test "distinct part identities with the same message and usage both count" do
    first = step("m1", "p1", "tool-calls")
    last = step("m1", "p2")
    result = parse([first, first, last, last])
    assert result.completion_state == :completed
    assert result.failure_evidence == []

    assert result.usage == %{
             input_tokens: 20,
             output_tokens: 40,
             total_tokens: 60,
             reasoning_tokens: 8,
             cache_read_tokens: 10,
             cache_write_tokens: 12,
             cost: 0.25
           }

    assert result.event_count == 4
    assert {:ok, acc, _} = WorkerEvent.accumulate(nil, first)
    assert {:ok, acc, _} = WorkerEvent.accumulate(acc, last)
    assert result.usage == acc.usage
  end

  defp parse(events) do
    events
    |> Enum.reduce(Parser.new(), fn event, state ->
      Parser.feed(state, Jason.encode!(event) <> "\n")
    end)
    |> Parser.finish(0)
    |> Parser.to_result()
  end

  defp text(session), do: %{"type" => "text", "sessionID" => session, "part" => %{"text" => "x"}}

  defp step(message, part, reason \\ "stop") do
    %{
      "type" => "step_finish",
      "sessionID" => "ses_a",
      "timestamp" => 1_728_490_000,
      "part" => %{
        "messageID" => message,
        "id" => part,
        "reason" => reason,
        "cost" => 0.125,
        "tokens" => %{"input" => 10, "output" => 20, "reasoning" => 4, "cache" => %{"read" => 5, "write" => 6}}
      }
    }
  end
end
