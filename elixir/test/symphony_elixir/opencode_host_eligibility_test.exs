defmodule SymphonyElixir.OpenCodeHostEligibilityTest do
  @moduledoc """
  M1-H-F focused coverage: OpenCode dispatch must never silently launch a
  local worker when Symphony selects a remote SSH worker host.

  The OpenCode adapter has no SSH execution path, so host eligibility is
  enforced fail-closed at three layers:

  - the orchestrator dispatch boundary parks an OpenCode-authorized dispatch
    whose selected worker host is remote — no spawn, no workspace mutation,
    no retry timer, and never a silent Codex fallback;
  - AgentRunner refuses an OpenCode dispatch carrying a remote host before
    workspace creation or any adapter call, classifying through the OpenCode
    taxonomy so the attempt never degrades into a Codex worker;
  - the adapter itself refuses a launch naming a remote host before any
    directory, config, marker, or process exists.

  The authorized local Windows containment path and Codex SSH dispatch
  behavior are asserted unchanged. No real provider, Codex worker, or
  credential is exercised: OpenCode launches target the locally compiled
  mock through the `:opencode_executable` app-env seam, and SSH traffic is
  intercepted by the FakeSSH fixture.
  """

  use SymphonyElixir.TestSupport

  Code.require_file("../support/mock_opencode.exs", __DIR__)

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.Config.Schema.OpenCode
  alias SymphonyElixir.LaunchMarker
  alias SymphonyElixir.OpenCode.Adapter
  alias SymphonyElixir.TestSupport.FakeSSH
  alias SymphonyElixir.TestSupport.MockOpenCode
  alias SymphonyElixir.Wake.{Ledger, Store}
  alias SymphonyElixir.WorkerContainment

  @moduletag :opencode_integration

  @remote_host "worker-01:2200"

  setup do
    root = create_temp_fixture_root!("opencode-host-eligibility")
    state_root = Path.join(root, "state")
    workspace_root = Path.join(root, "workspaces")
    File.mkdir_p!(state_root)
    File.mkdir_p!(workspace_root)

    mock_exe = MockOpenCode.ensure_built!()
    Application.put_env(:symphony_elixir, :opencode_executable, mock_exe)

    # PILOT-AUTH-F: the pinned pilot provider is a mapped allowlist identity
    # ("anthropic"); the synthetic placeholder credential satisfies the
    # production credential presence preflight offline.
    saved_credential = System.get_env("ANTHROPIC_API_KEY")
    System.put_env("ANTHROPIC_API_KEY", "sk-ant-synthetic-test-placeholder")

    on_exit(fn ->
      restore_env("ANTHROPIC_API_KEY", saved_credential)
      Application.delete_env(:symphony_elixir, :opencode_executable)
      remove_temp_fixture_root!(root)
    end)

    {:ok, root: root, state_root: state_root, workspace_root: workspace_root, mock_exe: mock_exe, issue: test_issue("ISSUE-HE-9", "MIC-HE-9")}
  end

  # ===========================================================================
  # Orchestrator dispatch boundary
  # ===========================================================================

  describe "orchestrator dispatch boundary" do
    test "an authorized OpenCode dispatch on a selected SSH host parks fail-closed before any spawn" do
      fixture = dispatch_fixture!("ssh-park", ssh_pilot_workflow())
      issue = active_issue("issue-he-1", "MIC-HE-1")

      {:ok, sup} = start_test_task_supervisor("ssh-park")
      state = Orchestrator.dispatch_issue_for_test(runtime_state(sup), issue)

      # Refused at the boundary: parked with claim, no retry timer, no task
      # spawned at all — so no local process, adapter launch, or workspace
      # mutation can happen under the remote host's identity slot.
      parked = Map.get(state.parked, issue.id) || flunk("issue was not parked")
      assert parked.stop_reason == :opencode_remote_host_ineligible
      assert parked.failure_class == "PERSISTENT_WORKER_FAILURE"
      assert parked.worker_host == @remote_host
      assert parked.error =~ "not eligible on remote worker host"

      assert MapSet.member?(state.claimed, issue.id)
      refute Map.has_key?(state.running, issue.id)
      assert state.retry_attempts == %{}
      assert Task.Supervisor.children(sup) == []

      # No workspace was created and no launch marker was stranded.
      refute File.exists?(Path.join(fixture.workspace_root, Workspace.workspace_key(issue)))
      refute File.exists?(LaunchMarker.marker_path(issue.id))
    end

    test "the parked OpenCode dispatch never falls back to the Codex harness" do
      dispatch_fixture!("no-fallback", ssh_pilot_workflow())
      issue = active_issue("issue-he-2", "MIC-HE-2")

      {:ok, sup} = start_test_task_supervisor("no-fallback")
      state = Orchestrator.dispatch_issue_for_test(runtime_state(sup), issue)

      # The pilot authorized OpenCode for this issue; the remote host makes it
      # ineligible, so the dispatch stops entirely instead of degrading to a
      # Codex worker: nothing is running, nothing is retrying, and the park
      # records the OpenCode refusal.
      refute Map.has_key?(state.running, issue.id)
      assert state.retry_attempts == %{}
      assert Task.Supervisor.children(sup) == []

      parked = Map.get(state.parked, issue.id) || flunk("issue was not parked")
      assert parked.stop_reason == :opencode_remote_host_ineligible
    end

    test "an authorized OpenCode dispatch on the local host still spawns the OpenCode worker" do
      dispatch_fixture!("local-spawn", pilot_workflow())
      issue = active_issue("issue-he-3", "MIC-HE-3")

      {:ok, sup} = start_test_task_supervisor("local-spawn")
      state = Orchestrator.dispatch_issue_for_test(runtime_state(sup), issue)

      # Local (nil-host) dispatch is the authorized path and is unchanged.
      running = Map.get(state.running, issue.id) || flunk("issue was not dispatched")
      assert running.harness == :opencode
      assert running.worker_host == nil

      refute Map.has_key?(state.parked, issue.id)

      # The contained mock worker runs to completion and the task drains.
      wait_until(fn -> Task.Supervisor.children(sup) == [] end, 30_000)
    end

    test "a Codex dispatch on the same SSH host still spawns unchanged" do
      fixture = dispatch_fixture!("codex-ssh", ssh_pilot_workflow())

      # The pilot is enabled but authorizes a different issue, so this issue
      # takes the default Codex harness on the same configured SSH host.
      issue = active_issue("issue-he-4", "MIC-HE-4")

      trace_file = Path.join(fixture.test_root, "ssh.trace")
      previous_path = System.get_env("PATH")
      previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

      on_exit(fn ->
        restore_env("PATH", previous_path)
        restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
      end)

      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      FakeSSH.install!(fixture.test_root, :trace, trace_file: trace_file)

      {:ok, sup} = start_test_task_supervisor("codex-ssh")
      state = Orchestrator.dispatch_issue_for_test(runtime_state(sup), issue)

      running = Map.get(state.running, issue.id) || flunk("issue was not dispatched")
      assert running.harness == :codex
      assert running.worker_host == @remote_host
      refute Map.has_key?(state.parked, issue.id)

      # The remote execution path was still attempted over SSH (the fake
      # intercepts and traces it), proving Codex SSH routing is untouched.
      wait_until(fn -> File.exists?(trace_file) and File.read!(trace_file) != "" end, 10_000)

      # The remote worker attempt fails fast against the fake (no codex
      # server answers); wait it out so no task outlives the assertion.
      wait_until(fn -> Task.Supervisor.children(sup) == [] end, 30_000)
    end
  end

  # ===========================================================================
  # Active wake ledger (WAKE-EVENT-TAXONOMY-FIX)
  # ===========================================================================

  describe "remote-host refusal with an active wake ledger" do
    # park_opencode_remote_host/3 observes the refusal as a wake event before it
    # parks. With `wake_ledger: nil` observe_wake/4 is a no-op (which is why the
    # delivered dispatch-boundary tests stayed green), so the unregistered kind
    # only surfaced once a wake ledger was live — as a FunctionClauseError out of
    # Event.classify/2, raised before the park could happen at all.
    test "the refusal is classified and persisted without raising, and the park is unchanged" do
      workflow =
        pilot_workflow()
        |> Keyword.update!(:opencode_allowed_issues, &(&1 ++ ["MIC-HE-WL"]))
        |> Keyword.put(:worker_ssh_hosts, [@remote_host])

      fixture = dispatch_fixture!("wake-ledger", workflow)
      issue = active_issue("issue-he-wl", "MIC-HE-WL")

      wake_root = Path.join(fixture.test_root, "wake-root")
      File.mkdir_p!(wake_root)

      {:ok, sup} = start_test_task_supervisor("wake-ledger")

      state = %{runtime_state(sup) | wake_ledger: Ledger.new(wake_root)}
      state = Orchestrator.dispatch_issue_for_test(state, issue)

      # No classification exception: the refusal is a registered kind and wakes
      # exactly as an actionable event for this issue.
      snapshot = Ledger.snapshot(state.wake_ledger)

      refused =
        Enum.find(snapshot.pending_actionable, &(&1.kind == :opencode_remote_host_ineligible)) ||
          flunk("remote-host refusal did not reach the wake ledger")

      assert refused.actionable
      assert refused.issue_id == issue.id

      # The refusal and the park it produces stay distinct pending wakes, the
      # same way the fence/park pair does (wake_test.exs).
      assert Enum.sort(Enum.map(snapshot.pending_actionable, & &1.kind)) ==
               [:opencode_remote_host_ineligible, :parked]

      # Correct event persistence: the actionable receipt is durably recorded.
      assert File.exists?(Store.issue_path(wake_root, issue.id))
      assert {:ok, %{pending: pending}} = Store.read_issue(wake_root, issue.id)
      assert Enum.any?(pending, &(&1.kind == :opencode_remote_host_ineligible and &1.actionable))

      # Unchanged issue parking behavior: the delivered M1-H-F park contract is
      # intact — claim, no retry timer, no spawn, no workspace, no marker.
      parked = Map.get(state.parked, issue.id) || flunk("issue was not parked")
      assert parked.stop_reason == :opencode_remote_host_ineligible
      assert parked.failure_class == "PERSISTENT_WORKER_FAILURE"
      assert parked.worker_host == @remote_host
      assert parked.error =~ "not eligible on remote worker host"

      assert MapSet.member?(state.claimed, issue.id)
      refute Map.has_key?(state.running, issue.id)
      assert state.retry_attempts == %{}
      assert Task.Supervisor.children(sup) == []

      refute File.exists?(Path.join(fixture.workspace_root, Workspace.workspace_key(issue)))
      refute File.exists?(LaunchMarker.marker_path(issue.id))
    end
  end

  # ===========================================================================
  # AgentRunner host eligibility (defense in depth)
  # ===========================================================================

  describe "AgentRunner host eligibility" do
    test "an OpenCode dispatch carrying an SSH host fails closed before workspace mutation", context do
      %{issue: issue} = context

      error =
        assert_raise AgentRunner.FailureError, fn ->
          AgentRunner.run(issue, self(), dispatch_opts(context, issue, worker_host: @remote_host))
        end

      # OpenCode taxonomy (persistent), never the Codex AppServer mapper, so
      # the refusal can never be reinterpreted as a Codex worker failure.
      assert error.reason == {:opencode_remote_host_ineligible, @remote_host}
      assert error.failure_class == :persistent_worker_failure
      assert error.failure_info.failure_class == :persistent_worker_failure
      assert error.failure_info.message =~ @remote_host

      # No workspace was created, no marker was stranded, and no worker
      # evidence of any kind reached the recipient.
      refute File.exists?(Path.join(context.state_root, Workspace.workspace_key(issue)))
      refute File.exists?(LaunchMarker.marker_path(issue.id, root: context.state_root))
      assert drain_worker_mailbox() == []
    end

    test "the refusal reason classifies as a persistent OpenCode failure" do
      assert SymphonyElixir.OpenCode.classify_failure({:opencode_remote_host_ineligible, @remote_host}) ==
               :persistent_worker_failure

      info = SymphonyElixir.OpenCode.failure_info({:opencode_remote_host_ineligible, @remote_host})
      assert info.failure_class == :persistent_worker_failure
      assert info.message =~ @remote_host
    end

    test "an OpenCode dispatch without a worker host keeps the local run path", context do
      %{issue: issue} = context

      assert :ok = AgentRunner.run(issue, self(), dispatch_opts(context, issue))
    end
  end

  # ===========================================================================
  # Adapter host eligibility (last-chance gate)
  # ===========================================================================

  describe "adapter host eligibility" do
    test "start_session refuses a remote worker host before any artifact or process exists", context do
      %{issue: issue} = context
      workspace = prepare_workspace!(context, issue)

      # Precondition: a remote host carries no Windows containment
      # eligibility, which is exactly the hazard — before the gate the
      # adapter would have launched the child locally and uncontained.
      refute WorkerContainment.contained_launch?(@remote_host)

      assert {:error, {:opencode_remote_host_ineligible, @remote_host}} =
               Adapter.start_session(workspace, "prompt", adapter_opts(context, issue, worker_host: @remote_host))

      # Nothing exists: no session directories, no config, no stderr, no
      # marker — and the mock executable never ran.
      assert File.ls!(workspace) == []
      refute File.exists?(Path.join(workspace, ".symphony-state"))
      refute File.exists?(LaunchMarker.marker_path(issue.id, root: context.state_root))
    end

    test "an empty-string worker host is refused like a remote one", context do
      %{issue: issue} = context
      workspace = prepare_workspace!(context, issue)

      assert {:error, {:opencode_remote_host_ineligible, ""}} =
               Adapter.start_session(workspace, "prompt", adapter_opts(context, issue, worker_host: ""))

      assert File.ls!(workspace) == []
    end

    test "a local nil-host launch keeps the authorized contained Windows path", context do
      %{issue: issue, state_root: state_root} = context
      workspace = prepare_workspace!(context, issue)

      assert {:ok, session} = Adapter.start_session(workspace, "prompt", adapter_opts(context, issue))

      if WorkerContainment.contained_launch?(nil) do
        marker_path = LaunchMarker.marker_path(issue.id, root: state_root)
        wait_until(fn -> File.exists?(marker_path) end)
        assert {:blocked, _reuse_reason} = LaunchMarker.reuse_gate(issue.id, root: state_root)

        assert %{status: :TERMINATED_CONFIRMED} = Adapter.stop_session(session)
        wait_until(fn -> not File.exists?(marker_path) end)
        assert LaunchMarker.reuse_gate(issue.id, root: state_root) == :allowed
      else
        assert %{status: :NOT_APPLICABLE} = Adapter.stop_session(session)
      end
    end
  end

  # ===========================================================================
  # Fixtures and helpers
  # ===========================================================================

  defp test_issue(id, identifier) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "OpenCode host eligibility " <> identifier,
      description: "M1-H-F host eligibility gate",
      state: "Todo",
      url: "https://example.org/issues/" <> identifier,
      dispatchable: true
    }
  end

  defp active_issue(id, identifier) do
    %{test_issue(id, identifier) | state: "In Progress", labels: ["repo:symphony-runtime"]}
  end

  defp pilot(identifier, overrides \\ []) do
    %OpenCode{
      enabled: true,
      provider: "anthropic",
      model: "mock-model",
      timeout_ms: 15_000,
      allowed_tools: ["read", "glob"],
      allowed_issues: [identifier]
    }
    |> Map.merge(Map.new(overrides))
  end

  defp pilot_workflow do
    [
      opencode_enabled: true,
      opencode_provider: "anthropic",
      opencode_model: "mock-model",
      opencode_allowed_tools: ["read", "glob"],
      opencode_allowed_issues: ["MIC-HE-1", "MIC-HE-2", "MIC-HE-3"]
    ]
  end

  defp ssh_pilot_workflow do
    Keyword.put(pilot_workflow(), :worker_ssh_hosts, [@remote_host])
  end

  # A dispatch fixture mirroring the launch-fence pattern: a real source/remote
  # git pair so workspace classification resolves, plus pinned durable-state
  # roots so parks, markers, and receipts stay inside the fixture tree.
  defp dispatch_fixture!(name, workflow_overrides) do
    test_root = create_temp_fixture_root!("symphony-opencode-host-eligibility-#{name}")
    on_exit(fn -> remove_temp_fixture_root!(test_root) end)
    fixture = setup_source_fixture!(test_root)

    Application.put_env(:symphony_elixir, :launch_marker_root, Path.join(test_root, "launches"))
    Application.put_env(:symphony_elixir, :worker_termination_receipt_root, Path.join(test_root, "receipts"))

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :launch_marker_root)
      Application.delete_env(:symphony_elixir, :worker_termination_receipt_root)
    end)

    defaults = [
      tracker_kind: "memory",
      workspace_root: fixture.workspace_root,
      codex_stall_timeout_ms: 50,
      codex_read_timeout_ms: 300,
      codex_worker_termination_grace_ms: 100,
      routing: routing_config(fixture)
    ]

    workflow_file = Workflow.workflow_file_path()
    File.mkdir_p!(Path.dirname(workflow_file))
    write_workflow_file!(workflow_file, Keyword.merge(defaults, workflow_overrides))

    File.mkdir_p!(fixture.workspace_root)
    Map.put(fixture, :test_root, test_root)
  end

  defp routing_config(fixture) do
    %{
      target_label_prefix: "repo:",
      default_branch: "main",
      targets: %{
        "symphony-runtime" => %{source_path: fixture.source_repo, remote: fixture.remote_repo}
      }
    }
  end

  # The workspace AgentRunner will resolve for the issue, pre-created so
  # adapter-level tests control exactly what exists before the launch.
  defp prepare_workspace!(%{state_root: state_root}, %Issue{identifier: identifier}) do
    workspace = Path.join(state_root, Workspace.workspace_key(identifier))
    File.mkdir_p!(workspace)
    workspace
  end

  defp dispatch_opts(%{state_root: state_root}, %Issue{} = issue, extra \\ []) do
    [
      harness: :opencode,
      opencode: pilot(issue.identifier),
      attempt: 1,
      authority_root: state_root
    ] ++ extra
  end

  defp adapter_opts(%{state_root: state_root}, %Issue{} = issue, extra \\ []) do
    [
      provider: "anthropic",
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

  defp setup_source_fixture!(test_root) do
    File.mkdir_p!(test_root)

    remote_repo = Path.join(test_root, "remote.git") |> String.replace("\\", "/")
    source_repo = Path.join(test_root, "source") |> String.replace("\\", "/")
    workspace_root = Path.join(test_root, "workspaces") |> String.replace("\\", "/")

    git!(["init", "--bare", remote_repo])
    git!(["init", "-b", "main", source_repo])
    git!(["-C", source_repo, "config", "user.name", "Test User"])
    git!(["-C", source_repo, "config", "user.email", "test@example.com"])
    File.write!(Path.join(source_repo, "README.md"), "initial content\n")
    git!(["-C", source_repo, "add", "README.md"])
    git!(["-C", source_repo, "commit", "-m", "initial commit"])
    git!(["-C", source_repo, "remote", "add", "origin", remote_repo])
    git!(["-C", source_repo, "push", "-u", "origin", "main"])

    %{
      remote_repo: remote_repo,
      source_repo: source_repo,
      workspace_root: workspace_root
    }
  end

  defp git!(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, code} -> flunk("git #{Enum.join(args, " ")} failed (#{code}): #{output}")
    end
  end

  defp start_test_task_supervisor(suffix) do
    name = Module.concat(__MODULE__, :"HostEligibilitySup_#{suffix}_#{System.unique_integer([:positive])}")
    {:ok, sup} = Task.Supervisor.start_link(name: name)

    on_exit(fn ->
      if Process.whereis(name) do
        try do
          GenServer.stop(name)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    {:ok, sup}
  end

  # A fresh runtime state, exactly as the launch-fence dispatch tests build it.
  defp runtime_state(supervisor) do
    %Orchestrator.State{
      task_supervisor: supervisor,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }
  end
end
