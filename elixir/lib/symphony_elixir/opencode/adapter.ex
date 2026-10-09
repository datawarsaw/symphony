defmodule SymphonyElixir.OpenCode.Adapter do
  @moduledoc """
  Standalone non-interactive OpenCode process adapter for Symphony workers.

  Security and reliability invariants:
  - Explicit provider and model routing: rejects bare models and forbids automatic provider fallback.
  - Deny-by-default tool permissions: configuration is generated per launch with tools denied by default.
  - Credential boundary: unrelated provider keys and tracker secrets are scrubbed from child environment.
  - State isolation: session, cache, and config dirs are isolated from the user's global ~/.local or ~/.config dirs.
  - Windows Job Object containment: integrated with jobrun wrapper (KILL_ON_JOB_CLOSE, positive death receipts).
  - Clean lifecycle: supports natural process exits and forced termination with verifiable receipts.
  """

  require Logger

  alias SymphonyElixir.OpenCode.{Config, Environment, Failure, Parser}
  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.WorkerContainment

  @default_timeout_ms 60_000

  @type session :: %{
          port: port(),
          identity: map() | nil,
          workspace: Path.t(),
          dirs: map(),
          executable: String.t(),
          provider: String.t(),
          model: String.t(),
          launch_id: String.t(),
          parser: %Parser.State{}
        }

  @type run_result :: %{
          optional(:failure_info) => map(),
          optional(:termination) => map() | nil,
          optional(:exit_code) => integer() | nil,
          required(:session_id) => String.t() | nil,
          required(:message_ids) => [String.t()],
          required(:tool_events) => [map()],
          required(:completion_state) => atom(),
          required(:usage) => map(),
          required(:failure_evidence) => [term()]
        }

  # ---------------------------------------------------------------------------
  # High-level run/3
  # ---------------------------------------------------------------------------

  @doc """
  Runs an OpenCode worker non-interactively in the given workspace.
  Spawns the process under Job containment, parses JSONL output incrementally,
  awaits completion, and ensures positive termination confirmation.
  """
  @spec run(Path.t(), String.t(), keyword()) :: {:ok, run_result()} | {:error, term()}
  def run(workspace, prompt, opts \\ []) do
    with {:ok, session} <- start_session(workspace, prompt, opts) do
      try do
        timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
        await_completion(session, timeout_ms, opts)
      after
        # Always confirm termination upon exit
        stop_session(session)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Session Lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Starts an OpenCode process session.
  Validates model/provider selection, prepares isolated environment,
  writes deny-by-default config, and opens the contained Port.
  """
  @spec start_session(Path.t(), String.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, prompt, opts \\ []) do
    with {:ok, {provider, model}} <- validate_model_selection(opts),
         {:ok, canonical_workspace} <- validate_workspace(workspace),
         {:ok, executable} <- resolve_executable(opts) do
      launch_id =
        Keyword.get(opts, :launch_id) ||
          "#{System.system_time(:millisecond)}-#{:erlang.unique_integer([:positive])}"

      with {:ok, dirs} <- Environment.prepare_directories(canonical_workspace, launch_id),
           {:ok, _config_file} <- Config.write_config(dirs.config, opts),
           {:ok, port_env} <- Environment.build_port_env(provider, dirs, opts) do
        worker_host = Keyword.get(opts, :worker_host)
        contained? = WorkerContainment.contained_launch?(worker_host)

        identity =
          if contained? do
            WorkerContainment.new_identity(
              issue_id: Keyword.get(opts, :issue_id),
              attempt_id: Keyword.get(opts, :attempt_id),
              workspace: canonical_workspace,
              worker_host: nil,
              authority_root: Keyword.get(opts, :authority_root)
            )
          else
            nil
          end

        child_args = build_opencode_args(provider, model, canonical_workspace, prompt, opts)

        case start_port(canonical_workspace, executable, child_args, port_env, identity) do
          {:ok, port} ->
            session = %{
              port: port,
              identity: identity,
              workspace: canonical_workspace,
              dirs: dirs,
              executable: executable,
              provider: provider,
              model: model,
              launch_id: launch_id,
              parser: Parser.new()
            }

            {:ok, session}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  @doc """
  Stops an active OpenCode session and collects positive termination confirmation.
  If running under Windows Job containment, confirms ActiveProcesses == 0 via receipt.
  """
  @spec stop_session(session()) :: map()
  def stop_session(%{port: port, identity: identity}) do
    if identity && is_port(port) do
      grace_ms = WorkerContainment.grace_ms()
      WorkerContainment.stop_and_confirm(port, identity, grace_ms)
    else
      if is_port(port) do
        try do
          Port.close(port)
        rescue
          _ -> :ok
        end
      end

      %{status: :NOT_APPLICABLE}
    end
  end

  def stop_session(_), do: %{status: :NOT_APPLICABLE}

  # ---------------------------------------------------------------------------
  # Stream processing & waiting
  # ---------------------------------------------------------------------------

  defp await_completion(session, timeout_ms, opts) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    on_event = Keyword.get(opts, :on_event)
    loop_stream(session.port, session.parser, deadline, on_event, session)
  end

  defp loop_stream(port, parser, deadline, on_event, session) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        chunk = normalize_chunk(data)
        updated_parser = Parser.feed(parser, chunk)

        if is_function(on_event, 1) do
          for event <- updated_parser.events -- parser.events do
            on_event.(event)
          end
        end

        loop_stream(port, updated_parser, deadline, on_event, session)

      {^port, {:exit_status, status}} ->
        final_parser = Parser.finish(parser, status)
        result = Parser.to_result(final_parser)

        # Collect receipt evidence if contained
        termination =
          if session.identity do
            confirmation = WorkerContainment.stop_and_confirm(port, session.identity, WorkerContainment.grace_ms())
            confirmation
          else
            %{status: :NOT_APPLICABLE}
          end

        final_result =
          result
          |> Map.put(:termination, termination)
          |> Map.put(:exit_code, status)

        if status == 0 and final_parser.completion_state != :failed do
          {:ok, final_result}
        else
          error_reason =
            find_primary_failure_reason(final_parser.failure_evidence, status)

          failure_info = Failure.failure_info(error_reason)
          {:error, {error_reason, Map.put(final_result, :failure_info, failure_info)}}
        end
    after
      remaining_ms ->
        # Timed out waiting for completion
        termination = stop_session(session)
        final_parser = Parser.finish(parser, 253)
        result = Parser.to_result(final_parser)
        failure_info = Failure.failure_info(:timeout)

        final_result =
          result
          |> Map.put(:termination, termination)
          |> Map.put(:exit_code, 253)
          |> Map.put(:failure_info, failure_info)

        {:error, {:timeout, final_result}}
    end
  end

  defp find_primary_failure_reason(evidence_list, status) do
    # Prioritize specific protocol or tool errors over generic process exit code
    Enum.find(evidence_list, fn
      {:process_exit, _} -> false
      _ -> true
    end) || List.first(evidence_list) || {:process_exit, status}
  end

  defp normalize_chunk({:eol, line}), do: line <> "\n"
  defp normalize_chunk({:noeol, line}), do: line
  defp normalize_chunk(binary) when is_binary(binary), do: binary
  defp normalize_chunk(other), do: to_string(other)

  # ---------------------------------------------------------------------------
  # Process spawning (jobrun containment or direct)
  # ---------------------------------------------------------------------------

  defp start_port(workspace, executable, child_args, env, nil) do
    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: Enum.map(child_args, &String.to_charlist/1),
          cd: String.to_charlist(workspace),
          env: env
        ]
      )

    {:ok, port}
  rescue
    error in ErlangError -> {:error, {:port_spawn_failed, error.original}}
    error -> {:error, {:port_spawn_failed, Exception.message(error)}}
  end

  defp start_port(workspace, executable, child_args, env, identity) when not is_nil(identity) do
    with {:ok, jobrun} <- WorkerContainment.helper_path() do
      wrapper_args =
        WorkerContainment.launch_args(
          identity,
          executable,
          Enum.map(child_args, &String.to_charlist/1)
        )

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(jobrun)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: wrapper_args,
            cd: String.to_charlist(workspace),
            env: env
          ]
        )

      {:ok, port}
    end
  rescue
    error in ErlangError -> {:error, {:port_spawn_failed, error.original}}
    error -> {:error, {:port_spawn_failed, Exception.message(error)}}
  end

  # ---------------------------------------------------------------------------
  # Validation & resolution
  # ---------------------------------------------------------------------------

  @doc """
  Validates explicit provider/model selection.
  Requires either `model: "provider/model_name"` or explicit `provider: "..."` and `model: "..."`.
  Rejects bare models without a provider to forbid automatic provider fallback.
  """
  @spec validate_model_selection(keyword()) :: {:ok, {String.t(), String.t()}} | {:error, term()}
  def validate_model_selection(opts) do
    raw_model = Keyword.get(opts, :model)
    raw_provider = Keyword.get(opts, :provider)

    cond do
      is_nil(raw_model) or String.trim(to_string(raw_model)) == "" ->
        {:error, :missing_model}

      is_binary(raw_provider) and String.trim(raw_provider) != "" ->
        provider = String.trim(raw_provider)
        model = raw_model |> to_string() |> String.trim()
        # If model starts with provider/, strip it
        clean_model =
          if String.starts_with?(model, provider <> "/") do
            String.replace_prefix(model, provider <> "/", "")
          else
            model
          end

        if clean_model == "" do
          {:error, :missing_model}
        else
          {:ok, {provider, clean_model}}
        end

      is_binary(raw_model) ->
        trimmed = String.trim(raw_model)

        case String.split(trimmed, "/", parts: 2) do
          [provider, model] when provider != "" and model != "" ->
            {:ok, {provider, model}}

          _ ->
            # Bare model without provider rejected (forbids automatic fallback)
            {:error, {:invalid_model_selection, "Model must be specified as 'provider/model'. Automatic fallback is forbidden."}}
        end

      true ->
        {:error, :invalid_model_selection}
    end
  end

  @doc """
  Builds CLI arguments vector for non-interactive OpenCode execution.
  """
  @spec build_opencode_args(String.t(), String.t(), Path.t(), String.t(), keyword()) :: [String.t()]
  def build_opencode_args(provider, model, workspace, prompt, opts) do
    model_spec = "#{provider}/#{model}"

    base = [
      "run",
      "--format",
      "json",
      "-m",
      model_spec,
      "--dir",
      workspace,
      "--pure"
    ]

    variant = Keyword.get(opts, :variant)

    args_with_variant =
      if is_binary(variant) and variant != "" do
        base ++ ["--variant", variant]
      else
        base
      end

    title = Keyword.get(opts, :title)

    args_with_title =
      if is_binary(title) and title != "" do
        args_with_variant ++ ["--title", title]
      else
        args_with_variant
      end

    args_with_title ++ [prompt]
  end

  @doc """
  Resolves the OpenCode executable path.
  Prioritizes explicit `executable` in opts, then looks for `opencode.exe` on Windows
  or `opencode` in PATH.
  """
  @spec resolve_executable(keyword()) :: {:ok, String.t()} | {:error, term()}
  def resolve_executable(opts \\ []) do
    case Keyword.get(opts, :executable) do
      path when is_binary(path) and path != "" ->
        validate_executable_path(path)

      _ ->
        discover_opencode_executable()
    end
  end

  defp validate_executable_path(path) do
    expanded = Path.expand(path)

    if File.exists?(expanded) do
      {:ok, expanded}
    else
      case System.find_executable(path) do
        found when is_binary(found) -> {:ok, Path.expand(found)}
        nil -> {:error, {:executable_not_found, path}}
      end
    end
  end

  defp discover_opencode_executable do
    home = System.user_home!() || ""

    candidates =
      case :os.type() do
        {:win32, _} ->
          [
            Path.join([home, "AppData", "Roaming", "npm", "node_modules", "opencode-ai", "bin", "opencode.exe"]),
            Path.join([home, ".cache", "opencode", "bin", "opencode.exe"]),
            Path.join([home, "AppData", "Roaming", "npm", "opencode.cmd"])
          ]

        _ ->
          [
            Path.join([home, ".cache", "opencode", "bin", "opencode"]),
            "/usr/local/bin/opencode",
            "/usr/bin/opencode"
          ]
      end

    found =
      Enum.find(candidates, &File.exists?/1) ||
        System.find_executable("opencode.exe") ||
        System.find_executable("opencode")

    case found do
      path when is_binary(path) and path != "" ->
        {:ok, Path.expand(path)}

      _ ->
        {:error, :opencode_executable_not_found}
    end
  end

  defp validate_workspace(workspace) do
    with {:ok, canonical} <- PathSafety.canonicalize(workspace),
         true <- File.dir?(canonical) || {:error, {:workspace_not_a_directory, canonical}} do
      {:ok, canonical}
    end
  end
end
