defmodule SymphonyElixir.RestartReconciliationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RepositoryRouter.Route
  alias SymphonyElixir.Config
  alias SymphonyElixir.{AgentRunner, Orchestrator, PromptBuilder, Tracker, Workflow, Workspace}
  alias SymphonyElixir.Tracker.Issue

  describe "restart reconciliation and resumption" do
    test "1. active issue + existing valid dirty workspace -> classified resume and contents preserved" do
      test_root = test_root_path("resume-valid-dirty")

      try do
        fixture = setup_source_fixture!(test_root)
        configure_workspace_workflow!(fixture)

        issue = %Issue{
          id: "issue-valid-dirty",
          identifier: "MT-101",
          title: "Surviving work item",
          state: "In Progress",
          labels: ["repo:symphony-runtime"],
          dispatchable: true
        }

        safe_id = Workspace.workspace_key(issue)
        workspace_path = Path.join(fixture.workspace_root, safe_id)

        # Materialize an authoritative worktree for the issue
        File.mkdir_p!(fixture.workspace_root)
        git!(["-C", fixture.source_repo, "worktree", "add", workspace_path, "-b", "symphony/MT-101"])

        # Create uncommitted dirty changes
        dirty_file = Path.join(workspace_path, "workpad.md")
        File.write!(dirty_file, "in-progress dirty notes\n")
        File.write!(Path.join(workspace_path, "README.md"), "modified readme content\n")

        # Classification authority check
        assert {:ok, :resume, classified_path, %Route{target: "symphony-runtime"}} =
                 Workspace.classify_candidate(issue)

        assert Path.expand(classified_path) == Path.expand(workspace_path)
        assert File.read!(dirty_file) == "in-progress dirty notes\n"
        assert File.read!(Path.join(workspace_path, "README.md")) == "modified readme content\n"

        # Startup reconciliation in Orchestrator
        Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

        state = %Orchestrator.State{task_supervisor: SymphonyElixir.TaskSupervisor}
        state = Orchestrator.run_startup_reconciliation_for_test(state)

        assert MapSet.member?(state.resumed_issues, issue.id)
        assert File.read!(dirty_file) == "in-progress dirty notes\n"
        assert File.read!(Path.join(workspace_path, "README.md")) == "modified readme content\n"
      after
        File.rm_rf(test_root)
      end
    end

    test "2. resumed dispatch receives continuation/resumption framing" do
      issue = %Issue{
        id: "issue-framing",
        identifier: "MT-102",
        title: "Prompt framing test",
        description: "Verify continuation prompt semantics",
        state: "In Progress",
        dispatchable: true
      }

      provenance = %{prepared_base_commit: "deadbeef", repository_target: "symphony-runtime"}

      # Resumed prompt framing (turn 1)
      resumed_prompt =
        AgentRunner.build_turn_prompt_for_test(issue, [resumed: true], provenance, 1, 10)

      assert resumed_prompt =~ "Resumption guidance:"
      assert resumed_prompt =~ "interrupted by a runtime restart and is resuming in its existing workspace"
      assert resumed_prompt =~ "Resume progress from the current workspace state instead of starting over."
      assert resumed_prompt =~ "Host-prepared workspace provenance"
      assert resumed_prompt =~ "deadbeef"

      # Fresh prompt does not contain resumption guidance
      fresh_prompt =
        AgentRunner.build_turn_prompt_for_test(issue, [resumed: false], provenance, 1, 10)

      refute fresh_prompt =~ "Resumption guidance:"
      assert fresh_prompt =~ "Host-prepared workspace provenance"

      # PromptBuilder Solid variable support
      template = "{% if resumed %}CONTINUATION{% else %}FRESH{% endif %}: {{ issue.identifier }}"
      write_workflow_file!(Workflow.workflow_file_path(), prompt: template)

      assert PromptBuilder.build_prompt(issue, resumed: true) =~ "CONTINUATION: MT-102"
      assert PromptBuilder.build_prompt(issue, resumed: false) =~ "FRESH: MT-102"
    end

    test "3. active issue + workspace Git identity mismatch -> fail closed, directory preserved" do
      test_root = test_root_path("mismatch-fail-closed")

      try do
        fixture_a = setup_source_fixture!(Path.join(test_root, "repo_a"))
        fixture_b = setup_source_fixture!(Path.join(test_root, "repo_b"))

        # Routing points to Repo A
        shared_workspace_root = Path.join(test_root, "shared_workspaces")
        File.mkdir_p!(shared_workspace_root)

        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "memory",
          workspace_root: shared_workspace_root,
          routing: %{
            target_label_prefix: "repo:",
            default_branch: "main",
            targets: %{
              "symphony-runtime" => %{source_path: fixture_a.source_repo, remote: fixture_a.remote_repo}
            }
          }
        )

        issue = %Issue{
          id: "issue-mismatch",
          identifier: "MT-103",
          title: "Mismatched repo issue",
          state: "In Progress",
          labels: ["repo:symphony-runtime"],
          dispatchable: true
        }

        safe_id = Workspace.workspace_key(issue)
        mismatched_ws = Path.join(shared_workspace_root, safe_id)

        # Workspace on disk was prepared against Repo B instead of Repo A
        git!(["-C", fixture_b.source_repo, "worktree", "add", mismatched_ws, "-b", "symphony/MT-103"])
        critical_file = Path.join(mismatched_ws, "critical_workpad.md")
        File.write!(critical_file, "surviving important data\n")

        # 1. Authority check fails closed
        assert {:error, {:workspace_repository_mismatch, "symphony-runtime", {:git_common_dir, _actual, _expected}}} =
                 Workspace.classify_candidate(issue)

        # 2. Startup reconciliation marks issue blocked and preserves directory
        Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

        state = %Orchestrator.State{task_supervisor: SymphonyElixir.TaskSupervisor}
        state = Orchestrator.run_startup_reconciliation_for_test(state)

        assert Map.has_key?(state.blocked, issue.id)
        assert MapSet.member?(state.claimed, issue.id)
        refute MapSet.member?(state.resumed_issues, issue.id)
        assert state.blocked[issue.id].error =~ "workspace repository identity mismatch"

        # 3. Issue is not dispatchable
        refute Orchestrator.should_dispatch_issue_for_test(issue, state)

        # 4. Directory is untouched byte-for-byte
        assert File.dir?(mismatched_ws)
        assert File.read!(critical_file) == "surviving important data\n"
      after
        File.rm_rf(test_root)
      end
    end

    test "4. terminal workspace cleanup still occurs before dispatch" do
      test_root = test_root_path("terminal-ahead-of-dispatch")

      try do
        workspace_root = Path.join(test_root, "workspaces")
        File.mkdir_p!(workspace_root)

        terminal_issue = %Issue{
          id: "issue-term",
          identifier: "MT-TERM",
          title: "Closed ticket",
          state: "Closed",
          labels: [],
          dispatchable: false
        }

        active_issue = %Issue{
          id: "issue-active",
          identifier: "MT-ACTIVE",
          title: "In-flight ticket",
          state: "In Progress",
          labels: [],
          dispatchable: true
        }

        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "memory",
          workspace_root: workspace_root,
          tracker_terminal_states: ["Closed", "Done"],
          tracker_active_states: ["In Progress", "Todo"]
        )

        term_ws = Path.join(workspace_root, Workspace.workspace_key(terminal_issue))
        active_ws = Path.join(workspace_root, Workspace.workspace_key(active_issue))

        File.mkdir_p!(term_ws)
        File.write!(Path.join(term_ws, "stale.txt"), "should be cleaned\n")

        File.mkdir_p!(active_ws)
        File.write!(Path.join(active_ws, "active.txt"), "must survive\n")

        # Tracker serves both issues
        Application.put_env(:symphony_elixir, :memory_tracker_issues, [terminal_issue, active_issue])

        # Start an orchestrator instance to test the startup sequence
        orchestrator_name = Module.concat(__MODULE__, "TestInitOrch#{System.unique_integer([:positive])}")
        task_sup_name = Module.concat(__MODULE__, "TestInitTaskSup#{System.unique_integer([:positive])}")

        {:ok, task_sup} = Task.Supervisor.start_link(name: task_sup_name)

        on_exit(fn ->
          try do
            if pid = Process.whereis(orchestrator_name) do
              if Process.alive?(pid), do: GenServer.stop(pid)
            end
          catch
            :exit, _ -> :ok
          end

          try do
            if Process.alive?(task_sup), do: GenServer.stop(task_sup)
          catch
            :exit, _ -> :ok
          end
        end)

        assert {:ok, _orch_pid} =
                 Orchestrator.start_link(name: orchestrator_name, task_supervisor: task_sup_name)

        # Terminal workspace was cleaned at startup
        refute File.exists?(term_ws)

        # Active workspace was preserved and not cleaned
        assert File.dir?(active_ws)
        assert File.read!(Path.join(active_ws, "active.txt")) == "must survive\n"
      after
        File.rm_rf(test_root)
      end
    end

    test "5. active workspace is never cleaned by restart reconciliation" do
      test_root = test_root_path("active-workspace-retained")

      try do
        workspace_root = Path.join(test_root, "workspaces")
        File.mkdir_p!(workspace_root)

        active_issue = %Issue{
          id: "issue-active-5",
          identifier: "MT-ACTIVE-5",
          title: "Active task to retain",
          state: "In Progress",
          labels: [],
          dispatchable: true
        }

        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "memory",
          workspace_root: workspace_root
        )

        active_ws = Path.join(workspace_root, Workspace.workspace_key(active_issue))
        File.mkdir_p!(active_ws)
        workpad = Path.join(active_ws, "workpad.txt")
        File.write!(workpad, "pre-restart workpad contents\n")

        Application.put_env(:symphony_elixir, :memory_tracker_issues, [active_issue])

        state = %Orchestrator.State{task_supervisor: SymphonyElixir.TaskSupervisor}
        state = Orchestrator.run_startup_reconciliation_for_test(state)

        # Preserved byte-for-byte
        assert File.dir?(active_ws)
        assert File.read!(workpad) == "pre-restart workpad contents\n"
        assert MapSet.member?(state.resumed_issues, active_issue.id)
      after
        File.rm_rf(test_root)
      end
    end

    test "6. retry-state loss does not create duplicate dispatch under the documented local assumptions" do
      test_root = test_root_path("no-duplicate-dispatch")

      try do
        workspace_root = Path.join(test_root, "workspaces")
        File.mkdir_p!(workspace_root)

        issue = %Issue{
          id: "issue-no-dup",
          identifier: "MT-200",
          title: "No duplicate dispatch",
          state: "In Progress",
          labels: [],
          dispatchable: true
        }

        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "memory",
          workspace_root: workspace_root
        )

        Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

        # State starts with empty retry_attempts (representing loss of retry state after restart)
        state = %Orchestrator.State{
          task_supervisor: SymphonyElixir.TaskSupervisor,
          retry_attempts: %{},
          running: %{},
          claimed: MapSet.new()
        }

        state = Orchestrator.run_startup_reconciliation_for_test(state)

        # Initial dispatch candidacy check succeeds exactly once
        assert Orchestrator.should_dispatch_issue_for_test(issue, state)

        # Simulate issue dispatch into state.running and state.claimed
        state = %{
          state
          | running: Map.put(state.running, issue.id, %{
              pid: self(),
              ref: make_ref(),
              identifier: issue.identifier,
              issue: issue,
              resumed: true
            }),
            claimed: MapSet.put(state.claimed, issue.id),
            resumed_issues: MapSet.delete(state.resumed_issues, issue.id)
        }

        # Candidate is not dispatched again on subsequent evaluations
        refute Orchestrator.should_dispatch_issue_for_test(issue, state)
      after
        File.rm_rf(test_root)
      end
    end

    test "7. no lifecycle/review/Human Acceptance transition is fabricated" do
      test_root = test_root_path("no-fabricated-transitions")

      try do
        workspace_root = Path.join(test_root, "workspaces")
        File.mkdir_p!(workspace_root)

        issue = %Issue{
          id: "issue-steady-state",
          identifier: "MT-300",
          title: "Steady state task",
          state: "In Progress",
          labels: [],
          dispatchable: true
        }

        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "memory",
          workspace_root: workspace_root
        )

        Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

        state = %Orchestrator.State{task_supervisor: SymphonyElixir.TaskSupervisor}
        _state = Orchestrator.run_startup_reconciliation_for_test(state)

        # Tracker state remains exactly as before - untouched
        {:ok, [fetched_issue]} = Tracker.fetch_issues_by_ids([issue.id])
        assert fetched_issue.state == "In Progress"
        assert fetched_issue.id == issue.id
      after
        File.rm_rf(test_root)
      end
    end

    test "8. unowned surviving workspaces are observable as orphans and not automatically deleted" do
      test_root = test_root_path("orphan-visibility")

      try do
        workspace_root = Path.join(test_root, "workspaces")
        File.mkdir_p!(workspace_root)

        active_issue = %Issue{
          id: "issue-known",
          identifier: "MT-KNOWN",
          title: "Known active task",
          state: "In Progress",
          labels: [],
          dispatchable: true
        }

        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "memory",
          workspace_root: workspace_root
        )

        # Active workspace
        active_ws = Path.join(workspace_root, Workspace.workspace_key(active_issue))
        File.mkdir_p!(active_ws)

        # Unowned orphaned workspace
        orphan_ws = Path.join(workspace_root, "unrecognized_abandoned_workspace")
        File.mkdir_p!(orphan_ws)
        File.write!(Path.join(orphan_ws, "leftover.txt"), "leftover data\n")

        Application.put_env(:symphony_elixir, :memory_tracker_issues, [active_issue])

        state = %Orchestrator.State{task_supervisor: SymphonyElixir.TaskSupervisor}
        state = Orchestrator.run_startup_reconciliation_for_test(state)

        orphans = Orchestrator.orphaned_workspaces_for_test(state)
        assert Enum.any?(orphans, &String.ends_with?(&1, "unrecognized_abandoned_workspace"))

        # Orphan is NOT deleted
        assert File.dir?(orphan_ws)
        assert File.read!(Path.join(orphan_ws, "leftover.txt")) == "leftover data\n"
      after
        File.rm_rf(test_root)
      end
    end

    test "9. resumed running entry keeps MIC-224 resumed state and MIC-221 workspace_root" do
      test_root = test_root_path("resumed-carries-workspace-root")

      try do
        fixture = setup_source_fixture!(test_root)
        configure_workspace_workflow!(fixture)

        issue = %Issue{
          id: "issue-combined-metadata",
          identifier: "MT-104",
          title: "Combined metadata task",
          state: "In Progress",
          labels: ["repo:symphony-runtime"],
          dispatchable: true
        }

        File.mkdir_p!(fixture.workspace_root)
        workspace_path = Path.join(fixture.workspace_root, Workspace.workspace_key(issue))
        git!(["-C", fixture.source_repo, "worktree", "add", workspace_path, "-b", "symphony/MT-104"])

        Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

        state = %Orchestrator.State{task_supervisor: SymphonyElixir.TaskSupervisor}
        state = Orchestrator.run_startup_reconciliation_for_test(state)

        assert MapSet.member?(state.resumed_issues, issue.id)

        # The resumable workspace is the one that lives under the MIC-221 recorded root.
        recorded_root = Config.local_workspace_root()

        assert Path.expand(Path.join(recorded_root, Workspace.workspace_key(issue))) ==
                 Path.expand(workspace_path)

        assert {:ok, :resume, classified_path, %Route{target: "symphony-runtime"}} =
                 Workspace.classify_candidate(issue)

        assert Path.expand(classified_path) == Path.expand(workspace_path)

        # Running entry shape produced by spawn_issue_on_worker_host/6 for a resumed issue:
        # the resumed flag is known at spawn time, while MIC-221 workspace metadata arrives
        # later with the worker runtime info message.
        running_entry = %{
          pid: self(),
          ref: make_ref(),
          identifier: issue.identifier,
          issue: issue,
          worker_host: nil,
          workspace_path: nil,
          workspace_root: nil,
          session_id: nil,
          resumed: true,
          started_at: DateTime.utc_now()
        }

        state = %{state | running: Map.put(state.running, issue.id, running_entry)}

        assert {:noreply, updated_state} =
                 Orchestrator.handle_info(
                   {:worker_runtime_info, issue.id,
                    %{
                      worker_host: nil,
                      workspace_path: workspace_path,
                      workspace_root: recorded_root
                    }},
                   state
                 )

        # Both metadata families survive on the same running entry.
        assert %{
                 resumed: true,
                 workspace_root: ^recorded_root,
                 workspace_path: ^workspace_path
               } = updated_state.running[issue.id]
      after
        File.rm_rf(test_root)
      end
    end

    test "10. reconciliation mismatch cannot cause unsafe workspace cleanup" do
      test_root = test_root_path("mismatch-no-unsafe-cleanup")

      try do
        fixture_a = setup_source_fixture!(Path.join(test_root, "repo_a"))
        fixture_b = setup_source_fixture!(Path.join(test_root, "repo_b"))

        original_root = Path.join(test_root, "original_root")
        reloaded_root = Path.join(test_root, "reloaded_root")
        File.mkdir_p!(original_root)

        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "memory",
          workspace_root: original_root,
          tracker_active_states: ["In Progress"],
          tracker_terminal_states: ["Closed"],
          routing: %{
            target_label_prefix: "repo:",
            default_branch: "main",
            targets: %{
              "symphony-runtime" => %{source_path: fixture_a.source_repo, remote: fixture_a.remote_repo}
            }
          }
        )

        issue = %Issue{
          id: "issue-mismatch-cleanup",
          identifier: "MT-105",
          title: "Mismatch cleanup safety",
          state: "In Progress",
          labels: ["repo:symphony-runtime"],
          dispatchable: true
        }

        # Workspace on disk was prepared against Repo B while routing points at Repo A.
        mismatched_ws = Path.join(original_root, Workspace.workspace_key(issue))
        git!(["-C", fixture_b.source_repo, "worktree", "add", mismatched_ws, "-b", "symphony/MT-105"])
        critical_file = Path.join(mismatched_ws, "critical_workpad.md")
        File.write!(critical_file, "must survive cleanup\n")

        Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

        state = %Orchestrator.State{task_supervisor: SymphonyElixir.TaskSupervisor}
        state = Orchestrator.run_startup_reconciliation_for_test(state)

        assert Map.has_key?(state.blocked, issue.id)
        assert Path.expand(state.blocked[issue.id].workspace_path) == Path.expand(mismatched_ws)
        assert File.read!(critical_file) == "must survive cleanup\n"

        # A configuration reload moves the trusted root while the blocked entry still points
        # at the workspace that was recorded under the previous root.
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "memory",
          workspace_root: reloaded_root,
          tracker_active_states: ["In Progress"],
          tracker_terminal_states: ["Closed"]
        )

        closed_issue = %Issue{issue | state: "Closed"}
        state = Orchestrator.reconcile_blocked_issue_states_for_test([closed_issue], state)

        assert is_nil(Map.get(state.blocked, issue.id))
        refute MapSet.member?(state.claimed, issue.id)

        # Releasing the block routes through cleanup_issue_workspace/2 with the blocked entry,
        # and block_reconciliation_mismatch/3 records no MIC-221 workspace_root. The trusted
        # boundary therefore falls back to the currently configured root, which no longer
        # contains this workspace, so the recorded removal is refused and the directory survives.
        assert File.dir?(mismatched_ws)
        assert File.read!(critical_file) == "must survive cleanup\n"
      after
        File.rm_rf(test_root)
      end
    end

    test "11. reconciliation mismatch survives terminal transition when workspace root is unchanged" do
      test_root = test_root_path("mismatch-terminal-preserved")

      try do
        fixture_a = setup_source_fixture!(Path.join(test_root, "repo_a"))
        fixture_b = setup_source_fixture!(Path.join(test_root, "repo_b"))

        shared_root = Path.join(test_root, "shared_workspaces")
        File.mkdir_p!(shared_root)

        hook_marker = Path.join(test_root, "before_remove_marker")
        hook_marker_posix = String.replace(hook_marker, "\\", "/")
        File.rm_rf(hook_marker)

        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "memory",
          workspace_root: shared_root,
          tracker_active_states: ["In Progress"],
          tracker_terminal_states: ["Closed"],
          hook_before_remove: "touch \"#{hook_marker_posix}\"",
          routing: %{
            target_label_prefix: "repo:",
            default_branch: "main",
            targets: %{
              "symphony-runtime" => %{source_path: fixture_a.source_repo, remote: fixture_a.remote_repo}
            }
          }
        )

        issue = %Issue{
          id: "issue-mismatch-terminal",
          identifier: "MT-106",
          title: "Mismatch terminal preservation",
          state: "In Progress",
          labels: ["repo:symphony-runtime"],
          dispatchable: true
        }

        mismatched_ws = Path.join(shared_root, Workspace.workspace_key(issue))
        git!(["-C", fixture_b.source_repo, "worktree", "add", mismatched_ws, "-b", "symphony/MT-106"])
        sentinel = Path.join(mismatched_ws, "critical_workpad.md")
        File.write!(sentinel, "must survive terminal transition\n")

        Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

        state = %Orchestrator.State{task_supervisor: SymphonyElixir.TaskSupervisor}
        state = Orchestrator.run_startup_reconciliation_for_test(state)

        assert Map.has_key?(state.blocked, issue.id)
        assert MapSet.member?(state.claimed, issue.id)
        refute Orchestrator.should_dispatch_issue_for_test(issue, state)
        assert Path.expand(state.blocked[issue.id].workspace_path) == Path.expand(mismatched_ws)
        assert Path.expand(state.blocked[issue.id].workspace_root) == Path.expand(shared_root)
        assert state.blocked[issue.id].reconciliation_mismatch == true
        assert File.read!(sentinel) == "must survive terminal transition\n"

        # Configured root is unchanged: the trusted boundary still contains the
        # mismatched workspace, so only the explicit mismatch fence keeps it alive.
        assert Path.expand(Config.local_workspace_root()) == Path.expand(shared_root)

        closed_issue = %Issue{issue | state: "Closed"}
        state = Orchestrator.reconcile_blocked_issue_states_for_test([closed_issue], state)

        assert is_nil(Map.get(state.blocked, issue.id))
        refute MapSet.member?(state.claimed, issue.id)

        assert File.dir?(mismatched_ws)
        assert File.read!(sentinel) == "must survive terminal transition\n"
        refute File.exists?(hook_marker)
      after
        File.rm_rf(test_root)
      end
    end

    test "12. reconciliation mismatch survives orchestrator restart when issue becomes terminal" do
      test_root = test_root_path("mismatch-restart-terminal")

      try do
        fixture_a = setup_source_fixture!(Path.join(test_root, "repo_a"))
        fixture_b = setup_source_fixture!(Path.join(test_root, "repo_b"))

        shared_root = Path.join(test_root, "shared_workspaces")
        File.mkdir_p!(shared_root)

        hook_marker = Path.join(test_root, "before_remove_marker")
        hook_marker_posix = String.replace(hook_marker, "\\", "/")
        File.rm_rf(hook_marker)

        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "memory",
          workspace_root: shared_root,
          tracker_active_states: ["In Progress"],
          tracker_terminal_states: ["Closed"],
          hook_before_remove: "echo hook_ran > \"" <> hook_marker_posix <> "\"",
          routing: %{
            target_label_prefix: "repo:",
            default_branch: "main",
            targets: %{
              "symphony-runtime" => %{source_path: fixture_a.source_repo, remote: fixture_a.remote_repo}
            }
          }
        )

        issue = %Issue{
          id: "issue-mismatch-restart",
          identifier: "MT-107",
          title: "Mismatch restart preservation",
          state: "In Progress",
          labels: ["repo:symphony-runtime"],
          dispatchable: true
        }

        mismatched_ws = Path.join(shared_root, Workspace.workspace_key(issue))
        git!(["-C", fixture_b.source_repo, "worktree", "add", mismatched_ws, "-b", "symphony/MT-107"])
        sentinel = Path.join(mismatched_ws, "critical_workpad.md")
        File.write!(sentinel, "must survive restart and terminal transition\n")

        Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

        # Phase A: Start Orchestrator with issue active
        orch_name_1 = Module.concat(__MODULE__, "TestRestartOrch1_#{System.unique_integer([:positive])}")
        task_sup_name_1 = Module.concat(__MODULE__, "TestRestartTaskSup1_#{System.unique_integer([:positive])}")

        {:ok, task_sup_1} = Task.Supervisor.start_link(name: task_sup_name_1)

        assert {:ok, orch_pid_1} =
                 Orchestrator.start_link(name: orch_name_1, task_supervisor: task_sup_name_1)

        snapshot_1 = Orchestrator.snapshot(orch_name_1, 1_000)
        assert length(snapshot_1.blocked) == 1
        assert hd(snapshot_1.blocked).issue_id == issue.id
        assert snapshot_1.running == []
        assert File.dir?(mismatched_ws)
        assert File.read!(sentinel) == "must survive restart and terminal transition\n"
        refute File.exists?(hook_marker)

        # Stop the orchestrator
        GenServer.stop(orch_pid_1)
        GenServer.stop(task_sup_1)

        # Phase B: Issue becomes terminal in Tracker while Symphony is stopped
        closed_issue = %Issue{issue | state: "Closed", dispatchable: false}
        Application.put_env(:symphony_elixir, :memory_tracker_issues, [closed_issue])

        # Start a fresh Orchestrator process with configured root unchanged
        orch_name_2 = Module.concat(__MODULE__, "TestRestartOrch2_#{System.unique_integer([:positive])}")
        task_sup_name_2 = Module.concat(__MODULE__, "TestRestartTaskSup2_#{System.unique_integer([:positive])}")

        {:ok, task_sup_2} = Task.Supervisor.start_link(name: task_sup_name_2)

        on_exit(fn ->
          try do
            if pid = Process.whereis(orch_name_2), do: GenServer.stop(pid)
          catch
            :exit, _ -> :ok
          end

          try do
            if Process.alive?(task_sup_2), do: GenServer.stop(task_sup_2)
          catch
            :exit, _ -> :ok
          end
        end)

        assert {:ok, orch_pid_2} =
                 Orchestrator.start_link(name: orch_name_2, task_supervisor: task_sup_name_2)

        # Assert post-restart invariant:
        # Workspace and sentinel must still exist, before_remove marker must NOT exist
        assert File.dir?(mismatched_ws)
        assert File.read!(sentinel) == "must survive restart and terminal transition\n"
        refute File.exists?(hook_marker)

        GenServer.stop(orch_pid_2)
      after
        File.rm_rf(test_root)
      end
    end

    test "13. resumed_issues membership cannot leak across claims or override fresh workspace classification" do
      test_root = test_root_path("resumed-leak-guard")

      try do
        fixture = setup_source_fixture!(test_root)
        configure_workspace_workflow!(fixture)

        issue = %Issue{
          id: "issue-fresh-leak",
          identifier: "MT-108",
          title: "Fresh issue with leaked resumed marker",
          state: "In Progress",
          labels: ["repo:symphony-runtime"],
          dispatchable: true
        }

        # Workspace does NOT exist on disk -> candidate is fresh
        assert {:ok, :fresh, _workspace, %Route{target: "symphony-runtime"}} =
                 Workspace.classify_candidate(issue)

        task_sup_name = Module.concat(__MODULE__, "TestLeakTaskSup_#{System.unique_integer([:positive])}")
        {:ok, task_sup} = Task.Supervisor.start_link(name: task_sup_name)

        on_exit(fn ->
          try do
            if Process.alive?(task_sup), do: GenServer.stop(task_sup)
          catch
            :exit, _ -> :ok
          end
        end)

        state = %Orchestrator.State{
          task_supervisor: task_sup_name,
          resumed_issues: MapSet.new([issue.id])
        }

        # Dispatch fresh issue whose ID was erroneously present in state.resumed_issues
        state = Orchestrator.dispatch_issue_for_test(state, issue)

        # 1. Leaked resumed_issues entry was purged
        refute MapSet.member?(state.resumed_issues, issue.id)

        # 2. Running entry was dispatched as fresh, NOT resumed
        assert Map.has_key?(state.running, issue.id)
        assert state.running[issue.id].resumed == false

        # 3. release_issue_claim clears resumed_issues
        state_with_leak = %{state | resumed_issues: MapSet.put(state.resumed_issues, "leaked-issue-id")}
        state_cleared = Orchestrator.release_issue_claim_for_test(state_with_leak, "leaked-issue-id")
        refute MapSet.member?(state_cleared.resumed_issues, "leaked-issue-id")
      after
        File.rm_rf(test_root)
      end
    end
  end

  defp test_root_path(name) do
    Path.join(
      System.tmp_dir!(),
      "symphony-restart-reconcile-#{name}-#{System.unique_integer([:positive])}"
    )
  end

  defp setup_source_fixture!(test_root) do
    remote_repo = Path.join(test_root, "remote.git") |> String.replace("\\", "/")
    source_repo = Path.join(test_root, "source") |> String.replace("\\", "/")
    workspace_root = Path.join(test_root, "workspaces")

    git!(["init", "--bare", remote_repo])
    git!(["init", "-b", "main", source_repo])
    git!(["-C", source_repo, "config", "user.name", "Test User"])
    git!(["-C", source_repo, "config", "user.email", "test@example.com"])
    File.write!(Path.join(source_repo, "README.md"), "initial content\n")
    git!(["-C", source_repo, "add", "README.md"])
    git!(["-C", source_repo, "commit", "-m", "initial commit"])
    git!(["-C", source_repo, "remote", "add", "origin", remote_repo])
    git!(["-C", source_repo, "push", "-u", "origin", "main"])

    initial_commit = get_head_sha(source_repo)
    git!(["-C", remote_repo, "symbolic-ref", "HEAD", "refs/heads/main"])

    route = %Route{
      target: "symphony-runtime",
      source_path: source_repo,
      remote: remote_repo,
      default_branch: "main"
    }

    %{
      initial_commit: initial_commit,
      remote_repo: remote_repo,
      route: route,
      source_repo: source_repo,
      workspace_root: workspace_root
    }
  end

  defp configure_workspace_workflow!(fixture) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: fixture.workspace_root,
      routing: %{
        target_label_prefix: "repo:",
        default_branch: "main",
        targets: %{
          "symphony-runtime" => %{source_path: fixture.source_repo, remote: fixture.remote_repo}
        }
      }
    )
  end

  defp git!(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, code} -> flunk("git #{Enum.join(args, " ")} failed (#{code}): #{output}")
    end
  end

  defp get_head_sha(repo_path) do
    {sha, 0} = System.cmd("git", ["-c", "safe.directory=#{repo_path}", "-C", repo_path, "rev-parse", "HEAD"])
    String.trim(sha)
  end
end
