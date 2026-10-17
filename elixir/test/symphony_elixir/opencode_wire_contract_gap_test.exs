defmodule SymphonyElixir.OpenCodeWireContractGapTest do
  @moduledoc """
  Expected-red contract gates for OpenCode 1.18.28 wire handling.

  Each gate asserts a behavior that the current Parser or Failure module does
  not yet provide. Gates are not skipped or made green, and this suite changes
  no production module.

  Gates carry one of two taxonomy tags:

  - :product_policy. The desired behavior is a Symphony policy decision. A red
    result does not establish a defect, because upstream evidence does not
    settle the policy question on its own.
  - :implementation_candidate. The gate becomes a code defect only if the
    referenced upstream shape is emitted at runtime. The upstream sources and
    tests read for this suite do not establish that emission.

  No gate is a demonstrated upstream defect. To run one taxonomy, use
  mix test --only product_policy or mix test --only implementation_candidate.

  Gap labels A1, A2, A3 and A5 are local to the remediation. Their source
  anchors are listed in docs/m1-opencode-wire-fixtures-provenance.md.
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

  @tag :product_policy
  test "GATE 1 (Gap A2): explicit tokens.total is reflected in total_tokens" do
    content = read_fixture!("synthetic_explicit_total.jsonl")

    result =
      Parser.new()
      |> Parser.feed(content)
      |> Parser.finish(0)
      |> Parser.to_result()

    # Synthetic explicit total 8643 (input 954 + output 9 + cache read 7680).
    # The current Parser sums input and output only, giving 963. Whether
    # total_tokens should follow an explicit provider total is a product decision:
    # packages/llm/src/protocols/shared.ts treats a provider total as authoritative,
    # while the input-plus-output fallback is documented as intentional.
    assert result.usage.total_tokens == 8643
  end

  @tag :product_policy
  test "GATE 2 (Gap A3): tool_error_recovery.jsonl allows recovery when the turn concludes with stop" do
    content = read_fixture!("tool_error_recovery.jsonl")

    result =
      Parser.new()
      |> Parser.feed(content)
      |> Parser.finish(0)
      |> Parser.to_result()

    # The current Parser latches completion_state :failed on any tool error
    # (Parser.process_tool_use/2). Whether a recovered tool error may complete
    # the turn is a fail-closed policy choice.
    assert result.completion_state == :completed
  end

  @tag :product_policy
  test "GATE 3 (Gap A1): terminal_reason_other.jsonl completes successfully on finish reason other" do
    content = read_fixture!("terminal_reason_other.jsonl")

    result =
      Parser.new()
      |> Parser.feed(content)
      |> Parser.finish(0)
      |> Parser.to_result()

    # The value "other" is synthetic: the v1.18.28 FinishReason union does not include it
    # (packages/llm/src/schema/ids.ts line 39). The current Parser terminal list is
    # stop, length, content-filter and unknown.
    assert result.completion_state == :completed
  end

  @tag :implementation_candidate
  test "GATE 4 (Gap A5, status): api_error_non_retryable_forbidden.jsonl maps statusCode 403 to :persistent_worker_failure" do
    [line] = fixture_lines("api_error_non_retryable_forbidden.jsonl")
    event = Jason.decode!(line)

    # The APIError schema (packages/schema/src/v1/session.ts lines 48-55) declares
    # statusCode optional. Failure.classify_error_map/1 reads only status, so
    # statusCode is ignored. This is a defect only if the CLI emits statusCode.
    assert Failure.classify(event["error"]) == :persistent_worker_failure
  end

  @tag :implementation_candidate
  test "GATE 5 (Gap A5, name): ProviderAuthError classifies directly as :auth_unavailable" do
    error_map = %{
      "name" => "ProviderAuthError",
      "data" => %{
        "providerID" => "anthropic",
        "message" => "Key rejected"
      }
    }

    # The AuthError schema (packages/schema/src/v1/session.ts lines 38-41) names the
    # error ProviderAuthError. Failure.classify_error_map/1 checks only AuthError and
    # UnauthorizedError by name. This is a defect only if the CLI emits this name.
    assert Failure.classify(error_map) == :auth_unavailable
  end
end
