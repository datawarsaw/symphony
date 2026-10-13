defmodule SymphonyElixir.RetryStore do
  @moduledoc """
  Durable JSON store for MIC-195 Slice A retry/PARKED records.

  One file per issue under `<workspace_root>/.symphony-state/retries/<safe>.json`.
  Writes are atomic (temp file + rename). Corrupt or ambiguous state must
  fail closed: callers treat read errors as PARKED-like (claim, no timer).

  Harness identity is additive on schema version 1. A validated pin is
  `harness` of `codex` or `opencode` plus `harness_authority` of `pinned`
  (or `legacy_codex` for an explicit Codex interpretation). Records that
  predate the pin and carry no harness key are provably legacy Codex only
  when they also carry no OpenCode identity. A harness-shaped value that is
  missing, invalid, or contradicted by `worker_identity.harness` is missing
  authority and must not be read as Codex.
  """

  @schema_version 1

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec retries_dir(String.t()) :: String.t()
  def retries_dir(workspace_root), do: Path.join([workspace_root, ".symphony-state", "retries"])

  @spec safe_issue_id(String.t()) :: String.t()
  def safe_issue_id(issue_id) do
    issue_id |> String.downcase() |> String.replace(~r/[^a-z0-9_-]/, "_") |> String.slice(0, 128)
  end

  @spec record_path(String.t(), String.t()) :: String.t()
  def record_path(workspace_root, issue_id) do
    Path.join(retries_dir(workspace_root), safe_issue_id(issue_id) <> ".json")
  end

  @spec write_record(String.t(), map()) :: :ok
  def write_record(workspace_root, record) when is_map(record) do
    dir = retries_dir(workspace_root)
    File.mkdir_p!(dir)
    issue_id = Map.fetch!(record, "issue_id")
    path = record_path(workspace_root, issue_id)
    tmp = path <> "." <> Integer.to_string(:erlang.unique_integer([:positive])) <> ".tmp"
    payload = Jason.encode!(Map.put_new(record, "schema_version", @schema_version), pretty: true)
    File.write!(tmp, payload)
    File.rename!(tmp, path)
    :ok
  end

  @spec delete_record(String.t(), String.t()) :: :ok
  def delete_record(workspace_root, issue_id) do
    _ = File.rm(record_path(workspace_root, issue_id))
    :ok
  end

  @spec read_record(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def read_record(workspace_root, issue_id) do
    path = record_path(workspace_root, issue_id)

    case File.read(path) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, %{"schema_version" => 1} = record} -> {:ok, record}
          {:ok, _} -> {:error, :ambiguous_state}
          {:error, _} -> {:error, :corrupt_state}
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, _} ->
        {:error, :unreadable_state}
    end
  end

  @spec list_records(String.t()) :: [{String.t(), {:ok, map()} | {:error, atom()}}]
  def list_records(workspace_root) do
    case File.ls(retries_dir(workspace_root)) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(fn name ->
          issue_id = String.trim_trailing(name, ".json")
          {issue_id, read_record_by_file(workspace_root, name)}
        end)

      {:error, _} ->
        []
    end
  end

  @spec read_record_by_file(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  defp read_record_by_file(workspace_root, name) do
    path = Path.join(retries_dir(workspace_root), name)

    case File.read(path) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, %{"schema_version" => 1} = record} -> {:ok, record}
          {:ok, _} -> {:error, :ambiguous_state}
          {:error, _} -> {:error, :corrupt_state}
        end

      {:error, _} ->
        {:error, :unreadable_state}
    end
  end

  @spec build_record(map()) :: map()
  def build_record(attrs) when is_map(attrs) do
    attrs
    |> core_record()
    |> put_optional_harness(attrs)
  end

  defp core_record(attrs) do
    %{
      "schema_version" => @schema_version,
      "issue_id" => Map.fetch!(attrs, :issue_id),
      "identifier" => Map.get(attrs, :identifier, ""),
      "status" => Map.fetch!(attrs, :status),
      "failure_class" => Map.fetch!(attrs, :failure_class),
      "attempt_count" => Map.get(attrs, :attempt_count, 0),
      "identical_failure_count" => Map.get(attrs, :identical_failure_count, 1),
      "first_failure_at" => Map.get(attrs, :first_failure_at),
      "last_failure_at" => Map.get(attrs, :last_failure_at),
      "next_retry_at" => Map.get(attrs, :next_retry_at),
      "last_error" => Map.get(attrs, :last_error, ""),
      "worker_host" => Map.get(attrs, :worker_host, ""),
      "worker_identity" => Map.get(attrs, :worker_identity),
      "workspace_path" => Map.get(attrs, :workspace_path, ""),
      "workspace_root" => Map.get(attrs, :workspace_root, ""),
      # MIC-195 Slice C: durable route state. Additive fields with safe
      # defaults — legacy version-1 records without them still parse and
      # recover as route=primary, primary_failure_count=0, so no version bump
      # and no invalidation of existing retry state.
      "route" => route_name(Map.get(attrs, :route)),
      "primary_failure_count" => primary_failure_count(Map.get(attrs, :primary_failure_count))
    }
  end

  @valid_harnesses ["codex", "opencode"]

  @doc """
  Classifies the harness authority stored on one retry record.

  `{:ok, harness, :pinned | :legacy_codex, evidence}` is safe to dispatch.
  `{:error, reason, evidence}` is not, and the evidence must be kept. This
  function never rewrites an ambiguous OpenCode identity into Codex.
  """
  @spec harness_authority(map()) ::
          {:ok, :codex | :opencode, :pinned | :legacy_codex, String.t()}
          | {:error, :harness_authority_mismatch | :harness_authority_missing, String.t()}
  def harness_authority(record) when is_map(record) do
    harness = Map.get(record, "harness", :absent)
    authority = Map.get(record, "harness_authority", :absent)
    evidence = evidence_text(Map.get(record, "harness_evidence"))
    identity = identity_harness(Map.get(record, "worker_identity"))

    cond do
      harness in @valid_harnesses and authority == "pinned" and conflicts?(harness, identity) ->
        {:error, :harness_authority_mismatch, "pinned_harness=#{harness} worker_identity.harness=#{identity_label(identity)}"}

      harness in @valid_harnesses and authority == "pinned" ->
        {:ok, String.to_existing_atom(harness), :pinned, evidence || "pinned"}

      harness == "codex" and authority == "legacy_codex" and not conflicts?("codex", identity) ->
        {:ok, :codex, :legacy_codex, evidence || "legacy_codex"}

      provably_legacy_codex?(record, identity) ->
        {:ok, :codex, :legacy_codex, "legacy_codex:absent_harness_authority"}

      true ->
        {:error, :harness_authority_missing, missing_evidence(harness, authority, identity, evidence)}
    end
  end

  @doc """
  Writes a non-failure lifecycle pin (`active` or `continuing`).

  The record carries only the validated harness identity and the workspace
  coordinates needed to resume that same harness. It is not a failure envelope.
  """
  @spec write_lifecycle_pin(String.t(), map()) :: :ok
  def write_lifecycle_pin(workspace_root, attrs) when is_binary(workspace_root) and is_map(attrs) do
    harness = Map.fetch!(attrs, :harness)
    status = Map.get(attrs, :status, "active")

    if harness in [:codex, :opencode] and status in ["active", "continuing"] do
      record = %{
        "schema_version" => @schema_version,
        "issue_id" => Map.fetch!(attrs, :issue_id),
        "identifier" => Map.get(attrs, :identifier, "") || "",
        "status" => status,
        "harness" => Atom.to_string(harness),
        "harness_authority" => Atom.to_string(Map.get(attrs, :harness_authority, :pinned)),
        "harness_evidence" => evidence_or_default(attrs, harness),
        "worker_host" => Map.get(attrs, :worker_host) || "",
        "workspace_path" => Map.get(attrs, :workspace_path) || "",
        "workspace_root" => Map.get(attrs, :workspace_root) || workspace_root,
        "route" => route_name(Map.get(attrs, :route)),
        "primary_failure_count" => primary_failure_count(Map.get(attrs, :primary_failure_count))
      }

      write_record(workspace_root, record)
    else
      :ok
    end
  end

  @doc """
  Merges a validated harness pin into an existing record, or writes an
  `active` pin when the issue has no record yet. Corrupt records are left
  untouched.
  """
  @spec merge_harness_pin(String.t(), String.t(), map()) :: :ok
  def merge_harness_pin(workspace_root, issue_id, pin)
      when is_binary(workspace_root) and is_binary(issue_id) and is_map(pin) do
    case read_record(workspace_root, issue_id) do
      {:ok, record} ->
        write_record(workspace_root, promote_readmitted_pin(record, harness_field_map(pin)))

      {:error, :not_found} ->
        write_lifecycle_pin(workspace_root, %{
          issue_id: issue_id,
          identifier: Map.get(pin, :identifier, ""),
          status: "active",
          harness: Map.get(pin, :harness),
          harness_authority: Map.get(pin, :authority, :pinned),
          harness_evidence: Map.get(pin, :evidence),
          worker_host: Map.get(pin, :worker_host),
          workspace_path: Map.get(pin, :workspace_path),
          workspace_root: Map.get(pin, :workspace_root, workspace_root),
          route: Map.get(pin, :route, :primary),
          primary_failure_count: Map.get(pin, :primary_failure_count, 0)
        })

      {:error, _reason} ->
        :ok
    end
  end

  # PILOT-R4-READMISSION: committing a harness pin IS the launch of the
  # re-admitted attempt, so the record leaves the resting "readmitted" state
  # for the ordinary "active" lifecycle and the PILOT-R3 restart safety (a
  # durable active record parks on recovery) covers a crash while that
  # attempt is in flight. The embedded readmission evidence is preserved
  # verbatim.
  defp promote_readmitted_pin(%{"status" => "readmitted"} = record, pin_fields) do
    record |> Map.merge(pin_fields) |> Map.put("status", "active")
  end

  defp promote_readmitted_pin(record, pin_fields), do: Map.merge(record, pin_fields)

  @doc """
  Parks a record whose harness authority is missing or contradictory.

  The previous `harness` value is preserved when present. Codex is never
  written in its place.
  """
  @spec record_authority_failure(String.t(), map(), atom(), String.t()) :: :ok
  def record_authority_failure(workspace_root, record, reason, evidence)
      when is_binary(workspace_root) and is_map(record) and is_atom(reason) and is_binary(evidence) do
    authority = if reason == :harness_authority_mismatch, do: "mismatch", else: "missing"

    updated =
      record
      |> Map.put("schema_version", @schema_version)
      |> Map.put("status", "parked")
      |> Map.put("stop_reason", Atom.to_string(reason))
      |> Map.put("harness_authority", authority)
      |> Map.put("harness_evidence", evidence)
      |> Map.put("last_error", evidence)

    write_record(workspace_root, updated)
  end

  defp route_name(:fallback), do: "fallback"
  defp route_name(_route), do: "primary"

  defp primary_failure_count(count) when is_integer(count) and count >= 0, do: count
  defp primary_failure_count(_count), do: 0

  defp put_optional_harness(record, attrs) do
    case Map.get(attrs, :harness) do
      harness when harness in [:codex, :opencode] ->
        Map.merge(
          record,
          harness_field_map(%{
            harness: harness,
            authority: Map.get(attrs, :harness_authority, :pinned),
            evidence: Map.get(attrs, :harness_evidence)
          })
        )

      _absent ->
        record
    end
  end

  defp harness_field_map(%{harness: harness} = pin) when harness in [:codex, :opencode] do
    authority = Map.get(pin, :authority, :pinned)
    authority = if authority in [:pinned, :legacy_codex], do: authority, else: :pinned

    %{
      "harness" => Atom.to_string(harness),
      "harness_authority" => Atom.to_string(authority),
      "harness_evidence" => evidence_or_default(pin, harness)
    }
  end

  defp harness_field_map(_pin), do: %{}

  defp evidence_or_default(attrs, harness) do
    case Map.get(attrs, :harness_evidence) || Map.get(attrs, :evidence) do
      evidence when is_binary(evidence) and evidence != "" -> evidence
      _ -> "pinned:" <> Atom.to_string(harness)
    end
  end

  defp evidence_text(evidence) when is_binary(evidence) and evidence != "", do: evidence
  defp evidence_text(_evidence), do: nil

  defp identity_harness(%{"harness" => harness}) when is_binary(harness) and harness != "", do: harness
  defp identity_harness(%{"harness" => nil}), do: "nil"

  defp identity_harness(identity) when is_map(identity) do
    if Map.has_key?(identity, "harness"), do: inspect(Map.get(identity, "harness")), else: nil
  end

  defp identity_harness(_identity), do: nil

  defp conflicts?(harness, identity) when identity in ["codex", "opencode"], do: identity != harness
  defp conflicts?(_harness, _identity), do: false

  defp provably_legacy_codex?(record, identity) do
    not Map.has_key?(record, "harness") and
      not Map.has_key?(record, "harness_authority") and
      not Map.has_key?(record, "harness_evidence") and
      identity in [nil, "codex"]
  end

  defp missing_evidence(harness, authority, identity, evidence) do
    "missing_harness_authority harness=#{field_label(harness)} authority=#{field_label(authority)} " <>
      "worker_identity.harness=#{identity_label(identity)} evidence=#{field_label(evidence)}"
  end

  defp identity_label(nil), do: "absent"
  defp identity_label(identity), do: identity

  defp field_label(:absent), do: "absent"
  defp field_label(nil), do: "nil"
  defp field_label(value) when is_binary(value), do: value
  defp field_label(value), do: inspect(value)
end
