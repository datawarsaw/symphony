defmodule SymphonyElixir.PilotReadmit do
  @moduledoc """
  PILOT-R4-READMISSION: the bounded, fail-closed, offline operator procedure
  that re-admits an issue whose pilot lifecycle ended in the single-attempt
  park (`stop_reason: "pilot_single_attempt"`).

  The single-attempt guard is never weakened: this module does not touch the
  scheduling funnel, the dispatch poller, restart recovery suppression, or the
  CONTROL verbs. It converts one exactly-matched durable parked record into
  the `"readmitted"` status and writes a durable audit record. The next armed
  runtime start rehydrates the `"readmitted"` record (Orchestrator recovery),
  the ordinary poller dispatches exactly one new attempt, and the
  single-attempt funnel parks the issue again when that attempt completes or
  fails. Every further re-admission requires a fresh run of this procedure
  against the NEW parked record.

  Preconditions (all required, all checked fail-closed, in order):

    1. Explicit operator authorization - a non-empty `:confirmation` string
       (who authorized the new attempt, and on what evidence), recorded
       verbatim in the audit record.
    2. The reviewed pilot manifest, whose `workflow_path` enables the
       OpenCode section and allows exactly this issue identifier - the
       mechanism is scoped to the armed pilot's own allowlist.
    3. Runtime stopped and authority safely released - the state root carries
       no `runtime/authority.json` at all (runbook §8 recovery is the
       documented release step; any lease file, of any class, refuses).
    4. Exact issue identity and expected parked record - exactly one durable
       record for the identifier with status `parked`, whose `stop_reason`,
       `attempt_count`, and `last_failure_at` equal the operator-supplied
       expected values byte-for-byte, so a stale command can never clear a
       newer attempt (a newer park writes a later `last_failure_at`).
    5. Only the single-attempt park class is eligible; every other park
       (`max_attempts`, fence parks, auth parks) refuses.
    6. No pending retry timer - the record's `next_retry_at` is nil.
    7. No unresolved launch fence - `LaunchMarker.reuse_gate/2` is `:allowed`
       for the issue (no marker, or a marker whose death is receipt-proven).
    8. Valid termination receipt for the consumed attempt - the operator
       supplies the consumed attempt's `launch_id`; a receipt named by that
       launch id must exist under the state root's managed
       `worker-terminations` directory, parse, match the launch id, and prove
       the tree drained with a conclusive terminal reason
       (`WorkerContainment.verify_identity_receipt/1`).

  On success the tool (a) appends one entry to
  `<state_root>/.symphony-state/readmissions/<issue>.json` naming the
  previous attempt (stop reason, attempt count, launch id, receipt path) and
  the verbatim authorization, and (b) rewrites the parked record to
  `status: "readmitted"` with an embedded `readmission` evidence map, every
  other field preserved. The audit is written before the record. Both writes
  are atomic; an unreadable existing audit refuses instead of being replaced.

  This procedure never contacts a tracker, never decrypts credentials, never
  calls a provider, never starts a process, and never touches the lease, the
  launch marker store, or any workspace. It is not a substitute for the
  bootstrap gate: the armed start still runs the full
  `SymphonyElixir.PilotBootstrap` admission sequence afterwards.

  A `readmitted` record read outside an armed OpenCode pilot, or with missing
  or invalid readmission evidence, fails closed at recovery (claim, no
  timer, no dispatch).
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.LaunchMarker
  alias SymphonyElixir.RetryStore
  alias SymphonyElixir.RuntimeLease
  alias SymphonyElixir.WorkerContainment
  alias SymphonyElixir.Workflow

  @required_manifest_keys ~w(pilot_root source_root expected_source_sha workflow_path workspace_root logs_root)

  @readmitted_status "readmitted"
  @eligible_stop_reason "pilot_single_attempt"
  @audit_schema_version 1

  @type refused :: {:error, {:pilot_readmit_refused, atom(), map()}}

  @doc """
  Runs the re-admission procedure against one parked record.

  Required opts: `:issue` (identifier), `:confirmation`, `:expected_attempt_count`,
  `:expected_stop_reason`, `:expected_last_failure_at`, `:expected_launch_id`.
  Optional: `:dry_run` (full precondition evaluation, no mutation).

  Returns `{:ok, receipt}` — with `receipt.dry_run` set for a dry run — or a
  `{:error, {:pilot_readmit_refused, code, evidence}}` refusal. Every refusal
  leaves the durable state untouched.
  """
  @spec readmit(Path.t(), keyword()) :: {:ok, map()} | refused() | {:error, term()}
  def readmit(manifest_path, opts \\ []) do
    env = %{
      now: Keyword.get(opts, :now, fn -> DateTime.utc_now() end),
      lease_observe: Keyword.get(opts, :lease_observe, &RuntimeLease.observe/1),
      launch_gate:
        Keyword.get(opts, :launch_gate, fn issue_id, root ->
          LaunchMarker.reuse_gate(issue_id, root: root)
        end),
      fence: Keyword.get(opts, :fence, &WorkerContainment.verify_identity_receipt/1)
    }

    with {:ok, request} <- build_request(opts),
         {:ok, manifest} <- load_manifest(manifest_path),
         {:ok, settings} <- load_settings(manifest.workflow_path),
         :ok <- pilot_issue_authorized?(settings, request.identifier),
         :ok <- state_root_present?(manifest.workspace_root),
         :ok <- runtime_stopped?(manifest.workspace_root, env.lease_observe),
         {:ok, record} <- find_parked_record(manifest.workspace_root, request.identifier),
         :ok <- expected_record?(record, request),
         :ok <- no_pending_retry_timer?(record),
         :ok <- launch_fence_clear?(record, manifest.workspace_root, env.launch_gate),
         :ok <- termination_evidence?(manifest.workspace_root, request, env.fence) do
      receipt = base_receipt(manifest, record, request, env)

      if request.dry_run do
        {:ok, Map.put(receipt, :dry_run, true)}
      else
        commit(manifest.workspace_root, record, request, receipt, env)
      end
    end
  end

  @doc """
  Validates the embedded readmission evidence of a `"readmitted"` retry
  record. Shared with Orchestrator restart recovery: a record claiming the
  readmitted status without structurally valid evidence (operator
  authorization, single-attempt origin, consumed-attempt identity) is
  ambiguous state and must fail closed.
  """
  @spec validate_readmission_evidence(term()) :: {:ok, map()} | {:error, term()}
  def validate_readmission_evidence(evidence) when is_map(evidence) do
    with :ok <- present_field(evidence, "readmission_id"),
         :ok <- present_field(evidence, "authorization"),
         :ok <- parseable_timestamp(evidence, "authorized_at"),
         :ok <- present_field(evidence, "from_launch_id"),
         :ok <- present_field(evidence, "from_last_failure_at"),
         :ok <- from_stop_reason_eligible?(evidence),
         :ok <- from_attempt_count_valid?(evidence) do
      {:ok, evidence}
    end
  end

  def validate_readmission_evidence(_evidence), do: {:error, :readmission_evidence_missing}

  @doc """
  Path of the per-issue re-admission audit record under the state root.
  """
  @spec audit_path(String.t(), String.t()) :: String.t()
  def audit_path(state_root, issue_id) when is_binary(state_root) and is_binary(issue_id) do
    Path.join([state_root, ".symphony-state", "readmissions", RetryStore.safe_issue_id(issue_id) <> ".json"])
  end

  # ── request ─────────────────────────────────────────────────────────────────

  defp build_request(opts) do
    request = %{
      identifier: Keyword.get(opts, :issue),
      confirmation: Keyword.get(opts, :confirmation),
      expected_attempt_count: Keyword.get(opts, :expected_attempt_count),
      expected_stop_reason: Keyword.get(opts, :expected_stop_reason),
      expected_last_failure_at: Keyword.get(opts, :expected_last_failure_at),
      expected_launch_id: Keyword.get(opts, :expected_launch_id),
      dry_run: Keyword.get(opts, :dry_run, false) == true
    }

    cond do
      not present_binary?(request.identifier) ->
        refused(:invalid_request, %{field: :issue, requirement: :non_empty_issue_identifier})

      not present_binary?(request.confirmation) ->
        # The explicit operator authorization: without it the command is an
        # observation, never a mutation.
        refused(:missing_confirmation, %{field: :confirmation})

      not is_integer(request.expected_attempt_count) or request.expected_attempt_count < 1 ->
        refused(:invalid_request, %{field: :expected_attempt_count, requirement: :positive_integer})

      not present_binary?(request.expected_stop_reason) ->
        refused(:invalid_request, %{field: :expected_stop_reason})

      not present_binary?(request.expected_last_failure_at) ->
        refused(:invalid_request, %{field: :expected_last_failure_at})

      not present_binary?(request.expected_launch_id) ->
        refused(:invalid_request, %{field: :expected_launch_id})

      true ->
        {:ok, request}
    end
  end

  # ── manifest / workflow ─────────────────────────────────────────────────────

  defp load_manifest(path) do
    with :ok <- manifest_readable(path),
         {:ok, map} <- manifest_yaml(path),
         :ok <- validate_manifest_keys(map) do
      {:ok,
       %{
         pilot_root: Map.fetch!(map, "pilot_root"),
         workflow_path: Map.fetch!(map, "workflow_path"),
         workspace_root: Map.fetch!(map, "workspace_root")
       }}
    end
  end

  defp manifest_readable(path) do
    if File.regular?(path), do: :ok, else: {:error, {:pilot_readmit_refused, :manifest_missing, %{path: path}}}
  end

  defp manifest_yaml(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _other} -> {:error, {:pilot_readmit_refused, :manifest_not_a_map, %{path: path}}}
      {:error, reason} -> {:error, {:pilot_readmit_refused, :manifest_parse_error, %{path: path, reason: inspect(reason)}}}
    end
  end

  defp validate_manifest_keys(map) do
    case Enum.reject(@required_manifest_keys, fn key -> present_binary?(Map.get(map, key)) end) do
      [] -> :ok
      missing -> {:error, {:pilot_readmit_refused, :manifest_missing_keys, %{missing: missing}}}
    end
  end

  defp load_settings(path) do
    case Workflow.load(path) do
      {:ok, %{config: config}} ->
        case Schema.parse(config) do
          {:ok, settings} -> {:ok, settings}
          {:error, reason} -> {:error, {:pilot_readmit_refused, :workflow_schema_invalid, %{reason: inspect(reason)}}}
        end

      {:error, reason} ->
        {:error, {:pilot_readmit_refused, :workflow_unreadable, %{path: path, reason: inspect(reason)}}}
    end
  end

  # The mechanism re-admits only an issue the armed pilot itself authorizes:
  # an identifier outside the OpenCode allowlist is out of scope even when a
  # matching parked record exists.
  defp pilot_issue_authorized?(settings, identifier) do
    opencode = Map.get(settings, :opencode)
    allowed_issues = if is_struct(opencode), do: opencode.allowed_issues, else: []

    cond do
      not match?(%{enabled: true}, opencode) ->
        {:error, {:pilot_readmit_refused, :pilot_section_disabled, %{identifier: identifier}}}

      identifier not in (allowed_issues || []) ->
        {:error, {:pilot_readmit_refused, :pilot_issue_not_authorized, %{identifier: identifier, allowed_issues: allowed_issues || []}}}

      true ->
        :ok
    end
  end

  # ── preconditions ───────────────────────────────────────────────────────────

  defp state_root_present?(state_root) do
    if File.dir?(state_root),
      do: :ok,
      else: {:error, {:pilot_readmit_refused, :state_root_missing, %{state_root: state_root}}}
  end

  # "Runtime stopped and authority safely released": any authority lease file
  # at this state root's well-known authority path — active, stale, foreign,
  # or unreadable — refuses. The documented release step is the operator's
  # runbook §8 recovery, which removes the file; this procedure never
  # releases, recovers, or rewrites the lease itself. Presence is judged on
  # the file, not on a byte-form root comparison: the lease records the
  # runtime's own spelling of the root, which can differ from the manifest's.
  defp runtime_stopped?(state_root, lease_observe) do
    authority_path = RuntimeLease.authority_path(state_root)

    if File.exists?(authority_path) do
      evidence =
        case lease_observe.(state_root) do
          {:ok, lease} -> %{authority_path: authority_path, lease: lease}
          {:error, reason} -> %{authority_path: authority_path, reason: inspect(reason)}
        end

      {:error, {:pilot_readmit_refused, :runtime_authority_present, evidence}}
    else
      :ok
    end
  end

  # Exactly one durable record for the identifier, and it must be a park.
  defp find_parked_record(state_root, identifier) do
    case parked_records_for_identifier(state_root, identifier) do
      [record] ->
        {:ok, record}

      [] ->
        {:error, {:pilot_readmit_refused, :parked_record_not_found, %{identifier: identifier, requirement: :exactly_one_parked_record}}}

      records ->
        {:error, {:pilot_readmit_refused, :ambiguous_parked_record, %{identifier: identifier, matching_records: length(records)}}}
    end
  end

  defp parked_records_for_identifier(state_root, identifier) do
    state_root
    |> RetryStore.list_records()
    |> Enum.flat_map(fn {_file_id, result} ->
      case result do
        {:ok, %{"identifier" => ^identifier, "status" => "parked"} = record} -> [record]
        _other -> []
      end
    end)
  end

  # The exact durable-state identity: a stale command prepared against an
  # older park cannot match a newer park's record, because a newer park
  # always carries a later `last_failure_at`.
  defp expected_record?(record, request) do
    expected = %{
      "stop_reason" => request.expected_stop_reason,
      "attempt_count" => request.expected_attempt_count,
      "last_failure_at" => request.expected_last_failure_at
    }

    actual = Map.take(record, Map.keys(expected))
    mismatches = Enum.flat_map(expected, fn {field, value} -> if actual[field] == value, do: [], else: [field] end)

    cond do
      mismatches != [] ->
        {:error, {:pilot_readmit_refused, :expected_record_mismatch, %{fields: mismatches, expected: expected, actual: actual}}}

      request.expected_stop_reason != @eligible_stop_reason ->
        # Policy parks and fence parks have their own recovery paths (or
        # deliberately none); this mechanism re-admits only the
        # single-attempt park class.
        {:error, {:pilot_readmit_refused, :park_class_not_supported, %{stop_reason: request.expected_stop_reason, eligible: [@eligible_stop_reason]}}}

      true ->
        :ok
    end
  end

  defp no_pending_retry_timer?(record) do
    if Map.get(record, "next_retry_at") == nil,
      do: :ok,
      else: {:error, {:pilot_readmit_refused, :pending_retry_timer, %{next_retry_at: Map.get(record, "next_retry_at")}}}
  end

  defp launch_fence_clear?(record, state_root, launch_gate) do
    case launch_gate.(record["issue_id"], state_root) do
      :allowed ->
        :ok

      {:blocked, reason} ->
        {:error, {:pilot_readmit_refused, :launch_fence_unresolved, %{verdict: reason, issue_id: record["issue_id"]}}}
    end
  end

  # Valid termination receipt for the consumed attempt: the operator states
  # the consumed attempt's launch id; the receipt named by that launch id
  # must exist under this state root's managed worker-terminations directory,
  # parse, match the launch id, and positively prove the drain with a
  # conclusive terminal reason (the same fence primitive the runtime uses).
  defp termination_evidence?(state_root, request, fence) do
    receipt_path = Path.join(WorkerContainment.receipt_dir(state_root), request.expected_launch_id <> ".json")

    identity = %{
      "receipt_path" => receipt_path,
      "launch_id" => request.expected_launch_id,
      "authority_root" => state_root
    }

    case fence.(identity) do
      {:ok, :dead} ->
        :ok

      {:error, verdict} ->
        {:error, {:pilot_readmit_refused, :termination_evidence_invalid, %{launch_id: request.expected_launch_id, receipt_path: receipt_path, fence_verdict: verdict}}}
    end
  end

  # ── mutation ────────────────────────────────────────────────────────────────

  defp commit(state_root, record, request, receipt, env) do
    now_iso = DateTime.to_iso8601(env.now.())
    readmission_id = "readmit-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    evidence = %{
      "readmission_id" => readmission_id,
      "from_stop_reason" => record["stop_reason"],
      "from_attempt_count" => record["attempt_count"],
      "from_last_failure_at" => record["last_failure_at"],
      "from_launch_id" => request.expected_launch_id,
      "authorized_at" => now_iso,
      "authorization" => request.confirmation
    }

    audit_entry = %{
      "readmission_id" => readmission_id,
      "issue_id" => record["issue_id"],
      "identifier" => record["identifier"],
      "authorized_at" => now_iso,
      "authorization" => request.confirmation,
      "previous_attempt" => %{
        "status" => record["status"],
        "stop_reason" => record["stop_reason"],
        "attempt_count" => record["attempt_count"],
        "last_failure_at" => record["last_failure_at"],
        "launch_id" => request.expected_launch_id
      },
      "termination_receipt_path" => receipt.termination_receipt_path,
      "new_status" => @readmitted_status
    }

    # The audit trail first: the preserved evidence of who authorized the new
    # attempt must exist before the parked record changes.
    with :ok <- append_audit(state_root, record["issue_id"], record["identifier"], audit_entry) do
      updated = record |> Map.put("status", @readmitted_status) |> Map.put("readmission", evidence)
      :ok = RetryStore.write_record(state_root, updated)

      case verify_commit(state_root, record["issue_id"], readmission_id) do
        :ok ->
          {:ok, Map.merge(receipt, %{dry_run: false, readmission_id: readmission_id, authorized_at: now_iso})}

        {:error, evidence_detail} ->
          {:error, {:pilot_readmit_verification_failed, evidence_detail}}
      end
    end
  end

  defp verify_commit(state_root, issue_id, readmission_id) do
    with {:ok, record} <- RetryStore.read_record(state_root, issue_id),
         :ok <- written_status?(record, readmission_id),
         :ok <- audit_written?(state_root, issue_id, readmission_id) do
      :ok
    end
  end

  defp written_status?(record, readmission_id) do
    if Map.get(record, "status") == @readmitted_status and
         match?(%{"readmission_id" => ^readmission_id}, Map.get(record, "readmission")),
       do: :ok,
       else: {:error, %{stage: :record_verify, status: Map.get(record, "status")}}
  end

  defp audit_written?(state_root, issue_id, readmission_id) do
    case read_audit(state_root, issue_id) do
      {:ok, entries} ->
        if Enum.any?(entries, &match?(%{"readmission_id" => ^readmission_id}, &1)),
          do: :ok,
          else: {:error, %{stage: :audit_verify, path: audit_path(state_root, issue_id)}}

      {:error, reason} ->
        {:error, %{stage: :audit_verify, path: audit_path(state_root, issue_id), reason: inspect(reason)}}
    end
  end

  # Read-modify-write with atomic rename, mirroring RetryStore. An existing
  # audit that cannot be parsed refuses the whole procedure: recorded
  # re-admission evidence is never overwritten or reset.
  defp append_audit(state_root, issue_id, identifier, entry) do
    path = audit_path(state_root, issue_id)

    entries =
      case read_audit(state_root, issue_id) do
        {:ok, entries} ->
          entries

        {:error, :not_found} ->
          []

        {:error, reason} ->
          {:error, {:pilot_readmit_refused, :audit_evidence_unreadable, %{path: path, reason: inspect(reason)}}}
      end

    case entries do
      {:error, _refusal} = refusal ->
        refusal

      entries when is_list(entries) ->
        document = %{
          "schema_version" => @audit_schema_version,
          "issue_id" => issue_id,
          "identifier" => identifier,
          "entries" => entries ++ [entry]
        }

        write_audit_atomically(path, document)
    end
  end

  defp read_audit(state_root, issue_id) do
    case File.read(audit_path(state_root, issue_id)) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, %{"schema_version" => @audit_schema_version, "entries" => entries}} when is_list(entries) ->
            {:ok, entries}

          {:ok, _other} ->
            {:error, :audit_ambiguous_state}

          {:error, _reason} ->
            {:error, :audit_corrupt_state}
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, _reason} ->
        {:error, :audit_unreadable_state}
    end
  end

  defp write_audit_atomically(path, document) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> "." <> Integer.to_string(:erlang.unique_integer([:positive])) <> ".tmp"
    File.write!(tmp, Jason.encode!(document, pretty: true))
    File.rename!(tmp, path)
    :ok
  rescue
    error -> {:error, {:pilot_readmit_refused, :audit_write_failed, %{path: path, reason: Exception.message(error)}}}
  end

  # ── receipt ─────────────────────────────────────────────────────────────────

  defp base_receipt(manifest, record, request, env) do
    %{
      action: :pilot_readmit,
      issue_id: record["issue_id"],
      identifier: record["identifier"],
      state_root: manifest.workspace_root,
      record_path: RetryStore.record_path(manifest.workspace_root, record["issue_id"]),
      audit_path: audit_path(manifest.workspace_root, record["issue_id"]),
      previous_attempt: %{
        status: record["status"],
        stop_reason: record["stop_reason"],
        attempt_count: record["attempt_count"],
        last_failure_at: record["last_failure_at"]
      },
      expected_launch_id: request.expected_launch_id,
      termination_receipt_path: Path.join(WorkerContainment.receipt_dir(manifest.workspace_root), request.expected_launch_id <> ".json"),
      launch_fence: :allowed,
      termination_verdict: :dead,
      confirmation: request.confirmation,
      new_status: @readmitted_status,
      checked_at: DateTime.to_iso8601(env.now.())
    }
  end

  # ── shared helpers ──────────────────────────────────────────────────────────

  defp refused(code, evidence), do: {:error, {:pilot_readmit_refused, code, evidence}}

  defp present_binary?(value), do: is_binary(value) and String.trim(value) != ""

  defp present_field(evidence, field) do
    if present_binary?(Map.get(evidence, field)),
      do: :ok,
      else: {:error, {:readmission_evidence_invalid, %{field: field}}}
  end

  defp parseable_timestamp(evidence, field) do
    value = Map.get(evidence, field)

    case present_binary?(value) && DateTime.from_iso8601(value) do
      {:ok, _dt, _offset} -> :ok
      _ -> {:error, {:readmission_evidence_invalid, %{field: field, requirement: :iso8601_timestamp}}}
    end
  end

  defp from_stop_reason_eligible?(evidence) do
    if Map.get(evidence, "from_stop_reason") == @eligible_stop_reason,
      do: :ok,
      else: {:error, {:readmission_evidence_invalid, %{field: "from_stop_reason", expected: @eligible_stop_reason}}}
  end

  defp from_attempt_count_valid?(evidence) do
    count = Map.get(evidence, "from_attempt_count")

    if is_integer(count) and count >= 1,
      do: :ok,
      else: {:error, {:readmission_evidence_invalid, %{field: "from_attempt_count", requirement: :positive_integer}}}
  end
end
