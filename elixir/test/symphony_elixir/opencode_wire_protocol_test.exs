defmodule SymphonyElixir.OpenCodeWireProtocolTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.OpenCode.Failure
  alias SymphonyElixir.OpenCode.Parser

  @fixtures_dir Path.expand("../fixtures/opencode_wire", __DIR__)

  defp read_fixture!(filename) do
    @fixtures_dir
    |> Path.join(filename)
    |> File.read!()
  end

  defp fixture_lines(filename) do
    filename
    |> read_fixture!()
    |> String.split(["\r\n", "\n"], trim: true)
  end

  describe "manifest and fixture hygiene" do
    test "manifest documents all wire fixtures with explicit provenance labeling" do
      manifest_path = Path.join(@fixtures_dir, "manifest.json")
      assert File.exists?(manifest_path)

      manifest = Jason.decode!(File.read!(manifest_path))
      assert manifest["version"] == "1.18.28"
      assert manifest["upstream_repository"] == "anomalyco/opencode"
      assert manifest["upstream_commit_sha"] == "22006d97652839999596a34a48ff6be7dbb40c6e"

      fixtures = manifest["fixtures"]
      assert is_list(fixtures)
      assert length(fixtures) == 9

      valid_labels = ~w(upstream-derived schema-derived synthetic)

      for fix <- fixtures do
        assert fix["label"] in valid_labels, "Invalid label #{fix["label"]} for #{fix["name"]}"
        assert is_binary(fix["description"])
        assert is_list(fix["source_references"]) and length(fix["source_references"]) > 0
        assert is_list(fix["wire_events"]) and length(fix["wire_events"]) > 0

        # Verify physical file existence
        file_path = Path.join(@fixtures_dir, fix["name"])
        assert File.exists?(file_path), "Fixture file #{fix["name"]} must exist"

        # If not synthetic malformed control, every line must be valid JSON
        if fix["name"] != "synthetic_malformed_control.jsonl" do
          lines = fixture_lines(fix["name"])
          assert length(lines) > 0

          for line <- lines do
            assert {:ok, %{}} = Jason.decode(line)
          end
        end
      end
    end
  end

  describe "upstream-derived fixtures" do
    test "single_turn_success.jsonl parses cleanly and exposes total_tokens accounting gap" do
      content = read_fixture!("single_turn_success.jsonl")

      parser =
        Parser.new()
        |> Parser.feed(content)
        |> Parser.finish(0)

      result = Parser.to_result(parser)

      assert result.completion_state == :completed
      assert result.failure_evidence == []
      assert result.session_id == "ses_01J9W18A2B3C4D5E6F7G8H9J0K"
      assert result.message_ids == ["msg_01J9W18A2B3C4D5E6F7G8H9M01"]

      # Tokens captured individually
      assert result.usage.input_tokens == 954
      assert result.usage.output_tokens == 9
      assert result.usage.reasoning_tokens == 0
      assert result.usage.cache_read_tokens == 7680
      assert result.usage.cache_write_tokens == 0
      assert result.usage.cost == 0.00312

      # Accounting divergence check (Audit M1-W Finding A2):
      # Current Symphony implementation computes total_tokens = input + output
      assert result.usage.total_tokens == 963

      # Upstream 1.18.28 wire contract has explicit tokens.total = input + output + reasoning + cache.read + cache.write
      raw_last_event =
        fixture_lines("single_turn_success.jsonl")
        |> List.last()
        |> Jason.decode!()

      upstream_total = get_in(raw_last_event, ["part", "tokens", "total"])
      assert upstream_total == 8643

      # Disparity: current implementation underreports total when prompt cache is used
      assert result.usage.total_tokens < upstream_total
      assert upstream_total - result.usage.total_tokens == 7680
    end

    test "multi_step_tool_success.jsonl handles intermediate tool-calls step and terminal completion" do
      lines = fixture_lines("multi_step_tool_success.jsonl")

      # Step 1: step_start, tool_use, intermediate step_finish(reason: "tool-calls")
      step1 = Enum.take(lines, 3) |> Enum.join("\n") |> Kernel.<>("\n")

      parser_step1 =
        Parser.new()
        |> Parser.feed(step1)

      # Intermediate check: turn is still running
      assert parser_step1.completion_state == :running
      assert length(parser_step1.tool_events) == 1

      [tool] = parser_step1.tool_events
      assert tool.tool == "read_file"
      assert tool.call_id == "call_01J9W18B01C2D3E4F5G6H7J8C1"
      assert tool.status == "completed"

      # Step 2: step_start, text, terminal step_finish(reason: "stop")
      step2 = Enum.drop(lines, 3) |> Enum.join("\n") |> Kernel.<>("\n")

      parser_final =
        parser_step1
        |> Parser.feed(step2)
        |> Parser.finish(0)

      result = Parser.to_result(parser_final)

      assert result.completion_state == :completed
      assert result.failure_evidence == []
      assert result.session_id == "ses_01J9W18B01C2D3E4F5G6H7J8K9"
      assert result.message_ids == ["msg_01J9W18B01C2D3E4F5G6H7J8M1", "msg_01J9W18B01C2D3E4F5G6H7J8M2"]
      assert result.usage.input_tokens == 2550
      assert result.usage.output_tokens == 120
      assert result.usage.cost == 0.0033
    end

    test "reasoning_thinking_turn.jsonl parses thinking part and accumulates reasoning tokens" do
      content = read_fixture!("reasoning_thinking_turn.jsonl")

      result =
        Parser.new()
        |> Parser.feed(content)
        |> Parser.finish(0)
        |> Parser.to_result()

      assert result.completion_state == :completed
      assert result.failure_evidence == []
      assert result.usage.input_tokens == 1500
      assert result.usage.output_tokens == 150
      assert result.usage.reasoning_tokens == 600
      assert result.usage.cost == 0.005

      # Current total_tokens ignores reasoning tokens (1500 + 150 = 1650 vs wire total 2250)
      assert result.usage.total_tokens == 1650
      wire_total = 2250
      assert result.usage.total_tokens + result.usage.reasoning_tokens == wire_total
    end
  end

  describe "policy-sensitive fixtures" do
    test "tool_error_recovery.jsonl documents tool error latching behavior vs upstream recovery" do
      content = read_fixture!("tool_error_recovery.jsonl")

      result =
        Parser.new()
        |> Parser.feed(content)
        |> Parser.finish(0)
        |> Parser.to_result()

      # Current Symphony behavior (Audit M1-W Finding A3):
      # process_tool_use latches completion_state: :failed on status == "error",
      # and apply_step_finish_reason only completes when state is :running.
      # Therefore, even with exit code 0 and final step_finish reason "stop", the turn fails closed.
      assert result.completion_state == :failed
      assert length(result.tool_events) == 1

      [tool] = result.tool_events
      assert tool.tool == "read_file"
      assert tool.status == "error"
      assert tool.error =~ "ENOENT"

      assert Enum.any?(result.failure_evidence, fn
               {:tool_error, "read_file", err} -> err =~ "ENOENT"
               _ -> false
             end)

      # Upstream 1.18.28 protocol reality:
      # The CLI handles tool errors inside the session loop and exits 0 when the model
      # concludes its recovery step cleanly with "stop".
      # This test confirms that Symphony fail-closed policy remains active until
      # an intentional product recovery decision is made.
    end

    test "terminal_reason_other.jsonl documents rejection of 'other' finishReason" do
      content = read_fixture!("terminal_reason_other.jsonl")

      result =
        Parser.new()
        |> Parser.feed(content)
        |> Parser.finish(0)
        |> Parser.to_result()

      # Current Symphony behavior (Audit M1-W Finding A1):
      # @terminal_step_reasons is ~w(stop length content-filter unknown).
      # "other" is not in this list, so apply_step_finish_reason does not transition
      # to :completed, and finish/2 records {:incomplete_stream, :missing_completion_event}.
      assert result.completion_state == :failed

      assert Enum.any?(result.failure_evidence, fn
               {:incomplete_stream, :missing_completion_event} -> true
               _ -> false
             end)

      # Upstream 1.18.28 protocol reality:
      # AI SDK finishReason mapper in opencode binary returns "other" as default fallback.
    end
  end

  describe "schema-derived API and provider errors" do
    test "api_error_retryable_rate_limit.jsonl carries statusCode 429 and isRetryable" do
      [line] = fixture_lines("api_error_retryable_rate_limit.jsonl")
      event = Jason.decode!(line)

      assert event["type"] == "error"
      assert event["error"]["name"] == "APIError"
      data = event["error"]["data"]
      assert data["statusCode"] == 429
      assert data["isRetryable"] == true

      # Parsing through Parser
      result =
        Parser.new()
        |> Parser.feed(line <> "\n")
        |> Parser.finish(1)
        |> Parser.to_result()

      assert result.completion_state == :failed

      # Classification check:
      # Current Failure.classify_error_map checks map["status"] or data["status"].
      # Because upstream schema uses data["statusCode"], the status check misses,
      # but message matches "Rate limit", so classify_text catches it as :provider_rate_limit.
      assert Failure.classify(event["error"]) == :provider_rate_limit
    end

    test "api_error_non_retryable_forbidden.jsonl exposes status vs statusCode classification gap" do
      [line] = fixture_lines("api_error_non_retryable_forbidden.jsonl")
      event = Jason.decode!(line)

      assert event["type"] == "error"
      assert event["error"]["name"] == "APIError"
      data = event["error"]["data"]
      assert data["statusCode"] == 403
      assert data["isRetryable"] == false

      # Current Failure classification (Audit M1-W Finding A5):
      # In Failure.classify_error_map, status is read from "status" instead of "statusCode".
      # For a 403 where message doesn't contain explicit permission strings,
      # classification fails to match HTTP 403 (:persistent_worker_failure)
      # and falls back to :transient_worker_failure.
      current_class = Failure.classify(event["error"])
      assert current_class == :transient_worker_failure

      # Document desired behavior:
      # If data["statusCode"] == 403 were read, this would be classified as :persistent_worker_failure.
      desired_class = :persistent_worker_failure
      assert current_class != desired_class
    end

    test "provider_auth_error.jsonl classifies ProviderAuthError" do
      [line] = fixture_lines("provider_auth_error.jsonl")
      event = Jason.decode!(line)

      assert event["type"] == "error"
      assert event["error"]["name"] == "ProviderAuthError"

      # Current Failure classification:
      # name in ["AuthError", "UnauthorizedError"] does not match "ProviderAuthError",
      # but message contains "Invalid API key", so classify_text resolves :auth_unavailable.
      assert Failure.classify(event["error"]) == :auth_unavailable
    end
  end

  describe "stream framing and chunking invariance" do
    test "framing invariance: 1-byte, 3-byte, line, and whole chunks yield identical results" do
      raw = read_fixture!("single_turn_success.jsonl")

      # Baseline: single feed
      baseline =
        Parser.new()
        |> Parser.feed(raw)
        |> Parser.finish(0)
        |> Parser.to_result()

      # 1-byte chunks
      one_byte_result =
        raw
        |> :binary.bin_to_list()
        |> Enum.reduce(Parser.new(), fn byte, acc ->
          Parser.feed(acc, <<byte>>)
        end)
        |> Parser.finish(0)
        |> Parser.to_result()

      assert one_byte_result == baseline

      # 3-byte chunks across arbitrary boundaries
      three_byte_result =
        raw
        |> chunk_binary(3)
        |> Enum.reduce(Parser.new(), fn chunk, acc ->
          Parser.feed(acc, chunk)
        end)
        |> Parser.finish(0)
        |> Parser.to_result()

      assert three_byte_result == baseline

      # Line by line
      line_result =
        fixture_lines("single_turn_success.jsonl")
        |> Enum.reduce(Parser.new(), fn line, acc ->
          Parser.feed(acc, line <> "\r\n")
        end)
        |> Parser.finish(0)
        |> Parser.to_result()

      assert line_result == baseline
    end

    test "trailing buffer without newline is finalized by finish/2" do
      lines = fixture_lines("single_turn_success.jsonl")
      # Omit trailing newline on last line
      payload_without_trailing_nl = Enum.join(lines, "\n")

      result =
        Parser.new()
        |> Parser.feed(payload_without_trailing_nl)
        |> Parser.finish(0)
        |> Parser.to_result()

      assert result.completion_state == :completed
      assert result.usage.total_tokens == 963
    end
  end

  describe "synthetic negative control" do
    test "synthetic_malformed_control.jsonl captures corrupt line into failure_evidence" do
      content = read_fixture!("synthetic_malformed_control.jsonl")

      result =
        Parser.new()
        |> Parser.feed(content)
        |> Parser.finish(0)
        |> Parser.to_result()

      assert result.completion_state == :failed

      assert Enum.any?(result.failure_evidence, fn
               {:malformed_json_line, text, _err} -> text =~ "CORRUPT_NON_JSON_LINE"
               _ -> false
             end)
    end
  end

  defp chunk_binary(binary, size) when is_binary(binary) and size > 0 do
    do_chunk_binary(binary, size, [])
  end

  defp do_chunk_binary(<<>>, _size, acc), do: Enum.reverse(acc)

  defp do_chunk_binary(binary, size, acc) when byte_size(binary) <= size do
    Enum.reverse([binary | acc])
  end

  defp do_chunk_binary(binary, size, acc) do
    <<chunk::binary-size(size), rest::binary>> = binary
    do_chunk_binary(rest, size, [chunk | acc])
  end
end

