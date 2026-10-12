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

  Containment is not decided lexically. Every boundary-relevant path - the pilot
  root, the manifest entries, the protected roots and the working directory - is
  resolved against the real filesystem by walking each existing ancestor, so
  NTFS junctions, directory and file symlinks, and chained links that leave the
  approved pilot directory are rejected however the path is spelled: forward or
  back slashes, any casing, trailing separators, `.`/`..` segments or `\\?\`
  device-path aliases. A path that cannot be resolved safely - a broken or
  looping link, an unreadable ancestor, a `\\.\` device namespace - fails closed.
  Resolution only stats and reads; it never follows a link into a protected tree
  to write anything, and paths that do not exist yet are accepted only when
  every existing ancestor resolves inside the boundary.

  This is a validation-time control, not filesystem sandboxing. Between the
  check and any later mutation, a process that can write inside the pilot
  directory can still replace a component with a link (TOCTOU), and 8.3
  short-name aliases are matched by prefix rather than expanded. Operating-system
  level isolation remains the only absolute boundary; this gate narrows, but
  does not eliminate, the window.

  The gate is policy plus filesystem and `git` inspection. It contacts no tracker,
  prepares no workspace, invokes no provider and starts no process, so it runs
  offline and is safe to repeat.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.HarnessSelection
  alias SymphonyElixir.LogFile
  alias SymphonyElixir.PilotGuard
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

  A start that passes also arms the pilot dispatch guard
  (`SymphonyElixir.PilotGuard`), so once running, the pilot parks any issue it
  cannot authorize on the OpenCode harness instead of falling back to Codex.
  """
  @spec start(Path.t(), keyword()) :: {:ok, report()} | {:error, term()}
  def start(manifest_path, opts \\ []) do
    env = env(opts)

    with {:ok, report} <- preflight(manifest_path, Keyword.merge(opts, mode: :armed)) do
      :ok = Workflow.set_workflow_file_path(report.workflow_path)
      Application.put_env(:symphony_elixir, :log_file, report.log_file)
      # PILOT-GUARD-F1: armed before the runtime starts so no poll or dispatch
      # can outrun the guard. Application environment, not WORKFLOW.md: a
      # workflow reload can change the allowlist but never disarm the guard.
      :ok = PilotGuard.arm(workflow_path: report.workflow_path, source_sha: report.source_sha)

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
    resolved = resolve_boundary(manifest, env)

    [
      {:manifest_paths, check_manifest_paths(manifest, resolved)},
      {:source_identity, check_source_identity(manifest, env, resolved)},
      {:workflow_identity, check_workflow_identity(manifest, resolved)},
      {:workflow_load, check_workflow_load(loaded)},
      {:workspace_root, check_workspace_root(manifest, loaded, resolved)},
      {:logs_root, check_logs_root(manifest, resolved)},
      {:worker_containment, check_worker_containment(loaded)},
      {:routing_boundary, check_routing_boundary(manifest, loaded, resolved)}
    ]
  end

  defp check_manifest_paths(manifest, resolved) do
    with :ok <- absolute_paths(manifest),
         :ok <- resolvable_paths(resolved),
         :ok <-
           inside_pilot(resolved.entries.source_root, resolved.entries.pilot_root, :source_root_outside_pilot) do
      unprotected(resolved)
    end
  end

  defp resolvable_paths(resolved) do
    case resolved.unresolvable do
      [] -> :ok
      [{name, path, reason} | _rest] -> {:error, {:path_unresolvable, name, path, reason}}
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

  defp unprotected(resolved) do
    entries =
      Enum.reject(resolved.entries, fn
        {:pilot_root, _path} -> true
        {_name, nil} -> true
        {_name, _path} -> false
      end)

    case Enum.find_value(resolved.protected_roots, fn root -> protected_reference(entries, root) end) do
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

  defp check_source_identity(manifest, env, resolved) do
    expected_cwd = Path.join(resolved.entries.source_root, "elixir")

    with :ok <- same_directory(resolved.cwd, expected_cwd),
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

  defp check_workflow_identity(manifest, resolved) do
    workflow = resolved.entries.workflow_path
    tracked = Path.join([resolved.entries.source_root, "elixir", "WORKFLOW.md"])

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

  defp check_workspace_root(manifest, loaded, resolved) do
    root = resolved.entries.workspace_root
    declared_path = declared_workspace_root(loaded)
    declared = resolve_or_lexical(declared_path)

    cond do
      not inside?(root, resolved.entries.pilot_root) ->
        {:error, {:workspace_root_outside_pilot, manifest.workspace_root}}

      inside?(root, resolved.entries.source_root) ->
        {:error, {:workspace_root_inside_source_checkout, manifest.workspace_root}}

      not nonblank?(declared_path) ->
        {:error, :workspace_root_missing}

      normalize(declared) != normalize(root) ->
        {:error, {:workspace_root_mismatch, declared_path, manifest.workspace_root}}

      true ->
        :ok
    end
  end

  defp declared_workspace_root({:ok, settings}), do: settings.workspace.root
  defp declared_workspace_root(_loaded), do: nil

  defp check_logs_root(manifest, resolved) do
    root = resolved.entries.logs_root

    cond do
      not inside?(root, resolved.entries.pilot_root) ->
        {:error, {:logs_root_outside_pilot, manifest.logs_root}}

      inside?(root, resolved.entries.source_root) ->
        {:error, {:logs_root_inside_source_checkout, manifest.logs_root}}

      Enum.any?(resolved.protected_roots, &overlaps?(root, &1)) ->
        {:error, {:logs_root_protected, manifest.logs_root}}

      true ->
        :ok
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

  defp check_routing_boundary(manifest, {:ok, settings}, resolved) do
    targets = settings.routing.targets || %{}
    approved = manifest.approved_source_path

    cond do
      map_size(targets) == 0 ->
        :ok

      not nonblank?(approved) ->
        {:error, {:unapproved_repository_targets, Map.keys(targets)}}

      not inside?(resolved.entries.approved_source_path, resolved.entries.pilot_root) ->
        {:error, {:approved_source_path_outside_pilot, approved}}

      true ->
        mismatched_source_path(targets, resolved)
    end
  end

  defp check_routing_boundary(_manifest, {:error, reason}, _resolved), do: {:error, reason}

  defp mismatched_source_path(targets, resolved) do
    approved = resolved.entries.approved_source_path

    case Enum.find(targets, fn {_target, config} ->
           normalize(resolve_or_lexical(source_path(config))) != normalize(approved)
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

  # real-path resolution

  defp resolve_boundary(manifest, env) do
    %{
      entries: Map.new(boundary_paths(manifest), fn {name, path} -> {name, resolve_or_lexical(path)} end),
      unresolvable: unresolvable_entries(manifest),
      cwd: resolve_or_lexical(env.cwd),
      protected_roots: Enum.map(env.protected_roots, &resolve_or_lexical/1)
    }
  end

  defp boundary_paths(manifest) do
    path_entries(manifest) ++ [{:approved_source_path, manifest.approved_source_path}]
  end

  defp unresolvable_entries(manifest) do
    for {name, path} <- boundary_paths(manifest),
        nonblank?(path),
        {:error, reason} <- [resolve_path(path)] do
      {name, path, reason}
    end
  end

  defp resolve_or_lexical(path) when is_binary(path) do
    case resolve_path(path) do
      {:ok, resolved} -> resolved
      {:error, _reason} -> normalize(path)
    end
  end

  defp resolve_or_lexical(nil), do: nil

  @link_hop_limit 32

  # Resolves `path` to its real location by walking every existing ancestor:
  # a junction or symlink found on the way is replaced by its target and the
  # walk restarts from it (bounded), so the result names where the path actually
  # lives. A missing tail is kept lexically, because nothing below a directory
  # that does not exist can be a live link. Anything unreadable is an error,
  # never a guess.
  defp resolve_path(path) when is_binary(path) do
    with {:ok, root, components} <- lexical_components(path) do
      walk(root, [], components, 0)
    end
  end

  defp resolve_path(_other), do: {:error, :not_a_path}

  defp lexical_components(path) do
    with {:ok, plain} <- strip_device_prefix(String.replace(path, <<92>>, "/")) do
      split_root(plain)
    end
  end

  defp strip_device_prefix(path) do
    down = String.downcase(path)

    cond do
      String.starts_with?(down, "//./") -> {:error, :device_namespace_path}
      String.starts_with?(down, "//?/unc/") -> {:ok, "//" <> String.slice(path, 8..-1//1)}
      String.starts_with?(down, "//?/") -> {:ok, String.slice(path, 4..-1//1)}
      true -> {:ok, path}
    end
  end

  defp split_root("//" <> unc_rest) do
    {:ok, "//", components(unc_rest)}
  end

  defp split_root(plain) do
    if drive_root?(String.downcase(plain)) do
      {_drive, rest} = String.split_at(plain, 2)
      {:ok, String.slice(plain, 0, 2), components(rest)}
    else
      {:error, :not_absolute}
    end
  end

  defp drive_root?(<<letter, ?:, _rest::binary>>) when letter in ?a..?z, do: true
  defp drive_root?(_other), do: false

  defp components(rest), do: String.split(rest, "/", trim: true)

  defp walk(root, resolved, [], _hops), do: {:ok, join_root(root, resolved)}

  defp walk(root, resolved, [component | rest], hops) when hops <= @link_hop_limit do
    cond do
      component == "." -> walk(root, resolved, rest, hops)
      component == ".." -> walk_parent(root, resolved, rest, hops)
      true -> walk_component(root, resolved, component, rest, hops)
    end
  end

  defp walk(_root, _resolved, _components, _hops), do: {:error, :link_hop_limit_exceeded}

  defp walk_parent(root, resolved, rest, hops) do
    if resolved == [],
      do: walk(root, [], rest, hops),
      else: walk(root, Enum.drop(resolved, -1), rest, hops)
  end

  defp walk_component(root, resolved, component, rest, hops) do
    candidate = join_root(root, resolved ++ [component])

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} -> follow_link(root, resolved, component, rest, hops)
      {:ok, %File.Stat{type: :directory}} -> walk(root, resolved ++ [component], rest, hops)
      {:ok, %File.Stat{type: _leaf}} -> {:ok, lexical_tail(root, resolved ++ [component], rest)}
      {:error, :enoent} -> {:ok, lexical_tail(root, resolved ++ [component], rest)}
      {:error, reason} -> {:error, {:path_stat_failed, candidate, reason}}
    end
  end

  defp follow_link(root, resolved, component, rest, hops) do
    link_path = join_root(root, resolved ++ [component])

    case File.read_link(link_path) do
      {:ok, target} ->
        case link_replacement(target) do
          {:absolute, new_root, components} -> walk(new_root, [], components ++ rest, hops + 1)
          {:relative, components} -> walk(root, resolved, components ++ rest, hops + 1)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, {:link_target_unreadable, link_path, reason}}
    end
  end

  defp link_replacement(target) do
    with {:ok, plain} <- strip_device_prefix(String.replace(target, <<92>>, "/")) do
      case split_root(plain) do
        {:ok, root, components} -> {:absolute, root, components}
        {:error, :not_absolute} -> {:relative, components(plain)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # The tail below a missing component cannot hold live links, so `.`/`..` and
  # names are folded lexically onto the last resolved prefix.
  defp lexical_tail(root, resolved, rest) do
    resolved =
      Enum.reduce(rest, resolved, fn
        ".", acc -> acc
        "..", acc -> if acc == [], do: acc, else: Enum.drop(acc, -1)
        name, acc -> acc ++ [name]
      end)

    join_root(root, resolved)
  end

  defp join_root("//" = root, []), do: root
  defp join_root("//" = root, components), do: root <> Enum.join(components, "/")
  defp join_root(root, []), do: root
  defp join_root(root, components), do: root <> "/" <> Enum.join(components, "/")

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
