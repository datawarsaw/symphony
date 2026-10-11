defmodule SymphonyElixir.OpenCodeTerminalReasonTest do
  @moduledoc """
  M1-TERM-F: Fail-closed OpenCode terminal reason eligibility.

  Upstream OpenCode v1.18.28 treats the finish reason "unknown" as
  non-concluding and maps unsupported finish reasons to "unknown". A stream
  that ends with step_finish(reason="unknown") therefore carries no explicit
  model-side conclusion and must never authorize clean worker success, even
  with exit status 0 and an otherwise clean stream.

  Contract under test:
  1. Only an explicit finish reason "stop" is eligible for clean success.
  2. "unknown" and "other" remain observational terminal completions
     (completion_state: :completed) but are never eligible.
  3. unknown-last and other-last executions fail with an explicit
     {:terminal_reason, reason} failure instead of a misleading
     {:process_exit, 0}.
  4. unknown followed by later activity and a final "stop" stays eligible
     when every other safety gate is satisfied.
  5. An exit-0 stream without any terminal finish event still fails closed
     as an incomplete stream.
  """

  use SymphonyElixir.TestSupport

  Code.require_file("../support/mock_opencode.exs", __DIR__)

  alias SymphonyElixir.OpenCode
  alias SymphonyElixir.OpenCode.{Failure, Parser}
  alias SymphonyElixir.TestSupport.MockOpenCode

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "m1term-workspace-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)

    # PILOT-AUTH-F: launches pass the production credential preflight with a
    # synthetic placeholder credential (offline, never authenticated).
    saved_credential = System.get_env("ANTHROPIC_API_KEY")
    System.put_env("ANTHROPIC_API_KEY", "sk-ant-synthetic-test-placeholder")

    on_exit(fn ->
      restore_env("ANTHROPIC_API_KEY", saved_credential)
      File.rm_rf(workspace)
    end)

    {:ok, workspace: workspace}
  end

  # ===========================================================================
  # 1. Parser eligibility: only "stop" authorizes clean success
  # ===========================================================================

  describe "1. Parser terminal-reason eligibility" do
    test "unknown-last is observational terminal but not eligible for clean success" do
      stream =
        step_start_line("ses_u", "msg_1") <>
          text_line("ses_u", "inconclusive model output") <>
          step_finish_line("ses_u", "msg_1", "unknown", 10, 20)

      result = feed_stream(stream)
      assert result.completion_state == :completed
      assert result.finish_reason == "unknown"
      assert result.failure_evidence == []
      assert result.tool_failures == []
      assert Parser.terminal_finish_reason?("unknown") == true
      assert Parser.eligible_finish_reason?("unknown") == false
    end

    test "other-last is observational terminal but not eligible for clean success" do
      stream =
        step_start_line("ses_o", "msg_1") <>
          step_finish_line("ses_o", "msg_1", "other", 10, 20)

      result = feed_stream(stream)
      assert result.completion_state == :completed
      assert result.finish_reason == "other"
      assert result.failure_evidence == []
      assert Parser.terminal_finish_reason?("other") == true
      assert Parser.eligible_finish_reason?("other") == false
    end

    test "stop remains the only eligible terminal reason" do
      for reason <- ["length", "content-filter", "unknown", "other", "tool-calls", "error"] do
        assert Parser.eligible_finish_reason?(reason) == false
      end

      assert Parser.eligible_finish_reason?("stop") == true
    end

    test "unknown followed by later text and a final stop stays eligible" do
      stream =
        step_start_line("ses_us", "msg_1") <>
          step_finish_line("ses_us", "msg_1", "unknown", 10, 20) <>
          step_start_line("ses_us", "msg_2") <>
          text_line("ses_us", "model continues after the inconclusive step") <>
          step_finish_line("ses_us", "msg_2", "stop", 30, 40)

      result = feed_stream(stream)
      assert result.completion_state == :completed
      assert result.finish_reason == "stop"
      assert result.failure_evidence == []
      assert result.tool_failures == []
      assert Parser.eligible_finish_reason?(result.finish_reason) == true
    end
  end

  # ===========================================================================
  # 2. Adapter authority: unknown/other-last fail closed with explicit reason
  # ===========================================================================

  describe "2. Adapter terminal-reason authority" do
    @tag :windows_only
    test "unknown-last stream with exit 0 fails with {:terminal_reason, \"unknown\"}, not {:ok, result}", %{
      workspace: workspace
    } do
      outcome = run_mock(workspace, "--mock-mode=reason-unknown")

      assert {:error, {{:terminal_reason, "unknown"}, result}} = outcome

      # The protocol observation is preserved even though success is denied.
      assert result.exit_code == 0
      assert result.completion_state == :completed
      assert result.finish_reason == "unknown"
      assert result.failure_evidence == []

      # Retryable classification bounded by the existing retry policy.
      assert result.failure_info.failure_class == :transient_worker_failure
    end

    @tag :windows_only
    test "other-last stream with exit 0 fails with {:terminal_reason, \"other\"}, not {:ok, result}", %{
      workspace: workspace
    } do
      outcome = run_mock(workspace, "--mock-mode=reason-other")

      assert {:error, {{:terminal_reason, "other"}, result}} = outcome

      assert result.exit_code == 0
      assert result.completion_state == :completed
      assert result.finish_reason == "other"
      assert result.failure_evidence == []
      assert result.failure_info.failure_class == :transient_worker_failure
    end

    @tag :windows_only
    test "unknown-then-stop stream with exit 0 succeeds when all other gates pass", %{
      workspace: workspace
    } do
      assert {:ok, result} = run_mock(workspace, "--mock-mode=reason-unknown-then-stop")

      assert result.exit_code == 0
      assert result.completion_state == :completed
      assert result.finish_reason == "stop"
      assert result.failure_evidence == []
      assert result.tool_failures == []
    end

    @tag :windows_only
    test "exit-0 stream without a terminal finish event fails closed as incomplete", %{
      workspace: workspace
    } do
      outcome = run_mock(workspace, "--mock-mode=partial")

      assert {:error, {{:incomplete_stream, :missing_completion_event}, result}} = outcome

      assert result.exit_code == 0
      assert result.completion_state == :failed
      assert {:incomplete_stream, :missing_completion_event} in result.failure_evidence
    end
  end

  # ===========================================================================
  # 3. Failure classification for terminal-reason denials
  # ===========================================================================

  describe "3. Failure classification" do
    test "unknown and other terminal reasons classify as retryable transient failures" do
      assert Failure.classify({:terminal_reason, "unknown"}) == :transient_worker_failure
      assert Failure.classify({:terminal_reason, "other"}) == :transient_worker_failure
    end

    test "length stays transient and content-filter stays persistent" do
      assert Failure.classify({:terminal_reason, "length"}) == :transient_worker_failure
      assert Failure.classify({:terminal_reason, "content-filter"}) == :persistent_worker_failure
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp run_mock(workspace, prompt, extra \\ []) do
    mock_exe = MockOpenCode.ensure_built!()

    OpenCode.run(
      workspace,
      prompt,
      Keyword.merge(
        [
          provider: "anthropic",
          model: "claude-3-5-sonnet",
          executable: mock_exe,
          timeout_ms: 8_000
        ],
        extra
      )
    )
  end

  defp feed_stream(stream) do
    Parser.new() |> Parser.feed(stream) |> Parser.finish(0) |> Parser.to_result()
  end

  defp jsonl(map), do: Jason.encode!(map) <> "\n"

  defp step_start_line(session_id, message_id) do
    jsonl(%{
      "type" => "step_start",
      "timestamp" => 1,
      "sessionID" => session_id,
      "part" => %{
        "type" => "step-start",
        "id" => "part_start_" <> message_id,
        "sessionID" => session_id,
        "messageID" => message_id
      }
    })
  end

  defp step_finish_line(session_id, message_id, reason, in_tok, out_tok) do
    jsonl(%{
      "type" => "step_finish",
      "timestamp" => 2,
      "sessionID" => session_id,
      "part" => %{
        "type" => "step-finish",
        "id" => "part_finish_" <> message_id,
        "sessionID" => session_id,
        "messageID" => message_id,
        "reason" => reason,
        "cost" => 0.001,
        "tokens" => %{"input" => in_tok, "output" => out_tok}
      }
    })
  end

  defp text_line(session_id, text) do
    jsonl(%{
      "type" => "text",
      "timestamp" => 3,
      "sessionID" => session_id,
      "part" => %{"type" => "text", "text" => text}
    })
  end
end
