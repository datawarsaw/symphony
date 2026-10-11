defmodule SymphonyElixir.OpenCodeWireContractGapTest do
  @moduledoc """
  Expected-red protocol contract test suite for OpenCode 1.18.28 wire alignment.

  ISOLATION NOTE:
  These checks assert the DESIRED upstream OpenCode 1.18.28 behavior for the
  gaps identified in protocol audit M1-W (findings A1, A2, A3, A5).
  Because production modules (Parser, Failure, Adapter) remain untouched
  in this fixture candidate task, these tests currently fail red against the
  baseline implementation.

  Per the test contract:
  - Tests in this module are tagged with `@moduletag :expected_red`.
  - They are NOT skipped or made artificially green.
  - They fail with exact assertions describing what implementation change is required.
  - When production modules are updated in subsequent implementation tasks,
    these gates will turn green.
  """

  use ExUnit.Case, async: true

  @moduletag :expected_red

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

  test "GATE 1 (Audit A2): single_turn_success.jsonl accounts for full tokens.total on wire" do
    content = read_fixture!("single_turn_success.jsonl")

    result =
      Parser.new()
      |> Parser.feed(content)
      |> Parser.finish(0)
      |> Parser.to_result()

    # Wire event has tokens.total = 8643 (input 954 + output 9 + cache.read 7680)
    # Current implementation reports 963 (input 954 + output 9 only).
    assert result.usage.total_tokens == 8643
  end

  test "GATE 2 (Audit A3): tool_error_recovery.jsonl allows recovery when turn concludes with stop" do
    content = read_fixture!("tool_error_recovery.jsonl")

    result =
      Parser.new()
      |> Parser.feed(content)
      |> Parser.finish(0)
      |> Parser.to_result()

    # Upstream CLI completes naturally with exit 0 when model recovers from tool error.
    # Current implementation latches completion_state: :failed on tool error.
    assert result.completion_state == :completed
  end

  test "GATE 3 (Audit A1): terminal_reason_other.jsonl completes successfully on finishReason 'other'" do
    content = read_fixture!("terminal_reason_other.jsonl")

    result =
      Parser.new()
      |> Parser.feed(content)
      |> Parser.finish(0)
      |> Parser.to_result()

    # Upstream AI SDK maps unknown provider completion states to "other".
    # Current implementation only recognizes stop, length, content-filter, unknown.
    assert result.completion_state == :completed
  end

  test "GATE 4 (Audit A5): api_error_non_retryable_forbidden.jsonl maps statusCode 403 to :persistent_worker_failure" do
    [line] = fixture_lines("api_error_non_retryable_forbidden.jsonl")
    event = Jason.decode!(line)

    # Upstream APIError carries statusCode 403 and isRetryable: false.
    # Current implementation checks map["status"] instead of data["statusCode"],
    # falling back to :transient_worker_failure instead of :persistent_worker_failure.
    assert Failure.classify(event["error"]) == :persistent_worker_failure
  end

  test "GATE 5 (Audit A5): ProviderAuthError error name classifies directly as :auth_unavailable" do
    error_map = %{
      "name" => "ProviderAuthError",
      "data" => %{
        "providerID" => "anthropic",
        "message" => "Key rejected"
      }
    }

    # Upstream AuthError is named "ProviderAuthError".
    # Current implementation only checks "AuthError" and "UnauthorizedError" in name list.
    assert Failure.classify(error_map) == :auth_unavailable
  end
end

