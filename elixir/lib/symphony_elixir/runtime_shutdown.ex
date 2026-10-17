defmodule SymphonyElixir.RuntimeShutdown do
  @moduledoc """
  Guarded graceful shutdown for a running Symphony runtime.

  A normal runtime termination already releases the runtime authority: an
  application stop terminates the supervision tree through supervision and
  then releases the lease (`SymphonyElixir.Application.stop/1` ->
  `RuntimeLease.release_held/1`). What that path never had is a supported
  trigger. The foreground runtime entry points only blocked on the supervisor,
  and every console exit, window close, or forced process termination bypasses
  the application stop entirely — the durable lease was left on disk and every
  restart needed explicit operator recovery. This module is that trigger,
  guarded so it can only ever release authority this instance provably still
  owns.

  The stop contract, in order:

  1. Preconditions — all fail-closed, nothing is mutated while one fails:
     - a live holder holds runtime authority (`RuntimeLease.authoritative?/1`);
     - the durable lease file still belongs to this runtime instance
       (`RuntimeLease.holds_authority_for?/1`, re-read from disk, so a
       successor's lease refuses the stop);
     - the worker-drain requirement holds: the Orchestrator snapshot reports
       no `running` workers. A snapshot that cannot be obtained while the
       runtime supervisor is still up is a refused stop — an unverifiable
       drain is not a drained drain.
  2. Supervised termination — the application is stopped. The supervision
     tree terminates through supervision first, and only then does the
     application stop callback release the lease. That release is
     owner-token-checked inside `RuntimeLease.release/2`: a lease that
     stopped belonging to this instance between the preconditions and the
     release is refused and left intact — a shutdown path can never delete a
     successor's lease.
  3. Verified outcome — the durable lease is re-read after the stop. Success
     is reported only when the lease is verifiably gone; a lease that
     survived the stop (a successor's, or a recovery racing the stop) is
     reported, never smoothed over.

  Stale and foreign leases are never released here. Recovery after a crash or
  a forced termination stays explicit operator recovery
  (`RuntimeLease.force_release/2`).

  ## Stop requests

  `wait_for_shutdown/1` is the foreground wait used by the runtime entry
  points (`mix symphony.pilot_bootstrap`, `SymphonyElixir.CLI`). It blocks on
  the runtime supervisor as before and additionally polls the durable stop
  request file `<state_root>/.symphony-state/runtime/stop.request`. A request
  is honored only when it is valid and names this exact runtime instance
  (`instance_id` is minted once per BEAM boot and is visible in
  `RuntimeLease.status/0`, `GET /api/v1/state`, and the runtime log). A
  request naming another instance — stale residue or a wrong target — is
  ignored, logged once, and never consumed. `request/3` writes an attributable
  request against the current lease holder; `mix symphony.stop_request` wraps
  it for operators.

  A valid request is consumed (removed) before the guarded stop runs: a
  refused stop (for example a worker still running) can never re-trigger, and
  a leftover request can never auto-stop a later runtime instance, whose
  instance id cannot match. After a refused stop the operator clears the
  blocker and re-requests.
  """

  require Logger

  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.RuntimeLease

  @schema_version 1
  @stop_request_kind "runtime-stop-request"
  @stop_request_filename "stop.request"
  @default_poll_ms 1_000
  @snapshot_timeout_ms 15_000

  @type request :: %{
          required(:instance_id) => String.t(),
          required(:reason) => String.t(),
          required(:requested_by) => String.t(),
          optional(:requested_at) => String.t() | nil
        }

  @type stop_error ::
          :no_runtime_authority
          | :not_authority_holder
          | {:workers_still_running, [String.t() | nil]}
          | {:drain_unverifiable, :orchestrator_unavailable | :orchestrator_timeout}
          | {:stop_application_failed, term()}
          | {:lease_not_released, map()}

  @doc """
  Guarded graceful stop: verify authority and drain, terminate the application
  through supervision, release the lease, verify the release.

  Fails closed with a tagged reason and without stopping anything when a
  precondition fails, and reports `{:error, {:lease_not_released, evidence}}`
  when the tree is down but the durable lease survived (a successor's lease, or
  a recovery racing the stop — operator recovery decides, never this path).
  """
  @spec stop(keyword()) :: :ok | {:error, stop_error()}
  def stop(opts \\ []) do
    with {:ok, root} <- ready_root(opts),
         :ok <- stop_application(opts) do
      verify_released(root, opts)
    end
  end

  @doc """
  Read-only dry run of the stop preconditions: authority held by this
  instance, and the worker-drain requirement satisfied. Never mutates
  anything.
  """
  @spec check_ready(keyword()) :: :ok | {:error, stop_error()}
  def check_ready(opts \\ []) do
    case ready_root(opts) do
      {:ok, _root} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # The authority preconditions and the drain requirement. Returns the pinned
  # authority root on success so the post-stop verification reads the same
  # root the preconditions proved, even though the holder is gone by then.
  defp ready_root(opts) do
    lease = lease_module(opts)
    holder = holder(opts)

    if lease.authoritative?(holder) do
      with {:ok, root} <- lease.authority_root(holder) do
        if lease.holds_authority_for?(root) do
          case drained?(opts) do
            :ok -> {:ok, root}
            {:error, reason} -> {:error, reason}
          end
        else
          {:error, :not_authority_holder}
        end
      end
    else
      {:error, :no_runtime_authority}
    end
  end

  # Worker-drain requirement: a stop may only proceed when no dispatched
  # worker is still running. A snapshot is answered only between orchestrator
  # messages, so an answered snapshot with an empty running map means no
  # worker is alive and no poll cycle was mid-flight. A snapshot that cannot
  # be obtained while the runtime supervisor is still up is refused; with the
  # supervisor already gone the tree cannot hold workers and the stop may
  # finish (it then releases, or honestly reports the lease residue).
  defp drained?(opts) do
    case snapshot_fun(opts).() do
      %{running: []} ->
        :ok

      %{running: running} ->
        {:error, {:workers_still_running, Enum.map(running, &Map.get(&1, :identifier))}}

      :unavailable ->
        drain_unverifiable(opts, :orchestrator_unavailable)

      :timeout ->
        drain_unverifiable(opts, :orchestrator_timeout)
    end
  end

  defp drain_unverifiable(opts, reason) do
    supervisor = Keyword.get(opts, :supervisor, SymphonyElixir.Supervisor)

    if Process.whereis(supervisor) do
      {:error, {:drain_unverifiable, reason}}
    else
      :ok
    end
  end

  defp stop_application(opts) do
    case application_stop_fun(opts).() do
      # Already terminating or stopped (a concurrent application stop): the
      # post-stop verification decides the outcome either way.
      :ok -> :ok
      {:error, {:not_started, :symphony_elixir}} -> :ok
      {:error, reason} -> {:error, {:stop_application_failed, reason}}
    end
  end

  defp verify_released(root, opts) do
    case lease_module(opts).observe(root) do
      {:error, :not_found} ->
        Logger.info("Runtime shutdown completed state_root=#{root} runtime_authority=released")
        :ok

      {:ok, evidence} ->
        Logger.warning(
          "Runtime shutdown left the runtime authority in place state_root=#{root} " <>
            "instance_id=#{Map.get(evidence, "instance_id")} — not released by this stop; " <>
            "operator recovery decides"
        )

        {:error, {:lease_not_released, evidence}}

      {:error, reason} ->
        Logger.warning("Runtime shutdown could not verify the lease removal state_root=#{root} reason=#{inspect(reason)}")

        {:error, {:lease_not_released, %{"verify_error" => inspect(reason)}}}
    end
  end

  @doc """
  Writes an attributable stop request against the runtime instance that
  currently holds the authority lease for `state_root`.

  Fails closed — nothing written — when `reason` or `requested_by` is blank
  (the same attribution discipline as `RuntimeLease.force_release/2`), when no
  lease exists at the state root, when the lease cannot be read, or when a
  request naming a DIFFERENT instance is already pending. A conflicting
  request is surfaced with its path, never silently replaced: it is either
  another runtime's operator intent or stale residue an operator removes
  explicitly. Re-writing a request for the same instance updates it in place.
  """
  @spec request(String.t(), String.t(), keyword()) ::
          {:ok, request()}
          | {:error, :reason_required}
          | {:error, :requested_by_required}
          | {:error, :no_runtime_lease}
          | {:error, {:lease_unreadable, term()}}
          | {:error, {:stale_stop_request_present, %{path: String.t(), instance_id: String.t()}}}
          | {:error, {:stop_request_write_failed, term()}}
  def request(state_root, reason, opts \\ []) when is_binary(state_root) and is_binary(reason) do
    requested_by = Keyword.get(opts, :requested_by, "") || ""
    trimmed_reason = String.trim(reason)
    trimmed_by = String.trim(requested_by)

    cond do
      trimmed_reason == "" ->
        {:error, :reason_required}

      trimmed_by == "" ->
        {:error, :requested_by_required}

      true ->
        with {:ok, evidence} <- observe_lease(state_root, opts),
             :ok <- refuse_conflicting_request(state_root, evidence) do
          write_request(state_root, evidence["instance_id"], trimmed_reason, trimmed_by)
        end
    end
  end

  @doc """
  The durable stop request file for `state_root`.
  """
  @spec stop_request_path(String.t()) :: String.t()
  def stop_request_path(state_root) when is_binary(state_root) do
    Path.join(RuntimeLease.authority_dir(state_root), @stop_request_filename)
  end

  @doc """
  Validates one raw stop request file against `expected_instance_id`.

  A request is valid only when it parses, carries the stop-request kind and
  schema version, names exactly `expected_instance_id`, and carries non-blank
  `reason` and `requested_by`. Every other shape — including a foreign or
  stale instance id — is a tagged error; the caller ignores and preserves such
  a file.
  """
  @spec parse_stop_request(binary(), String.t()) ::
          {:ok, request()} | {:error, {:invalid_stop_request, atom()}}
  def parse_stop_request(raw, expected_instance_id)
      when is_binary(raw) and is_binary(expected_instance_id) do
    with {:ok, map} <- decode_request(raw),
         :ok <- validate_request(map, expected_instance_id) do
      {:ok,
       %{
         instance_id: map["instance_id"],
         reason: map["reason"],
         requested_by: map["requested_by"],
         requested_at: Map.get(map, "requested_at")
       }}
    end
  end

  defp decode_request(raw) do
    case Jason.decode(raw) do
      {:ok, %{} = map} -> {:ok, map}
      {:error, _} -> {:error, {:invalid_stop_request, :corrupt_json}}
    end
  end

  defp validate_request(map, expected_instance_id) do
    cond do
      map["kind"] != @stop_request_kind ->
        {:error, {:invalid_stop_request, :unknown_kind}}

      map["schema_version"] != @schema_version ->
        {:error, {:invalid_stop_request, :schema_version_invalid}}

      not is_binary(map["instance_id"]) or map["instance_id"] == "" ->
        {:error, {:invalid_stop_request, :instance_id_missing}}

      map["instance_id"] != expected_instance_id ->
        {:error, {:invalid_stop_request, :instance_mismatch}}

      not nonempty_binary?(map["reason"]) ->
        {:error, {:invalid_stop_request, :reason_required}}

      not nonempty_binary?(map["requested_by"]) ->
        {:error, {:invalid_stop_request, :requested_by_required}}

      true ->
        :ok
    end
  end

  @doc """
  Foreground runtime wait: blocks until the runtime supervisor is down, and
  polls the durable stop request file so a valid, exact-instance request
  triggers the guarded graceful stop. Returns `:ok` for a clean shutdown
  (supervised stop or graceful stop), `{:error, {:supervisor_exited, reason}}`
  when the supervisor exited abnormally, and `{:error, :supervisor_not_running}`
  when there is nothing to wait for.
  """
  @spec wait_for_shutdown(keyword()) ::
          :ok | {:error, :supervisor_not_running | {:supervisor_exited, term()}}
  def wait_for_shutdown(opts \\ []) do
    supervisor = Keyword.get(opts, :supervisor, SymphonyElixir.Supervisor)

    case Process.whereis(supervisor) do
      nil ->
        {:error, :supervisor_not_running}

      pid ->
        state = %{
          pid: pid,
          ref: Process.monitor(pid),
          poll_ms: Keyword.get(opts, :poll_ms, @default_poll_ms),
          opts: opts,
          last_seen: :none
        }

        wait_loop(state)
    end
  end

  defp wait_loop(%{pid: pid, ref: ref} = state) do
    receive do
      # :shutdown is what an application master uses when it stops the top
      # supervisor during an application stop — a clean supervised shutdown.
      {:DOWN, ^ref, :process, ^pid, reason} when reason in [:normal, :shutdown] -> :ok
      {:DOWN, ^ref, :process, ^pid, reason} -> {:error, {:supervisor_exited, reason}}
    after
      state.poll_ms ->
        last_seen = consider_stop_request(state)
        wait_loop(%{state | last_seen: last_seen})
    end
  end

  # One stop-request poll. `last_seen` keys the logging so an unchanged
  # invalid or foreign file is logged once, not once per poll. Only a valid,
  # exact-instance request is consumed (removed) and executed; everything else
  # is preserved untouched for its owner.
  defp consider_stop_request(state) do
    with {:ok, root} <- authority_root(state.opts),
         path = stop_request_path(root),
         {:ok, raw} <- File.read(path) do
      if raw == state.last_seen do
        raw
      else
        case honor_stop_request(path, raw, state.opts) do
          :ok -> raw
          :ignored -> raw
          {:error, reason} -> log_refused_request(path, reason)
        end
      end
    else
      _ -> :none
    end
  end

  # Consume-then-execute: the request is removed before the guarded stop, so a
  # refused stop can never re-trigger on the next poll and a leftover request
  # can never match a later instance (instance ids are minted once per BEAM
  # boot).
  defp honor_stop_request(path, raw, opts) do
    with {:ok, request} <- parse_stop_request(raw, lease_module(opts).instance_id()) do
      case File.rm(path) do
        :ok ->
          Logger.info(
            "Runtime stop request accepted instance_id=#{request.instance_id} " <>
              "requested_by=#{inspect(request.requested_by)} reason=#{inspect(request.reason)}"
          )

          case stop(opts) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.warning("Runtime stop request not executed reason=#{inspect(reason)}; still waiting")
              {:error, reason}
          end

        {:error, :enoent} ->
          # Already consumed by an earlier accept, or removed by hand.
          :ok

        {:error, reason} ->
          {:error, {:stop_request_unremovable, reason}}
      end
    else
      {:error, {:invalid_stop_request, invalid}} ->
        case invalid do
          :instance_mismatch ->
            Logger.warning("Ignoring runtime stop request for another instance path=#{path}")

          _ ->
            Logger.warning("Ignoring invalid runtime stop request path=#{path} reason=#{inspect(invalid)}")
        end

        :ignored
    end
  end

  defp log_refused_request(path, reason) do
    Logger.warning("Runtime stop request not executed path=#{path} reason=#{inspect(reason)}")
    :error
  end

  defp observe_lease(state_root, opts) do
    case lease_module(opts).observe(state_root) do
      {:ok, evidence} -> {:ok, evidence}
      {:error, :not_found} -> {:error, :no_runtime_lease}
      {:error, reason} -> {:error, {:lease_unreadable, reason}}
    end
  end

  defp refuse_conflicting_request(state_root, evidence) do
    path = stop_request_path(state_root)

    case existing_request_instance(path) do
      {:ok, other} ->
        if is_binary(other) and other != evidence["instance_id"] do
          {:error, {:stale_stop_request_present, %{path: path, instance_id: other}}}
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  defp existing_request_instance(path) do
    case File.read(path) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, %{"instance_id" => instance_id}} -> {:ok, instance_id}
          _ -> :error
        end

      {:error, _} ->
        :error
    end
  end

  defp write_request(state_root, instance_id, reason, requested_by) do
    body = %{
      "schema_version" => @schema_version,
      "kind" => @stop_request_kind,
      "instance_id" => instance_id,
      "reason" => reason,
      "requested_by" => requested_by,
      "requested_at" => now_iso()
    }

    path = stop_request_path(state_root)
    File.mkdir_p(Path.dirname(path))

    case File.write(path, Jason.encode!(body, pretty: true)) do
      :ok ->
        Logger.info(
          "Runtime stop request written path=#{path} instance_id=#{instance_id} " <>
            "requested_by=#{inspect(requested_by)}"
        )

        {:ok, body}

      {:error, write_reason} ->
        {:error, {:stop_request_write_failed, write_reason}}
    end
  end

  defp authority_root(opts) do
    lease_module(opts).authority_root(holder(opts))
  end

  defp lease_module(opts), do: Keyword.get(opts, :lease, RuntimeLease)
  defp holder(opts), do: Keyword.get(opts, :holder, RuntimeLease)

  defp snapshot_fun(opts) do
    Keyword.get(opts, :snapshot, fn ->
      Orchestrator.snapshot(Keyword.get(opts, :orchestrator, Orchestrator), @snapshot_timeout_ms)
    end)
  end

  defp application_stop_fun(opts) do
    Keyword.get(opts, :application_stop, fn -> Application.stop(:symphony_elixir) end)
  end

  defp nonempty_binary?(value), do: is_binary(value) and String.trim(value) != ""

  defp now_iso, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
