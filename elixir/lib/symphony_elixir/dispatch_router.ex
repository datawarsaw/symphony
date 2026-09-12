defmodule SymphonyElixir.DispatchRouter do
  @moduledoc """
  Materializes the dispatch selection for an already-decided route intent.

  MIC-195 C0 seam: this module sits between the orchestrator and the agent
  runtime. The orchestrator decides *that* an issue dispatches; this module
  resolves *what* the dispatch selects. Given a route intent that has already
  been decided (only `:primary` exists today; Slice C fallback routing will
  extend the intent space), it resolves the selected model, the reasoning
  effort, and any explicit route override, enforces pin/override precedence,
  and returns one normalized, immutable `Selection` that flows down through
  `AgentRunner` -> `Codex.AppServer` -> `Codex.WorkerRouting`.

  Ownership boundary:

  * The orchestrator (and `RetryPolicy`) own failure classification, the
    retry envelope, attempt counters, `primary_failure_count`, fallback
    thresholds and eligibility, parking, timers, process supervision, worker
    host selection, and lifecycle state. None of that lives here.
  * `DispatchRouter` owns only selection materialization for the decided
    intent: resolving the model, the reasoning effort, explicit overrides,
    and pin/override precedence. It does not classify failures, count
    attempts, or choose between a primary and a fallback route.
  * `Codex.WorkerRouting` remains the lower-level resolver: model/effort
    resolution rules, thread override materialization, and thread-start
    selection validation stay there.
  """

  alias SymphonyElixir.Codex.WorkerRouting
  alias SymphonyElixir.Tracker.Issue

  @type intent :: :primary

  defmodule Selection do
    @moduledoc """
    Normalized dispatch selection materialized before an agent run starts.

    Carries the resolved model and reasoning effort, where each value came
    from, and whether the route is pinned by an explicit override. Downstream
    stages consume this instead of re-resolving routing policy mid-flight.
    """

    @type route_source :: :default | :explicit_override

    @type t :: %__MODULE__{
            intent: SymphonyElixir.DispatchRouter.intent(),
            model: String.t(),
            reasoning_effort: String.t(),
            model_source: route_source(),
            reasoning_source: route_source(),
            route_source: route_source(),
            pinned: boolean()
          }

    defstruct [
      :intent,
      :model,
      :reasoning_effort,
      :model_source,
      :reasoning_source,
      :route_source,
      :pinned
    ]
  end

  @doc """
  Materializes the dispatch selection for an already-decided route intent.

  `opts` must be the same dispatch opts handed to `AgentRunner.run/3`, so the
  materialized selection is exactly what `Codex.WorkerRouting` would have
  resolved at session start.
  """
  @spec materialize(intent(), Issue.t() | nil, keyword()) :: Selection.t()
  def materialize(intent, issue, opts \\ []) when intent == :primary and is_list(opts) do
    route = WorkerRouting.resolve(opts, issue)

    %Selection{
      intent: intent,
      model: route.model,
      reasoning_effort: route.reasoning_effort,
      model_source: route.model_source,
      reasoning_source: route.reasoning_source,
      route_source: route.route_source,
      pinned: route.route_source == :explicit_override
    }
  end

  @doc """
  Projects a selection onto the lower-level route map consumed by
  `Codex.WorkerRouting` and `Codex.AppServer`.
  """
  @spec worker_route(Selection.t()) :: %{
          model: String.t(),
          reasoning_effort: String.t(),
          model_source: Selection.route_source(),
          reasoning_source: Selection.route_source(),
          route_source: Selection.route_source()
        }
  def worker_route(%Selection{} = selection) do
    %{
      model: selection.model,
      reasoning_effort: selection.reasoning_effort,
      model_source: selection.model_source,
      reasoning_source: selection.reasoning_source,
      route_source: selection.route_source
    }
  end
end
