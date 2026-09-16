defmodule SymphonyElixir.SteeringStore do
  @moduledoc """
  Durable JSON store for operator steering records.

  One file per steer under `<workspace_root>/.symphony-state/steering/<safe>.json`.
  Writes are atomic (temp file + rename). Records follow the RetryStore
  conventions: schema_version 1, string-keyed maps, fail-closed reads —
  a record that cannot be parsed is reported as an error, never silently
  reinterpreted.
  """

  @schema_version 1

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec steering_dir(String.t()) :: String.t()
  def steering_dir(workspace_root), do: Path.join([workspace_root, ".symphony-state", "steering"])

  @spec safe_steer_id(String.t()) :: String.t()
  def safe_steer_id(steer_id) do
    steer_id |> String.downcase() |> String.replace(~r/[^a-z0-9_-]/, "_") |> String.slice(0, 128)
  end

  @spec record_path(String.t(), String.t()) :: String.t()
  def record_path(workspace_root, steer_id) do
    Path.join(steering_dir(workspace_root), safe_steer_id(steer_id) <> ".json")
  end

  @spec write_record(String.t(), map()) :: :ok
  def write_record(workspace_root, record) when is_map(record) do
    dir = steering_dir(workspace_root)
    File.mkdir_p!(dir)
    steer_id = Map.fetch!(record, "steer_id")
    path = record_path(workspace_root, steer_id)
    tmp = path <> "." <> Integer.to_string(:erlang.unique_integer([:positive])) <> ".tmp"
    payload = Jason.encode!(Map.put_new(record, "schema_version", @schema_version), pretty: true)
    File.write!(tmp, payload)
    File.rename!(tmp, path)
    :ok
  end

  @spec read_record(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def read_record(workspace_root, steer_id) do
    read_record_by_file(record_path(workspace_root, steer_id))
  end

  @spec list_records(String.t()) :: [{String.t(), {:ok, map()} | {:error, atom()}}]
  def list_records(workspace_root) do
    case File.ls(steering_dir(workspace_root)) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(fn name ->
          steer_id = String.trim_trailing(name, ".json")
          {steer_id, read_record_by_file(Path.join(steering_dir(workspace_root), name))}
        end)

      {:error, _} ->
        []
    end
  end

  @spec read_record_by_file(String.t()) :: {:ok, map()} | {:error, atom()}
  def read_record_by_file(path) do
    case File.read(path) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, %{"schema_version" => 1, "steer_id" => steer_id} = record} when is_binary(steer_id) ->
            {:ok, record}

          {:ok, _} ->
            {:error, :ambiguous_state}

          {:error, _} ->
            {:error, :corrupt_state}
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, _} ->
        {:error, :unreadable_state}
    end
  end
end
