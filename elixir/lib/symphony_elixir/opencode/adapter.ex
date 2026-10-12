defmodule SymphonyElixir.OpenCode.Adapter do
  @moduledoc """
  Standalone non-interactive OpenCode process adapter for Symphony workers.

  Security and reliability invariants:
  - Local-host eligibility: a launch naming a remote worker_host is refused before any artifact exists;
    the adapter has no SSH execution path and never substitutes a local run for a remote one.
  - Explicit provider and model routing: rejects bare models and forbids automatic provider fallback.
  - Credential presence preflight: an armed launch is refused before any directory, config, marker,
    or process exists when the selected provider has no supported credential mapping, when no
    supported nonempty credential variable resolves for it, or when an endpoint/base-URL override
    would be inherited silently from the ambient environment. The check is presence-only and never
    authenticates; provider and model identity stay pinned with no substitution.
  - Deny-by-default tool permissions: configuration is generated per launch with tools denied by default.
  - Effective config isolation: project config is disabled and inherited OpenCode config, permission, and home lookup are pinned to the launch directory.
  - Credential boundary: the child environment is an allowlist limited to the selected provider.
  - State isolation: session, cache, and config dirs are isolated from the user's global ~/.local or ~/.config dirs.
  - Windows Job Object containment: integrated with jobrun wrapper (KILL_ON_JOB_CLOSE, positive death receipts).
  - Recoverable launch identity: a durable LaunchMarker is recorded before the OpenCode child process exists;
    it is cleared only on conclusive never-spawned or TERMINATED_CONFIRMED evidence, and unconfirmed
    termination keeps the marker so workspace reuse and cleanup fail closed.
  - Positive completion: exit status 0 is not success without an explicit eligible
    finish reason ("stop"), a completion event, clean JSONL, and confirmed termination.
  - Clean lifecycle: stdin EOF is delivered to OpenCode without closing the containment stop pipe, and stop is idempotent.
  """

  require Logger

  alias SymphonyElixir.LaunchMarker
  alias SymphonyElixir.OpenCode.{Config, Environment, Failure, Parser}
  alias SymphonyElixir.OpenCode.{Redactor, StdioHost}
  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.WorkerContainment

  @default_timeout_ms 60_000
  @stop_table :symphony_opencode_stop_latch

  @type session :: %{
          port: port(),
          identity: map() | nil,
          workspace: Path.t(),
          dirs: map(),
          executable: String.t(),
          provider: String.t(),
          model: String.t(),
          launch_id: String.t(),
          stderr_path: Path.t(),
          parser: %Parser.State{}
        }

  @type run_result :: %{
          optional(:failure_info) => map(),
          optional(:termination) => map() | nil,
          optional(:exit_code) => integer() | nil,
          optional(:stderr) => String.t(),
          optional(:finish_reason) => String.t() | nil,
          optional(:tool_failures) => [term()],
          required(:session_id) => String.t() | nil,
          required(:message_ids) => [String.t()],
          required(:tool_events) => [map()],
          required(:completion_state) => atom(),
          required(:usage) => map(),
          required(:failure_evidence) => [term()]
        }

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

        case await_completion(session, timeout_ms, opts) do
          {:exit, status, parser} ->
            termination = stop_session(session)
            conclude(session, parser, status, termination)

          {:timeout, parser} ->
            termination = stop_session(session)
            timeout_result(session, parser, termination, Keyword.get(opts, :on_event))
        end
      after
        stop_session(session)
      end
    end
  end

  @doc """
  Starts an OpenCode process session.
  Validates model/provider selection, refuses launches without a supported
  credential for the selected provider (before any launch artifact exists),
  prepares isolated environment, writes deny-by-default config, records the
  durable launch marker, and opens the contained Port.
  """
  @spec start_session(Path.t(), String.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, prompt, opts \\ []) do
    launch_id =
      Keyword.get(opts, :launch_id) ||
        "#{System.system_time(:millisecond)}-#{:erlang.unique_integer([:positive])}"

    with :ok <- validate_host_eligibility(opts),
         {:ok, {provider, model}} <- validate_model_selection(opts),
         :ok <- Environment.preflight_provider_credentials(provider, opts),
         {:ok, canonical_workspace} <- validate_workspace(workspace),
         {:ok, executable} <- resolve_executable(opts),
         {:ok, dirs} <- Environment.prepare_directories(canonical_workspace, launch_id),
         {:ok, _config_file} <- Config.write_config(dirs, opts),
         {:ok, port_env} <- Environment.build_port_env(provider, dirs, opts),
         {:ok, host} <- StdioHost.ensure_built() do
      worker_host = Keyword.get(opts, :worker_host)
      contained? = WorkerContainment.contained_launch?(worker_host)

      identity =
        if contained? do
          WorkerContainment.new_identity(
            issue_id: Keyword.get(opts, :issue_id),
            attempt_id: Keyword.get(opts, :attempt_id),
            workspace: canonical_workspace,
            worker_host: nil,
            authority_root: Keyword.get(opts, :authority_root),
            # M1-D: the durable marker names the harness that owns the launch
            # so reuse/cleanup/audit paths can distinguish an OpenCode launch
            # from a Codex launch without inferring it from the executable.
            harness: :opencode
          )
        else
          nil
        end

      stderr_path = Path.join(dirs.tmp, "stderr.log")
      opencode_args = build_opencode_args(provider, model, canonical_workspace, prompt, opts)
      port_args = ["--stderr", stderr_path, "--", executable | opencode_args]

      # M1-G1: the durable launch marker must be on disk BEFORE the worker
      # becomes materially active — no contained OpenCode launch may start
      # unless its fenceable identity is already recoverable after a BEAM
      # restart. A marker write failure for an issue-keyed launch refuses
      # the launch (fail closed).
      with :ok <- record_launch_marker(identity, opts),
           {:ok, port} <- start_port(canonical_workspace, host, port_args, port_env, identity) do
        identity = attach_wrapper_pid(identity, port)
        record_launch_wrapper_identity(identity)

        session = %{
          port: port,
          identity: identity,
          workspace: canonical_workspace,
          dirs: dirs,
          executable: executable,
          provider: provider,
          model: model,
          launch_id: launch_id,
          stderr_path: stderr_path,
          parser: Parser.new()
        }

        {:ok, session}
      else
        {:error, reason} ->
          # Pre-port failure (helper resolution or Port.open itself): no
          # process was ever created, so the pre-launch marker is cleared on
          # conclusive never-spawned evidence instead of stranding the issue
          # behind an eternally-unprovable fence.
          clear_launch_marker(identity)

          {:error, reason}
      end
    end
  end

  @doc """
  Stops an active OpenCode session and collects positive termination confirmation.
  Repeated calls return the first confirmation and do not issue a second kill.
  """
  @spec stop_session(session()) :: map()
  def stop_session(%{port: port, identity: identity, launch_id: launch_id}) do
    table = ensure_stop_table()

    case :ets.insert_new(table, {launch_id, :pending}) do
      true ->
        confirmation = safe_stop(port, identity)
        maybe_clear_confirmed_launch_marker(identity, confirmation)
        :ets.insert(table, {launch_id, confirmation})
        confirmation

      false ->
        cached_stop(table, launch_id)
    end
  end

  def stop_session(_), do: %{status: :NOT_APPLICABLE}

  defp await_completion(session, timeout_ms, opts) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    on_event = Keyword.get(opts, :on_event)
    loop_stream(session.port, session.parser, deadline, on_event)
  end

  defp loop_stream(port, parser, deadline, on_event) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        chunk = normalize_chunk(data)
        updated_parser = Parser.feed(parser, chunk)
        dispatch_events(parser, updated_parser, on_event)

        loop_stream(port, updated_parser, deadline, on_event)

      {^port, {:exit_status, status}} ->
        {:exit, status, finish_and_dispatch(parser, status, on_event)}
    after
      remaining_ms ->
        {:timeout, parser}
    end
  end

  # Delivery contract: every decoded JSONL line reaches :on_event exactly once,
  # in parse order — oldest-first within each chunk, so the observer stream is
  # chronological regardless of how the OS segments the pipe. Duplicate events
  # are delivered per occurrence and deduplication stays the consumer's policy.
  # Events finalized by Parser.finish from the trailing buffer (a final line
  # without newline) are dispatched at both finish sites, so the callback
  # stream never loses the terminal event the run result still reports.
  defp dispatch_events(before_parser, after_parser, on_event) do
    if is_function(on_event, 1) do
      for event <- Parser.events_between(before_parser, after_parser) do
        on_event.(event)
      end
    end
  end

  defp finish_and_dispatch(parser, status, on_event) do
    final_parser = Parser.finish(parser, status)
    dispatch_events(parser, final_parser, on_event)
    final_parser
  end

  defp conclude(session, parser, status, termination) do
    result = assembled_result(session, parser, status, termination)

    cond do
      success?(parser, status, termination, session.identity) ->
        {:ok, result}

      terminal_protocol_complete?(parser, status) and not termination_ok?(session.identity, termination) ->
        {:error, {:termination_unconfirmed, result}}

      true ->
        reason = find_primary_failure_reason(parser, status)
        {:error, {reason, Map.put(result, :failure_info, Failure.failure_info(reason))}}
    end
  end

  defp timeout_result(session, parser, termination, on_event) do
    # M1-INT-F timeout fusion: the parser's timeout status is always the
    # explicit :timeout atom — never nil — so downstream completion semantics
    # (SEM/TERM) can distinguish a timed-out stream from a silent one.
    final_parser = finish_and_dispatch(parser, :timeout, on_event)
    result = assembled_result(session, final_parser, 253, termination)
    failure_info = Failure.failure_info(:timeout)
    {:error, {:timeout, Map.put(result, :failure_info, failure_info)}}
  end

  defp assembled_result(session, parser, exit_code, termination) do
    parser
    |> Parser.to_result()
    |> Map.put(:termination, termination)
    |> Map.put(:exit_code, exit_code)
    |> Map.put(:stderr, read_stderr(session))
    |> Redactor.redact()
  end

  defp success?(parser, status, termination, identity) do
    status == 0 and
      eligible_protocol_completion?(parser) and
      parser.failure_evidence == [] and
      parser.tool_failures == [] and
      termination_ok?(identity, termination)
  end

  defp eligible_protocol_completion?(parser) do
    parser.completion_state == :completed and
      Parser.eligible_finish_reason?(parser.finish_reason)
  end

  defp terminal_protocol_complete?(parser, 0) do
    parser.completion_state == :completed and
      Parser.eligible_finish_reason?(parser.finish_reason) and
      parser.failure_evidence == [] and
      parser.tool_failures == []
  end

  defp terminal_protocol_complete?(_parser, _status), do: false

  defp termination_ok?(nil, %{status: :NOT_APPLICABLE}), do: true
  defp termination_ok?(identity, %{status: :TERMINATED_CONFIRMED}) when is_map(identity), do: true
  defp termination_ok?(_identity, _termination), do: false

  defp read_stderr(%{stderr_path: path}) when is_binary(path) do
    case File.read(path) do
      {:ok, text} -> text
      _ -> ""
    end
  end

  defp read_stderr(_session), do: ""

  defp find_primary_failure_reason(parser, status) do
    fatal_reason =
      Enum.find(parser.failure_evidence, fn
        {:process_exit, _} -> false
        _ -> true
      end)

    cond do
      not is_nil(fatal_reason) ->
        fatal_reason

      parser.tool_failures != [] ->
        List.first(parser.tool_failures)

      # M1-TERM-F: terminal-but-ineligible finish reasons (unknown, other,
      # length, content-filter) must surface as an explicit terminal-reason
      # failure rather than falling through to a misleading {:process_exit, 0}.
      terminal_ineligible_finish_reason?(parser.finish_reason) ->
        {:terminal_reason, parser.finish_reason}

      status != 0 ->
        {:process_exit, status}

      true ->
        List.first(parser.failure_evidence) || {:process_exit, status}
    end
  end

  defp terminal_ineligible_finish_reason?(reason) do
    is_binary(reason) and
      Parser.terminal_finish_reason?(reason) and
      not Parser.eligible_finish_reason?(reason)
  end

  defp normalize_chunk({:eol, line}), do: line <> "\n"
  defp normalize_chunk({:noeol, line}), do: line
  defp normalize_chunk(binary) when is_binary(binary), do: binary
  defp normalize_chunk(other), do: to_string(other)

  defp start_port(workspace, executable, child_args, env, nil) do
    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
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

  defp attach_wrapper_pid(nil, _port), do: nil

  defp attach_wrapper_pid(identity, port) when is_map(identity) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} -> Map.put(identity, "wrapper_pid", to_string(os_pid))
      _ -> identity
    end
  end

  # M1-G1 LaunchMarker lifecycle, mirroring the Codex AppServer contract: the
  # marker is issue-keyed because every orchestrator reuse/cleanup decision is
  # issue-keyed. A contained OpenCode launch that cannot name its issue can
  # never be fenced at those decision points; direct API use without an issue
  # keeps legacy behavior with a visible warning. A marker write failure for a
  # keyed launch refuses the launch (fail closed). Mutation-root pinning: the
  # marker is written into the store under the launch's authority root
  # (`:root`), so a later `workspace.root` reload can never strand the fence's
  # memory in a store the gates no longer read.
  defp record_launch_marker(nil, _opts), do: :ok

  defp record_launch_marker(identity, opts) when is_map(identity) do
    case Map.get(identity, "issue_id") do
      issue_id when is_binary(issue_id) and issue_id != "" ->
        LaunchMarker.record(identity,
          identifier: Keyword.get(opts, :identifier),
          attempt_id: Keyword.get(opts, :attempt_id),
          root: Keyword.get(opts, :authority_root)
        )

      _unkeyed ->
        Logger.warning("Contained OpenCode launch without an issue id cannot be fenced by a launch marker; proceeding unfenced")

        :ok
    end
  end

  defp record_launch_wrapper_identity(nil), do: :ok

  defp record_launch_wrapper_identity(identity),
    do: LaunchMarker.record_wrapper_identity(identity, launch_marker_identity_opts(identity))

  defp clear_launch_marker(nil), do: :ok

  defp clear_launch_marker(identity),
    do: LaunchMarker.clear(identity, launch_marker_identity_opts(identity))

  # The marker store root carried by the launch's own identity: the
  # authority root recorded at creation. Identity-derived operations (wrapper
  # identity refresh, confirmed clear, never-spawned clear) mutate exactly
  # the store the launch was fenced with.
  defp launch_marker_identity_opts(%{"authority_root" => root}) when is_binary(root) and root != "",
    do: [root: root]

  defp launch_marker_identity_opts(_identity), do: []

  # Marker clearing is fence-accepted-only: TERMINATED_CONFIRMED means the
  # wrapper receipt durably proves the tree drained, so the marker cannot be
  # deleted while a worker may still be alive. Any other status keeps the
  # marker as evidence for the resume/cleanup gates.
  defp maybe_clear_confirmed_launch_marker(%{"issue_id" => _issue_id} = identity, %{status: :TERMINATED_CONFIRMED}) do
    LaunchMarker.clear(identity, launch_marker_identity_opts(identity))
  end

  defp maybe_clear_confirmed_launch_marker(_identity, _confirmation), do: :ok

  defp safe_stop(port, identity) do
    if is_map(identity) and is_port(port) do
      WorkerContainment.stop_and_confirm(port, identity, WorkerContainment.grace_ms())
    else
      close_port(port)
      %{status: :NOT_APPLICABLE}
    end
  end

  defp close_port(port) do
    if is_port(port) do
      try do
        Port.close(port)
      rescue
        _ -> :ok
      end
    end

    :ok
  end

  defp ensure_stop_table do
    case :ets.whereis(@stop_table) do
      :undefined ->
        try do
          :ets.new(@stop_table, [:named_table, :public, :set])
        rescue
          ArgumentError -> @stop_table
        end

      table ->
        table
    end
  end

  defp cached_stop(table, launch_id) do
    deadline = System.monotonic_time(:millisecond) + 15_000
    wait_for_cached_stop(table, launch_id, deadline)
  end

  defp wait_for_cached_stop(table, launch_id, deadline) do
    case :ets.lookup(table, launch_id) do
      [{^launch_id, confirmation}] when confirmation != :pending ->
        confirmation

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          %{
            status: :TERMINATION_UNCONFIRMED,
            receipt: nil,
            exit_code: nil,
            reason: :duplicate_stop_unresolved
          }
        else
          Process.sleep(20)
          wait_for_cached_stop(table, launch_id, deadline)
        end
    end
  end

  @doc """
  Validates explicit provider/model selection.
  Requires either \`model: "provider/model_name"\` or explicit \`provider: "..."\` and \`model: "..."\`.
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
            {:error, {:invalid_model_selection, "Model must be specified as 'provider/model'. Automatic fallback is forbidden."}}
        end

      true ->
        {:error, :invalid_model_selection}
    end
  end

  @doc """
  Builds CLI arguments vector for non-interactive OpenCode execution.
  The prompt is placed after \`--\` so values such as \`--auto\` are not parsed as options.
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

    args_with_title ++ ["--", prompt]
  end

  @doc """
  Resolves the OpenCode executable path.
  Prioritizes explicit \`executable\` in opts, then the
  \`:opencode_executable\` app env override (explicit test/tool seam, mirroring
  \`:jobrun_helper_path\`), then looks for \`opencode.exe\` on Windows
  or \`opencode\` in PATH.
  """
  @spec resolve_executable(keyword()) :: {:ok, String.t()} | {:error, term()}
  def resolve_executable(opts \\ []) do
    case Keyword.get(opts, :executable) || Application.get_env(:symphony_elixir, :opencode_executable) do
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

  # M1-H-F host eligibility: this adapter executes OpenCode only through the
  # local containment path, and a non-nil worker_host means the orchestrator
  # selected a remote SSH host for this launch. Running the child locally
  # instead would escape Job containment (contained_launch?/1 is false for
  # every remote host) while the orchestrator accounts for a remote slot, so
  # the launch is refused before any directory, config, marker, or process
  # exists. Only nil (local) is eligible.
  defp validate_host_eligibility(opts) do
    case Keyword.get(opts, :worker_host) do
      nil -> :ok
      worker_host -> {:error, {:opencode_remote_host_ineligible, worker_host}}
    end
  end
end
