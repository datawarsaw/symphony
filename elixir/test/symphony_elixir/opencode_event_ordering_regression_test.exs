defmodule SymphonyElixir.OpenCodeEventOrderingRegressionTest do
  @moduledoc """
  M1-T2: deterministic offline regression tests for OpenCode JSONL event ordering.

  Contract under test: when one adapter stream chunk contains multiple JSONL
  events, the events must reach the `:on_event` callback — and through it the
  `WorkerEvent` consumption layer — in chronological order, without loss and
  without double accounting.

  Reported issue under regression: reversed event order. The adapter's stream
  loop dispatches each chunk's new events with
  `updated_parser.events -- parser.events`, and the parser prepends every
  recorded event (`events: [event | state.events]`), so the per-chunk delta
  list is newest-first and the callback observes the chunk's events in reverse
  chronological order. A second latent defect is covered here as well: events
  decoded by `Parser.finish/2` from the trailing buffer at process exit (a
  final JSONL line without a newline) are never dispatched to `:on_event` at
  all, so the callback stream loses the terminal event while the run result
  still reports it.

  Segmentation independence (no reliance on OS chunking):

  - Parser-level tests feed explicit chunk strings, so chunk boundaries are
    authored, not observed.
  - Adapter-level tests spawn the in-box mock in `emit-parts` mode: every
    `*.part` file is one flushed stdout write, so a multi-event chunk is one
    atomic write, and multi-chunk splits are separated by a written delay.
  - Every adapter-level ordering assertion states a property that holds for a
    correct implementation under ANY pipe segmentation (chronological delivery
    is segmentation-invariant when each chunk's delta is delivered
    oldest-first), so these tests cannot flake green-to-red on a correct
    implementation regardless of how the OS coalesces or fragments pipe
    writes. The per-line-segmentation control test documents the flip side:
    the reversed-order defect is chunk-granular and is only observable when a
    chunk carries more than one event, which is why the multi-event-chunk
    scenarios above are the load-bearing ones.

  No production module is modified by this suite. Failing tests in this file
  are the red regression candidates: they must be made green by fixing the
  adapter's dispatch order, not by editing this file.
  """

  use SymphonyElixir.TestSupport

  Code.require_file("../support/mock_opencode.exs", __DIR__)

  alias SymphonyElixir.OpenCode
  alias SymphonyElixir.OpenCode.Parser
  alias SymphonyElixir.TestSupport.MockOpenCode
  alias SymphonyElixir.WorkerEvent

  @base_ts 1_700_000_000_000
  @session "ses_m1t2_order"
  @session_canonical "ses_m1t2_canon"
  @session_rogue "ses_m1t2_rogue"
  @raw_secret "sk-ant-api03-abcdefghijklmnopqrstuvwxyz"

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "m1t2-ordering-ws-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)

    marker_root = Path.join(workspace, ".symphony-state/launches")
    File.mkdir_p!(marker_root)
    Application.put_env(:symphony_elixir, :launch_marker_root, marker_root)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :launch_marker_root)
      File.rm_rf(workspace)
    end)

    {:ok, workspace: workspace, marker_root: marker_root}
  end

  # ===========================================================================
  # Deterministic event fixtures (distinct, strictly increasing timestamps)
  # ===========================================================================

  defp step_start_line(session_id, message_id, step_id, ts) do
    Jason.encode!(%{
      "type" => "step_start",
      "timestamp" => ts,
      "sessionID" => session_id,
      "part" => %{
        "type" => "step-start",
        "id" => step_id,
        "sessionID" => session_id,
        "messageID" => message_id
      }
    })
  end

  defp tool_use_line(session_id, message_id, tool_id, call_id, ts) do
    Jason.encode!(%{
      "type" => "tool_use",
      "timestamp" => ts,
      "sessionID" => session_id,
      "part" => %{
        "type" => "tool",
        "id" => tool_id,
        "sessionID" => session_id,
        "messageID" => message_id,
        "tool" => "read",
        "callID" => call_id,
        "state" => %{"status" => "completed", "output" => "file contents"}
      }
    })
  end

  defp step_finish_line(session_id, message_id, step_id, reason, ts, tokens, cost) do
    Jason.encode!(%{
      "type" => "step_finish",
      "timestamp" => ts,
      "sessionID" => session_id,
      "part" => %{
        "type" => "step-finish",
        "id" => step_id,
        "sessionID" => session_id,
        "messageID" => message_id,
        "reason" => reason,
        "cost" => cost,
        "tokens" => %{
          "input" => tokens.input,
          "output" => tokens.output,
          "reasoning" => tokens.reasoning,
          "cache" => %{"read" => tokens.cache_read, "write" => tokens.cache_write}
        }
      }
    })
  end

  # Chronological multi-step stream: step_start -> intermediate tool-calls
  # step_finish -> tool_use -> step_start -> terminal stop step_finish.
  defp chronological_lines(session_id \\ @session) do
    [
      step_start_line(session_id, "msg_01", "step_s1", @base_ts),
      step_finish_line(session_id, "msg_01", "step_f1", "tool-calls", @base_ts + 100,
        %{input: 40, output: 60, reasoning: 10, cache_read: 5, cache_write: 5}, 0.002),
      tool_use_line(session_id, "msg_01", "toolu_01", "call_01", @base_ts + 200),
      step_start_line(session_id, "msg_02", "step_s2", @base_ts + 300),
      step_finish_line(session_id, "msg_02", "step_f2", "stop", @base_ts + 400,
        %{input: 60, output: 90, reasoning: 15, cache_read: 10, cache_write: 5}, 0.003)
    ]
  end

  defp chronological_sequence do
    [
      {"step_start", "step_s1"},
      {"step_finish", "step_f1"},
      {"tool_use", "toolu_01"},
      {"step_start", "step_s2"},
      {"step_finish", "step_f2"}
    ]
  end

  defp chronological_timestamps,
    do: Enum.map(0..4, &(@base_ts + &1 * 100))

  defp delivered_pairs(delivered),
    do: Enum.map(delivered, &{Map.get(&1, "type"), get_in(&1, ["part", "id"])})

  defp delivered_timestamps(delivered),
    do: Enum.map(delivered, &Map.get(&1, "timestamp"))

  # ===========================================================================
  # Adapter run helper driving the emit-parts mock (see moduledoc)
  # ===========================================================================

  defp run_manifest(parts, ctx, opts) do
    %{workspace: ws, marker_root: mr} = ctx

    issue_id =
      Keyword.get(opts, :issue_id) || "ISSUE-M1T2-#{System.unique_integer([:positive])}"

    delay_ms = Keyword.get(opts, :part_delay_ms, 0)

    parts_dir = Path.join(ws, "m1t2-parts-#{System.unique_integer([:positive])}")
    File.mkdir_p!(parts_dir)

    parts
    |> Enum.with_index(1)
    |> Enum.each(fn {data, idx} ->
      name = String.pad_leading(Integer.to_string(idx), 2, "0") <> ".part"
      File.write!(Path.join(parts_dir, name), data)
    end)

    File.write!(
      Path.join(ws, "opencode-mock-control.txt"),
      "mode=emit-parts\nparts_dir=#{parts_dir}\npart_delay_ms=#{delay_ms}\n"
    )

    run_opts =
      [
        provider: "anthropic",
        model: "claude-3-5-sonnet",
        executable: MockOpenCode.ensure_built!(),
        issue_id: issue_id,
        authority_root: mr,
        timeout_ms: 20_000
      ]
      |> Keyword.merge(Keyword.drop(opts, [:part_delay_ms, :issue_id]))

    {issue_id, OpenCode.run(ws, "m1-t2-ordering-regression", run_opts)}
  end

  defp run_with_on_event(parts, ctx, opts \\ []) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    {issue_id, run_result} =
      run_manifest(
        parts,
        ctx,
        Keyword.put(opts, :on_event, fn event -> Agent.update(agent, &[event | &1]) end)
      )

    # The collector prepends, so reversing yields the actual delivery order.
    delivered = agent |> Agent.get(& &1) |> Enum.reverse()
    Agent.stop(agent)

    {issue_id, run_result, delivered}
  end

  # WorkerEvent.callback delivers accepted updates to the caller's mailbox in
  # on_event invocation order (its submit path is synchronous), so draining the
  # mailbox after Adapter.run returns observes the consumption order exactly.
  defp drain_worker_updates(issue_id, acc \\ []) do
    receive do
      {:codex_worker_update, ^issue_id, update} -> drain_worker_updates(issue_id, [update | acc])
    after
      300 -> Enum.reverse(acc)
    end
  end

  defp run_with_worker_event_callback(parts, ctx) do
    issue_id = "ISSUE-M1T2-CB-#{System.unique_integer([:positive])}"

    {issue_id, run_result} =
      run_manifest(parts, ctx,
        issue_id: issue_id,
        on_event: WorkerEvent.callback(self(), issue_id)
      )

    {issue_id, run_result, drain_worker_updates(issue_id)}
  end

  # ===========================================================================
  # 1. Parser-level chunk segmentation invariants (authored chunks, no OS)
  # ===========================================================================

  describe "1. Parser-level chunk segmentation invariants (deterministic)" do
    test "a single multi-event chunk parses every event with full accounting" do
      jsonl = Enum.join(chronological_lines(), "\n") <> "\n"

      result = Parser.new() |> Parser.feed(jsonl) |> Parser.to_result()

      assert result.event_count == 5
      assert result.session_id == @session
      assert result.completion_state == :completed
      assert result.failure_evidence == []
      assert result.usage.input_tokens == 100
      assert result.usage.output_tokens == 150
      assert result.usage.reasoning_tokens == 25
      assert result.usage.cache_read_tokens == 15
      assert result.usage.cache_write_tokens == 10
      assert result.usage.total_tokens == 250
      assert Float.round(result.usage.cost, 6) == 0.005
      assert Enum.map(result.tool_events, & &1.call_id) == ["call_01"]
      assert result.message_ids == ["msg_01", "msg_02"]
    end

    test "arbitrary chunk splits, byte dribbles, CRLF and blank lines lose nothing" do
      lines = chronological_lines()
      [l1, l2 | _] = lines
      jsonl = Enum.join(lines, "\n") <> "\n"

      whole = Parser.new() |> Parser.feed(jsonl) |> Parser.to_result()

      after_l1 = byte_size(l1) + 1
      mid_l3 = after_l1 + byte_size(l2) + 1 + div(byte_size(Enum.at(lines, 2)), 2)

      cut_chunks = split_binary_at(jsonl, [div(byte_size(l1), 2), after_l1, mid_l3])

      dribble_chunks = for i <- 0..(byte_size(jsonl) - 1), do: binary_part(jsonl, i, 1)

      crlf_jsonl = Enum.join(lines, "\r\n") <> "\r\n"

      blank_jsonl =
        (lines
         |> Enum.intersperse("\n")
         |> Enum.join("\n")) <> "\n\n"

      feed_all = fn chunks ->
        chunks
        |> Enum.reduce(Parser.new(), fn chunk, state -> Parser.feed(state, chunk) end)
        |> Parser.to_result()
      end

      assert feed_all.(cut_chunks) == whole
      assert feed_all.(dribble_chunks) == whole
      assert feed_all.([crlf_jsonl]) == whole
      assert feed_all.([blank_jsonl]) == whole

      # Chronological extraction survives every segmentation alike.
      for result <- [feed_all.(cut_chunks), feed_all.(dribble_chunks)] do
        assert Enum.map(result.tool_events, & &1.call_id) == ["call_01"]
        assert result.event_count == 5
      end
    end
  end

  defp split_binary_at(binary, offsets) do
    offsets
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reverse()
    |> Enum.reduce([binary], fn offset, [head | tail] ->
      size = byte_size(head)

      if offset <= 0 or offset >= size do
        [head | tail]
      else
        [binary_part(head, 0, offset), binary_part(head, offset, size - offset) | tail]
      end
    end)
  end

  # ===========================================================================
  # 2. Adapter on_event delivery order for multi-event chunks
  # ===========================================================================

  describe "2. Adapter multi-event chunk delivery order" do
    @describetag :ordering_regression

    test "a single chunk carrying the whole stream delivers events chronologically", ctx do
      parts = [Enum.join(chronological_lines(), "\n") <> "\n"]

      {_issue_id, run_result, delivered} = run_with_on_event(parts, ctx)

      assert {:ok, result} = run_result
      assert result.completion_state == :completed
      assert result.event_count == 5

      assert delivered_pairs(delivered) == chronological_sequence(),
             "on_event must observe the chunk's events oldest-first; " <>
               "reverse intra-chunk order is the reported regression"

      assert delivered_timestamps(delivered) == chronological_timestamps()
    end

    test "chunk splits across JSONL line boundaries still deliver chronologically", ctx do
      lines = chronological_lines()

      # Part 1 cuts the first line in half; part 2 completes it and carries two
      # whole events plus the start of the fourth; part 3 (CRLF endings)
      # completes the stream. Inter-part delays make these the observed chunks.
      l1 = Enum.at(lines, 0)
      l2 = Enum.at(lines, 1)
      l3 = Enum.at(lines, 2)
      l4 = Enum.at(lines, 3)
      l5 = Enum.at(lines, 4)
      half_l1 = div(byte_size(l1), 2)
      half_l4 = div(byte_size(l4), 2)

      parts = [
        binary_part(l1, 0, half_l1),
        binary_part(l1, half_l1, byte_size(l1) - half_l1) <> "\n" <> l2 <> "\n" <> l3 <> "\n" <>
          binary_part(l4, 0, half_l4),
        binary_part(l4, half_l4, byte_size(l4) - half_l4) <> "\r\n" <> l5 <> "\r\n"
      ]

      {_issue_id, run_result, delivered} = run_with_on_event(parts, ctx, part_delay_ms: 150)

      assert {:ok, result} = run_result
      assert result.completion_state == :completed
      assert result.event_count == 5

      assert delivered_pairs(delivered) == chronological_sequence()
      assert delivered_timestamps(delivered) == chronological_timestamps()
    end

    @tag :segmentation_control
    test "control: per-line segmentation preserves order (why multi-event chunks matter)", ctx do
      parts = Enum.map(chronological_lines(), &(&1 <> "\n"))

      {_issue_id, run_result, delivered} = run_with_on_event(parts, ctx, part_delay_ms: 150)

      assert {:ok, _result} = run_result

      # One event per chunk has no intra-chunk order to reverse, so even the
      # defective dispatcher passes this. This is the control that shows the
      # regression is chunk-granular: hiding it only requires a segmentation
      # that never coalesces events, which real pipes do not promise.
      assert delivered_pairs(delivered) == chronological_sequence()
    end
  end

  # ===========================================================================
  # 3. Terminal stop and malformed lines
  # ===========================================================================

  describe "3. Terminal stop and malformed lines" do
    @describetag :ordering_regression

    test "a trailing terminal line without newline is not lost from the callback stream", ctx do
      lines = [
        step_start_line(@session, "msg_01", "step_s1", @base_ts),
        tool_use_line(@session, "msg_01", "toolu_01", "call_01", @base_ts + 100),
        step_finish_line(@session, "msg_01", "step_f1", "stop", @base_ts + 200,
          %{input: 10, output: 20, reasoning: 0, cache_read: 0, cache_write: 0}, 0.001)
      ]

      # No newline after the final line: the terminal event is only decoded by
      # Parser.finish at exit. The run result below proves the parser saw it;
      # the callback assertion proves the observer did too.
      parts = [Enum.join(lines, "\n")]

      {_issue_id, run_result, delivered} = run_with_on_event(parts, ctx)

      assert {:ok, result} = run_result
      assert result.completion_state == :completed
      assert result.usage.input_tokens == 10
      assert result.event_count == 3

      assert {"step_finish", "step_f1"} in delivered_pairs(delivered),
             "the terminal step_finish was parsed into the run result but never dispatched " <>
               "to on_event: events decoded by Parser.finish at exit are silently dropped"
    end

    test "a malformed line mid-chunk yields no callback event and fails closed (order-insensitive)",
         ctx do
      malformed = "{not-json-line " <> @raw_secret

      parts = [
        step_start_line(@session, "msg_01", "step_s1", @base_ts) <> "\n" <>
          malformed <> "\n" <>
          step_finish_line(@session, "msg_01", "step_f1", "stop", @base_ts + 100,
            %{input: 10, output: 20, reasoning: 0, cache_read: 0, cache_write: 0}, 0.001) <> "\n"
      ]

      {_issue_id, run_result, delivered} = run_with_on_event(parts, ctx)

      assert {:error, {_reason, result}} = run_result
      assert result.completion_state == :failed

      assert Enum.any?(result.failure_evidence, fn
               {:malformed_json_line, _, _} -> true
               _ -> false
             end)

      # Both valid events are delivered exactly once each (order asserted in
      # the dedicated ordering test below); nothing that resembles the
      # malformed line becomes a callback event.
      assert delivered_pairs(delivered) |> Enum.sort() ==
               Enum.sort([{"step_start", "step_s1"}, {"step_finish", "step_f1"}])

      refute inspect(delivered) =~ @raw_secret
      refute inspect(result) =~ @raw_secret
      refute inspect(result) =~ "Jason.DecodeError"
    end

    test "valid events around a malformed line are still delivered chronologically", ctx do
      malformed = "not-json-at-all-malformed-line"

      parts = [
        step_start_line(@session, "msg_01", "step_s1", @base_ts) <> "\n" <>
          malformed <> "\n" <>
          tool_use_line(@session, "msg_01", "toolu_01", "call_01", @base_ts + 100) <> "\n" <>
          step_finish_line(@session, "msg_01", "step_f1", "stop", @base_ts + 200,
            %{input: 10, output: 20, reasoning: 0, cache_read: 0, cache_write: 0}, 0.001) <> "\n"
      ]

      {_issue_id, _run_result, delivered} = run_with_on_event(parts, ctx)

      assert delivered_pairs(delivered) == [
               {"step_start", "step_s1"},
               {"tool_use", "toolu_01"},
               {"step_finish", "step_f1"}
             ]
    end
  end

  # ===========================================================================
  # 4. WorkerEvent consumption of the adapter callback stream
  # ===========================================================================

  describe "4. WorkerEvent consumption of the callback stream" do
    @describetag :ordering_regression

    test "chronological updates with cumulative usage snapshots and session identity", ctx do
      parts = [Enum.join(chronological_lines(), "\n") <> "\n"]

      {_issue_id, run_result, updates} = run_with_worker_event_callback(parts, ctx)

      assert {:ok, result} = run_result
      assert result.session_id == @session

      assert Enum.map(updates, & &1.event) == [
               :step_start,
               :step_finish,
               :tool_use,
               :step_start,
               :step_finish
             ]

      assert Enum.all?(updates, &(&1.session_id == @session))
      assert Enum.all?(updates, &(&1.harness == :opencode))

      timestamps = Enum.map(updates, &DateTime.to_unix(&1.timestamp, :millisecond))
      assert timestamps == chronological_timestamps()

      snapshots =
        for update <- updates, update.event == :step_finish do
          {update.usage.input_tokens, update.usage.output_tokens, Float.round(update.usage.cost, 6)}
        end

      assert snapshots == [{40, 60, 0.002}, {100, 150, 0.005}]
    end

    test "a duplicated terminal step_finish is deduplicated without double accounting", ctx do
      terminal = List.last(chronological_lines())
      parts = [Enum.join(chronological_lines() ++ [terminal], "\n") <> "\n"]

      {_issue_id, run_result, updates} = run_with_worker_event_callback(parts, ctx)

      assert {:ok, _result} = run_result

      assert Enum.map(updates, & &1.event) == [
               :step_start,
               :step_finish,
               :tool_use,
               :step_start,
               :step_finish
             ]

      # The duplicate terminal must be dropped by identity, so the final
      # snapshot stays the summed total, never twice it.
      final = updates |> Enum.filter(&(&1.event == :step_finish)) |> List.last()

      assert final.usage.input_tokens == 100
      assert final.usage.output_tokens == 150
      assert Float.round(final.usage.cost, 6) == 0.005
    end

    test "a mid-stream session change never locks out the canonical session events", ctx do
      canonical_stop =
        step_finish_line(@session_canonical, "msg_01", "step_f1", "stop", @base_ts + 100,
          %{input: 10, output: 20, reasoning: 0, cache_read: 0, cache_write: 0}, 0.001)

      parts = [
        step_start_line(@session_canonical, "msg_01", "step_s1", @base_ts) <> "\n" <>
          canonical_stop <> "\n" <>
          step_start_line(@session_rogue, "msg_02", "step_s2", @base_ts + 200) <> "\n"
      ]

      {_issue_id, run_result, updates} = run_with_worker_event_callback(parts, ctx)

      assert {:ok, result} = run_result
      assert result.session_id == @session_canonical

      # Chronological consumption locks the canonical session first and drops
      # only the conflicting event. Reversed chunk delivery inverts the lock:
      # the rogue session arrives first, and every canonical event — including
      # the terminal stop — is rejected, losing the whole observed stream.
      assert Enum.map(updates, &{&1.event, &1.session_id}) == [
               {:step_start, @session_canonical},
               {:step_finish, @session_canonical}
             ]
    end
  end
end
