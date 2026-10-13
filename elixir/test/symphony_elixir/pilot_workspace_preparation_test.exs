defmodule SymphonyElixir.PilotWorkspacePreparationTest do
  @moduledoc """
  Regression coverage for the PILOT-WORKSPACE-FIX defect.

  PILOT-LIVE-1-R2 dispatched MIC-306 against a routed repository target whose
  workflow defined no hooks.after_create. Workspace.ensure_workspace/3 then
  produced an EMPTY workspace directory, the provenance gate failed closed with
  {:workspace_provenance_failed, :git_read_failed}, and the single automatic
  in-envelope retry failed at the reuse identity gate with
  :workspace_not_a_git_repository. No worker ever launched.

  These tests pin both halves of that contract with real Git repositories in a
  temp root and no network access:

    * no preparation hook reproduces the frozen failure signatures, and
    * the pilot after_create hook prepares a routed workspace that passes the
      existing provenance, Git-identity and viability gates and stays resumable
      on reuse (the path the automatic retry takes).

  The hook text below mirrors hooks.after_create in the pilot workflow file
  (C:/AI/symphony-workspaces/pilot-m1-opencode/config/WORKFLOW.md), which is the
  tracked production hook (elixir/WORKFLOW.md) minus its Elixir dependency step.
  The pilot-local offline check
  (evidence/PILOT-WORKSPACE-FIX/offline-workspace-preparation-check.exs) loads the
  deployed workflow file itself and asserts the same guards, so configuration
  drift between the two is detected there.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Tracker.Issue

  @target "symphony-pilot-target"

  @after_create """
  set -eu
  : "${SYMPHONY_REPOSITORY_TARGET:?missing repository target}"
  : "${SYMPHONY_REPOSITORY_SOURCE_PATH:?missing repository source path}"
  : "${SYMPHONY_REPOSITORY_DEFAULT_BRANCH:?missing repository default branch}"
  source_path="$SYMPHONY_REPOSITORY_SOURCE_PATH"
  default_branch="$SYMPHONY_REPOSITORY_DEFAULT_BRANCH"
  task_branch="symphony/$SYMPHONY_ISSUE_IDENTIFIER"
  test -d "$source_path/.git"
  git -C "$source_path" diff --quiet
  git -C "$source_path" diff --cached --quiet
  test -z "$(git -C "$source_path" ls-files --unmerged)"
  if [ -n "${SYMPHONY_REPOSITORY_REMOTE:-}" ]; then
    test "$(git -C "$source_path" remote get-url origin)" = "$SYMPHONY_REPOSITORY_REMOTE"
  fi
  git -C "$source_path" fetch --prune origin
  git -C "$source_path" show-ref --verify --quiet "refs/remotes/origin/$default_branch"
  if git -C "$source_path" show-ref --verify --quiet "refs/heads/$task_branch"; then
    exit 1
  fi
  if git -C "$source_path" show-ref --verify --quiet "refs/remotes/origin/$task_branch"; then
    exit 1
  fi
  git -C "$source_path" worktree add --no-checkout -b "$task_branch" "$PWD" "refs/remotes/origin/$default_branch"
  git -C "$PWD" checkout "$task_branch"
  """

  setup do
    fixture = build_fixture!(Path.join(System.tmp_dir!(), "symphony-pilot-prep-#{System.unique_integer([:positive])}"))
    on_exit(fn -> File.rm_rf(fixture.root) end)

    {:ok, fixture: fixture}
  end

  test "a routed target without a preparation hook reproduces the PILOT-LIVE-1-R2 failure", %{fixture: fixture} do
    issue = issue("MIC-PREP-NOHOOK")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: fixture.workspace_root,
      routing: routing(fixture)
    )

    assert {:ok, workspace, route, _root} =
             Workspace.create_for_issue_with_route(issue, nil, workspace_root: fixture.workspace_root)

    assert route.target == @target
    assert File.dir?(workspace)
    assert File.ls!(workspace) == []

    assert {:error, {:workspace_provenance_failed, :git_read_failed}} =
             Workspace.capture_provenance(workspace, issue, nil, route, workspace_root: fixture.workspace_root)

    assert {:error, {:workspace_repository_mismatch, @target, :workspace_not_a_git_repository}} =
             Workspace.classify_candidate(issue, nil, workspace_root: fixture.workspace_root)
  end

  test "the pilot after_create hook prepares a routed workspace that passes every gate", %{fixture: fixture} do
    issue = issue("MIC-PREP-HOOK")
    task_branch = "symphony/" <> issue.identifier

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: fixture.workspace_root,
      routing: routing(fixture),
      hook_after_create: @after_create
    )

    assert {:ok, workspace, route, recorded_root} =
             Workspace.create_for_issue_with_route(issue, nil, workspace_root: fixture.workspace_root)

    assert recorded_root == fixture.workspace_root
    assert Path.basename(workspace) == issue.identifier
    assert File.exists?(Path.join(workspace, ".git"))
    assert File.regular?(Path.join(workspace, "README.md"))
    assert git_output!(workspace, ["rev-parse", "--verify", "HEAD^{commit}"]) == fixture.head
    assert git_output!(workspace, ["branch", "--show-current"]) == task_branch
    assert git_output!(workspace, ["remote", "get-url", "origin"]) == fixture.origin
    assert git_output!(workspace, ["status", "--porcelain"]) == ""
    assert git_output!(workspace, ["ls-files"]) == "README.md"

    assert {:ok, provenance} =
             Workspace.capture_provenance(workspace, issue, nil, route, workspace_root: fixture.workspace_root)

    assert provenance.repository_target == @target
    assert provenance.repository_source_path == fixture.source
    assert provenance.repository_default_branch == "main"
    assert provenance.configured_remote == fixture.origin
    assert provenance.repository_origin == fixture.origin
    assert provenance.prepared_base_commit == fixture.head

    assert :ok = Workspace.verify_workspace_git_identity(workspace, route, nil)
    assert :ok = Workspace.verify_workspace_viability(workspace, route, nil)

    assert {:ok, :resume, ^workspace, ^route} =
             Workspace.classify_candidate(issue, nil, workspace_root: fixture.workspace_root)

    # The automatic retry re-enters through the same call with the workspace
    # already on disk (created? == false), so it must reuse it, not fail closed.
    assert {:ok, reused, ^route, ^recorded_root} =
             Workspace.create_for_issue_with_route(issue, nil, workspace_root: fixture.workspace_root)

    assert reused == workspace
    assert git_output!(workspace, ["branch", "--show-current"]) == task_branch

    # The source checkout is read, never mutated: same HEAD, same branch, clean
    # tracked tree, and exactly one registered worktree besides the new one.
    assert git_output!(fixture.source, ["rev-parse", "HEAD"]) == fixture.head
    assert git_output!(fixture.source, ["branch", "--show-current"]) == "main"
    assert git_output!(fixture.source, ["status", "--porcelain"]) == ""
    assert registered_worktrees(fixture.source) == Enum.sort([normalize_path(fixture.source), normalize_path(workspace)])
  end

  test "the preparation hook fails closed when the task branch already exists", %{fixture: fixture} do
    issue = issue("MIC-PREP-GUARD")

    git!(fixture.source, ["branch", "symphony/" <> issue.identifier])

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: fixture.workspace_root,
      routing: routing(fixture),
      hook_after_create: @after_create
    )

    assert {:error, {:workspace_hook_failed, "after_create", _status, _output}} =
             Workspace.create_for_issue_with_route(issue, nil, workspace_root: fixture.workspace_root)

    assert File.exists?(Path.join(fixture.workspace_root, issue.identifier)) == false
    assert registered_worktrees(fixture.source) == [normalize_path(fixture.source)]
  end

  defp build_fixture!(root) do
    origin = Path.join(root, "origin.git")
    source = Path.join(root, "source")
    workspace_root = Path.join(root, "workspaces")

    File.mkdir_p!(source)
    File.mkdir_p!(workspace_root)

    git!(root, ["init", "--bare", "-b", "main", origin])
    git!(source, ["init", "-b", "main"])
    git!(source, ["config", "user.name", "Pilot Test"])
    git!(source, ["config", "user.email", "pilot-test@example.com"])
    git!(source, ["config", "core.autocrlf", "false"])
    File.write!(Path.join(source, "README.md"), "prepared target\n")
    git!(source, ["add", "README.md"])
    git!(source, ["commit", "-m", "prepared base"])
    git!(source, ["remote", "add", "origin", origin])
    git!(source, ["push", "-u", "origin", "main"])

    %{
      root: root,
      origin: origin,
      source: source,
      workspace_root: workspace_root,
      head: git_output!(source, ["rev-parse", "HEAD"])
    }
  end

  defp issue(identifier) do
    %Issue{
      id: String.downcase(identifier),
      identifier: identifier,
      title: "pilot workspace preparation",
      state: "Todo",
      labels: ["repo:" <> @target]
    }
  end

  defp routing(%{source: source, origin: origin}) do
    %{
      target_label_prefix: "repo:",
      default_branch: "main",
      targets: %{@target => %{source_path: source, remote: origin}}
    }
  end

  defp registered_worktrees(source) do
    source
    |> git_output!(["worktree", "list", "--porcelain"])
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn
      "worktree " <> path -> [normalize_path(path)]
      _line -> []
    end)
    |> Enum.sort()
  end

  # `git worktree list` reports forward-slash paths with the drive letter's
  # original case, while Path.join produces native separators; compare one form.
  defp normalize_path(path) do
    path |> Path.expand() |> String.replace("\\", "/") |> String.downcase()
  end

  defp git!(dir, args) do
    case System.cmd("git", ["-C", dir | args], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git #{Enum.join(args, " ")} in #{dir} failed (#{status}): #{output}")
    end
  end

  defp git_output!(dir, args) do
    case System.cmd("git", ["-C", dir | args], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("git #{Enum.join(args, " ")} in #{dir} failed (#{status}): #{output}")
    end
  end
end
