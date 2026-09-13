defmodule SymphonyElixir.RetryStore do
  @moduledoc """
  Durable JSON store for MIC-195 Slice A retry/PARKED records.

  One file per issue under `<workspace_root>/.symphony-state/retries/<safe>.json`.
  Writes are atomic (temp file + rename). Corrupt or ambiguous state must
  fail closed: callers treat read errors as PARKED-like (claim, no timer).
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

  defp route_name(:fallback), do: "fallback"
  defp route_name(_route), do: "primary"

  defp primary_failure_count(count) when is_integer(count) and count >= 0, do: count
  defp primary_failure_count(_count), do: 0
end
