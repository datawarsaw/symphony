defmodule SymphonyElixir.OpenCodeCompletionPolicyTest do
  @moduledoc """
  M1-SEM-F / M1-TERM-F: Comprehensive policy tests separating terminal protocol
  observation, tool failures, and authoritative worker success.

  Contract under test:
  1. Protocol completion (completion_state: :completed) reflects wire protocol completion
     and is preserved even when tool failures occurred during previous steps.
  2. Tool failures are recorded separately in tool_failures, and remain disqualifying
     for authoritative worker success by default. (M1-COMPLETION-POLICY / PILOT-LIVE-R4)
     A tool failure that is an OpenCode permission-rule rejection whose deny held — the
     exact R4 containment signature — is recovered containment evidence: it never
     disqualifies an otherwise-clean completed run. Generic permission wording,
     including ordinary EACCES/EPERM execution errors, is not containment evidence
     and fails closed.
  3. Fatal failure_evidence is preserved for malformed data, top-level errors, and
     incomplete streams.
  4. Terminal reasons include stop, unknown, and other; tool-calls is intermediate.
     (M1-TERM-F) Only "stop" is eligible for clean worker success; "unknown" and
     "other" remain observational terminal completions that never authorize success.
  5. finish_reason is recorded explicitly across all steps.
  6. length, content-filter, unknown, and other are terminal observations but NOT
     clean success.
  7. Adapter success strictly requires: exit 0, eligible protocol completion
     (explicit "stop"), no fatal evidence, no non-denial tool failures (every recorded
     tool failure must be a recovered OpenCode permission-rule denial), and
     TERMINATED_CONFIRMED.
  8. On timeout, a failed result with nonempty evidence is returned even if a terminal
     event was observed before the hang.
  9. Session integrity and Human Acceptance boundaries are strictly preserved.
  """

  use SymphonyElixir.TestSupport

  Code.require_file("../support/mock_opencode.exs", __DIR__)

  alias SymphonyElixir.OpenCode
  alias SymphonyElixir.OpenCode.{Failure, Parser}
  alias SymphonyElixir.TestSupport.MockOpenCode
  alias SymphonyElixir.WorkerContainment
  alias SymphonyElixir.WorkerEvent

  # Verbatim OpenCode permission-rule rejection from the PILOT-LIVE-R4 runtime
  # log (rules list genericized to workspace-shaped paths; the load-bearing
  # phrase is byte-identical). This is the external_directory containment deny
  # that held while the model adapted and completed the task, and the only
  # error text the completion policy recognizes as a recovered containment
  # denial (M2-COMPLETION-POLICY-TIGHTENING: generic permission wording,
  # including ordinary EACCES/EPERM execution errors, fails closed).
  @r4_denial "The user has specified a rule which prevents you from using this specific tool call. Here are some of the relevant rules [{\"permission\":\"external_directory\",\"action\":\"deny\",\"pattern\":\"*\"},{\"permission\":\"external_directory\",\"pattern\":\"C:\\\\workspace\\\\allowed\\\\*\",\"action\":\"allow\"}]"

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "m1sem-workspace-#{System.unique_integer([:positive])}")

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
  # 1. Reason Matrix: Parser protocol observations & Adapter eligibility
  # ===========================================================================

  describe "1. Reason Matrix: Parser & Adapter completion" do
    test "terminal reason 'stop' completes protocol and is eligible for clean success" do
      stream =
        step_start_line("ses_1", "msg_1") <>
          step_finish_line("ses_1", "msg_1", "stop", 10, 20)

      result = feed_stream(stream)
      assert result.completion_state == :completed
      assert result.finish_reason == "stop"
      assert result.failure_evidence == []
      assert result.tool_failures == []
      assert Parser.terminal_finish_reason?("stop") == true
      assert Parser.eligible_finish_reason?("stop") == true
    end

    test "terminal reason 'unknown' completes protocol observation but is NOT eligible for clean success (M1-TERM-F)" do
      stream =
        step_start_line("ses_1", "msg_1") <>
          step_finish_line("ses_1", "msg_1", "unknown", 10, 20)

      result = feed_stream(stream)
      assert result.completion_state == :completed
      assert result.finish_reason == "unknown"
      assert result.failure_evidence == []
      assert result.tool_failures == []
      assert Parser.terminal_finish_reason?("unknown") == true
      assert Parser.eligible_finish_reason?("unknown") == false
    end

    test "terminal reason 'other' completes protocol observation but is NOT eligible for clean success (M1-TERM-F / Audit A1)" do
      stream =
        step_start_line("ses_1", "msg_1") <>
          step_finish_line("ses_1", "msg_1", "other", 10, 20)

      result = feed_stream(stream)
      assert result.completion_state == :completed
      assert result.finish_reason == "other"
      assert result.failure_evidence == []
      assert result.tool_failures == []
      assert Parser.terminal_finish_reason?("other") == true
      assert Parser.eligible_finish_reason?("other") == false
    end

    test "terminal reason 'length' completes protocol observation but is NOT clean success" do
      stream =
        step_start_line("ses_1", "msg_1") <>
          step_finish_line("ses_1", "msg_1", "length", 10, 20)

      result = feed_stream(stream)
      assert result.completion_state == :completed
      assert result.finish_reason == "length"
      assert result.failure_evidence == []
      assert result.tool_failures == []
      assert Parser.terminal_finish_reason?("length") == true
      assert Parser.eligible_finish_reason?("length") == false
    end

    test "terminal reason 'content-filter' completes protocol observation but is NOT clean success" do
      stream =
        step_start_line("ses_1", "msg_1") <>
          step_finish_line("ses_1", "msg_1", "content-filter", 10, 20)

      result = feed_stream(stream)
      assert result.completion_state == :completed
      assert result.finish_reason == "content-filter"
      assert result.failure_evidence == []
      assert result.tool_failures == []
      assert Parser.terminal_finish_reason?("content-filter") == true
      assert Parser.eligible_finish_reason?("content-filter") == false
    end

    test "intermediate reason 'tool-calls' keeps state :running and fails closed if uncompleted" do
      stream =
        step_start_line("ses_1", "msg_1") <>
          step_finish_line("ses_1", "msg_1", "tool-calls", 10, 20)

      state = Parser.new() |> Parser.feed(stream)
      assert state.completion_state == :running
      assert state.finish_reason == "tool-calls"

      # Finishing with exit 0 while stream is still running fails closed
      result = state |> Parser.finish(0) |> Parser.to_result()
      assert result.completion_state == :failed
      assert {:incomplete_stream, :missing_completion_event} in result.failure_evidence
      assert Parser.terminal_finish_reason?("tool-calls") == false
      assert Parser.eligible_finish_reason?("tool-calls") == false
    end

    test "error reason 'error' does not grant terminal completion and fails closed" do
      stream =
        step_start_line("ses_1", "msg_1") <>
          step_finish_line("ses_1", "msg_1", "error", 10, 20)

      result = feed_stream(stream)
      assert result.completion_state == :failed
      assert result.finish_reason == "error"
      assert {:incomplete_stream, :missing_completion_event} in result.failure_evidence
      assert Parser.terminal_finish_reason?("error") == false
      assert Parser.eligible_finish_reason?("error") == false
    end
  end

  # ===========================================================================
  # 2. Tool-Error Recovery: Protocol Completion vs Worker Success Separation
  # ===========================================================================

  describe "2. Tool-Error Recovery: Protocol Completion vs Worker Success Separation" do
    test "recovered protocol turn completes at protocol level while recording tool failures separately" do
      # Step 1: tool error
      # Step 2: model recovers and finishes with 'stop'
      stream =
        step_start_line("ses_rec", "msg_1") <>
          tool_use_error_line("ses_rec", "msg_1", "read_file", "c1", "ENOENT: no such file") <>
          step_finish_line("ses_rec", "msg_1", "tool-calls", 10, 20) <>
          step_start_line("ses_rec", "msg_2") <>
          text_line("ses_rec", "Recovered from missing file") <>
          step_finish_line("ses_rec", "msg_2", "stop", 30, 40)

      result = feed_stream(stream)

      # 1. Protocol completion is preserved
      assert result.completion_state == :completed
      assert result.finish_reason == "stop"

      # 2. Fatal failure evidence is clean (stream was syntactically valid and terminal)
      assert result.failure_evidence == []

      # 3. Tool failure is recorded separately
      assert length(result.tool_failures) == 1
      assert [{:tool_error, "read_file", err}] = result.tool_failures
      assert err =~ "ENOENT"

      # 4. Tool events are preserved
      assert length(result.tool_events) == 1
      assert hd(result.tool_events).status == "error"
    end

    @tag :windows_only
    test "recovered containment denial under adapter is authoritative success with the denial preserved for audit (PILOT-LIVE-R4)", %{
      workspace: workspace
    } do
      # --mock-mode=tool-error emits the OpenCode permission-rule rejection
      # (the R4 external_directory deny), followed by step_finish 'stop' and
      # exit 0 — the R4 shape: the deny held and the model adapted, so the
      # worker completed the task.
      outcome = run_mock(workspace, "--mock-mode=tool-error")

      assert {:ok, result} = outcome

      # Protocol completion and clean evidence are preserved.
      assert result.completion_state == :completed
      assert result.finish_reason == "stop"
      assert result.exit_code == 0
      assert result.failure_evidence == []

      # The denial is still recorded as observational evidence — never erased.
      assert [{:tool_error, "read", @r4_denial}] = result.tool_failures

      if WorkerContainment.containment_active?() do
        assert result.termination.status == :TERMINATED_CONFIRMED
      end
    end

    @tag :windows_only
    test "a non-denial tool error still blocks adapter success even when the turn ends clean", %{
      workspace: workspace
    } do
      err = "ENOENT: no such file or directory, open 'required.txt'"

      outcome =
        run_parts(
          workspace,
          [
            tool_use_error_line("ses_nondenial", "msg_1", "read", "c1", err) <>
              step_finish_line("ses_nondenial", "msg_1", "stop", 10, 20)
          ]
        )

      assert {:error, {{:tool_error, "read", ^err}, result}} = outcome

      assert result.completion_state == :completed
      assert result.finish_reason == "stop"
      assert result.exit_code == 0
      assert result.failure_evidence == []
      assert [{:tool_error, "read", ^err}] = result.tool_failures
      assert result.failure_info.failure_class == :persistent_worker_failure
      assert result.failure_info.message =~ "ENOENT"
    end
  end

  # ===========================================================================
  # 3. Fatal Evidence Preservation: Malformed Data, Top-level Errors & Exit Codes
  # ===========================================================================

  describe "3. Fatal Evidence Preservation" do
    test "malformed non-JSON lines latch completion_state: :failed and cannot be rescued by later terminal finish" do
      stream =
        "garbage line not json\n" <>
          step_start_line("ses_err", "msg_1") <>
          step_finish_line("ses_err", "msg_1", "stop", 10, 20)

      result = feed_stream(stream)
      assert result.completion_state == :failed
      assert length(result.failure_evidence) == 1
      assert [{:malformed_json_line, line, _detail}] = result.failure_evidence
      assert line =~ "garbage"
    end

    test "top-level error event latches completion_state: :failed" do
      err_event =
        jsonl(%{
          "type" => "error",
          "sessionID" => "ses_err",
          "error" => %{"name" => "ModelNotFoundError", "data" => %{"message" => "Model unavailable"}}
        })

      result = feed_stream(err_event)
      assert result.completion_state == :failed

      assert Enum.any?(result.failure_evidence, fn
               {:error_event, err} -> err["name"] == "ModelNotFoundError"
               _ -> false
             end)
    end

    test "non-zero process exit latches completion_state: :failed even after terminal finish" do
      stream =
        step_start_line("ses_x", "msg_1") <>
          step_finish_line("ses_x", "msg_1", "stop", 10, 20)

      state = Parser.new() |> Parser.feed(stream)
      assert state.completion_state == :completed

      # finish with exit code 1
      result = state |> Parser.finish(1) |> Parser.to_result()
      assert result.completion_state == :failed
      assert {:process_exit, 1} in result.failure_evidence
    end
  end

  # ===========================================================================
  # 4. Timeout-after-terminal: Bounded Timeout Semantics
  # ===========================================================================

  describe "4. Timeout after terminal step_finish" do
    test "Parser.finish with :timeout sets :failed and adds nonempty timeout evidence" do
      stream =
        step_start_line("ses_t", "msg_1") <>
          step_finish_line("ses_t", "msg_1", "stop", 10, 20)

      state = Parser.new() |> Parser.feed(stream)
      assert state.completion_state == :completed

      result = state |> Parser.finish(:timeout) |> Parser.to_result()
      assert result.completion_state == :failed
      assert result.failure_evidence == [{:timeout, :process_timeout}]
    end

    @tag :windows_only
    test "worker that hangs after terminal finish returns {:error, {:timeout, result}} with nonempty failure evidence", %{
      workspace: workspace
    } do
      outcome = run_mock(workspace, "--mock-mode=terminal-then-hang", timeout_ms: 1_500)

      assert {:error, {:timeout, result}} = outcome
      assert result.exit_code == 253
      assert result.completion_state == :failed
      assert result.failure_evidence != []
      assert result.failure_info.failure_class == :runtime_unavailable

      if WorkerContainment.containment_active?() do
        assert result.termination.status == :TERMINATED_CONFIRMED
      end

      # Invariant check: run MUST NOT look like a clean success
      refute result.completion_state == :completed and result.failure_evidence == []
    end
  end

  # ===========================================================================
  # 5. Adapter Authoritative Success: Full 5-Condition Gate
  # ===========================================================================

  describe "5. Adapter Authoritative Success Gates" do
    @tag :windows_only
    test "clean execution with finish reason 'stop' succeeds with {:ok, result}", %{
      workspace: workspace
    } do
      assert {:ok, result} = run_mock(workspace, "--mock-mode=single-turn")

      assert result.exit_code == 0
      assert result.completion_state == :completed
      assert result.finish_reason == "stop"
      assert result.failure_evidence == []
      assert result.tool_failures == []
    end

    @tag :windows_only
    test "execution with finish reason 'other' is blocked by adapter with :transient_worker_failure (M1-TERM-F)", %{
      workspace: workspace
    } do
      outcome = run_mock(workspace, "--mock-mode=reason-other")

      assert {:error, {{:terminal_reason, "other"}, result}} = outcome

      # Protocol observation is preserved even though success is denied.
      assert result.exit_code == 0
      assert result.completion_state == :completed
      assert result.finish_reason == "other"
      assert result.failure_evidence == []
      assert result.tool_failures == []
      assert result.failure_info.failure_class == :transient_worker_failure
      assert result.failure_info.code == "OTHER"
    end

    @tag :windows_only
    test "execution with finish reason 'length' is blocked by adapter with :transient_worker_failure", %{
      workspace: workspace
    } do
      outcome = run_mock(workspace, "--mock-mode=reason-length")

      assert {:error, {{:terminal_reason, "length"}, result}} = outcome
      assert result.exit_code == 0
      assert result.completion_state == :completed
      assert result.finish_reason == "length"
      assert result.failure_info.failure_class == :transient_worker_failure
      assert result.failure_info.code == "LENGTH"
    end

    @tag :windows_only
    test "execution with finish reason 'content-filter' is blocked by adapter with :persistent_worker_failure", %{
      workspace: workspace
    } do
      outcome = run_mock(workspace, "--mock-mode=reason-content-filter")

      assert {:error, {{:terminal_reason, "content-filter"}, result}} = outcome
      assert result.exit_code == 0
      assert result.completion_state == :completed
      assert result.finish_reason == "content-filter"
      assert result.failure_info.failure_class == :persistent_worker_failure
      assert result.failure_info.code == "CONTENT-FILTER"
    end
  end

  # ===========================================================================
  # 6. Failure Classification: Status codes, Provider Auth & Finish Reasons
  # ===========================================================================

  describe "6. Failure Classification additions" do
    test "ProviderAuthError maps to :auth_unavailable (Audit A5 / Gate 5)" do
      err = %{
        "name" => "ProviderAuthError",
        "data" => %{"providerID" => "anthropic", "message" => "Key rejected"}
      }

      assert Failure.classify(err) == :auth_unavailable
    end

    test "APIError with statusCode 403 maps to :persistent_worker_failure (Audit A5 / Gate 4)" do
      err = %{
        "name" => "APIError",
        "data" => %{
          "statusCode" => 403,
          "isRetryable" => false,
          "message" => "Forbidden tier access"
        }
      }

      assert Failure.classify(err) == :persistent_worker_failure
    end

    test "terminal and finish reasons classify appropriately" do
      assert Failure.classify({:terminal_reason, "content-filter"}) == :persistent_worker_failure
      assert Failure.classify({:terminal_reason, "length"}) == :transient_worker_failure
      assert Failure.classify({:finish_reason, "content-filter"}) == :persistent_worker_failure
      assert Failure.classify({:finish_reason, "length"}) == :transient_worker_failure
    end
  end

  # ===========================================================================
  # 7. WorkerEvent Contract Alignment
  # ===========================================================================

  describe "7. WorkerEvent reasons alignment" do
    test "WorkerEvent.from_opencode recognizes all terminal reasons" do
      for reason <- ["stop", "unknown", "other", "length", "content-filter"] do
        event = step_finish_worker_event(reason)
        assert event.event == :step_finish
        assert event.terminal? == true
        assert event.metadata.finish_reason == reason
        assert event.metadata.successful_completion? == false
      end
    end

    test "WorkerEvent.from_opencode treats intermediate and error reasons as non-terminal" do
      for reason <- ["tool-calls", "error"] do
        event = step_finish_worker_event(reason)
        assert event.event == :step_finish
        assert event.terminal? == false
        assert event.metadata.finish_reason == reason
        assert event.metadata.successful_completion? == false
      end

      nil_event = step_finish_worker_event(nil)
      assert nil_event.terminal? == false
      assert nil_event.metadata.successful_completion? == false
    end
  end

  # ===========================================================================
  # 8. Recovered Containment Denial vs Terminal Failure (M1-COMPLETION-POLICY /
  #    PILOT-LIVE-R4)
  # ===========================================================================

  describe "8. Recovered containment denial vs terminal failure (PILOT-LIVE-R4)" do
    test "parser records the R4 external_directory denial separately while protocol completion stays clean" do
      r4_denial = @r4_denial

      stream =
        step_start_line("ses_r4", "msg_1") <>
          tool_use_error_line("ses_r4", "msg_1", "read", "call_r4", r4_denial) <>
          step_finish_line("ses_r4", "msg_1", "stop", 10, 20)

      result = feed_stream(stream)

      assert result.completion_state == :completed
      assert result.finish_reason == "stop"
      assert result.failure_evidence == []
      assert [{:tool_error, "read", ^r4_denial}] = result.tool_failures
    end

    test "permission_denial? recognizes the exact R4 rule-rejection signature and fails closed on everything else" do
      r4_denial = @r4_denial

      assert Failure.permission_denial?({:tool_error, "read", r4_denial}) == true

      # Ordinary execution errors whose text carries generic permission
      # wording are tool faults, not containment evidence.
      refute Failure.permission_denial?({:tool_error, "bash", "bash: /etc/shadow: Permission denied"})
      refute Failure.permission_denial?({:tool_error, "read", "EACCES: permission denied, open 'out.txt'"})
      refute Failure.permission_denial?({:tool_error, "write", "EPERM: operation not permitted, write 'out.txt'"})

      # Non-denial tool failures containing permission-related words.
      refute Failure.permission_denial?({:tool_error, "bash", "tool permission check failed: script exited 3"})
      refute Failure.permission_denial?({:tool_error, "bash", "user is not permitted to run sudo"})
      refute Failure.permission_denial?({:tool_error, "bash", "permission auto-rejected by policy"})

      # Missing, blank, or non-text evidence fails closed — even when a
      # non-text payload contains the signature phrase.
      refute Failure.permission_denial?({:tool_error, "write", nil})
      refute Failure.permission_denial?({:tool_error, "read", ""})
      refute Failure.permission_denial?({:tool_error, "read", %{"message" => @r4_denial}})
      refute Failure.permission_denial?(nil)
    end

    test "an unresolved denial still classifies persistent_worker_failure — classification never sees completion state" do
      r4_denial = @r4_denial

      assert Failure.classify({:tool_error, "read", r4_denial}) == :persistent_worker_failure
      assert Failure.classify({:tool_error, "read", "permission denied"}) == :persistent_worker_failure
      assert Failure.classify({:tool_error, "read", "ENOENT: no such file or directory"}) == :persistent_worker_failure
    end

    @tag :windows_only
    test "R4 signature end-to-end: external_directory denial recovered by a clean stop is adapter success", %{
      workspace: workspace
    } do
      r4_denial = @r4_denial

      # Two-step shape from the R4 timeline: the denied read concludes an
      # intermediate step, the model adapts, and the turn ends with "stop".
      stream =
        step_start_line("ses_r4_adapter", "msg_1") <>
          tool_use_error_line("ses_r4_adapter", "msg_1", "read", "call_r4", r4_denial) <>
          step_finish_line("ses_r4_adapter", "msg_1", "tool-calls", 10, 20) <>
          step_start_line("ses_r4_adapter", "msg_2") <>
          text_line("ses_r4_adapter", "Recovered; wrote the artifact inside the workspace") <>
          step_finish_line("ses_r4_adapter", "msg_2", "stop", 30, 40)

      assert {:ok, result} = run_parts(workspace, [stream])

      assert result.exit_code == 0
      assert result.completion_state == :completed
      assert result.finish_reason == "stop"
      assert result.failure_evidence == []
      assert [{:tool_error, "read", ^r4_denial}] = result.tool_failures

      if WorkerContainment.containment_active?() do
        assert result.termination.status == :TERMINATED_CONFIRMED
      end
    end

    @tag :windows_only
    test "denial with a non-eligible finish reason is not a recovered success and fails closed", %{
      workspace: workspace
    } do
      r4_denial = @r4_denial

      stream =
        step_start_line("ses_r4_unk", "msg_1") <>
          tool_use_error_line("ses_r4_unk", "msg_1", "read", "call_r4u", r4_denial) <>
          step_finish_line("ses_r4_unk", "msg_1", "unknown", 10, 20)

      # The turn never reached an eligible "stop", so recovery never happened.
      # Recorded tool failures keep their pre-existing precedence as the
      # surfaced reason and the run stays a persistent failure (fail closed).
      assert {:error, {{:tool_error, "read", ^r4_denial}, result}} = run_parts(workspace, [stream])
      assert result.failure_info.failure_class == :persistent_worker_failure
      assert [{:tool_error, "read", ^r4_denial}] = result.tool_failures
    end

    @tag :windows_only
    test "denial with a nonzero exit is not a recovered success — an unsuccessful task stays a failure", %{
      workspace: workspace
    } do
      r4_denial = @r4_denial

      stream =
        step_start_line("ses_r4_exit", "msg_1") <>
          tool_use_error_line("ses_r4_exit", "msg_1", "read", "call_r4x", r4_denial) <>
          step_finish_line("ses_r4_exit", "msg_1", "stop", 10, 20)

      assert {:error, {{:tool_error, "read", ^r4_denial}, result}} =
               run_parts(workspace, [stream], exit_code: 1)

      assert result.exit_code == 1
      assert result.completion_state == :failed
      assert {:process_exit, 1} in result.failure_evidence
      assert result.failure_info.failure_class == :persistent_worker_failure
    end

    @tag :windows_only
    test "one genuine tool failure disqualifies the run even alongside recovered denials", %{
      workspace: workspace
    } do
      r4_denial = @r4_denial
      write_err = "ENOENT: no such file or directory, open 'out.txt'"

      stream =
        step_start_line("ses_mix", "msg_1") <>
          tool_use_error_line("ses_mix", "msg_1", "read", "c1", r4_denial) <>
          tool_use_error_line("ses_mix", "msg_1", "write", "c2", write_err) <>
          step_finish_line("ses_mix", "msg_1", "stop", 10, 20)

      # The recorded tool failures keep their pre-existing precedence: the
      # most recent one surfaces as the reason and the run stays a failure —
      # recovered denials never whitewash a run with a genuine tool failure.
      assert {:error, {{:tool_error, "write", ^write_err}, result}} = run_parts(workspace, [stream])
      assert result.failure_info.failure_class == :persistent_worker_failure
      assert length(result.tool_failures) == 2
    end

    @tag :windows_only
    test "an ordinary EACCES execution error is not a recovered containment denial — a clean stop does not rescue it", %{
      workspace: workspace
    } do
      eacces = "EACCES: permission denied, open 'C:\\workspace\\allowed\\out.txt'"

      stream =
        step_start_line("ses_eacces", "msg_1") <>
          tool_use_error_line("ses_eacces", "msg_1", "read", "call_ea", eacces) <>
          step_finish_line("ses_eacces", "msg_1", "stop", 10, 20)

      # M2 policy tightening regression pin: generic "permission denied" text
      # is not rule-rejection evidence, so the otherwise-clean stop cannot
      # turn this execution error into a recovered success.
      assert {:error, {{:tool_error, "read", ^eacces}, result}} = run_parts(workspace, [stream])
      assert result.completion_state == :completed
      assert result.finish_reason == "stop"
      assert result.failure_info.failure_class == :persistent_worker_failure
      assert [{:tool_error, "read", ^eacces}] = result.tool_failures
    end

    @tag :windows_only
    test "a recovered denial with an incomplete stream never becomes a success", %{
      workspace: workspace
    } do
      r4_denial = @r4_denial

      stream =
        step_start_line("ses_r4_partial", "msg_1") <>
          tool_use_error_line("ses_r4_partial", "msg_1", "read", "call_r4p", r4_denial)

      # No terminal step_finish ever arrives, so the run is incomplete and the
      # surfaced reason is the missing completion event — fail closed.
      assert {:error, {{:incomplete_stream, :missing_completion_event}, result}} =
               run_parts(workspace, [stream])

      assert result.completion_state == :failed
      assert [{:tool_error, "read", ^r4_denial}] = result.tool_failures
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

  # Drives the mock in emit-parts mode: every chunk becomes one flushed stdout
  # write of byte-exact JSONL, so adapter-level tests control the stream the
  # parser sees (same mechanism as the event-ordering regression suite).
  defp run_parts(workspace, chunks, opts \\ []) do
    parts_dir = Path.join(workspace, "parts-#{System.unique_integer([:positive])}")
    File.mkdir_p!(parts_dir)

    chunks
    |> Enum.with_index(1)
    |> Enum.each(fn {data, idx} ->
      name = String.pad_leading(Integer.to_string(idx), 2, "0") <> ".part"
      File.write!(Path.join(parts_dir, name), data)
    end)

    File.write!(
      Path.join(workspace, "opencode-mock-control.txt"),
      "mode=emit-parts\nparts_dir=#{parts_dir}\nexit_code=#{Keyword.get(opts, :exit_code, 0)}\n"
    )

    run_mock(workspace, "emit-parts", Keyword.delete(opts, :exit_code))
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

  defp tool_use_error_line(session_id, message_id, tool, call_id, err) do
    jsonl(%{
      "type" => "tool_use",
      "timestamp" => 4,
      "sessionID" => session_id,
      "part" => %{
        "type" => "tool",
        "id" => "part_tool_" <> call_id,
        "sessionID" => session_id,
        "messageID" => message_id,
        "tool" => tool,
        "callID" => call_id,
        "state" => %{"status" => "error", "error" => err}
      }
    })
  end

  defp step_finish_worker_event(reason) do
    payload = %{
      "type" => "step_finish",
      "timestamp" => 1_728_570_000,
      "sessionID" => "ses_we_1",
      "part" => %{
        "type" => "step-finish",
        "reason" => reason,
        "tokens" => %{"input" => 10, "output" => 20}
      }
    }

    WorkerEvent.from_opencode(payload)
  end
end
