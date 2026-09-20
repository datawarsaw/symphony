defmodule SymphonyElixir.WorkspaceViabilityLaunchFenceTest do
  use SymphonyElixir.TestSupport

  # Combined composition tests: the LaunchMarker fence and the workspace
  # viability gate must hold together, in a fixed order, without either
  # weakening or bypassing the other.
  #
  #   Dispatch order:  reuse_gate (launch fence) → repository identity →
  #                    workspace viability → spawn
  #   Cleanup order:   cleanup_gate (launch fence) → viability preservation →
  #                    destructive removal
  #
  # Every scenario drives the real orchestrator decision paths (dispatch,
  # blocked-issue reconcile, running-issue terminal reconcile), never a gate
  # helper in isolation. The launch marker and its wrapper receipt are written
  # exactly as AppServer / the jobrun wrapper would leave them.

  alias SymphonyElixir.{LaunchMarker, Orchestrator, WorkerContainment, Workspace}
  alias SymphonyElixir.Tracker.Issue

  @grace_ms 100
  @hard_budget_ms 300

  setup do
    workflow_file = Workflow.workflow_file_path()
    File.mkdir_p!(Path.dirname(workflow_file))
    :ok
  end

  setup do
    state_root =
      Path.join(System.tmp_dir!(), "symphony-viability-fence-#{System.unique_integer([:positive])}")

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

  # ── Combined dispatch attack matrix ────────────────────────────────────────
  #
  #   A. live prior launch + viable workspace      → refuse
  #   B. dead prior launch + non-viable workspace  → refuse + preserve
  #   C. dead prior launch + viable workspace      → dispatch eligible
  #   D. no marker + never-checked-out workspace   → refuse
  #   E. no marker + legitimate dirty workspace    → dispatch eligible
  #   F. corrupt marker + viable workspace         → refuse
  describe "combined dispatch gates (launch fence first, viability second)" do
    @tag :combined_dispatch_matrix
    test "A: live prior launch + viable workspace refuses through the launch fence alone" do
      fixture = combined_fixture!("dispatch-a-live-viable")
      issue = active_issue("issue-a-live-viable", "MT-921")
      workspace = existing_workspace!(fixture, issue, "a viable workpad\n")
      marker!(issue, workspace)

      {:ok, sup} = start_test_task_supervisor("matrix-a")
      state = Orchestrator.dispatch_issue_for_test(runtime_state(sup), issue)

      # The launch fence refuses before classification is ever consulted: the
      # viable workspace is irrelevant while the previous worker is unproven.
      assert state.parked[issue.id].stop_reason == :worker_launch_unproven
      refute Map.has_key?(state.running, issue.id)
      assert state.retry_attempts == %{}
      assert Task.Supervisor.children(sup) == []
      assert File.read!(Path.join(workspace, "workpad.md")) == "a viable workpad\n"
      assert match?({:ok, _marker}, LaunchMarker.read(issue.id))
    end

    @tag :combined_dispatch_matrix
    test "B: dead prior launch + non-viable workspace refuses and preserves through the viability gate" do
      fixture = combined_fixture!("dispatch-b-dead-nonviable")
      issue = active_issue("issue-b-dead-nonviable", "MT-922")
      workspace = interrupted_workspace!(fixture, issue)
      identity = marker!(issue, workspace)
      write_receipt!(identity)

      {:ok, sup} = start_test_task_supervisor("matrix-b")
      state = Orchestrator.dispatch_issue_for_test(runtime_state(sup), issue)

      # Death is proven, so the launch fence admits; the viability gate then
      # fails closed: no worker, workspace parked as blocked evidence.
      refute Map.has_key?(state.running, issue.id)
      refute Map.has_key?(state.parked, issue.id)
      assert state.retry_attempts == %{}
      assert Task.Supervisor.children(sup) == []

      blocked_entry = Map.fetch!(state.blocked, issue.id)
      assert blocked_entry.viability_error == true
      assert match?({:error, {:workspace_not_viable, _path, :never_checked_out}}, blocked_entry.error)

      # The non-viable workspace itself survives as evidence for repair.
      assert File.exists?(workspace)
    end

    @tag :combined_dispatch_matrix
    test "C: dead prior launch + viable workspace is dispatch eligible" do
      fixture = combined_fixture!("dispatch-c-dead-viable")
      issue = active_issue("issue-c-dead-viable", "MT-923")
      workspace = existing_workspace!(fixture, issue, "c viable workpad\n")
      identity = marker!(issue, workspace)
      write_receipt!(identity)

      {:ok, sup} = start_test_task_supervisor("matrix-c")
      state = Orchestrator.dispatch_issue_for_test(runtime_state(sup), issue)

      # Both gates pass: exactly one replacement worker launches.
      assert Map.has_key?(state.running, issue.id)
      assert File.read!(Path.join(workspace, "workpad.md")) == "c viable workpad\n"
      wait_until(fn -> Task.Supervisor.children(sup) == [] end, 5_000)
    end

    @tag :combined_dispatch_matrix
    test "D: no marker + never-checked-out workspace refuses through the viability gate" do
      fixture = combined_fixture!("dispatch-d-no-marker-interrupted")
      issue = active_issue("issue-d-interrupted", "MT-924")
      workspace = interrupted_workspace!(fixture, issue)

      {:ok, sup} = start_test_task_supervisor("matrix-d")
      state = Orchestrator.dispatch_issue_for_test(runtime_state(sup), issue)

      refute Map.has_key?(state.running, issue.id)
      assert Task.Supervisor.children(sup) == []

      blocked_entry = Map.fetch!(state.blocked, issue.id)
      assert blocked_entry.viability_error == true
      assert match?({:error, {:workspace_not_viable, _path, :never_checked_out}}, blocked_entry.error)
      assert File.exists?(workspace)
    end

    @tag :combined_dispatch_matrix
    test "E: no marker + legitimate dirty viable workspace is dispatch eligible" do
      fixture = combined_fixture!("dispatch-e-dirty")
      issue = active_issue("issue-e-dirty", "MT-925")
      workspace = existing_workspace!(fixture, issue, "dirty tracked content\n")
      File.write!(Path.join(workspace, "worker-scratch.md"), "untracked scratch\n")
      git!(["-C", workspace, "add", "worker-scratch.md"])

      {:ok, sup} = start_test_task_supervisor("matrix-e")
      state = Orchestrator.dispatch_issue_for_test(runtime_state(sup), issue)

      # Dirty is not broken: modified tracked + staged untracked content stays
      # fully resumable when identity and structure hold.
      assert Map.has_key?(state.running, issue.id)
      wait_until(fn -> Task.Supervisor.children(sup) == [] end, 5_000)
    end

    @tag :combined_dispatch_matrix
    test "F: corrupt marker + viable workspace refuses through the launch fence" do
      fixture = combined_fixture!("dispatch-f-corrupt-marker")
      issue = active_issue("issue-f-corrupt", "MT-926")
      workspace = existing_workspace!(fixture, issue, "f viable workpad\n")
      marker!(issue, workspace)
      File.write!(LaunchMarker.marker_path(issue.id), "{corrupted")

      {:ok, sup} = start_test_task_supervisor("matrix-f")
      state = Orchestrator.dispatch_issue_for_test(runtime_state(sup), issue)

      # An unreadable marker is UNKNOWN: the viability of the workspace never
      # comes into play and nothing launches.
      assert state.parked[issue.id].stop_reason == :worker_launch_unproven
      refute Map.has_key?(state.running, issue.id)
      assert Task.Supervisor.children(sup) == []
      assert File.exists?(workspace)
    end
  end

  # ── Combined cleanup attack matrix ─────────────────────────────────────────
  #
  #   A. live prior worker + cleanup requested            → no cleanup
  #   B. unknown prior worker + cleanup requested         → no cleanup
  #   C. confirmed dead + preserved viability state       → no cleanup
  #   D. confirmed dead + normal disposable workspace     → cleanup allowed
  describe "combined cleanup gates (fence first, preservation second)" do
    @tag :combined_cleanup_matrix
    test "A: live prior worker (tree not drained) + cleanup requested preserves the workspace" do
      fixture = combined_fixture!("cleanup-a-live")
      issue = terminal_issue("issue-cleanup-a", "MT-931")
      workspace = existing_workspace!(fixture, issue, "cleanup-a workpad\n")
      identity = marker!(issue, workspace)
      write_receipt!(identity, %{"tree_drained" => false})

      {:ok, sup, pid, ref} = start_dummy_worker_task()
      entry = running_entry(issue, pid, ref, workspace, fixture.workspace_root)
      state = %{runtime_state(sup) | running: %{issue.id => entry}}

      state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      # The bounded drain wait expires without positive proof: no cleanup.
      Process.sleep(@grace_ms + @hard_budget_ms + 600)
      assert File.read!(Path.join(workspace, "workpad.md")) == "cleanup-a workpad\n"
      assert match?({:ok, _marker}, LaunchMarker.read(issue.id))
      refute Map.has_key?(state.running, issue.id)
    end

    @tag :combined_cleanup_matrix
    test "B: unknown prior worker (mismatched receipt) + cleanup requested preserves the workspace" do
      fixture = combined_fixture!("cleanup-b-unknown")
      issue = terminal_issue("issue-cleanup-b", "MT-932")
      workspace = existing_workspace!(fixture, issue, "cleanup-b workpad\n")
      identity = marker!(issue, workspace)

      File.mkdir_p!(Path.dirname(identity["receipt_path"]))

      receipt =
        Map.merge(base_receipt(identity), %{
          "launch_id" => "launch-that-never-owned-this-workspace"
        })

      File.write!(identity["receipt_path"], Jason.encode!(receipt))

      {:ok, sup, pid, ref} = start_dummy_worker_task()
      entry = running_entry(issue, pid, ref, workspace, fixture.workspace_root)
      state = %{runtime_state(sup) | running: %{issue.id => entry}}

      state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      Process.sleep(@grace_ms + @hard_budget_ms + 600)
      assert File.read!(Path.join(workspace, "workpad.md")) == "cleanup-b workpad\n"
      assert match?({:ok, _marker}, LaunchMarker.read(issue.id))
      refute Map.has_key?(state.running, issue.id)
    end

    @tag :combined_cleanup_matrix
    test "C: confirmed dead + viability-preserved workspace is NOT cleaned even though the fence allows" do
      fixture = combined_fixture!("cleanup-c-preserved")
      issue = active_issue("issue-cleanup-c", "MT-933")
      workspace = interrupted_workspace!(fixture, issue)

      # The viability gate parked this issue: blocked entry marks the workspace
      # as preserved evidence. The old launch (if any) is positively dead, so
      # the fence permits — the preservation policy must still block.
      identity = marker!(issue, workspace)
      write_receipt!(identity)

      blocked_entry = blocked_viability_entry(issue, workspace, fixture.workspace_root)
      state = %{runtime_state(start_test_task_supervisor("matrix-c")) | blocked: %{issue.id => blocked_entry}}
      terminal = terminal_issue(issue.id, issue.identifier)

      reconciled = Orchestrator.reconcile_blocked_issue_states_for_test([terminal], state)

      # Fence allowed (marker cleared) but the workspace survived: terminal
      # reconciliation alone never destroys viability-preserved evidence.
      assert match?({:error, :not_found}, LaunchMarker.read(issue.id))
      assert File.exists?(workspace)
      refute MapSet.member?(reconciled.claimed, issue.id)
    end

    @tag :combined_cleanup_matrix
    test "C2: viability-preserved workspace with no marker stays preserved" do
      fixture = combined_fixture!("cleanup-c2-preserved-no-marker")
      issue = active_issue("issue-cleanup-c2", "MT-934")
      workspace = interrupted_workspace!(fixture, issue)

      blocked_entry = blocked_viability_entry(issue, workspace, fixture.workspace_root)
      state = %{runtime_state(start_test_task_supervisor("matrix-c2")) | blocked: %{issue.id => blocked_entry}}
      terminal = terminal_issue(issue.id, issue.identifier)

      Orchestrator.reconcile_blocked_issue_states_for_test([terminal], state)

      assert File.exists?(workspace)
    end

    @tag :combined_cleanup_matrix
    test "D: confirmed dead + normal disposable workspace is cleaned and marker cleared" do
      fixture = combined_fixture!("cleanup-d-disposable")
      issue = terminal_issue("issue-cleanup-d", "MT-935")
      workspace = existing_workspace!(fixture, issue, "cleanup-d workpad\n")
      identity = marker!(issue, workspace)
      write_receipt!(identity)

      {:ok, sup, pid, ref} = start_dummy_worker_task()
      entry = running_entry(issue, pid, ref, workspace, fixture.workspace_root)
      state = %{runtime_state(sup) | running: %{issue.id => entry}}

      state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      # Both gates allow a genuinely disposable workspace: cleanup proceeds.
      refute File.exists?(workspace)
      assert match?({:error, :not_found}, LaunchMarker.read(issue.id))
      refute Map.has_key?(state.running, issue.id)
    end
  end

  # ── Repair-safety composition ──────────────────────────────────────────────
  #
  # The bounded repair command must keep refusing when it cannot prove branch
  # safety: with origin/<default_branch> missing, even a fully-merged branch
  # stays preserved (fail closed on ambiguous evidence).
  describe "repair safety (missing origin/default refuses)" do
    test "branch preserved when origin default branch is missing" do
      fixture = combined_fixture!("repair-missing-origin")
      identifier = "MT-941"
      task_branch = "symphony/#{identifier}"
      workspace = interrupted_workspace!(fixture, active_issue("issue-repair-origin", identifier))
      File.rm_rf!(workspace)

      # Simulate a source repository whose origin/default ref is gone.
      git!(["-C", fixture.source_repo, "update-ref", "-d", "refs/remotes/origin/main"])

      assert_raise(
        Mix.Error,
        ~r/cannot prove branch safety/,
        fn ->
          Mix.Task.rerun("symphony.workspace_repair", [identifier, "--source", fixture.source_repo])
        end
      )

      # Unique-work preservation: the branch survives the refused repair.
      assert {output, 0} = System.cmd("git", ["-C", fixture.source_repo, "show-ref", "--verify", "refs/heads/#{task_branch}"], stderr_to_stdout: true)
      assert String.trim(output) != ""
    end
  end

  # ── Fixtures and helpers ────────────────────────────────────────────────────

  defp combined_fixture!(name) do
    test_root = Path.join(System.tmp_dir!(), "symphony-viability-fence-fixture-#{name}-#{System.unique_integer([:positive])}")
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

    workflow_file = Workflow.workflow_file_path()
    File.mkdir_p!(Path.dirname(workflow_file))

    write_workflow_file!(workflow_file,
      tracker_kind: "memory",
      workspace_root: workspace_root,
      codex_stall_timeout_ms: 50,
      codex_read_timeout_ms: 300,
      codex_worker_containment_enabled: false,
      codex_worker_termination_grace_ms: @grace_ms,
      routing: %{
        target_label_prefix: "repo:",
        default_branch: "main",
        targets: %{
          "symphony-runtime" => %{source_path: source_repo, remote: remote_repo}
        }
      }
    )

    File.mkdir_p!(workspace_root)

    %{test_root: test_root, source_repo: source_repo, remote_repo: remote_repo, workspace_root: workspace_root}
  end

  defp active_issue(id, identifier) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Combined gate scenario #{identifier}",
      state: "In Progress",
      labels: ["repo:symphony-runtime"],
      url: "https://example.org/issues/#{identifier}",
      dispatchable: true
    }
  end

  defp terminal_issue(id, identifier), do: %{active_issue(id, identifier) | state: "Done"}

  # A structurally viable workspace with a tracked file, as a completed
  # `git worktree add` would leave it.
  defp existing_workspace!(fixture, issue, workpad_content) do
    workspace = Path.join(fixture.workspace_root, Workspace.workspace_key(issue))
    git!(["-C", fixture.source_repo, "worktree", "add", workspace, "-b", "symphony/#{issue.identifier}"])
    File.write!(Path.join(workspace, "workpad.md"), workpad_content)
    workspace
  end

  # The interrupted-create signature: registered and branched, checkout never
  # ran (`git worktree add --no-checkout`), so the workspace is provably
  # non-viable (:never_checked_out) but is also exactly the residue the
  # viability-preservation policy and the repair command must protect.
  defp interrupted_workspace!(fixture, issue) do
    workspace = Path.join(fixture.workspace_root, Workspace.workspace_key(issue))
    File.mkdir_p!(workspace)

    git!([
      "-C",
      fixture.source_repo,
      "worktree",
      "add",
      "--no-checkout",
      "-b",
      "symphony/#{issue.identifier}",
      workspace,
      "refs/remotes/origin/main"
    ])

    workspace
  end

  defp blocked_viability_entry(issue, workspace, workspace_root) do
    %{
      issue_id: issue.id,
      identifier: issue.identifier,
      issue: issue,
      worker_host: nil,
      workspace_path: workspace,
      workspace_root: workspace_root,
      viability_error: true,
      session_id: nil,
      error: {:error, {:workspace_not_viable, workspace, :never_checked_out}},
      discovery_result: nil,
      blocked_at: DateTime.utc_now(),
      last_codex_message: nil,
      last_codex_event: nil,
      last_codex_timestamp: nil
    }
  end

  # Writes the same durable marker AppServer.start_session writes before a
  # contained launch.
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

  defp base_receipt(identity) do
    %{
      "schema_version" => 1,
      "launch_id" => identity["launch_id"],
      "tree_drained" => true,
      "terminal_reason" => "HARD_JOB_TERMINATION",
      "termination_mode" => "hard",
      "child_exit_code" => 1
    }
  end

  defp write_receipt!(identity, overrides \\ %{}) do
    File.mkdir_p!(Path.dirname(identity["receipt_path"]))
    receipt = Map.merge(base_receipt(identity), overrides)
    File.write!(identity["receipt_path"], Jason.encode!(receipt))
    identity["receipt_path"]
  end

  defp start_test_task_supervisor(suffix) do
    name = Module.concat(__MODULE__, :"ViabilityFenceTaskSup_#{suffix}_#{System.unique_integer([:positive])}")
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

  defp runtime_state(supervisor) do
    %Orchestrator.State{
      task_supervisor: supervisor,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }
  end

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

  defp git!(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, code} -> flunk("git #{Enum.join(args, " ")} failed (#{code}): #{output}")
    end
  end
end
