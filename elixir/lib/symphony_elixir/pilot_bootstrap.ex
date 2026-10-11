defmodule SymphonyElixir.PilotBootstrap do
  @moduledoc """
  Fail-closed bootstrap gate for the isolated Symphony / OpenCode pilot.

  A bare `mix run` reads `WORKFLOW.md` from the current directory, the tracked
  production workflow is `elixir/WORKFLOW.md`, an empty routing allowlist resolves
  every issue to the default workspace, and an enabled OpenCode section still
  falls back to the Codex harness for issues it does not authorize. None of
  those defaults may decide whether a pilot runs.

  `preflight/2` reads an explicit pilot manifest and proves that the running
  checkout, the workflow file, the workspace root, the log root and the
  repository routing all belong to the pilot directory. `start/2` runs the same
  checks in `:armed` mode and refuses the whole start - before any tracker poll,
  worker dispatch or provider call - when something is missing, invalid,
  unverifiable, or points at a protected path.

  The gate is policy plus filesystem and `git` inspection. It contacts no tracker,
  prepares no workspace, invokes no provider and starts no process, so it runs
  offline and is safe to repeat.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.HarnessSelection
  alias SymphonyElixir.LogFile
  alias SymphonyElixir.RepositoryRouter
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Workflow

  @required_keys ~w(pilot_root source_root expected_source_sha workflow_path workspace_root logs_root)

  @placeholder_markers ["REPLACE_WITH", "PILOT_PROJECT_SLUG_REQUIRED", "CHANGE_ME", "PLACEHOLDER"]

  @default_protected_roots [
    "C:/Users/micha/symphony-source",
    "C:/Users/micha/symphony-runtime"
  ]

  @type mode :: :preflight | :armed

  @type env :: %{
          cwd: Path.t() | nil,
          git: (Path.t(), [String.t()] -> {:ok, String.t()} | {:error, term()}),
          protected_roots: [Path.t()],
          ensure_all_started: (-> {:ok, [atom()]} | {:error, term()})
        }

  @type report :: map()

  @doc """
  Runs the boundary checks, plus the arming checks in `:armed` mode.

  Returns `{:ok, report}` when the boundary checks pass. In `:armed` mode a
  non-empty arming blocker list is also a refusal. For `:preflight` the blockers are
  reported in `report.arming_blockers`, because a disabled pilot configuration is
  expected to be incomplete there.
  """
  @spec preflight(Path.t(), keyword()) :: {:ok, report()} | {:error, term()}
  def preflight(manifest_path, opts \\ []) do
    mode = Keyword.get(opts, :mode, :preflight)
    env = env(opts)
    manifest_path = Path.expand(manifest_path)

    with {:ok, manifest} <- load_manifest(manifest_path) do
      loaded = load_settings(manifest.workflow_path)
      boundary = boundary_checks(manifest, env, loaded)
      arming = arming_checks(manifest, loaded)
      failures = failures(boundary)
      blockers = failures(arming)

      cond do
        mode == :armed and failures ++ blockers != [] ->
          {:error, {:pilot_bootstrap_refused, failures ++ blockers}}

        failures != [] ->
          {:error, {:pilot_bootstrap_failed, failures}}

        true ->
          {:ok, report(mode, manifest, loaded, blockers)}
      end
    end
  end

  @doc """
  Runs the `:armed` gate and only then starts the runtime.

  The workflow file path and the log file are applied to the application
  environment before the application start, so the client never reads the
  tracked production workflow and the disk log cannot fall back to the default
  runtime location. A refusal returns before either is touched, leaving no
  partial configuration behind.
  """
  @spec start(Path.t(), keyword()) :: {:ok, report()} | {:error, term()}
  def start(manifest_path, opts \\ []) do
    env = env(opts)

    with {:ok, report} <- preflight(manifest_path, Keyword.merge(opts, mode: :armed)) do
      :ok = Workflow.set_workflow_file_path(report.workflow_path)
      Application.put_env(:symphony_elixir, :log_file, report.log_file)

      case env.ensure_all_started.() do
        {:ok, _started} -> {:ok, report}
        {:error, reason} -> {:error, {:runtime_start_failed, reason}}
      end
    end
  end

  defp env(opts) do
    %{
      cwd: Keyword.get(opts, :cwd, File.cwd!()),
      git: Keyword.get(opts, :git, &default_git/2),
      protected_roots: protected_roots(Keyword.get(opts, :protected_roots)),
      ensure_all_started:
        Keyword.get(opts, :ensure_all_started, fn ->
          Application.ensure_all_started(:symphony_elixir)
        end)
    }
  end

  defp protected_roots(nil), do: @default_protected_roots
  defp protected_roots([]), do: @default_protected_roots
  defp protected_roots(roots) when is_list(roots), do: roots

  defp default_git(dir, args) do
    case System.cmd("git", ["-C", dir | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:git_exit, status, String.trim(output)}}
    end
  rescue
    error in ErlangError -> {:error, {:git_unavailable, Exception.message(error)}}
  end

  # manifest

  defp load_manifest(path) do
    with :ok <- manifest_readable(path),
         {:ok, map} <- manifest_yaml(path),
         :ok <- validate_manifest_keys(map) do
      {:ok, normalize_manifest(map)}
    end
  end

  defp manifest_readable(path) do
    if File.regular?(path), do: :ok, else: {:error, {:manifest_missing, path}}
  end

  defp manifest_yaml(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, other} -> {:error, {:manifest_not_a_map, other}}
      {:error, reason} -> {:error, {:manifest_parse_error, reason}}
    end
  end

  defp validate_manifest_keys(map) do
    case Enum.reject(@required_keys, fn key -> nonblank?(Map.get(map, key)) end) do
      [] -> :ok
      missing -> {:error, {:manifest_missing_keys, missing}}
    end
  end

  defp normalize_manifest(map) do
    %{
      pilot_root: Map.get(map, "pilot_root"),
      source_root: Map.get(map, "source_root"),
      expected_source_sha: trim(Map.get(map, "expected_source_sha")),
      workflow_path: Map.get(map, "workflow_path"),
      workspace_root: Map.get(map, "workspace_root"),
      logs_root: Map.get(map, "logs_root"),
      approved_repo_target: trim(Map.get(map, "approved_repo_target")),
      approved_source_path: Map.get(map, "approved_source_path"),
      approved_remote: Map.get(map, "approved_remote")
    }
  end

  # workflow settings

  defp load_settings(path) when is_binary(path) do
    case Workflow.load(path) do
      {:ok, %{config: config}} ->
        case Schema.parse(config) do
          {:ok, settings} -> {:ok, settings}
          {:error, reason} -> {:error, {:workflow_schema_invalid, reason}}
        end

      {:error, reason} ->
        {:error, {:workflow_unreadable, reason}}
    end
  end

  defp load_settings(_path), do: {:error, {:workflow_unreadable, :missing_path}}

  # boundary checks

  defp boundary_checks(manifest, env, loaded) do
    [
      {:manifest_paths, check_manifest_paths(manifest, env.protected_roots)},
      {:source_identity, check_source_identity(manifest, env)},
      {:workflow_identity, check_workflow_identity(manifest)},
      {:workflow_load, check_workflow_load(loaded)},
      {:workspace_root, check_workspace_root(manifest, loaded)},
      {:logs_root, check_logs_root(manifest, env.protected_roots)},
      {:worker_containment, check_worker_containment(loaded)},
      {:routing_boundary, check_routing_boundary(manifest, loaded)}
    ]
  end

  defp check_manifest_paths(manifest, protected) do
    with :ok <- absolute_paths(manifest),
         :ok <- inside_pilot(manifest.source_root, manifest.pilot_root, :source_root_outside_pilot) do
      unprotected(manifest, protected)
    end
  end

  defp path_entries(manifest) do
    [
      {:pilot_root, manifest.pilot_root},
      {:source_root, manifest.source_root},
      {:workflow_path, manifest.workflow_path},
      {:workspace_root, manifest.workspace_root},
      {:logs_root, manifest.logs_root}
    ]
  end

  defp absolute_paths(manifest) do
    case Enum.reject(path_entries(manifest), fn {_name, path} -> Path.type(path) == :absolute end) do
      [] -> :ok
      [{name, path} | _rest] -> {:error, {:path_not_absolute, name, path}}
    end
  end

  defp inside_pilot(path, root, tag) do
    if inside?(path, root), do: :ok, else: {:error, {tag, path, root}}
  end

  defp unprotected(manifest, protected) do
    entries = Enum.reject(path_entries(manifest), fn {name, _path} -> name == :pilot_root end)

    case Enum.find_value(protected, fn root -> protected_reference(entries, root) end) do
      nil -> :ok
      error -> error
    end
  end

  defp protected_reference(entries, root) do
    case Enum.find(entries, fn {_name, path} -> overlaps?(path, root) end) do
      nil -> nil
      {name, path} -> {:error, {:protected_path_reference, name, root, path}}
    end
  end

  defp check_source_identity(manifest, env) do
    expected_cwd = Path.join(manifest.source_root, "elixir")

    with :ok <- same_directory(env.cwd, expected_cwd),
         {:ok, head} <- git_head(manifest, env),
         :ok <- head_matches(head, manifest.expected_source_sha) do
      clean_worktree(manifest, env)
    end
  end

  defp same_directory(nil, _expected), do: {:error, :source_cwd_unknown}

  defp same_directory(cwd, expected) do
    if normalize(cwd) == normalize(expected),
      do: :ok,
      else: {:error, {:source_cwd_mismatch, cwd, expected}}
  end

  defp git_head(manifest, env) do
    case env.git.(manifest.source_root, ["rev-parse", "HEAD"]) do
      {:ok, head} -> {:ok, String.trim(head)}
      {:error, reason} -> {:error, {:source_head_unverified, reason}}
    end
  end

  defp head_matches(head, expected) do
    if head == String.trim(expected),
      do: :ok,
      else: {:error, {:source_head_mismatch, head, expected}}
  end

  defp clean_worktree(manifest, env) do
    case env.git.(manifest.source_root, ["status", "--porcelain", "--untracked-files=no"]) do
      {:ok, output} ->
        case String.trim(output) do
          "" -> :ok
          status -> {:error, {:source_worktree_dirty, status}}
        end

      {:error, reason} ->
        {:error, {:source_status_unverified, reason}}
    end
  end

  defp check_workflow_identity(manifest) do
    workflow = manifest.workflow_path
    tracked = Path.join([manifest.source_root, "elixir", "WORKFLOW.md"])

    cond do
      not inside?(workflow, manifest.pilot_root) ->
        {:error, {:workflow_outside_pilot, workflow}}

      inside?(workflow, manifest.source_root) ->
        {:error, {:workflow_inside_source_checkout, workflow}}

      normalize(workflow) == normalize(tracked) ->
        {:error, {:default_workflow_rejected, workflow}}

      same_content?(workflow, tracked) ->
        {:error, {:workflow_matches_tracked_default, tracked}}

      true ->
        :ok
    end
  end

  defp same_content?(path, tracked) do
    case {File.read(path), File.read(tracked)} do
      {{:ok, a}, {:ok, b}} -> a == b
      _other -> false
    end
  end

  defp check_workflow_load({:ok, _settings}), do: :ok
  defp check_workflow_load({:error, reason}), do: {:error, reason}

  defp check_workspace_root(manifest, loaded) do
    root = manifest.workspace_root
    declared = declared_workspace_root(loaded)

    cond do
      not inside?(root, manifest.pilot_root) ->
        {:error, {:workspace_root_outside_pilot, root}}

      inside?(root, manifest.source_root) ->
        {:error, {:workspace_root_inside_source_checkout, root}}

      not nonblank?(declared) ->
        {:error, :workspace_root_missing}

      normalize(declared) != normalize(root) ->
        {:error, {:workspace_root_mismatch, declared, root}}

      true ->
        :ok
    end
  end

  defp declared_workspace_root({:ok, settings}), do: settings.workspace.root
  defp declared_workspace_root(_loaded), do: nil

  defp check_logs_root(manifest, protected) do
    root = manifest.logs_root

    cond do
      not inside?(root, manifest.pilot_root) -> {:error, {:logs_root_outside_pilot, root}}
      inside?(root, manifest.source_root) -> {:error, {:logs_root_inside_source_checkout, root}}
      Enum.any?(protected, &overlaps?(root, &1)) -> {:error, {:logs_root_protected, root}}
      true -> :ok
    end
  end

  defp check_worker_containment({:ok, settings}) do
    cond do
      settings.worker.ssh_hosts != [] ->
        {:error, {:remote_worker_hosts_not_allowed, settings.worker.ssh_hosts}}

      settings.codex.worker_containment_enabled != true ->
        {:error, :job_object_containment_disabled}

      settings.agent.max_concurrent_agents != 1 ->
        {:error, {:max_concurrent_agents_not_one, settings.agent.max_concurrent_agents}}

      settings.agent.max_turns != 1 ->
        {:error, {:max_turns_not_one, settings.agent.max_turns}}

      settings.discovery.enabled != false ->
        {:error, :discovery_not_disabled}

      true ->
        :ok
    end
  end

  defp check_worker_containment({:error, reason}), do: {:error, reason}

  defp check_routing_boundary(manifest, {:ok, settings}) do
    targets = settings.routing.targets || %{}
    approved = manifest.approved_source_path

    cond do
      map_size(targets) == 0 ->
        :ok

      not nonblank?(approved) ->
        {:error, {:unapproved_repository_targets, Map.keys(targets)}}

      not inside?(approved, manifest.pilot_root) ->
        {:error, {:approved_source_path_outside_pilot, approved}}

      true ->
        mismatched_source_path(targets, approved)
    end
  end

  defp check_routing_boundary(_manifest, {:error, reason}), do: {:error, reason}

  defp mismatched_source_path(targets, approved) do
    case Enum.find(targets, fn {_target, config} ->
           normalize(source_path(config)) != normalize(approved)
         end) do
      nil -> :ok
      {target, config} -> {:error, {:routing_source_path_mismatch, target, source_path(config), approved}}
    end
  end

  # arming checks

  defp arming_checks(manifest, loaded) do
    [
      {:tracker_arming, check_tracker_arming(loaded)},
      {:opencode_arming, check_opencode_arming(loaded)},
      {:routing_arming, check_routing_arming(manifest, loaded)},
      {:route_proof, check_route_proof(manifest, loaded)},
      {:harness_selection, check_harness_selection(loaded)}
    ]
  end

  defp check_tracker_arming({:ok, settings}) do
    slug = tracker_project_slug(settings)

    cond do
      settings.tracker.required_labels == [] -> {:error, :missing_required_labels}
      placeholder?(slug) -> {:error, {:tracker_project_slug_placeholder, slug}}
      true -> :ok
    end
  end

  defp check_tracker_arming({:error, reason}), do: {:error, reason}

  defp check_opencode_arming({:ok, settings}) do
    opencode = settings.opencode
    allowed_issues = opencode.allowed_issues || []

    cond do
      opencode.enabled != true -> {:error, :opencode_not_enabled}
      placeholder?(opencode.provider) -> {:error, {:opencode_provider_placeholder, opencode.provider}}
      placeholder?(opencode.model) -> {:error, {:opencode_model_placeholder, opencode.model}}
      opencode.allowed_tools == [] -> {:error, :opencode_allowed_tools_empty}
      allowed_issues == [] -> {:error, :opencode_allowed_issues_empty}
      Enum.any?(allowed_issues, &placeholder?/1) -> {:error, {:opencode_allowed_issues_placeholder, allowed_issues}}
      true -> :ok
    end
  end

  defp check_opencode_arming({:error, reason}), do: {:error, reason}

  defp check_routing_arming(manifest, {:ok, settings}) do
    targets = settings.routing.targets || %{}
    approved = manifest.approved_repo_target

    cond do
      placeholder?(approved) ->
        {:error, {:approved_repo_target_required, approved}}

      map_size(targets) != 1 ->
        {:error, {:routing_targets_not_exactly_one, Map.keys(targets)}}

      not Map.has_key?(targets, approved) ->
        {:error, {:approved_repo_target_not_in_routing, approved, Map.keys(targets)}}

      true ->
        :ok
    end
  end

  defp check_routing_arming(_manifest, {:error, reason}), do: {:error, reason}

  defp check_route_proof(manifest, {:ok, settings}) do
    approved = manifest.approved_repo_target

    if placeholder?(approved) do
      {:error, {:route_proof_unavailable, :approved_repo_target_missing}}
    else
      labelled_route_proof(settings.routing, approved)
    end
  end

  defp check_route_proof(_manifest, {:error, reason}), do: {:error, reason}

  defp labelled_route_proof(routing, approved) do
    prefix = routing.target_label_prefix || "repo:"
    labelled = %Issue{identifier: "PILOT-ROUTE-PROOF", labels: [prefix <> approved]}
    unlabelled = %Issue{identifier: "PILOT-ROUTE-PROOF", labels: []}

    case RepositoryRouter.resolve(labelled, routing) do
      {:ok, %RepositoryRouter.Route{} = route} ->
        unlabelled_route_proof(routing, route, unlabelled, approved)

      {:ok, nil} ->
        {:error, {:labelled_issue_unrouted, :no_routing_targets}}

      {:error, reason} ->
        {:error, {:labelled_issue_unrouted, reason}}
    end
  end

  defp unlabelled_route_proof(routing, route, unlabelled, approved) do
    case route_matches(route, approved) do
      :ok -> unlabelled_refused(RepositoryRouter.resolve(unlabelled, routing))
      error -> error
    end
  end

  defp route_matches(%RepositoryRouter.Route{target: target}, approved) do
    if target == approved, do: :ok, else: {:error, {:route_proof_wrong_target, target, approved}}
  end

  defp unlabelled_refused({:error, :missing_repository_target}), do: :ok
  defp unlabelled_refused({:ok, nil}), do: {:error, :unlabelled_issue_routable}
  defp unlabelled_refused(other), do: {:error, {:unlabelled_issue_unexpected, other}}

  defp check_harness_selection({:ok, settings}) do
    issues = settings.opencode.allowed_issues || []

    case Enum.find(issues, fn identifier -> select_harness(identifier, settings) != :ok end) do
      nil -> :ok
      identifier -> {:error, {:unexpected_harness_selection, identifier, select_harness(identifier, settings)}}
    end
  end

  defp check_harness_selection({:error, reason}), do: {:error, reason}

  defp select_harness(identifier, settings) do
    case HarnessSelection.select(%Issue{identifier: identifier}, settings.opencode) do
      {:opencode, :opencode_selected} -> :ok
      other -> {:error, other}
    end
  end

  # helpers

  defp failures(results) do
    for {name, {:error, reason}} <- results, do: {name, reason}
  end

  defp report(mode, manifest, loaded, blockers) do
    %{
      mode: mode,
      pilot_root: manifest.pilot_root,
      source_root: manifest.source_root,
      source_sha: manifest.expected_source_sha,
      workflow_path: manifest.workflow_path,
      workspace_root: manifest.workspace_root,
      logs_root: manifest.logs_root,
      log_file: LogFile.default_log_file(manifest.logs_root),
      routing_targets: routing_targets(loaded),
      approved_repo_target: manifest.approved_repo_target,
      approved_source_path: manifest.approved_source_path,
      armed_ready?: blockers == [],
      arming_blockers: blockers
    }
  end

  defp routing_targets({:ok, settings}) do
    settings.routing.targets |> Map.keys() |> Enum.sort()
  end

  defp routing_targets(_loaded), do: []

  defp tracker_project_slug(settings) do
    provider = settings.tracker.provider || %{}

    case Map.get(provider, "project_slug") || Map.get(provider, :project_slug) do
      value when is_binary(value) -> value
      _other -> settings.tracker.project_slug
    end
  end

  defp source_path(config) when is_map(config) do
    case Map.get(config, "source_path") || Map.get(config, :source_path) do
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  defp source_path(_config), do: nil

  defp placeholder?(nil), do: true

  defp placeholder?(value) when is_binary(value) do
    trimmed = String.trim(value)
    trimmed == "" or Enum.any?(@placeholder_markers, &String.contains?(trimmed, &1))
  end

  defp placeholder?(_value), do: false

  defp inside?(path, root) when is_binary(path) and is_binary(root) do
    path = normalize(path)
    root = normalize(root)
    root != "" and (path == root or String.starts_with?(path, root <> "/"))
  end

  defp inside?(_path, _root), do: false

  defp overlaps?(path, root) when is_binary(path) and is_binary(root) do
    inside?(path, root) or inside?(root, path)
  end

  defp overlaps?(_path, _root), do: false

  defp normalize(nil), do: nil
  defp normalize(""), do: ""

  defp normalize(path) when is_binary(path) do
    path
    |> Path.expand()
    |> String.replace(<<92>>, "/")
    |> String.trim_trailing("/")
    |> String.downcase()
  end

  defp trim(nil), do: nil
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""
end
