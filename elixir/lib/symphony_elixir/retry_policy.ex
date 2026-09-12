defmodule SymphonyElixir.RetryPolicy do
  @moduledoc """
  Pure, stateless, deterministic retry/park policy for already-classified
  worker failures (MIC-195 A0).

  RetryPolicy owns the bounded failure envelope: retry vs park, the envelope
  stop reason, the bounded-envelope history fold, and the failure backoff
  formula. It is free of timers, filesystem I/O, tracker calls, process
  inspection, and Orchestrator state mutation.

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
end
