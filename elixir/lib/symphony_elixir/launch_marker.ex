defmodule SymphonyElixir.LaunchMarker do
  @moduledoc """
  Durable launch marker: one small record per issue naming the worker launch
  that last owned the issue's workspace, plus the resume/cleanup fence over
  that record.

  MIC-223 proved worker death on failure/retry paths through termination
  receipts, but a healthy first-attempt worker had no durable launch
  identity: after a BEAM crash + fast runtime restart, the workspace was
  classified resumable and a second worker could be dispatched before the
  old job tree drained. The marker closes that gap without a new lifecycle
  subsystem — it is one JSON file per issue answering exactly one question:

  > which worker launch last owned this issue/workspace, and has its death
  > been positively proven?

  Central invariant:

  ```
  A workspace must never be reused or destructively cleaned
  while a previous worker that owned it may still be alive.
  ```

  Lifecycle:

  - Written by `AppServer.start_session` BEFORE `Port.open` — no worker may
    become active unless its fenceable identity is already recoverable after
    a BEAM restart.
  - Replaced by every subsequent launch of the same issue.
  - Cleared only after termination evidence is durable and accepted by the
    same fence logic (`TERMINATED_CONFIRMED` receipts), so the marker can
    never vanish while a worker may still be alive.
  - A launch that conclusively never spawned a process (`Port.open` never
    succeeded) clears the marker on that `:never_spawned` evidence.

  Verdicts come from `SymphonyElixir.WorkerFence` (termination receipts);
  death is never inferred from a missing BEAM process, a missing task,
  elapsed time, workspace presence, or the runtime restart itself. LIVE and
  UNKNOWN fail closed.

  State-file conventions mirror `SymphonyElixir.RetryStore`: one JSON file
  per issue under `<workspace_root>/.symphony-state/launches/`, atomic
  tmp+rename writes, string-keyed maps, `schema_version` gate on read.

  Mutation-root pinning: the marker store is lifecycle mutation state — the
  durable memory of the reuse/cleanup fences. Runtime-driven callers pass the
  boot-pinned authority root via the `:root` option, so a hot-reloaded
  `workspace.root` can never move the store out from under an unproven marker
  (that would fail the gates open). The `:launch_marker_root` app env keeps its
  explicit-override meaning; absent both, configuration resolves the store
  root live, exactly as before pinning existed.
  """

  require Logger

  alias SymphonyElixir.{Config, RetryStore, WorkerFence}

  @schema_version 1

  @type marker :: map()
  # Mirrors WorkerContainment.reuse_gate/2's verdict shape: the single
  # allowed/blocked idiom across reuse and cleanup decisions.
  @type gate_verdict :: :allowed | {:blocked, atom()}

  # ---------------------------------------------------------------------------
  # Storage
  # ---------------------------------------------------------------------------

  @doc """
  Directory holding one launch marker per issue. Mirrors the RetryStore and
  receipt-directory convention: durable state lives under
  `<workspace_root>/.symphony-state` so markers survive per-workspace
  cleanup and runtime restarts.

  Resolution order: the `:launch_marker_root` app env override (explicit
  test/tool seam), then the `:root` option (the runtime's boot-pinned
  authority root), then live configuration (direct API use).
  """
  @spec root(keyword()) :: String.t()
  def root(opts \\ []) do
    override = Application.get_env(:symphony_elixir, :launch_marker_root)

    case override do
      root when is_binary(root) and root != "" ->
        root

      _ ->
        case Keyword.get(opts, :root) do
          root when is_binary(root) and root != "" -> launches_dir(root)
          _ -> launches_dir(Config.local_workspace_root())
        end
    end
  end

  defp launches_dir(root), do: Path.join([root, ".symphony-state", "launches"])

  @spec marker_path(String.t(), keyword()) :: String.t()
  def marker_path(issue_id, opts \\ []) when is_binary(issue_id) do
    Path.join(root(opts), RetryStore.safe_issue_id(issue_id) <> ".json")
  end

  # ---------------------------------------------------------------------------
  # Write / read / clear
  # ---------------------------------------------------------------------------

  @doc """
  Builds and durably writes the pre-launch marker for a contained worker
  identity. Must complete before the worker process exists; callers must not
  launch when this returns an error (fail closed). The `:root` option pins the
  store to the runtime's authority root.
  """
  @spec record(map(), keyword()) :: :ok | {:error, term()}
  def record(identity, opts \\ []) do
    do_record(identity, opts)
  end

  defp do_record(
         %{
           "issue_id" => issue_id,
           "launch_id" => launch_id,
           "workspace" => workspace,
           "receipt_path" => receipt_path
         } = identity,
         opts
       )
       when is_binary(issue_id) and issue_id != "" and is_binary(launch_id) and launch_id != "" and
              is_binary(workspace) and workspace != "" and is_binary(receipt_path) and
              receipt_path != "" do
    marker = %{
      "schema_version" => @schema_version,
      "issue_id" => issue_id,
      "identifier" => keyword_value(opts, :identifier),
      "attempt_id" => keyword_value(opts, :attempt_id),
      "workspace" => workspace,
      "workspace_key" => Path.basename(workspace),
      "launch_id" => launch_id,
      "worker_host" => identity["worker_host"],
      "started_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "worker_identity" => identity
    }

    write(issue_id, marker, opts)
  end

  # An identity that cannot name its issue, launch, or workspace can never be
  # fenced at the reuse/cleanup decision points — refuse it instead of writing
  # a marker that reads as UNKNOWN forever.
  defp do_record(_identity, _opts), do: {:error, :launch_marker_identity_invalid}

  @doc """
  Best-effort refresh of the stored worker identity (e.g. after the wrapper
  OS pid is attached). Never fails the launch; a refresh whose launch id no
  longer matches the stored marker (replaced launch) leaves the newer marker
  untouched. The `:root` option pins the store to the runtime's authority root.
  """
  @spec record_wrapper_identity(map() | nil, keyword()) :: :ok
  def record_wrapper_identity(identity, opts \\ []) do
    do_record_wrapper_identity(identity, opts)
  end

  defp do_record_wrapper_identity(
         %{"issue_id" => issue_id, "launch_id" => launch_id} = identity,
         opts
       )
       when is_binary(issue_id) and issue_id != "" and is_binary(launch_id) do
    case read(issue_id, opts) do
      {:ok, %{"launch_id" => ^launch_id} = marker} ->
        _ = write(issue_id, Map.put(marker, "worker_identity", identity), opts)
        :ok

      _other ->
        :ok
    end
  end

  defp do_record_wrapper_identity(_other, _opts), do: :ok

  @doc """
  Reads the marker for an issue. Any structural deviation (missing file aside)
  is an error: callers treat corrupt/unreadable markers as UNKNOWN and fail
  closed — a hand-corrupted marker is never read as "no launch happened". The
  `:root` option pins the store to the runtime's authority root.
  """
  @spec read(term(), keyword()) :: {:ok, marker()} | {:error, :not_found | :corrupt | :unreadable}
  def read(issue_id, opts \\ []) do
    do_read(issue_id, opts)
  end

  defp do_read(issue_id, opts) when is_binary(issue_id) and issue_id != "" do
    case File.read(marker_path(issue_id, opts)) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, %{"schema_version" => @schema_version} = marker} -> {:ok, marker}
          {:ok, _other} -> {:error, :corrupt}
          {:error, _} -> {:error, :corrupt}
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, _} ->
        {:error, :unreadable}
    end
  end

  defp do_read(_other, _opts), do: {:error, :not_found}

  @doc """
  Stored worker identity for an issue, or nil when no readable marker exists.
  Used by paths that must carry the old launch identity into a fence decision
  (for example a CONTROL terminate whose in-memory entry never received the
  worker identity). The `:root` option pins the store to the runtime's
  authority root.
  """
  @spec stored_identity(term(), keyword()) :: map() | nil
  def stored_identity(issue_id, opts \\ []) do
    case read(issue_id, opts) do
      {:ok, marker} -> Map.get(marker, "worker_identity")
      _ -> nil
    end
  end

  @doc """
  Clears the marker. Callers clear only after termination evidence is durable
  and fence-accepted (or on conclusive never-spawned evidence), so a failed
  clear is safe: the next fence re-proves from the receipt. The `:root` option
  pins the store to the runtime's authority root.
  """
  @spec clear(term(), keyword()) :: :ok
  def clear(target, opts \\ []) do
    do_clear(target, opts)
  end

  defp do_clear(issue_id, opts) when is_binary(issue_id) and issue_id != "" do
    _ = File.rm(marker_path(issue_id, opts))
    :ok
  end

  defp do_clear(%{"issue_id" => issue_id}, opts), do: do_clear(issue_id, opts)
  defp do_clear(_other, _opts), do: :ok

  # ---------------------------------------------------------------------------
  # Fences
  # ---------------------------------------------------------------------------

  @doc """
  Resume gate: may a new worker be dispatched for this issue?

  No marker → allowed (no managed launch ever happened for this issue).
  Otherwise the stored identity's death must be positively proven through the
  `WorkerFence` (MIC-223 termination receipt). LIVE and UNKNOWN fail closed;
  a corrupt or unreadable marker fails closed. The `:root` option pins the
  store to the runtime's authority root.
  """
  @spec reuse_gate(term(), keyword()) :: gate_verdict()
  def reuse_gate(issue_id, opts \\ []) do
    do_reuse_gate(issue_id, opts)
  end

  defp do_reuse_gate(issue_id, opts) when is_binary(issue_id) and issue_id != "" do
    case read(issue_id, opts) do
      {:error, :not_found} -> :allowed
      {:error, _reason} -> {:blocked, :launch_marker_unreadable}
      {:ok, marker} -> fence_marker_identity(marker)
    end
  end

  # A dispatch that carries no issue id can never name a marker; the launch
  # itself is refused for contained workers (see AppServer), so nothing to gate.
  defp do_reuse_gate(_other, _opts), do: :allowed

  @doc """
  Cleanup gate: may this issue's workspace be destructively cleaned?

  Same evidence bar as `reuse_gate/1`: a stored marker requires positive
  `TERMINATED_CONFIRMED` proof; no marker keeps legacy behavior (no managed
  worker launch to prove). The `:root` option pins the store to the runtime's
  authority root.
  """
  @spec cleanup_gate(term(), keyword()) :: gate_verdict()
  def cleanup_gate(issue_id, opts \\ []), do: reuse_gate(issue_id, opts)

  @doc """
  Strict fence verdict over the stored marker: positive receipt proof only.
  A missing marker is UNKNOWN — never death — because this verdict is used
  inside bounded drain waits where the marker must not disappear without the
  fail-closed answer. The `:root` option pins the store to the runtime's
  authority root.
  """
  @spec fence_verdict(term(), keyword()) :: WorkerFence.verdict()
  def fence_verdict(issue_id, opts \\ []) do
    do_fence_verdict(issue_id, opts)
  end

  defp do_fence_verdict(issue_id, opts) when is_binary(issue_id) and issue_id != "" do
    case read(issue_id, opts) do
      {:ok, marker} -> WorkerFence.confirm_termination_receipt(Map.get(marker, "worker_identity"))
      {:error, _reason} -> {:error, :unknown}
    end
  end

  defp do_fence_verdict(_other, _opts), do: {:error, :unknown}

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp fence_marker_identity(marker) do
    case WorkerFence.confirm_termination_receipt(Map.get(marker, "worker_identity")) do
      {:ok, :dead} -> :allowed
      {:error, :alive} -> {:blocked, :worker_alive}
      {:error, :unknown} -> {:blocked, :worker_termination_unproven}
    end
  end

  defp keyword_value(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp keyword_value(_opts, _key), do: nil

  # Atomic write, mirroring RetryStore: temp file + rename, so a crash mid-
  # write can never surface a torn marker.
  defp write(issue_id, marker, opts) do
    path = marker_path(issue_id, opts)
    File.mkdir_p!(root(opts))

    tmp = path <> "." <> Integer.to_string(:erlang.unique_integer([:positive])) <> ".tmp"
    File.write!(tmp, Jason.encode!(marker, pretty: true))
    File.rename!(tmp, path)

    :ok
  rescue
    error ->
      Logger.error("Launch marker write failed issue_id=#{issue_id}: #{Exception.message(error)}")
      {:error, {:launch_marker_write_failed, Exception.message(error)}}
  end
end
