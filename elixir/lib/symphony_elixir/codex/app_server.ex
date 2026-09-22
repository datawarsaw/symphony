defmodule SymphonyElixir.Codex.AppServer do
  @moduledoc """
  Minimal client for the Codex app-server JSON-RPC 2.0 stream over stdio.
  """

  require Logger
  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Codex.WorkerEnvironment
  alias SymphonyElixir.Codex.WorkerRouting
  alias SymphonyElixir.Config
  alias SymphonyElixir.LaunchMarker
  alias SymphonyElixir.DispatchRouter
  alias SymphonyElixir.Discovery.Session
  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.SSH
  alias SymphonyElixir.Steering
  alias SymphonyElixir.WorkerContainment

  @initialize_id 1
  @thread_start_id 2
  @turn_start_id 3
  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000
  @type session :: %{
          optional(:model) => String.t() | nil,
          optional(:reasoning_effort) => String.t() | nil,
          optional(:model_source) => atom() | nil,
          optional(:reasoning_source) => atom() | nil,
          optional(:route_source) => atom() | nil,
          optional(:discovery_route) => map() | nil,
          optional(:steering) => map() | nil,
          port: port(),
          metadata: map(),
          approval_policy: String.t() | map(),
          auto_approve_requests: boolean(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map(),
          thread_id: String.t(),
          workspace: Path.t(),
          worker_host: String.t() | nil,
          dynamic_tool_binding: map()
        }

  # MIC-223: contained sessions additionally carry `worker_identity` (string-keyed,
  # RetryStore-persistable). Kept off the informal type above because the type mixes
  # keyword shorthand.

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        confirmation = stop_session(session)
        publish_session_termination(Keyword.get(opts, :worker_termination_publisher), session, confirmation)
        maybe_warn_unconfirmed(issue, confirmation)
      end
    end
  end

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    termination_publisher = Keyword.get(opts, :worker_termination_publisher)
    dynamic_tool_binding = DynamicTool.bind()
    discovery_route = Keyword.get(opts, :discovery_route)
    dynamic_tool_binding = if discovery_route, do: Map.put(dynamic_tool_binding, :tool_specs, []), else: dynamic_tool_binding
    issue = Keyword.get(opts, :issue)
    worker_identity = new_worker_identity(workspace, issue, opts, worker_host)

    # Hardening slice: the durable launch marker must be on disk BEFORE the
    # worker becomes materially active — no worker may start unless its
    # fenceable identity is already recoverable after a BEAM restart. A
    # failed marker write refuses the launch (fail closed).
    with :ok <- record_launch_marker(worker_identity, issue, opts),
         {:ok, worker_route} <- worker_route_for(opts, issue, discovery_route),
         {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host, Keyword.get(opts, :authority_root)),
         {:ok, port} <- start_port(expanded_workspace, worker_host, dynamic_tool_binding, worker_identity) do
      metadata = port_metadata(port, worker_host)
      worker_identity = attach_wrapper_pid(worker_identity, port)
      record_launch_wrapper_identity(worker_identity)

      with {:ok, session_policies} <- session_policies(expanded_workspace, worker_host, discovery_route),
           {:ok, thread_id, evidence} <-
             do_start_session(port, expanded_workspace, session_policies, dynamic_tool_binding, discovery_route, worker_route) do
        session_metadata = Map.merge(metadata, evidence)

        {:ok,
         %{
           port: port,
           metadata: session_metadata,
           approval_policy: session_policies.approval_policy,
           auto_approve_requests: is_nil(discovery_route) and session_policies.approval_policy == "never",
           thread_sandbox: session_policies.thread_sandbox,
           turn_sandbox_policy: session_policies.turn_sandbox_policy,
           thread_id: thread_id,
           workspace: expanded_workspace,
           worker_host: worker_host,
           dynamic_tool_binding: dynamic_tool_binding,
           steering: steering_context(opts, worker_host),
           discovery_route: discovery_route,
           worker_identity: worker_identity,
           model: evidence[:model],
           reasoning_effort: evidence[:reasoning_effort],
           model_source: evidence[:model_source],
           reasoning_source: evidence[:reasoning_source],
           route_source: evidence[:route_source]
         }}
      else
        {:error, reason} ->
          # MIC-223 partial-start seam: the port was created, so a managed
          # process may have entered execution. stop_and_confirm already ran;
          # publishing its discarded confirmation through the same
          # :worker_termination message the shutdown path uses keeps the reuse
          # gate from falling back to legacy nil semantics on evidence the
          # runtime provably holds.
          confirmation = stop_and_confirm_session_port(port, worker_identity)

          maybe_clear_confirmed_launch_marker(worker_identity, confirmation)

          publish_worker_termination(termination_publisher, %{
            worker_identity: worker_identity,
            worker_termination: confirmation,
            termination_expectation: WorkerContainment.termination_expectation(worker_host)
          })

          {:error, reason}
      end
    else
      {:error, reason} ->
        # Pre-port failure (routing, cwd validation, or Port.open itself):
        # no process was ever created, so the pre-launch marker is cleared on
        # conclusive never-spawned evidence instead of bricking the issue with
        # an eternally-unprovable marker.
        clear_launch_marker(worker_identity)

        {:error, reason}
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          port: port,
          metadata: metadata,
          approval_policy: approval_policy,
          auto_approve_requests: auto_approve_requests,
          turn_sandbox_policy: turn_sandbox_policy,
          thread_id: thread_id,
          workspace: workspace,
          dynamic_tool_binding: dynamic_tool_binding
        } = app_session,
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    tool_executor = session_tool_executor(app_session, opts, dynamic_tool_binding, issue)

    case start_turn(port, thread_id, prompt, issue, workspace, approval_policy, turn_sandbox_policy) do
      {:ok, turn_id} ->
        session_id = "#{thread_id}-#{turn_id}"

        Logger.info(
          "Codex session started for #{issue_context(issue)} session_id=#{session_id} model=#{app_session[:model]} reasoning_effort=#{app_session[:reasoning_effort]} route_source=#{app_session[:route_source]}"
        )

        emit_message(
          on_message,
          :session_started,
          %{
            session_id: session_id,
            thread_id: thread_id,
            turn_id: turn_id,
            model: app_session[:model],
            reasoning_effort: app_session[:reasoning_effort],
            model_source: app_session[:model_source],
            reasoning_source: app_session[:reasoning_source],
            route_source: app_session[:route_source]
          },
          metadata
        )

        case await_turn_completion(port, on_message, tool_executor, auto_approve_requests) do
          {:ok, result} ->
            Logger.info("Codex session completed for #{issue_context(issue)} session_id=#{session_id}")

            {:ok,
             %{
               result: result,
               session_id: session_id,
               thread_id: thread_id,
               turn_id: turn_id,
               model: app_session[:model],
               reasoning_effort: app_session[:reasoning_effort],
               model_source: app_session[:model_source],
               reasoning_source: app_session[:reasoning_source],
               route_source: app_session[:route_source]
             }}

          {:error, reason} ->
            Logger.warning("Codex session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

            emit_message(
              on_message,
              :turn_ended_with_error,
              %{
                session_id: session_id,
                reason: reason
              },
              metadata
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Codex session failed for #{issue_context(issue)}: #{inspect(reason)}")
        emit_message(on_message, :startup_failed, %{reason: reason}, metadata)
        {:error, reason}
    end
  end

  defp session_tool_executor(%{discovery_route: route}, _opts, _binding, _issue) when not is_nil(route) do
    fn _, _ -> %{"success" => false, "output" => "Discovery tool execution denied"} end
  end

  defp session_tool_executor(session, opts, binding, issue) do
    default_executor =
      Keyword.get(opts, :tool_executor, fn tool, arguments ->
        DynamicTool.execute(tool, arguments, binding, issue: issue)
      end)

    fn tool, arguments ->
      case tool do
        # MIC-10 deterministic steering acknowledgement: a named tool call
        # validated against the session's steering identity. Worker prose is
        # never parsed.
        "symphony_steer_ack" -> Steering.ack_tool_response(session[:steering], session[:thread_id], arguments)
        _ -> default_executor.(tool, arguments)
      end
    end
  end

  defp steering_context(opts, worker_host) do
    workspace_root = Keyword.get(opts, :workspace_root)
    issue = Keyword.get(opts, :issue)

    if is_binary(workspace_root) and workspace_root != "" and match?(%SymphonyElixir.Tracker.Issue{}, issue) do
      %{
        workspace_root: workspace_root,
        issue_id: issue.id,
        attempt_id: Steering.normalize_attempt(Keyword.get(opts, :attempt)),
        worker_host: worker_host
      }
    else
      nil
    end
  end

  @doc """
  Stops the worker session and returns a termination confirmation.

  MIC-223: on a contained local Windows launch, `Port.close` is only a stop
  request. The returned confirmation is `:TERMINATED_CONFIRMED` only when the
  jobrun receipt positively proves the process tree drained; otherwise it is
  `:TERMINATION_UNCONFIRMED` and callers must not reuse or clean the
  workspace. Non-contained launches (remote, non-Windows, disabled) return
  `:NOT_APPLICABLE` after the legacy port close.
  """
  @spec stop_session(session()) :: WorkerContainment.confirmation()
  def stop_session(%{port: port} = session) when is_port(port) do
    case Map.get(session, :worker_identity) do
      nil ->
        stop_port(port)
        %{status: :NOT_APPLICABLE}

      identity ->
        confirmation = WorkerContainment.stop_and_confirm(port, identity, WorkerContainment.grace_ms())

        # Successful-completion semantics: the marker is cleared only once
        # termination evidence is durable (the wrapper receipt) and accepted
        # by the same fence logic — never while a worker might still be alive.
        maybe_clear_confirmed_launch_marker(identity, confirmation)

        confirmation
    end
  end

  @doc """
  Exposes structured protocol/transport failure information for a Codex
  session error without owning retry policy.

  Only surfaces provider reset timing when the runtime reliably provides it
  (explicit numeric reset/retry-after fields); otherwise returns nil.
  """
  @spec failure_info({:error, term()} | term()) :: map()
  def failure_info({:error, reason}), do: describe_reason(reason)
  def failure_info(reason), do: describe_reason(reason)

  @spec describe_reason(term()) :: map()
  defp describe_reason({kind, payload}) when is_atom(kind) and is_map(payload) do
    %{
      kind: kind,
      message: extract_message(payload),
      http_status: extract_http_status(payload),
      reset_after_ms: extract_reset_after_ms(payload),
      raw: %{kind: kind, payload: payload}
    }
  end

  defp describe_reason({kind, detail}) when is_atom(kind) do
    %{kind: kind, message: inspect(detail), http_status: nil, reset_after_ms: nil, raw: detail}
  end

  defp describe_reason(reason) when is_atom(reason) do
    %{kind: reason, message: Atom.to_string(reason), http_status: nil, reset_after_ms: nil, raw: reason}
  end

  defp describe_reason(reason) when is_binary(reason) do
    %{kind: :unknown, message: reason, http_status: nil, reset_after_ms: nil, raw: reason}
  end

  defp describe_reason(reason) do
    %{kind: :unknown, message: inspect(reason), http_status: nil, reset_after_ms: nil, raw: reason}
  end

  @spec extract_message(map()) :: String.t()
  defp extract_message(payload) do
    cond do
      is_binary(Map.get(payload, "message")) -> Map.get(payload, "message")
      is_binary(Map.get(payload, "error")) -> inspect(Map.get(payload, "error"))
      is_binary(Map.get(payload, :message)) -> Map.get(payload, :message)
      true -> inspect(payload)
    end
  end

  @spec extract_http_status(map()) :: pos_integer() | nil
  defp extract_http_status(%{"status" => status}) when is_integer(status) and status > 0, do: status
  defp extract_http_status(%{status: status}) when is_integer(status) and status > 0, do: status
  defp extract_http_status(%{"http_status" => status}) when is_integer(status) and status > 0, do: status
  defp extract_http_status(_payload), do: nil

  @spec extract_reset_after_ms(map()) :: non_neg_integer() | nil
  defp extract_reset_after_ms(%{"reset_after_ms" => ms}) when is_integer(ms) and ms >= 0, do: ms
  defp extract_reset_after_ms(%{reset_after_ms: ms}) when is_integer(ms) and ms >= 0, do: ms
  defp extract_reset_after_ms(%{"retry_after_ms" => ms}) when is_integer(ms) and ms >= 0, do: ms
  defp extract_reset_after_ms(%{retry_after_ms: ms}) when is_integer(ms) and ms >= 0, do: ms
  defp extract_reset_after_ms(_payload), do: nil

  # MIC-223: the stop confirmation of a fully started session is evidence too.
  # Discovery launches through this entry point, and without publication its
  # reuse decisions would fall back to legacy nil semantics even though the
  # session was managed and stopped.
  defp publish_session_termination(publisher, session, confirmation) do
    publish_worker_termination(publisher, %{
      worker_identity: Map.get(session, :worker_identity),
      worker_termination: confirmation
    })
  end

  defp publish_worker_termination(publisher, info) when is_function(publisher, 1) do
    publisher.(info)
    :ok
  end

  defp publish_worker_termination(_publisher, _info), do: :ok

  defp validate_workspace_cwd(workspace, nil, local_root) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)

    # Local launch containment: the workspace must sit inside the runtime's
    # mutation root — the boot-pinned authority root when one is supplied,
    # otherwise the configured root (direct API use). Validating against a
    # moved live root would reject pinned workspaces after a `workspace.root`
    # reload.
    expanded_root =
      case local_root do
        root when is_binary(root) and root != "" -> Path.expand(root)
        _ -> Config.local_workspace_root()
      end

    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host, _local_root)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  # Contained local Windows launch (MIC-223): the port runs the jobrun Job
  # Object wrapper, which receives the shell as its own absolute-path child.
  # The wrapper inherits the port's cd/env policy, so workspace, environment,
  # secret removal, line mode and stdio behavior are unchanged. A missing or
  # unverified helper fails the launch visibly instead of silently falling
  # back to an unprotected spawn.
  defp start_port(workspace, nil, dynamic_tool_binding, identity) when not is_nil(identity) do
    with {:ok, jobrun} <- WorkerContainment.helper_path(),
         {:ok, executable} <- SymphonyElixir.Codex.LocalShell.resolve(Config.settings!().codex.shell_executable),
         {:ok, worker_environment} <- WorkerEnvironment.prepare(workspace) do
      port =
        Port.open(
          {:spawn_executable, jobrun_charlist(jobrun)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args:
              WorkerContainment.launch_args(identity, executable, [
                ~c"-lc",
                String.to_charlist(local_launch_command(dynamic_tool_binding, worker_environment))
              ]),
            cd: String.to_charlist(workspace),
            env: worker_environment ++ tracker_secret_port_env(dynamic_tool_binding),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  rescue
    error -> {:error, {:local_shell_start_failed, Exception.message(error)}}
  end

  # Legacy launch: remote workers, non-Windows hosts, and containment disabled
  # keep the historical direct shell spawn (behaviorally unchanged).
  defp start_port(workspace, nil, dynamic_tool_binding, nil) do
    with {:ok, executable} <- SymphonyElixir.Codex.LocalShell.resolve(Config.settings!().codex.shell_executable),
         {:ok, worker_environment} <- WorkerEnvironment.prepare(workspace) do
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(local_launch_command(dynamic_tool_binding, worker_environment))],
            cd: String.to_charlist(workspace),
            env: worker_environment ++ tracker_secret_port_env(dynamic_tool_binding),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  rescue
    error -> {:error, {:local_shell_start_failed, Exception.message(error)}}
  end

  defp start_port(workspace, worker_host, dynamic_tool_binding, _identity) when is_binary(worker_host) do
    remote_command = remote_launch_command(workspace, dynamic_tool_binding)
    SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

  defp jobrun_charlist(jobrun) when is_binary(jobrun), do: String.to_charlist(jobrun)

  # MIC-223 worker identity exists only for contained local Windows launches;
  # the decision is the canonical WorkerContainment.contained_launch? predicate
  # shared with the orchestrator's pre-launch termination expectation.
  defp new_worker_identity(workspace, issue, opts, worker_host) do
    if WorkerContainment.contained_launch?(worker_host) do
      WorkerContainment.new_identity(
        issue_id: issue && Map.get(issue, :id),
        attempt_id: Keyword.get(opts, :attempt_id),
        workspace: workspace,
        worker_host: nil,
        # Mutation-root pinning: the boot-pinned authority root this launch is
        # fenced under. Resolves the termination-receipt directory and rides
        # inside the identity so every identity-derived marker operation stays
        # in the same mutation domain as the launch itself.
        authority_root: Keyword.get(opts, :authority_root)
      )
    else
      nil
    end
  end

  # Hardening slice: the launch marker is keyed by issue because every
  # orchestrator reuse/cleanup decision is issue-keyed, and every production
  # launch (AgentRunner, Discovery) carries its issue. A contained launch that
  # cannot name its issue can never be fenced at those decision points; direct
  # API use without an issue keeps legacy behavior with a visible warning.
  # A marker write failure for a keyed launch refuses it (fail closed).
  # Mutation-root pinning: the marker is written into the store under the
  # boot-pinned authority root (`:root`), so a later `workspace.root` reload
  # can never strand the fence's memory in a store the gates no longer read.
  defp record_launch_marker(nil, _issue, _opts), do: :ok

  defp record_launch_marker(identity, issue, opts) do
    case issue && Map.get(issue, :id) do
      issue_id when is_binary(issue_id) and issue_id != "" ->
        LaunchMarker.record(identity,
          identifier: issue && Map.get(issue, :identifier),
          attempt_id: Keyword.get(opts, :attempt_id) || Keyword.get(opts, :attempt),
          root: Keyword.get(opts, :authority_root)
        )

      _unkeyed ->
        Logger.warning("Contained launch without an issue id cannot be fenced by a launch marker; proceeding unfenced")

        :ok
    end
  end

  defp record_launch_wrapper_identity(nil), do: :ok

  defp record_launch_wrapper_identity(identity),
    do: LaunchMarker.record_wrapper_identity(identity, launch_marker_identity_opts(identity))

  defp clear_launch_marker(nil), do: :ok
  defp clear_launch_marker(identity), do: LaunchMarker.clear(identity, launch_marker_identity_opts(identity))

  # The marker store root carried by the launch's own identity: the boot-pinned
  # authority root recorded at creation. Identity-derived operations (wrapper
  # identity refresh, confirmed clear, never-spawned clear) mutate exactly the
  # store the launch was fenced with.
  defp launch_marker_identity_opts(%{"authority_root" => root}) when is_binary(root) and root != "", do: [root: root]
  defp launch_marker_identity_opts(_identity), do: []

  # Marker clearing is fence-accepted-only: TERMINATED_CONFIRMED means the
  # wrapper receipt durably proves the tree drained, so the marker cannot be
  # deleted while a worker may still be alive. Any other status keeps the
  # marker as evidence for the resume/cleanup gates.
  defp maybe_clear_confirmed_launch_marker(%{"issue_id" => _issue_id} = identity, %{status: :TERMINATED_CONFIRMED}) do
    LaunchMarker.clear(identity, launch_marker_identity_opts(identity))
  end

  defp maybe_clear_confirmed_launch_marker(_identity, _confirmation), do: :ok

  defp attach_wrapper_pid(nil, _port), do: nil

  defp attach_wrapper_pid(identity, port) when is_map(identity) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} -> Map.put(identity, "wrapper_pid", to_string(os_pid))
      _ -> identity
    end
  end

  defp stop_and_confirm_session_port(port, nil) when is_port(port) do
    stop_port(port)
    %{status: :NOT_APPLICABLE}
  end

  defp stop_and_confirm_session_port(port, identity) when is_port(port) and is_map(identity) do
    confirmation = WorkerContainment.stop_and_confirm(port, identity, WorkerContainment.grace_ms())
    maybe_warn_unconfirmed(nil, confirmation)
    confirmation
  end

  defp maybe_warn_unconfirmed(issue, %{status: :TERMINATION_UNCONFIRMED} = confirmation) do
    issue_context =
      case issue do
        %{id: issue_id, identifier: identifier} -> "issue_id=#{issue_id} issue_identifier=#{identifier}"
        _ -> "issue_unknown"
      end

    Logger.error("Worker termination UNCONFIRMED for #{issue_context}; workspace reuse/cleanup must fail closed confirmation=#{inspect(confirmation)}")
  end

  defp maybe_warn_unconfirmed(_issue, _confirmation), do: :ok

  defp local_launch_command(dynamic_tool_binding, worker_environment) do
    [
      worker_environment_export_command(worker_environment),
      tracker_secret_unset_command(dynamic_tool_binding),
      "exec #{Config.settings!().codex.command}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  # Applied after Bash profile loading so a host profile cannot point the worker
  # back at ambient build, dependency or temporary directories.
  defp worker_environment_export_command([]), do: nil

  defp worker_environment_export_command(worker_environment) do
    "export " <>
      Enum.map_join(worker_environment, " ", fn {name, value} ->
        "#{name}=#{shell_escape(to_string(value))}"
      end)
  end

  defp remote_launch_command(workspace, dynamic_tool_binding) when is_binary(workspace) do
    [
      "cd #{shell_escape(workspace)}",
      tracker_secret_unset_command(dynamic_tool_binding),
      "exec #{Config.settings!().codex.command}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  defp tracker_secret_port_env(dynamic_tool_binding) do
    dynamic_tool_binding.secret_environment_names
    |> valid_environment_names()
    |> Enum.map(fn name -> {String.to_charlist(name), false} end)
  end

  defp tracker_secret_unset_command(dynamic_tool_binding) do
    case dynamic_tool_binding.secret_environment_names |> valid_environment_names() do
      [] -> nil
      names -> "unset " <> Enum.join(names, " ")
    end
  end

  defp valid_environment_names(names) do
    Enum.filter(names, fn name ->
      is_binary(name) and String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)
    end)
  end

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} ->
          %{codex_app_server_pid: to_string(os_pid)}

        _ ->
          %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp send_initialize(port) do
    payload = %{
      "method" => "initialize",
      "id" => @initialize_id,
      "params" => %{
        "capabilities" => %{
          "experimentalApi" => true
        },
        "clientInfo" => %{
          "name" => "symphony-orchestrator",
          "title" => "Symphony Orchestrator",
          "version" => "0.1.0"
        }
      }
    }

    send_message(port, payload)

    with {:ok, _} <- await_response(port, @initialize_id) do
      send_message(port, %{"method" => "initialized", "params" => %{}})
      :ok
    end
  end

  defp session_policies(workspace, nil) do
    Config.codex_runtime_settings(workspace)
  end

  defp session_policies(workspace, worker_host) when is_binary(worker_host) do
    Config.codex_runtime_settings(workspace, remote: true)
  end

  defp do_start_session(port, workspace, session_policies, dynamic_tool_binding, discovery_route, worker_route) do
    with :ok <- send_initialize(port),
         {:ok, overrides} <- route_overrides(port, workspace, discovery_route, worker_route) do
      start_thread(port, workspace, session_policies, dynamic_tool_binding, overrides, discovery_route, worker_route)
    end
  end

  defp route_overrides(port, workspace, route, _worker_route) when not is_nil(route) do
    discovery_overrides(port, workspace, route)
  end

  defp route_overrides(_port, _workspace, nil, worker_route) do
    {:ok, WorkerRouting.thread_overrides(worker_route)}
  end

  # Discovery routes resolve through Discovery.Session; implementation workers
  # use the selection materialized by DispatchRouter at dispatch time, and fall
  # back to WorkerRouting resolution for callers that predate the seam.
  #
  # MIC-195 Slice C precondition (C0 review finding): the PRESENCE of the
  # :dispatch_selection key is meaningful, so its three states are handled
  # explicitly — absent → legacy WorkerRouting resolution; a valid Selection →
  # consumed as-is; present but invalid → fail closed. A leaked fallback
  # materialization error tuple (or any malformed selection) must never be
  # silently re-resolved into a primary session.
  defp worker_route_for(_opts, _issue, discovery_route) when not is_nil(discovery_route), do: {:ok, nil}

  defp worker_route_for(opts, issue, nil) do
    case Keyword.fetch(opts, :dispatch_selection) do
      {:ok, %DispatchRouter.Selection{} = selection} ->
        {:ok, DispatchRouter.worker_route(selection)}

      {:ok, invalid} ->
        {:error, {:invalid_dispatch_selection, invalid}}

      :error ->
        {:ok, WorkerRouting.resolve(opts, issue)}
    end
  end

  defp discovery_overrides(port, workspace, route) do
    send_message(port, %{"method" => "config/read", "id" => 4, "params" => %{"cwd" => workspace, "includeLayers" => false}})

    case await_response(port, 4) do
      {:ok, %{"config" => config}} -> Session.thread_overrides(config, route)
      _ -> {:error, :discovery_config_unavailable}
    end
  end

  defp session_policies(workspace, worker_host, nil), do: session_policies(workspace, worker_host)

  defp session_policies(_workspace, _worker_host, _route) do
    {:ok, %{approval_policy: "never", thread_sandbox: "read-only", turn_sandbox_policy: %{"type" => "readOnly"}}}
  end

  defp start_thread(
         port,
         workspace,
         %{approval_policy: approval_policy, thread_sandbox: thread_sandbox},
         dynamic_tool_binding,
         overrides,
         discovery_route,
         worker_route
       ) do
    send_message(port, %{
      "method" => "thread/start",
      "id" => @thread_start_id,
      "params" =>
        Map.merge(
          %{
            "approvalPolicy" => approval_policy,
            "sandbox" => thread_sandbox,
            "cwd" => workspace,
            "dynamicTools" => dynamic_tool_binding.tool_specs
          },
          overrides
        )
    })

    case await_response(port, @thread_start_id) do
      {:ok, %{"thread" => thread_payload} = response} ->
        cond do
          not is_nil(discovery_route) ->
            if discovery_selection_valid?(response, overrides) do
              case thread_identifier(thread_payload) do
                {:ok, thread_id} ->
                  evidence = %{
                    model: discovery_route.model,
                    reasoning_effort: discovery_route.reasoning,
                    model_source: :discovery,
                    reasoning_source: :discovery,
                    route_source: :discovery
                  }

                  {:ok, thread_id, evidence}

                other ->
                  other
              end
            else
              {:error, :discovery_model_selection_unverified}
            end

          true ->
            with {:ok, selection} <- WorkerRouting.validate_selection(response, worker_route),
                 {:ok, thread_id} <- thread_identifier(thread_payload) do
              evidence =
                Map.merge(selection, %{
                  model_source: worker_route.model_source,
                  reasoning_source: worker_route.reasoning_source,
                  route_source: worker_route.route_source
                })

              {:ok, thread_id, evidence}
            end
        end

      other ->
        other
    end
  end

  defp discovery_selection_valid?(response, %{"model" => model}) do
    response["model"] == model and response["approvalPolicy"] == "never" and
      match?(%{"type" => "readOnly"}, response["sandbox"]) and response["sandbox"]["networkAccess"] != true
  end

  defp discovery_selection_valid?(_response, _overrides), do: true

  defp thread_identifier(%{"id" => thread_id}), do: {:ok, thread_id}
  defp thread_identifier(payload), do: {:error, {:invalid_thread_payload, payload}}

  defp start_turn(port, thread_id, prompt, issue, workspace, approval_policy, turn_sandbox_policy) do
    send_message(port, %{
      "method" => "turn/start",
      "id" => @turn_start_id,
      "params" => %{
        "threadId" => thread_id,
        "input" => [
          %{
            "type" => "text",
            "text" => prompt
          }
        ],
        "cwd" => workspace,
        "title" => "#{issue.identifier}: #{issue.title}",
        "approvalPolicy" => approval_policy,
        "sandboxPolicy" => turn_sandbox_policy
      }
    })

    case await_response(port, @turn_start_id) do
      {:ok, %{"turn" => %{"id" => turn_id}}} -> {:ok, turn_id}
      other -> other
    end
  end

  defp await_turn_completion(port, on_message, tool_executor, auto_approve_requests) do
    receive_loop(
      port,
      on_message,
      Config.settings!().codex.turn_timeout_ms,
      "",
      tool_executor,
      auto_approve_requests
    )
  end

  defp receive_loop(port, on_message, timeout_ms, pending_line, tool_executor, auto_approve_requests) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_incoming(port, on_message, complete_line, timeout_ms, tool_executor, auto_approve_requests)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(
          port,
          on_message,
          timeout_ms,
          pending_line <> to_string(chunk),
          tool_executor,
          auto_approve_requests
        )

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp handle_incoming(port, on_message, data, timeout_ms, tool_executor, auto_approve_requests) do
    payload_string = to_string(data)

    case Jason.decode(payload_string) do
      {:ok, %{"method" => "turn/completed"} = payload} ->
        emit_turn_event(on_message, :turn_completed, payload, payload_string, port, payload)
        {:ok, :turn_completed}

      {:ok, %{"method" => "turn/failed", "params" => _} = payload} ->
        emit_turn_event(
          on_message,
          :turn_failed,
          payload,
          payload_string,
          port,
          Map.get(payload, "params")
        )

        {:error, {:turn_failed, Map.get(payload, "params")}}

      {:ok, %{"method" => "turn/cancelled", "params" => _} = payload} ->
        emit_turn_event(
          on_message,
          :turn_cancelled,
          payload,
          payload_string,
          port,
          Map.get(payload, "params")
        )

        {:error, {:turn_cancelled, Map.get(payload, "params")}}

      {:ok, %{"method" => method} = payload}
      when is_binary(method) ->
        handle_turn_method(
          port,
          on_message,
          payload,
          payload_string,
          method,
          timeout_ms,
          tool_executor,
          auto_approve_requests
        )

      {:ok, payload} ->
        emit_message(
          on_message,
          :other_message,
          %{
            payload: payload,
            raw: payload_string
          },
          metadata_from_message(port, payload)
        )

        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)

      {:error, _reason} ->
        log_non_json_stream_line(payload_string, "turn stream")

        if protocol_message_candidate?(payload_string) do
          emit_message(
            on_message,
            :malformed,
            %{
              payload: payload_string,
              raw: payload_string
            },
            metadata_from_message(port, %{raw: payload_string})
          )
        end

        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)
    end
  end

  defp emit_turn_event(on_message, event, payload, payload_string, port, payload_details) do
    emit_message(
      on_message,
      event,
      %{
        payload: payload,
        raw: payload_string,
        details: payload_details
      },
      metadata_from_message(port, payload)
    )
  end

  defp handle_turn_method(
         port,
         on_message,
         payload,
         payload_string,
         method,
         timeout_ms,
         tool_executor,
         auto_approve_requests
       ) do
    metadata = metadata_from_message(port, payload)

    case maybe_handle_approval_request(
           port,
           method,
           payload,
           payload_string,
           on_message,
           metadata,
           tool_executor,
           auto_approve_requests
         ) do
      :input_required ->
        emit_message(
          on_message,
          :turn_input_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:turn_input_required, payload}}

      :approved ->
        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)

      :approval_required ->
        emit_message(
          on_message,
          :approval_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:approval_required, payload}}

      :unhandled ->
        if needs_input?(method, payload) do
          emit_message(
            on_message,
            :turn_input_required,
            %{payload: payload, raw: payload_string},
            metadata
          )

          {:error, {:turn_input_required, payload}}
        else
          emit_message(
            on_message,
            :notification,
            %{
              payload: payload,
              raw: payload_string
            },
            metadata
          )

          Logger.debug("Codex notification: #{inspect(method)}")
          receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)
        end
    end
  end

  defp maybe_handle_approval_request(
         port,
         "item/commandExecution/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/call",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         tool_executor,
         _auto_approve_requests
       ) do
    tool_name = tool_call_name(params)
    arguments = tool_call_arguments(params)

    result =
      tool_name
      |> tool_executor.(arguments)
      |> normalize_dynamic_tool_result()

    send_message(port, %{
      "id" => id,
      "result" => result
    })

    event =
      case result do
        %{"success" => true} -> :tool_call_completed
        _ when is_nil(tool_name) -> :unsupported_tool_call
        _ -> :tool_call_failed
      end

    emit_message(on_message, event, %{payload: payload, raw: payload_string}, metadata)

    :approved
  end

  defp maybe_handle_approval_request(
         port,
         "execCommandApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "applyPatchApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/fileChange/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/requestUserInput",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    maybe_auto_answer_tool_request_user_input(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         _port,
         _method,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         _tool_executor,
         _auto_approve_requests
       ) do
    :unhandled
  end

  defp normalize_dynamic_tool_result(%{"success" => success} = result) when is_boolean(success) do
    output =
      case Map.get(result, "output") do
        existing_output when is_binary(existing_output) -> existing_output
        _ -> dynamic_tool_output(result)
      end

    content_items =
      case Map.get(result, "contentItems") do
        existing_items when is_list(existing_items) -> existing_items
        _ -> dynamic_tool_content_items(output)
      end

    result
    |> Map.put("output", output)
    |> Map.put("contentItems", content_items)
  end

  defp normalize_dynamic_tool_result(result) do
    %{
      "success" => false,
      "output" => inspect(result),
      "contentItems" => dynamic_tool_content_items(inspect(result))
    }
  end

  defp dynamic_tool_output(%{"contentItems" => [%{"text" => text} | _]}) when is_binary(text), do: text
  defp dynamic_tool_output(result), do: Jason.encode!(result, pretty: true)

  defp dynamic_tool_content_items(output) when is_binary(output) do
    [
      %{
        "type" => "inputText",
        "text" => output
      }
    ]
  end

  defp approve_or_require(
         port,
         id,
         decision,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    send_message(port, %{"id" => id, "result" => %{"decision" => decision}})

    emit_message(
      on_message,
      :approval_auto_approved,
      %{payload: payload, raw: payload_string, decision: decision},
      metadata
    )

    :approved
  end

  defp approve_or_require(
         _port,
         _id,
         _decision,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         false
       ) do
    :approval_required
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    case tool_request_user_input_approval_answers(params) do
      {:ok, answers, decision} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :approval_auto_approved,
          %{payload: payload, raw: payload_string, decision: decision},
          metadata
        )

        :approved

      :error ->
        :input_required
    end
  end

  defp maybe_auto_answer_tool_request_user_input(
         _port,
         _id,
         _params,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         false
       ),
       do: :input_required

  defp tool_request_user_input_approval_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_approval_answer(question) do
          {:ok, question_id, answer_label} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [answer_label]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map, "Approve this Session"}
      _ -> :error
    end
  end

  defp tool_request_user_input_approval_answers(_params), do: :error

  defp tool_request_user_input_approval_answer(%{"id" => question_id, "options" => options})
       when is_binary(question_id) and is_list(options) do
    if String.starts_with?(question_id, "mcp_tool_call_approval_") do
      case tool_request_user_input_approval_option_label(options) do
        nil -> :error
        answer_label -> {:ok, question_id, answer_label}
      end
    else
      :error
    end
  end

  defp tool_request_user_input_approval_answer(_question), do: :error

  defp tool_request_user_input_approval_option_label(options) do
    options
    |> Enum.map(&tool_request_user_input_option_label/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      labels ->
        Enum.find(labels, &(&1 == "Approve this Session")) ||
          Enum.find(labels, &(&1 == "Approve Once")) ||
          Enum.find(labels, &approval_option_label?/1)
    end
  end

  defp tool_request_user_input_option_label(%{"label" => label}) when is_binary(label), do: label
  defp tool_request_user_input_option_label(_option), do: nil

  defp approval_option_label?(label) when is_binary(label) do
    normalized_label =
      label
      |> String.trim()
      |> String.downcase()

    String.starts_with?(normalized_label, "approve") or String.starts_with?(normalized_label, "allow")
  end

  defp await_response(port, request_id) do
    with_timeout_response(port, request_id, Config.settings!().codex.read_timeout_ms, "")
  end

  defp with_timeout_response(port, request_id, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_response(port, request_id, complete_line, timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        with_timeout_response(port, request_id, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :response_timeout}
    end
  end

  defp handle_response(port, request_id, data, timeout_ms) do
    payload = to_string(data)

    case Jason.decode(payload) do
      {:ok, %{"id" => ^request_id, "error" => error}} ->
        {:error, {:response_error, error}}

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^request_id} = response_payload} ->
        {:error, {:response_error, response_payload}}

      {:ok, %{} = other} ->
        Logger.debug("Ignoring message while waiting for response: #{inspect(other)}")
        with_timeout_response(port, request_id, timeout_ms, "")

      {:error, _} ->
        log_non_json_stream_line(payload, "response stream")
        with_timeout_response(port, request_id, timeout_ms, "")
    end
  end

  defp log_non_json_stream_line(data, stream_label) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Codex #{stream_label} output: #{text}")
      else
        Logger.debug("Codex #{stream_label} output: #{text}")
      end
    end
  end

  defp protocol_message_candidate?(data) do
    data
    |> to_string()
    |> String.trim_leading()
    |> String.starts_with?("{")
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError ->
            :ok
        end
    end
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp metadata_from_message(port, payload) do
    port |> port_metadata(nil) |> maybe_set_usage(payload)
  end

  defp maybe_set_usage(metadata, payload) when is_map(payload) do
    usage = Map.get(payload, "usage") || Map.get(payload, :usage)

    if is_map(usage) do
      Map.put(metadata, :usage, usage)
    else
      metadata
    end
  end

  defp maybe_set_usage(metadata, _payload), do: metadata

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp default_on_message(_message), do: :ok

  defp tool_call_name(params) when is_map(params) do
    case Map.get(params, "tool") || Map.get(params, :tool) || Map.get(params, "name") || Map.get(params, :name) do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp tool_call_name(_params), do: nil

  defp tool_call_arguments(params) when is_map(params) do
    Map.get(params, "arguments") || Map.get(params, :arguments) || %{}
  end

  defp tool_call_arguments(_params), do: %{}

  defp send_message(port, message) do
    line = Jason.encode!(message) <> "\n"
    Port.command(port, line)
  end

  defp needs_input?("mcpServer/elicitation/request", payload) when is_map(payload), do: true

  defp needs_input?(method, payload)
       when is_binary(method) and is_map(payload) do
    String.starts_with?(method, "turn/") && input_required_method?(method, payload)
  end

  defp needs_input?(_method, _payload), do: false

  defp input_required_method?(method, payload) when is_binary(method) do
    method in [
      "turn/input_required",
      "turn/needs_input",
      "turn/need_input",
      "turn/request_input",
      "turn/request_response",
      "turn/provide_input",
      "turn/approval_required"
    ] || request_payload_requires_input?(payload)
  end

  defp request_payload_requires_input?(payload) do
    params = Map.get(payload, "params")
    needs_input_field?(payload) || needs_input_field?(params)
  end

  defp needs_input_field?(payload) when is_map(payload) do
    Map.get(payload, "requiresInput") == true or
      Map.get(payload, "needsInput") == true or
      Map.get(payload, "input_required") == true or
      Map.get(payload, "inputRequired") == true or
      Map.get(payload, "type") == "input_required" or
      Map.get(payload, "type") == "needs_input"
  end

  defp needs_input_field?(_payload), do: false
end
