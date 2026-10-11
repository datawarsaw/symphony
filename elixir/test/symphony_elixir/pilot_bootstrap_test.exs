defmodule SymphonyElixir.PilotBootstrapTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.PilotBootstrap
  alias SymphonyElixir.RepositoryRouter
  alias SymphonyElixir.Tracker.Issue

  @sha "0123456789abcdef0123456789abcdef01234567"
  @drift "fedcba9876543210fedcba9876543210fedcba98"
  @target "symphony-runtime"

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-pilot-boot-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(Path.join(root, "source/elixir"))
    File.mkdir_p!(Path.join(root, "config"))
    File.mkdir_p!(Path.join(root, "workspace-root"))
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  # -- the as-prepared pilot configuration ---------------------------------

  test "disabled pilot configuration passes preflight and reports its arming blockers", %{root: root} do
    write_tracked_default(root)
    write_pilot_workflow(root)
    manifest = write_manifest(root)

    assert {:ok, report} = PilotBootstrap.preflight(manifest, gate(root))

    refute report.armed_ready?
    assert blocker?(report, :tracker_arming)
    assert blocker?(report, :opencode_arming)
    assert blocker?(report, :routing_arming)
    assert blocker?(report, :route_proof)
    refute blocker?(report, :harness_selection)
    assert report.routing_targets == []
    assert report.source_sha == @sha
  end

  test "the effective log path is inside the dedicated pilot directory", %{root: root} do
    write_tracked_default(root)
    write_pilot_workflow(root)
    manifest = write_manifest(root)

    assert {:ok, report} = PilotBootstrap.preflight(manifest, gate(root))
    assert report.log_file == slash(Path.join([logs_root(root), "log", "symphony.log"]))
    assert report.logs_root == slash(logs_root(root))
  end

  # -- workflow selection ---------------------------------------------------

  test "preflight rejects the tracked production workflow as the pilot workflow", %{root: root} do
    write_tracked_default(root)
    write_pilot_workflow(root)
    tracked = source_workflow(root)
    manifest = write_manifest(root, workflow: tracked)

    assert {:error, {:pilot_bootstrap_failed, failures}} = PilotBootstrap.preflight(manifest, gate(root))
    assert failure?(failures, :workflow_identity)
    refute failure?(failures, :workflow_load)
  end

  test "preflight rejects a pilot workflow whose content is the tracked default", %{root: root} do
    tracked_content = "---\ntracker:\n  kind: linear\n---\nDEFAULT PRODUCTION PROMPT\n"
    File.write!(source_workflow(root), tracked_content)
    File.write!(pilot_workflow(root), tracked_content)
    manifest = write_manifest(root)

    assert {:error, {:pilot_bootstrap_failed, failures}} = PilotBootstrap.preflight(manifest, gate(root))
    assert failure?(failures, :workflow_identity)
    assert {:workflow_matches_tracked_default, _tracked} = List.keyfind(failures, :workflow_identity, 0) |> elem(1)
  end

  test "preflight rejects a missing explicit workflow before anything else can start", %{root: root} do
    write_tracked_default(root)
    write_pilot_workflow(root)
    File.rm!(pilot_workflow(root))
    manifest = write_manifest(root)

    assert {:error, {:pilot_bootstrap_failed, failures}} = PilotBootstrap.preflight(manifest, gate(root))
    assert failure?(failures, :workflow_load)
  end

  # -- workspace, logs and source boundaries --------------------------------

  test "preflight rejects a workspace root outside the pilot directory", %{root: root} do
    write_tracked_default(root)
    write_pilot_workflow(root)
    elsewhere = Path.join(System.tmp_dir!(), "symphony-pilot-elsewhere-" <> Integer.to_string(System.unique_integer([:positive])))
    manifest = write_manifest(root, workspace_root: elsewhere)

    assert {:error, {:pilot_bootstrap_failed, failures}} = PilotBootstrap.preflight(manifest, gate(root))
    assert failure?(failures, :workspace_root)
  end

  test "preflight rejects a workspace root that points into the pilot source checkout", %{root: root} do
    write_tracked_default(root)
    inside_source = Path.join([root, "source", "ws"])
    write_pilot_workflow(root, workspace: inside_source)
    manifest = write_manifest(root, workspace_root: inside_source)

    assert {:error, {:pilot_bootstrap_failed, failures}} = PilotBootstrap.preflight(manifest, gate(root))
    assert failure?(failures, :workspace_root)
  end

  test "preflight rejects a log root outside the pilot directory", %{root: root} do
    write_tracked_default(root)
    write_pilot_workflow(root)
    elsewhere = Path.join(System.tmp_dir!(), "symphony-pilot-logs-" <> Integer.to_string(System.unique_integer([:positive])))
    manifest = write_manifest(root, logs_root: elsewhere)

    assert {:error, {:pilot_bootstrap_failed, failures}} = PilotBootstrap.preflight(manifest, gate(root))
    assert failure?(failures, :logs_root)
  end

  test "preflight rejects a workspace or log root that overlaps a protected root", %{root: root} do
    write_tracked_default(root)
    write_pilot_workflow(root)
    protected = Path.join(root, "legacy-runtime")
    File.mkdir_p!(protected)
    manifest = write_manifest(root, workspace_root: Path.join(protected, "workspace"))
    gate_opts = Keyword.put(gate(root), :protected_roots, [protected])

    assert {:error, {:pilot_bootstrap_failed, failures}} = PilotBootstrap.preflight(manifest, gate_opts)
    assert failure?(failures, :manifest_paths)
  end

  test "preflight rejects a source root that points at a protected checkout", %{root: root} do
    protected = Path.join(root, "protected-source")
    File.mkdir_p!(Path.join(protected, "elixir"))
    write_tracked_default(root)
    write_pilot_workflow(root)
    manifest = write_manifest(root, source_root: protected)
    gate_opts = Keyword.put(gate(root), :protected_roots, [protected])

    assert {:error, {:pilot_bootstrap_failed, failures}} = PilotBootstrap.preflight(manifest, gate_opts)

    assert {:protected_path_reference, :source_root, _root, _path} =
             List.keyfind(failures, :manifest_paths, 0) |> elem(1)
  end

  test "preflight rejects a source head that does not match the approved commit", %{root: root} do
    write_tracked_default(root)
    write_pilot_workflow(root)
    manifest = write_manifest(root)
    gate_opts = Keyword.put(gate(root), :git, git_stub(@drift))

    assert {:error, {:pilot_bootstrap_failed, failures}} = PilotBootstrap.preflight(manifest, gate_opts)
    assert failure?(failures, :source_identity)
  end

  test "preflight rejects a modified tracked tree, including the legacy workflow copy", %{root: root} do
    write_tracked_default(root)
    write_pilot_workflow(root)
    manifest = write_manifest(root)
    gate_opts = Keyword.put(gate(root), :git, git_stub(@sha, " M elixir/WORKFLOW.md\n"))

    assert {:error, {:pilot_bootstrap_failed, failures}} = PilotBootstrap.preflight(manifest, gate_opts)
    assert {:source_worktree_dirty, _status} = List.keyfind(failures, :source_identity, 0) |> elem(1)
  end

  test "preflight rejects a working directory other than the pilot source elixir directory", %{root: root} do
    write_tracked_default(root)
    write_pilot_workflow(root)
    manifest = write_manifest(root)
    gate_opts = Keyword.put(gate(root), :cwd, root)

    assert {:error, {:pilot_bootstrap_failed, failures}} = PilotBootstrap.preflight(manifest, gate_opts)
    assert failure?(failures, :source_identity)
  end

  # -- arming ---------------------------------------------------------------

  test "an armed configuration with one approved target passes preflight", %{root: root} do
    armed = armed_workflow_opts(root)
    write_tracked_default(root)
    write_pilot_workflow(root, armed)
    manifest = write_manifest(root, armed_manifest_opts(root))
    gate_opts = gate(root) ++ [mode: :armed]

    assert {:ok, report} = PilotBootstrap.preflight(manifest, gate_opts)
    assert report.armed_ready?
    assert report.arming_blockers == []
    assert report.routing_targets == [@target]
    assert report.approved_repo_target == @target

    opencode = %{
      enabled: true,
      provider: "openrouter",
      model: "approved-model",
      timeout_ms: 300_000,
      allowed_tools: ["read", "edit"],
      allowed_issues: ["PILOT-1"]
    }

    assert {:opencode, :opencode_selected} =
             SymphonyElixir.HarnessSelection.select(%Issue{identifier: "PILOT-1"}, opencode)

    assert {:codex, :issue_not_authorized} =
             SymphonyElixir.HarnessSelection.select(%Issue{identifier: "PILOT-2"}, opencode)
  end

  test "an armed configuration with no routing target is refused", %{root: root} do
    armed = Keyword.delete(armed_workflow_opts(root), :targets)
    write_tracked_default(root)
    write_pilot_workflow(root, armed)
    manifest = write_manifest(root, armed_manifest_opts(root))

    assert {:error, {:pilot_bootstrap_refused, failures}} =
             PilotBootstrap.preflight(manifest, gate(root) ++ [mode: :armed])

    assert failure?(failures, :routing_arming)
    assert failure?(failures, :route_proof)
  end

  test "an armed configuration with a blank authorized issue entry is refused by the schema", %{root: root} do
    armed = Keyword.put(armed_workflow_opts(root), :allowed_issues, ~s(["PILOT-1", ""]))
    write_tracked_default(root)
    write_pilot_workflow(root, armed)
    manifest = write_manifest(root, armed_manifest_opts(root))

    assert {:error, {:pilot_bootstrap_refused, failures}} =
             PilotBootstrap.preflight(manifest, gate(root) ++ [mode: :armed])

    assert failure?(failures, :workflow_load)
  end

  test "an armed configuration with an empty authorized issue list is refused", %{root: root} do
    armed = Keyword.put(armed_workflow_opts(root), :allowed_issues, "[]")
    write_tracked_default(root)
    write_pilot_workflow(root, armed)
    manifest = write_manifest(root, armed_manifest_opts(root))

    assert {:error, {:pilot_bootstrap_refused, failures}} =
             PilotBootstrap.preflight(manifest, gate(root) ++ [mode: :armed])

    assert List.keyfind(failures, :opencode_arming, 0) ==
             {:opencode_arming, :opencode_allowed_issues_empty}
  end

  test "an armed configuration with a remote worker host is refused", %{root: root} do
    armed = Keyword.put(armed_workflow_opts(root), :ssh_hosts, ~s(["builder@remote"]))
    write_tracked_default(root)
    write_pilot_workflow(root, armed)
    manifest = write_manifest(root, armed_manifest_opts(root))

    assert {:error, {:pilot_bootstrap_refused, failures}} =
             PilotBootstrap.preflight(manifest, gate(root) ++ [mode: :armed])

    assert failure?(failures, :worker_containment)
  end

  test "the routing contract refuses an unlabelled issue once a target is authorized" do
    routing = %SymphonyElixir.Config.Schema.Routing{
      targets: %{@target => %{"source_path" => "C:/pilot/approved-source"}}
    }

    unlabelled = %Issue{identifier: "PILOT-ROUTE-PROOF", labels: []}
    labelled = %Issue{identifier: "PILOT-ROUTE-PROOF", labels: ["repo:" <> @target]}

    assert {:error, :missing_repository_target} = RepositoryRouter.resolve(unlabelled, routing)
    assert {:ok, %RepositoryRouter.Route{target: @target}} = RepositoryRouter.resolve(labelled, routing)
  end

  # -- start ----------------------------------------------------------------

  test "start refuses a disabled configuration without starting the runtime", %{root: root} do
    write_tracked_default(root)
    write_pilot_workflow(root)
    manifest = write_manifest(root)
    before = Application.get_env(:symphony_elixir, :workflow_file_path)
    test_pid = self()

    ensure = fn ->
      send(test_pid, :runtime_started)
      {:ok, []}
    end

    assert {:error, {:pilot_bootstrap_refused, failures}} =
             PilotBootstrap.start(manifest, [ensure_all_started: ensure] ++ gate(root))

    assert failure?(failures, :opencode_arming)
    refute_received :runtime_started
    assert Application.get_env(:symphony_elixir, :workflow_file_path) == before
  end

  # -- helpers --------------------------------------------------------------

  defp gate(root) do
    [cwd: source_elixir(root), git: git_stub(@sha)]
  end

  defp git_stub(sha, status \\ "") do
    fn _dir, args ->
      case args do
        ["rev-parse", "HEAD"] -> {:ok, sha <> "\n"}
        ["status", "--porcelain", "--untracked-files=no"] -> {:ok, status}
        other -> {:error, {:unexpected_git, other}}
      end
    end
  end

  defp blocker?(report, name), do: Enum.any?(report.arming_blockers, fn {n, _r} -> n == name end)
  defp failure?(failures, name), do: Enum.any?(failures, fn {n, _r} -> n == name end)

  defp source_elixir(root), do: Path.join([root, "source", "elixir"])
  defp source_workflow(root), do: Path.join([root, "source", "elixir", "WORKFLOW.md"])
  defp pilot_workflow(root), do: Path.join([root, "config", "WORKFLOW.md"])
  defp workspace_root(root), do: Path.join(root, "workspace-root")
  defp logs_root(root), do: Path.join(root, "logs")
  defp approved_source(root), do: Path.join(root, "approved-source")

  defp write_tracked_default(root) do
    File.write!(source_workflow(root), "---\ntracker:\n  kind: linear\n---\nDEFAULT PRODUCTION PROMPT\n")
  end

  defp write_pilot_workflow(root, opts \\ []) do
    lines =
      [
        "---",
        "tracker:",
        "  kind: linear",
        "  provider:",
        "    project_slug: " <> Keyword.get(opts, :project_slug, ~s("PILOT_PROJECT_SLUG_REQUIRED")),
        "  required_labels:",
        "    - symphony-pilot-queued",
        "workspace:",
        ~s(  root: ") <> slash(Keyword.get(opts, :workspace, workspace_root(root))) <> ~s("),
        "routing:",
        ~s(  target_label_prefix: "repo:"),
        ~s(  default_branch: "main"),
        "  targets: " <> Keyword.get(opts, :targets, "{}"),
        "worker:",
        "  ssh_hosts: " <> Keyword.get(opts, :ssh_hosts, "[]"),
        "agent:",
        "  max_concurrent_agents: " <> to_string(Keyword.get(opts, :max_concurrent_agents, 1)),
        "  max_turns: " <> to_string(Keyword.get(opts, :max_turns, 1)),
        "discovery:",
        "  enabled: false",
        "opencode:",
        "  enabled: " <> to_string(Keyword.get(opts, :opencode_enabled, false)),
        "  allowed_issues: " <> Keyword.get(opts, :allowed_issues, "[]"),
        "  allowed_tools: " <> Keyword.get(opts, :allowed_tools, "[]")
      ] ++
        Keyword.get(opts, :opencode_extra_lines, []) ++
        [
          "codex:",
          "  worker_containment_enabled: " <> to_string(Keyword.get(opts, :containment, true)),
          "---",
          "",
          "PILOT PROMPT"
        ]

    File.write!(pilot_workflow(root), Enum.join(lines, "\n") <> "\n")
    pilot_workflow(root)
  end

  defp write_manifest(root, opts \\ []) do
    path = Path.join(root, "config/pilot-bootstrap.yml")

    lines = [
      ~s(pilot_id: "pilot-m1-opencode"),
      ~s(pilot_root: ") <> slash(root) <> ~s("),
      ~s(source_root: ") <> slash(Keyword.get(opts, :source_root, Path.join(root, "source"))) <> ~s("),
      ~s(expected_source_sha: ") <> Keyword.get(opts, :sha, @sha) <> ~s("),
      ~s(workflow_path: ") <> slash(Keyword.get(opts, :workflow, pilot_workflow(root))) <> ~s("),
      ~s(workspace_root: ") <> slash(Keyword.get(opts, :workspace_root, workspace_root(root))) <> ~s("),
      ~s(logs_root: ") <> slash(Keyword.get(opts, :logs_root, logs_root(root))) <> ~s("),
      ~s(approved_repo_target: ") <>
        Keyword.get(opts, :approved_repo_target, "REPLACE_WITH_APPROVED_REPO_TARGET") <> ~s("),
      ~s(approved_source_path: ") <>
        slash(Keyword.get(opts, :approved_source_path, approved_source(root))) <> ~s(")
    ]

    File.write!(path, Enum.join(lines, "\n") <> "\n")
    path
  end

  defp armed_workflow_opts(root) do
    [
      project_slug: ~s("pilot-project"),
      targets: ~s({"#{@target}": {source_path: "#{slash(approved_source(root))}"}}),
      opencode_enabled: true,
      allowed_issues: ~s(["PILOT-1"]),
      allowed_tools: ~s(["read", "edit"]),
      opencode_extra_lines: [
        ~s(  provider: "openrouter"),
        ~s(  model: "approved-model"),
        "  timeout_ms: 300000"
      ]
    ]
  end

  defp armed_manifest_opts(root) do
    [approved_repo_target: @target, approved_source_path: approved_source(root)]
  end

  defp slash(path), do: String.replace(path, <<92>>, "/")
end
