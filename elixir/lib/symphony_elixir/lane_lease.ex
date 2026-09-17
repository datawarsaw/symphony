defmodule SymphonyElixir.LaneLease do
  @moduledoc """
  Durable delivery-lane lease with explicit single-owner semantics.

  One file per lane under `<workspace_root>/.symphony-state/lanes/<safe-lane-id>.json`.
  A lane is a logical delivery identity (`"<lane_kind>:<issue_id>"`, e.g. `"delivery:MIC-10"`).
  At most one owner (an opaque invocation token) is ever valid for a lane.

  What this protects: two executor sessions cannot simultaneously operate the same delivery
  worktree / branch / accepted-SHA lane. A second claimant fails closed with
  `{:error, {:lease_held, evidence}}`; a lost claim is always visible, never silent.

  What this does NOT protect: processes that ignore the lease entirely, or a hostile writer
  that deletes/rewrites state files (operator `force_release/4` exists precisely because file
  state is operator-trusted). The lease is structural against racing honest executors, not
  security against malice.

  Staleness is classification only. A stale heartbeat makes a lease `:stale_unconfirmed` or
  `:releasable` for humans and tooling, but `claim/2` still refuses while the file exists:
  a dead heartbeat is not authority to destroy a lane whose owner may be mid-delivery.
  Recovery is `force_release/4` — explicit operator confirmation plus a written reason, with
  the pre-recovery state preserved to a `.recovery.json` evidence file. Ordinary recovery
  refuses an `:active` lease; destroying an active lease additionally requires
  `force_active: true`. Destructive lease mutation is serialized against `claim/2`,
  `renew/4`, and `release/4` by a per-lane lock file, and recovery success means the
  targeted lease was verified absent after removal.

  Executor cycle: `claim/2` → `renew/4` periodically (heartbeat) →
  `verify_live_state/2` immediately before push/PR → `release/4`.
  Changing the accepted artifact requires `release/4` (or operator `force_release/4`) and a
  fresh claim; `renew/4` can never move `accepted_sha`, `branch`, `worktree_path`, or `base_sha`.

  Durability follows `SymphonyElixir.RetryStore`: bounded JSON with `schema_version`, atomic
  temp + rename for rewrites, fail-closed on corrupt/ambiguous/foreign reads. The initial
  `claim/2` create is atomic (`:exclusive`) so concurrent claimants produce exactly one winner.
  """

  @schema_version 1
  @default_stale_after_seconds 15 * 60
  @default_abandoned_after_seconds 12 * 60 * 60
  @default_op_lock_timeout_ms 5_000
  @op_lock_poll_ms 5
  @required_fields ~w(lane_id lane_kind issue_id owner_token owner_id worktree_path branch accepted_sha base_sha created_at heartbeat_at)
  # Private deterministic-test seam (per-process, unset in production): override for the
  # destructive removal inside force_release/4. Deliberately not a general filesystem hook.
  @force_rm_test_hook :"$lane_lease_force_rm_hook"

  @type lease :: map()
  @type evidence :: map()
  @type lane_kind :: String.t()
  @type issue_id :: String.t()
  @type owner_token :: String.t()
  @type lease_class :: :active | :stale_unconfirmed | :releasable
  @type read_error ::
          {:lease_state_invalid, :corrupt_state | :ambiguous_state | :lane_mismatch | :schema_invalid | :unreadable_state}

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec lane_id(lane_kind(), issue_id()) :: String.t()
  def lane_id(lane_kind, issue_id), do: lane_kind <> ":" <> issue_id

  @spec lanes_dir(String.t()) :: String.t()
  def lanes_dir(workspace_root), do: Path.join([workspace_root, ".symphony-state", "lanes"])

  @spec safe_lane_name(String.t()) :: String.t()
  def safe_lane_name(lane_id) do
    lane_id |> String.downcase() |> String.replace(~r/[^a-z0-9_-]/, "_") |> String.slice(0, 128)
  end

  @spec lease_path(String.t(), lane_kind(), issue_id()) :: String.t()
  def lease_path(workspace_root, lane_kind, issue_id) do
    Path.join(lanes_dir(workspace_root), safe_lane_name(lane_id(lane_kind, issue_id)) <> ".json")
  end

  @doc """
  Builds a normalized lease payload from claim attributes. Randomizes `owner_token`;
  whitelists fields so claimants cannot smuggle `lane_id`, `owner_token`, or timestamps.
  """
  @spec build_lease(%{
          required(:issue_id) => issue_id(),
          required(:owner_id) => String.t(),
          required(:worktree_path) => String.t(),
          required(:branch) => String.t(),
          required(:accepted_sha) => String.t(),
          required(:base_sha) => String.t(),
          optional(:lane_kind) => lane_kind()
        }) :: lease()
  def build_lease(attrs) when is_map(attrs) do
    lane_kind = Map.get(attrs, :lane_kind, "delivery")
    now = now_iso()

    %{
      "schema_version" => @schema_version,
      "lane_id" => lane_id(lane_kind, Map.fetch!(attrs, :issue_id)),
      "lane_kind" => lane_kind,
      "issue_id" => Map.fetch!(attrs, :issue_id),
      "owner_token" => new_owner_token(),
      "owner_id" => Map.fetch!(attrs, :owner_id),
      "worktree_path" => Map.fetch!(attrs, :worktree_path),
      "branch" => Map.fetch!(attrs, :branch),
      "accepted_sha" => Map.fetch!(attrs, :accepted_sha),
      "base_sha" => Map.fetch!(attrs, :base_sha),
      "created_at" => now,
      "heartbeat_at" => now
    }
  end

  @doc """
  Atomically claims the lane. Succeeds only if no lease file exists (`:exclusive` create).
  Any existing lease — including a stale or corrupt-looking one — fails closed; a stale
  heartbeat is reported as evidence but never authorizes takeover.
  """
  @spec claim(String.t(), map()) ::
          {:ok, lease()}
          | {:error, {:lease_held, evidence()}}
          | {:error, read_error()}
          | {:error, {:lease_write_failed, term()}}
          | {:error, {:lease_vanished, :retry}}
          | {:error, {:lease_unavailable, term()}}
          | {:error, {:lease_op_lock_unavailable, term()}}
          | {:error, :invalid_attrs}
  def claim(workspace_root, attrs) do
    with {:ok, lease} <- validate_claim_attrs(attrs),
         :ok <- File.mkdir_p(lanes_dir(workspace_root)) do
      path = lease_path(workspace_root, lease["lane_kind"], lease["issue_id"])
      payload = Jason.encode!(lease, pretty: true)

      with_op_lock(workspace_root, lease["lane_kind"], lease["issue_id"], @default_op_lock_timeout_ms, fn ->
        case :file.open(path, [:raw, :write, :exclusive]) do
          {:ok, io} ->
            result =
              case :file.write(io, payload) do
                :ok -> {:ok, lease}
                {:error, reason} -> {:error, {:lease_write_failed, reason}}
              end

            :file.close(io)
            if match?({:error, {:lease_write_failed, _}}, result), do: _ = File.rm(path)
            result

          {:error, :eexist} ->
            reject_claim(workspace_root, lease["lane_kind"], lease["issue_id"])

          {:error, reason} ->
            {:error, {:lease_unavailable, reason}}
        end
      end)
    else
      {:error, :invalid_attrs} -> {:error, :invalid_attrs}
      {:error, reason} -> {:error, {:lease_unavailable, reason}}
    end
  end

  @doc """
  Renews (heartbeats) the lease. Only the current owner token may renew; the binding fields
  are immutable here by construction. Lost or corrupt lease fails closed.
  """
  @spec renew(String.t(), lane_kind(), issue_id(), owner_token()) ::
          {:ok, lease()}
          | {:error, :lease_missing}
          | {:error, :not_owner}
          | {:error, read_error()}
          | {:error, {:lease_op_lock_unavailable, term()}}
  def renew(workspace_root, lane_kind, issue_id, owner_token) do
    if File.dir?(lanes_dir(workspace_root)) do
      with_op_lock(workspace_root, lane_kind, issue_id, @default_op_lock_timeout_ms, fn ->
        with {:ok, lease} <- read_lease(workspace_root, lane_kind, issue_id),
             :ok <- authorize(lease, owner_token) do
          updated = Map.put(lease, "heartbeat_at", now_iso())
          :ok = write_lease(workspace_root, lane_kind, issue_id, updated)
          {:ok, updated}
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
  Releases the lease. Only the current owner token may release; a foreign token is refused and
  the lease is left intact. Release by the owner is idempotent (already-free lane is `:ok`).
  A failed removal is reported, never reported as success.
  """
  @spec release(String.t(), lane_kind(), issue_id(), owner_token()) ::
          :ok
          | {:error, :not_owner}
          | {:error, read_error()}
          | {:error, {:lease_remove_failed, term()}}
          | {:error, {:lease_op_lock_unavailable, term()}}
  def release(workspace_root, lane_kind, issue_id, owner_token) do
    if File.dir?(lanes_dir(workspace_root)) do
      with_op_lock(workspace_root, lane_kind, issue_id, @default_op_lock_timeout_ms, fn ->
        case read_lease(workspace_root, lane_kind, issue_id) do
          {:ok, lease} ->
            if valid_token?(lease, owner_token) do
              case File.rm(lease_path(workspace_root, lane_kind, issue_id)) do
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
  Read-only current ownership evidence (classification included, owner token stripped).
  """
  @spec inspect(String.t(), lane_kind(), issue_id()) ::
          {:ok, evidence()} | {:error, :not_found} | {:error, read_error()}
  def inspect(workspace_root, lane_kind, issue_id) do
    case read_lease(workspace_root, lane_kind, issue_id) do
      {:ok, lease} -> {:ok, evidence(lease)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Classifies lease liveness from `heartbeat_at`: `:active` within `:stale_after_seconds`
  (default #{@default_stale_after_seconds}s), then `:stale_unconfirmed`, then `:releasable`
  after `:abandoned_after_seconds` (default #{@default_abandoned_after_seconds}s).
  Classification never grants takeover authority — see the module doc.
  """
  @spec classify(lease(), DateTime.t() | nil, keyword()) ::
          {:ok, lease_class()} | {:error, :corrupt_state}
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
  Explicit operator recovery: force-clears a lane after human decision. Requires
  `confirm: true` and a non-empty `reason`. The current lease is classified first: an
  `:active` lease is refused with `{:error, {:active_lease, evidence}}` unless
  `force_active: true` is also passed — heartbeat classification is diagnostic evidence,
  never takeover authority on its own. Recovery of stale/releasable/corrupt state needs no
  override.

  Destructive recovery runs under a per-lane operation lock shared with `claim/2`,
  `renew/4`, and `release/4`, so a new owner's lease can never be destroyed by a recovery
  that started earlier. The prior state (or the corrupt raw bytes) is preserved to
  `<safe-lane>.recovery.json` before removal; the removal result is checked and the lane is
  re-read afterwards: success is returned only when the targeted lease is verifiably gone.
  A surviving lease (same, replacement, or corrupt) or a failed removal fails closed.
  Options: `forced_by`, `lock_timeout_ms` (default #{@default_op_lock_timeout_ms}ms).
  """
  @spec force_release(String.t(), lane_kind(), issue_id(), keyword()) ::
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
  def force_release(workspace_root, lane_kind, issue_id, opts) do
    reason = Keyword.get(opts, :reason)

    cond do
      not Keyword.get(opts, :confirm, false) ->
        {:error, :recovery_unconfirmed}

      not (is_binary(reason) and reason != "") ->
        {:error, :recovery_reason_required}

      true ->
        File.mkdir_p(lanes_dir(workspace_root))

        with_op_lock(workspace_root, lane_kind, issue_id, lock_timeout(opts), fn ->
          recover_locked(workspace_root, lane_kind, issue_id, reason, Keyword.get(opts, :force_active) == true, opts)
        end)
    end
  end

  @doc """
  Pure binding check: every field present in `observed` (atom keys) must match the lease.
  Worktree paths compare separator- and case-insensitively. Returns the mismatched fields.
  """
  @spec verify_binding(lease(), map()) :: :ok | {:error, {:binding_mismatch, [atom()]}}
  def verify_binding(lease, observed) when is_map(lease) and is_map(observed) do
    checked =
      [:worktree_path, :branch, :accepted_sha, :base_sha]
      |> Enum.filter(&Map.has_key?(observed, &1))
      |> Enum.reject(fn field ->
        leased = Map.fetch!(lease, Atom.to_string(field))
        live = Map.fetch!(observed, field)

        if field == :worktree_path do
          paths_equal?(leased, live)
        else
          leased == live
        end
      end)

    if checked == [], do: :ok, else: {:error, {:binding_mismatch, checked}}
  end

  @doc """
  Reads the live Git state of a delivery worktree: current branch and HEAD SHA.
  """
  @spec observe_worktree(String.t()) ::
          {:ok, %{branch: String.t(), head_sha: String.t()}} | {:error, {:git_failed, String.t()}}
  def observe_worktree(worktree_path) do
    with {:ok, branch} <- git(worktree_path, ["rev-parse", "--abbrev-ref", "HEAD"]),
         {:ok, head} <- git(worktree_path, ["rev-parse", "HEAD"]) do
      {:ok, %{branch: String.trim(branch), head_sha: String.trim(head)}}
    end
  end

  @doc """
  Re-checks that live Git state still matches the lease: worktree path, branch, and that the
  leased `base_sha` is an ancestor of HEAD. Options: `:worktree_path` (observe an explicit
  path), `:accepted_sha` (assert the artifact being pushed is the leased one),
  `:require_accepted_in_head` (accepted SHA must be an ancestor of HEAD — the pre-push gate).
  """
  @spec verify_live_state(lease(), keyword()) ::
          :ok | {:error, {:binding_mismatch, [String.t()]}} | {:error, {:git_failed, String.t()}}
  def verify_live_state(lease, opts \\ []) when is_map(lease) do
    worktree_path = Keyword.get(opts, :worktree_path) || Map.fetch!(lease, "worktree_path")

    with {:ok, observed} <- observe_worktree(worktree_path) do
      observed_map = %{worktree_path: worktree_path, branch: observed.branch}
      observed_map = if opts[:accepted_sha], do: Map.put(observed_map, :accepted_sha, opts[:accepted_sha]), else: observed_map

      mismatches =
        case verify_binding(lease, observed_map) do
          :ok -> []
          {:error, {:binding_mismatch, fields}} -> Enum.map(fields, &Atom.to_string/1)
        end

      ancestry_checks = [{"base_sha", Map.fetch!(lease, "base_sha"), observed.head_sha}]

      ancestry_checks =
        if opts[:require_accepted_in_head],
          do: ancestry_checks ++ [{"accepted_sha in HEAD", Map.fetch!(lease, "accepted_sha"), observed.head_sha}],
          else: ancestry_checks

      mismatches = mismatches ++ ancestry_mismatches(worktree_path, ancestry_checks)

      if mismatches == [], do: :ok, else: {:error, {:binding_mismatch, mismatches}}
    end
  end

  # -- internals --

  # Operator recovery, run under the lane's operation lock. The lease read here is the one
  # that gets removed: no claim/renew/release can interleave inside the critical section.
  defp recover_locked(workspace_root, lane_kind, issue_id, reason, force_active, opts) do
    case read_lease(workspace_root, lane_kind, issue_id) do
      {:ok, lease} ->
        class = class_of(lease)

        if class == :active and not force_active do
          {:error, {:active_lease, evidence(lease)}}
        else
          record = recovery_record(lane_kind, issue_id, lease, Atom.to_string(class), reason, force_active, opts)
          remove_and_verify(workspace_root, lane_kind, issue_id, record, lease["owner_token"])
        end

      # Corrupt/ambiguous/schema-invalid/foreign content: explicit operator recovery remains
      # the only way through. The raw bytes (or best-effort decode) become the evidence.
      {:error, {:lease_state_invalid, invalid}} ->
        case File.read(lease_path(workspace_root, lane_kind, issue_id)) do
          {:ok, raw} ->
            record = recovery_record(lane_kind, issue_id, decode_or_raw(raw), Atom.to_string(invalid), reason, force_active, opts)
            remove_and_verify(workspace_root, lane_kind, issue_id, record, nil)

          {:error, :enoent} ->
            {:error, :lease_missing}

          {:error, _} ->
            {:error, {:lease_state_invalid, :unreadable_state}}
        end

      {:error, :not_found} ->
        {:error, :lease_missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp recovery_record(lane_kind, issue_id, prior_state, prior_class, reason, force_active, opts) do
    %{
      "schema_version" => @schema_version,
      "lane_id" => lane_id(lane_kind, issue_id),
      "recovered_at" => now_iso(),
      "reason" => reason,
      "forced_by" => Keyword.get(opts, :forced_by, ""),
      "force_active" => force_active,
      "prior_class" => prior_class,
      "prior_state" => prior_state
    }
  end

  defp remove_and_verify(workspace_root, lane_kind, issue_id, record, target_token) do
    case write_evidence(workspace_root, lane_kind, issue_id, record) do
      :ok ->
        path = lease_path(workspace_root, lane_kind, issue_id)

        case fs_rm(path) do
          :ok -> verify_removed(path, target_token, record)
          {:error, rm_reason} -> {:error, {:lease_remove_failed, Map.put(record, "remove_error", rm_reason)}}
        end

      {:error, write_reason} ->
        {:error, {:recovery_evidence_write_failed, write_reason}}
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

  defp write_evidence(workspace_root, lane_kind, issue_id, record) do
    evidence_path = Path.join(lanes_dir(workspace_root), recovery_name(lane_kind, issue_id))
    _ = File.rm(evidence_path)

    case File.write(evidence_path, Jason.encode!(record, pretty: true)) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp class_of(lease) do
    case classify(lease) do
      {:ok, class} -> class
      {:error, _} -> :corrupt_state
    end
  end

  # Deterministic-test seam for the destructive removal above. Plain File.rm everywhere else.
  defp fs_rm(path) do
    case Process.get(@force_rm_test_hook) do
      nil -> File.rm(path)
      fun when is_function(fun, 1) -> fun.(path)
    end
  end

  defp lock_timeout(opts) do
    case Keyword.get(opts, :lock_timeout_ms) do
      t when is_integer(t) and t >= 0 -> t
      _ -> @default_op_lock_timeout_ms
    end
  end

  # Per-lane mutual exclusion over lease mutation: claim, renew, release, and destructive
  # operator recovery all hold this lock across their read-modify-write. Acquired via the
  # same atomic exclusive-create primitive as the initial claim. Bounded wait, fail-closed.
  defp with_op_lock(workspace_root, lane_kind, issue_id, timeout_ms, fun) do
    path = op_lock_path(workspace_root, lane_kind, issue_id)
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
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(@op_lock_poll_ms)
          acquire_op_lock(path, deadline)
        end

      # On Windows, a create-race against a holder's open handle surfaces as a sharing
      # violation (:eacces) rather than :eexist; both mean "someone holds it, wait".
      {:error, :eacces} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(@op_lock_poll_ms)
          acquire_op_lock(path, deadline)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A lock that cannot be released would wedge the lane forever; retry briefly before
  # giving up. Residual leak (host crash mid-critical-section) requires manual removal of
  # the .op-lock file — documented in docs/delivery_lane_lease.md.
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

  defp op_lock_path(workspace_root, lane_kind, issue_id) do
    Path.join(lanes_dir(workspace_root), safe_lane_name(lane_id(lane_kind, issue_id)) <> ".op-lock")
  end

  defp op_lock_payload do
    Jason.encode!(%{"holder" => inspect(self()), "node" => to_string(node()), "acquired_at" => now_iso()})
  end

  defp ancestry_mismatches(worktree_path, checks) do
    Enum.flat_map(checks, fn {name, ancestor, descendant} ->
      case git_ancestor?(worktree_path, ancestor, descendant) do
        {:ok, true} -> []
        {:ok, false} -> [name]
        {:error, _} -> [name <> " (unverifiable)"]
      end
    end)
  end

  defp reject_claim(workspace_root, lane_kind, issue_id) do
    case read_lease(workspace_root, lane_kind, issue_id) do
      {:ok, lease} -> {:error, {:lease_held, evidence(lease)}}
      {:error, :not_found} -> {:error, {:lease_vanished, :retry}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorize(lease, owner_token) do
    if valid_token?(lease, owner_token), do: :ok, else: {:error, :not_owner}
  end

  defp valid_token?(lease, owner_token), do: is_binary(owner_token) and lease["owner_token"] == owner_token

  defp read_lease(workspace_root, lane_kind, issue_id) do
    case File.read(lease_path(workspace_root, lane_kind, issue_id)) do
      {:ok, raw} -> decode_lease(raw, lane_kind, issue_id)
      {:error, :enoent} -> {:error, :not_found}
      {:error, _} -> {:error, {:lease_state_invalid, :unreadable_state}}
    end
  end

  defp decode_lease(raw, lane_kind, issue_id) do
    case Jason.decode(raw) do
      {:ok, %{"schema_version" => @schema_version} = lease} -> validate_lease(lease, lane_kind, issue_id)
      {:ok, _} -> {:error, {:lease_state_invalid, :ambiguous_state}}
      {:error, _} -> {:error, {:lease_state_invalid, :corrupt_state}}
    end
  end

  defp validate_lease(lease, lane_kind, issue_id) do
    fields_valid = Enum.all?(@required_fields, fn f -> is_binary(Map.get(lease, f)) and Map.get(lease, f) != "" end)

    timestamps_parseable = parse_ts(lease["created_at"]) != :error and parse_ts(lease["heartbeat_at"]) != :error

    cond do
      not fields_valid or not timestamps_parseable ->
        {:error, {:lease_state_invalid, :schema_invalid}}

      lease["lane_id"] != lane_id(lane_kind, issue_id) or lease["issue_id"] != issue_id ->
        {:error, {:lease_state_invalid, :lane_mismatch}}

      true ->
        {:ok, lease}
    end
  end

  defp write_lease(workspace_root, lane_kind, issue_id, lease) do
    path = lease_path(workspace_root, lane_kind, issue_id)
    tmp = path <> "." <> Integer.to_string(:erlang.unique_integer([:positive])) <> ".tmp"
    File.write!(tmp, Jason.encode!(lease, pretty: true))
    File.rename!(tmp, path)
    :ok
  end

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

  defp validate_claim_attrs(attrs) do
    required = [:issue_id, :owner_id, :worktree_path, :branch, :accepted_sha, :base_sha]
    lane_kind = Map.get(attrs, :lane_kind, "delivery")

    if Enum.all?(required, fn f -> is_binary(Map.get(attrs, f)) and Map.get(attrs, f) != "" end) and
         is_binary(lane_kind) and Regex.match?(~r/\A[a-z][a-z0-9_-]{0,31}\z/, lane_kind) do
      {:ok, build_lease(Map.put(attrs, :lane_kind, lane_kind))}
    else
      {:error, :invalid_attrs}
    end
  end

  defp decode_or_raw(raw) do
    case Jason.decode(raw) do
      {:ok, parsed} -> parsed
      {:error, _} -> raw
    end
  end

  defp recovery_name(lane_kind, issue_id), do: safe_lane_name(lane_id(lane_kind, issue_id)) <> ".recovery.json"

  defp new_owner_token, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  defp now_iso, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp parse_ts(value) do
    case DateTime.from_iso8601(value || "") do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _} -> :error
    end
  end

  defp paths_equal?(a, b) do
    normalize = fn p -> p |> Path.expand() |> String.replace("\\", "/") |> String.downcase() end
    normalize.(a) == normalize.(b)
  end

  defp git(worktree_path, args) do
    case System.cmd("git", ["-c", "safe.directory=#{worktree_path}", "-C", worktree_path | args], stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, _} -> {:error, {:git_failed, String.trim(out)}}
    end
  end

  defp git_ancestor?(repo, ancestor, descendant) do
    case System.cmd("git", ["-c", "safe.directory=#{repo}", "-C", repo, "merge-base", "--is-ancestor", ancestor, descendant], stderr_to_stdout: true) do
      {_, 0} -> {:ok, true}
      {_, 1} -> {:ok, false}
      {out, _} -> {:error, {:git_failed, String.trim(out)}}
    end
  end
end
