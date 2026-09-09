defmodule SymphonyElixir.TestSupport do
  @workflow_prompt "You are an agent for this repository."

  # Application env owned by the harness: every test may change it, and later
  # tests assume it is back at the value the test environment was configured
  # with (`config/config.exs`). Deleting it instead of restoring it destroys
  # shared test state for the rest of the run.
  @shared_app_env_keys [
    :workflow_file_path,
    :server_port_override,
    :memory_tracker_issues
  ]

  @baseline_key {__MODULE__, :baseline}

  @doc """
  Captures the configured application/test baseline once, before any test runs.
  """
  @spec capture_baseline!() :: :ok
  def capture_baseline! do
    baseline = %{
      app_env:
        Map.new(@shared_app_env_keys, fn key ->
          {key, Application.get_env(:symphony_elixir, key)}
        end),
      running_children: running_supervisor_children()
    }

    :persistent_term.put(@baseline_key, baseline)
    :ok
  end

  @doc """
  Restores the configured application env and the application supervisor shape
  a test may have taken down. Registered before any fixture work so it runs
  after both pass and fail.
  """
  @spec restore_shared_state() :: :ok
  def restore_shared_state do
    restore_shared_app_env()
    restore_shared_supervisor_children()
    :ok
  end

  defp baseline do
    :persistent_term.get(@baseline_key, %{app_env: %{}, running_children: []})
  end

  defp restore_shared_app_env do
    Enum.each(baseline().app_env, &restore_shared_app_env_key/1)
  end

  defp restore_shared_app_env_key({:workflow_file_path, path}) when is_binary(path) do
    # Route through Workflow so the shared WorkflowStore reloads the configured
    # baseline instead of serving the previous test's last-known-good settings.
    SymphonyElixir.Workflow.set_workflow_file_path(path)
  end

  defp restore_shared_app_env_key({key, nil}) do
    Application.delete_env(:symphony_elixir, key)
  end

  defp restore_shared_app_env_key({key, value}) do
    Application.put_env(:symphony_elixir, key, value)
  end

  defp restore_shared_supervisor_children do
    supervisor = Process.whereis(SymphonyElixir.Supervisor)

    if is_pid(supervisor) do
      running = running_supervisor_children()

      baseline().running_children
      |> Enum.reject(&(&1 in running))
      |> Enum.each(&restart_supervisor_child(supervisor, &1))
    end
  end

  defp restart_supervisor_child(supervisor, child_id) do
    case Supervisor.restart_child(supervisor, child_id) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, :running} ->
        :ok

      {:error, reason} ->
        raise "shared test supervisor child #{inspect(child_id)} not restored: #{inspect(reason)}"
    end
  end

  defp running_supervisor_children do
    if Process.whereis(SymphonyElixir.Supervisor) do
      SymphonyElixir.Supervisor
      |> Supervisor.which_children()
      |> Enum.flat_map(fn
        {id, pid, _type, _modules} when is_pid(pid) -> [id]
        _child -> []
      end)
    else
      []
    end
  end

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case
      import ExUnit.CaptureLog

      alias SymphonyElixir.AgentRunner
      alias SymphonyElixir.CLI
      alias SymphonyElixir.Codex.AppServer
      alias SymphonyElixir.Config
      alias SymphonyElixir.HttpServer
      alias SymphonyElixir.Linear.Client
      alias SymphonyElixir.Orchestrator
      alias SymphonyElixir.PromptBuilder
      alias SymphonyElixir.StatusDashboard
      alias SymphonyElixir.Tracker
      alias SymphonyElixir.Tracker.Issue
      alias SymphonyElixir.Workflow
      alias SymphonyElixir.WorkflowStore
      alias SymphonyElixir.Workspace

      import SymphonyElixir.TestSupport,
        only: [
          write_workflow_file!: 1,
          write_workflow_file!: 2,
          restore_env: 2,
          stop_default_http_server: 0,
          link_dir_fixture!: 2,
          symlink_fixture_skip_reason: 0,
          remove_dir_link_fixtures!: 1
        ]

      setup do
        # Register shared-state cleanup before any fixture work: a setup or
        # fixture failure must not bypass it, and it must run after both pass
        # and fail so the next test starts from the configured baseline.
        on_exit(fn -> SymphonyElixir.TestSupport.restore_shared_state() end)

        workflow_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-workflow-#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(workflow_root)
        on_exit(fn -> File.rm_rf(workflow_root) end)

        workflow_file = Path.join(workflow_root, "WORKFLOW.md")
        write_workflow_file!(workflow_file)
        Workflow.set_workflow_file_path(workflow_file)
        if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()
        stop_default_http_server()

        :ok
      end
    end
  end

  # Symlink fixtures (MIC-208).
  #
  # A host without SeCreateSymbolicLinkPrivilege - an unprivileged account,
  # Developer Mode disabled, or a restricted sandbox token - cannot create a
  # symlink at all: File.ln_s/2 returns :eperm even for a valid, non-existing
  # link path. That is a missing host capability, not a product security
  # failure, so the fixture must not be reported as one.
  #
  # A directory junction is a reparse point that OTP reports as
  # %File.Stat{type: :symlink} and that :file.read_link_all/1 resolves to its
  # target, so PathSafety.canonicalize/1 walks it through exactly the same code
  # path as a real symlink, while creating one needs no privilege. The escape
  # assertions therefore keep executing against the real product check instead
  # of being skipped on Windows.
  #
  # Only capability errors fall back or skip. Any other File.ln_s/2 error means
  # the fixture itself is broken and is raised.
  @symlink_capability_errors [:eperm, :eacces, :enotsup]

  @doc """
  Creates the directory link a symlink-escape fixture depends on.

  Returns `:symlink` when the host created a real symlink, `:junction` when
  symlink creation was denied and a Windows directory junction was used
  instead. Raises when the fixture cannot be created for any other reason.
  """
  def link_dir_fixture!(target, link) when is_binary(target) and is_binary(link) do
    case create_dir_link(target, link) do
      {:ok, strategy} ->
        strategy

      {:error, :capability_unavailable, detail} ->
        raise "symlink fixture prerequisite unavailable for #{inspect(link)} -> #{inspect(target)}: #{detail}"

      {:error, :fixture_error, detail} ->
        raise "symlink fixture setup failed for #{inspect(link)} -> #{inspect(target)}: #{detail}"
    end
  end

  @doc """
  `false` when this host can build the symlink fixture, otherwise the exact
  reason to use as an ExUnit `@tag skip:` value.

  Only the prerequisite-dependent case is skipped, and the reason names the
  capability that is missing.
  """
  def symlink_fixture_skip_reason do
    case symlink_fixture_capability() do
      {:ok, _strategy} ->
        false

      {:error, :capability_unavailable, detail} ->
        "host cannot create the symlink fixture prerequisite (#{detail}); product symlink guard not exercised"

      {:error, :fixture_error, detail} ->
        raise "symlink fixture probe failed: #{detail}"
    end
  end

  @doc """
  Probes the host once per test run for the link strategy a symlink fixture can use.
  """
  def symlink_fixture_capability do
    key = {__MODULE__, :symlink_fixture_capability}

    case :persistent_term.get(key, :unset) do
      :unset ->
        capability = probe_symlink_fixture()
        :persistent_term.put(key, capability)
        capability

      capability ->
        capability
    end
  end

  @doc """
  Removes the directory links under `root`, then the fixture tree itself.

  `File.rm_rf/1` recurses *through* a Windows directory junction, deletes the
  link target and leaves the dangling reparse point behind, so a plain
  `File.rm_rf/1` both destroys the fixture's outside directory early and leaves
  residue that collides with the next run of the same test. Unlinking every
  reparse point first (which `File.rm_rf/1` does handle) keeps cleanup exact for
  real symlinks and junctions alike.
  """
  def remove_dir_link_fixtures!(root) do
    root
    |> dir_link_paths()
    |> Enum.each(&remove_reparse_point/1)

    File.rm_rf(root)
  end

  defp remove_reparse_point(path) do
    # File.rm_rf/1 cannot unlink a directory reparse point whose target is gone
    # (:eperm from DeleteFile); rmdir removes the link itself, so try that first
    # and fall back for file symlinks.
    case File.rmdir(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> File.rm_rf(path)
    end
  end

  defp dir_link_paths(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        [path]

      {:ok, %File.Stat{type: :directory}} ->
        case File.ls(path) do
          {:ok, entries} -> Enum.flat_map(entries, &dir_link_paths(Path.join(path, &1)))
          {:error, _reason} -> []
        end

      _other ->
        []
    end
  end

  defp probe_symlink_fixture do
    base =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-symlink-capability-#{System.unique_integer([:positive])}"
      )

    target = Path.join(base, "target")
    link = Path.join(base, "link")

    try do
      File.mkdir_p!(target)

      case create_dir_link(target, link) do
        {:ok, strategy} -> {:ok, strategy}
        {:error, _class, detail} -> {:error, :capability_unavailable, detail}
      end
    rescue
      error -> {:error, :capability_unavailable, "fixture probe failed: #{Exception.message(error)}"}
    after
      remove_dir_link_fixtures!(base)
    end
  end

  defp create_dir_link(target, link) do
    with :ok <- check_link_target(target),
         :ok <- check_link_absent(link) do
      case File.ln_s(target, link) do
        :ok ->
          {:ok, :symlink}

        {:error, reason} when reason in @symlink_capability_errors ->
          create_dir_junction(target, link, reason)

        {:error, reason} ->
          {:error, :fixture_error, "File.ln_s/2 failed: #{describe_errno(reason)}"}
      end
    end
  end

  defp check_link_target(target) do
    if File.dir?(target) do
      :ok
    else
      {:error, :fixture_error, "fixture target #{inspect(target)} is not an existing directory"}
    end
  end

  defp check_link_absent(link) do
    case File.lstat(link) do
      {:error, :enoent} ->
        :ok

      {:ok, _stat} ->
        {:error, :fixture_error, "fixture link path #{inspect(link)} already exists"}

      {:error, reason} ->
        {:error, :fixture_error, "cannot stat fixture link path #{inspect(link)}: #{describe_errno(reason)}"}
    end
  end

  defp create_dir_junction(target, link, symlink_reason) do
    if windows?() do
      {output, status} =
        System.shell("mklink /J \"#{windows_path(link)}\" \"#{windows_path(target)}\"",
          stderr_to_stdout: true
        )

      cond do
        status == 0 and junction_link?(link, target) ->
          {:ok, :junction}

        status == 0 ->
          {:error, :fixture_error, "mklink /J reported success but #{inspect(link)} is not a reparse point Erlang resolves as a symlink"}

        true ->
          {:error, :capability_unavailable,
           "File.ln_s/2 denied symlink creation (#{describe_errno(symlink_reason)}) and the directory-junction " <>
             "fallback failed (mklink /J exit #{status}: #{String.trim(to_string(output))})"}
      end
    else
      {:error, :capability_unavailable, "File.ln_s/2 denied symlink creation (#{describe_errno(symlink_reason)}) and directory junctions are Windows-only"}
    end
  end

  defp junction_link?(link, target) do
    with {:ok, %File.Stat{type: :symlink}} <- File.lstat(link),
         {:ok, resolved} <- :file.read_link_all(String.to_charlist(link)) do
      String.downcase(Path.expand(IO.chardata_to_string(resolved))) ==
        String.downcase(Path.expand(target))
    else
      _other -> false
    end
  end

  defp windows?, do: match?({:win32, _}, :os.type())

  # mklink is a cmd built-in; give it native separators even when the fixture
  # built the path with Path.join/Path.expand.
  defp windows_path(path), do: String.replace(path, "/", "\\")

  defp describe_errno(reason), do: "#{reason} (#{:file.format_error(reason)})"

  def write_workflow_file!(path, overrides \\ []) do
    workflow = workflow_content(overrides)
    File.write!(path, workflow)

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      try do
        SymphonyElixir.WorkflowStore.force_reload()
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)

  def stop_default_http_server do
    case Enum.find(Supervisor.which_children(SymphonyElixir.Supervisor), fn
           {SymphonyElixir.HttpServer, _pid, _type, _modules} -> true
           _child -> false
         end) do
      {SymphonyElixir.HttpServer, pid, _type, _modules} when is_pid(pid) ->
        :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.HttpServer)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end

        :ok

      _ ->
        :ok
    end
  end

  defp workflow_content(overrides) do
    config =
      Keyword.merge(
        [
          tracker_kind: "linear",
          tracker_endpoint: "https://api.linear.app/graphql",
          tracker_api_token: "token",
          tracker_project_slug: "project",
          tracker_assignee: nil,
          tracker_required_labels: [],
          tracker_active_states: ["Todo", "In Progress"],
          tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
          poll_interval_ms: 30_000,
          workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
          routing: %{},
          worker_ssh_hosts: [],
          worker_max_concurrent_agents_per_host: nil,
          max_concurrent_agents: 10,
          max_turns: 20,
          max_retry_backoff_ms: 300_000,
         max_concurrent_agents_by_state: %{},
         codex_command: "codex app-server",
         codex_shell_executable: nil,
         codex_approval_policy: %{reject: %{sandbox_approval: true, rules: true, mcp_elicitations: true}},
          codex_thread_sandbox: "workspace-write",
          codex_turn_sandbox_policy: nil,
          codex_turn_timeout_ms: 3_600_000,
          codex_read_timeout_ms: 5_000,
          codex_stall_timeout_ms: 300_000,
          hook_after_create: nil,
          hook_before_run: nil,
          hook_after_run: nil,
          hook_before_remove: nil,
          hook_timeout_ms: 60_000,
          observability_enabled: true,
          observability_refresh_ms: 1_000,
          observability_render_interval_ms: 16,
          server_port: nil,
          server_host: nil,
          prompt: @workflow_prompt
        ],
        overrides
      )

    tracker_kind = Keyword.get(config, :tracker_kind)
    tracker_endpoint = Keyword.get(config, :tracker_endpoint)
    tracker_api_token = Keyword.get(config, :tracker_api_token)
    tracker_project_slug = Keyword.get(config, :tracker_project_slug)
    tracker_assignee = Keyword.get(config, :tracker_assignee)
    tracker_required_labels = Keyword.get(config, :tracker_required_labels)
    tracker_active_states = Keyword.get(config, :tracker_active_states)
    tracker_terminal_states = Keyword.get(config, :tracker_terminal_states)
    poll_interval_ms = Keyword.get(config, :poll_interval_ms)
    workspace_root = Keyword.get(config, :workspace_root)
    routing = Keyword.get(config, :routing)
    worker_ssh_hosts = Keyword.get(config, :worker_ssh_hosts)
    worker_max_concurrent_agents_per_host = Keyword.get(config, :worker_max_concurrent_agents_per_host)
    max_concurrent_agents = Keyword.get(config, :max_concurrent_agents)
    max_turns = Keyword.get(config, :max_turns)
    max_retry_backoff_ms = Keyword.get(config, :max_retry_backoff_ms)
    max_concurrent_agents_by_state = Keyword.get(config, :max_concurrent_agents_by_state)
   codex_command = Keyword.get(config, :codex_command)
   codex_shell_executable = Keyword.get(config, :codex_shell_executable)
   codex_approval_policy = Keyword.get(config, :codex_approval_policy)
    codex_thread_sandbox = Keyword.get(config, :codex_thread_sandbox)
    codex_turn_sandbox_policy = Keyword.get(config, :codex_turn_sandbox_policy)
    codex_turn_timeout_ms = Keyword.get(config, :codex_turn_timeout_ms)
    codex_read_timeout_ms = Keyword.get(config, :codex_read_timeout_ms)
    codex_stall_timeout_ms = Keyword.get(config, :codex_stall_timeout_ms)
    hook_after_create = Keyword.get(config, :hook_after_create)
    hook_before_run = Keyword.get(config, :hook_before_run)
    hook_after_run = Keyword.get(config, :hook_after_run)
    hook_before_remove = Keyword.get(config, :hook_before_remove)
    hook_timeout_ms = Keyword.get(config, :hook_timeout_ms)
    observability_enabled = Keyword.get(config, :observability_enabled)
    observability_refresh_ms = Keyword.get(config, :observability_refresh_ms)
    observability_render_interval_ms = Keyword.get(config, :observability_render_interval_ms)
    server_port = Keyword.get(config, :server_port)
    server_host = Keyword.get(config, :server_host)
    prompt = Keyword.get(config, :prompt)

    sections =
      [
        "---",
        "tracker:",
        "  kind: #{yaml_value(tracker_kind)}",
        "  endpoint: #{yaml_value(tracker_endpoint)}",
        "  api_key: #{yaml_value(tracker_api_token)}",
        "  project_slug: #{yaml_value(tracker_project_slug)}",
        "  assignee: #{yaml_value(tracker_assignee)}",
        "  required_labels: #{yaml_value(tracker_required_labels)}",
        "  active_states: #{yaml_value(tracker_active_states)}",
        "  terminal_states: #{yaml_value(tracker_terminal_states)}",
        "polling:",
        "  interval_ms: #{yaml_value(poll_interval_ms)}",
        "workspace:",
        "  root: #{yaml_value(workspace_root)}",
        "routing: #{yaml_value(routing)}",
        worker_yaml(worker_ssh_hosts, worker_max_concurrent_agents_per_host),
        "agent:",
        "  max_concurrent_agents: #{yaml_value(max_concurrent_agents)}",
        "  max_turns: #{yaml_value(max_turns)}",
        "  max_retry_backoff_ms: #{yaml_value(max_retry_backoff_ms)}",
        "  max_concurrent_agents_by_state: #{yaml_value(max_concurrent_agents_by_state)}",
       "codex:",
       "  command: #{yaml_value(codex_command)}",
       if(codex_shell_executable, do: "  shell_executable: #{yaml_value(codex_shell_executable)}", else: nil),
       "  approval_policy: #{yaml_value(codex_approval_policy)}",
        "  thread_sandbox: #{yaml_value(codex_thread_sandbox)}",
        "  turn_sandbox_policy: #{yaml_value(codex_turn_sandbox_policy)}",
        "  turn_timeout_ms: #{yaml_value(codex_turn_timeout_ms)}",
        "  read_timeout_ms: #{yaml_value(codex_read_timeout_ms)}",
        "  stall_timeout_ms: #{yaml_value(codex_stall_timeout_ms)}",
        hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, hook_timeout_ms),
        observability_yaml(observability_enabled, observability_refresh_ms, observability_render_interval_ms),
        server_yaml(server_port, server_host),
        "---",
        prompt
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join(sections, "\n") <> "\n"
  end

  defp yaml_value(value) when is_binary(value) do
    escaped_value =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"" <> escaped_value <> "\""
  end

  defp yaml_value(value) when is_integer(value), do: to_string(value)
  defp yaml_value(true), do: "true"
  defp yaml_value(false), do: "false"
  defp yaml_value(nil), do: "null"

  defp yaml_value(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &yaml_value/1) <> "]"
  end

  defp yaml_value(values) when is_map(values) do
    "{" <>
      Enum.map_join(values, ", ", fn {key, value} ->
        "#{yaml_value(to_string(key))}: #{yaml_value(value)}"
      end) <> "}"
  end

  defp yaml_value(value), do: yaml_value(to_string(value))

  defp hooks_yaml(nil, nil, nil, nil, timeout_ms), do: "hooks:\n  timeout_ms: #{yaml_value(timeout_ms)}"

  defp hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, timeout_ms) do
    [
      "hooks:",
      "  timeout_ms: #{yaml_value(timeout_ms)}",
      hook_entry("after_create", hook_after_create),
      hook_entry("before_run", hook_before_run),
      hook_entry("after_run", hook_after_run),
      hook_entry("before_remove", hook_before_remove)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host)
       when ssh_hosts in [nil, []] and is_nil(max_concurrent_agents_per_host),
       do: nil

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host) do
    [
      "worker:",
      ssh_hosts not in [nil, []] && "  ssh_hosts: #{yaml_value(ssh_hosts)}",
      !is_nil(max_concurrent_agents_per_host) &&
        "  max_concurrent_agents_per_host: #{yaml_value(max_concurrent_agents_per_host)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp observability_yaml(enabled, refresh_ms, render_interval_ms) do
    [
      "observability:",
      "  dashboard_enabled: #{yaml_value(enabled)}",
      "  refresh_ms: #{yaml_value(refresh_ms)}",
      "  render_interval_ms: #{yaml_value(render_interval_ms)}"
    ]
    |> Enum.join("\n")
  end

  defp server_yaml(nil, nil), do: nil

  defp server_yaml(port, host) do
    [
      "server:",
      port && "  port: #{yaml_value(port)}",
      host && "  host: #{yaml_value(host)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp hook_entry(_name, nil), do: nil

  defp hook_entry(name, command) when is_binary(command) do
    indented =
      command
      |> String.split("\n")
      |> Enum.map_join("\n", &("    " <> &1))

    "  #{name}: |\n#{indented}"
  end
end
