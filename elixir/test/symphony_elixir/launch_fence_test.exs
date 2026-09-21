defmodule SymphonyElixir.LaunchFenceTest do
  use SymphonyElixir.TestSupport

  # Hardening slice: crash/restart scenario tests and the dual-execution
  # adversarial probe. Central expected behavior:
  #
  #   UNKNOWN = NO REUSE
  #   UNKNOWN = NO DESTRUCTIVE CLEANUP
  #
  # Every scenario below drives the real decision paths (orchestrator
  # dispatch, stall restart, reconcile-driven terminal cleanup, startup
  # terminal cleanup, AppServer session lifecycle) — never a fence helper in
  # isolation. Only the worker launch itself is simulated by writing the same
  # durable marker AppServer writes, with or without the wrapper's
  # termination receipt, exactly as a BEAM crash would leave them.

  alias SymphonyElixir.{LaunchMarker, Orchestrator, WorkerContainment, Workspace}
  alias SymphonyElixir.Tracker.Issue

  @grace_ms 100
  @hard_budget_ms 300

  # A prior test's on_exit cleanup can race this test's fixture work on slow
  # filesystems; re-create the workflow directory right before fixture writes.
  setup do
    workflow_file = Workflow.workflow_file_path()
    File.mkdir_p!(Path.dirname(workflow_file))
    :ok
  end

  setup do
    state_root =
      Path.join(System.tmp_dir!(), "symphony-launch-fence-#{System.unique_integer([:positive])}")

    File.mkdir_p!(state_root)
    Application.put_env(:symphony_elixir, :launch_marker_root, Path.join(state_root, "launches"))
    Application.put_env(:symphony_elixir, :worker_termination_receipt_root, Path.join(state_root, "receipts"))
    Application.put_env(:symphony_elixir, :worker_termination_hard_budget_ms, @hard_budget_ms)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :launch_marker_root)
      Application.delete_env(:symphony_elixir, :worker_termination_receipt_root)
      Application.delete_env(:symphony_elixir, :worker_termination_hard_budget_ms)
      File.rm_rf(state_root)
    end)

    %{state_root: state_root}
  end

  describe "first-attempt crash: resume gate" do
    test "old receipt absent -> dispatch fails closed, no second worker, workspace preserved" do
      fixture = fence_fixture!("crash-receipt-absent")
      issue = active_issue("issue-crash-absent", "MT-901")
      workspace = existing_workspace!(fixture, issue, "crash-absent workpad\n")
      marker!(issue, workspace)

      {:ok, sup} = start_test_task_supervisor("crash-absent")
      state = Orchestrator.dispatch_issue_for_test(runtime_state(sup), issue)

      # UNKNOWN -> NO REUSE: parked fail-closed with claim and no retry timer,
      # no worker task spawned, workspace untouched.
      assert Map.has_key?(state.parked, issue.id)
      assert state.parked[issue.id].stop_reason == :worker_launch_unproven
      assert MapSet.member?(state.claimed, issue.id)
      refute Map.has_key?(state.running, issue.id)
      assert state.retry_attempts == %{}
      assert Task.Supervisor.children(sup) == []
      assert File.read!(Path.join(workspace, "workpad.md")) == "crash-absent workpad\n"
      assert match?({:ok, _marker}, LaunchMarker.read(issue.id))
    end

    test "old receipt confirms death -> dispatch allowed, worker launched" do
      fixture = fence_fixture!("crash-receipt-proven")
      issue = active_issue("issue-crash-proven", "MT-902")
      workspace = existing_workspace!(fixture, issue, "crash-proven workpad\n")
      identity = marker!(issue, workspace)
      write_receipt!(identity)

      {:ok, sup} = start_test_task_supervisor("crash-proven")
      state = Orchestrator.dispatch_issue_for_test(runtime_state(sup), issue)

      # Positively proven DEAD -> replacement dispatch proceeds.
      assert Map.has_key?(state.running, issue.id)
      refute Map.has_key?(state.parked, issue.id)

      # The spawned agent task fails fast (no codex server in this fixture);
      # wait it out so the assertion process outlives the monitor.
      wait_until(fn -> Task.Supervisor.children(sup) == [] end, 5_000)
      assert File.read!(Path.join(workspace, "workpad.md")) == "crash-proven workpad\n"
    end

    test "stale marker with corrupt receipt -> UNKNOWN -> dispatch fails closed" do
      fixture = fence_fixture!("crash-corrupt-receipt")
      issue = active_issue("issue-crash-corrupt", "MT-903")
      workspace = existing_workspace!(fixture, issue, "crash-corrupt workpad\n")
      identity = marker!(issue, workspace)

      File.mkdir_p!(Path.dirname(identity["receipt_path"]))
      File.write!(identity["receipt_path"], "{corrupted")

      {:ok, sup} = start_test_task_supervisor("crash-corrupt")
      state = Orchestrator.dispatch_issue_for_test(runtime_state(sup), issue)

      assert state.parked[issue.id].stop_reason == :worker_launch_unproven
      assert Task.Supervisor.children(sup) == []
      assert File.exists?(workspace)
    end

    test "no marker (first dispatch ever) -> legacy dispatch proceeds" do
      fixture = fence_fixture!("no-marker")
      issue = active_issue("issue-no-marker", "MT-904")
      existing_workspace!(fixture, issue, "no-marker workpad\n")

      {:ok, sup} = start_test_task_supervisor("no-marker")
      state = Orchestrator.dispatch_issue_for_test(runtime_state(sup), issue)

      assert Map.has_key?(state.running, issue.id)
      wait_until(fn -> Task.Supervisor.children(sup) == [] end, 5_000)
    end
  end

  describe "stall restart" do
    test "old worker unconfirmed -> retry dispatch fails closed, workspace preserved" do
      fixture = fence_fixture!("stall-unconfirmed")
      issue = active_issue("issue-stall-unconfirmed", "MT-905")
      workspace = existing_workspace!(fixture, issue, "stall-unconfirmed workpad\n")
      marker!(issue, workspace)

      {:ok, sup, pid, ref} = start_dummy_worker_task()
      entry = running_entry(issue, pid, ref, workspace, fixture.workspace_root)

      state = %{runtime_state(sup) | running: %{issue.id => entry}}
      state = Orchestrator.reconcile_stalled_running_issues_for_test(state)

      # The stall restart killed the task and scheduled a retry; the marker
      # still holds the unproven identity.
      refute Map.has_key?(state.running, issue.id)
      assert Map.has_key?(state.retry_attempts, issue.id)
      assert match?({:ok, _marker}, LaunchMarker.read(issue.id))

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      retry_entry = Map.fetch!(state.retry_attempts, issue.id)

      state =
        Orchestrator.handle_retry_issue_lookup_for_test(
          issue,
          state,
          issue.id,
          retry_entry.attempt,
          %{identifier: issue.identifier, worker_host: nil}
        )

      assert state.parked[issue.id].stop_reason == :worker_launch_unproven
      refute Map.has_key?(state.running, issue.id)
      assert File.read!(Path.join(workspace, "workpad.md")) == "stall-unconfirmed workpad\n"
    end

    test "old worker confirmed during retry backoff -> retry dispatch allowed" do
      fixture = fence_fixture!("stall-confirmed")
      issue = active_issue("issue-stall-confirmed", "MT-906")
      workspace = existing_workspace!(fixture, issue, "stall-confirmed workpad\n")
      identity = marker!(issue, workspace)

      {:ok, sup, pid, ref} = start_dummy_worker_task()
      entry = running_entry(issue, pid, ref, workspace, fixture.workspace_root)

      state = %{runtime_state(sup) | running: %{issue.id => entry}}
      state = Orchestrator.reconcile_stalled_running_issues_for_test(state)
      refute Map.has_key?(state.running, issue.id)

      # The wrapper drains during the retry backoff and writes the receipt.
      write_receipt!(identity)

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      retry_entry = Map.fetch!(state.retry_attempts, issue.id)

      state =
        Orchestrator.handle_retry_issue_lookup_for_test(
          issue,
          state,
          issue.id,
          retry_entry.attempt,
          %{identifier: issue.identifier, worker_host: nil}
        )

      assert Map.has_key?(state.running, issue.id)
      wait_until(fn -> Task.Supervisor.children(sup) == [] end, 5_000)
    end
  end

  describe "destructive cleanup fence" do
    test "terminal cleanup after task kill with receipt absent -> workspace preserved" do
      fixture = fence_fixture!("cleanup-unconfirmed")
      issue = terminal_issue("issue-cleanup-unconfirmed", "MT-907")
      workspace = existing_workspace!(fixture, issue, "cleanup-unconfirmed workpad\n")
      marker!(issue, workspace)

      {:ok, sup, pid, ref} = start_dummy_worker_task()
      entry = running_entry(issue, pid, ref, workspace, fixture.workspace_root)
      state = %{runtime_state(sup) | running: %{issue.id => entry}}

      state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      # The synchronous reconcile must not have deleted the workspace: the
      # fence waits for positive drain proof before destructive cleanup.
      assert File.read!(Path.join(workspace, "workpad.md")) == "cleanup-unconfirmed workpad\n"

      # The bounded drain wait expires without proof: workspace and marker
      # are preserved (fail closed), and the entry left the running map.
      Process.sleep(@grace_ms + @hard_budget_ms + 600)
      assert File.read!(Path.join(workspace, "workpad.md")) == "cleanup-unconfirmed workpad\n"
      assert match?({:ok, _marker}, LaunchMarker.read(issue.id))
      refute Map.has_key?(state.running, issue.id)
    end

    test "terminal cleanup after confirmed drain -> workspace removed, marker cleared" do
      fixture = fence_fixture!("cleanup-confirmed")
      issue = terminal_issue("issue-cleanup-confirmed", "MT-908")
      workspace = existing_workspace!(fixture, issue, "cleanup-confirmed workpad\n")
      identity = marker!(issue, workspace)
      write_receipt!(identity)

      {:ok, sup, pid, ref} = start_dummy_worker_task()
      entry = running_entry(issue, pid, ref, workspace, fixture.workspace_root)
      state = %{runtime_state(sup) | running: %{issue.id => entry}}

      state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute File.exists?(workspace)
      assert match?({:error, :not_found}, LaunchMarker.read(issue.id))
      refute Map.has_key?(state.running, issue.id)
    end

    test "startup terminal workspace cleanup preserves workspace without drain proof" do
      fixture = fence_fixture!("startup-cleanup-unconfirmed")
      issue = terminal_issue("issue-startup-unconfirmed", "MT-909")
      workspace = existing_workspace!(fixture, issue, "startup-unconfirmed workpad\n")
      marker!(issue, workspace)

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      start_supervised!({Orchestrator, name: Module.concat(__MODULE__, :StartupUnconfirmed)})

      assert File.read!(Path.join(workspace, "workpad.md")) == "startup-unconfirmed workpad\n"
      assert match?({:ok, _marker}, LaunchMarker.read(issue.id))

      Process.sleep(@grace_ms + @hard_budget_ms + 600)
      assert File.exists?(workspace)
      assert match?({:ok, _marker}, LaunchMarker.read(issue.id))
    end

    test "startup terminal workspace cleanup removes workspace after confirmed drain" do
      fixture = fence_fixture!("startup-cleanup-confirmed")
      issue = terminal_issue("issue-startup-confirmed", "MT-910")
      workspace = existing_workspace!(fixture, issue, "startup-confirmed workpad\n")
      identity = marker!(issue, workspace)
      write_receipt!(identity)

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      start_supervised!({Orchestrator, name: Module.concat(__MODULE__, :StartupConfirmed)})

      refute File.exists?(workspace)
      assert match?({:error, :not_found}, LaunchMarker.read(issue.id))
    end
  end

  describe "dual-execution adversarial probe" do
    @doc """
    Models: old worker identity exists, workspace exists, runtime state lost,
    new dispatch arrives. Proves — through the real orchestrator dispatch
    path (dispatch -> resume gate -> classify -> Task.Supervisor spawn
    primitive) — that no second worker launch occurs until the previous
    worker's death is positively confirmed, and that confirmation admits
    exactly the replacement launch.
    """
    @tag :dual_execution_probe
    test "no second worker launch until death is confirmed, then exactly one" do
      fixture = fence_fixture!("dual-execution")
      issue = active_issue("issue-dual-execution", "MT-911")
      workspace = existing_workspace!(fixture, issue, "dual-execution workpad\n")
      identity = marker!(issue, workspace)

      # Runtime state lost: a fresh %State{} with no memory of the old worker.
      {:ok, sup} = start_test_task_supervisor("dual-execution")
      fresh_state = runtime_state(sup)

      blocked_state = Orchestrator.dispatch_issue_for_test(fresh_state, issue)

      # The spawn primitive was never reached: zero worker tasks exist.
      assert Task.Supervisor.children(sup) == []
      assert blocked_state.running == %{}
      assert blocked_state.parked[issue.id].stop_reason == :worker_launch_unproven
      assert File.read!(Path.join(workspace, "workpad.md")) == "dual-execution workpad\n"

      # The old tree drains and its receipt lands; the same decision path now
      # admits exactly one replacement worker.
      write_receipt!(identity)

      {:ok, sup2} = start_test_task_supervisor("dual-execution-confirmed")
      confirmed_state = Orchestrator.dispatch_issue_for_test(runtime_state(sup2), issue)

      assert Map.has_key?(confirmed_state.running, issue.id)
      wait_until(fn -> Task.Supervisor.children(sup2) != [] end, 5_000)
      wait_until(fn -> Task.Supervisor.children(sup2) == [] end, 5_000)
    end
  end

  describe "successful normal execution" do
    test "marker durable while worker active, cleared only after confirmed drain" do
      # The real contained launch path (jobrun wrapper) proves both the
      # write-point invariant and the successful-completion semantics;
      # containment stays enabled (the production default).
      fixture = fence_fixture!("successful-execution", codex_worker_containment_enabled: true)
      issue = active_issue("issue-successful", "MT-912")

      :ok = WorkerContainment.ensure_helper_built()

      workspace_root = fixture.workspace_root
      workspace = Path.join(workspace_root, Workspace.workspace_key(issue))
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "seed.txt"), "seed\n")

      codex_binary = Path.join(fixture.test_root, "fake-codex")

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1) printf '%s\\n' '{"id":1,"result":{}}' ;;
          2) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-fence-ok"}}}' ;;
          3) printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-fence-ok"}}}' ;;
          4) printf '%s\\n' '{"method":"turn/completed"}'; sleep 5; exit 0 ;;
          *) exit 0 ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      workflow_file = Workflow.workflow_file_path()
      File.mkdir_p!(Path.dirname(workflow_file))

      write_workflow_file!(workflow_file,
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{String.replace(codex_binary, "\\", "/")} app-server",
        codex_worker_termination_grace_ms: @grace_ms,
        routing: routing_config(fixture)
      )

      receipts = Application.fetch_env!(:symphony_elixir, :worker_termination_receipt_root)

      on_message = fn message ->
        # First model instruction is about to run: the worker is materially
        # active, so the marker must already be durable and no receipt may
        # exist yet (write point precedes worker activation).
        if Map.get(message, :event) == :session_started do
          assert {:ok, marker} = LaunchMarker.read(issue.id)
          assert is_binary(marker["launch_id"])
          assert marker["issue_id"] == issue.id
          assert marker["workspace"] == workspace
          assert receipt_files(receipts) == []
        end

        :ok
      end

      assert {:ok, _result} =
               AppServer.run(workspace, "Run the fence probe", issue,
                 issue: issue,
                 on_message: on_message
               )

      # Successful stop: the wrapper receipt proved the tree drained, the
      # same fence logic accepted it, and only then was the marker cleared.
      assert {:error, :not_found} = LaunchMarker.read(issue.id)
      receipt_files = receipt_files(receipts)
      assert length(receipt_files) == 1

      assert {:ok, receipt} = WorkerContainment.parse_receipt(hd(receipt_files))
      assert receipt["tree_drained"] == true
    end
  end

  # ── Fixtures and helpers ────────────────────────────────────────────────────

  defp fence_fixture!(name, overrides \\ []) do
    test_root = test_root_path(name)
    # Register cleanup before the fixture exists, so even a fixture-setup
    # failure cannot leak the tree into the shared TEMP root.
    on_exit(fn -> SymphonyElixir.TestSupport.remove_temp_fixture_root!(test_root) end)
    fixture = setup_source_fixture!(test_root)

    # Dispatch fixtures keep containment off so the agent task a successful
    # gate spawn fails fast and deterministically (no codex server, no jobrun
    # dependence). The fence itself is containment-independent: the gate reads
    # the durable marker, not the containment predicate. The successful-
    # execution scenario enables containment (the default) explicitly.
    defaults = [
      tracker_kind: "memory",
      workspace_root: fixture.workspace_root,
      codex_stall_timeout_ms: 50,
      codex_read_timeout_ms: 300,
      codex_worker_containment_enabled: false,
      codex_worker_termination_grace_ms: @grace_ms,
      routing: routing_config(fixture)
    ]

    workflow_file = Workflow.workflow_file_path()
    File.mkdir_p!(Path.dirname(workflow_file))
    write_workflow_file!(workflow_file, Keyword.merge(defaults, overrides))

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

  defp active_issue(id, identifier) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Fence scenario #{identifier}",
      state: "In Progress",
      labels: ["repo:symphony-runtime"],
      url: "https://example.org/issues/#{identifier}",
      dispatchable: true
    }
  end

  defp terminal_issue(id, identifier), do: %{active_issue(id, identifier) | state: "Done"}

  defp workpad(workspace), do: File.read!(Path.join(workspace, "workpad.md"))

  defp existing_workspace!(fixture, issue, sentinel_content) do
    workspace = Path.join(fixture.workspace_root, Workspace.workspace_key(issue))
    git!(["-C", fixture.source_repo, "worktree", "add", workspace, "-b", "symphony/#{issue.identifier}"])
    File.write!(Path.join(workspace, "workpad.md"), sentinel_content)
    workspace
  end

  # Writes the same durable marker AppServer.start_session writes before a
  # contained launch, simulating a worker whose launch is (or was) active.
  defp marker!(issue, workspace) do
    identity =
      WorkerContainment.new_identity(
        issue_id: issue.id,
        attempt_id: 1,
        workspace: workspace,
        worker_host: nil
      )

    assert :ok = LaunchMarker.record(identity, identifier: issue.identifier, attempt_id: 1)
    identity
  end

  defp write_receipt!(identity, overrides \\ %{}) do
    File.mkdir_p!(Path.dirname(identity["receipt_path"]))

    receipt =
      Map.merge(
        %{
          "schema_version" => 1,
          "launch_id" => identity["launch_id"],
          "tree_drained" => true,
          "terminal_reason" => "HARD_JOB_TERMINATION",
          "termination_mode" => "hard",
          "child_exit_code" => 1
        },
        overrides
      )

    File.write!(identity["receipt_path"], Jason.encode!(receipt))
    identity["receipt_path"]
  end

  defp receipt_files(receipts) do
    case File.ls(receipts) do
      {:ok, names} -> names |> Enum.filter(&String.ends_with?(&1, ".json")) |> Enum.map(&Path.join(receipts, &1))
      {:error, _} -> []
    end
  end

  defp start_test_task_supervisor(suffix) do
    name = Module.concat(__MODULE__, :"FenceTaskSup_#{suffix}_#{System.unique_integer([:positive])}")
    {:ok, sup} = Task.Supervisor.start_link(name: name)

    on_exit(fn ->
      if Process.whereis(name) do
        try do
          GenServer.stop(name)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    {:ok, sup}
  end

  # A fresh post-restart runtime state: empty lifecycle maps, the codex
  # totals initialized exactly as Orchestrator.init does.
  defp runtime_state(supervisor) do
    %Orchestrator.State{
      task_supervisor: supervisor,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }
  end

  # A stand-in agent task: real pid + real monitor so the stall/terminal
  # paths' stop primitives behave exactly as with a genuine worker task.
  defp start_dummy_worker_task do
    {:ok, sup} = start_test_task_supervisor("dummy")

    {:ok, pid} =
      Task.Supervisor.start_child(sup, fn ->
        Process.sleep(:infinity)
      end)

    ref = Process.monitor(pid)
    {:ok, sup, pid, ref}
  end

  defp running_entry(issue, pid, ref, workspace, workspace_root) do
    %{
      pid: pid,
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      worker_host: nil,
      workspace_path: workspace,
      workspace_root: workspace_root,
      session_id: nil,
      retry_attempt: 1,
      started_at: DateTime.utc_now(),
      last_codex_timestamp: DateTime.add(DateTime.utc_now(), -120_000, :millisecond),
      last_codex_message: nil,
      last_codex_event: nil
    }
  end

  # Grace + shrunk hard budget, plus polling slack (mirrored inline where a
  # test must outlive the bounded drain wait).

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition not met before deadline")
      end

      Process.sleep(25)
      do_wait_until(fun, deadline)
    end
  end

  defp test_root_path(name) do
    # unique_integer restarts at 1 in every BEAM, so a fixture root a previous
    # run leaked under the same id would be silently reinitialized by `git init`
    # and break this run's setup; the clock suffix makes the path unique across
    # concurrent and successive runs.
    Path.join(
      System.tmp_dir!(),
      "symphony-launch-fence-fixture-#{name}-#{System.unique_integer([:positive])}-#{System.system_time(:native)}"
    )
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
end
