defmodule SymphonyElixir.PilotBootstrapWindowsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.PilotBootstrap

  # PILOT-BOOT-R regression cases: every boundary decision must be made on the
  # real filesystem location of a path, so links and aliases that leave the
  # pilot directory are rejected however they are spelled, while ordinary
  # in-bound paths (including harmless alias spellings and in-bound links) pass.

  @sha "0123456789abcdef0123456789abcdef01234567"

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-pilot-guard-f2-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(Path.join(root, "source/elixir"))
    File.mkdir_p!(Path.join(root, "config"))
    File.mkdir_p!(Path.join(root, "workspace-root"))
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  test "preflight rejects a workspace root that escapes the pilot directory directly", %{root: root} do
    write_tracked_default(root)
    write_pilot_workflow(root)
    elsewhere = outside_dir(root, "elsewhere")
    manifest = write_manifest(root, workspace_root: Path.join(elsewhere, "ws"))

    assert {:error, {:pilot_bootstrap_failed, failures}} = PilotBootstrap.preflight(manifest, gate(source_elixir(root)))
    assert failure?(failures, :workspace_root)
  end

  test "preflight keeps passing for ordinary in-bound paths", %{root: root} do
    write_tracked_default(root)
    write_pilot_workflow(root)
    manifest = write_manifest(root)

    assert {:ok, _report} = PilotBootstrap.preflight(manifest, gate(source_elixir(root)))
  end

  if match?({:win32, _}, :os.type()) do
    test "preflight rejects a logs root junction into the protected legacy runtime (PILOT-BOOT-R)", %{root: root} do
      protected = Path.join(root, "legacy-runtime")
      File.mkdir_p!(protected)
      File.write!(Path.join(protected, "marker.txt"), "protected")
      logs_link = Path.join(root, "logs-link")
      make_junction!(logs_link, protected)
      remove_link_on_exit(logs_link)

      write_tracked_default(root)
      write_pilot_workflow(root)
      manifest = write_manifest(root, logs_root: logs_link)

      assert {:error, {:pilot_bootstrap_failed, failures}} =
               PilotBootstrap.preflight(manifest, gate(source_elixir(root), [protected]))

      assert {:protected_path_reference, :logs_root, _resolved_root, _resolved_path} =
               failure_reason(failures, :manifest_paths)

      assert failure?(failures, :logs_root)

      # validation stays non-destructive: the link and the protected tree survive it
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(logs_link)
      assert File.read!(Path.join(protected, "marker.txt")) == "protected"
      assert File.ls!(protected) == ["marker.txt"]
    end

    test "preflight rejects a workspace root junction out of the pilot directory", %{root: root} do
      elsewhere = outside_dir(root, "elsewhere")
      File.mkdir_p!(Path.join(elsewhere, "ws"))
      ws_link = Path.join(root, "ws-link")
      make_junction!(ws_link, Path.join(elsewhere, "ws"))
      remove_link_on_exit(ws_link)

      write_tracked_default(root)
      write_pilot_workflow(root, workspace: Path.join(elsewhere, "ws"))
      manifest = write_manifest(root, workspace_root: ws_link)

      assert {:error, {:pilot_bootstrap_failed, failures}} =
               PilotBootstrap.preflight(manifest, gate(source_elixir(root)))

      assert {:workspace_root_outside_pilot, path} = failure_reason(failures, :workspace_root)
      assert slash(path) == slash(ws_link)
    end

    test "preflight rejects a junction chain that leaves the pilot directory", %{root: root} do
      protected = Path.join(root, "legacy-runtime")
      File.mkdir_p!(Path.join(protected, "ws"))
      hop = Path.join(root, "hop")
      make_junction!(hop, protected)
      chain = Path.join(root, "chain")
      make_junction!(chain, hop)
      remove_link_on_exit(chain)
      remove_link_on_exit(hop)

      write_tracked_default(root)
      write_pilot_workflow(root, workspace: Path.join(protected, "ws"))
      manifest = write_manifest(root, workspace_root: chain)

      assert {:error, {:pilot_bootstrap_failed, failures}} =
               PilotBootstrap.preflight(manifest, gate(source_elixir(root), [protected]))

      assert {:protected_path_reference, :workspace_root, _resolved_root, _resolved_path} =
               failure_reason(failures, :manifest_paths)
    end

    test "preflight rejects an escape through an ancestor junction", %{root: root} do
      elsewhere = outside_dir(root, "elsewhere")
      File.mkdir_p!(Path.join(elsewhere, "nested/ws"))
      ancestor_link = Path.join(root, "ancestor-link")
      make_junction!(ancestor_link, Path.join(elsewhere, "nested"))
      remove_link_on_exit(ancestor_link)

      write_tracked_default(root)
      write_pilot_workflow(root, workspace: Path.join(elsewhere, "nested/ws"))
      manifest = write_manifest(root, workspace_root: Path.join(ancestor_link, "ws"))

      assert {:error, {:pilot_bootstrap_failed, failures}} =
               PilotBootstrap.preflight(manifest, gate(source_elixir(root)))

      assert failure?(failures, :workspace_root)
    end

    test "preflight rejects a directory symlink escape", %{root: root} do
      elsewhere = outside_dir(root, "elsewhere")
      File.mkdir_p!(Path.join(elsewhere, "ws"))
      link = Path.join(root, "ws-slink")

      case make_dir_symlink(link, Path.join(elsewhere, "ws")) do
        :ok ->
          remove_link_on_exit(link)
          write_tracked_default(root)
          write_pilot_workflow(root, workspace: Path.join(elsewhere, "ws"))
          manifest = write_manifest(root, workspace_root: link)

          assert {:error, {:pilot_bootstrap_failed, failures}} =
                   PilotBootstrap.preflight(manifest, gate(source_elixir(root)))

          assert failure?(failures, :workspace_root)

        {:error, out} ->
          IO.warn("skipping directory symlink escape case: mklink /D unavailable: #{out}")
      end
    end

    test "preflight rejects a file symlink workflow escape", %{root: root} do
      elsewhere = outside_dir(root, "elsewhere")
      File.write!(Path.join(elsewhere, "WORKFLOW.md"), "---\ntracker:\n  kind: linear\n---\nLINKED PROMPT\n")
      link = Path.join(root, "config/workflow-link.md")

      case make_file_symlink(link, Path.join(elsewhere, "WORKFLOW.md")) do
        :ok ->
          remove_file_link_on_exit(link)
          write_tracked_default(root)
          manifest = write_manifest(root, workflow: link)

          assert {:error, {:pilot_bootstrap_failed, failures}} =
                   PilotBootstrap.preflight(manifest, gate(source_elixir(root)))

          assert failure?(failures, :workflow_identity)

        {:error, out} ->
          IO.warn("skipping file symlink escape case: mklink unavailable: #{out}")
      end
    end

    test "preflight rejects a link loop as an unresolvable path", %{root: root} do
      loop = Path.join(root, "loop")
      make_junction!(loop, loop)
      remove_link_on_exit(loop)

      write_tracked_default(root)
      write_pilot_workflow(root)
      manifest = write_manifest(root, workspace_root: Path.join(loop, "ws"))

      assert {:error, {:pilot_bootstrap_failed, failures}} =
               PilotBootstrap.preflight(manifest, gate(source_elixir(root)))

      assert {:path_unresolvable, :workspace_root, _path, _reason} =
               failure_reason(failures, :manifest_paths)
    end

    test "preflight rejects a device-path alias escape with forward slashes", %{root: root} do
      write_tracked_default(root)
      write_pilot_workflow(root)
      elsewhere = outside_dir(root, "elsewhere")
      device_alias = "//?/" <> slash(Path.join(elsewhere, "ws"))
      manifest = write_manifest(root, workspace_root: device_alias)

      assert {:error, {:pilot_bootstrap_failed, failures}} =
               PilotBootstrap.preflight(manifest, gate(source_elixir(root)))

      assert failure?(failures, :workspace_root)
    end

    test "preflight rejects a device-path alias escape spelled with backslashes", %{root: root} do
      write_tracked_default(root)
      write_pilot_workflow(root)
      elsewhere = outside_dir(root, "elsewhere")

      manifest =
        write_manifest(root,
          workspace_root_yaml: "'#{device_prefix()}#{win(Path.join(elsewhere, "ws"))}'"
        )

      assert {:error, {:pilot_bootstrap_failed, failures}} =
               PilotBootstrap.preflight(manifest, gate(source_elixir(root)))

      assert failure?(failures, :workspace_root)
    end

    test "preflight rejects a pilot root that is a junction into a protected tree", %{root: root} do
      protected = Path.join(root, "legacy-runtime")
      File.mkdir_p!(Path.join(protected, "source/elixir"))
      File.mkdir_p!(Path.join(protected, "config"))
      File.mkdir_p!(Path.join(protected, "workspace-root"))
      pilot_link = Path.join(root, "pilot-link")
      make_junction!(pilot_link, protected)
      remove_link_on_exit(pilot_link)

      File.write!(Path.join(protected, "source/elixir/WORKFLOW.md"), "---\ntracker:\n  kind: linear\n---\nDEFAULT PRODUCTION PROMPT\n")
      File.write!(Path.join(protected, "config/WORKFLOW.md"), pilot_workflow_content(Path.join(protected, "workspace-root")))

      manifest =
        write_manifest(root,
          pilot_root: pilot_link,
          source_root: Path.join(pilot_link, "source"),
          workflow: Path.join(pilot_link, "config/WORKFLOW.md"),
          workspace_root: Path.join(pilot_link, "workspace-root"),
          logs_root: Path.join(pilot_link, "logs")
        )

      assert {:error, {:pilot_bootstrap_failed, failures}} =
               PilotBootstrap.preflight(manifest, gate(Path.join(protected, "source/elixir"), [protected]))

      assert {:protected_path_reference, _entry, _resolved_root, _resolved_path} =
               failure_reason(failures, :manifest_paths)
    end

    test "preflight preserves in-bound paths spelled with case, separator and device aliases", %{root: root} do
      write_tracked_default(root)
      write_pilot_workflow(root)

      manifest =
        write_manifest(root,
          pilot_root: String.upcase(slash(root)) <> "/",
          source_root: win(Path.join(root, "source")),
          workflow: String.upcase(slash(pilot_workflow(root))),
          workspace_root: "//?/" <> slash(workspace_root(root)),
          logs_root: slash(logs_root(root)) <> "/"
        )

      assert {:ok, _report} = PilotBootstrap.preflight(manifest, gate(source_elixir(root)))
    end

    test "preflight preserves a junction that stays inside the pilot directory", %{root: root} do
      real_ws = Path.join(root, "real-ws")
      File.mkdir_p!(real_ws)
      ws_link = Path.join(root, "ws-link")
      make_junction!(ws_link, real_ws)
      remove_link_on_exit(ws_link)

      write_tracked_default(root)
      write_pilot_workflow(root, workspace: real_ws)
      manifest = write_manifest(root, workspace_root: ws_link)

      assert {:ok, _report} = PilotBootstrap.preflight(manifest, gate(source_elixir(root)))
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp source_elixir(root), do: Path.join(root, "source/elixir")
  defp source_workflow(root), do: Path.join(root, "source/elixir/WORKFLOW.md")
  defp pilot_workflow(root), do: Path.join(root, "config/WORKFLOW.md")
  defp workspace_root(root), do: Path.join(root, "workspace-root")
  defp logs_root(root), do: Path.join(root, "logs")
  defp approved_source(root), do: Path.join(root, "approved-source")

  defp outside_dir(root, name) do
    dir = Path.join(Path.dirname(root), Path.basename(root) <> "-" <> name)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp gate(cwd, protected \\ nil) do
    gate = [cwd: cwd, git: git_stub()]

    if protected, do: Keyword.put(gate, :protected_roots, protected), else: gate
  end

  defp git_stub do
    fn _dir, args ->
      case args do
        ["rev-parse", "HEAD"] -> {:ok, @sha <> "\n"}
        ["status", "--porcelain", "--untracked-files=no"] -> {:ok, ""}
        other -> {:error, {:unexpected_git, other}}
      end
    end
  end

  defp failure?(failures, name), do: Enum.any?(failures, fn {n, _r} -> n == name end)

  defp failure_reason(failures, name) do
    {^name, reason} = List.keyfind(failures, name, 0)
    reason
  end

  defp write_tracked_default(root) do
    File.write!(source_workflow(root), "---\ntracker:\n  kind: linear\n---\nDEFAULT PRODUCTION PROMPT\n")
  end

  defp write_pilot_workflow(root, opts \\ []) do
    File.write!(pilot_workflow(root), pilot_workflow_content(Keyword.get(opts, :workspace, workspace_root(root))))
    pilot_workflow(root)
  end

  defp pilot_workflow_content(workspace) do
    lines = [
      "---",
      "tracker:",
      "  kind: linear",
      "  provider:",
      ~s(    project_slug: "PILOT_PROJECT_SLUG_REQUIRED"),
      "  required_labels:",
      "    - symphony-pilot-queued",
      "workspace:",
      ~s(  root: ") <> slash(workspace) <> ~s("),
      "routing:",
      ~s(  target_label_prefix: "repo:"),
      ~s(  default_branch: "main"),
      ~s(  targets: {}),
      "worker:",
      ~s(  ssh_hosts: []),
      "agent:",
      "  max_concurrent_agents: 1",
      "  max_turns: 1",
      "discovery:",
      "  enabled: false",
      "opencode:",
      "  enabled: false",
      ~s(  allowed_issues: []),
      ~s(  allowed_tools: []),
      "codex:",
      "  worker_containment_enabled: true",
      "---",
      "",
      "PILOT PROMPT"
    ]

    Enum.join(lines, "\n") <> "\n"
  end

  defp write_manifest(root, opts \\ []) do
    path = Path.join(root, "config/pilot-bootstrap.yml")

    workspace_yaml =
      Keyword.get_lazy(opts, :workspace_root_yaml, fn ->
        ~s(") <> slash(Keyword.get(opts, :workspace_root, workspace_root(root))) <> ~s(")
      end)

    lines = [
      ~s(pilot_id: "pilot-m1-opencode"),
      ~s(pilot_root: ") <> slash(Keyword.get(opts, :pilot_root, root)) <> ~s("),
      ~s(source_root: ") <> slash(Keyword.get(opts, :source_root, Path.join(root, "source"))) <> ~s("),
      ~s(expected_source_sha: ") <> @sha <> ~s("),
      ~s(workflow_path: ") <> slash(Keyword.get(opts, :workflow, pilot_workflow(root))) <> ~s("),
      "workspace_root: " <> workspace_yaml,
      ~s(logs_root: ") <> slash(Keyword.get(opts, :logs_root, logs_root(root))) <> ~s("),
      ~s(approved_repo_target: "REPLACE_WITH_APPROVED_REPO_TARGET"),
      ~s(approved_source_path: ") <> slash(Keyword.get(opts, :approved_source_path, approved_source(root))) <> ~s(")
    ]

    File.write!(path, Enum.join(lines, "\n") <> "\n")
    path
  end

  defp slash(path), do: String.replace(path, <<92>>, "/")
  defp win(path), do: String.replace(path, "/", "\\")
  defp device_prefix, do: String.duplicate("\\", 2) <> "?" <> "\\"

  defp make_junction!(link, target) do
    {out, status} = cmd_link(["/J", win(link), win(target)])
    assert status == 0, "mklink /J failed for #{link}: #{out}"
    link
  end

  defp make_dir_symlink(link, target) do
    {out, status} = cmd_link(["/D", win(link), win(target)])
    if status == 0, do: :ok, else: {:error, out}
  end

  defp make_file_symlink(link, target) do
    {out, status} = cmd_link([win(link), win(target)])
    if status == 0, do: :ok, else: {:error, out}
  end

  defp cmd_link(args) do
    System.cmd("cmd", ["/c", "mklink" | args], stderr_to_stdout: true)
  end

  # rmdir removes a junction without touching its target, so cleanup cannot
  # delete protected content through the link
  defp remove_link_on_exit(link) do
    on_exit(fn -> System.cmd("cmd", ["/c", "rmdir", win(link)], stderr_to_stdout: true) end)
  end

  defp remove_file_link_on_exit(link) do
    on_exit(fn -> System.cmd("cmd", ["/c", "del", win(link)], stderr_to_stdout: true) end)
  end
end
