defmodule SymphonyElixir.WorkspaceViabilityTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.RepositoryRouter.Route
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Workflow
  alias SymphonyElixir.Workspace
  alias SymphonyElixir.Workspace.Viability

  @task_branch "symphony/MT-101"

  describe "Viability.verify/1" do
    test "clean checked-out worktree is viable" do
      test_root = viability_root_path("clean")

      try do
        source = git_source_fixture!(test_root)
        worktree = Path.join(test_root, "ws")

        git!(["-C", source, "worktree", "add", worktree, "-b", @task_branch])

        assert Viability.verify(worktree) == :ok
      after
        File.rm_rf(test_root)
      end
    end

    test "dirty worktree with modified, untracked, and staged content stays viable" do
      test_root = viability_root_path("dirty")

      try do
        source = git_source_fixture!(test_root)
        worktree = Path.join(test_root, "ws")

        git!(["-C", source, "worktree", "add", worktree, "-b", @task_branch])

        # Legitimate unfinished coding work: modified tracked file, untracked
        # worker file, and a staged addition. None of this is breakage.
        File.write!(Path.join(worktree, "README.md"), "modified content\n")
        File.write!(Path.join(worktree, "workpad.md"), "worker scratch notes\n")
        git!(["-C", worktree, "add", "workpad.md"])

        assert Viability.verify(worktree) == :ok
      after
        File.rm_rf(test_root)
      end
    end

    test "worktree whose checkout never ran is not viable (:never_checked_out)" do
      test_root = viability_root_path("never-checked-out")

      try do
        source = git_source_fixture!(test_root)
        worktree = Path.join(test_root, "ws")

        # Interrupted create: registered and branched, crash before checkout.
        git!(["-C", source, "worktree", "add", "--no-checkout", "-b", @task_branch, worktree, "refs/remotes/origin/main"])

        assert {:error, {:workspace_not_viable, ^worktree, :never_checked_out}} = Viability.verify(worktree)
      after
        File.rm_rf(test_root)
      end
    end

    test "worktree whose registration was removed underneath it is not viable (:head_unresolvable)" do
      test_root = viability_root_path("dangling-gitdir")

      try do
        source = git_source_fixture!(test_root)
        worktree = Path.join(test_root, "ws")

        git!(["-C", source, "worktree", "add", "--no-checkout", "-b", @task_branch, worktree, "refs/remotes/origin/main"])
        File.rm_rf!(worktree_registration_dir(source, worktree))

        assert {:error, {:workspace_not_viable, ^worktree, :head_unresolvable}} = Viability.verify(worktree)
      after
        File.rm_rf(test_root)
      end
    end

    test "worktree with damaged HEAD metadata is not viable (:head_unresolvable)" do
      test_root = viability_root_path("missing-head")

      try do
        source = git_source_fixture!(test_root)
        worktree = Path.join(test_root, "ws")

        git!(["-C", source, "worktree", "add", worktree, "-b", @task_branch])
        File.rm!(worktree_registration_dir(source, worktree) |> Path.join("HEAD"))

        assert {:error, {:workspace_not_viable, ^worktree, :head_unresolvable}} = Viability.verify(worktree)
      after
        File.rm_rf(test_root)
      end
    end

    test "worktree with corrupt index is not viable (:index_unreadable)" do
      test_root = viability_root_path("corrupt-index")

      try do
        source = git_source_fixture!(test_root)
        worktree = Path.join(test_root, "ws")

        git!(["-C", source, "worktree", "add", worktree, "-b", @task_branch])
        File.write!(Path.join([worktree_registration_dir(source, worktree), "index"]), "garbage")

        assert {:error, {:workspace_not_viable, ^worktree, :index_unreadable}} = Viability.verify(worktree)
      after
        File.rm_rf(test_root)
      end
    end

    test "worktree with partially populated index is not viable (:incomplete_index)" do
      test_root = viability_root_path("partial-index")

      try do
        source = git_source_fixture!(test_root)
        worktree = Path.join(test_root, "ws")

        git!(["-C", source, "worktree", "add", worktree, "-b", @task_branch])
        git!(["-C", worktree, "rm", "--cached", "-q", "README.md"])

        assert {:error, {:workspace_not_viable, ^worktree, :incomplete_index}} = Viability.verify(worktree)
      after
        File.rm_rf(test_root)
      end
    end

    test "empty HEAD tree with empty index cannot be proven broken and stays viable" do
      test_root = viability_root_path("empty-tree")

      try do
        repo = Path.join(test_root, "empty-source")
        worktree = Path.join(test_root, "ws")

        git!(["init", "-b", "main", repo])
        git!(["-C", repo, "config", "user.name", "Test User"])
        git!(["-C", repo, "config", "user.email", "test@example.com"])
        git!(["-C", repo, "commit", "--allow-empty", "-m", "empty root"])

        git!(["-C", repo, "worktree", "add", "--no-checkout", "-b", @task_branch, worktree, "main"])
        git!(["-C", worktree, "checkout", "-q", @task_branch])

        assert Viability.verify(worktree) == :ok
      after
        File.rm_rf(test_root)
      end
    end

    test "registration_entry/2 reports stale entries and nil for unregistered paths" do
      test_root = viability_root_path("registration")

      try do
        source = git_source_fixture!(test_root)
        worktree = Path.join(test_root, "ws")

        assert {:ok, nil} = Viability.registration_entry(source, worktree)

        git!(["-C", source, "worktree", "add", "--no-checkout", "-b", @task_branch, worktree, "refs/remotes/origin/main"])

        assert {:ok, nil} = Viability.registration_entry(source, Path.join(test_root, "other"))

        File.rm_rf!(worktree)

        assert {:ok, entry} = Viability.registration_entry(source, worktree)
        assert entry.prunable? == true
        assert entry.branch == "refs/heads/#{@task_branch}"
        assert entry.prunable_reason
      after
        File.rm_rf(test_root)
      end
    end
  end

  describe "classification gate" do
    test "fresh workspace classifies :fresh" do
      test_root = classification_root_path("fresh")

      try do
        fixture = setup_source_fixture!(test_root)
        configure_workspace_workflow!(fixture)
        issue = build_issue("MT-201")

        assert {:ok, :fresh, _workspace, %Route{target: "symphony-runtime"}} =
                 Workspace.classify_candidate(issue)
      after
        File.rm_rf(test_root)
      end
    end

    test "valid dirty existing workspace classifies :resume" do
      test_root = classification_root_path("resume-dirty")

      try do
        fixture = setup_source_fixture!(test_root)
        configure_workspace_workflow!(fixture)
        issue = build_issue("MT-201")

        workspace_path = Path.join(fixture.workspace_root, Workspace.workspace_key(issue))
        File.mkdir_p!(fixture.workspace_root)
        git!(["-C", fixture.source_repo, "worktree", "add", workspace_path, "-b", @task_branch])
        File.write!(Path.join(workspace_path, "README.md"), "modified\n")
        File.write!(Path.join(workspace_path, "worker-notes.md"), "untracked\n")

        {:ok, canonical_path} = PathSafety.canonicalize(workspace_path)

        assert {:ok, :resume, ^canonical_path, %Route{}} = Workspace.classify_candidate(issue)
      after
        File.rm_rf(test_root)
      end
    end

    test "foreign repository fails closed with identity mismatch" do
      test_root = classification_root_path("foreign")

      try do
        fixture_a = setup_source_fixture!(Path.join(test_root, "a"))
        fixture_b = setup_source_fixture!(Path.join(test_root, "b"))
        configure_workspace_workflow!(fixture_a)
        issue = build_issue("MT-201")

        # Materialize the workspace as a worktree of a different repository.
        workspace_path = Path.join(fixture_a.workspace_root, Workspace.workspace_key(issue))
        File.mkdir_p!(fixture_a.workspace_root)
        git!(["-C", fixture_b.source_repo, "worktree", "add", workspace_path, "-b", @task_branch])

        assert {:error, {:workspace_repository_mismatch, "symphony-runtime", _details}} =
                 Workspace.classify_candidate(issue)
      after
        File.rm_rf(test_root)
      end
    end

    test "interrupted create (empty --no-checkout worktree) no longer classifies as resumable" do
      test_root = classification_root_path("interrupted-create")

      try do
        fixture = setup_source_fixture!(test_root)
        configure_workspace_workflow!(fixture)
        issue = build_issue("MT-201")

        workspace_path = materialize_interrupted_workspace!(fixture, issue)

        {:ok, canonical_path} = PathSafety.canonicalize(workspace_path)

        assert {:error, {:workspace_not_viable, ^canonical_path, :never_checked_out}} =
                 Workspace.classify_candidate(issue)
      after
        File.rm_rf(test_root)
      end
    end

    test "gutted worktree (registration pruned under a surviving directory) fails closed" do
      test_root = classification_root_path("gutted")

      try do
        fixture = setup_source_fixture!(test_root)
        configure_workspace_workflow!(fixture)
        issue = build_issue("MT-201")

        workspace_path = materialize_interrupted_workspace!(fixture, issue)
        File.rm_rf!(worktree_registration_dir(fixture.source_repo, workspace_path))

        # A workspace whose registration is gone is not even provably a Git
        # repository, so the identity gate rejects it before viability runs.
        # Either way the classification fails closed.
        assert {:error, {:workspace_repository_mismatch, "symphony-runtime", :workspace_not_a_git_repository}} =
                 Workspace.classify_candidate(issue)
      after
        File.rm_rf(test_root)
      end
    end

    test "reused-workspace creation gate refuses to hand a broken worktree to a worker" do
      test_root = classification_root_path("create-gate")

      try do
        fixture = setup_source_fixture!(test_root)
        configure_workspace_workflow!(fixture)
        issue = build_issue("MT-201")

        workspace_path = materialize_interrupted_workspace!(fixture, issue)

        {:ok, canonical_path} = PathSafety.canonicalize(workspace_path)

        assert {:error, {:workspace_not_viable, ^canonical_path, :never_checked_out}} =
                 Workspace.create_for_issue_with_route(issue)

        # Fail closed with the evidence preserved for the repair command.
        assert File.exists?(workspace_path)
      after
        File.rm_rf(test_root)
      end
    end
  end

  describe "startup reconciliation" do
    test "non-viable workspace blocks the issue fail-closed and preserves evidence" do
      test_root = classification_root_path("reconcile-blocked")

      try do
        fixture = setup_source_fixture!(test_root)
        configure_workspace_workflow!(fixture)
        issue = build_issue("MT-201")

        workspace_path = materialize_interrupted_workspace!(fixture, issue)

        Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

        state = %Orchestrator.State{task_supervisor: SymphonyElixir.TaskSupervisor}
        state = Orchestrator.run_startup_reconciliation_for_test(state)

        blocked_entry = state.blocked[issue.id]
        assert blocked_entry.viability_error == true
        assert match?({:error, {:workspace_not_viable, _path, :never_checked_out}}, blocked_entry.error)
        refute MapSet.member?(state.resumed_issues, issue.id)

        # The broken workspace is evidence for the repair command: it survives.
        assert File.exists?(workspace_path)
      after
        File.rm_rf(test_root)
      end
    end
  end

  # --- fixtures -------------------------------------------------------------

  defp viability_root_path(name) do
    Path.join(System.tmp_dir!(), "symphony-viability-#{name}-#{System.unique_integer([:positive])}")
  end

  defp classification_root_path(name) do
    Path.join(System.tmp_dir!(), "symphony-classify-#{name}-#{System.unique_integer([:positive])}")
  end

  # A source repository with a bare origin and `refs/remotes/origin/main` in place,
  # mirroring the state the real `after_create` hook prerequisites expect.
  defp git_source_fixture!(test_root) do
    remote_repo = Path.join(test_root, "remote.git") |> String.replace("\\", "/")
    source_repo = Path.join(test_root, "source") |> String.replace("\\", "/")

    git!(["init", "--bare", remote_repo])
    git!(["init", "-b", "main", source_repo])
    git!(["-C", source_repo, "config", "user.name", "Test User"])
    git!(["-C", source_repo, "config", "user.email", "test@example.com"])
    File.write!(Path.join(source_repo, "README.md"), "initial content\n")
    File.write!(Path.join(source_repo, "app.txt"), "app content\n")
    git!(["-C", source_repo, "add", "README.md", "app.txt"])
    git!(["-C", source_repo, "commit", "-m", "initial commit"])
    git!(["-C", source_repo, "remote", "add", "origin", remote_repo])
    git!(["-C", source_repo, "push", "-u", "origin", "main"])

    source_repo
  end

  defp setup_source_fixture!(test_root) do
    source_repo = git_source_fixture!(Path.join(test_root, "repo"))

    %{
      source_repo: source_repo,
      remote_repo: git_remote_of(source_repo),
      workspace_root: Path.join(test_root, "workspaces")
    }
  end

  defp git_remote_of(source_repo) do
    {output, 0} = System.cmd("git", ["-C", source_repo, "remote", "get-url", "origin"])
    String.trim(output)
  end

  defp configure_workspace_workflow!(fixture, overrides \\ []) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [
          tracker_kind: "memory",
          workspace_root: fixture.workspace_root,
          routing: %{
            target_label_prefix: "repo:",
            default_branch: "main",
            targets: %{
              "symphony-runtime" => %{source_path: fixture.source_repo, remote: fixture.remote_repo}
            }
          }
        ],
        overrides
      )
    )
  end

  defp build_issue(identifier) do
    %Issue{
      id: "issue-#{identifier}",
      identifier: identifier,
      title: "Workspace viability probe",
      state: "In Progress",
      labels: ["repo:symphony-runtime"],
      dispatchable: true
    }
  end

  # Reproduces the audit's interrupted creation: ensure_workspace made the empty
  # directory, the after_create hook registered the worktree with --no-checkout,
  # and the process died before checkout.
  defp materialize_interrupted_workspace!(fixture, issue) do
    workspace_path = Path.join(fixture.workspace_root, Workspace.workspace_key(issue))
    File.mkdir_p!(fixture.workspace_root)
    File.mkdir_p!(workspace_path)

    git!([
      "-C",
      fixture.source_repo,
      "worktree",
      "add",
      "--no-checkout",
      "-b",
      "symphony/#{issue.identifier}",
      workspace_path,
      "refs/remotes/origin/main"
    ])

    workspace_path
  end

  defp worktree_registration_dir(source_repo, worktree) do
    basename = Path.basename(worktree)
    registration_root = Path.join([source_repo, ".git", "worktrees"])

    if File.dir?(Path.join(registration_root, basename)) do
      Path.join(registration_root, basename)
    else
      flunk("no worktree registration found for #{worktree}")
    end
  end

  defp git!(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, code} -> flunk("git #{Enum.join(args, " ")} failed (#{code}): #{output}")
    end
  end
end
