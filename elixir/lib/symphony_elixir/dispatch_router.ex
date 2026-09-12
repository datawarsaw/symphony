defmodule SymphonyElixir.DispatchRouter do
  @moduledoc """
  Materializes the dispatch selection for an already-decided route intent.

  MIC-195 C0 seam: this module sits between the orchestrator and the agent
  runtime. The orchestrator decides *that* an issue dispatches and *which*
  route intent it dispatches as (`:primary` today; Slice C owns when
  `:fallback` becomes eligible); this module resolves *what* the dispatch
  selects. Given an explicit route intent, it validates the intent, resolves
  the model and the reasoning effort for that route, preserves any explicit
  model/reasoning pin carried by the dispatch, and returns one normalized,
  immutable `Selection` that flows down through `AgentRunner` ->
  `Codex.AppServer` -> `Codex.WorkerRouting`.

  Ownership boundary:

  * The orchestrator (and, in Slice C, the fallback decision layer) own
    failure classification, `primary_failure_count`, fallback thresholds and
    eligibility, the retry envelope, parking, timers, process supervision,
    worker host selection, and lifecycle state. None of that lives here: this
    module never decides *when* a fallback route is used — the caller must
    already have decided the intent.
  * `DispatchRouter` owns only selection materialization for the decided
    intent: resolving the model, the reasoning effort, explicit overrides,
    and pin/override precedence. It fails closed when a requested route
    cannot be materialized.
  * `Codex.WorkerRouting` remains the lower-level resolver: model/effort
    resolution rules, route-selection validation, thread override
    materialization, and thread-start selection validation stay there.

  Route intents:

  * `:primary` resolves through the normal worker routing rules and always
    materializes; it returns a bare `Selection.t()`.
  * `:fallback` resolves the configured `codex.fallback` seam (disabled by
    default). It returns a bare `Selection.t()` when the seam can be
    materialized and `{:error, reason}` when it cannot — disabled, missing
    model, or invalid reasoning effort. It never silently degrades to
    `:primary`. A pin carried by the dispatch is detected and exposed as
    `pinned: true`, but this module does not decide whether the pin allows
    fallback; the pin-exception policy belongs to Slice C.
  * Any other intent fails closed: `materialize/3` has a guard on the intent
    and raises `FunctionClauseError` instead of coercing.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema.Codex.Fallback
  alias SymphonyElixir.Codex.WorkerRouting
  alias SymphonyElixir.Tracker.Issue

  @type intent :: :primary | :fallback

  defmodule Selection do
    @moduledoc """
    Normalized dispatch selection materialized before an agent run starts.

    Carries the resolved route, the resolved model and reasoning effort,
    where each value came from, and whether the dispatch carried an explicit
    model/reasoning pin. Downstream stages consume this instead of
    re-resolving routing policy mid-flight. The worker host is deliberately
    absent: host selection belongs to the orchestrator.
    """

    @type route_source :: :default | :explicit_override
    @type source :: route_source() | :fallback_config

    @type t :: %__MODULE__{
            route: SymphonyElixir.DispatchRouter.intent(),
            model: String.t(),
            reasoning_effort: String.t(),
            model_source: source(),
            reasoning_source: source(),
            route_source: route_source(),
            pinned: boolean()
          }

    defstruct [
      :route,
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

  `:primary` always returns a bare `Selection.t()`. `:fallback` returns a
  bare `Selection.t()` when the configured fallback seam can be materialized
  and `{:error, reason}` when it cannot. Any other intent raises
  `FunctionClauseError`.
  """
  @spec materialize(:primary, Issue.t() | nil, keyword()) :: Selection.t()
  @spec materialize(:fallback, Issue.t() | nil, keyword()) ::
          Selection.t() | {:error, :fallback_disabled | {:invalid_route_selection, term()}}
  @spec materialize(intent(), Issue.t() | nil, keyword()) :: Selection.t() | {:error, term()}
  def materialize(intent, issue, opts \\ []) when intent in [:primary, :fallback] and is_list(opts) do
    case intent do
      :primary -> materialize_primary(issue, opts)
      :fallback -> materialize_fallback(issue, opts)
    end
  end

  @doc """
  Projects a selection onto the lower-level route map consumed by
  `Codex.WorkerRouting` and `Codex.AppServer`.

  A `:fallback_config` source projects as `:explicit_override`: the fallback
  model is an explicitly configured selection, so it receives the same
  fail-closed thread-start verification as any explicit override. The
  lower-level route map itself never carries fallback provenance; the
  `route` and `pinned` fields stay on the selection.
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
      model_source: worker_route_source(selection.model_source),
      reasoning_source: worker_route_source(selection.reasoning_source),
      route_source: selection.route_source
    }
  end

  defp materialize_primary(issue, opts) do
    route = WorkerRouting.resolve(opts, issue)

    %Selection{
      route: :primary,
      model: route.model,
      reasoning_effort: route.reasoning_effort,
      model_source: route.model_source,
      reasoning_source: route.reasoning_source,
      route_source: route.route_source,
      pinned: route.route_source == :explicit_override
    }
  end

  # The fallback route is *explicitly requested* by the caller; this module
  # only checks that the configured fallback seam can actually be
  # materialized. Eligibility, thresholds, and pin-exception policy stay with
  # the caller. Pair validation is delegated to WorkerRouting so the rules
  # for "what is a valid model/reasoning selection" exist in one place.
  defp materialize_fallback(issue, opts) do
    with {:ok, fallback} <- enabled_fallback(),
         {:ok, validated} <-
           WorkerRouting.validate_route_selection(%{
             model: fallback.model,
             reasoning_effort: fallback.reasoning_effort
           }) do
      %Selection{
        route: :fallback,
        model: validated.model,
        reasoning_effort: validated.reasoning_effort,
        model_source: :fallback_config,
        reasoning_source: :fallback_config,
        route_source: :explicit_override,
        pinned: dispatch_pin_present?(opts, issue)
      }
    end
  end

  defp enabled_fallback do
    case Config.settings() do
      {:ok, %{codex: %{fallback: %Fallback{enabled: true} = fallback}}} ->
        {:ok, fallback}

      _ ->
        {:error, :fallback_disabled}
    end
  rescue
    _ -> {:error, :fallback_disabled}
  end

  # Pin detection reuses the WorkerRouting resolution rules: a dispatch
  # carries an explicit model/reasoning pin exactly when resolving its opts
  # and issue labels produces an explicit override. The pin is only reported
  # here; whether it permits a fallback route is decided above this seam.
  defp dispatch_pin_present?(opts, issue) do
    WorkerRouting.resolve(opts, issue).route_source == :explicit_override
  end

  defp worker_route_source(:fallback_config), do: :explicit_override
  defp worker_route_source(source), do: source
end
