defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{Config, PathSafety, RepositoryRouter, SourceSync, SSH}

  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"
  @remote_provenance_marker "__SYMPHONY_PROVENANCE__"

  @type worker_host :: String.t() | nil
  @type route :: RepositoryRouter.Route.t() | nil
  @type issue_reference :: map() | String.t() | nil
  @type classification :: :fresh | :resume

  @spec create_for_issue(map() | String.t() | nil, worker_host()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host \\ nil) do
    case create_for_issue_with_route(issue_or_identifier, worker_host) do
      {:ok, workspace, _route, _workspace_root} -> {:ok, workspace}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec create_for_issue_with_route(map() | String.t() | nil, worker_host()) ::
          {:ok, Path.t(), RepositoryRouter.Route.t() | nil, Path.t() | nil} | {:error, term()}
  def create_for_issue_with_route(issue_or_identifier, worker_host \\ nil) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = workspace_key(issue_or_identifier)

      with {:ok, route} <- resolve_repository_route(issue_or_identifier),
           :ok <- sync_source_baseline(route, issue_context, worker_host),
           issue_context = Map.put(issue_context, :repository_route, route),
           {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host),
           :ok <- validate_workspace_path(workspace, worker_host),
           {:ok, workspace, created?, recorded_root} <-
             ensure_workspace(workspace, worker_host, creation_workspace_root(worker_host)),
           :ok <- verify_reused_workspace_repository(workspace, route, created?, worker_host) do
        case maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
          :ok ->
            {:ok, workspace, route, recorded_root}

          {:error, _reason} = error ->
            cleanup_failed_new_workspace(workspace, created?, worker_host)
            error
        end
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} worker_host=#{worker_host_for_log(worker_host)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  # The trusted deletion boundary for a workspace is the root it was created under,
  # captured here at creation time. Remote roots are resolved by the prepare script
  # because the recorded workspace path is that host's canonical `pwd -P` output,
  # which the control host cannot reproduce for `~`-relative or relative roots.
  defp creation_workspace_root(nil), do: Config.local_workspace_root()

  defp creation_workspace_root(worker_host) when is_binary(worker_host) do
    Config.settings!().workspace.root
  end

  defp ensure_workspace(workspace, nil, workspace_root) do
    cond do
      File.dir?(workspace) ->
        {:ok, workspace, false, workspace_root}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace, workspace_root)

      true ->
        create_workspace(workspace, workspace_root)
    end
  end

  defp ensure_workspace(workspace, worker_host, workspace_root) when is_binary(worker_host) do
    root_assign =
      if is_binary(workspace_root) do
        remote_shell_assign("workspace_root", workspace_root)
      else
        "workspace_root=''"
      end

    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        root_assign,
        "if [ -d \"$workspace\" ]; then",
        "  created=0",
        "elif [ -e \"$workspace\" ]; then",
        "  rm -rf \"$workspace\"",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "else",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "fi",
        "cd \"$workspace\"",
        "resolved_workspace_root=$(cd \"$workspace_root\" 2>/dev/null && pwd -P) || resolved_workspace_root=\"$workspace_root\"",
        "printf '%s\\t%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$created\" \"$(pwd -P)\" \"$resolved_workspace_root\""
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        parse_remote_workspace_output(output)

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_workspace(workspace, workspace_root) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, workspace, true, workspace_root}
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace), do: remove(workspace, nil)

  @spec remove(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, nil) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace, nil) do
          :ok ->
            remove_local_workspace(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  def remove(workspace, worker_host) when is_binary(worker_host) do
    maybe_run_before_remove_hook(workspace, worker_host)

    script =
      [
        remote_shell_assign("workspace", workspace),
        "rm -rf \"$workspace\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        {:ok, []}

      {:ok, {output, status}} ->
        {:error, {:workspace_remove_failed, worker_host, status, output}, ""}

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  @doc false
  @spec remove_recorded(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove_recorded(workspace, worker_host), do: remove_recorded(workspace, worker_host, nil)

  # Recorded cleanup is the only removal path that acts on a path stored outside the
  # caller's control, so it must prove containment in the workspace root that was active
  # when the workspace was created. `recorded_root` is that root; when it is unavailable
  # the current configured root is the boundary instead. Nothing touches the workspace -
  # no `before_remove` hook and no recursive deletion - until containment holds.
  @doc false
  @spec remove_recorded(Path.t(), worker_host(), Path.t() | nil) ::
          {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove_recorded(workspace, nil, recorded_root) when is_binary(workspace) do
    if Path.type(workspace) == :absolute do
      case validate_local_workspace_path(workspace, trusted_local_workspace_root(recorded_root)) do
        :ok ->
          remove_local_workspace(workspace)

        {:error, reason} ->
          {:error, reason, ""}
      end
    else
      {:error, {:workspace_path_unreadable, workspace, :not_absolute}, ""}
    end
  end

  def remove_recorded(workspace, worker_host, recorded_root)
      when is_binary(workspace) and is_binary(worker_host) do
    case validate_remote_workspace_path(workspace, trusted_remote_workspace_root(recorded_root)) do
      :ok ->
        remove(workspace, worker_host)

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  def remove_recorded(workspace, _worker_host, _recorded_root) do
    {:error, {:workspace_path_unreadable, workspace, :invalid}, ""}
  end

  defp remove_local_workspace(workspace) do
    maybe_run_before_remove_hook(workspace, nil)
    File.rm_rf(workspace)
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier), do: remove_issue_workspaces(identifier, nil)

  @spec remove_issue_workspaces(term(), worker_host()) :: :ok
  def remove_issue_workspaces(%{id: _issue_id, identifier: _identifier} = issue, worker_host)
      when is_binary(worker_host) do
    case workspace_path_for_issue(workspace_key(issue), worker_host) do
      {:ok, workspace} -> remove(workspace, worker_host)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(%{id: _issue_id, identifier: _identifier} = issue, nil) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        remove_local_issue_workspace(issue)

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(issue, &1))
    end

    :ok
  end

  def remove_issue_workspaces(identifier, worker_host) when is_binary(identifier) and is_binary(worker_host) do
    case workspace_path_for_issue(workspace_key(identifier), worker_host) do
      {:ok, workspace} -> remove(workspace, worker_host)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(identifier, nil) when is_binary(identifier) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        remove_local_issue_workspace(identifier)

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(identifier, &1))
    end

    :ok
  end

  def remove_issue_workspaces(_identifier, _worker_host), do: :ok

  defp remove_local_issue_workspace(issue_or_identifier) do
    case classify_candidate(issue_or_identifier, nil) do
      {:ok, :resume, workspace, _route} ->
        remove(workspace, nil)
        :ok

      {:ok, :fresh, _workspace, _route} ->
        :ok

      {:error, {:workspace_repository_mismatch, target, details}} ->
        Logger.warning(
          "Preserving workspace for #{issue_log_context(issue_context(issue_or_identifier))}; " <>
            "workspace repository identity mismatch for target #{target}: #{inspect(details)}"
        )

        :ok

      {:error, reason} ->
        Logger.warning(
          "Preserving workspace for #{issue_log_context(issue_context(issue_or_identifier))}; " <>
            "unable to verify repository identity: #{inspect(reason)}"
        )

        :ok
    end
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    with {:ok, route} <- resolve_repository_route(issue_or_identifier) do
      run_before_run_hook(workspace, issue_or_identifier, worker_host, route)
    end
  end

  @doc false
  @spec run_before_run_hook(Path.t(), issue_reference(), worker_host(), route()) :: :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host, route)
      when is_binary(workspace) and (is_nil(route) or is_struct(route, RepositoryRouter.Route)) do
    issue_context = issue_or_identifier |> issue_context() |> Map.put(:repository_route, route)
    run_before_run_hook_for_context(workspace, issue_context, worker_host)
  end

  @doc false
  @spec capture_provenance(Path.t(), map() | String.t() | nil, worker_host()) ::
          {:ok, map()} | {:error, term()}
  def capture_provenance(workspace, issue_or_identifier, worker_host \\ nil)
      when is_binary(workspace) do
    with {:ok, route} <- resolve_repository_route(issue_or_identifier) do
      capture_provenance(workspace, issue_or_identifier, worker_host, route)
    end
  end

  @doc false
  @spec capture_provenance(Path.t(), issue_reference(), worker_host(), route()) :: {:ok, map()} | {:error, term()}
  def capture_provenance(workspace, _issue_or_identifier, worker_host, route)
      when is_binary(workspace) and (is_nil(route) or is_struct(route, RepositoryRouter.Route)) do
    capture_workspace_provenance(workspace, route, worker_host)
  end

  defp run_before_run_hook_for_context(workspace, issue_context, worker_host) do
    hooks = Config.settings!().hooks

    case hooks.before_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run", worker_host)
    end
  end

  defp capture_workspace_provenance(workspace, nil, nil) do
    case validate_workspace_path(workspace, nil) do
      :ok ->
        case local_git_output(workspace, ["rev-parse", "--verify", "HEAD^{commit}"]) do
          {:ok, head} ->
            {:ok, unrouted_provenance(head, local_origin(workspace))}

          {:error, :git_read_failed} ->
            {:ok, empty_provenance()}
        end

      {:error, reason} ->
        {:error, {:workspace_provenance_failed, reason}}
    end
  end

  defp capture_workspace_provenance(workspace, nil, worker_host) when is_binary(worker_host) do
    case validate_workspace_path(workspace, worker_host) do
      :ok ->
        case remote_git_provenance(workspace, worker_host) do
          {:ok, {head, origin}} -> {:ok, unrouted_provenance(head, {:ok, origin})}
          {:error, :git_read_failed} -> {:ok, empty_provenance()}
          {:error, reason} -> {:error, {:workspace_provenance_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:workspace_provenance_failed, reason}}
    end
  end

  defp capture_workspace_provenance(workspace, %RepositoryRouter.Route{} = route, nil) do
    with :ok <- validate_workspace_path(workspace, nil),
         {:ok, head} <- local_git_output(workspace, ["rev-parse", "--verify", "HEAD^{commit}"]),
         {:ok, origin} <- local_origin(workspace) do
      {:ok, provenance(route, head, origin)}
    else
      {:error, reason} -> {:error, {:workspace_provenance_failed, reason}}
    end
  end

  defp capture_workspace_provenance(workspace, %RepositoryRouter.Route{} = route, worker_host)
       when is_binary(worker_host) do
    with :ok <- validate_workspace_path(workspace, worker_host),
         {:ok, {head, origin}} <- remote_git_provenance(workspace, worker_host) do
      {:ok, provenance(route, head, origin)}
    else
      {:error, reason} -> {:error, {:workspace_provenance_failed, reason}}
    end
  end

  defp empty_provenance do
    %{
      repository_target: nil,
      repository_source_path: nil,
      repository_default_branch: nil,
      configured_remote: nil,
      repository_origin: nil,
      prepared_base_commit: nil
    }
  end

  defp local_origin(workspace) do
    case local_git_output(workspace, ["remote", "get-url", "origin"]) do
      {:ok, origin} -> {:ok, origin}
      {:error, :git_read_failed} -> {:ok, nil}
    end
  end

  defp local_git_output(workspace, args) do
    case System.cmd("git", ["-c", "safe.directory=#{workspace}", "-C", workspace | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {_output, _status} -> {:error, :git_read_failed}
    end
  end

  defp remote_git_provenance(workspace, worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        "head=$(git -c \"safe.directory=$workspace\" -C \"$workspace\" rev-parse --verify 'HEAD^{commit}')",
        "origin=$(git -c \"safe.directory=$workspace\" -C \"$workspace\" remote get-url origin 2>/dev/null || true)",
        "printf '%s\\t%s\\t%s\\n' '#{@remote_provenance_marker}' \"$head\" \"${origin:-}\""
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} -> parse_remote_provenance_output(output)
      {:ok, {_output, _status}} -> {:error, :git_read_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_remote_provenance_output(output) do
    output
    |> IO.iodata_to_binary()
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn line ->
      case String.split(line, "\t", parts: 3) do
        [@remote_provenance_marker, head, origin] when head != "" -> {:ok, {head, origin}}
        _ -> nil
      end
    end)
    |> case do
      nil -> {:error, :invalid_git_read_output}
      result -> result
    end
  end

  defp provenance(route, head, origin) do
    %{
      repository_target: route.target,
      repository_source_path: route.source_path,
      repository_default_branch: route.default_branch,
      configured_remote: redact_remote(route.remote),
      repository_origin: redact_remote(origin),
      prepared_base_commit: head
    }
  end

  defp unrouted_provenance(head, {:ok, origin}) do
    empty_provenance()
    |> Map.put(:prepared_base_commit, head)
    |> Map.put(:repository_origin, redact_remote(origin))
  end

  defp redact_remote(nil), do: nil

  defp redact_remote(remote) when is_binary(remote) do
    remote
    |> String.trim()
    |> String.replace(~r<(://)[^/@\s]+@>, "\\1")
    |> String.replace(~r<^([^/@\s]+)@(?=[^:/\s]+[:/])>, "")
    |> String.replace(~r/[?#].*$/, "")
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context =
      case resolve_repository_route(issue_or_identifier) do
        {:ok, route} -> issue_or_identifier |> issue_context() |> Map.put(:repository_route, route)
        {:error, _reason} -> issue_context(issue_or_identifier)
      end

    hooks = Config.settings!().hooks

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run", worker_host)
        |> ignore_hook_failure()
    end
  end

  @doc false
  @spec workspace_path(issue_reference(), worker_host()) :: {:ok, Path.t()} | {:error, term()}
  def workspace_path(issue_or_identifier, worker_host \\ nil) do
    safe_id = workspace_key(issue_or_identifier)
    workspace_path_for_issue(safe_id, worker_host)
  end

  @doc false
  @spec classify_candidate(issue_reference(), worker_host()) ::
          {:ok, classification(), Path.t(), route()} | {:error, term()}
  def classify_candidate(issue_or_identifier, worker_host \\ nil) do
    with {:ok, route} <- resolve_repository_route(issue_or_identifier),
         {:ok, workspace} <- workspace_path(issue_or_identifier, worker_host) do
      case workspace_exists?(workspace, worker_host) do
        true ->
          case verify_workspace_git_identity(workspace, route, worker_host) do
            :ok ->
              {:ok, :resume, workspace, route}

            {:error, _reason} = error ->
              error
          end

        false ->
          {:ok, :fresh, workspace, route}
      end
    end
  end

  defp workspace_exists?(workspace, nil) when is_binary(workspace), do: File.exists?(workspace)
  defp workspace_exists?(_workspace, _worker_host), do: false

  defp workspace_path_for_issue(safe_id, nil) when is_binary(safe_id) do
    Config.local_workspace_root()
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp workspace_path_for_issue(safe_id, worker_host) when is_binary(safe_id) and is_binary(worker_host) do
    {:ok, Path.join(Config.settings!().workspace.root, safe_id)}
  end

  @doc """
  Returns the collision-safe directory name for an issue identifier.

  The hash is derived from the original identifier so callers that only know the identifier can
  derive the same key as callers holding a full tracker issue.
  """
  @spec workspace_key(map() | String.t() | nil) :: String.t()
  def workspace_key(%{identifier: identifier}), do: workspace_key(identifier)

  def workspace_key(identifier) when is_binary(identifier) do
    safe_identifier = safe_identifier(identifier)

    if safe_identifier == identifier do
      safe_identifier
    else
      "#{safe_identifier}--#{short_identifier_hash(identifier)}"
    end
  end

  def workspace_key(_identifier), do: "issue"

  defp safe_identifier(identifier) when is_binary(identifier),
    do: String.replace(identifier, ~r/[^a-zA-Z0-9._-]/, "_")

  defp short_identifier_hash(identifier) do
    :crypto.hash(:sha256, identifier)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
    hooks = Config.settings!().hooks

    case created? do
      true ->
        case hooks.after_create do
          nil ->
            :ok

          command ->
            run_hook(command, workspace, issue_context, "after_create", worker_host)
        end

      false ->
        :ok
    end
  end

  defp cleanup_failed_new_workspace(_workspace, false, _worker_host), do: :ok

  defp cleanup_failed_new_workspace(workspace, true, nil) do
    case File.rm_rf(workspace) do
      {:ok, _removed} ->
        :ok

      {:error, reason, path} ->
        Logger.warning("Failed to remove partial workspace path=#{path} reason=#{inspect(reason)}")
    end
  end

  defp cleanup_failed_new_workspace(workspace, true, worker_host) when is_binary(worker_host) do
    script = [remote_shell_assign("workspace", workspace), "rm -rf \"$workspace\""] |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        :ok

      result ->
        Logger.warning("Failed to remove partial workspace worker_host=#{worker_host_for_log(worker_host)} result=#{inspect(result)}")
    end
  end

  defp maybe_run_before_remove_hook(workspace, nil) do
    hooks = Config.settings!().hooks

    case File.dir?(workspace) do
      true ->
        case hooks.before_remove do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove",
              nil
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, worker_host) when is_binary(worker_host) do
    hooks = Config.settings!().hooks

    case hooks.before_remove do
      nil ->
        :ok

      command ->
        script =
          [
            remote_shell_assign("workspace", workspace),
            "if [ -d \"$workspace\" ]; then",
            "  cd \"$workspace\"",
            "  #{command}",
            "fi"
          ]
          |> Enum.join("\n")

        run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms)
        |> case do
          {:ok, {output, status}} ->
            handle_hook_command_result(
              {output, status},
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )

          {:error, {:workspace_hook_timeout, "before_remove", _timeout_ms} = reason} ->
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end
        |> ignore_hook_failure()
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name, nil) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")

    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", command],
          cd: workspace,
          env: repository_route_environment(issue_context),
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp run_hook(command, workspace, issue_context, hook_name, worker_host) when is_binary(worker_host) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

    script =
      [
        repository_route_shell_assignments(issue_context),
        "cd #{shell_escape(workspace)} && #{command}"
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      {:error, {:workspace_hook_timeout, ^hook_name, _timeout_ms} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp validate_workspace_path(workspace, nil) when is_binary(workspace) do
    validate_local_workspace_path(workspace, Config.local_workspace_root())
  end

  defp validate_workspace_path(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:workspace_path_unreadable, workspace, :invalid_characters}}

      true ->
        :ok
    end
  end

  # Trusted deletion boundary for recorded cleanup: the root the workspace was created
  # under whenever that root was recorded, otherwise the current configured root. The
  # recorded root is preferred because WORKFLOW.md may have moved the active root since
  # the workspace was created, and that move must not silently retarget deletion.
  defp trusted_local_workspace_root(recorded_root) when is_binary(recorded_root) do
    case String.trim(recorded_root) do
      "" -> Config.local_workspace_root()
      root -> root
    end
  end

  defp trusted_local_workspace_root(_recorded_root), do: Config.local_workspace_root()

  defp trusted_remote_workspace_root(recorded_root) when is_binary(recorded_root) do
    case String.trim(recorded_root) do
      "" -> configured_remote_workspace_root()
      root -> root
    end
  end

  defp trusted_remote_workspace_root(_recorded_root), do: configured_remote_workspace_root()

  defp configured_remote_workspace_root do
    case Config.settings!().workspace.root do
      root when is_binary(root) -> root
      _ -> nil
    end
  end

  defp validate_local_workspace_path(workspace, workspace_root)
       when is_binary(workspace) and is_binary(workspace_root) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(workspace_root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  # Remote containment is decided on the path strings themselves. The recorded workspace
  # and the recorded root are both the worker host's canonical `pwd -P` output, and this
  # control host cannot resolve another machine's filesystem, so comparing the
  # already-canonical remote paths is the honest test. Shell escaping is not containment:
  # anything that cannot be proven to sit strictly inside the trusted root is rejected
  # before the hook or `rm -rf` command is built. A `~`-relative trusted root is rejected
  # for the same reason: matching the root's tail segments against an unresolved home
  # directory would accept paths that are not provably inside it. Roots recorded by the
  # prepare script are already `pwd -P` output, so this only fails closed for metadata
  # that never carried a resolved root.
  defp validate_remote_workspace_path(workspace, workspace_root)
       when is_binary(workspace) and is_binary(workspace_root) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:workspace_path_unreadable, workspace, :invalid_characters}}

      not absolute_posix_path?(workspace) ->
        {:error, {:workspace_path_unreadable, workspace, :not_absolute}}

      not absolute_posix_path?(workspace_root) ->
        {:error, {:workspace_path_unreadable, workspace_root, :not_absolute}}

      true ->
        remote_containment_result(normalize_posix_path(workspace), normalize_posix_path(workspace_root))
    end
  end

  defp validate_remote_workspace_path(workspace, _workspace_root) when is_binary(workspace) do
    {:error, {:workspace_path_unreadable, workspace, :invalid}}
  end

  defp remote_containment_result(workspace, workspace_root) do
    root_prefix = if String.ends_with?(workspace_root, "/"), do: workspace_root, else: workspace_root <> "/"

    cond do
      workspace == workspace_root ->
        {:error, {:workspace_equals_root, workspace, workspace_root}}

      String.starts_with?(workspace, root_prefix) ->
        :ok

      true ->
        {:error, {:workspace_outside_root, workspace, workspace_root}}
    end
  end

  defp absolute_posix_path?(path) when is_binary(path) do
    String.starts_with?(path, "/")
  end

  defp normalize_posix_path(path) when is_binary(path) do
    path_without_base = String.trim_leading(path, "/")

    segments =
      path_without_base
      |> String.split("/", trim: true)
      |> Enum.reduce([], fn
        ".", segments -> segments
        "..", [] -> []
        "..", [_dropped | rest] -> rest
        segment, segments -> [segment | segments]
      end)
      |> Enum.reverse()

    case segments do
      [] -> "/"
      segs -> "/" <> Enum.join(segs, "/")
    end
  end

  defp remote_shell_assign(variable_name, raw_path)
       when is_binary(variable_name) and is_binary(raw_path) do
    [
      "#{variable_name}=#{shell_escape(raw_path)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#\\~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  defp parse_remote_workspace_output(output) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    payload =
      Enum.find_value(lines, fn line ->
        case String.split(line, "\t") do
          [@remote_workspace_marker, created, path] when created in ["0", "1"] and path != "" ->
            {created == "1", path, nil}

          [@remote_workspace_marker, created, path, root]
          when created in ["0", "1"] and path != "" ->
            {created == "1", path, normalize_recorded_root(root)}

          _ ->
            nil
        end
      end)

    case payload do
      {created?, workspace, recorded_root} when is_boolean(created?) and is_binary(workspace) ->
        {:ok, workspace, created?, recorded_root}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  # The prepare script reports the trusted root it resolved on the worker host. An older
  # or truncated marker line leaves it empty, which callers treat as "no recorded root".
  defp normalize_recorded_root(root) when is_binary(root) do
    case String.trim(root) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp run_remote_command(worker_host, script, timeout_ms)
       when is_binary(worker_host) and is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue"
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue"
    }
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end

  defp resolve_repository_route(%SymphonyElixir.Tracker.Issue{} = issue) do
    RepositoryRouter.resolve(issue, Config.settings!().routing)
  end

  defp resolve_repository_route(_issue), do: {:ok, nil}

  defp sync_source_baseline(nil, _issue_context, _worker_host), do: :ok

  defp sync_source_baseline(%RepositoryRouter.Route{} = route, issue_context, nil) do
    case SourceSync.sync(route) do
      {:ok, result} ->
        Logger.info("Source baseline synchronized #{issue_log_context(issue_context)} target=#{route.target} result=#{SourceSync.reason_code_string(result)}")

        :ok

      {:error, reason} ->
        reason_code = SourceSync.reason_code_string(reason)

        Logger.warning("Source baseline sync failed #{issue_log_context(issue_context)} target=#{route.target} reason=#{reason_code}")

        {:error, {:source_baseline_sync_failed, route.target, reason}}
    end
  end

  defp sync_source_baseline(%RepositoryRouter.Route{}, _issue_context, worker_host)
       when is_binary(worker_host),
       do: :ok

  # A reused workspace is trusted only after its Git repository identity matches the
  # selected route's source repository. A freshly created workspace is prepared from that
  # source by the after_create hook, so it needs no re-verification. Unrouted issues keep
  # their historical reuse behavior.
  defp verify_reused_workspace_repository(_workspace, _route, true, _worker_host), do: :ok

  defp verify_reused_workspace_repository(workspace, route, false, worker_host) do
    verify_workspace_git_identity(workspace, route, worker_host)
  end

  @doc false
  @spec verify_workspace_git_identity(Path.t(), route(), worker_host()) :: :ok | {:error, term()}
  def verify_workspace_git_identity(_workspace, nil, _worker_host), do: :ok
  # Remote worker hosts keep their historical reuse behavior: the local Git identity probe
  # cannot read a remote filesystem, and the configured worker fleet does not use remote
  # reuse. Tightening this requires a remote identity probe and is tracked separately.
  def verify_workspace_git_identity(_workspace, _route, worker_host) when is_binary(worker_host), do: :ok

  def verify_workspace_git_identity(workspace, %RepositoryRouter.Route{} = route, nil) do
    case local_git_common_dir(workspace) do
      {:ok, workspace_common_dir} ->
        case local_git_common_dir(route.source_path) do
          {:ok, source_common_dir} ->
            if normalize_git_dir(workspace_common_dir) == normalize_git_dir(source_common_dir) do
              :ok
            else
              {:error,
               {:workspace_repository_mismatch, route.target, {:git_common_dir, workspace_common_dir, source_common_dir}}}
            end

          {:error, :git_read_failed} ->
            {:error, {:workspace_repository_mismatch, route.target, :source_not_a_git_repository}}
        end

      {:error, :git_read_failed} ->
        {:error, {:workspace_repository_mismatch, route.target, :workspace_not_a_git_repository}}
    end
  end

  defp local_git_common_dir(repo_path) when is_binary(repo_path) do
    case System.cmd(
           "git",
           [
             "-c",
             "safe.directory=#{repo_path}",
             "-C",
             repo_path,
             "rev-parse",
             "--path-format=absolute",
             "--git-common-dir"
           ],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case String.trim(output) do
          "" ->
            {:error, :git_read_failed}

          common_dir ->
            case PathSafety.canonicalize(common_dir) do
              {:ok, canonical_common_dir} -> {:ok, canonical_common_dir}
              {:error, _reason} -> {:error, :git_read_failed}
            end
        end

      {_output, _status} ->
        {:error, :git_read_failed}
    end
  end

  defp normalize_git_dir(path) when is_binary(path) do
    case :os.type() do
      {:win32, _} -> path |> String.replace("\\", "/") |> String.downcase()
      _ -> path
    end
  end

  defp repository_route_environment(%{
         repository_route: %RepositoryRouter.Route{} = route,
         issue_identifier: issue_identifier
       }) do
    [
      {"SYMPHONY_ISSUE_IDENTIFIER", issue_identifier},
      {"SYMPHONY_REPOSITORY_TARGET", route.target},
      {"SYMPHONY_REPOSITORY_SOURCE_PATH", route.source_path},
      {"SYMPHONY_REPOSITORY_DEFAULT_BRANCH", route.default_branch}
    ] ++ optional_route_environment(route.remote)
  end

  defp repository_route_environment(%{issue_identifier: issue_identifier}) when is_binary(issue_identifier),
    do: [{"SYMPHONY_ISSUE_IDENTIFIER", issue_identifier}]

  defp repository_route_environment(_issue_context), do: []

  defp optional_route_environment(nil), do: []
  defp optional_route_environment(remote), do: [{"SYMPHONY_REPOSITORY_REMOTE", remote}]

  defp repository_route_shell_assignments(issue_context) do
    issue_context
    |> repository_route_environment()
    |> Enum.map_join("\n", fn {name, value} -> "export #{name}=#{shell_escape(value)}" end)
  end
end
