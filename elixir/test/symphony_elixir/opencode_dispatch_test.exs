defmodule SymphonyElixir.OpenCodeDispatchTest do
  @moduledoc """
  M1-D focused dispatch-wiring coverage: the production path from an
  explicitly authorized issue to the OpenCode adapter, and the invariants the
  wiring must preserve.

  Covers:
  - the orchestrator's per-dispatch harness decision (authorized OpenCode,
    default Codex, fail-closed configuration states);
  - the AgentRunner OpenCode branch end-to-end against the offline mock
    executable (launch marker with harness metadata, streaming events into
    the WorkerEvent channel, termination evidence before task exit,
    completion requiring containment evidence);
  - failure classification through OpenCode.Failure with the retry envelope
    intact and no silent Codex fallback;
  - launch-marker blocking of reuse/cleanup while an OpenCode launch is live;
  - same-issue concurrency prevention across harnesses.

  No real OpenCode provider, Codex worker, or credential is exercised: every
  launch targets the locally compiled mock through the
  `:opencode_executable` app-env seam.
  """

  use SymphonyElixir.TestSupport

  Code.require_file("../support/mock_opencode.exs", __DIR__)

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.Config.Schema.OpenCode
  alias SymphonyElixir.LaunchMarker
  alias SymphonyElixir.OpenCode.Adapter
  alias SymphonyElixir.TestSupport.MockOpenCode

  @moduletag :opencode_integration

  setup context do
    root = create_temp_fixture_root!("opencode-dispatch")
    state_root = Path.join(root, "state")
    workspace_root = Path.join(root, "workspaces")
    File.mkdir_p!(state_root)
    File.mkdir_p!(workspace_root)

    mock_exe = MockOpenCode.ensure_built!()
    Application.put_env(:symphony_elixir, :opencode_executable, mock_exe)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :opencode_executable)
      remove_temp_fixture_root!(root)
    end)

    {:ok,
     root: root,
     state_root: state_root,
     workspace_root: workspace_root,
     mock_exe: mock_exe,
     issue: test_issue("ISSUE-OD-1", "MIC-OD-1")}
  end

  defp test_issue(id, identifier) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "OpenCode dispatch " <> identifier,
      description: "M1-D dispatch wiring",
      state: "Todo",
      url: "https://example.org/issues/" <> identifier,
      dispatchable: true
    }
  end

  defp pilot(identifier, overrides \\ []) do
    %OpenCode{
      enabled: true,
      provider: "mockprovider",
      model: "mock-model",
      timeout_ms: 15_000,
      allowed_tools: ["read", "glob"],
      allowed_issues: [identifier]
    }
    |> Map.merge(Map.new(overrides))
  end

  defp enable_pilot!(issue, overrides \\ []) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [
          opencode_enabled: true,
          opencode_provider: "mockprovider",
          opencode_model: "mock-model",
          opencode_allowed_tools: ["read", "glob"],
          opencode_allowed_issues: [issue.identifier]
        ],
        overrides
      )
    )
  end

  # The workspace AgentRunner will resolve for the issue, pre-created so the
  # test can seed the mock's control file before the launch. Under a pinned
  # runtime the dispatch's `authority_root` IS the workspace mutation root,
  # mirroring the orchestrator's boot-pinned semantics.
  defp prepare_workspace!(%{state_root: state_root}, %Issue{identifier: identifier}, control \\ []) do
    workspace = Path.join(state_root, SymphonyElixir.Workspace.workspace_key(identifier))
    File.mkdir_p!(workspace)

    unless control == [] do
      File.write!(Path.join(workspace, "opencode-mock-control.txt"), Enum.join(control, "\n"))
    end

    workspace
  end

  defp dispatch_opts(%{state_root: state_root}, pilot_struct, extra \\ []) do
    [
      harness: :opencode,
      opencode: pilot_struct,
      attempt: 1,
      authority_root: state_root
    ] ++ extra
  end

  defp adapter_opts(%{state_root: state_root}, %Issue{} = issue, extra \\ []) do
    [
      provider: "mockprovider",
      model: "mock-model",
      allowed_tools: ["read", "glob"],
      timeout_ms: 15_000,
      issue_id: issue.id,
      attempt_id: 1,
      identifier: issue.identifier,
      authority_root: state_root
    ] ++ extra
  end

  defp drain_worker_mailbox(timeout_ms \\ 200) do
    receive do
      {:codex_worker_update, issue_id, update} -> [{:update, issue_id, update} | drain_worker_mailbox(timeout_ms)]
      {:worker_termination, issue_id, info} -> [{:termination, issue_id, info} | drain_worker_mailbox(timeout_ms)]
      {:worker_runtime_info, issue_id, info} -> [{:runtime_info, issue_id, info} | drain_worker_mailbox(timeout_ms)]
    after
      timeout_ms -> []
    end
  end

  defp wait_until(fun, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition was not met within #{timeout_ms}ms")
      else
        Process.sleep(50)
        wait_until(fun, timeout_ms)
      end
    end
  end

  defp termination_evidence(messages) do
    List.keyfind(messages, :termination, 0) || flunk("no termination evidence reached the recipient")
  end

  # ===========================================================================
  # Orchestrator dispatch-boundary harness selection
  # ===========================================================================

  describe "dispatch harness selection" do
    test "an explicitly authorized issue selects OpenCode with the pinned pilot snapshot", %{issue: issue} do
      enable_pilot!(issue)

      assert {:opencode, snapshot} = Orchestrator.dispatch_harness_for_test(issue)
      assert %OpenCode{} = snapshot
      assert snapshot.provider == "mockprovider"
      assert snapshot.model == "mock-model"
      assert snapshot.allowed_tools == ["read", "glob"]
      assert snapshot.timeout_ms == 900_000
      assert issue.identifier in snapshot.allowed_issues
    end

    test "without an opencode section every issue stays on the Codex default", %{issue: issue} do
      assert {:codex, :opencode_disabled} = Orchestrator.dispatch_harness_for_test(issue)
    end

    test "an enabled pilot without a pinned model fails closed to Codex", %{issue: issue} do
      # The schema rejects the section, so the workflow itself is invalid and
      # the settings store keeps serving the last-known-good configuration.
      # The dispatch decision still fails closed: never OpenCode.
      enable_pilot!(issue, opencode_model: nil)

      assert {:codex, _fail_closed_reason} = Orchestrator.dispatch_harness_for_test(issue)
    end

    test "an issue outside the allowlist fails closed to Codex", %{issue: issue} do
      enable_pilot!(issue, opencode_allowed_issues: ["MIC-OTHER"])

      assert {:codex, :issue_not_authorized} = Orchestrator.dispatch_harness_for_test(issue)
    end

    test "a schema-rejected pilot section fails closed to Codex", %{issue: issue} do
      # Unrestricted tool grants never parse into settings; the store keeps
      # the last-known-good configuration and dispatch stays off OpenCode.
      enable_pilot!(issue, opencode_allowed_tools: ["*"])

      assert {:codex, _fail_closed_reason} = Orchestrator.dispatch_harness_for_test(issue)
    end
  end

  # ===========================================================================
  # AgentRunner OpenCode branch (offline mock executable)
  # ===========================================================================

  describe "authorized OpenCode dispatch through AgentRunner" do
    test "runs the mock worker to completion with events and termination evidence", context do
      %{issue: issue} = context
      prepare_workspace!(context, issue)
      enable_pilot!(issue)

      assert :ok = AgentRunner.run(issue, self(), dispatch_opts(context, pilot(issue.identifier)))

      messages = drain_worker_mailbox()
      assert {:runtime_info, runtime_issue_id, %{workspace_path: workspace}} = List.keyfind(messages, :runtime_info, 0)
      assert runtime_issue_id == issue.id
      assert File.dir?(workspace)

      # Streaming events flowed through the harness-neutral channel, in
      # stream order, marked as OpenCode and never claiming completion: the
      # recipient-side authority for success stays the run result's
      # containment evidence, never the event stream.
      updates = messages |> Enum.filter(&match?({:update, _, _}, &1)) |> Enum.map(fn {:update, _, u} -> u end)
      assert Enum.map(updates, & &1.event) == [:step_start, :tool_use, :step_finish]

      for update <- updates do
        assert update.harness == :opencode
        assert update.successful_completion? == false
      end

      final = List.last(updates)
      assert final.terminal? == true
      assert final.usage_accounting == :cumulative
      assert get_in(final, [:tokenUsage, :total, :totalTokens]) == 300

      # Termination evidence reached the recipient before the task could exit.
      {:termination, termination_issue_id, %{worker_termination: termination}} = termination_evidence(messages)
      assert termination_issue_id == issue.id
      assert %{status: :TERMINATED_CONFIRMED} = termination

      # Completion required containment evidence: the confirmed marker for
      # this issue is gone and the reuse gate re-admits the issue.
      wait_until(fn -> not File.exists?(LaunchMarker.marker_path(issue.id, root: context.state_root)) end)
      assert LaunchMarker.reuse_gate(issue.id, root: context.state_root) == :allowed
    end

    test "records the durable launch marker with harness metadata while the worker runs", context do
      %{issue: issue, state_root: state_root} = context
      # The sleep holds the mock worker alive so the marker is observably on
      # disk while the worker is live.
      prepare_workspace!(context, issue, ["sleep=2500"])
      enable_pilot!(issue)

      runner =
        Task.async(fn ->
          AgentRunner.run(issue, nil, dispatch_opts(context, pilot(issue.identifier)))
        end)

      marker_path = LaunchMarker.marker_path(issue.id, root: state_root)
      wait_until(fn -> File.exists?(marker_path) end)

      assert {:ok, marker} = LaunchMarker.read(issue.id, root: state_root)
      assert marker["issue_id"] == issue.id
      assert marker["identifier"] == issue.identifier
      assert marker["attempt_id"] == 1
      assert marker["worker_identity"]["harness"] == "opencode"
      assert is_binary(marker["worker_identity"]["launch_id"])

      assert :ok = Task.await(runner, 30_000)
    end
  end

  # ===========================================================================
  # Failure classification, timeout, and no-silent-fallback
  # ===========================================================================

  describe "OpenCode worker failures" do
    test "a provider error raises an OpenCode-classified failure with termination evidence", context do
      %{issue: issue} = context
      prepare_workspace!(context, issue, ["mode=error"])
      enable_pilot!(issue)

      error =
        assert_raise AgentRunner.FailureError, fn ->
          AgentRunner.run(issue, self(), dispatch_opts(context, pilot(issue.identifier)))
        end

      # OpenCode.Failure taxonomy (ModelNotFoundError), not the Codex
      # AppServer reason mapper: the structured info carries failure_class.
      assert error.failure_class == :model_unavailable
      assert is_map(error.failure_info)
      assert error.failure_info.failure_class == :model_unavailable

      messages = drain_worker_mailbox()
      {:termination, termination_issue_id, %{worker_termination: termination}} = termination_evidence(messages)
      assert termination_issue_id == issue.id
      assert %{status: :TERMINATED_CONFIRMED} = termination
    end

    test "a timeout is classified runtime_unavailable and fences the launch", context do
      %{issue: issue} = context
      prepare_workspace!(context, issue, ["sleep=9000"])
      enable_pilot!(issue)

      error =
        assert_raise AgentRunner.FailureError, fn ->
          AgentRunner.run(issue, self(), dispatch_opts(context, pilot(issue.identifier, timeout_ms: 1_200)))
        end

      assert error.failure_class == :runtime_unavailable
      assert {:timeout, _result} = error.reason

      messages = drain_worker_mailbox()
      {:termination, _issue_id, %{worker_termination: termination}} = termination_evidence(messages)
      assert %{status: :TERMINATED_CONFIRMED} = termination
    end

    test "a missing pilot snapshot fails closed without launching a worker", context do
      %{issue: issue, state_root: state_root} = context
      prepare_workspace!(context, issue)
      enable_pilot!(issue)

      error =
        assert_raise AgentRunner.FailureError, fn ->
          AgentRunner.run(issue, self(), dispatch_opts(context, nil))
        end

      assert {:opencode_launch_settings_invalid, nil} = error.reason

      # Contained launch that conclusively never started: the pre-launch
      # NEVER_STARTED expectation is published and no marker is stranded.
      messages = drain_worker_mailbox()
      {:termination, _issue_id, %{termination_expectation: :NEVER_STARTED}} = termination_evidence(messages)
      refute File.exists?(LaunchMarker.marker_path(issue.id, root: state_root))
    end

    test "every streamed update during an OpenCode attempt stays harness-marked", context do
      %{issue: issue} = context
      prepare_workspace!(context, issue, ["mode=multi-step"])
      enable_pilot!(issue)

      assert :ok = AgentRunner.run(issue, self(), dispatch_opts(context, pilot(issue.identifier)))

      updates =
        drain_worker_mailbox()
        |> Enum.filter(&match?({:update, _, _}, &1))
        |> Enum.map(fn {:update, _, u} -> u end)

      assert updates != []

      for update <- updates do
        assert update.harness == :opencode
      end
    end
  end

  # ===========================================================================
  # Launch-marker fencing and cross-harness concurrency
  # ===========================================================================

  describe "launch-marker fencing across harnesses" do
    test "a live OpenCode launch marker blocks reuse and cleanup until confirmed", context do
      %{issue: issue, state_root: state_root} = context
      workspace = prepare_workspace!(context, issue, ["sleep=15000"])
      enable_pilot!(issue)

      assert {:ok, session} = Adapter.start_session(workspace, "prompt", adapter_opts(context, issue))

      marker_path = LaunchMarker.marker_path(issue.id, root: state_root)
      wait_until(fn -> File.exists?(marker_path) end)

      # While the contained OpenCode worker is live, both fences fail closed
      # for this issue — for any harness.
      assert {:blocked, _reuse_reason} = LaunchMarker.reuse_gate(issue.id, root: state_root)
      assert {:blocked, _cleanup_reason} = LaunchMarker.cleanup_gate(issue.id, root: state_root)

      assert %{status: :TERMINATED_CONFIRMED} = Adapter.stop_session(session)
      wait_until(fn -> not File.exists?(marker_path) end)
      assert LaunchMarker.reuse_gate(issue.id, root: state_root) == :allowed
    end

    test "an interrupted OpenCode run fails closed but clean termination re-admits dispatch", context do
      %{issue: issue, state_root: state_root} = context
      prepare_workspace!(context, issue, ["mode=interrupted"])
      enable_pilot!(issue)

      error =
        assert_raise AgentRunner.FailureError, fn ->
          AgentRunner.run(issue, self(), dispatch_opts(context, pilot(issue.identifier)))
        end

      # The interrupted child exited 130 with an incomplete stream: a
      # process-exit failure in the OpenCode taxonomy, retried inside the
      # same envelope. The tree still drained with a positive receipt.
      assert error.failure_class == :transient_worker_failure
      assert {{:process_exit, 130}, _result} = error.reason

      messages = drain_worker_mailbox()
      {:termination, _issue_id, %{worker_termination: termination}} = termination_evidence(messages)
      assert %{status: :TERMINATED_CONFIRMED} = termination

      wait_until(fn -> not File.exists?(LaunchMarker.marker_path(issue.id, root: state_root)) end)
      assert LaunchMarker.reuse_gate(issue.id, root: state_root) == :allowed
    end

    test "a latched Codex fallback route never replaces a selected OpenCode harness", %{issue: issue} do
      enable_pilot!(issue)

      # A failure sequence that latched the Codex fallback route...
      state = %Orchestrator.State{}
      state = put_in(state.retry_history[issue.id], %{route: :fallback, primary_failure_count: 2})
      assert Orchestrator.next_dispatch_route_for_test(state, issue.id) == :fallback

      # ...still dispatches the authorized issue onto OpenCode: the harness
      # decision is not a route materialization and cannot be silently
      # degraded to Codex by the retry/fallback machinery.
      assert {:opencode, _snapshot} = Orchestrator.dispatch_harness_for_test(issue)
    end

    test "an issue with a running OpenCode worker is not dispatched again", %{issue: issue} do
      state = %Orchestrator.State{}

      running =
        put_in(state.running[issue.id], %{
          pid: spawn(fn -> Process.sleep(:infinity) end),
          ref: make_ref(),
          identifier: issue.identifier,
          issue: issue,
          harness: :opencode,
          termination_expectation: :MANAGED_CONFIRMATION_REQUIRED
        })

      # Same guard as Codex: the running map is keyed by issue, independent
      # of harness, so no second worker of ANY harness may start.
      refute Orchestrator.should_dispatch_issue_for_test(issue, running)

      claimed_only = %{state | claimed: MapSet.put(state.claimed, issue.id)}
      refute Orchestrator.should_dispatch_issue_for_test(issue, claimed_only)
    end
  end
end
