defmodule SymphonyElixir.RetryPolicy do
  @moduledoc """
  Pure, stateless, deterministic retry/park policy for already-classified
  worker failures (MIC-195 A0).

  RetryPolicy owns the bounded failure envelope: retry vs park, the envelope
  stop reason, the bounded-envelope history fold, and the failure backoff
  formula. It is free of timers, filesystem I/O, tracker calls, process
  inspection, and Orchestrator state mutation.

  Slice C adds the pure fallback route policy to the same authority: the
  fallback-eligible failure classes, the per-class thresholds of consecutive
  eligible primary failures, the primary→fallback route fold, and the
  pin/opt-in permission rule (`fallback_eligible_class?/1`,
  `update_route_state/2`, `fallback_route_decision/3`, `pin_permits_fallback?/2`).
  The decision consumes only already-classified failures and caller-supplied
  gate results; it never reads config or performs I/O.

  Failure classification remains owned by `SymphonyElixir.FailureClass`;
  this module consumes already-classified failure information and never
  parses raw app-server errors. The Orchestrator keeps the process concerns
  (concurrency, timers, claims, running workers, supervision) and persists
  durable state through `SymphonyElixir.RetryStore`.

  Note on the delay: the wall-clock timer delay is scheduling state owned by
  the Orchestrator (its dispatch-attempt lineage lives in the retry table,
  not in the envelope history). The backoff formula itself lives in
  `backoff_delay/3`, which is the single production authority for failure
  backoff; the Orchestrator's scheduler calls it and never reimplements it.
  """

  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.FailureClass

  @max_attempts 10
  @max_age_ms 2 * 60 * 60 * 1_000
  @max_identical 3
  @retry_base_ms 10_000

  @type stop_reason :: :max_attempts | :max_age | :max_identical | :auth_unavailable
  @type decision :: {:retry, map()} | {:park, stop_reason(), map()}

  # ── MIC-195 Slice C: fallback route policy ─────────────────────────────────
  #
  # The fallback route decision is pure: the Orchestrator classifies the
  # failure, folds the durable route state, evaluates the config/pin gates,
  # and persists the result. This module owns the single authority for the
  # eligible classes, the per-class thresholds, the consecutive eligible
  # primary-failure fold, and the pin/opt-in permission rule. It never reads
  # config, performs I/O, spawns, or touches Orchestrator state.

  @fallback_eligible_classes [:model_unavailable, :provider_quota, :provider_rate_limit, :provider_outage]

  @fallback_thresholds %{
    model_unavailable: 1,
    provider_quota: 2,
    provider_rate_limit: 2,
    provider_outage: 2
  }

  @type route :: :primary | :fallback
  @type route_state :: %{route: route(), primary_failure_count: non_neg_integer()}
  @type fallback_opt_in :: :none | :opt_in | :opt_out | :ambiguous
  @type route_decision :: {:switch_to_fallback, route_state()} | {:stay_primary, route_state()} | {:stay_fallback, route_state()}

  @doc "Maximum automatic failure attempts before parking."
  @spec max_attempts() :: pos_integer()
  def max_attempts, do: @max_attempts

  @doc "Maximum retry age in milliseconds before parking."
  @spec max_age_ms() :: pos_integer()
  def max_age_ms, do: @max_age_ms

  @doc "Maximum identical consecutive technical failures before parking."
  @spec max_identical() :: pos_integer()
  def max_identical, do: @max_identical

  @doc "Base failure backoff in milliseconds (existing exponential schedule)."
  @spec retry_base_ms() :: pos_integer()
  def retry_base_ms, do: @retry_base_ms

  @doc "True when the class must park immediately without automatic retry."
  @spec park_immediately?(FailureClass.t()) :: boolean()
  def park_immediately?(:auth_unavailable), do: true
  def park_immediately?(_class), do: false

  @doc "True when any bounded-envelope stop condition holds."
  @spec should_stop?(term(), term(), term()) :: boolean()
  def should_stop?(attempt_count, age_ms, identical_count) do
    stop_reason(attempt_count, age_ms, identical_count) != :ok
  end

  @doc "Envelope stop reason, or :ok when retries may continue."
  @spec stop_reason(term(), term(), term()) :: :ok | {:stop, :max_attempts | :max_age | :max_identical}
  def stop_reason(attempt_count, age_ms, identical_count) do
    cond do
      is_integer(attempt_count) and attempt_count >= @max_attempts -> {:stop, :max_attempts}
      is_integer(age_ms) and age_ms >= @max_age_ms -> {:stop, :max_age}
      is_integer(identical_count) and identical_count >= @max_identical -> {:stop, :max_identical}
      true -> :ok
    end
  end

  @doc """
  Evaluate the bounded failure envelope for an already-classified failure.

  `metadata` keys:

    * `:failure_class` — canonical failure class atom or serialized class
      name for the failure being evaluated. Raw errors are never classified
      here; unknown values only decode through the FailureClass taxonomy and
      fall back to the transient class.
    * `:history` — prior bounded-envelope history map for the issue, or nil.
    * `:now_ms` — monotonic millisecond timestamp of this failure. Required;
      passing the clock reading explicitly keeps the evaluation deterministic.
    * `:reset_in_ms` — provider-provided reset timing when explicitly and
      reliably available (already extracted from the failure payload).

  Returns `{:retry, updated_history}` when the envelope allows another
  automatic failure retry, or `{:park, stop_reason, updated_history}` when
  the issue must park. The updated history carries the folded attempt and
  identical-failure counters for the Orchestrator to persist.
  """
  @spec evaluate(map()) :: decision()
  def evaluate(metadata) when is_map(metadata) do
    failure_class = FailureClass.normalize_class(Map.get(metadata, :failure_class))
    now_ms = Map.fetch!(metadata, :now_ms)
    history = update_history(Map.get(metadata, :history), failure_class, now_ms)
    age_ms = now_ms - Map.get(history, :first_failure_at_ms, now_ms)

    cond do
      park_immediately?(failure_class) ->
        {:park, :auth_unavailable, history}

      true ->
        case stop_reason(history.attempt_count, age_ms, history.identical_failure_count) do
          :ok -> {:retry, history}
          {:stop, stop_reason} -> {:park, stop_reason, history}
        end
    end
  end

  @doc "Fold a new classified failure into the bounded-envelope history."
  @spec update_history(map() | nil, FailureClass.t(), integer()) :: map()
  def update_history(nil, failure_class, now_ms) do
    %{
      attempt_count: 1,
      identical_failure_count: 1,
      first_failure_at_ms: now_ms,
      last_failure_at_ms: now_ms,
      last_failure_class: failure_class
    }
  end

  def update_history(history, failure_class, now_ms) when is_map(history) do
    previous_class = Map.get(history, :last_failure_class)
    previous_identical = Map.get(history, :identical_failure_count, 0)
    identical = if previous_class == failure_class, do: previous_identical + 1, else: 1

    %{
      attempt_count: Map.get(history, :attempt_count, 0) + 1,
      identical_failure_count: identical,
      first_failure_at_ms: Map.get(history, :first_failure_at_ms, now_ms),
      last_failure_at_ms: now_ms,
      last_failure_class: failure_class
    }
  end

  def update_history(_history, failure_class, now_ms), do: update_history(nil, failure_class, now_ms)

  @doc "Reset the identical-consecutive counter after a successful continuation turn."
  @spec reset_identical(map()) :: map()
  def reset_identical(history) when is_map(history) do
    Map.put(history, :identical_failure_count, 0)
  end

  def reset_identical(_history), do: %{identical_failure_count: 0}

  @doc """
  Failure backoff (base 10s, doubling, capped at max_ms). When provider reset
  timing is reliably available it is honored as a floor: the delay never lands
  before the reset. Retry-After values are never invented.
  """
  @spec backoff_delay(term(), pos_integer(), integer() | nil) :: pos_integer()
  def backoff_delay(attempt, max_ms, reset_in_ms \\ nil) do
    safe_attempt = if is_integer(attempt) and attempt > 0, do: attempt, else: 1
    exponential = min(@retry_base_ms * (1 <<< min(safe_attempt - 1, 10)), max_ms)
    if is_integer(reset_in_ms) and reset_in_ms > exponential, do: reset_in_ms, else: exponential
  end

  @doc "Failure classes eligible for automatic primary→fallback routing (exact set, closed for extension)."
  @spec fallback_eligible_classes() :: [FailureClass.t(), ...]
  def fallback_eligible_classes, do: @fallback_eligible_classes

  @doc "True when the class may trigger automatic fallback."
  @spec fallback_eligible_class?(FailureClass.t()) :: boolean()
  def fallback_eligible_class?(class), do: class in @fallback_eligible_classes

  @doc """
  Consecutive eligible primary failures required before switching to fallback
  for the class, or nil when the class is not fallback-eligible.
  """
  @spec fallback_threshold(FailureClass.t()) :: pos_integer() | nil
  def fallback_threshold(class) when class in @fallback_eligible_classes, do: Map.fetch!(@fallback_thresholds, class)
  def fallback_threshold(_class), do: nil

  @doc "Route state for a fresh failure sequence."
  @spec new_route_state() :: route_state()
  def new_route_state, do: %{route: :primary, primary_failure_count: 0}

  @doc """
  Fold one classified failure into the consecutive eligible-primary-failure count.

  * eligible failure while route == primary → increment `primary_failure_count`;
  * ineligible failure while route == primary → reset the count to 0 (the
    consecutive eligible-primary sequence is terminated);
  * any failure while route == fallback → count unchanged (fallback failures
    never increment it and the latch never folds back to primary).

  The count is diagnostic after the switch: it is preserved, not incremented,
  for the rest of the failure sequence.
  """
  @spec update_route_state(route_state() | nil, FailureClass.t()) :: route_state()
  def update_route_state(nil, failure_class), do: update_route_state(new_route_state(), failure_class)

  def update_route_state(route_state, failure_class) when is_map(route_state) do
    case Map.get(route_state, :route, :primary) do
      :fallback ->
        route_state

      _primary ->
        count = Map.get(route_state, :primary_failure_count, 0)
        next_count = if fallback_eligible_class?(failure_class), do: count + 1, else: 0
        route_state |> Map.put(:route, :primary) |> Map.put(:primary_failure_count, next_count)
    end
  end

  def update_route_state(_route_state, failure_class), do: update_route_state(new_route_state(), failure_class)

  @doc """
  Decide the route of the NEXT attempt after a classified failure was folded
  into `route_state` (fold first via `update_route_state/2`).

  Options:

    * `:pinned` — true when the failing dispatch carried an explicit
      model/reasoning pin.
    * `:fallback_opt_in` — parsed explicit fallback opt-in (`fallback_opt_in/1`).
    * `:fallback_available` — true when the caller verified the fallback seam
      is enabled with a valid model/reasoning pair (the Orchestrator probes
      this through `DispatchRouter.materialize/3`; config never crosses this
      boundary).

  Rules:

    * route == :fallback → `{:stay_fallback, route_state}` — the latch holds
      for the whole failure sequence; fallback never routes back to primary.
    * otherwise `{:switch_to_fallback, ...}` only when the class is eligible,
      the per-class threshold of consecutive eligible primary failures is
      reached, the fallback seam is available, and the pin policy permits;
    * every other case → `{:stay_primary, route_state}`.
  """
  @spec fallback_route_decision(route_state(), FailureClass.t(), keyword()) :: route_decision()
  def fallback_route_decision(route_state, failure_class, opts \\ []) when is_list(opts) do
    case Map.get(route_state, :route, :primary) do
      :fallback ->
        {:stay_fallback, route_state}

      _primary ->
        if switch_eligible?(route_state, failure_class, opts) do
          {:switch_to_fallback, Map.put(route_state, :route, :fallback)}
        else
          {:stay_primary, Map.put(route_state, :route, :primary)}
        end
    end
  end

  defp switch_eligible?(route_state, failure_class, opts) do
    fallback_eligible_class?(failure_class) and
      Map.get(route_state, :primary_failure_count, 0) >= fallback_threshold(failure_class) and
      Keyword.get(opts, :fallback_available, false) and
      pin_permits_fallback?(Keyword.get(opts, :pinned, false), Keyword.get(opts, :fallback_opt_in, :none))
  end

  @doc """
  Whether an explicit pin permits automatic fallback.

  * ambiguous or explicit `false` opt-in → never (fail closed);
  * pinned without an explicit `fallback: true` opt-in → never (a pin is never
    silently overridden and the opt-in is never inferred);
  * pinned with an explicit opt-in → permitted;
  * unpinned → permitted.
  """
  @spec pin_permits_fallback?(boolean(), fallback_opt_in()) :: boolean()
  def pin_permits_fallback?(_pinned, :ambiguous), do: false
  def pin_permits_fallback?(_pinned, :opt_out), do: false
  def pin_permits_fallback?(true, :opt_in), do: true
  def pin_permits_fallback?(true, _none), do: false
  def pin_permits_fallback?(false, _opt_in), do: true

  @doc """
  Parse the explicit fallback opt-in from an issue's labels.

  Exactly one `fallback:` label with value `true`/`false` (case-insensitive)
  parses to `:opt_in`/`:opt_out`. Any other value, an empty value, or more
  than one `fallback:` label is `:ambiguous` (fail closed). No `fallback:`
  label is `:none`; the opt-in is never inferred from anything else.
  """
  @spec fallback_opt_in(term()) :: fallback_opt_in()
  def fallback_opt_in(labels) when is_list(labels) do
    values =
      labels
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&String.starts_with?(String.downcase(&1), "fallback:"))
      |> Enum.map(fn label ->
        label |> String.slice(String.length("fallback:")..-1//1) |> String.trim() |> String.downcase()
      end)

    case values do
      [] -> :none
      [value] -> parse_opt_in_value(value)
      _multiple -> :ambiguous
    end
  end

  def fallback_opt_in(_labels), do: :none

  defp parse_opt_in_value("true"), do: :opt_in
  defp parse_opt_in_value("false"), do: :opt_out
  defp parse_opt_in_value(_other), do: :ambiguous
end
