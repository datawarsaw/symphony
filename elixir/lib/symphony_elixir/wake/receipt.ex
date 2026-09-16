defmodule SymphonyElixir.Wake.Receipt do
  @moduledoc """
  Bounded MIC-10 wake receipt: the durable record of one wake-eligibility
  decision (Phase 4). `event_id` is a deterministic digest of the domain
  identity, so the same underlying fact observed before and after a restart
  carries the same id and dedup holds across restarts.
  """

  alias SymphonyElixir.Wake.Event

  @type status :: :pending | :handled | :stale | :superseded

  defstruct [
    :event_id,
    :identity,
    :issue_id,
    :attempt_id,
    :kind,
    :observed_at,
    :source,
    :actionable,
    :decision_required,
    :status,
    :handled_at
  ]

  @type t :: %__MODULE__{
          event_id: String.t(),
          identity: String.t(),
          issue_id: String.t() | nil,
          attempt_id: String.t() | nil,
          kind: Event.kind(),
          observed_at: DateTime.t(),
          source: atom(),
          actionable: boolean(),
          decision_required: boolean(),
          status: status(),
          handled_at: DateTime.t() | nil
        }

  @spec build(keyword()) :: t()
  def build(attrs) when is_list(attrs) do
    classification = Keyword.fetch!(attrs, :classification)
    identity = Keyword.fetch!(attrs, :identity)

    %__MODULE__{
      event_id: event_id(identity),
      identity: identity,
      issue_id: Keyword.get(attrs, :issue_id),
      attempt_id: Keyword.get(attrs, :attempt_id),
      kind: Keyword.fetch!(attrs, :kind),
      observed_at: Keyword.get(attrs, :observed_at, DateTime.utc_now()),
      source: Keyword.get(attrs, :source, :orchestrator),
      actionable: classification == :actionable,
      decision_required: classification == :human,
      status: :pending,
      handled_at: nil
    }
  end

  @spec event_id(String.t()) :: String.t()
  def event_id(identity) when is_binary(identity) do
    :crypto.hash(:sha256, identity)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = receipt) do
    %{
      "event_id" => receipt.event_id,
      "identity" => receipt.identity,
      "issue_id" => receipt.issue_id,
      "attempt_id" => receipt.attempt_id,
      "kind" => to_string(receipt.kind),
      "observed_at" => to_iso8601(receipt.observed_at),
      "source" => to_string(receipt.source),
      "actionable" => receipt.actionable,
      "decision_required" => receipt.decision_required,
      "status" => to_string(receipt.status),
      "handled_at" => to_iso8601(receipt.handled_at)
    }
  end

  @spec from_map(map()) :: t() | nil
  def from_map(%{"event_id" => event_id, "identity" => identity} = map)
      when is_binary(event_id) and is_binary(identity) do
    %__MODULE__{
      event_id: event_id,
      identity: identity,
      issue_id: map["issue_id"],
      attempt_id: map["attempt_id"],
      kind: kind_from(map["kind"]),
      observed_at: from_iso8601(map["observed_at"]) || DateTime.utc_now(),
      source: source_from(map["source"]),
      actionable: map["actionable"] == true,
      decision_required: map["decision_required"] == true,
      status: status_from(map["status"]),
      handled_at: from_iso8601(map["handled_at"])
    }
  end

  def from_map(_), do: nil

  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = receipt) do
    %{
      event_id: receipt.event_id,
      issue_id: receipt.issue_id,
      attempt_id: receipt.attempt_id,
      kind: receipt.kind,
      observed_at: receipt.observed_at,
      source: receipt.source,
      actionable: receipt.actionable,
      decision_required: receipt.decision_required,
      status: receipt.status
    }
  end

  defp kind_from(name) do
    Enum.find(Event.kinds(), :poll_tick, fn kind -> to_string(kind) == name end)
  end

  defp status_from("pending"), do: :pending
  defp status_from("handled"), do: :handled
  defp status_from("stale"), do: :stale
  defp status_from("superseded"), do: :superseded
  defp status_from(_), do: :pending

  # Sources are produced only by this codebase, so never mint a new atom from
  # persisted data: an unknown or corrupt value degrades to :orchestrator.
  defp source_from(nil), do: :orchestrator

  defp source_from(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> :orchestrator
  end

  defp to_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp to_iso8601(nil), do: nil
  defp to_iso8601(other), do: other

  defp from_iso8601(nil), do: nil

  defp from_iso8601(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp from_iso8601(other), do: other
end
