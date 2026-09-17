defmodule SymphonyElixir.Wake.Ledger do
  @moduledoc """
  Pure MIC-10 wake ledger: classifies observations, decides wake eligibility,
  dedups by stable domain identity, and reconciles across restarts.

  The ledger is a plain struct owned by the caller (the Orchestrator keeps it
  in its `State`), so observing an event adds no process, no message hop, and
  no new supervision — only a bounded receipt write for actionable and
  human-owned events. Deterministic and observed events are counted and
  logged, never persisted and never woken.

  Verdicts returned by `observe/4`:

    * `{:wake, receipt}`                       — actionable, first observation
    * `{:suppress, receipt, :duplicate}`       — identity already pending or handled
    * `{:suppress, receipt, :deterministic}`   — runtime handles it without reasoning
    * `{:suppress, receipt, :human_owned}`     — decision_required, surfaced not woken
    * `{:suppress, receipt, :non_actionable}`  — telemetry only
    * `{:suppress, receipt, :stale}`           — identity was already reconciled away
  """

  require Logger

  alias SymphonyElixir.Wake.{Event, Receipt, Store}

  defstruct root: nil,
            issues: %{},
            stale_identities: %{},
            handled_count: 0,
            stale_count: 0,
            superseded_count: 0,
            suppressed: %{},
            last_event: nil,
            last_wake: nil

  @type t :: %__MODULE__{}

  @empty_suppressed %{duplicate: 0, non_actionable: 0, deterministic: 0, human_owned: 0, stale: 0}
  @empty_issue %{pending: %{}, handled: %{}}

  @spec new(String.t() | nil) :: t()
  def new(root \\ nil), do: %__MODULE__{root: root}

  @doc """
  Rebuilds the ledger from durable receipts. Corrupt or unreadable issue
  records are skipped (fail-open to re-observation, never to a stuck wake).
  """
  @spec recover(String.t() | nil) :: t()
  def recover(nil), do: new()

  def recover(root) do
    issues =
      root
      |> Store.list_issue_ids()
      |> Enum.reduce(%{}, fn issue_id, acc ->
        case Store.read_issue(root, issue_id) do
          {:ok, %{issue_id: record_issue_id, pending: pending, handled: handled}} ->
            Map.put(acc, record_issue_id || issue_id, %{pending: Map.new(pending, &{&1.event_id, &1}), handled: handled})

          {:error, reason} ->
            Logger.warning("Wake ledger skipping unreadable record for issue_id=#{issue_id}: #{inspect(reason)}")
            acc
        end
      end)

    %__MODULE__{root: root, issues: issues}
  end

  @doc """
  Observes one runtime occurrence. Returns `{ledger, verdict}`; see the
  module doc for verdict shapes. Unknown event kinds raise: the taxonomy is
  bounded and a mislabeled producer must fail loudly instead of silently
  never waking.
  """
  @spec observe(t(), Event.kind(), String.t() | nil, keyword()) :: {t(), term()}
  def observe(%__MODULE__{} = ledger, kind, issue_id, opts \\ []) do
    classification = Event.classify(kind, opts)
    identity = Event.identity(kind, issue_id, opts)

    receipt =
      Receipt.build(
        classification: classification,
        identity: identity,
        kind: kind,
        issue_id: issue_id,
        attempt_id: Keyword.get(opts, :attempt_id),
        source: Keyword.get(opts, :source, :orchestrator)
      )

    issue = Map.get(ledger.issues, issue_id, @empty_issue)

    cond do
      classification == :observed ->
        verdict = {:suppress, receipt, :non_actionable}
        {record_event(ledger, receipt, verdict), verdict}

      Map.has_key?(issue.pending, receipt.event_id) or Map.has_key?(issue.handled, identity) ->
        verdict = {:suppress, receipt, :duplicate}
        {record_event(ledger, receipt, verdict), verdict}

      MapSet.member?(Map.get(ledger.stale_identities, issue_id, MapSet.new()), identity) ->
        verdict = {:suppress, receipt, :stale}
        {record_event(ledger, receipt, verdict), verdict}

      true ->
        {issue, superseded} = supersede_same_kind(issue, kind, receipt.event_id)
        issue = %{issue | pending: Map.put(issue.pending, receipt.event_id, receipt)}

        ledger = %{
          ledger
          | issues: Map.put(ledger.issues, issue_id, issue),
            superseded_count: ledger.superseded_count + superseded
        }

        ledger = persist(ledger, issue_id)

        verdict =
          case classification do
            :actionable -> {:wake, receipt}
            :deterministic -> {:suppress, receipt, :deterministic}
            :human -> {:suppress, receipt, :human_owned}
          end

        {record_event(ledger, receipt, verdict), verdict}
    end
  end

  @doc """
  Marks one pending event handled (its reasoning or deterministic
  continuation is done). The handled identity stays in the ledger so a repeat
  observation of the same underlying fact dedups instead of waking again.
  """
  @spec mark_handled(t(), String.t()) :: {t(), :ok | :not_found}
  def mark_handled(%__MODULE__{} = ledger, event_id) when is_binary(event_id) do
    found =
      Enum.find_value(ledger.issues, fn {issue_id, issue} ->
        case Map.get(issue.pending, event_id) do
          nil -> nil
          receipt -> {issue_id, receipt}
        end
      end)

    case found do
      nil ->
        {ledger, :not_found}

      {issue_id, receipt} ->
        issue = complete_pending(Map.get(ledger.issues, issue_id, @empty_issue), receipt)

        ledger = %{
          ledger
          | issues: Map.put(ledger.issues, issue_id, issue),
            handled_count: ledger.handled_count + 1
        }

        {persist(ledger, issue_id), :ok}
    end
  end

  @doc """
  Marks every pending event of one issue handled — used when the issue leaves
  the runtime's live sets (claim release), which resolves whatever the issue
  was waiting on.
  """
  @spec mark_issue_handled(t(), String.t()) :: {t(), non_neg_integer()}
  def mark_issue_handled(%__MODULE__{} = ledger, issue_id) do
    issue = Map.get(ledger.issues, issue_id, @empty_issue)

    case Map.keys(issue.pending) do
      [] ->
        {ledger, 0}

      event_ids ->
        count = length(event_ids)

        issue =
          issue.pending
          |> Map.values()
          |> Enum.reduce(issue, &complete_pending(&2, &1))

        ledger = %{
          ledger
          | issues: Map.put(ledger.issues, issue_id, issue),
            handled_count: ledger.handled_count + count
        }

        {persist(ledger, issue_id), count}
    end
  end

  @doc """
  Restart/poll reconciliation: pending receipts whose issue is no longer in
  the live domain sets are stale — the underlying evidence is obsolete — so
  they neither wake nor block a future wake from fresh evidence. Their
  identities are remembered as stale so the obsolete fact cannot wake later.
  """
  @spec reconcile(t(), Enumerable.t()) :: {t(), non_neg_integer()}
  def reconcile(%__MODULE__{} = ledger, live_issue_ids) do
    live = MapSet.new(live_issue_ids)

    ledger.issues
    |> Enum.filter(fn {issue_id, issue} ->
      map_size(issue.pending) > 0 and not MapSet.member?(live, issue_id)
    end)
    |> Enum.reduce({ledger, 0}, fn {issue_id, issue}, {ledger_acc, stale_total} ->
      stale_receipts = Map.values(issue.pending)

      issue = %{issue | pending: %{}}

      stale_identities =
        ledger_acc.stale_identities
        |> Map.get(issue_id, MapSet.new())
        |> MapSet.union(MapSet.new(stale_receipts, & &1.identity))

      ledger_acc = %{
        ledger_acc
        | issues: Map.put(ledger_acc.issues, issue_id, issue),
          stale_identities: Map.put(ledger_acc.stale_identities, issue_id, stale_identities),
          stale_count: ledger_acc.stale_count + length(stale_receipts)
      }

      ledger_acc = persist(ledger_acc, issue_id)
      {ledger_acc, stale_total + length(stale_receipts)}
    end)
    |> then(fn {ledger_acc, stale_total} ->
      {prune_stale_identities(ledger_acc, live), stale_total}
    end)
  end

  @doc """
  Operator/observability projection: last event, pending actionable events,
  pending human decisions, handled/stale/superseded counters, dedup counters,
  and the reason the last wake was or was not emitted.
  """
  @spec snapshot(t() | nil) :: map()
  def snapshot(nil), do: empty_snapshot()

  def snapshot(%__MODULE__{} = ledger) do
    pending =
      ledger.issues
      |> Enum.flat_map(fn {_issue_id, issue} -> Map.values(issue.pending) end)
      |> Enum.sort_by(&DateTime.to_unix(&1.observed_at))

    summaries = Enum.map(pending, &Receipt.summary/1)

    %{
      last_event: ledger.last_event,
      last_wake: ledger.last_wake,
      pending_actionable: Enum.filter(summaries, & &1.actionable),
      pending_decisions: Enum.filter(summaries, & &1.decision_required),
      handled_count: ledger.handled_count,
      stale_count: ledger.stale_count,
      superseded_count: ledger.superseded_count,
      suppressed: Map.merge(@empty_suppressed, ledger.suppressed)
    }
  end

  # A newer observation of the same kind replaces an older pending one: the
  # older evidence is superseded and must not accumulate.
  defp supersede_same_kind(issue, kind, keep_event_id) do
    {kept, dropped} =
      Map.split_with(issue.pending, fn {_event_id, receipt} ->
        receipt.kind != kind or receipt.event_id == keep_event_id
      end)

    {%{issue | pending: kept}, map_size(dropped)}
  end

  defp complete_pending(issue, receipt) do
    %{
      issue
      | pending: Map.delete(issue.pending, receipt.event_id),
        handled: Map.put(issue.handled, receipt.identity, DateTime.utc_now())
    }
  end

  # Stale identities of issues that are live again can be observed fresh under
  # a new identity; the exact obsolete identities stay suppressed. Prune only
  # issues with no stale identities to keep memory bounded.
  defp prune_stale_identities(ledger, live) do
    stale_identities =
      ledger.stale_identities
      |> Enum.filter(fn {issue_id, _identities} -> not MapSet.member?(live, issue_id) end)
      |> Map.new()

    %{ledger | stale_identities: stale_identities}
  end

  defp record_event(ledger, receipt, {:suppress, _receipt, reason}) do
    ledger = %{
      ledger
      | last_event: %{
          event_id: receipt.event_id,
          issue_id: receipt.issue_id,
          kind: receipt.kind,
          observed_at: receipt.observed_at,
          outcome: :suppress,
          reason: reason
        }
    }

    record_outcome(ledger, reason)
  end

  defp record_event(ledger, receipt, {:wake, _receipt}) do
    %{
      ledger
      | last_event: %{
          event_id: receipt.event_id,
          issue_id: receipt.issue_id,
          kind: receipt.kind,
          observed_at: receipt.observed_at,
          outcome: :wake,
          reason: :actionable
        },
        last_wake: Receipt.summary(receipt)
    }
  end

  defp record_outcome(ledger, :wake), do: ledger

  defp record_outcome(ledger, reason) do
    %{ledger | suppressed: Map.update(ledger.suppressed, reason, 1, &(&1 + 1))}
  end

  defp persist(%__MODULE__{root: nil} = ledger, _issue_id), do: ledger

  defp persist(%__MODULE__{root: root} = ledger, issue_id) do
    issue = Map.get(ledger.issues, issue_id, @empty_issue)

    result =
      case {map_size(issue.pending), map_size(issue.handled)} do
        {0, 0} ->
          Store.delete_issue(root, issue_id)

        _ ->
          Store.write_issue(root, issue_id, %{pending: Map.values(issue.pending), handled: issue.handled})
      end

    case result do
      :ok ->
        :ok

      # Best-effort persistence: the in-memory ledger stays authoritative, the
      # failure is surfaced to operators, and no durable success is claimed. A
      # lost write can only cause a redundant wake after a restart (fail-open
      # observability); there is no retry loop and no timer.
      {:error, reason} ->
        Logger.warning("Wake persistence degraded (best-effort continues in memory): issue_id=#{issue_id} reason=#{inspect(reason)}")
    end

    ledger
  end

  defp empty_snapshot do
    %{
      last_event: nil,
      last_wake: nil,
      pending_actionable: [],
      pending_decisions: [],
      handled_count: 0,
      stale_count: 0,
      superseded_count: 0,
      suppressed: @empty_suppressed
    }
  end
end
