defmodule SymphonyElixir.RuntimeLease do
  @moduledoc """
  Durable single-instance runtime authority for one Symphony state root.

  One file under `<state_root>/.symphony-state/runtime/authority.json`. At most one
  runtime instance may hold lifecycle mutation authority (Orchestrator dispatch,
  worker spawn, cleanup, retry mutation) for a state root at any moment. The state
  root is resolved once at boot, exactly like `SymphonyElixir.Orchestrator`'s durable
  record root (`:retry_store_root` app env, else the configured local workspace root).

  What this protects: a second accidental Symphony runtime cannot become a second
  lifecycle authority over the same workspace root, `.symphony-state`, tracker
  project, workspaces, and retry records. A second startup fails closed — before the
  runtime supervisor starts — with `{:error, {:runtime_authority_held, evidence}}`.

  What this does NOT protect: processes that ignore the lease entirely, or a hostile
  writer that deletes/rewrites state files (operator `force_release/2` exists because
  file state is operator-trusted). The lease is structural against racing honest
  runtimes, not security against malice.

  Authority is held by a long-lived holder process started by `acquire_and_hold/1`
  from `SymphonyElixir.Application.start_runtime/0`, before any supervisor child
  (Orchestrator, TaskSupervisor, HTTP) exists. That acquisition is the production
  authority gate: a held or unusable root fails the whole application start, so
  the runtime tree — and therefore the Orchestrator — never comes up without
  authority through the production entry path. Entry paths that build a runtime
  tree directly (tests, tools) run without a holder and resolve roots from live
  configuration, exactly as before the lease existed; `authoritative?/0` and
  `holds_authority_for?/1` remain available to such callers as read-only
  evidence checks, and the detached cleanup watcher uses
  `holds_authority_for?/1` to refuse destructive work it can no longer prove
  authority for.

  Durability follows `SymphonyElixir.LaneLease` and `SymphonyElixir.RetryStore`:
  bounded JSON with `schema_version`, atomic temp + rename for rewrites, fail-closed
  on corrupt/ambiguous/foreign reads, and an atomic (`:exclusive`) initial create so
  two simultaneous startups produce exactly one owner and one rejection. All lease
  mutations (claim, re-adopt, renew, release, recovery) are serialized by a
  state-root op lock acquired with the same exclusive-create primitive.

  Heartbeat: the holder renews periodically. Renewal exists for operator evidence
  (liveness classification below) and to notice a broken filesystem — a renew
  failure fails closed: the holder marks the instance lost, stops the runtime
  supervisor, and terminates; the instance may never re-acquire in the same BEAM
  (`:runtime_authority_lost`). Staleness is classification only (`classify/3`) and
  never authorizes takeover: a fresh runtime refuses to start against a stale or
  corrupt lease just like against an active one.

  Recovery is `force_release/2` — explicit operator confirmation plus a written
  reason, with the prior state preserved to `authority.recovery.json` as evidence and
  the removal verified by a re-read. Recovery refuses an `:active` lease unless
  `force_active: true`; there is no time-based automatic takeover.

  Mutation-root pinning: the root the holder claims is the only lifecycle
  mutation root for as long as the holder lives. `authority_root/0` publishes it
  to the Orchestrator/Workspace/RetryStore paths; a hot-reloaded `workspace.root`
  may change configuration's desired root but can never move the physical
  mutation root — changing roots requires a runtime restart. The pinned root is
  unusable before acquisition and after authority loss (fail-closed), so the pin
  can never become an authority bypass.
  """

  use GenServer
  require Logger

  @schema_version 1
  @kind "runtime-authority"
  @default_heartbeat_ms 60 * 1_000
  @default_stale_after_seconds 15 * 60
  @default_abandoned_after_seconds 12 * 60 * 60
  @default_op_lock_timeout_ms 5_000
  @op_lock_poll_ms 5
  @authority_check_timeout_ms 5_000
  @core_fields ~w(state_root instance_id owner_token os_pid node started_at heartbeat_at)
  # Private deterministic-test seam (per-process, unset in production): override for the
  # destructive removal inside force_release/2. Deliberately not a general filesystem hook.
  @force_rm_test_hook :"$runtime_lease_force_rm_hook"

  @type lease :: map()
  @type evidence :: map()
  @type lease_class :: :active | :stale_unconfirmed | :releasable
  @type read_error ::
          {:lease_state_invalid, :corrupt_state | :ambiguous_state | :root_mismatch | :schema_invalid | :unreadable_state}

  @type t :: %__MODULE__{
          name: atom(),
          root: String.t() | nil,
          lease: lease() | nil,
          runtime_supervisor: atom() | nil,
          heartbeat_ms: pos_integer() | nil,
          last_renew_at: String.t() | nil,
          renew_error: term() | nil,
          renew_failures: non_neg_integer() | nil,
          lost?: boolean()
        }

  defstruct [
    :name,
    :root,
    :lease,
    :runtime_supervisor,
    :heartbeat_ms,
    :last_renew_at,
    :renew_error,
    :renew_failures,
    lost?: false
  ]

  # -- paths and identity --

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec authority_dir(String.t()) :: String.t()
  def authority_dir(state_root), do: Path.join([state_root, ".symphony-state", "runtime"])

  @spec authority_path(String.t()) :: String.t()
  def authority_path(state_root), do: Path.join(authority_dir(state_root), "authority.json")

  @doc """
  The runtime instance identity: a random value minted once per BEAM boot. A
  supervisor restart of the holder inside the same BEAM re-adopts its own residue;
  a fresh BEAM never does.
  """
  @spec instance_id() :: String.t()
  def instance_id do
    :persistent_term.get({__MODULE__, :instance_id}, nil) || mint_instance_id()
  end

  defp mint_instance_id do
    id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    :persistent_term.put({__MODULE__, :instance_id}, id)
    id
  end

  @doc """
  Resolves the state root the runtime authority binds: the `:retry_store_root` app
  env seam (same resolution as the Orchestrator's durable record root), else the
  configured local workspace root.
  """
  @spec state_root() :: String.t()
  def state_root do
    case resolve_configured_root() do
      {:ok, root} -> root
      {:error, {:invalid_state_root, message}} -> raise ArgumentError, message: message
    end
  end

  # -- claim / renew / release (durable operations) --

  @doc """
  Atomically claims runtime authority for `state_root`. Succeeds only if no lease
  file exists (`:exclusive` create) or the existing lease provably belongs to this
  same runtime instance (holder restart inside one BEAM — see `instance_id/0`).
  Any other lease — active, stale, or corrupt — fails closed with evidence; a stale
  heartbeat is reported but never authorizes takeover.
  """
  @spec claim(String.t(), keyword()) ::
          {:ok, lease()}
          | {:error, {:runtime_authority_held, evidence()}}
          | {:error, {:lease_state_invalid, atom()}}
          | {:error, {:lease_write_failed, term()}}
          | {:error, {:lease_unavailable, term()}}
          | {:error, {:lease_op_lock_unavailable, term()}}
  def claim(state_root, opts \\ []) when is_binary(state_root) do
    File.mkdir_p(authority_dir(state_root))

    with_op_lock(state_root, Keyword.get(opts, :lock_timeout_ms, @default_op_lock_timeout_ms), fn ->
      claim_locked(state_root, opts)
    end)
  end

  defp claim_locked(state_root, opts) do
    lease = new_lease(state_root, opts)

    case exclusive_create(authority_path(state_root), lease) do
      {:ok, created} ->
        {:ok, created}

      {:error, :eexist} ->
        readopt_or_reject(state_root)

      {:error, _reason} = failure ->
        failure
    end
  end

  # Exclusive create, the exact primitive LaneLease claims with. A Windows
  # create-race against a concurrent claimant's open handle surfaces as a sharing
  # violation (:eacces) instead of :eexist; both mean "someone is claiming right
  # now" and fail closed — never read-then-create.
  defp exclusive_create(path, lease) do
    case :file.open(path, [:raw, :write, :exclusive]) do
      {:ok, io} ->
        result =
          case :file.write(io, Jason.encode!(lease, pretty: true)) do
            :ok -> {:created, lease}
            {:error, reason} -> {:error, {:lease_write_failed, reason}}
          end

        :file.close(io)

        if match?({:error, {:lease_write_failed, _}}, result) do
          _ = File.rm(path)
        end

        case result do
          {:created, created} -> {:ok, created}
          {:error, _reason} = failure -> failure
        end

      {:error, :eexist} ->
        {:error, :eexist}

      {:error, reason} ->
        {:error, {:lease_unavailable, reason}}
    end
  end

  defp readopt_or_reject(state_root) do
    case read_lease(state_root) do
      {:ok, lease} ->
        if lease["instance_id"] == instance_id() and lease["node"] == to_string(node()) do
          readopt(state_root, lease)
        else
          {:error, {:runtime_authority_held, evidence(lease)}}
        end

      {:error, {:lease_state_invalid, _} = invalid} ->
        {:error, invalid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Same-instance re-adoption (holder restart inside one BEAM). Under the op lock,
  # so an operator recovery or a foreign claim can never interleave: whoever runs
  # next sees the re-adopted file, not a free root.
  defp readopt(state_root, lease) do
    adopted =
      lease
      |> Map.put("owner_token", new_owner_token())
      |> Map.put("os_pid", os_pid())
      |> Map.put("hostname", hostname())
      |> Map.put("heartbeat_at", now_iso())

    case write_lease(state_root, adopted) do
      :ok -> {:ok, adopted}
      {:error, reason} -> {:error, {:lease_write_failed, reason}}
    end
  end

  @doc """
  Renews (heartbeats) the lease. Only the current owner token may renew; binding
  fields are immutable here. Lost or corrupt lease fails closed.
  """
  @spec renew(String.t(), String.t()) ::
          {:ok, lease()}
          | {:error, :lease_missing}
          | {:error, :not_owner}
          | {:error, {:lease_state_invalid, atom()}}
          | {:error, {:lease_write_failed, term()}}
          | {:error, {:lease_op_lock_unavailable, term()}}
  def renew(state_root, owner_token) when is_binary(state_root) and is_binary(owner_token) do
    if File.dir?(authority_dir(state_root)) do
      with_op_lock(state_root, @default_op_lock_timeout_ms, fn ->
        with {:ok, lease} <- read_lease(state_root),
             :ok <- authorize(lease, owner_token) do
          updated = Map.put(lease, "heartbeat_at", now_iso())

          case write_lease(state_root, updated) do
            :ok -> {:ok, updated}
            {:error, reason} -> {:error, {:lease_write_failed, reason}}
          end
        else
          {:error, :not_found} -> {:error, :lease_missing}
          {:error, reason} -> {:error, reason}
        end
      end)
    else
      {:error, :lease_missing}
    end
  end

  @doc """
  Releases the lease. Only the current owner token may release; a foreign token is
  refused and the lease is left intact — a stale shutdown path can never delete a
  successor's lease. Release by the owner is idempotent (already-free root is :ok).
  A failed removal is reported, never reported as success.
  """
  @spec release(String.t(), String.t()) ::
          :ok
          | {:error, :not_owner}
          | {:error, {:lease_state_invalid, atom()}}
          | {:error, {:lease_remove_failed, term()}}
          | {:error, {:lease_op_lock_unavailable, term()}}
  def release(state_root, owner_token) when is_binary(state_root) and is_binary(owner_token) do
    if File.dir?(authority_dir(state_root)) do
      with_op_lock(state_root, @default_op_lock_timeout_ms, fn ->
        case read_lease(state_root) do
          {:ok, lease} ->
            if valid_token?(lease, owner_token) do
              case File.rm(authority_path(state_root)) do
                :ok -> :ok
                {:error, reason} -> {:error, {:lease_remove_failed, reason}}
              end
            else
              {:error, :not_owner}
            end

          {:error, :not_found} ->
            :ok

          {:error, reason} ->
            {:error, reason}
        end
      end)
    else
      :ok
    end
  end

  @doc """
  Read-only current ownership evidence from the authoritative file (classification
  included, owner token stripped). Never mutates anything and never grants
  authority.
  """
  @spec observe(String.t()) :: {:ok, evidence()} | {:error, :not_found} | {:error, read_error()}
  def observe(state_root) when is_binary(state_root) do
    case read_lease(state_root) do
      {:ok, lease} -> {:ok, evidence(lease)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Classifies lease liveness from `heartbeat_at`: `:active` within
  `:stale_after_seconds` (default #{@default_stale_after_seconds}s), then
  `:stale_unconfirmed`, then `:releasable` after `:abandoned_after_seconds`
  (default #{@default_abandoned_after_seconds}s). Classification never grants
  takeover authority — see the module doc.
  """
  @spec classify(lease(), DateTime.t() | nil, keyword()) :: {:ok, lease_class()} | {:error, :corrupt_state}
  def classify(lease, now \\ nil, opts \\ []) when is_map(lease) do
    now = now || DateTime.utc_now()

    case parse_ts(lease["heartbeat_at"]) do
      {:ok, heartbeat} ->
        age = DateTime.diff(now, heartbeat, :second)
        stale_after = Keyword.get(opts, :stale_after_seconds, @default_stale_after_seconds)
        abandoned_after = Keyword.get(opts, :abandoned_after_seconds, @default_abandoned_after_seconds)

        cond do
          age < stale_after -> {:ok, :active}
          age < abandoned_after -> {:ok, :stale_unconfirmed}
          true -> {:ok, :releasable}
        end

      :error ->
        {:error, :corrupt_state}
    end
  end

  @doc """
  Explicit operator recovery: force-clears the runtime authority after a human
  decision. Requires `confirm: true` and a non-empty `reason`. The current lease is
  classified first: an `:active` lease is refused with
  `{:error, {:active_lease, evidence}}` unless `force_active: true` is also passed —
  heartbeat classification is diagnostic evidence, never takeover authority on its
  own. Recovery of stale/releasable/corrupt/foreign state needs no override.

  Recovery runs under the same op lock as claim/renew/release, so a fresh runtime's
  lease can never be destroyed by a recovery that started earlier. The prior state
  (or the corrupt raw bytes) is preserved to `authority.recovery.json` before
  removal; the removal result is checked and the root is re-read afterwards: success
  is returned only when the lease is verifiably gone. A surviving lease (same,
  replacement, or corrupt) or a failed removal fails closed.
  Options: `forced_by`, `lock_timeout_ms` (default #{@default_op_lock_timeout_ms}ms).
  """
  @spec force_release(String.t(), keyword()) ::
          {:ok, map()}
          | {:error, :recovery_unconfirmed}
          | {:error, :recovery_reason_required}
          | {:error, :lease_missing}
          | {:error, {:active_lease, evidence()}}
          | {:error, {:lease_remove_failed, map()}}
          | {:error, {:lease_survived, :same_lease | :newer_lease | :corrupt_state | :unreadable_state, map()}}
          | {:error, {:recovery_evidence_write_failed, term()}}
          | {:error, {:lease_op_lock_unavailable, term()}}
          | {:error, read_error()}
  def force_release(state_root, opts) when is_binary(state_root) do
    reason = Keyword.get(opts, :reason)

    cond do
      not Keyword.get(opts, :confirm, false) ->
        {:error, :recovery_unconfirmed}

      not (is_binary(reason) and reason != "") ->
        {:error, :recovery_reason_required}

      true ->
        File.mkdir_p(authority_dir(state_root))

        with_op_lock(state_root, Keyword.get(opts, :lock_timeout_ms, @default_op_lock_timeout_ms), fn ->
          recover_locked(state_root, reason, Keyword.get(opts, :force_active) == true, opts)
        end)
    end
  end

  defp recover_locked(state_root, reason, force_active, opts) do
    case read_lease(state_root) do
      {:ok, lease} ->
        class = class_of(lease)

        if class == :active and not force_active do
          {:error, {:active_lease, evidence(lease)}}
        else
          record = recovery_record(lease, Atom.to_string(class), reason, force_active, opts)
          remove_and_verify(state_root, record, lease["owner_token"])
        end

      # Corrupt/ambiguous/schema-invalid/foreign content: explicit operator recovery
      # remains the only way through. The raw bytes (or best-effort decode) become
      # the evidence.
      {:error, {:lease_state_invalid, invalid}} ->
        case File.read(authority_path(state_root)) do
          {:ok, raw} ->
            record = recovery_record(decode_or_raw(raw), Atom.to_string(invalid), reason, force_active, opts)
            remove_and_verify(state_root, record, nil)

          {:error, :enoent} ->
            {:error, :lease_missing}

          {:error, _} ->
            {:error, {:lease_state_invalid, :unreadable_state}}
        end

      {:error, :not_found} ->
        {:error, :lease_missing}
    end
  end

  defp recovery_record(prior_state, prior_class, reason, force_active, opts) do
    %{
      "schema_version" => @schema_version,
      "kind" => "runtime-authority-recovery",
      "recovered_at" => now_iso(),
      "reason" => reason,
      "forced_by" => Keyword.get(opts, :forced_by, ""),
      "force_active" => force_active,
      "prior_class" => prior_class,
      "prior_state" => prior_state
    }
  end

  defp remove_and_verify(state_root, record, target_token) do
    case write_evidence(state_root, record) do
      :ok ->
        path = authority_path(state_root)

        case fs_rm(path) do
          :ok -> verify_removed(path, target_token, record)
          {:error, rm_reason} -> {:error, {:lease_remove_failed, Map.put(record, "remove_error", rm_reason)}}
        end

      {:error, write_reason} ->
        {:error, {:recovery_evidence_write_failed, write_reason}}
    end
  end

  # Deterministic-test seam for the destructive removal above. Plain File.rm everywhere else.
  defp fs_rm(path) do
    case Process.get(@force_rm_test_hook) do
      nil -> File.rm(path)
      fun when is_function(fun, 1) -> fun.(path)
    end
  end

  defp verify_removed(path, target_token, record) do
    case File.read(path) do
      {:error, :enoent} ->
        {:ok, record}

      {:ok, raw} ->
        {:error, survivor_error(raw, target_token)}

      {:error, read_reason} ->
        {:error, {:lease_survived, :unreadable_state, Map.put(record, "verify_error", read_reason)}}
    end
  end

  defp survivor_error(raw, target_token) do
    case Jason.decode(raw) do
      {:ok, %{"owner_token" => token} = survivor} when is_binary(token) ->
        kind = if survivor["owner_token"] == target_token, do: :same_lease, else: :newer_lease
        {:lease_survived, kind, evidence(survivor)}

      _ ->
        {:lease_survived, :corrupt_state, %{"raw" => raw}}
    end
  end

  defp write_evidence(state_root, record) do
    evidence_path = Path.join(authority_dir(state_root), "authority.recovery.json")
    _ = File.rm(evidence_path)

    case File.write(evidence_path, Jason.encode!(record, pretty: true)) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # -- holder --

  @doc """
  Supervisor-child entry point. `SymphonyElixir.AgentRuntimeSupervisor`-style trees
  place `{#{inspect(__MODULE__)}, opts}` before any lifecycle-capable child; a
  failed acquisition fails the whole tree start.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Acquires runtime authority and holds it for the lifetime of this BEAM instance.
  Called once from `SymphonyElixir.Application.start_runtime/0` before any
  supervisor child exists; an error fails the application start (fail-start).

  On renewal failure the holder fails closed: it marks the instance lost, stops the
  runtime supervisor (`:runtime_supervisor` opt, default `SymphonyElixir.Supervisor`),
  and terminates with `{:runtime_authority_lost, reason}`. The lost instance may
  never re-acquire in the same BEAM; a fresh runtime fails closed against the
  residue unless the operator runs `force_release/2`.

  Options: `:name` (default `#{inspect(__MODULE__)}`), `:root` (override state root
  resolution), `:runtime_supervisor`, `:heartbeat_ms` (default
  `:runtime_lease_heartbeat_ms` app env, else #{@default_heartbeat_ms}ms).
  """
  @spec acquire_and_hold(keyword()) :: {:ok, pid()} | {:error, term()}
  def acquire_and_hold(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    previous_flag = Process.flag(:trap_exit, true)

    try do
      case start_link(opts) do
        {:ok, pid} ->
          {:ok, pid}

        {:error, {:already_started, pid}} ->
          if authoritative?(name), do: {:ok, pid}, else: {:error, {:already_started, pid}}

        {:error, reason} ->
          {:error, reason}
      end
    after
      # A failed init exits the holder abnormally; consume the linked exit signal
      # so the caller observes the {:error, reason} return instead of dying.
      receive do
        {:EXIT, _pid, _reason} -> :ok
      after
        0 -> :ok
      end

      Process.flag(:trap_exit, previous_flag)
    end
  end

  @doc """
  Whether a runtime authority holder currently holds authority for this instance,
  answered from the holder's in-memory state. Read-only evidence for callers
  outside the production boot path (the production gate is the fail-start in
  `SymphonyElixir.Application.start_runtime/0`). Note the answer can lag an
  operator `force_release/2` by up to one heartbeat interval; `holds_authority_for?/1`
  re-reads the durable lease when a decision must reflect ownership right now.
  """
  @spec authoritative?(GenServer.server()) :: boolean()
  def authoritative?(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) ->
        GenServer.call(pid, :authoritative?, @authority_check_timeout_ms)

      _ ->
        false
    end
  catch
    :exit, _reason -> false
  end

  @doc """
  The root actually owned by the live holder — the single authoritative
  mutation root for this runtime instance. Every lifecycle mutation path
  (workspace creation/removal, retry records, steering records, cleanup,
  orphan scans) must derive its root from here, never from live configuration.

  Fail-closed: `{:error, :no_runtime_authority}` before the lease is claimed,
  after a normal release, and after authority loss — a pinned root never
  outlives the authority that justifies it.
  """
  @spec authority_root(GenServer.server()) :: {:ok, String.t()} | {:error, :no_runtime_authority}
  def authority_root(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) ->
        GenServer.call(pid, :authority_root, @authority_check_timeout_ms)

      _ ->
        {:error, :no_runtime_authority}
    end
  catch
    :exit, _reason -> {:error, :no_runtime_authority}
  end

  @doc """
  Alias-safe root equality: two roots are the same mutation domain when they
  canonicalize to the same path. Slash direction, trailing separators, drive
  letter case (Windows), and junction/symlink aliases must not turn one root
  into two apparent roots. Unresolvable paths never match anything.
  """
  @spec roots_match?(String.t() | nil, String.t() | nil) :: boolean()
  def roots_match?(left, right) when is_binary(left) and is_binary(right) do
    with {:ok, canonical_left} <- SymphonyElixir.PathSafety.canonicalize(left),
         {:ok, canonical_right} <- SymphonyElixir.PathSafety.canonicalize(right) do
      normalize_root(canonical_left) == normalize_root(canonical_right)
    else
      {:error, _reason} -> false
    end
  end

  def roots_match?(_left, _right), do: false

  defp normalize_root(path) do
    case :os.type() do
      {:win32, _} -> path |> String.replace("/", "\\") |> String.downcase()
      _ -> path
    end
  end

  @doc """
  Whether this BEAM instance can prove, from the durable lease file at `root`,
  that it still holds authority over `root` right now.

  This is the authority-loss guard for detached mutation workers (the fenced
  cleanup watcher) that outlive the orchestrator process that spawned them and
  act on captured, pinned roots. Unlike `authoritative?/1` — which answers from
  the holder's memory and can lag an operator `force_release/2` by up to one
  heartbeat — this re-reads the lease file and requires it to still exist,
  parse, and belong to this instance's identity (`instance_id` + node). A
  missing lease (released or operator-recovered), a corrupt one, or a foreign
  owner's lease (a successor already acquired the root) all fail closed: no
  authority proof, no destructive mutation.

  Unresolvable roots also fail closed. The check never mutates anything and
  never grants authority; it only refuses work the pin no longer justifies.
  """
  @spec holds_authority_for?(String.t() | nil) :: boolean()
  def holds_authority_for?(root) when is_binary(root) do
    case observe(root) do
      {:ok, evidence} ->
        Map.get(evidence, "instance_id") == instance_id() and Map.get(evidence, "node") == to_string(node())

      {:error, _reason} ->
        false
    end
  end

  def holds_authority_for?(_other), do: false

  @doc """
  Read-only holder status: what authority is held, since when, and the heartbeat
  state. The owner token is never included. `:unavailable` when no holder runs —
  which by itself means the runtime has no lifecycle authority.

  Root truth: `root` is the authority root the lease protects; `configured_root`
  is the workspace root live configuration currently desires; `root_drift?` /
  `restart_required` are true when the two differ. Drift never moves the
  mutation root — the runtime keeps mutating the authority root until it is
  restarted.
  """
  @spec status(GenServer.server()) :: {:ok, map()} | :unavailable
  def status(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) ->
        GenServer.call(pid, :status, @authority_check_timeout_ms)

      _ ->
        :unavailable
    end
  catch
    :exit, _reason -> :unavailable
  end

  @doc """
  Explicitly releases held authority and stops the holder. Used by
  `SymphonyElixir.Application.stop/1` so a normal shutdown releases the lease even
  if the holder was not terminated through supervision. Idempotent; only releases
  when the lease still belongs to this instance.
  """
  @spec release_held(GenServer.server()) :: :ok | {:error, term()}
  def release_held(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) ->
        GenServer.call(pid, :release_and_stop, @authority_check_timeout_ms)

      _ ->
        :ok
    end
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(opts) do
    # Trap exits so supervision shutdown (and parent death) reaches terminate/1:
    # the normal-shutdown path must release the lease, not leave residue.
    Process.flag(:trap_exit, true)
    name = Keyword.get(opts, :name, __MODULE__)

    case resolve_root(opts) do
      {:ok, root} ->
        init_for_root(opts, name, root)

      {:error, reason} ->
        Logger.critical("Runtime authority unavailable reason=#{inspect(reason)}; refusing to start runtime lifecycle")
        {:stop, {:runtime_authority_unavailable, reason}}
    end
  end

  # Same resolution as the Orchestrator's durable record root. A broken config must
  # fail the holder cleanly (not raise): the holder runs before WorkflowStore, so it
  # is the first process to observe configuration at boot.
  defp resolve_root(opts) do
    case Keyword.get(opts, :root) do
      root when is_binary(root) -> {:ok, root}
      _ -> resolve_configured_root()
    end
  end

  defp resolve_configured_root do
    case Application.get_env(:symphony_elixir, :retry_store_root) do
      root when is_binary(root) ->
        {:ok, root}

      _ ->
        try do
          {:ok, SymphonyElixir.Config.local_workspace_root()}
        rescue
          error -> {:error, {:invalid_state_root, Exception.message(error)}}
        end
    end
  end

  defp init_for_root(opts, name, root) do
    lost_key = lost_flag_key(name, root)

    if :persistent_term.get(lost_key, false) do
      {:stop, {:runtime_authority_lost, root}}
    else
      init_claim(opts, name, root)
    end
  end

  defp init_claim(opts, name, root) do
    case claim(root) do
      {:ok, lease} ->
        Logger.info(
          "Runtime authority acquired state_root=#{root} instance_id=#{lease["instance_id"]} " <>
            "os_pid=#{lease["os_pid"]} started_at=#{lease["started_at"]}"
        )

        heartbeat_ms = Keyword.get(opts, :heartbeat_ms, heartbeat_ms_from_env())
        schedule_heartbeat(heartbeat_ms)

        {:ok,
         %__MODULE__{
           name: name,
           root: root,
           lease: lease,
           runtime_supervisor: Keyword.get(opts, :runtime_supervisor, SymphonyElixir.Supervisor),
           heartbeat_ms: heartbeat_ms,
           renew_failures: 0
         }}

      {:error, reason} ->
        Logger.critical(
          "Runtime authority unavailable state_root=#{root} reason=#{inspect(reason)}; " <>
            "refusing to start runtime lifecycle"
        )

        {:stop, {:runtime_authority_unavailable, reason}}
    end
  end

  defp heartbeat_ms_from_env do
    case Application.get_env(:symphony_elixir, :runtime_lease_heartbeat_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @default_heartbeat_ms
    end
  end

  @impl true
  def handle_call(:authoritative?, _from, %__MODULE__{} = state) do
    {:reply, holds?(state), state}
  end

  def handle_call(:authority_root, _from, %__MODULE__{} = state) do
    {:reply, authority_root_from_state(state), state}
  end

  def handle_call(:status, _from, %__MODULE__{} = state) do
    {:reply, {:ok, status_map(state)}, state}
  end

  def handle_call(:release_and_stop, _from, %__MODULE__{} = state) do
    result =
      case state.lease do
        nil ->
          :ok

        lease ->
          case release(state.root, lease["owner_token"]) do
            :ok ->
              Logger.info("Runtime authority released state_root=#{state.root}")
              :ok

            {:error, reason} ->
              Logger.warning("Runtime authority release failed state_root=#{state.root} reason=#{inspect(reason)}")
              {:error, reason}
          end
      end

    if match?({:error, _}, result) do
      {:reply, result, state, {:continue, :stop}}
    else
      {:reply, :ok, %{state | lease: nil}, {:continue, :stop}}
    end
  end

  @impl true
  def handle_continue(:stop, %__MODULE__{} = state) do
    {:stop, :normal, state}
  end

  # Pattern-matched instead of `not is_nil(state.lease) and not state.lost?`:
  # on a narrowed non-nil lease the hidden `case` arm of `and` folds to an
  # unmatched `false` pattern and dialyzer reports it location-less.
  defp holds?(%__MODULE__{lease: nil}), do: false
  defp holds?(%__MODULE__{lost?: true}), do: false
  defp holds?(%__MODULE__{}), do: true

  @impl true
  def handle_info(:heartbeat, %__MODULE__{} = state) do
    case renew(state.root, state.lease["owner_token"]) do
      {:ok, lease} ->
        schedule_heartbeat(state.heartbeat_ms)
        {:noreply, %{state | lease: lease, last_renew_at: now_iso(), renew_error: nil, renew_failures: 0}}

      {:error, reason} ->
        renew_failed(state, reason)
    end
  end

  # Trapping exits means linked-process EXIT notices arrive as messages; nothing
  # outside the authority decision may stop the holder.
  def handle_info(_msg, %__MODULE__{} = state), do: {:noreply, state}

  # Ownership loss (lease gone, foreign owner, mutated state) is terminal: the
  # instance no longer provably holds authority. Filesystem-only failures do not
  # answer the ownership question, so they retry with the next heartbeat and only
  # become terminal once they persist (`:runtime_lease_max_renew_failures` app
  # env, default #{@default_max_renew_failures}) — a broken filesystem is
  # fail-closed, a transient one is not a takeover signal.
  @default_max_renew_failures 3

  defp renew_failed(%__MODULE__{} = state, reason) do
    failures = state.renew_failures + 1

    if ownership_lost?(reason) or failures >= max_renew_failures() do
      authority_lost(state, reason)
    else
      Logger.warning(
        "Runtime authority renewal failed (will retry) state_root=#{state.root} " <>
          "failures=#{failures} reason=#{inspect(reason)}"
      )

      schedule_heartbeat(state.heartbeat_ms)
      {:noreply, %{state | renew_error: reason, renew_failures: failures}}
    end
  end

  defp max_renew_failures do
    case Application.get_env(:symphony_elixir, :runtime_lease_max_renew_failures) do
      n when is_integer(n) and n >= 1 -> n
      _ -> @default_max_renew_failures
    end
  end

  defp ownership_lost?(:lease_missing), do: true
  defp ownership_lost?(:not_owner), do: true
  defp ownership_lost?({:lease_state_invalid, invalid}) when invalid != :unreadable_state, do: true
  defp ownership_lost?(_reason), do: false

  # Authority loss is terminal for this instance: mark it lost, take the runtime
  # down (no lifecycle mutation may continue without authority), and stop. The
  # persistent flag keeps a restarted holder from silently re-acquiring in the same
  # BEAM; a successor must be a fresh runtime that fails closed against the residue
  # unless the operator recovers explicitly.
  defp authority_lost(%__MODULE__{} = state, reason) do
    Logger.critical(
      "Runtime authority lost state_root=#{state.root} instance_id=#{state.lease["instance_id"]} " <>
        "reason=#{inspect(reason)}; stopping runtime lifecycle"
    )

    :persistent_term.put(lost_flag_key(state.name, state.root), true)
    stop_runtime_supervisor(state.runtime_supervisor)
    {:stop, {:runtime_authority_lost, reason}, %{state | lost?: true}}
  end

  defp stop_runtime_supervisor(nil), do: :ok

  defp stop_runtime_supervisor(supervisor) do
    case GenServer.whereis(supervisor) do
      pid when is_pid(pid) ->
        GenServer.stop(pid, :runtime_authority_lost, @authority_check_timeout_ms)
        :ok

      _ ->
        :ok
    end
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def terminate(_reason, %__MODULE__{lease: nil}), do: :ok
  def terminate(_reason, %__MODULE__{lost?: true}), do: :ok

  def terminate(_reason, %__MODULE__{} = state) do
    case release(state.root, state.lease["owner_token"]) do
      :ok ->
        Logger.info("Runtime authority released state_root=#{state.root}")
        :ok

      {:error, reason} ->
        Logger.warning("Runtime authority release failed state_root=#{state.root} reason=#{inspect(reason)}")
        :ok
    end
  end

  defp authority_root_from_state(%__MODULE__{lost?: true}), do: {:error, :no_runtime_authority}
  defp authority_root_from_state(%__MODULE__{lease: %{"state_root" => root}}), do: {:ok, root}
  defp authority_root_from_state(%__MODULE__{}), do: {:error, :no_runtime_authority}

  defp schedule_heartbeat(heartbeat_ms), do: Process.send_after(self(), :heartbeat, heartbeat_ms)

  defp status_map(%__MODULE__{} = state) do
    now = DateTime.utc_now()

    class =
      case state.lease && classify(state.lease, now) do
        {:ok, class} -> class
        _ -> nil
      end

    configured_root = configured_workspace_root()
    drift? = root_drift?(state.root, configured_root)

    %{
      name: state.name,
      root: state.root,
      configured_root: configured_root,
      root_drift?: drift?,
      restart_required: drift?,
      instance_id: state.lease && state.lease["instance_id"],
      os_pid: state.lease && state.lease["os_pid"],
      node: state.lease && state.lease["node"],
      hostname: state.lease && state.lease["hostname"],
      started_at: state.lease && state.lease["started_at"],
      heartbeat_at: state.lease && state.lease["heartbeat_at"],
      last_renew_at: state.last_renew_at,
      renew_error: state.renew_error,
      lost?: state.lost?,
      held?: not is_nil(state.lease),
      class: class
    }
  end

  # Live workspace root configuration currently desires, for drift truth only.
  # Never used as a mutation root: resolution failure reports nil instead of
  # inventing a root.
  defp configured_workspace_root do
    SymphonyElixir.Config.local_workspace_root()
  rescue
    _error -> nil
  end

  defp root_drift?(_authority_root, nil), do: false

  defp root_drift?(authority_root, configured_root) when is_binary(authority_root) do
    not roots_match?(authority_root, configured_root)
  end

  # -- internals --

  defp new_lease(state_root, opts) do
    now = now_iso()

    %{
      "schema_version" => @schema_version,
      "kind" => @kind,
      "state_root" => state_root,
      "instance_id" => Keyword.get(opts, :instance_id, instance_id()),
      "owner_token" => new_owner_token(),
      "os_pid" => os_pid(),
      "node" => to_string(node()),
      "hostname" => hostname(),
      "started_at" => now,
      "heartbeat_at" => now
    }
  end

  # Per-state-root mutual exclusion: claim, re-adopt, renew, release, and destructive
  # operator recovery all hold this lock across their read-(modify-)write. Acquired
  # via the same atomic exclusive-create primitive as the lease itself; bounded
  # wait, fail-closed. Harvested from SymphonyElixir.LaneLease.
  defp with_op_lock(state_root, timeout_ms, fun) do
    path = op_lock_path(state_root)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    case acquire_op_lock(path, deadline) do
      {:ok, io} ->
        try do
          fun.()
        after
          :file.close(io)
          remove_op_lock(path)
        end

      {:error, :timeout} ->
        {:error, {:lease_op_lock_unavailable, :timeout}}

      {:error, reason} ->
        {:error, {:lease_op_lock_unavailable, reason}}
    end
  end

  defp acquire_op_lock(path, deadline) do
    case :file.open(path, [:raw, :write, :exclusive]) do
      {:ok, io} ->
        case :file.write(io, op_lock_payload()) do
          :ok ->
            {:ok, io}

          {:error, reason} ->
            :file.close(io)
            _ = File.rm(path)
            {:error, reason}
        end

      {:error, :eexist} ->
        wait_for_op_lock(path, deadline)

      # On Windows, a create-race against a holder's open handle surfaces as a
      # sharing violation (:eacces) rather than :eexist; both mean "someone holds
      # it, wait".
      {:error, :eacces} ->
        wait_for_op_lock(path, deadline)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp wait_for_op_lock(path, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :timeout}
    else
      Process.sleep(@op_lock_poll_ms)
      acquire_op_lock(path, deadline)
    end
  end

  # A lock that cannot be released would wedge the state root forever; retry briefly
  # before giving up. Residual leak (host crash mid-critical-section) requires manual
  # removal of the .op-lock file — documented in docs/runtime_authority.md.
  defp remove_op_lock(path), do: remove_op_lock(path, 5)

  defp remove_op_lock(_path, 0), do: :error

  defp remove_op_lock(path, attempts) do
    case File.rm(path) do
      :ok ->
        :ok

      {:error, _} ->
        Process.sleep(@op_lock_poll_ms)
        remove_op_lock(path, attempts - 1)
    end
  end

  defp op_lock_path(state_root), do: Path.join(authority_dir(state_root), "authority.op-lock")

  defp op_lock_payload do
    Jason.encode!(%{"holder" => inspect(self()), "node" => to_string(node()), "acquired_at" => now_iso()})
  end

  defp read_lease(state_root) do
    case File.read(authority_path(state_root)) do
      {:ok, raw} -> decode_lease(raw, state_root)
      {:error, :enoent} -> {:error, :not_found}
      {:error, _} -> {:error, {:lease_state_invalid, :unreadable_state}}
    end
  end

  defp decode_lease(raw, state_root) do
    case Jason.decode(raw) do
      {:ok, %{"schema_version" => @schema_version, "kind" => @kind} = lease} ->
        validate_lease(lease, state_root)

      {:ok, _} ->
        {:error, {:lease_state_invalid, :ambiguous_state}}

      {:error, _} ->
        {:error, {:lease_state_invalid, :corrupt_state}}
    end
  end

  defp validate_lease(lease, state_root) do
    fields_valid =
      Enum.all?(@core_fields, fn f -> is_binary(Map.get(lease, f)) and Map.get(lease, f) != "" end) and
        is_binary(Map.get(lease, "hostname"))

    timestamps_parseable = parse_ts(lease["started_at"]) != :error and parse_ts(lease["heartbeat_at"]) != :error

    cond do
      not fields_valid or not timestamps_parseable ->
        {:error, {:lease_state_invalid, :schema_invalid}}

      lease["state_root"] != state_root ->
        {:error, {:lease_state_invalid, :root_mismatch}}

      true ->
        {:ok, lease}
    end
  end

  defp write_lease(state_root, lease) do
    path = authority_path(state_root)
    tmp = path <> "." <> Integer.to_string(:erlang.unique_integer([:positive])) <> ".tmp"

    with :ok <- File.write(tmp, Jason.encode!(lease, pretty: true)),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, reason}
    end
  end

  defp authorize(lease, owner_token) do
    if valid_token?(lease, owner_token), do: :ok, else: {:error, :not_owner}
  end

  # The stored token is always a binary, so plain equality already refuses
  # non-binary tokens. (An `is_binary(owner_token) and ...` guard here folds
  # to a constant `true` for dialyzer and surfaces as a location-less
  # pattern_match warning.)
  defp valid_token?(lease, owner_token), do: lease["owner_token"] == owner_token

  defp evidence(lease) do
    now = DateTime.utc_now()

    class =
      case classify(lease, now) do
        {:ok, c} -> Atom.to_string(c)
        {:error, _} -> "corrupt_state"
      end

    heartbeat_age =
      case parse_ts(lease["heartbeat_at"]) do
        {:ok, heartbeat} -> DateTime.diff(now, heartbeat, :second)
        :error -> nil
      end

    lease
    |> Map.drop(["owner_token"])
    |> Map.put("class", class)
    |> Map.put("heartbeat_age_seconds", heartbeat_age)
  end

  defp class_of(lease) do
    case classify(lease) do
      {:ok, class} -> class
      {:error, _} -> :corrupt_state
    end
  end

  defp decode_or_raw(raw) do
    case Jason.decode(raw) do
      {:ok, parsed} -> parsed
      {:error, _} -> raw
    end
  end

  defp lost_flag_key(name, root), do: {__MODULE__, name, :authority_lost, root}

  defp new_owner_token, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  defp os_pid, do: to_string(:os.getpid())

  # :inet.gethostname/0's dialyzer spec disagrees with its runtime contract
  # ({:ok, charlist} at runtime), so the error clause is suppressed, not removed.
  @dialyzer {:nowarn_function, hostname: 0}
  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      {:error, _} -> ""
    end
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp parse_ts(value) do
    case DateTime.from_iso8601(value || "") do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _} -> :error
    end
  end
end
