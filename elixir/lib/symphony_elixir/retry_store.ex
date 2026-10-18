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

  @spec write_record(String.t(), map()) :: :ok | {:error, term()}
  def write_record(workspace_root, record) when is_map(record) do
    with :ok <- validate_record(record),
         {:ok, payload} <- Jason.encode(record, pretty: true),
         :ok <- File.mkdir_p(retries_dir(workspace_root)),
         :ok <- ensure_replaceable(record_path(workspace_root, record["issue_id"]), record["issue_id"]) do
      path = record_path(workspace_root, record["issue_id"])
      write_atomically(path, payload)
    end
  end

  @spec delete_record(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_record(workspace_root, issue_id) do
    case read_record(workspace_root, issue_id) do
      {:ok, _record} -> File.rm(record_path(workspace_root, issue_id))
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, {:record_delete_refused, reason}}
    end
  end

  @spec read_record(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def read_record(workspace_root, issue_id) do
    path = record_path(workspace_root, issue_id)

    case File.read(path) do
      {:ok, raw} ->
        case decode_record(raw) do
          {:ok, %{"issue_id" => ^issue_id} = record} -> {:ok, record}
          {:ok, _record} -> {:error, :identity_mismatch}
          {:error, reason} -> {:error, reason}
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, _} ->
        {:error, :unreadable_state}
    end
  end

  @spec list_records(String.t()) :: {:ok, [{String.t(), {:ok, map()} | {:error, term()}}]} | {:error, term()}
  def list_records(workspace_root) do
    case File.ls(retries_dir(workspace_root)) do
      {:ok, names} ->
        records =
          names
          |> Enum.filter(&String.ends_with?(&1, ".json"))
          |> Enum.map(fn name ->
            issue_id = String.trim_trailing(name, ".json")
            {issue_id, read_record_by_file(workspace_root, name)}
          end)

        {:ok, records}

      {:error, :enoent} ->
        if absent_directory?(retries_dir(workspace_root)),
          do: {:ok, []},
          else: {:error, {:retry_directory_unreadable, :enoent}}

      {:error, reason} ->
        {:error, {:retry_directory_unreadable, reason}}
    end
  end

  # Windows can report ENOENT for a path below a regular file. That is
  # inaccessible state, not evidence that a retry directory never existed.
  defp absent_directory?(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        parent = Path.dirname(path)
        parent != path and absent_directory?(parent)

      {:ok, %{type: :directory}} ->
        true

      _ ->
        false
    end
  end

  @spec read_record_by_file(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  defp read_record_by_file(workspace_root, name) do
    path = Path.join(retries_dir(workspace_root), name)
    file_id = String.trim_trailing(name, ".json")

    case File.read(path) do
      {:ok, raw} ->
        case decode_record(raw) do
          {:ok, %{"issue_id" => issue_id} = record} ->
            if safe_issue_id(issue_id) == file_id, do: {:ok, record}, else: {:error, :identity_mismatch}

          {:ok, _record} ->
            {:error, :identity_mismatch}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, _} ->
        {:error, :unreadable_state}
    end
  end

  @spec build_record(map()) :: map()
  def build_record(attrs) when is_map(attrs) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    first_failure_at = Map.get(attrs, :first_failure_at) || now

    %{
      "schema_version" => @schema_version,
      "issue_id" => Map.fetch!(attrs, :issue_id),
      "identifier" => Map.get(attrs, :identifier, ""),
      "status" => Map.fetch!(attrs, :status),
      "failure_class" => Map.fetch!(attrs, :failure_class),
      "attempt_count" => Map.get(attrs, :attempt_count, 0),
      "identical_failure_count" => Map.get(attrs, :identical_failure_count, 1),
      "first_failure_at" => first_failure_at,
      "last_failure_at" => Map.get(attrs, :last_failure_at) || first_failure_at,
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

  defp write_atomically(path, payload) do
    tmp = path <> "." <> Integer.to_string(:erlang.unique_integer([:positive])) <> ".tmp"

    with {:ok, io} <- File.open(tmp, [:write, :exclusive, :binary]),
         :ok <- write_and_sync(io, payload),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, {:retry_record_write_failed, reason}}
    end
  end

  defp write_and_sync(io, payload) do
    case IO.binwrite(io, payload) do
      :ok ->
        sync_result = :file.sync(io)
        close_result = File.close(io)

        case {sync_result, close_result} do
          {:ok, :ok} -> :ok
          {{:error, reason}, _} -> {:error, reason}
          {:ok, {:error, reason}} -> {:error, reason}
        end

      {:error, reason} ->
        _ = File.close(io)
        {:error, reason}
    end
  end

  defp ensure_replaceable(path, issue_id) do
    case File.read(path) do
      {:error, :enoent} ->
        :ok

      {:ok, raw} ->
        case decode_record(raw) do
          {:ok, %{"issue_id" => ^issue_id}} -> :ok
          _ -> {:error, :existing_record_untrusted}
        end

      {:error, _reason} ->
        {:error, :existing_record_untrusted}
    end
  end

  defp decode_record(raw) do
    with {:ok, record} <- Jason.decode(raw),
         :ok <- validate_record(record) do
      {:ok, record}
    else
      {:error, %Jason.DecodeError{}} -> {:error, :corrupt_state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_record(
         %{
           "schema_version" => @schema_version,
           "issue_id" => issue_id,
           "status" => status,
           "failure_class" => failure_class,
           "attempt_count" => attempt_count,
           "identical_failure_count" => identical_failure_count,
           "first_failure_at" => first_failure_at,
           "last_failure_at" => last_failure_at
         } = record
       )
       when is_binary(issue_id) and byte_size(issue_id) > 0 and status in ["retrying", "parked"] and
              is_binary(failure_class) and byte_size(failure_class) > 0 and is_integer(attempt_count) and
              attempt_count >= 0 and is_integer(identical_failure_count) and identical_failure_count >= 1 do
    with {:ok, first_dt} <- parse_time(first_failure_at),
         {:ok, last_dt} <- parse_time(last_failure_at),
         :ok <- validate_timestamp_order(first_dt, last_dt),
         :ok <- validate_optional_time(Map.get(record, "next_retry_at")),
         :ok <- validate_route(record) do
      :ok
    end
  end

  defp validate_record(_record), do: {:error, :ambiguous_state}

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> {:error, :ambiguous_state}
    end
  end

  defp parse_time(_value), do: {:error, :ambiguous_state}

  defp validate_timestamp_order(first_dt, last_dt) do
    if DateTime.compare(first_dt, last_dt) in [:lt, :eq], do: :ok, else: {:error, :ambiguous_state}
  end

  defp validate_optional_time(nil), do: :ok

  defp validate_optional_time(value),
    do:
      parse_time(value)
      |> then(fn
        {:ok, _datetime} -> :ok
        error -> error
      end)

  defp validate_route(record) do
    case {Map.get(record, "route", "primary"), Map.get(record, "primary_failure_count", 0)} do
      {route, count} when route in ["primary", "fallback"] and is_integer(count) and count >= 0 -> :ok
      _ -> {:error, :ambiguous_state}
    end
  end
end
