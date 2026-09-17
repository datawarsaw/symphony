defmodule SymphonyElixir.Wake.Event do
  @moduledoc """
  MIC-10 bounded wake-event taxonomy and classification.

  Every runtime occurrence that could justify supervisor reasoning is observed
  as exactly one event kind, and every kind classifies to exactly one of:

    * `:actionable`    — eligible to wake reasoning, at most once per identity
    * `:deterministic` — the runtime already handles it deterministically; never wakes
    * `:human`         — the decision belongs to an operator; surfaced, never auto-woken
    * `:observed`      — telemetry only; never wakes

  Kinds are only declared for producers that exist in this runtime. There is no
  `steer_ack_timeout` (no steer mechanism yet) and no dedicated review verdict
  kinds: review-lane states arrive as `tracker_state_changed` transitions and
  can be made actionable through `actionable_tracker_states/0` without
  introducing duplicate event semantics.
  """

  @actionable_kinds [:worker_failed, :worker_termination_unconfirmed, :eligibility_action_required]
  @deterministic_kinds [:worker_completed, :worker_stale]
  @human_kinds [:discovery_needs_decision, :human_decision_required]
  @observed_kinds [:poll_tick]
  @policy_kinds [:parked, :tracker_state_changed]

  @kinds @actionable_kinds ++ @deterministic_kinds ++ @human_kinds ++ @observed_kinds ++ @policy_kinds

  # RetryPolicy stop reasons that exhaust the deterministic retry envelope and
  # leave the issue waiting on an operator/tracker decision. `:auth_unavailable`
  # waits on a provider reset timer (deterministic) and `:recovered_parked` is
  # a restart rehydration of an already-recorded park (the original receipt
  # already survived the restart), so neither may wake again.
  @retry_exhaustion_stop_reasons [:max_attempts, :max_identical, :max_age]
  @deterministic_stop_reasons [:auth_unavailable, :recovered_parked]
  # MIC-223 recovery parks: the worker could not be proven dead (`:fence_unknown`)
  # or is still alive (`:fence_alive`). Absence of termination evidence is never
  # treated as death, so these stay actionable.
  @fence_stop_reasons [:fence_unknown, :fence_alive]

  @type kind ::
          :worker_failed
          | :worker_completed
          | :worker_termination_unconfirmed
          | :worker_stale
          | :parked
          | :discovery_needs_decision
          | :eligibility_action_required
          | :human_decision_required
          | :tracker_state_changed
          | :poll_tick

  @type classification :: :actionable | :deterministic | :human | :observed

  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  Classifies one event kind. Unknown kinds raise: the taxonomy is bounded and
  a typo in a producer must fail loudly instead of silently never waking.
  """
  @spec classify(kind(), keyword()) :: classification()
  def classify(kind, opts \\ [])

  def classify(kind, _opts) when kind in @actionable_kinds, do: :actionable
  def classify(kind, _opts) when kind in @deterministic_kinds, do: :deterministic
  def classify(kind, _opts) when kind in @human_kinds, do: :human
  def classify(kind, _opts) when kind in @observed_kinds, do: :observed

  def classify(:parked, opts) do
    stop_reason = Keyword.get(opts, :stop_reason)

    cond do
      stop_reason in @retry_exhaustion_stop_reasons -> :actionable
      stop_reason in @fence_stop_reasons -> :actionable
      stop_reason in @deterministic_stop_reasons -> :deterministic
      true -> :actionable
    end
  end

  def classify(:tracker_state_changed, opts) do
    if Keyword.get(opts, :to_state) in actionable_tracker_states(), do: :actionable, else: :deterministic
  end

  @doc """
  Tracker states whose observation should wake reasoning (e.g. a future
  review-lane "Changes Requested" state). Empty by default: in the current
  runtime tracker transitions are handled deterministically by the
  orchestrator's reconciliation, so no state wakes by default.
  """
  @spec actionable_tracker_states() :: [String.t()]
  def actionable_tracker_states do
    Application.get_env(:symphony_elixir, :wake_actionable_tracker_states, [])
  end

  @doc """
  Stable dedup identity derived from domain evidence, not wall-clock time:
  re-observing the same underlying fact yields the same identity and must not
  wake twice (Phase 5). `|` is escaped so identities stay one-line.
  """
  @spec identity(kind(), String.t() | nil, keyword()) :: String.t()
  def identity(kind, issue_id, opts) do
    parts = [kind, issue_id, Keyword.get(opts, :attempt_id), Keyword.get(opts, :evidence)]

    Enum.map_join(parts, "|", fn
      nil -> "-"
      term -> String.replace(to_string(term), "|", "/")
    end)
  end
end
