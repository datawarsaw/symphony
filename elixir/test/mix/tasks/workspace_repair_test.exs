defmodule Mix.Tasks.Symphony.WorkspaceRepairTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureIO

  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Workflow
  alias SymphonyElixir.Workspace
  alias SymphonyElixir.Workspace.Viability

  # The residue-creating part of the production after_create hook (WORKFLOW.md):
  # it refuses to run when the task branch already exists, which is exactly how a
  # stale branch makes every later dispatch fail.
  @after_create_hook """
  set -eu
  source_path="$SYMPHONY_REPOSITORY_SOURCE_PATH"
  default_branch="$SYMPHONY_REPOSITORY_DEFAULT_BRANCH"
  task_branch="symphony/$SYMPHONY_ISSUE_IDENTIFIER"
  if git -C "$source_path" show-ref --verify --quiet "refs/heads/$task_branch"; then
    exit 1
  fi
  git -C "$source_path" worktree add --no-checkout -b "$task_branch" "$PWD" "refs/remotes/origin/$default_branch"
  git -C "$PWD" checkout "$task_branch"
  """

  describe "mix symphony.workspace_repair" do
    test "repairs proven stale registration and contained branch, making re-dispatch work" do
      test_root = repair_root_path("stale-registration")
      identifier = "MT-301"

      try do
        fixture = setup_source_fixture!(test_root, hook_after_create: @after_create_hook)
        issue = build_issue(identifier)
        workspace_path = materialize_interrupted_workspace!(fixture, issue)

        # Audit case B: the workspace directory is removed by the current
        # cleanup semantics; registration and branch survive in the source.
        File.rm_rf!(workspace_path)
        assert {:ok, entry} = Viability.registration_entry(fixture.source_repo, workspace_path)
        assert entry.prunable? == true
        assert branch_sha(fixture.source_repo, "symphony/#{identifier}")

        run_repair!(identifier, fixture)

        refute Viability.registration_entry(fixture.source_repo, workspace_path) |> elem(1)
        refute branch_sha(fixture.source_repo, "symphony/#{identifier}")

        # The whole point: re-dispatch succeeds again.
        assert {:ok, recreated, %SymphonyElixir.RepositoryRouter.Route{}, _root} =
                 Workspace.create_for_issue_with_route(issue)

        # Content check tolerates autocrlf: checkout may write CRLF on Windows.
        assert File.read!(Path.join(recreated, "README.md")) |> String.trim_trailing() == "initial content"
        assert git!(["-C", recreated, "rev-parse", "--abbrev-ref", "HEAD"]) |> String.trim() == "symphony/#{identifier}"
      after
        File.rm_rf(test_root)
      end
    end

    test "repairs an interrupted-create worktree (never checked out) without losing evidence" do
      test_root = repair_root_path("interrupted-create")
      identifier = "MT-302"

      try do
        fixture = setup_source_fixture!(test_root, hook_after_create: @after_create_hook)
        issue = build_issue(identifier)
        workspace_path = materialize_interrupted_workspace!(fixture, issue)

        run_repair!(identifier, fixture)

        refute File.exists?(workspace_path)
        refute Viability.registration_entry(fixture.source_repo, workspace_path) |> elem(1)
        refute branch_sha(fixture.source_repo, "symphony/#{identifier}")

        assert {:ok, recreated, _route, _root} = Workspace.create_for_issue_with_route(issue)
        assert File.read!(Path.join(recreated, "app.txt")) |> String.trim_trailing() == "app content"
      after
        File.rm_rf(test_root)
      end
    end

    test "refuses to delete a branch holding unique evidence and preserves it" do
      test_root = repair_root_path("unique-evidence")
      identifier = "MT-303"
      task_branch = "symphony/#{identifier}"

      try do
        fixture = setup_source_fixture!(test_root)
        workspace_path = materialize_interrupted_workspace!(fixture, build_issue(identifier))

        # Give the branch a commit that is not in origin/main.
        base = git!(["-C", fixture.source_repo, "rev-parse", "refs/remotes/origin/main"]) |> String.trim()
        tree = git!(["-C", fixture.source_repo, "rev-parse", "refs/remotes/origin/main^{tree}"]) |> String.trim()

        unique_sha =
          git!(["-C", fixture.source_repo, "commit-tree", tree, "-p", base, "-m", "unique work"])
          |> String.trim()

        git!(["-C", fixture.source_repo, "update-ref", "refs/heads/#{task_branch}", unique_sha])
        File.rm_rf!(workspace_path)

        assert_raise(Mix.Error, ~r/unique evidence preserved/, fn ->
          run_repair!(identifier, fixture)
        end)

        assert branch_sha(fixture.source_repo, task_branch) == unique_sha
        # The registration was provably stale, so the prune was legitimate even
        # though the branch was preserved.
        refute Viability.registration_entry(fixture.source_repo, workspace_path) |> elem(1)
      after
        File.rm_rf(test_root)
      end
    end

    test "refuses when a live valid workspace exists" do
      test_root = repair_root_path("live-workspace")
      identifier = "MT-304"
      task_branch = "symphony/#{identifier}"

      try do
        fixture = setup_source_fixture!(test_root)
        issue = build_issue(identifier)
        workspace_path = Path.join(fixture.workspace_root, Workspace.workspace_key(issue))

        File.mkdir_p!(fixture.workspace_root)
        git!(["-C", fixture.source_repo, "worktree", "add", workspace_path, "-b", task_branch])

        assert_raise(Mix.Error, ~r/live valid workspace exists/, fn ->
          run_repair!(identifier, fixture)
        end)

        assert File.exists?(workspace_path)
        assert branch_sha(fixture.source_repo, task_branch)
        assert {:ok, entry} = Viability.registration_entry(fixture.source_repo, workspace_path)
        assert entry.prunable? == false
      after
        File.rm_rf(test_root)
      end
    end

    test "refuses ambiguous broken workspace (surviving directory, pruned registration)" do
      test_root = repair_root_path("ambiguous")
      identifier = "MT-305"

      try do
        fixture = setup_source_fixture!(test_root)
        issue = build_issue(identifier)
        workspace_path = materialize_interrupted_workspace!(fixture, issue)

        # The workspace's .git file now dangles: unclassifiable debris, not
        # proven residue.
        File.rm_rf!(Path.join([fixture.source_repo, ".git", "worktrees", Workspace.workspace_key(issue)]))

        assert_raise(Mix.Error, ~r/refusing to repair/, fn ->
          run_repair!(identifier, fixture)
        end)

        assert File.exists?(workspace_path)
        assert branch_sha(fixture.source_repo, "symphony/#{identifier}")
      after
        File.rm_rf(test_root)
      end
    end

    test "refuses when interrupted-create workspace holds untracked content" do
      test_root = repair_root_path("untracked-content")
      identifier = "MT-306"

      try do
        fixture = setup_source_fixture!(test_root)
        workspace_path = materialize_interrupted_workspace!(fixture, build_issue(identifier))

        # A pre-hardening worker may have run inside the empty worktree and left
        # untracked work behind: possible evidence, must not be destroyed.
        File.write!(Path.join(workspace_path, "survivor.txt"), "untracked worker output\n")

        assert_raise(Mix.Error, ~r/untracked files present/, fn ->
          run_repair!(identifier, fixture)
        end)

        assert File.read!(Path.join(workspace_path, "survivor.txt")) == "untracked worker output\n"
        assert branch_sha(fixture.source_repo, "symphony/#{identifier}")
      after
        File.rm_rf(test_root)
      end
    end

    test "completes with nothing to do when no residue exists" do
      test_root = repair_root_path("no-residue")
      identifier = "MT-307"

      try do
        fixture = setup_source_fixture!(test_root)

        assert {result, _output} = run_repair!(identifier, fixture)
        assert result == :ok
        refute branch_sha(fixture.source_repo, "symphony/#{identifier}")
      after
        File.rm_rf(test_root)
      end
    end
  end

  # --- fixtures -------------------------------------------------------------

  defp repair_root_path(name) do
    Path.join(System.tmp_dir!(), "symphony-workspace-repair-#{name}-#{System.unique_integer([:positive])}")
  end

  defp setup_source_fixture!(test_root, overrides \\ []) do
    remote_repo = Path.join(test_root, "remote.git") |> String.replace("\\", "/")
    source_repo = Path.join(test_root, "source") |> String.replace("\\", "/")
    workspace_root = Path.join(test_root, "workspaces")

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

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      routing: %{
        target_label_prefix: "repo:",
        default_branch: "main",
        targets: %{
          "symphony-runtime" => %{source_path: source_repo, remote: remote_repo}
        }
      },
      hook_after_create: Keyword.get(overrides, :hook_after_create)
    )

    %{source_repo: source_repo, remote_repo: remote_repo, workspace_root: workspace_root}
  end

  defp build_issue(identifier) do
    %Issue{
      id: "issue-#{identifier}",
      identifier: identifier,
      title: "Workspace repair probe",
      state: "In Progress",
      labels: ["repo:symphony-runtime"],
      dispatchable: true
    }
  end

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

  defp run_repair!(identifier, fixture) do
    output =
      capture_io(fn ->
        result = Mix.Task.rerun("symphony.workspace_repair", [identifier, "--source", fixture.source_repo])
        send(self(), {:repair_result, result})
      end)

    assert_received {:repair_result, result}
    {result, output}
  end

  defp branch_sha(source_repo, branch) do
    case System.cmd("git", ["-C", source_repo, "show-ref", "--verify", "refs/heads/#{branch}"], stderr_to_stdout: true) do
      {output, 0} -> output |> String.split() |> List.first()
      {_output, _code} -> nil
    end
  end

  defp git!(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, code} -> flunk("git #{Enum.join(args, " ")} failed (#{code}): #{output}")
    end
  end
end
