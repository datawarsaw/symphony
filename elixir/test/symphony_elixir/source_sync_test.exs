defmodule SymphonyElixir.SourceSyncTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RepositoryRouter.Route
  alias SymphonyElixir.SourceSync
  alias SymphonyElixir.Workspace

  test "case 1: already current passes without mutation" do
    with_source_fixture("already-current", fn fixture ->
      assert {:ok, :current} = SourceSync.sync(fixture.route)
      assert get_head_sha(fixture.source_repo) == fixture.initial_commit
      assert get_head_sha(fixture.source_repo) == get_remote_head_sha(fixture.source_repo, "main")
    end)
  end

  test "case 2: clean behind safely fast-forwards to exact remote SHA" do
    with_source_fixture("clean-behind", fn fixture ->
      new_remote_commit = advance_remote!(fixture, "second commit on remote\n", "feat: second commit")

      assert {:ok, :fast_forwarded} = SourceSync.sync(fixture.route)
      assert get_head_sha(fixture.source_repo) == new_remote_commit
      assert get_head_sha(fixture.source_repo) == get_remote_head_sha(fixture.source_repo, "main")
    end)
  end

  test "case 3: tracked dirty fails closed and prevents source update" do
    with_source_fixture("tracked-dirty", fn fixture ->
      advance_remote!(fixture, "second commit on remote\n", "feat: second commit")
      File.write!(Path.join(fixture.source_repo, "README.md"), "dirty tracked modification\n")

      assert {:error, :dirty_tracked} = SourceSync.sync(fixture.route)
      assert get_head_sha(fixture.source_repo) == fixture.initial_commit
    end)
  end

  test "case 4: staged dirty fails closed" do
    with_source_fixture("staged-dirty", fn fixture ->
      advance_remote!(fixture, "second commit on remote\n", "feat: second commit")
      File.write!(Path.join(fixture.source_repo, "README.md"), "staged modification\n")
      git!(["-C", fixture.source_repo, "add", "README.md"])

      assert {:error, :dirty_index} = SourceSync.sync(fixture.route)
      assert get_head_sha(fixture.source_repo) == fixture.initial_commit
    end)
  end

  test "case 5: unmerged conflict state fails closed" do
    with_source_fixture("unmerged-conflict", fn fixture ->
      create_unmerged_conflict!(fixture)

      assert {:error, :unmerged} = SourceSync.sync(fixture.route)
    end)
  end

  test "case 6: local ahead fails closed and never resets source backwards" do
    with_source_fixture("local-ahead", fn fixture ->
      local_commit = commit_local!(fixture, "local ahead content\n", "feat: local ahead")

      assert {:error, :local_ahead} = SourceSync.sync(fixture.route)
      assert get_head_sha(fixture.source_repo) == local_commit
    end)
  end

  test "case 7: diverged branch fails closed without automatic merge or rebase" do
    with_source_fixture("diverged-branch", fn fixture ->
      local_commit = commit_local!(fixture, "local diverged\n", "feat: local branch")
      advance_remote!(fixture, "remote diverged\n", "feat: remote branch")

      assert {:error, :diverged} = SourceSync.sync(fixture.route)
      assert get_head_sha(fixture.source_repo) == local_commit
    end)
  end

  test "case 8: unrelated untracked files are preserved and do not block fast-forward" do
    with_source_fixture("untracked-preserved", fn fixture ->
      untracked_path = Path.join([fixture.source_repo, "state", "mic-82-b1-checkpoint.json"])
      File.mkdir_p!(Path.dirname(untracked_path))
      File.write!(untracked_path, "preserve checkpoint\n")

      new_remote_commit = advance_remote!(fixture, "remote update\n", "feat: remote update")

      assert {:ok, :fast_forwarded} = SourceSync.sync(fixture.route)
      assert get_head_sha(fixture.source_repo) == new_remote_commit
      assert File.read!(untracked_path) == "preserve checkpoint\n"
    end)
  end

  test "case 9: remote failure and missing default branch fail closed with actionable reason" do
    with_source_fixture("remote-failure", fn fixture ->
      bad_remote_route = %{fixture.route | remote: "https://example.invalid/bad.git"}
      assert {:error, {:remote_unavailable, {:remote_mismatch, _, _}}} = SourceSync.sync(bad_remote_route)

      missing_branch_route = %{fixture.route | default_branch: "nonexistent-branch"}
      assert {:error, :default_branch_missing} = SourceSync.sync(missing_branch_route)
    end)
  end

  test "case 10: post-sync SHA verification gates task worktree creation in Workspace" do
    test_root = test_root_path("post-sync-workspace")

    try do
      fixture = setup_source_fixture!(test_root)
      configure_workspace_workflow!(fixture)

      new_remote_commit = advance_remote!(fixture, "remote sync\n", "feat: remote sync")

      issue = %Issue{id: "sync-1", identifier: "MIC-128", labels: ["repo:symphony-runtime"]}

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      assert get_head_sha(fixture.source_repo) == new_remote_commit
      assert {"symphony/MIC-128\n", 0} = System.cmd("git", ["-C", workspace, "branch", "--show-current"])
    after
      File.rm_rf(test_root)
    end
  end

  test "source refresh on retry preserves the existing implementation base and diff" do
    with_source_fixture("retry-diff", fn fixture ->
      configure_workspace_workflow!(fixture)
      issue = %Issue{id: "retry-sync", identifier: "MIC-167-RETRY", labels: ["repo:symphony-runtime"]}
      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      prepared_base = get_head_sha(workspace)
      File.write!(Path.join(workspace, "README.md"), "uncommitted implementation\n")
      File.write!(Path.join(workspace, "review-notes.md"), "test evidence\n")
      remote_base = advance_remote!(fixture, "new upstream\n", "upstream update")

      assert {:ok, ^workspace} = Workspace.create_for_issue(issue)
      assert get_head_sha(fixture.source_repo) == remote_base
      assert get_head_sha(workspace) == prepared_base
      assert File.read!(Path.join(workspace, "README.md")) == "uncommitted implementation\n"
      assert File.read!(Path.join(workspace, "review-notes.md")) == "test evidence\n"
      assert {:ok, provenance} = Workspace.capture_provenance(workspace, issue)
      assert provenance.prepared_base_commit == prepared_base
      assert :ok = Workspace.run_after_run_hook(workspace, issue)
      assert File.read!(Path.join(workspace, "README.md")) == "uncommitted implementation\n"
    end)
  end

  test "routed workspace reuse accepts a workspace created from the selected repository" do
    with_source_fixture("reuse-same-repo", fn fixture ->
      configure_workspace_workflow!(fixture)
      issue = %Issue{id: "reuse-same", identifier: "MIC-167-SAME-REPO", labels: ["repo:symphony-runtime"]}

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      File.write!(Path.join(workspace, "notes.md"), "keep me\n")

      assert {:ok, ^workspace} = Workspace.create_for_issue(issue)
      assert File.read!(Path.join(workspace, "notes.md")) == "keep me\n"
      assert git_common_dir(workspace) == git_common_dir(fixture.source_repo)
    end)
  end

  test "routed workspace reuse rejects a workspace created from another repository" do
    first_root = test_root_path("reuse-other-repo-a")
    second_root = test_root_path("reuse-other-repo-b")

    try do
      first = setup_source_fixture!(first_root)
      second = setup_source_fixture!(second_root)
      configure_workspace_workflow!(first)
      issue = %Issue{id: "reuse-other", identifier: "MIC-167-OTHER-REPO", labels: ["repo:symphony-runtime"]}

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      assert String.trim(File.read!(Path.join(workspace, "README.md"))) == "initial content"
      assert {"symphony/MIC-167-OTHER-REPO\n", 0} = System.cmd("git", ["-C", workspace, "branch", "--show-current"])

      configure_workspace_workflow!(second, workspace_root: first.workspace_root)

      assert {:error, {:workspace_repository_mismatch, "symphony-runtime", {:git_common_dir, _actual, _expected}}} =
               Workspace.create_for_issue(issue)

      assert String.trim(File.read!(Path.join(workspace, "README.md"))) == "initial content"
      assert {"symphony/MIC-167-OTHER-REPO\n", 0} = System.cmd("git", ["-C", workspace, "branch", "--show-current"])
    after
      File.rm_rf(first_root)
      File.rm_rf(second_root)
    end
  end

  test "routed workspace reuse rejects a reused path that is not a git repository" do
    with_source_fixture("reuse-non-git", fn fixture ->
      configure_workspace_workflow!(fixture)
      issue = %Issue{id: "reuse-non-git", identifier: "MIC-167-NON-GIT", labels: ["repo:symphony-runtime"]}
      workspace = Path.join(fixture.workspace_root, Workspace.workspace_key(issue))
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "stale.txt"), "stale\n")

      assert {:error, {:workspace_repository_mismatch, "symphony-runtime", :workspace_not_a_git_repository}} =
               Workspace.create_for_issue(issue)

      assert File.read!(Path.join(workspace, "stale.txt")) == "stale\n"
    end)
  end

  test "binary path sync/2 fast-forwards and defaults to the main branch when no options are given" do
    with_source_fixture("binary-path-ff", fn fixture ->
      new_remote_commit = advance_remote!(fixture, "remote content for binary path\n", "feat: binary path")

      assert {:ok, :fast_forwarded} = SourceSync.sync(fixture.source_repo)
      assert get_head_sha(fixture.source_repo) == new_remote_commit
      assert get_branch_sha(fixture.source_repo, "main") == new_remote_commit
      # The binary clause configures no expected remote, so origin verification is skipped.
      assert get_remote_head_sha(fixture.source_repo, "main") == new_remote_commit
    end)
  end

  test "binary path sync/2 classifies a directory that is not a git repository" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-source-sync-not-a-repo-#{System.unique_integer([:positive])}"
      )

    try do
      plain_dir = Path.join(test_root, "plain") |> String.replace("\\", "/")
      File.mkdir_p!(plain_dir)
      File.write!(Path.join(plain_dir, "notes.txt"), "not version controlled\n")

      assert {:error, :not_a_git_repository} = SourceSync.sync(plain_dir)
      assert SourceSync.reason_code_string(:not_a_git_repository) == "NOT_A_GIT_REPOSITORY"
      refute File.exists?(Path.join(plain_dir, ".git"))
      assert File.read!(Path.join(plain_dir, "notes.txt")) == "not version controlled\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "missing local default branch is created from origin without touching the checked-out branch" do
    with_source_fixture("create-default-branch", fn fixture ->
      git!(["-C", fixture.source_repo, "checkout", "-b", "topic"])
      git!(["-C", fixture.source_repo, "branch", "-D", "main"])
      topic_sha = get_head_sha(fixture.source_repo)
      new_remote_commit = advance_remote!(fixture, "remote seeding main\n", "feat: seed remote main")

      assert {:ok, :fast_forwarded} = SourceSync.sync(fixture.route)
      assert get_branch_sha(fixture.source_repo, "main") == new_remote_commit
      assert get_current_branch(fixture.source_repo) == "topic"
      assert get_head_sha(fixture.source_repo) == topic_sha
      assert get_branch_sha(fixture.source_repo, "topic") == topic_sha
      assert get_remote_head_sha(fixture.source_repo, "main") == new_remote_commit
    end)
  end

  test "fast-forward moves the default branch while another branch stays checked out" do
    with_source_fixture("off-branch-fast-forward", fn fixture ->
      git!(["-C", fixture.source_repo, "checkout", "-b", "topic"])
      File.write!(Path.join(fixture.source_repo, "topic_file.txt"), "topic work\n")
      git!(["-C", fixture.source_repo, "add", "topic_file.txt"])
      git!(["-C", fixture.source_repo, "commit", "-m", "feat: topic work"])
      topic_sha = get_head_sha(fixture.source_repo)
      new_remote_commit = advance_remote!(fixture, "remote update\n", "feat: remote update")

      assert {:ok, :fast_forwarded} = SourceSync.sync(fixture.route)
      assert get_branch_sha(fixture.source_repo, "main") == new_remote_commit
      assert get_current_branch(fixture.source_repo) == "topic"
      assert get_head_sha(fixture.source_repo) == topic_sha
      assert get_branch_sha(fixture.source_repo, "topic") == topic_sha
      assert File.read!(Path.join(fixture.source_repo, "topic_file.txt")) == "topic work\n"
      assert get_remote_head_sha(fixture.source_repo, "main") == new_remote_commit
    end)
  end

  test "diverged failure preserves the local commit and mutates nothing but the remote-tracking ref" do
    with_source_fixture("diverged-state-preserved", fn fixture ->
      local_commit = commit_local!(fixture, "local diverged content\n", "feat: local diverged")
      remote_commit = advance_remote!(fixture, "remote diverged content\n", "feat: remote diverged")

      assert {:error, :diverged} = SourceSync.sync(fixture.route)
      assert SourceSync.reason_code_string(:diverged) == "DIVERGED"
      assert get_head_sha(fixture.source_repo) == local_commit
      assert get_branch_sha(fixture.source_repo, "main") == local_commit
      # The fetch itself still happened before classification; only the remote-tracking ref moved.
      assert get_remote_head_sha(fixture.source_repo, "main") == remote_commit
      assert File.read!(Path.join(fixture.source_repo, "local_file.txt")) == "local diverged content\n"
      assert get_bare_branch_sha(fixture.remote_repo, "main") == remote_commit
    end)
  end

  test "unmerged index fails closed as unmerged and leaves the conflict state intact" do
    with_source_fixture("unmerged-state-preserved", fn fixture ->
      create_unmerged_conflict!(fixture)
      conflicted_head = get_head_sha(fixture.source_repo)

      assert {:error, :unmerged} = SourceSync.sync(fixture.route)
      assert SourceSync.reason_code_string(:unmerged) == "UNMERGED"
      assert get_head_sha(fixture.source_repo) == conflicted_head

      {unmerged_files, 0} =
        System.cmd("git", ["-c", "safe.directory=#{fixture.source_repo}", "-C", fixture.source_repo, "ls-files", "--unmerged"])

      assert unmerged_files =~ "conflict.txt"
    end)
  end

  test "fetch failure and remote mismatch fail closed as remote_unavailable without mutation" do
    with_source_fixture("fetch-failure", fn fixture ->
      mismatch_route = %{fixture.route | remote: "https://example.invalid/other.git"}

      assert {:error, {:remote_unavailable, {:remote_mismatch, _, _}}} = SourceSync.sync(mismatch_route)
      assert SourceSync.reason_code_string({:remote_unavailable, {:remote_mismatch, nil, nil}}) == "REMOTE_UNAVAILABLE"

      File.rm_rf!(fixture.remote_repo)

      assert {:error, :remote_unavailable} = SourceSync.sync(fixture.route)
      assert SourceSync.reason_code_string(:remote_unavailable) == "REMOTE_UNAVAILABLE"
      assert get_head_sha(fixture.source_repo) == fixture.initial_commit
      assert get_branch_sha(fixture.source_repo, "main") == fixture.initial_commit
    end)
  end

  test "default branch checked out in a linked worktree blocks the fast-forward and mutates nothing" do
    with_source_fixture("fast-forward-blocked-by-worktree", fn fixture ->
      advance_remote!(fixture, "remote r1\n", "feat: remote r1")
      git!(["-C", fixture.source_repo, "checkout", "-b", "topic"])
      topic_sha = get_head_sha(fixture.source_repo)
      main_holder = Path.join(fixture.test_root, "main-holder") |> String.replace("\\", "/")
      git!(["-C", fixture.source_repo, "worktree", "add", main_holder, "main"])
      second_remote_commit = advance_remote!(fixture, "remote r2\n", "feat: remote r2")

      assert {:error, :fast_forward_failed} = SourceSync.sync(fixture.route)
      assert SourceSync.reason_code_string(:fast_forward_failed) == "FAST_FORWARD_FAILED"
      # The refused ref update leaves local main exactly where it started,
      # still two commits behind the remote.
      assert get_branch_sha(fixture.source_repo, "main") == fixture.initial_commit
      assert get_current_branch(fixture.source_repo) == "topic"
      assert get_head_sha(fixture.source_repo) == topic_sha
      assert get_remote_head_sha(fixture.source_repo, "main") == second_remote_commit
    end)
  end

  test "binary path sync/2 classifies a missing remote default branch" do
    with_source_fixture("binary-path-missing-branch", fn fixture ->
      assert {:error, :default_branch_missing} = SourceSync.sync(fixture.source_repo, default_branch: "ghost-branch")
      assert SourceSync.reason_code_string(:default_branch_missing) == "DEFAULT_BRANCH_MISSING"
      assert get_head_sha(fixture.source_repo) == fixture.initial_commit
    end)
  end

  test "reason_code_string exposes the stable uppercase mapping contract" do
    # Literal mapping contract for callers such as Workspace logging and
    # receipts. Every classification that ordinary repository states can
    # produce is additionally asserted from a real sync result in the
    # failure-state tests above; :head_verification_failed is only reachable
    # through git states inconsistent with the checks that precede it, so the
    # mapping arm is exercised directly here.
    mappings = [
      {:current, "CURRENT"},
      {:fast_forwarded, "FAST_FORWARDED"},
      {:dirty_tracked, "DIRTY_TRACKED"},
      {:dirty_index, "DIRTY_INDEX"},
      {:unmerged, "UNMERGED"},
      {:local_ahead, "LOCAL_AHEAD"},
      {:diverged, "DIVERGED"},
      {:remote_unavailable, "REMOTE_UNAVAILABLE"},
      {:default_branch_missing, "DEFAULT_BRANCH_MISSING"},
      {:fast_forward_failed, "FAST_FORWARD_FAILED"},
      {:head_verification_failed, "HEAD_VERIFICATION_FAILED"},
      {:not_a_git_repository, "NOT_A_GIT_REPOSITORY"}
    ]

    Enum.each(mappings, fn {reason, expected} ->
      assert SourceSync.reason_code_string(reason) == expected
      assert SourceSync.reason_code_string({reason, %{details: 1}}) == expected
    end)

    # The tuple arm keeps only atom reasons; anything else falls through to the
    # uppercase escape hatch for unrecognized classifications.
    assert SourceSync.reason_code_string(:unrecognized_future_code) == "UNRECOGNIZED_FUTURE_CODE"
  end

  defp with_source_fixture(name, fun) do
    test_root = test_root_path(name)

    try do
      fixture = setup_source_fixture!(test_root)
      fun.(fixture)
    after
      File.rm_rf(test_root)
    end
  end

  defp test_root_path(name) do
    Path.join(
      System.tmp_dir!(),
      "symphony-source-sync-#{name}-#{System.unique_integer([:positive])}"
    )
  end

  defp setup_source_fixture!(test_root) do
    remote_repo = Path.join(test_root, "remote.git") |> String.replace("\\", "/")
    source_repo = Path.join(test_root, "source") |> String.replace("\\", "/")
    publisher_repo = Path.join(test_root, "publisher") |> String.replace("\\", "/")
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

    git!(["clone", remote_repo, publisher_repo])
    git!(["-C", publisher_repo, "config", "user.name", "Publisher User"])
    git!(["-C", publisher_repo, "config", "user.email", "publisher@example.com"])

    route = %Route{
      target: "symphony-runtime",
      source_path: source_repo,
      remote: remote_repo,
      default_branch: "main"
    }

    %{
      initial_commit: initial_commit,
      publisher_repo: publisher_repo,
      remote_repo: remote_repo,
      route: route,
      source_repo: source_repo,
      test_root: test_root,
      workspace_root: workspace_root
    }
  end

  defp advance_remote!(fixture, file_content, commit_message) do
    File.write!(Path.join(fixture.publisher_repo, "README.md"), file_content)
    git!(["-C", fixture.publisher_repo, "add", "README.md"])
    git!(["-C", fixture.publisher_repo, "commit", "-m", commit_message])
    git!(["-C", fixture.publisher_repo, "push", "origin", "main"])
    get_head_sha(fixture.publisher_repo)
  end

  defp commit_local!(fixture, file_content, commit_message) do
    File.write!(Path.join(fixture.source_repo, "local_file.txt"), file_content)
    git!(["-C", fixture.source_repo, "add", "local_file.txt"])
    git!(["-C", fixture.source_repo, "commit", "-m", commit_message])
    get_head_sha(fixture.source_repo)
  end

  defp create_unmerged_conflict!(fixture) do
    File.write!(Path.join(fixture.source_repo, "conflict.txt"), "base\n")
    git!(["-C", fixture.source_repo, "add", "conflict.txt"])
    git!(["-C", fixture.source_repo, "commit", "-m", "base conflict"])
    git!(["-C", fixture.source_repo, "push", "origin", "main"])
    git!(["-C", fixture.source_repo, "branch", "feature-conflict"])

    File.write!(Path.join(fixture.source_repo, "conflict.txt"), "source change\n")
    git!(["-C", fixture.source_repo, "commit", "-am", "source branch"])

    git!(["-C", fixture.source_repo, "checkout", "feature-conflict"])
    File.write!(Path.join(fixture.source_repo, "conflict.txt"), "feature change\n")
    git!(["-C", fixture.source_repo, "commit", "-am", "feature branch"])

    git!(["-C", fixture.source_repo, "checkout", "main"])
    System.cmd("git", ["-C", fixture.source_repo, "merge", "feature-conflict"])
    :ok
  end

  defp configure_workspace_workflow!(fixture, opts \\ []) do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Keyword.get(opts, :workspace_root, fixture.workspace_root),
      routing: %{
        target_label_prefix: "repo:",
        default_branch: "main",
        targets: %{
          "symphony-runtime" => %{source_path: fixture.source_repo, remote: fixture.remote_repo}
        }
      },
      hook_after_create: """
      set -eu
      task_branch="symphony/$SYMPHONY_ISSUE_IDENTIFIER"
      git -C "$SYMPHONY_REPOSITORY_SOURCE_PATH" worktree add --no-checkout -b "$task_branch" "$PWD" "refs/remotes/origin/$SYMPHONY_REPOSITORY_DEFAULT_BRANCH"
      git -C "$PWD" checkout "$task_branch"
      """
    )
  end

  defp get_head_sha(repo_path) do
    {sha, 0} = System.cmd("git", ["-c", "safe.directory=#{repo_path}", "-C", repo_path, "rev-parse", "HEAD"])
    String.trim(sha)
  end

  defp get_branch_sha(repo_path, branch) do
    {sha, 0} =
      System.cmd("git", [
        "-c",
        "safe.directory=#{repo_path}",
        "-C",
        repo_path,
        "rev-parse",
        "refs/heads/#{branch}"
      ])

    String.trim(sha)
  end

  defp get_bare_branch_sha(repo_path, branch) do
    {sha, 0} = System.cmd("git", ["-C", repo_path, "rev-parse", branch])
    String.trim(sha)
  end

  defp get_current_branch(repo_path) do
    {branch, 0} =
      System.cmd("git", ["-c", "safe.directory=#{repo_path}", "-C", repo_path, "branch", "--show-current"])

    String.trim(branch)
  end

  defp git_common_dir(repo_path) do
    {output, 0} =
      System.cmd("git", [
        "-c",
        "safe.directory=#{repo_path}",
        "-C",
        repo_path,
        "rev-parse",
        "--path-format=absolute",
        "--git-common-dir"
      ])

    output |> String.trim() |> String.replace("\\", "/") |> String.downcase()
  end

  defp get_remote_head_sha(repo_path, branch) do
    {sha, 0} =
      System.cmd("git", [
        "-c",
        "safe.directory=#{repo_path}",
        "-C",
        repo_path,
        "rev-parse",
        "refs/remotes/origin/#{branch}"
      ])

    String.trim(sha)
  end

  defp git!(args) do
    case System.cmd("git", args) do
      {_output, 0} -> :ok
      {output, status} -> raise "git #{Enum.join(args, " ")} failed with #{status}: #{output}"
    end
  end
end
