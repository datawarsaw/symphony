defmodule SymphonyElixir.WorkspaceAndConfigTest do
  use SymphonyElixir.TestSupport
  alias Ecto.Changeset
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.{Codex, StringOrMap}
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.RepositoryRouter
  alias SymphonyElixir.TestSupport.FakeSSH

  # Symlink escape coverage runs with a real symlink when the host allows it and
  # with a directory junction otherwise; only an unavailable prerequisite skips it.
  @symlink_fixture_skip symlink_fixture_skip_reason()

  test "workspace bootstrap can be implemented in after_create hook" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-bootstrap-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(Path.join(template_repo, "keep"))
      File.write!(Path.join([template_repo, "keep", "file.txt"]), "keep me")
      File.write!(Path.join(template_repo, "README.md"), "hook clone\n")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md", "keep/file.txt"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "git clone --depth 1 #{template_repo} ."
      )

      assert {:ok, workspace} = Workspace.create_for_issue("S-1")
      assert File.exists?(Path.join(workspace, ".git"))
      assert File.read!(Path.join(workspace, "README.md")) == "hook clone\n"
      assert File.read!(Path.join([workspace, "keep", "file.txt"])) == "keep me"
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace path is deterministic per issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-deterministic-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:ok, first_workspace} = Workspace.create_for_issue("MT/Det")
    assert {:ok, second_workspace} = Workspace.create_for_issue("MT/Det")

    assert first_workspace == second_workspace
    assert Path.basename(first_workspace) == Workspace.workspace_key("MT/Det")
    assert String.starts_with?(Path.basename(first_workspace), "MT_Det--")
  end

  test "relative local workspace roots resolve from the workflow directory" do
    workflow_dir = Path.dirname(Workflow.workflow_file_path())
    launcher_dir = Path.join(System.tmp_dir!(), "symphony-elixir-launcher-#{System.unique_integer([:positive])}")
    original_cwd = File.cwd!()

    try do
      File.mkdir_p!(launcher_dir)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: "relative-workspaces")
      File.cd!(launcher_dir)

      assert {:ok, expected_workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join([workflow_dir, "relative-workspaces", "MT-REL"]))

      assert {:ok, workspace} = Workspace.create_for_issue("MT-REL")

      assert workspace == expected_workspace
      refute String.starts_with?(workspace, launcher_dir <> "/")
    after
      File.cd!(original_cwd)
      File.rm_rf(launcher_dir)
    end
  end

  test "workspace keys disambiguate identifiers that sanitize to the same path" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-collision-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      slash_issue = %Issue{id: "dispatch-slash", identifier: "team/a-1"}
      underscore_issue = %Issue{id: "dispatch-underscore", identifier: "team_a-1"}

      assert {:ok, slash_workspace} = Workspace.create_for_issue(slash_issue)
      assert {:ok, ^slash_workspace} = Workspace.create_for_issue("team/a-1")
      assert {:ok, underscore_workspace} = Workspace.create_for_issue(underscore_issue)

      refute slash_workspace == underscore_workspace
      assert Path.basename(underscore_workspace) == "team_a-1"
      assert String.starts_with?(Path.basename(slash_workspace), "team_a-1--")

      assert :ok = Workspace.remove_issue_workspaces("team/a-1")
      refute File.exists?(slash_workspace)
      assert File.exists?(underscore_workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace reuses existing issue directory without deleting local changes" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-reuse-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo first > README.md"
      )

      assert {:ok, first_workspace} = Workspace.create_for_issue("MT-REUSE")

      File.write!(Path.join(first_workspace, "README.md"), "changed\n")
      File.write!(Path.join(first_workspace, "local-progress.txt"), "in progress\n")
      File.mkdir_p!(Path.join(first_workspace, "deps"))
      File.mkdir_p!(Path.join(first_workspace, "_build"))
      File.mkdir_p!(Path.join(first_workspace, "tmp"))
      File.write!(Path.join([first_workspace, "deps", "cache.txt"]), "cached deps\n")
      File.write!(Path.join([first_workspace, "_build", "artifact.txt"]), "compiled artifact\n")
      File.write!(Path.join([first_workspace, "tmp", "scratch.txt"]), "remove me\n")

      assert {:ok, second_workspace} = Workspace.create_for_issue("MT-REUSE")
      assert second_workspace == first_workspace
      assert File.read!(Path.join(second_workspace, "README.md")) == "changed\n"
      assert File.read!(Path.join(second_workspace, "local-progress.txt")) == "in progress\n"
      assert File.read!(Path.join([second_workspace, "deps", "cache.txt"])) == "cached deps\n"
      assert File.read!(Path.join([second_workspace, "_build", "artifact.txt"])) == "compiled artifact\n"
      assert File.read!(Path.join([second_workspace, "tmp", "scratch.txt"])) == "remove me\n"
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace replaces stale non-directory paths" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-stale-path-#{System.unique_integer([:positive])}"
      )

    try do
      stale_workspace = Path.join(workspace_root, "MT-STALE")
      File.mkdir_p!(workspace_root)
      File.write!(stale_workspace, "old state\n")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(stale_workspace)
      assert {:ok, workspace} = Workspace.create_for_issue("MT-STALE")
      assert workspace == canonical_workspace
      assert File.dir?(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  @tag skip: @symlink_fixture_skip
  test "workspace rejects symlink escapes under the configured root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_root = Path.join(test_root, "outside")
      symlink_path = Path.join(workspace_root, "MT-SYM")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_root)
      link_dir_fixture!(outside_root, symlink_path)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_outside_root} = SymphonyElixir.PathSafety.canonicalize(outside_root)
      assert {:ok, canonical_workspace_root} = SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:error, {:workspace_outside_root, ^canonical_outside_root, ^canonical_workspace_root}} =
               Workspace.create_for_issue("MT-SYM")
    after
      remove_dir_link_fixtures!(test_root)
    end
  end

  @tag skip: @symlink_fixture_skip
  test "recorded workspace removal rejects symlink escapes before hooks" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-recorded-workspace-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      recorded_root = Path.join(test_root, "recorded-workspaces")
      current_root = Path.join(test_root, "current-workspaces")
      outside_root = Path.join(test_root, "outside")
      # The product reports the expanded recorded path, so keep the fixture path in
      # that canonical form; otherwise the pin below only holds where Path.expand
      # does not change separators or drive-letter case.
      recorded_workspace = Path.expand(Path.join(recorded_root, "MT-SYM"))
      hook_marker = Path.join(test_root, "before-remove-ran")

      File.mkdir_p!(recorded_root)
      File.mkdir_p!(outside_root)
      link_dir_fixture!(outside_root, recorded_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: current_root,
        hook_before_remove: "touch \"#{hook_marker}\""
      )

      assert {:ok, canonical_recorded_root} =
               SymphonyElixir.PathSafety.canonicalize(recorded_root)

      assert {:error, {:workspace_symlink_escape, ^recorded_workspace, ^canonical_recorded_root}, ""} =
               Workspace.remove_recorded(recorded_workspace, nil)

      refute File.exists?(hook_marker)
      assert File.exists?(outside_root)
    after
      remove_dir_link_fixtures!(test_root)
    end
  end

  @tag skip: @symlink_fixture_skip
  test "workspace canonicalizes symlinked workspace roots before creating issue directories" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-root-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      actual_root = Path.join(test_root, "actual-workspaces")
      linked_root = Path.join(test_root, "linked-workspaces")

      File.mkdir_p!(actual_root)
      link_dir_fixture!(actual_root, linked_root)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: linked_root)

      assert {:ok, canonical_workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(actual_root, "MT-LINK"))

      assert {:ok, workspace} = Workspace.create_for_issue("MT-LINK")
      assert workspace == canonical_workspace
      assert File.dir?(workspace)
    after
      remove_dir_link_fixtures!(test_root)
    end
  end

  test "workspace remove rejects the workspace root itself with a distinct error" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-root-remove-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace_root)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_workspace_root} =
               SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:error, {:workspace_equals_root, ^canonical_workspace_root, ^canonical_workspace_root}, ""} =
               Workspace.remove(workspace_root)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace surfaces after_create hook failures" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-failure-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo nope && exit 17"
      )

      assert {:error, {:workspace_hook_failed, "after_create", 17, _output}} =
               Workspace.create_for_issue("MT-FAIL")
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace retries after_create after a failed new workspace bootstrap" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-retry-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    attempt_log = Path.join(test_root, "after-create-attempts")

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: """
        if [ -f "#{attempt_log}" ]; then count=$(wc -l < "#{attempt_log}"); else count=0; fi
        printf 'attempt\\n' >> "#{attempt_log}"
        if [ "$count" -eq 0 ]; then printf partial > partial.txt; exit 17; fi
        printf ready > READY
        """
      )

      assert {:error, {:workspace_hook_failed, "after_create", 17, _output}} =
               Workspace.create_for_issue("MT-FAIL-RETRY")

      assert {:ok, workspace} = Workspace.create_for_issue("MT-FAIL-RETRY")
      assert File.read!(Path.join(workspace, "READY")) == "ready"
      assert String.split(String.trim(File.read!(attempt_log)), "\n") == ["attempt", "attempt"]
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace surfaces after_create hook timeouts" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_timeout_ms: 10,
        hook_after_create: "sleep 1"
      )

      assert {:error, {:workspace_hook_timeout, "after_create", 10}} =
               Workspace.create_for_issue("MT-TIMEOUT")
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace creates an empty directory when no bootstrap hook is configured" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-workspace-empty-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      workspace = Path.join(workspace_root, "MT-608")
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      assert {:ok, ^canonical_workspace} = Workspace.create_for_issue("MT-608")
      assert File.dir?(workspace)
      assert {:ok, []} = File.ls(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace removes all workspaces for a closed issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-workspace-cleanup-#{System.unique_integer([:positive])}"
      )

    try do
      target_workspace = Path.join(workspace_root, "S_1")
      untouched_workspace = Path.join(workspace_root, "OTHER-#{System.unique_integer([:positive])}")

      File.mkdir_p!(target_workspace)
      File.mkdir_p!(untouched_workspace)
      File.write!(Path.join(target_workspace, "marker.txt"), "stale")
      File.write!(Path.join(untouched_workspace, "marker.txt"), "keep")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert :ok = Workspace.remove_issue_workspaces("S_1")
      refute File.exists?(target_workspace)
      assert File.exists?(untouched_workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace cleanup handles missing workspace root" do
    missing_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-workspaces-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: missing_root)

    assert :ok = Workspace.remove_issue_workspaces("S-2")
  end

  test "workspace cleanup ignores non-binary identifier" do
    assert :ok = Workspace.remove_issue_workspaces(nil)
  end

  test "tracker issue helpers" do
    issue = %Issue{
      id: "abc",
      labels: ["frontend", "infra"],
      dispatchable: false
    }

    assert Issue.label_names(issue) == ["frontend", "infra"]
    assert issue.labels == ["frontend", "infra"]
    refute issue.dispatchable
  end

  test "tracker issue routing requires every configured label" do
    issue = %Issue{labels: [" Symphony ", "JavaScript"], dispatchable: true}

    assert Issue.routable?(issue, [])
    assert Issue.routable?(issue, ["symphony"])
    assert Issue.routable?(issue, ["SYMPHONY", "javascript"])
    refute Issue.routable?(issue, ["symph"])
    refute Issue.routable?(issue, [" "])
    refute Issue.routable?(issue, ["symphony", "security"])
    refute Issue.routable?(%{issue | dispatchable: false}, ["symphony"])
  end

  test "repository routing resolves one configured target and exports it to workspace hooks" do
    test_root = routed_source_test_root("repository-routing")

    try do
      fixture = routed_source_fixture!(test_root)
      git!(["-C", fixture.source_repo, "branch", "-m", "main", "trunk"])
      git!(["-C", fixture.remote_repo, "branch", "-m", "main", "trunk"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: fixture.workspace_root,
        routing: %{
          target_label_prefix: "repo:",
          default_branch: "trunk",
          targets: %{
            "wup" => %{source_path: "/sources/wup", remote: "datawarsaw/wup"},
            "symphony-runtime" => %{source_path: fixture.source_repo, remote: fixture.remote_repo}
          }
        },
        hook_after_create:
          "printf '%s|%s|%s|%s' \"$SYMPHONY_REPOSITORY_TARGET\" \"$SYMPHONY_REPOSITORY_SOURCE_PATH\" \"$SYMPHONY_REPOSITORY_DEFAULT_BRANCH\" \"$SYMPHONY_REPOSITORY_REMOTE\" > route.txt"
      )

      issue = %Issue{id: "issue-1", identifier: "MIC-129", labels: ["repo:symphony-runtime"]}

      assert {:ok, route} = RepositoryRouter.resolve(issue, Config.settings!().routing)
      assert route.target == "symphony-runtime"
      assert route.source_path == fixture.source_repo
      assert route.default_branch == "trunk"

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      assert File.read!(Path.join(workspace, "route.txt")) == "symphony-runtime|#{fixture.source_repo}|trunk|#{fixture.remote_repo}"
    after
      File.rm_rf(test_root)
    end
  end

  test "repository routing fails closed when the remote task branch already exists" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-remote-task-branch-collision-#{System.unique_integer([:positive])}"
      )

    try do
      remote_repo = Path.join(test_root, "remote.git") |> String.replace("\\\\", "/")
      source_repo = Path.join(test_root, "source") |> String.replace("\\\\", "/")
      publisher_repo = Path.join(test_root, "publisher") |> String.replace("\\\\", "/")
      workspace_root = Path.join(test_root, "workspaces")
      task_branch = "symphony/MIC-REMOTE-COLLISION"

      assert {_, 0} = System.cmd("git", ["init", "--bare", remote_repo])
      assert {_, 0} = System.cmd("git", ["init", "-b", "main", source_repo])
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "config", "user.name", "Test User"])

      assert {_, 0} =
               System.cmd("git", ["-C", source_repo, "config", "user.email", "test@example.com"])

      File.write!(Path.join(source_repo, "README.md"), "initial\n")
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "add", "README.md"])
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "commit", "-m", "initial"])
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "remote", "add", "origin", remote_repo])
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "push", "-u", "origin", "main"])

      assert {_, 0} = System.cmd("git", ["clone", remote_repo, publisher_repo])

      assert {_, 0} =
               System.cmd("git", ["-C", publisher_repo, "config", "user.name", "Test User"])

      assert {_, 0} =
               System.cmd("git", ["-C", publisher_repo, "config", "user.email", "test@example.com"])

      assert {_, 0} = System.cmd("git", ["-C", publisher_repo, "checkout", "-b", task_branch])
      File.write!(Path.join(publisher_repo, "branch-marker.txt"), "remote task branch\n")
      assert {_, 0} = System.cmd("git", ["-C", publisher_repo, "add", "branch-marker.txt"])

      assert {_, 0} =
               System.cmd("git", ["-C", publisher_repo, "commit", "-m", "remote task branch"])

      assert {_, 0} = System.cmd("git", ["-C", publisher_repo, "push", "origin", task_branch])

      production_workflow = Path.expand("../../WORKFLOW.md", __DIR__)
      assert {:ok, %{config: config}} = Workflow.load(production_workflow)
      hook_after_create = get_in(config, ["hooks", "after_create"])
      assert is_binary(hook_after_create)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        routing: %{
          target_label_prefix: "repo:",
          default_branch: "main",
          targets: %{"symphony-runtime" => %{source_path: source_repo, remote: remote_repo}}
        },
        hook_after_create: hook_after_create
      )

      issue = %Issue{
        id: "remote-branch-collision",
        identifier: "MIC-REMOTE-COLLISION",
        labels: ["repo:symphony-runtime"]
      }

      assert {:error, {:workspace_hook_failed, "after_create", 1, _output}} =
               Workspace.create_for_issue(issue)

      assert {_, 0} =
               System.cmd("git", [
                 "-C",
                 source_repo,
                 "show-ref",
                 "--verify",
                 "--quiet",
                 "refs/remotes/origin/#{task_branch}"
               ])

      assert {_, 1} =
               System.cmd("git", [
                 "-C",
                 source_repo,
                 "show-ref",
                 "--verify",
                 "--quiet",
                 "refs/heads/#{task_branch}"
               ])

      refute File.exists?(Path.join(workspace_root, Workspace.workspace_key(issue)))
    after
      File.rm_rf(test_root)
    end
  end

  test "repository routing permits unrelated untracked source state" do
    test_root = routed_source_test_root("untracked-source-state")

    try do
      fixture = routed_source_fixture!(test_root)
      untracked_path = Path.join([fixture.source_repo, "state", "preserved-checkpoint.json"])
      File.mkdir_p!(Path.dirname(untracked_path))
      File.write!(untracked_path, "preserve me\n")
      configure_routed_source_workflow!(fixture)

      issue = routed_source_issue("MIC-UNTRACKED-SOURCE")

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      assert File.read!(untracked_path) == "preserve me\n"

      assert {status, 0} =
               System.cmd("git", ["-C", fixture.source_repo, "status", "--porcelain", "--", "state"])

      assert status =~ "?? state/"

      assert {"symphony/MIC-UNTRACKED-SOURCE\n", 0} =
               System.cmd("git", ["-C", workspace, "branch", "--show-current"])

      refute File.exists?(Path.join([workspace, "state", "preserved-checkpoint.json"]))
    after
      File.rm_rf(test_root)
    end
  end

  test "repository routing fails closed for tracked source modifications" do
    test_root = routed_source_test_root("tracked-source-state")

    try do
      fixture = routed_source_fixture!(test_root)
      File.write!(Path.join(fixture.source_repo, "README.md"), "modified but unstaged\n")
      configure_routed_source_workflow!(fixture)

      issue = routed_source_issue("MIC-TRACKED-DIRTY")

      assert {:error, {:source_baseline_sync_failed, "symphony-runtime", :dirty_tracked}} =
               Workspace.create_for_issue(issue)

      assert {_, 1} =
               System.cmd("git", [
                 "-C",
                 fixture.source_repo,
                 "show-ref",
                 "--verify",
                 "--quiet",
                 "refs/heads/symphony/MIC-TRACKED-DIRTY"
               ])

      refute File.exists?(routed_source_workspace_path(fixture, issue))
    after
      File.rm_rf(test_root)
    end
  end

  test "repository routing fails closed for staged source modifications" do
    test_root = routed_source_test_root("staged-source-state")

    try do
      fixture = routed_source_fixture!(test_root)
      File.write!(Path.join(fixture.source_repo, "README.md"), "modified and staged\n")
      git!(["-C", fixture.source_repo, "add", "README.md"])
      configure_routed_source_workflow!(fixture)

      issue = routed_source_issue("MIC-STAGED-DIRTY")

      assert {:error, {:source_baseline_sync_failed, "symphony-runtime", :dirty_index}} =
               Workspace.create_for_issue(issue)

      assert {_, 1} =
               System.cmd("git", [
                 "-C",
                 fixture.source_repo,
                 "show-ref",
                 "--verify",
                 "--quiet",
                 "refs/heads/symphony/MIC-STAGED-DIRTY"
               ])

      refute File.exists?(routed_source_workspace_path(fixture, issue))
    after
      File.rm_rf(test_root)
    end
  end

  test "repository routing fails closed for missing, unknown, and ambiguous targets" do
    routing = %Schema.Routing{
      targets: %{
        "wup" => %{"source_path" => "/sources/wup"},
        "symphony-runtime" => %{"source_path" => "/sources/symphony"}
      }
    }

    assert {:error, :missing_repository_target} =
             RepositoryRouter.resolve(%Issue{labels: ["symphony-pilot"]}, routing)

    assert {:error, {:unsupported_repository_target, "unknown"}} =
             RepositoryRouter.resolve(%Issue{labels: ["repo:unknown"]}, routing)

    assert {:error, {:ambiguous_repository_target, ["wup", "symphony-runtime"]}} =
             RepositoryRouter.resolve(%Issue{labels: ["repo:wup", "repo:symphony-runtime"]}, routing)
  end

  test "repository routing rejects issue metadata that injects a filesystem path or Git URL" do
    routing = %Schema.Routing{
      targets: %{"symphony-runtime" => %{"source_path" => "/sources/symphony"}}
    }

    injected_labels = [
      "repo:/etc/passwd",
      "repo:../../etc",
      "repo:C:/Windows/System32",
      "repo:https://evil.example/attacker.git",
      "repo:git@evil.example:attacker.git",
      "repo:file:///etc/passwd"
    ]

    for label <- injected_labels do
      assert {:error, {:unsupported_repository_target, target}} =
               RepositoryRouter.resolve(%Issue{labels: [label]}, routing)

      assert String.downcase(target) == String.downcase(String.replace_prefix(label, "repo:", ""))
    end

    assert {:error, {:ambiguous_repository_target, _targets}} =
             RepositoryRouter.resolve(
               %Issue{labels: ["repo:symphony-runtime", "repo:/etc/passwd"]},
               routing
             )
  end

  test "linear client normalizes blockers from inverse relations" do
    raw_issue = %{
      "id" => "issue-1",
      "identifier" => "MT-1",
      "title" => "Blocked todo",
      "description" => "Needs dependency",
      "priority" => 2,
      "state" => %{"name" => "Todo"},
      "branchName" => "mt-1",
      "url" => "https://example.org/issues/MT-1",
      "assignee" => %{
        "id" => "user-1"
      },
      "labels" => %{"nodes" => [%{"name" => "Backend"}, %{"name" => " backend "}, %{"name" => " "}]},
      "inverseRelations" => %{
        "nodes" => [
          %{
            "type" => "blocks",
            "issue" => %{
              "id" => "issue-2",
              "identifier" => "MT-2",
              "state" => %{"name" => "In Progress"}
            }
          },
          %{
            "type" => "relatesTo",
            "issue" => %{
              "id" => "issue-3",
              "identifier" => "MT-3",
              "state" => %{"name" => "Done"}
            }
          }
        ]
      },
      "createdAt" => "2026-01-01T00:00:00Z",
      "updatedAt" => "2026-01-02T00:00:00Z"
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    assert issue.blocked_by == [%{id: "issue-2", identifier: "MT-2", state: "In Progress"}]
    assert issue.labels == ["backend"]
    assert issue.native_ref == nil
    assert issue.priority == 2
    assert issue.state == "Todo"
    assert issue.assignee_id == "user-1"
    refute issue.dispatchable
  end

  test "linear client rejects malformed issues instead of returning invalid scheduler records" do
    assert Client.normalize_issue_for_test(
             %{
               "id" => "issue-empty-title",
               "identifier" => "MT-EMPTY",
               "title" => " ",
               "state" => %{"name" => "Todo"}
             },
             nil
           ) == nil

    graphql_fun = fn _query, _variables ->
      {:ok,
       %{
         "data" => %{
           "issues" => %{
             "nodes" => [
               %{
                 "id" => "issue-empty-title",
                 "identifier" => "MT-EMPTY",
                 "title" => " ",
                 "state" => %{"name" => "Todo"}
               }
             ]
           }
         }
       }}
    end

    assert {:error, :linear_unknown_payload} =
             Client.fetch_issues_by_ids_for_test(["issue-empty-title"], graphql_fun)
  end

  test "linear client marks explicitly unassigned issues as not routed to worker" do
    raw_issue = %{
      "id" => "issue-99",
      "identifier" => "MT-99",
      "title" => "Someone else's task",
      "state" => %{"name" => "Todo"},
      "assignee" => %{
        "id" => "user-2"
      }
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    refute issue.dispatchable
  end

  test "linear client pagination merge helper preserves issue ordering" do
    issue_page_1 = [
      %Issue{id: "issue-1", identifier: "MT-1"},
      %Issue{id: "issue-2", identifier: "MT-2"}
    ]

    issue_page_2 = [
      %Issue{id: "issue-3", identifier: "MT-3"}
    ]

    merged = Client.merge_issue_pages_for_test([issue_page_1, issue_page_2])

    assert Enum.map(merged, & &1.identifier) == ["MT-1", "MT-2", "MT-3"]
  end

  test "linear client paginates issue state fetches by id beyond one page" do
    issue_ids = Enum.map(1..55, &"issue-#{&1}")
    first_batch_ids = Enum.take(issue_ids, 50)
    second_batch_ids = Enum.drop(issue_ids, 50)

    raw_issue = fn issue_id ->
      suffix = String.replace_prefix(issue_id, "issue-", "")

      %{
        "id" => issue_id,
        "identifier" => "MT-#{suffix}",
        "title" => "Issue #{suffix}",
        "description" => "Description #{suffix}",
        "state" => %{"name" => "In Progress"},
        "labels" => %{"nodes" => []},
        "inverseRelations" => %{"nodes" => []}
      }
    end

    graphql_fun = fn query, variables ->
      send(self(), {:fetch_issue_states_page, query, variables})

      body = %{
        "data" => %{
          "issues" => %{
            "nodes" => Enum.map(variables.ids, raw_issue)
          }
        }
      }

      {:ok, body}
    end

    assert {:ok, issues} = Client.fetch_issues_by_ids_for_test(issue_ids, graphql_fun)

    assert Enum.map(issues, & &1.id) == issue_ids

    assert_receive {:fetch_issue_states_page, query,
                    %{
                      ids: ^first_batch_ids,
                      projectSlug: "test-project",
                      first: 50,
                      relationFirst: 50
                    }}

    assert query =~ "SymphonyLinearIssuesById"
    assert query =~ "projectSlug"
    assert query =~ "slugId"

    assert_receive {:fetch_issue_states_page, ^query,
                    %{
                      ids: ^second_batch_ids,
                      projectSlug: "test-project",
                      first: 5,
                      relationFirst: 50
                    }}
  end

  test "linear client logs response bodies for non-200 graphql responses" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:linear_api_status, 400}} =
                 Client.graphql(
                   "query Viewer { viewer { id } }",
                   %{},
                   request_fun: fn _payload, _headers ->
                     {:ok,
                      %{
                        status: 400,
                        body: %{
                          "errors" => [
                            %{
                              "message" => "Variable \"$ids\" got invalid value",
                              "extensions" => %{"code" => "BAD_USER_INPUT"}
                            }
                          ]
                        }
                      }}
                   end
                 )
      end)

    assert log =~ "Linear GraphQL request failed status=400"
    assert log =~ ~s(body=%{"errors" => [%{"extensions" => %{"code" => "BAD_USER_INPUT"})
    assert log =~ "Variable \\\"$ids\\\" got invalid value"
  end

  test "linear graphql honors a bound tracker-settings snapshot without loading live config" do
    parent = self()
    original_workflow_path = Workflow.workflow_file_path()
    workflow_store_pid = Process.whereis(WorkflowStore)

    missing_workflow_path =
      Path.join(System.tmp_dir!(), "missing-bound-workflow-#{System.unique_integer([:positive])}.md")

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)

      if is_pid(workflow_store_pid) and is_nil(Process.whereis(WorkflowStore)) do
        Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
      end
    end)

    if is_pid(Process.whereis(WorkflowStore)) do
      assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    end

    Workflow.set_workflow_file_path(missing_workflow_path)

    assert {:ok, %{"data" => %{"viewer" => %{"id" => "viewer-bound"}}}} =
             Client.graphql(
               "query Viewer { viewer { id } }",
               %{},
               tracker_settings: %{
                 api_key: "bound-token",
                 endpoint: "https://bound.example.test/graphql"
               },
               request_fun: fn payload, headers ->
                 send(parent, {:bound_graphql_request, payload, headers})
                 {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"id" => "viewer-bound"}}}}}
               end
             )

    assert_receive {:bound_graphql_request, %{"query" => "query Viewer { viewer { id } }"}, [{"Authorization", "bound-token"}, {"Content-Type", "application/json"}]}
  end

  test "orchestrator sorts dispatch by priority then oldest created_at" do
    issue_same_priority_older = %Issue{
      id: "issue-old-high",
      identifier: "MT-200",
      title: "Old high priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-01 00:00:00Z]
    }

    issue_same_priority_newer = %Issue{
      id: "issue-new-high",
      identifier: "MT-201",
      title: "New high priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-02 00:00:00Z]
    }

    issue_lower_priority_older = %Issue{
      id: "issue-old-low",
      identifier: "MT-199",
      title: "Old lower priority",
      state: "Todo",
      priority: 2,
      created_at: ~U[2025-12-01 00:00:00Z]
    }

    sorted =
      Orchestrator.sort_issues_for_dispatch_for_test([
        issue_lower_priority_older,
        issue_same_priority_newer,
        issue_same_priority_older
      ])

    assert Enum.map(sorted, & &1.identifier) == ["MT-200", "MT-201", "MT-199"]
  end

  test "provider-marked blocked issue is not dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "blocked-1",
      identifier: "MT-1001",
      title: "Blocked work",
      state: "Todo",
      dispatchable: false,
      blocked_by: [%{id: "blocker-1", identifier: "MT-1002", state: "In Progress"}]
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "issue assigned to another worker is not dispatch-eligible" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "dev@example.com")

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "assigned-away-1",
      identifier: "MT-1007",
      title: "Owned elsewhere",
      state: "Todo",
      dispatchable: false
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "issue without every required label is not dispatch-eligible" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_required_labels: ["symphony", "javascript"]
    )

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "unlabeled-1",
      identifier: "MT-1008",
      title: "Not opted in",
      state: "Todo",
      labels: ["symphony"],
      dispatchable: true
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
    assert Orchestrator.should_dispatch_issue_for_test(%{issue | labels: ["Symphony", "JavaScript"]}, state)
  end

  test "provider-marked ready issue remains dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "ready-1",
      identifier: "MT-1003",
      title: "Ready work",
      state: "Todo",
      blocked_by: [%{id: "blocker-2", identifier: "MT-1004", state: "Closed"}],
      dispatchable: true
    }

    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "dispatch revalidation skips an issue when provider routing changes" do
    stale_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "Todo",
      blocked_by: []
    }

    refreshed_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "Todo",
      dispatchable: false,
      blocked_by: [%{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}]
    }

    fetcher = fn ["blocked-2"] -> {:ok, [refreshed_issue]} end

    assert {:skip, %Issue{} = skipped_issue} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(stale_issue, fetcher)

    assert skipped_issue.identifier == "MT-1005"
    assert skipped_issue.blocked_by == [%{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}]
  end

  test "dispatch revalidation skips an issue after a required label is removed" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: ["symphony"])

    stale_issue = %Issue{
      id: "unlabeled-2",
      identifier: "MT-1009",
      title: "Initially opted in",
      state: "Todo",
      labels: ["symphony"]
    }

    refreshed_issue = %{stale_issue | labels: []}
    fetcher = fn ["unlabeled-2"] -> {:ok, [refreshed_issue]} end

    assert {:skip, ^refreshed_issue} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(stale_issue, fetcher)
  end

  test "workspace remove returns error information for missing directory" do
    random_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-#{System.unique_integer([:positive])}"
      )

    assert {:ok, []} = Workspace.remove(random_path)
  end

  test "workspace hooks support multiline YAML scripts and run at lifecycle boundaries" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      before_remove_marker = Path.join(test_root, "before_remove.log")
      after_create_counter = Path.join(test_root, "after_create.count")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo after_create > after_create.log\necho call >> \"#{after_create_counter}\"",
        hook_before_remove: "echo before_remove > \"#{before_remove_marker}\""
      )

      config = Config.settings!()
      assert config.hooks.after_create =~ "echo after_create > after_create.log"
      assert config.hooks.before_remove =~ "echo before_remove >"

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS")
      assert File.read!(Path.join(workspace, "after_create.log")) == "after_create\n"

      assert {:ok, _workspace} = Workspace.create_for_issue("MT-HOOKS")
      assert length(String.split(String.trim(File.read!(after_create_counter)), "\n")) == 1

      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS")
      assert File.read!(before_remove_marker) == "before_remove\n"
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook fails" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "echo failure && exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-FAIL")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-FAIL")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook fails with large output" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-large-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "i=0; while [ $i -lt 3000 ]; do printf a; i=$((i+1)); done; exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-LARGE-FAIL")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-LARGE-FAIL")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook times out" do
    previous_timeout = Application.get_env(:symphony_elixir, :workspace_hook_timeout_ms)

    on_exit(fn ->
      if is_nil(previous_timeout) do
        Application.delete_env(:symphony_elixir, :workspace_hook_timeout_ms)
      else
        Application.put_env(:symphony_elixir, :workspace_hook_timeout_ms, previous_timeout)
      end
    end)

    Application.put_env(:symphony_elixir, :workspace_hook_timeout_ms, 10)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "sleep 1"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-TIMEOUT")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-TIMEOUT")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "config reads defaults for optional settings" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.delete_env("LINEAR_API_KEY")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: nil,
      max_concurrent_agents: nil,
      codex_approval_policy: nil,
      codex_thread_sandbox: nil,
      codex_turn_sandbox_policy: nil,
      codex_turn_timeout_ms: nil,
      codex_read_timeout_ms: nil,
      codex_stall_timeout_ms: nil,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    config = Config.settings!()
    assert config.tracker.endpoint == "https://api.linear.app/graphql"
    assert config.tracker.api_key == nil
    assert config.tracker.project_slug == nil
    assert config.tracker.required_labels == []
    expected_workspace_root = Path.join(System.tmp_dir!(), "symphony_workspaces")

    normalized_config_workspace_root =
      config.workspace.root |> Path.expand() |> String.replace("\\", "/")

    normalized_expected_workspace_root =
      expected_workspace_root |> Path.expand() |> String.replace("\\", "/")

    assert normalized_config_workspace_root == normalized_expected_workspace_root
    assert config.worker.max_concurrent_agents_per_host == nil
   assert config.agent.max_concurrent_agents == 10
   assert config.codex.command == "codex app-server"
   assert config.codex.shell_executable == nil

   assert config.codex.approval_policy == %{
             "reject" => %{
               "sandbox_approval" => true,
               "rules" => true,
               "mcp_elicitations" => true
             }
           }

    assert config.codex.thread_sandbox == "workspace-write"

    assert {:ok, canonical_default_workspace_root} =
             SymphonyElixir.PathSafety.canonicalize(Path.join(System.tmp_dir!(), "symphony_workspaces"))

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "workspaceWrite",
             "writableRoots" => [canonical_default_workspace_root],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert config.codex.turn_timeout_ms == 3_600_000
    assert config.codex.read_timeout_ms == 5_000
    assert config.codex.stall_timeout_ms == 300_000

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_required_labels: [" Symphony ", "SYMPHONY", "JavaScript"]
    )

    assert Config.settings!().tracker.required_labels == ["symphony", "javascript"]

    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: [" "])
    assert Config.settings!().tracker.required_labels == [""]

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_command: "codex --config 'model=\"gpt-5.5\"' app-server"
    )

   assert Config.settings!().codex.command ==
            "codex --config 'model=\"gpt-5.5\"' app-server"

   write_workflow_file!(Workflow.workflow_file_path(),
     codex_shell_executable: "C:/Program Files/Git/bin/bash.exe"
   )

   assert Config.settings!().codex.shell_executable == "C:/Program Files/Git/bin/bash.exe"

   explicit_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-explicit-sandbox-root-#{System.unique_integer([:positive])}"
      )

    explicit_workspace = Path.join(explicit_root, "MT-EXPLICIT")
    explicit_cache = Path.join(explicit_workspace, "cache")
    File.mkdir_p!(explicit_cache)

    on_exit(fn -> File.rm_rf(explicit_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: explicit_root,
      codex_approval_policy: "on-request",
      codex_thread_sandbox: "workspace-write",
      codex_turn_sandbox_policy: %{
        type: "workspaceWrite",
        writableRoots: [explicit_workspace, explicit_cache]
      }
    )

    config = Config.settings!()
    assert config.codex.approval_policy == "on-request"
    assert config.codex.thread_sandbox == "workspace-write"

    assert Config.codex_turn_sandbox_policy(explicit_workspace) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [explicit_workspace, explicit_cache]
           }

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: ",")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "tracker.active_states"

    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_concurrent_agents"

    write_workflow_file!(Workflow.workflow_file_path(), worker_max_concurrent_agents_per_host: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "worker.max_concurrent_agents_per_host"

    write_workflow_file!(Workflow.workflow_file_path(), codex_turn_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.turn_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), codex_read_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.read_timeout_ms"

   write_workflow_file!(Workflow.workflow_file_path(), codex_stall_timeout_ms: "bad")
   assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
   assert message =~ "codex.stall_timeout_ms"

   write_workflow_file!(Workflow.workflow_file_path(), codex_shell_executable: 123)
   assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
   assert message =~ "codex.shell_executable"

   write_workflow_file!(Workflow.workflow_file_path(), codex_shell_executable: "   ")
   assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
   assert message =~ "codex.shell_executable"

   write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: %{todo: true},
      tracker_terminal_states: %{done: true},
      poll_interval_ms: %{bad: true},
      workspace_root: 123,
      max_retry_backoff_ms: 0,
      max_concurrent_agents_by_state: %{"Todo" => "1", "Review" => 0, "Done" => "bad"},
      hook_timeout_ms: 0,
      observability_enabled: "maybe",
      observability_refresh_ms: %{bad: true},
      observability_render_interval_ms: %{bad: true},
      server_port: -1,
      server_host: 123
    )

    assert {:error, {:invalid_workflow_config, _message}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: "")
    assert :ok = Config.validate!()
    assert Config.settings!().codex.approval_policy == ""

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: "")
    assert :ok = Config.validate!()
    assert Config.settings!().codex.thread_sandbox == ""

    write_workflow_file!(Workflow.workflow_file_path(), codex_turn_sandbox_policy: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.turn_sandbox_policy"

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_approval_policy: "future-policy",
      codex_thread_sandbox: "future-sandbox",
      codex_turn_sandbox_policy: %{
        type: "futureSandbox",
        nested: %{flag: true}
      }
    )

    config = Config.settings!()
    assert config.codex.approval_policy == "future-policy"
    assert config.codex.thread_sandbox == "future-sandbox"

    assert :ok = Config.validate!()

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "futureSandbox",
             "nested" => %{"flag" => true}
           }

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "codex app-server")
    assert Config.settings!().codex.command == "codex app-server"
  end

  test "config resolves $VAR references for env-backed secret and path values" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "symphony-workspace-root")
    api_key = "resolved-secret"
    codex_bin = Path.join(["~", "bin", "codex"])

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "$#{api_key_env_var}",
      workspace_root: "$#{workspace_env_var}",
      codex_command: "#{codex_bin} app-server"
    )

    config = Config.settings!()
    assert config.tracker.api_key == api_key
    assert config.tracker.provider["api_key"] == "$#{api_key_env_var}"
    assert config.tracker.secret_environment_names == ["LINEAR_API_KEY", api_key_env_var]
    assert config.workspace.root == Path.expand(workspace_root)
    assert config.codex.command == "#{codex_bin} app-server"
  end

  test "schema preserves adapter-owned provider config while keeping linear aliases compatible" do
    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{
                 kind: "linear",
                 provider: %{
                   endpoint: "https://linear.example.test/graphql",
                   api_key: "provider-token",
                   project_slug: "provider-project",
                   extra: %{team: "platform"}
                 }
               }
             })

    assert settings.tracker.endpoint == "https://linear.example.test/graphql"
    assert settings.tracker.api_key == "provider-token"
    assert settings.tracker.project_slug == "provider-project"
    assert settings.tracker.secret_environment_names == ["LINEAR_API_KEY"]

    assert settings.tracker.provider == %{
             "endpoint" => "https://linear.example.test/graphql",
             "api_key" => "provider-token",
             "project_slug" => "provider-project",
             "assignee" => nil,
             "extra" => %{"team" => "platform"}
           }
  end

  test "linear adapter rejects invalid provider values without crashing config parsing" do
    assert {:ok, invalid_secret_settings} =
             Schema.parse(%{
               tracker: %{
                 kind: "linear",
                 provider: %{api_key: 123, project_slug: "project"}
               }
             })

    assert {:error, :missing_linear_api_token} =
             Config.validate_settings(invalid_secret_settings)

    assert {:ok, invalid_endpoint_settings} =
             Schema.parse(%{
               tracker: %{
                 kind: "linear",
                 provider: %{api_key: "token", project_slug: "project", endpoint: 123}
               }
             })

    assert {:error, :invalid_linear_endpoint} =
             Config.validate_settings(invalid_endpoint_settings)

    assert {:ok, invalid_assignee_settings} =
             Schema.parse(%{
               tracker: %{
                 kind: "linear",
                 provider: %{api_key: "token", project_slug: "project", assignee: 123}
               }
             })

    assert {:error, :invalid_linear_assignee} =
             Config.validate_settings(invalid_assignee_settings)
  end

  test "schema does not inject linear defaults before an adapter is selected" do
    assert {:ok, settings} = Schema.parse(%{tracker: %{kind: "future-tracker"}})

    assert settings.tracker.endpoint == nil
    assert settings.tracker.api_key == nil
    assert settings.tracker.active_states == nil
    assert settings.tracker.terminal_states == nil
    assert settings.tracker.provider == %{}
  end

  test "config no longer resolves legacy env: references" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "symphony-workspace-root")
    api_key = "resolved-secret"

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "env:#{api_key_env_var}",
      workspace_root: "env:#{workspace_env_var}"
    )

    config = Config.settings!()
    assert config.tracker.api_key == "env:#{api_key_env_var}"
    assert config.workspace.root == "env:#{workspace_env_var}"
  end

  test "config supports per-state max concurrent agent overrides" do
    workflow = """
    ---
    tracker:
      kind: memory
    agent:
      max_concurrent_agents: 10
      max_concurrent_agents_by_state:
        todo: 1
        "In Progress": 4
        "In Review": 2
    ---
    """

    File.write!(Workflow.workflow_file_path(), workflow)

    assert Config.settings!().agent.max_concurrent_agents == 10
    assert Config.max_concurrent_agents_for_state("Todo") == 1
    assert Config.max_concurrent_agents_for_state("In Progress") == 4
    assert Config.max_concurrent_agents_for_state("In Review") == 2
    assert Config.max_concurrent_agents_for_state("Closed") == 10
    assert Config.max_concurrent_agents_for_state(:not_a_string) == 10

    write_workflow_file!(Workflow.workflow_file_path(), worker_max_concurrent_agents_per_host: 2)
    assert :ok = Config.validate!()
    assert Config.settings!().worker.max_concurrent_agents_per_host == 2
  end

  test "schema helpers cover custom type and state limit validation" do
    assert StringOrMap.type() == :map
    assert StringOrMap.embed_as(:json) == :self
    assert StringOrMap.equal?(%{"a" => 1}, %{"a" => 1})
    refute StringOrMap.equal?(%{"a" => 1}, %{"a" => 2})

    assert {:ok, "value"} = StringOrMap.cast("value")
    assert {:ok, %{"a" => 1}} = StringOrMap.cast(%{"a" => 1})
    assert :error = StringOrMap.cast(123)

    assert {:ok, "value"} = StringOrMap.load("value")
    assert :error = StringOrMap.load(123)

    assert {:ok, %{"a" => 1}} = StringOrMap.dump(%{"a" => 1})
    assert :error = StringOrMap.dump(123)

    assert Schema.normalize_state_limits(nil) == %{}

    assert Schema.normalize_state_limits(%{" In Progress " => 2, todo: 1}) == %{
             "todo" => 1,
             "in progress" => 2
           }

    changeset =
      {%{}, %{limits: :map}}
      |> Changeset.cast(%{limits: %{"" => 1, "todo" => 0}}, [:limits])
      |> Schema.validate_state_limits(:limits)

    assert changeset.errors == [
             limits: {"state names must not be blank", []},
             limits: {"limits must be positive integers", []}
           ]

    whitespace_state_changeset =
      {%{}, %{limits: :map}}
      |> Changeset.cast(%{limits: %{"   " => 1}}, [:limits])
      |> Schema.validate_state_limits(:limits)

    assert whitespace_state_changeset.errors == [
             limits: {"state names must not be blank", []}
           ]
  end

  test "schema parse normalizes policy keys and env-backed fallbacks" do
    missing_workspace_env = "SYMP_MISSING_WORKSPACE_#{System.unique_integer([:positive])}"
    empty_secret_env = "SYMP_EMPTY_SECRET_#{System.unique_integer([:positive])}"
    missing_secret_env = "SYMP_MISSING_SECRET_#{System.unique_integer([:positive])}"

    previous_missing_workspace_env = System.get_env(missing_workspace_env)
    previous_empty_secret_env = System.get_env(empty_secret_env)
    previous_missing_secret_env = System.get_env(missing_secret_env)
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")

    System.delete_env(missing_workspace_env)
    System.put_env(empty_secret_env, "")
    System.delete_env(missing_secret_env)
    System.put_env("LINEAR_API_KEY", "fallback-linear-token")

    on_exit(fn ->
      restore_env(missing_workspace_env, previous_missing_workspace_env)
      restore_env(empty_secret_env, previous_empty_secret_env)
      restore_env(missing_secret_env, previous_missing_secret_env)
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
    end)

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{kind: "linear", api_key: "$#{empty_secret_env}"},
               workspace: %{root: "$#{missing_workspace_env}"},
               codex: %{approval_policy: %{reject: %{sandbox_approval: true}}}
             })

    assert settings.tracker.api_key == nil
    assert settings.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")

    assert settings.codex.approval_policy == %{
             "reject" => %{"sandbox_approval" => true}
           }

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{kind: "linear", api_key: "$#{missing_secret_env}"},
               workspace: %{root: ""}
             })

    assert settings.tracker.api_key == "fallback-linear-token"
    assert settings.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")
  end

  test "schema resolves sandbox policies from explicit and default workspaces" do
    explicit_policy = %{"type" => "workspaceWrite", "writableRoots" => ["/tmp/explicit"]}

    assert Schema.resolve_turn_sandbox_policy(%Schema{
             codex: %Codex{turn_sandbox_policy: explicit_policy},
             workspace: %Schema.Workspace{root: "/tmp/ignored"}
           }) == explicit_policy

    assert Schema.resolve_turn_sandbox_policy(%Schema{
             codex: %Codex{turn_sandbox_policy: nil},
             workspace: %Schema.Workspace{root: ""}
           }) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert Schema.resolve_turn_sandbox_policy(
             %Schema{
               codex: %Codex{turn_sandbox_policy: nil},
               workspace: %Schema.Workspace{root: "/tmp/ignored"}
             },
             "/tmp/workspace"
           ) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand("/tmp/workspace")],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }
  end

  test "schema keeps workspace roots raw while sandbox helpers expand only for local use" do
    assert {:ok, settings} =
             Schema.parse(%{
               workspace: %{root: "~/.symphony-workspaces"},
               codex: %{}
             })

    assert settings.workspace.root == "~/.symphony-workspaces"

    assert Schema.resolve_turn_sandbox_policy(settings) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand("~/.symphony-workspaces")],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert {:ok, remote_policy} =
             Schema.resolve_runtime_turn_sandbox_policy(settings, nil, remote: true)

    assert remote_policy == %{
             "type" => "workspaceWrite",
             "writableRoots" => ["~/.symphony-workspaces"],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }
  end

  test "runtime sandbox policy resolution passes explicit policies through unchanged" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-sandbox-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-100")
      File.mkdir_p!(issue_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: ["relative/path"],
          networkAccess: true
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "workspaceWrite",
               "writableRoots" => ["relative/path"],
               "networkAccess" => true
             }

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_turn_sandbox_policy: %{
          type: "futureSandbox",
          nested: %{flag: true}
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "futureSandbox",
               "nested" => %{"flag" => true}
             }
    after
      File.rm_rf(test_root)
    end
  end

  test "path safety returns errors for invalid path segments" do
    invalid_segment = String.duplicate("a", 300)
    path = Path.join(System.tmp_dir!(), invalid_segment)
    expanded_path = Path.expand(path)

    assert {:error, {:path_canonicalize_failed, ^expanded_path, :enametoolong}} =
             SymphonyElixir.PathSafety.canonicalize(path)
  end

  test "runtime sandbox policy resolution defaults when omitted and ignores workspace for explicit policies" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-sandbox-branches-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-101")

      File.mkdir_p!(issue_workspace)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      settings = Config.settings!()

      assert {:ok, canonical_workspace_root} =
               SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:ok, default_policy} = Schema.resolve_runtime_turn_sandbox_policy(settings)
      assert default_policy["type"] == "workspaceWrite"
      assert default_policy["writableRoots"] == [canonical_workspace_root]

      assert {:ok, blank_workspace_policy} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, "")

      assert blank_workspace_policy == default_policy

      read_only_settings = %{
        settings
        | codex: %{settings.codex | turn_sandbox_policy: %{"type" => "readOnly", "networkAccess" => true}}
      }

      assert {:ok, %{"type" => "readOnly", "networkAccess" => true}} =
               Schema.resolve_runtime_turn_sandbox_policy(read_only_settings, 123)

      future_settings = %{
        settings
        | codex: %{settings.codex | turn_sandbox_policy: %{"type" => "futureSandbox", "nested" => %{"flag" => true}}}
      }

      assert {:ok, %{"type" => "futureSandbox", "nested" => %{"flag" => true}}} =
               Schema.resolve_runtime_turn_sandbox_policy(future_settings, 123)

      assert {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, 123}}} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, 123)
    after
      File.rm_rf(test_root)
    end
  end

  test "workflow prompt is used when building base prompt" do
    workflow_prompt = "Workflow prompt body used as codex instruction."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)
    assert Config.workflow_prompt() == workflow_prompt
  end

  test "remote workspace lifecycle uses ssh host aliases from worker config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-remote-workspace-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      workspace_root = "~/.symphony-remote-workspaces"
      workspace_path = "/remote/home/.symphony-remote-workspaces/MT-SSH-WS"

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)

      FakeSSH.install!(test_root, :marker,
        trace_file: trace_file,
        output_line: "__SYMPHONY_WORKSPACE__\t1\t#{workspace_path}"
      )

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        worker_ssh_hosts: ["worker-01:2200"],
        hook_before_run: "echo before-run",
        hook_after_run: "echo after-run",
        hook_before_remove: "echo before-remove"
      )

      assert Config.settings!().worker.ssh_hosts == ["worker-01:2200"]
      assert Config.settings!().workspace.root == workspace_root
      assert {:ok, ^workspace_path} = Workspace.create_for_issue("MT-SSH-WS", "worker-01:2200")
      assert :ok = Workspace.run_before_run_hook(workspace_path, "MT-SSH-WS", "worker-01:2200")
      assert :ok = Workspace.run_after_run_hook(workspace_path, "MT-SSH-WS", "worker-01:2200")
      assert :ok = Workspace.remove_issue_workspaces("MT-SSH-WS", "worker-01:2200")

      trace = File.read!(trace_file)
      assert trace =~ "-p 2200 worker-01 bash -lc"
      assert trace =~ "__SYMPHONY_WORKSPACE__"
      assert trace =~ "~/.symphony-remote-workspaces/MT-SSH-WS"
      assert trace =~ "${workspace#\\~/}"
      assert trace =~ "echo before-run"
      assert trace =~ "echo after-run"
      assert trace =~ "echo before-remove"
      assert trace =~ "rm -rf"
      assert trace =~ workspace_path
    after
      File.rm_rf(test_root)
    end
  end

  defp routed_source_test_root(name) do
    Path.join(
      System.tmp_dir!(),
      "symphony-elixir-#{name}-#{System.unique_integer([:positive])}"
    )
  end

  defp routed_source_fixture!(test_root) do
    remote_repo = Path.join(test_root, "remote.git") |> String.replace("\\\\", "/")
    source_repo = Path.join(test_root, "source") |> String.replace("\\\\", "/")
    workspace_root = Path.join(test_root, "workspaces")

    git!(["init", "--bare", remote_repo])
    git!(["init", "-b", "main", source_repo])
    git!(["-C", source_repo, "config", "user.name", "Test User"])
    git!(["-C", source_repo, "config", "user.email", "test@example.com"])
    File.write!(Path.join(source_repo, "README.md"), "initial\n")
    git!(["-C", source_repo, "add", "README.md"])
    git!(["-C", source_repo, "commit", "-m", "initial"])
    git!(["-C", source_repo, "remote", "add", "origin", remote_repo])
    git!(["-C", source_repo, "push", "-u", "origin", "main"])

    production_workflow = Path.expand("../../WORKFLOW.md", __DIR__)
    assert {:ok, %{config: config}} = Workflow.load(production_workflow)
    hook_after_create = get_in(config, ["hooks", "after_create"])
    assert is_binary(hook_after_create)

    %{
      hook_after_create: hook_after_create,
      remote_repo: remote_repo,
      source_repo: source_repo,
      workspace_root: workspace_root
    }
  end

  defp configure_routed_source_workflow!(fixture) do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: fixture.workspace_root,
      routing: %{
        target_label_prefix: "repo:",
        default_branch: "main",
        targets: %{
          "symphony-runtime" => %{source_path: fixture.source_repo, remote: fixture.remote_repo}
        }
      },
      hook_after_create: fixture.hook_after_create
    )
  end

  defp routed_source_issue(identifier) do
    %Issue{id: "source-state-#{identifier}", identifier: identifier, labels: ["repo:symphony-runtime"]}
  end

  defp routed_source_workspace_path(fixture, issue) do
    Path.join(fixture.workspace_root, Workspace.workspace_key(issue))
  end

  defp git!(args) do
    case System.cmd("git", args) do
      {_output, 0} -> :ok
      {output, status} -> raise "git #{Enum.join(args, " ")} failed with #{status}: #{output}"
    end
  end
end
