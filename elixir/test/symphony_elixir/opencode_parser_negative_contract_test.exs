defmodule SymphonyElixir.OpenCodeParserNegativeContractTest do
  @moduledoc """
  M1-P-N: deterministic negative contract tests for the OpenCode worker-event
  parser and the adapter completion boundary.

  Baseline: 9ce11fd (M1-D dispatch wiring). The parser exercised here is
  byte-for-byte the assembly parser reviewed in M1-A (8b329e4); between those
  two revisions only elixir/lib/symphony_elixir/opencode/adapter.ex changed.

  Scope: tests and test fixtures only. No production module
  (Parser, Adapter, WorkerEvent, Orchestrator) is modified by this suite.

  Assertion policy (required actions 7 and 8):
  every expectation is grounded in either an existing documented contract of
  the module under test (Parser moduledoc resilience/completion semantics,
  WorkerEvent moduledoc duplicate-step accounting, Adapter moduledoc positive
  completion), or in the fail-closed contract this task defines for an invalid
  event shape (required action 2). Assertions that fail on the frozen baseline
  are demonstrated defects (RED); assertions that already hold pin existing
  behavior (GREEN). No assertion is weakened to reach a green result.

  Out of scope (required action 8): OpenCode callback ordering, which belongs
  to M1-T2.

  Inventory on the frozen baseline (see closeout for measured counts):
    RED  - Parser.feed raises on valid non-object JSON values (M1-A S14-S17)
    RED  - invalid event shape is not captured as fail-closed evidence
    RED  - timeout after a terminal step_finish still presents a completed run
    RED  - byte-identical duplicate step_finish lines double count usage/cost
    RED  - a foreign session's terminal completion is credited to the locked session
    RED  - a terminal completion with no session identity is reported as success
    GREEN- distinct step_finish events accumulate per-step usage
    GREEN- a hung turn is returned as a timeout error, never as success
    GREEN- sessionless events never lock a session; a locked session id is stable
    GREEN- terminal observations grant no completion authority
    GREEN- protocol completion without confirmed termination is an error
    GREEN- Human Acceptance needs its own workflow state and evidence
  """

  use SymphonyElixir.TestSupport

  Code.require_file("../support/mock_opencode.exs", __DIR__)

  alias SymphonyElixir.HumanAcceptance
  alias SymphonyElixir.OpenCode
  alias SymphonyElixir.OpenCode.Parser
  alias SymphonyElixir.TestSupport.MockOpenCode
  alias SymphonyElixir.WorkerEvent

  @secret "sk-ant-api03-abcdefghijklmnopqrstuvwxyz"
  @max_evidence_bytes 4_096

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "m1pn-workspace-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)
    {:ok, workspace: workspace}
  end

  # ===========================================================================
  # M1-P-N-1 / M1-P-N-2: parser resilience and fail-closed invalid shapes
  # ===========================================================================

  describe "M1-P-N-1 Parser.feed on valid non-object JSON values (M1-A S14-S17)" do
    # Grounding: the Parser moduledoc declares that malformed or corrupt lines
    # must never crash the stream parser and must instead be captured into
    # failure_evidence so the run fails closed with deterministic evidence. A
    # valid-JSON value that is not an event object is exactly such a line.
    test "S14 a valid JSON number line does not crash the parser and fails closed" do
      assert_parser_fails_closed_for_non_object("123")
    end

    test "S15 a valid JSON string line does not crash the parser and fails closed" do
      assert_parser_fails_closed_for_non_object(~s("hi"))
    end

    test "S16 a valid JSON array line does not crash the parser and fails closed" do
      assert_parser_fails_closed_for_non_object("[1,2]")
    end

    test "S17 a valid JSON null line does not crash the parser and fails closed" do
      assert_parser_fails_closed_for_non_object("null")
    end
  end

  describe "M1-P-N-2 fail-closed evidence for an invalid event shape" do
    test "non-object JSON evidence is bounded, redacted and JSON-encodable" do
      result = assert_parser_fails_closed_for_non_object(~s(") <> @secret <> ~s("))

      assert [{:invalid_event_shape, preview}] = invalid_shape_evidence(result.failure_evidence)

      assert is_binary(preview)
      assert String.valid?(preview)
      assert byte_size(preview) <= @max_evidence_bytes
      assert preview =~ "[redacted]"
      refute preview =~ @secret
      assert match?({:ok, _}, Jason.encode(preview))
    end

    test "an oversized non-object JSON line stays bounded and JSON-encodable" do
      line = ~s(") <> String.duplicate("a", 20_000) <> ~s(")
      result = assert_parser_fails_closed_for_non_object(line)

      assert [{:invalid_event_shape, preview}] = invalid_shape_evidence(result.failure_evidence)

      assert String.valid?(preview)
      assert byte_size(preview) <= @max_evidence_bytes
      assert match?({:ok, _}, Jason.encode(preview))
    end

    test "the parser stays usable after a non-object line and stays failed closed" do
      state =
        Parser.new()
        |> feed!("123\n")
        |> feed!(step_finish_line("ses_x", "m1", "stop", 10, 20, 0.001))
        |> Parser.finish(0)

      result = Parser.to_result(state)

      assert result.session_id == "ses_x"
      assert result.completion_state == :failed
      assert result.failure_evidence != []
    end
  end

  # ===========================================================================
  # M1-P-N-3: terminal step_finish followed by an adapter timeout
  # ===========================================================================

  describe "M1-P-N-3 terminal step_finish followed by an adapter timeout" do
    # The fixture mode terminal-then-hang emits a terminal step_finish and then
    # never terminates, so the adapter hits timeout_ms while the protocol is
    # already "complete".
    @tag :windows_only
    test "a hang after a terminal step_finish returns a timeout error, never success", %{
      workspace: workspace
    } do
      assert {:error, {:timeout, result}} =
               run_mock(workspace, "--mock-mode=terminal-then-hang", timeout_ms: 1_500)

      assert result.exit_code == 253
      assert result.termination.status == :TERMINATED_CONFIRMED
    end

    @tag :windows_only
    test "a timeout must not present the run as completed", %{workspace: workspace} do
      assert {:error, {:timeout, result}} =
               run_mock(workspace, "--mock-mode=terminal-then-hang", timeout_ms: 1_500)

      # The worker never terminated, so the run is not completed. A consumer
      # that reads only completion_state/failure_evidence from the timeout
      # result must not be able to see a clean success.
      assert result.completion_state == :failed
      assert result.failure_evidence != []
    end
  end

  # ===========================================================================
  # M1-P-N-4: duplicate step_finish usage and cost accumulation
  # ===========================================================================

  describe "M1-P-N-4 step_finish usage and cost accounting" do
    test "distinct step_finish events accumulate their per-step usage" do
      stream =
        step_finish_line("ses_u", "m1", "tool-calls", 10, 20, 0.001) <>
          step_finish_line("ses_u", "m2", "stop", 2, 3, 0.002)

      result = feed_stream(stream)

      assert result.completion_state == :completed
      assert result.failure_evidence == []
      assert result.usage.input_tokens == 12
      assert result.usage.output_tokens == 23
      assert result.usage.total_tokens == 35
      assert_in_delta result.usage.cost, 0.003, 1.0e-9
    end

    test "byte-identical duplicate step_finish lines are not double counted" do
      line = step_finish_line("ses_u", "m1", "stop", 10, 20, 0.001)
      result = feed_stream(line <> line)

      assert result.completion_state == :completed
      assert result.failure_evidence == []
      assert result.usage.input_tokens == 10
      assert result.usage.output_tokens == 20
      assert result.usage.total_tokens == 30
      assert_in_delta result.usage.cost, 0.001, 1.0e-9
    end

    test "parser duplicate accounting agrees with WorkerEvent.accumulate/2" do
      line = step_finish_line("ses_u", "m1", "stop", 10, 20, 0.001)

      parser_result = feed_stream(line <> line)

      {:ok, first_state, _event} = WorkerEvent.accumulate(nil, line)
      {:duplicate, duplicate_state} = WorkerEvent.accumulate(first_state, line)

      # WorkerEvent documents "Repeated step identities are duplicates and do
      # not add usage again"; the adapter's parser must agree with that
      # harness-neutral accounting contract.
      assert parser_result.usage.input_tokens == duplicate_state.usage.input_tokens
      assert parser_result.usage.output_tokens == duplicate_state.usage.output_tokens
      assert parser_result.usage.total_tokens == duplicate_state.usage.total_tokens
    end
  end

  # ===========================================================================
  # M1-P-N-5: missing, conflicting and stale session ids
  # ===========================================================================

  describe "M1-P-N-5 session identity" do
    test "a terminal completion from a foreign session fails closed" do
      stream = text_line("ses_a") <> step_finish_line("ses_b", "m1", "stop", 10, 20, 0.001)
      result = feed_stream(stream)

      assert result.session_id == "ses_a"
      assert result.completion_state == :failed
      assert result.failure_evidence != []
    end

    test "events without a session id never lock a session" do
      sessionless_text = jsonl(%{"type" => "text", "part" => %{"type" => "text", "text" => "x"}})

      assert %{session_id: nil} = feed_stream(sessionless_text)

      {:ok, state, _event} = WorkerEvent.accumulate(nil, sessionless_text)
      assert state.session_id == nil
    end

    @tag :windows_only
    test "a terminal completion without any session identity is not success", %{
      workspace: workspace
    } do
      # The fixture honours --mock-session-id= (empty value), so every emitted
      # event carries "sessionID":"": no usable session identity at all.
      case run_mock(workspace, "--mock-session-id=") do
        {:ok, result} -> assert is_binary(result.session_id) and result.session_id != ""
        {:error, _reason} -> :ok
      end
    end

    test "later events do not overwrite a locked session id" do
      stream =
        text_line("ses_a") <>
          step_finish_line("ses_a", "m1", "stop", 10, 20, 0.001) <>
          text_line("ses_b")

      result = feed_stream(stream)

      # Ordering of late/stale deliveries is M1-T2 scope; this only pins that a
      # later session id cannot take over the locked one.
      assert result.session_id == "ses_a"
    end
  end

  # ===========================================================================
  # M1-P-N-6: protocol completion vs verified termination vs Human Acceptance
  # ===========================================================================

  describe "M1-P-N-6 protocol completion vs verified termination vs Human Acceptance" do
    test "an OpenCode terminal observation never grants completion authority" do
      event = WorkerEvent.from_opencode(step_finish_line("ses_t", "m1", "stop", 1, 1, 0.0))

      assert event.terminal? == true
      assert event.harness == :opencode

      update = WorkerEvent.to_update(event)
      assert update.successful_completion? == false
    end

    @tag :windows_only
    test "protocol completion without confirmed termination is an error", %{workspace: workspace} do
      authority = Path.join(workspace, "authority-not-a-directory")
      File.write!(authority, "x")

      assert {:error, {:termination_unconfirmed, result}} =
               run_mock(workspace, "Test prompt", authority_root: authority)

      assert result.completion_state == :completed
      assert result.termination.status == :TERMINATION_UNCONFIRMED
      refute Map.has_key?(result, :human_acceptance)
      refute Map.has_key?(result, :accepted)
    end

    @tag :windows_only
    test "a successful worker result carries no Human Acceptance verdict", %{workspace: workspace} do
      assert {:ok, result} = run_mock(workspace, "--mock-mode=success")

      assert result.completion_state == :completed
      refute Map.has_key?(result, :human_acceptance)
      refute Map.has_key?(result, :accepted)
    end

    test "Human Acceptance needs its own workflow state and evidence" do
      assert {:error, {:invalid_issue_state, "In Progress"}} =
               HumanAcceptance.publish("issue-1", %{}, linear_client: acceptance_client("In Progress"))

      assert {:ok, %{ready: false}} =
               HumanAcceptance.publish("issue-1", %{}, linear_client: acceptance_client("In Review"))
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp feed!(state, chunk) do
    Parser.feed(state, chunk)
  rescue
    error ->
      flunk("Parser.feed raised #{inspect(error.__struct__)}: #{Exception.message(error)}")
  end

  defp feed_stream(stream) do
    Parser.new() |> feed!(stream) |> Parser.finish(0) |> Parser.to_result()
  end

  defp assert_parser_fails_closed_for_non_object(line) do
    result = feed_line(line)

    assert result.completion_state == :failed
    assert Enum.any?(result.failure_evidence, &invalid_event_shape?/1)
    refute inspect(result) =~ "CaseClauseError"
    refute inspect(result) =~ "Jason.DecodeError"
    assert match?({:ok, _}, Jason.encode(result))

    result
  end

  defp feed_line(line), do: feed_stream(line <> "\n")

  defp invalid_shape_evidence(evidence) do
    Enum.filter(evidence, &invalid_event_shape?/1)
  end

  defp invalid_event_shape?({:invalid_event_shape, _preview}), do: true
  defp invalid_event_shape?(_other), do: false

  defp jsonl(map), do: Jason.encode!(map) <> "\n"

  defp text_line(session_id) do
    jsonl(%{
      "type" => "text",
      "timestamp" => 1,
      "sessionID" => session_id,
      "part" => %{"type" => "text", "text" => "hi", "messageID" => "msg_0"}
    })
  end

  defp step_finish_line(session_id, message_id, reason, input, output, cost) do
    jsonl(%{
      "type" => "step_finish",
      "timestamp" => 2,
      "sessionID" => session_id,
      "part" => %{
        "type" => "step-finish",
        "id" => "part_" <> message_id,
        "sessionID" => session_id,
        "messageID" => message_id,
        "reason" => reason,
        "cost" => cost,
        "tokens" => %{"input" => input, "output" => output}
      }
    })
  end

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

  defp acceptance_client(state_name) do
    fn query, _variables, _opts ->
      cond do
        String.contains?(query, "SymphonyHumanAcceptanceIssue") ->
          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "id" => "issue-1",
                 "state" => %{"name" => state_name},
                 "comments" => %{
                   "nodes" => [],
                   "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                 }
               }
             }
           }}

        String.contains?(query, "SymphonyCreateHumanAcceptanceComment") ->
          {:ok,
           %{
             "data" => %{
               "commentCreate" => %{"success" => true, "comment" => %{"id" => "comment-1"}}
             }
           }}
      end
    end
  end
end
