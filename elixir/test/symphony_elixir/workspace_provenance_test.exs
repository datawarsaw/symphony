defmodule SymphonyElixir.WorkspaceProvenanceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RepositoryRouter
  alias SymphonyElixir.Tracker.Issue

  test "captures routed workspace provenance with credential-safe remote evidence" do
    test_root = Path.join(System.tmp_dir!(), "symphony-provenance-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MIC-167")

    try do
      File.mkdir_p!(workspace)
      git!(workspace, ["init", "-b", "main"])
      git!(workspace, ["config", "user.name", "Test User"])
      git!(workspace, ["config", "user.email", "test@example.com"])
      File.write!(Path.join(workspace, "README.md"), "prepared source\n")
      git!(workspace, ["add", "README.md"])
      git!(workspace, ["commit", "-m", "prepared base"])

      git!(workspace, [
        "remote",
        "add",
        "origin",
        "https://actual-user:actual-secret@example.com/actual/repo.git?token=secret#fragment"
      ])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        routing: %{
          target_label_prefix: "repo:",
          default_branch: "main",
          targets: %{
            "symphony-runtime" => %{
              source_path: "/host/symphony",
              remote: "https://configured-user:configured-secret@example.com/configured/repo.git?token=secret#fragment"
            }
          }
        }
      )

      issue = %Issue{id: "mic-167", identifier: "MIC-167", labels: ["repo:symphony-runtime"]}
      {:ok, provenance} = Workspace.capture_provenance(workspace, issue)

      assert provenance.repository_target == "symphony-runtime"
      assert provenance.repository_source_path == "/host/symphony"
      assert provenance.repository_default_branch == "main"
      assert provenance.prepared_base_commit == git_output!(workspace, ["rev-parse", "--verify", "HEAD"])
      assert provenance.configured_remote == "https://example.com/configured/repo.git"
      assert provenance.repository_origin == "https://example.com/actual/repo.git"
      refute provenance.configured_remote =~ "secret"
      refute provenance.repository_origin =~ "secret"
    after
      File.rm_rf(test_root)
    end
  end

  test "captures an origin even when the selected route does not configure one" do
    test_root = Path.join(System.tmp_dir!(), "symphony-provenance-origin-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MIC-167-ORIGIN")

    try do
      File.mkdir_p!(workspace)
      git!(workspace, ["init", "-b", "main"])
      git!(workspace, ["config", "user.name", "Test User"])
      git!(workspace, ["config", "user.email", "test@example.com"])
      File.write!(Path.join(workspace, "README.md"), "prepared source\n")
      git!(workspace, ["add", "README.md"])
      git!(workspace, ["commit", "-m", "prepared base"])
      git!(workspace, ["remote", "add", "origin", "git@github.com:datawarsaw/symphony.git"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        routing: %{
          target_label_prefix: "repo:",
          default_branch: "main",
          targets: %{"symphony-runtime" => %{source_path: "/host/symphony"}}
        }
      )

      issue = %Issue{id: "mic-167-origin", identifier: "MIC-167-ORIGIN", labels: ["repo:symphony-runtime"]}

      assert {:ok, %{configured_remote: nil, repository_origin: "github.com:datawarsaw/symphony.git"}} =
               Workspace.capture_provenance(workspace, issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "keeps unrouted non-git workspaces compatible" do
    test_root = Path.join(System.tmp_dir!(), "symphony-provenance-unrouted-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MIC-167-UNROUTED")

    try do
      File.mkdir_p!(workspace)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, %{repository_target: nil, repository_origin: nil, prepared_base_commit: nil}} =
               Workspace.capture_provenance(workspace, "MIC-167-UNROUTED")
    after
      File.rm_rf(test_root)
    end
  end

  test "captures provenance and preserves source edits when git metadata is read-only" do
    test_root = Path.join(System.tmp_dir!(), "symphony-provenance-readonly-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MIC-167-READONLY")

    try do
      File.mkdir_p!(workspace)
      initialize_git_workspace!(workspace)
      git!(workspace, ["remote", "add", "origin", "https://github.com/datawarsaw/symphony.git"])
      head = git_output!(workspace, ["rev-parse", "--verify", "HEAD^{commit}"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        routing: routing("/host/symphony")
      )

      readonly_git_metadata!(Path.join(workspace, ".git"))

      assert {:error, _reason} = File.write(Path.join([workspace, ".git", "probe"]), "must fail\n")
      assert {:error, _reason} = File.write(Path.join([workspace, ".git", "config"]), "must fail\n")
      assert :ok = File.write(Path.join(workspace, "README.md"), "agent source edit\n")

      issue = %Issue{id: "mic-167-readonly", identifier: "MIC-167-READONLY", labels: ["repo:symphony-runtime"]}

      assert {:ok, %{prepared_base_commit: ^head, repository_origin: "https://github.com/datawarsaw/symphony.git"}} =
               Workspace.capture_provenance(workspace, issue)

      assert git_output!(workspace, ["diff", "--", "README.md"]) =~ "agent source edit"
    after
      restore_git_metadata_permissions(Path.join(workspace, ".git"))
      File.rm_rf(test_root)
    end
  end

  test "fails closed when a routed workspace has no prepared commit" do
    test_root = Path.join(System.tmp_dir!(), "symphony-provenance-missing-head-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MIC-167-NO-HEAD")

    try do
      File.mkdir_p!(workspace)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root, routing: routing("/host/symphony"))
      issue = %Issue{id: "mic-167-no-head", identifier: "MIC-167-NO-HEAD", labels: ["repo:symphony-runtime"]}

      assert {:error, {:workspace_provenance_failed, :git_read_failed}} =
               Workspace.capture_provenance(workspace, issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "uses the selected route snapshot after workflow configuration reload" do
    test_root = Path.join(System.tmp_dir!(), "symphony-provenance-route-snapshot-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MIC-167-ROUTE-SNAPSHOT")

    try do
      File.mkdir_p!(workspace)
      initialize_git_workspace!(workspace)
      initial_source = "/host/selected-source"
      replacement_source = "/host/reloaded-source"
      hook = "printf '%s' \"$SYMPHONY_REPOSITORY_SOURCE_PATH\" > selected-route.txt"
      issue = %Issue{id: "mic-167-route", identifier: "MIC-167-ROUTE-SNAPSHOT", labels: ["repo:symphony-runtime"]}

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        routing: routing(initial_source),
        hook_before_run: hook
      )

      assert {:ok, route} = RepositoryRouter.resolve(issue, Config.settings!().routing)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        routing: routing(replacement_source),
        hook_before_run: hook
      )

      assert :ok = Workspace.run_before_run_hook(workspace, issue, nil, route)
      assert File.read!(Path.join(workspace, "selected-route.txt")) == initial_source
      assert {:ok, provenance} = Workspace.capture_provenance(workspace, issue, nil, route)
      assert provenance.repository_source_path == initial_source
    after
      File.rm_rf(test_root)
    end
  end

  defp initialize_git_workspace!(workspace) do
    git!(workspace, ["init", "-b", "main"])
    git!(workspace, ["config", "user.name", "Test User"])
    git!(workspace, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(workspace, "README.md"), "prepared source\n")
    git!(workspace, ["add", "README.md"])
    git!(workspace, ["commit", "-m", "prepared base"])
  end

  defp routing(source_path) do
    %{
      target_label_prefix: "repo:",
      default_branch: "main",
      targets: %{"symphony-runtime" => %{source_path: source_path}}
    }
  end

  defp readonly_git_metadata!(git_dir) do
    case :os.type() do
      {:win32, _} ->
        sid = current_user_sid!()
        {_output, 0} = System.cmd("icacls", [git_dir, "/deny", "*#{sid}:(OI)(CI)(WD,AD,WA,WEA)"])

      _ ->
        {_, 0} = System.cmd("chmod", ["-R", "a-w", git_dir])
    end
  end

  defp restore_git_metadata_permissions(git_dir) do
    case :os.type() do
      {:win32, _} ->
        sid = current_user_sid!()
        System.cmd("icacls", [git_dir, "/remove:d", "*#{sid}"])

      _ ->
        if File.dir?(git_dir) do
          System.cmd("chmod", ["-R", "u+w", git_dir])
        end
    end
  end

  defp current_user_sid! do
    {output, 0} = System.cmd("whoami", ["/user", "/fo", "csv", "/nh"])

    output
    |> String.trim()
    |> String.split(",")
    |> List.last()
    |> String.trim("\"")
  end

  defp git!(workspace, args) do
    case System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{output}")
    end
  end

  defp git_output!(workspace, args) do
    case System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{output}")
    end
  end
end
