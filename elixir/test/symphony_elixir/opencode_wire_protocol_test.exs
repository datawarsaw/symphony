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
      assert manifest["live_capture_status"] == "none"

      fixtures = manifest["fixtures"]
      assert is_list(fixtures)
      assert length(fixtures) == 11

      valid_labels = ~w(cli-emission-shape schema-derived synthetic)

      for fix <- fixtures do
        assert fix["label"] in valid_labels, "Invalid label #{fix["label"]} for #{fix["name"]}"
        assert is_binary(fix["description"])
        assert fix["captured_from_live_cli"] == false
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

  describe "cli-emission-shape fixtures" do
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

      # M1-U-F additive wire contract: total is the five-category sum
      # (954 input + 9 output + 0 reasoning + 7680 cache read + 0 cache write).
      assert result.usage.total_tokens == 8643

      # This fixture carries no tokens.total (removed in remediation; see the provenance document).
      raw_last_event =
        fixture_lines("single_turn_success.jsonl")
        |> List.last()
        |> Jason.decode!()

      assert get_in(raw_last_event, ["part", "tokens", "total"]) == nil
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

      # M1-U-F additive wire contract: 1500 input + 150 output + 600 reasoning.
      assert result.usage.total_tokens == 2250
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

      # M1-SEM-F (accepted): a recovered tool error no longer latches the
      # protocol stream failed — the turn that concludes with "stop" completes
      # at the protocol level while the tool error stays recorded as evidence
      # and blocks clean worker success downstream.
      assert result.completion_state == :completed
      assert length(result.tool_events) == 1

      [tool] = result.tool_events
      assert tool.tool == "read_file"
      assert tool.status == "error"
      assert tool.error =~ "ENOENT"

      # M1-SEM-F: tool errors are recorded separately in tool_failures and stay
      # disqualifying for clean worker success even though the protocol turn
      # completes on the concluding "stop".
      assert Enum.any?(result.tool_failures, fn
               {:tool_error, "read_file", err} -> err =~ "ENOENT"
               _ -> false
             end)
      assert result.completion_state == :completed
    end

    test "terminal_reason_other.jsonl documents rejection of 'other' finishReason" do
      content = read_fixture!("terminal_reason_other.jsonl")

      result =
        Parser.new()
        |> Parser.feed(content)
        |> Parser.finish(0)
        |> Parser.to_result()

      # M1-TERM-F (accepted): "other" is observational terminal — the protocol
      # turn concludes, so the stream completes — but it never authorizes clean
      # worker success (only an explicit "stop" is eligible).
      assert result.completion_state == :completed
      assert result.failure_evidence == []
      refute Parser.eligible_finish_reason?("other")
      assert Parser.terminal_finish_reason?("other")

      # Synthetic input: "other" is not in the v1.18.28 FinishReason union (packages/llm/src/schema/ids.ts line 39).
      # The AI SDK bridge maps unrecognized finish reasons to "unknown" (packages/opencode/src/session/llm/ai-sdk.ts lines 22-23).
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

      # M1-API-F (accepted): classification reads the upstream statusCode
      # field, so an explicit HTTP 403 is persistent, never retried as transient.
      current_class = Failure.classify(event["error"])
      assert current_class == :persistent_worker_failure
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
      assert result.usage.total_tokens == 8643
    end
  end

  describe "synthetic schema-optional tokens.total contract" do
    test "explicit tokens.total is honored as the authoritative per-step total" do
      content = read_fixture!("synthetic_explicit_total.jsonl")

      result =
        Parser.new()
        |> Parser.feed(content)
        |> Parser.finish(0)
        |> Parser.to_result()

      assert result.completion_state == :completed
      assert result.failure_evidence == []
      assert result.usage.input_tokens == 954
      assert result.usage.output_tokens == 9
      assert result.usage.cache_read_tokens == 7680

      # M1-U-F: an explicit wire total is the source of truth and is never
      # summed on top of the categories (here it also equals the additive sum).
      assert result.usage.total_tokens == 8643
    end

    test "explicit zero tokens.total parses as a zero-usage terminal turn" do
      content = read_fixture!("synthetic_explicit_total_zero.jsonl")

      result =
        Parser.new()
        |> Parser.feed(content)
        |> Parser.finish(0)
        |> Parser.to_result()

      assert result.completion_state == :completed
      assert result.failure_evidence == []
      assert result.usage.total_tokens == 0
      assert result.usage.input_tokens == 0
      assert result.usage.output_tokens == 0
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
