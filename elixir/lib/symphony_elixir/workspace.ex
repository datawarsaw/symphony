defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{Config, PathSafety, SSH, Workflow}

  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"
  @provenance_file ".symphony-provenance.json"

  @type worker_host :: String.t() | nil

  @spec create_for_issue(map() | String.t() | nil, worker_host()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host \\ nil) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = workspace_key(issue_or_identifier)

      with {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host),
           :ok <- validate_workspace_path(workspace, worker_host),
           {:ok, workspace, created?} <- ensure_workspace(workspace, worker_host) do
        case prepare_repository(workspace, worker_host) do
          :ok ->
            case maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
              :ok ->
                {:ok, workspace}

              {:error, _reason} = error ->
                cleanup_failed_new_workspace(workspace, created?, worker_host)
                error
            end

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

  @doc false
  @spec validate_preparation(Path.t()) :: :ok | {:error, term()}
  def validate_preparation(workspace), do: validate_preparation(workspace, nil)

  @doc false
  @spec validate_preparation(Path.t(), worker_host()) :: :ok | {:error, term()}
  def validate_preparation(_workspace, worker_host) when is_binary(worker_host) do
    case Config.settings!().workspace.repository do
      nil -> :ok
      "" -> :ok
      _repository -> {:error, {:workspace_sync_unsupported_remote, worker_host}}
    end
  end

  def validate_preparation(workspace, nil) when is_binary(workspace) do
    case Config.settings!().workspace.repository do
      repository when is_binary(repository) and repository != "" ->
        with :ok <- verify_git_metadata(workspace),
             :ok <- verify_checkout_location(workspace),
             :ok <- verify_provenance_destination(workspace),
             {:ok, %{origin: expected_origin, base_commit: base_commit}} <-
               read_repository_provenance(workspace, normalize_repository(repository)),
             {:ok, origin} <- git_output(workspace, ["remote", "get-url", "origin"]),
             :ok <- verify_origin(expected_origin, origin),
             {:ok, ^base_commit} <- git_output(workspace, ["rev-parse", "HEAD"]) do
          :ok
        else
          {:error, {:workspace_sync_failed, :provenance_repository_mismatch, _}} = error -> error
          _ -> {:error, {:workspace_sync_failed, :preparation_changed, workspace}}
        end

      _ ->
        :ok
    end
  end

  defp read_repository_provenance(workspace, repository) do
    case read_provenance(workspace) do
      {:ok, %{repository: ^repository}} = result -> result
      {:ok, _provenance} -> {:error, {:workspace_sync_failed, :provenance_repository_mismatch, workspace}}
      :error -> :error
    end
  end

  defp ensure_workspace(workspace, nil) do
    cond do
      File.dir?(workspace) ->
        {:ok, workspace, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp ensure_workspace(workspace, worker_host) when is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
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
        "printf '%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$created\" \"$(pwd -P)\""
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

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, workspace, true}
  end

  # Repository synchronization deliberately happens here, on the orchestration host, before the
  # app-server starts. Codex receives the prepared checkout with its Git directory read-only.
  defp prepare_repository(_workspace, worker_host) when is_binary(worker_host) do
    case Config.settings!().workspace.repository do
      nil -> :ok
      "" -> :ok
      _source -> {:error, {:workspace_sync_unsupported_remote, worker_host}}
    end
  end

  defp prepare_repository(workspace, nil) do
    case Config.settings!().workspace do
      %{repository: repository} when is_binary(repository) and repository != "" ->
        sync_local_repository(workspace, repository)

      _ ->
        :ok
    end
  end

  defp sync_local_repository(workspace, repository) do
    repository = normalize_repository(repository)

    with :ok <- ensure_checkout(workspace, repository),
         :ok <- verify_checkout_location(workspace),
         :ok <- verify_provenance_destination(workspace),
         {:ok, origin} <- git_output(workspace, ["remote", "get-url", "origin"]),
         :ok <- verify_origin(repository, origin),
         :ok <- git(workspace, ["fetch", "--quiet", "origin", "--", Config.settings!().workspace.base_ref]),
         {:ok, base_commit} <- git_output(workspace, ["rev-parse", "FETCH_HEAD"]),
         {:ok, dirty?} <- dirty_checkout?(workspace),
         :ok <- checkout_or_preserve_dirty(workspace, dirty?, base_commit),
         :ok <- write_provenance(workspace, repository, origin, base_commit) do
      :ok
    end
  end

  defp ensure_checkout(workspace, source) do
    git_metadata = Path.join(workspace, ".git")

    case File.lstat(git_metadata) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:ok, _stat} ->
        {:error, {:workspace_sync_failed, :unsafe_git_metadata, git_metadata}}

      {:error, :enoent} ->
        if directory_empty?(workspace) do
          git(Path.dirname(workspace), ["clone", "--no-local", "--", source, workspace])
        else
          {:error, {:workspace_sync_failed, :not_a_git_checkout, workspace}}
        end

      {:error, reason} ->
        {:error, {:workspace_sync_failed, :git_metadata_unreadable, git_metadata, reason}}
    end
  end

  defp directory_empty?(workspace) do
    case File.ls(workspace) do
      {:ok, []} -> true
      _ -> false
    end
  end

  defp verify_git_metadata(workspace) do
    metadata = Path.join(workspace, ".git")

    case File.lstat(metadata) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      _ -> {:error, {:workspace_sync_failed, :unsafe_git_metadata, metadata}}
    end
  end

  defp verify_provenance_destination(workspace) do
    path = Path.join([workspace, ".git", @provenance_file])

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:error, :enoent} -> :ok
      _ -> {:error, {:workspace_sync_failed, :unsafe_provenance_metadata, path}}
    end
  end

  defp verify_origin(repository, origin) do
    if normalize_repository(repository) == normalize_repository(origin) do
      :ok
    else
      {:error, {:workspace_sync_failed, :unexpected_origin, repository, origin}}
    end
  end

  defp verify_checkout_location(workspace) do
    with {:ok, top_level} <- git_output(workspace, ["rev-parse", "--show-toplevel"]),
         {:ok, git_dir} <- git_output(workspace, ["rev-parse", "--absolute-git-dir"]),
         {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace),
         {:ok, ^canonical_workspace} <- PathSafety.canonicalize(top_level),
         {:ok, canonical_git_dir} <- PathSafety.canonicalize(git_dir),
         {:ok, ^canonical_git_dir} <- PathSafety.canonicalize(Path.join(workspace, ".git")) do
      :ok
    else
      _ -> {:error, {:workspace_sync_failed, :unsafe_checkout_location, workspace}}
    end
  end

  defp normalize_repository(repository) do
    windows_drive? = String.match?(repository, ~r/^[A-Za-z]:[\\\/]/)
    scp_source? = String.match?(repository, ~r/^(?:[^\s\/\\@]+@)?(?:\[[^\]]+\]|[^\s\/\\:]+):.+$/)

    if String.contains?(repository, "://") or (scp_source? and not windows_drive?) do
      repository
    else
      workflow_dir = Workflow.workflow_file_path() |> Path.expand() |> Path.dirname()
      Path.expand(repository, workflow_dir)
    end
  end

  defp dirty_checkout?(workspace) do
    with {:ok, output} <- git_output(workspace, ["status", "--porcelain", "--untracked-files=all"]) do
      {:ok, String.trim(output) != ""}
    end
  end

  defp checkout_or_preserve_dirty(workspace, false, _base_commit) do
    git(workspace, ["checkout", "--quiet", "--detach", "FETCH_HEAD"])
  end

  defp checkout_or_preserve_dirty(workspace, true, base_commit) do
    with {:ok, head} <- git_output(workspace, ["rev-parse", "HEAD"]) do
      case read_provenance(workspace) do
        {:ok, %{base_commit: ^base_commit}} when head == base_commit -> :ok
        _ -> {:error, {:workspace_sync_failed, :dirty_workspace, workspace, base_commit}}
      end
    end
  end

  defp write_provenance(workspace, source, origin, base_commit) do
    provenance = %{repository: source, origin: origin, base_commit: base_commit}
    File.write(Path.join([workspace, ".git", @provenance_file]), Jason.encode!(provenance))
  end

  defp read_provenance(workspace) do
    with {:ok, contents} <- File.read(Path.join([workspace, ".git", @provenance_file])),
         {:ok, provenance} <- Jason.decode(contents),
         repository when is_binary(repository) <- Map.get(provenance, "repository"),
         origin when is_binary(origin) <- Map.get(provenance, "origin"),
         base_commit when is_binary(base_commit) <- Map.get(provenance, "base_commit") do
      {:ok, %{repository: repository, origin: origin, base_commit: base_commit}}
    else
      _ -> :error
    end
  end

  defp git(workspace, args) do
    case run_git(workspace, args) do
      {_output, 0} -> :ok
      {:error, :timeout} -> {:error, {:workspace_sync_failed, :git_timeout, workspace}}
      {:error, {:exception, message}} -> {:error, {:workspace_sync_failed, :git_unavailable, message}}
      {output, status} -> {:error, {:workspace_sync_failed, :git, status, output}}
    end
  end

  defp git_output(workspace, args) do
    case run_git(workspace, args) do
      {output, 0} -> {:ok, String.trim(output)}
      {:error, :timeout} -> {:error, {:workspace_sync_failed, :git_timeout, workspace}}
      {:error, {:exception, message}} -> {:error, {:workspace_sync_failed, :git_unavailable, message}}
      {output, status} -> {:error, {:workspace_sync_failed, :git, status, output}}
    end
  end

  defp run_git(workspace, args) do
    task =
      Task.async(fn ->
        try do
          System.cmd("git", ["-C", workspace | args],
            stderr_to_stdout: true,
            env: [{"GIT_TERMINAL_PROMPT", "0"}]
          )
        rescue
          error -> {:error, {:exception, Exception.message(error)}}
        end
      end)

    case Task.yield(task, Config.settings!().hooks.timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, :timeout}
    end
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
  def remove_recorded(workspace, nil) when is_binary(workspace) do
    if Path.type(workspace) == :absolute do
      case validate_recorded_workspace_path(workspace) do
        :ok ->
          remove_local_workspace(workspace)

        {:error, reason} ->
          {:error, reason, ""}
      end
    else
      {:error, {:workspace_path_unreadable, workspace, :not_absolute}, ""}
    end
  end

  def remove_recorded(workspace, worker_host) when is_binary(workspace) and is_binary(worker_host) do
    remove(workspace, worker_host)
  end

  def remove_recorded(workspace, _worker_host) do
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
        case workspace_path_for_issue(workspace_key(issue), nil) do
          {:ok, workspace} -> remove(workspace, nil)
          {:error, _reason} -> :ok
        end

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
        case workspace_path_for_issue(workspace_key(identifier), nil) do
          {:ok, workspace} -> remove(workspace, nil)
          {:error, _reason} -> :ok
        end

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(identifier, &1))
    end

    :ok
  end

  def remove_issue_workspaces(_identifier, _worker_host), do: :ok

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.before_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run", worker_host)
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run", worker_host)
        |> ignore_hook_failure()
    end
  end

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
        System.cmd("sh", ["-lc", command], cd: workspace, stderr_to_stdout: true)
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

    case run_remote_command(worker_host, "cd #{shell_escape(workspace)} && #{command}", timeout_ms) do
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

  defp validate_recorded_workspace_path(workspace) when is_binary(workspace) do
    validate_local_workspace_path(workspace, Path.dirname(workspace))
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
        case String.split(line, "\t", parts: 3) do
          [@remote_workspace_marker, created, path] when created in ["0", "1"] and path != "" ->
            {created == "1", path}

          _ ->
            nil
        end
      end)

    case payload do
      {created?, workspace} when is_boolean(created?) and is_binary(workspace) ->
        {:ok, workspace, created?}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
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
end
