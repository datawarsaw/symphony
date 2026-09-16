defmodule SymphonyElixir.Wake.Store do
  @moduledoc """
  Durable JSON store for MIC-10 wake receipts, reusing the RetryStore pattern:
  one atomic (temp file + rename) file per issue under
  `<workspace_root>/.symphony-state/wakes/`.

  The store is bounded by design: pending receipts are capped at one per issue
  and event kind (a newer observation of the same kind supersedes the older
  one), and handled identities are capped at
  `@max_handled_identities_per_issue` with oldest-first eviction. This is not
  a general event store — it holds exactly the state needed for dedup and
  restart reconciliation of wake decisions.

  Read failures degrade to "no record" rather than raising: a lost suppression
  can only cause a redundant wake, which the runtime handles deterministically,
  while a raised error would take down scheduling. Write failures follow the
  same best-effort philosophy: `write_issue/3` returns `{:error, reason}`
  instead of raising, so a wake-store outage cannot crash the Orchestrator; the
  ledger keeps its in-memory state authoritative and logs the degradation, and
  no durable success is claimed on error.
  """

  alias SymphonyElixir.RetryStore
  alias SymphonyElixir.Wake.Receipt

  @schema_version 1
  @max_handled_identities_per_issue 64

  @spec wakes_dir(String.t()) :: String.t()
  def wakes_dir(workspace_root), do: Path.join([workspace_root, ".symphony-state", "wakes"])

  @spec issue_path(String.t(), String.t()) :: String.t()
  def issue_path(workspace_root, issue_id) do
    Path.join(wakes_dir(workspace_root), RetryStore.safe_issue_id(issue_id) <> ".json")
  end

  @type issue_record :: %{issue_id: String.t() | nil, pending: [Receipt.t()], handled: %{String.t() => DateTime.t()}}

  @spec write_issue(String.t(), String.t(), issue_record()) :: :ok | {:error, term()}
  def write_issue(workspace_root, issue_id, %{pending: pending, handled: handled}) do
    with :ok <- File.mkdir_p(wakes_dir(workspace_root)),
         {:ok, payload} <- encode_issue(issue_id, pending, handled) do
      atomic_write(workspace_root, issue_id, payload)
    end
  end

  defp encode_issue(issue_id, pending, handled) do
    record = %{
      "schema_version" => @schema_version,
      "issue_id" => issue_id,
      "pending" => Enum.map(pending, &Receipt.to_map/1),
      "handled" => handled |> cap_handled() |> Map.new(fn {identity, at} -> {identity, to_iso8601(at)} end)
    }

    Jason.encode(record, pretty: true)
  end

  defp atomic_write(workspace_root, issue_id, payload) do
    path = issue_path(workspace_root, issue_id)
    tmp = path <> "." <> Integer.to_string(:erlang.unique_integer([:positive])) <> ".tmp"

    with :ok <- File.write(tmp, payload),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, reason}
    end
  end

  @spec read_issue(String.t(), String.t()) :: {:ok, issue_record()} | {:error, atom()}
  def read_issue(workspace_root, issue_id) do
    case File.read(issue_path(workspace_root, issue_id)) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, %{"schema_version" => @schema_version} = record} -> {:ok, decode_record(record)}
          {:ok, _} -> {:error, :ambiguous_state}
          {:error, _} -> {:error, :corrupt_state}
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, _} ->
        {:error, :unreadable_state}
    end
  end

  @spec delete_issue(String.t(), String.t()) :: :ok
  def delete_issue(workspace_root, issue_id) do
    _ = File.rm(issue_path(workspace_root, issue_id))
    :ok
  end

  @spec list_issue_ids(String.t()) :: [String.t()]
  def list_issue_ids(workspace_root) do
    case File.ls(wakes_dir(workspace_root)) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(&String.trim_trailing(&1, ".json"))

      {:error, _} ->
        []
    end
  end

  defp decode_record(record) do
    pending =
      record
      |> Map.get("pending", [])
      |> Enum.map(&Receipt.from_map/1)
      |> Enum.reject(&is_nil/1)

    handled =
      record
      |> Map.get("handled", %{})
      |> Enum.flat_map(fn {identity, iso} ->
        case DateTime.from_iso8601(iso || "") do
          {:ok, dt, _offset} -> [{identity, dt}]
          _ -> []
        end
      end)
      |> Map.new()

    # The original issue id (the filename is the safe downcased form), so the
    # recovered ledger is keyed exactly like in-memory observations.
    %{issue_id: record["issue_id"], pending: pending, handled: handled}
  end

  defp cap_handled(handled) when map_size(handled) <= @max_handled_identities_per_issue, do: handled

  defp cap_handled(handled) do
    handled
    |> Enum.sort_by(fn {identity, at} -> {to_unix(at), identity} end, :desc)
    |> Enum.take(@max_handled_identities_per_issue)
    |> Map.new()
  end

  defp to_unix(%DateTime{} = dt), do: DateTime.to_unix(dt)
  defp to_unix(nil), do: 0

  defp to_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp to_iso8601(nil), do: nil
end
