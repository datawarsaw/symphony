defmodule SymphonyElixir.DispatchRouterTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Codex.WorkerRouting
  alias SymphonyElixir.DispatchRouter
  alias SymphonyElixir.Tracker.Issue

  describe "materialize/3" do
    test "primary intent resolves the configured default route" do
      selection = DispatchRouter.materialize(:primary, nil)

      assert selection.intent == :primary
      assert selection.model == "gpt-6-astra"
      assert selection.reasoning_effort == "medium"
      assert selection.model_source == :default
      assert selection.reasoning_source == :default
      assert selection.route_source == :default
      refute selection.pinned
    end

    test "explicit model override in opts pins the selection" do
      selection = DispatchRouter.materialize(:primary, nil, model: "gpt-5.6-terra")

      assert selection.model == "gpt-5.6-terra"
      assert selection.reasoning_effort == "medium"
      assert selection.model_source == :explicit_override
      assert selection.reasoning_source == :default
      assert selection.route_source == :explicit_override
      assert selection.pinned
    end

    test "explicit model override in issue label pins the selection" do
      issue = %Issue{
        id: "issue-1",
        identifier: "MIC-ROUTER-1",
        labels: ["backend", "model:gpt-5.6-sol"]
      }

      selection = DispatchRouter.materialize(:primary, issue)

      assert selection.model == "gpt-5.6-sol"
      assert selection.model_source == :explicit_override
      assert selection.pinned
    end

    test "explicit reasoning override in opts pins the selection without changing the model" do
      selection = DispatchRouter.materialize(:primary, nil, reasoning_effort: "high")

      assert selection.model == "gpt-6-astra"
      assert selection.reasoning_effort == "high"
      assert selection.model_source == :default
      assert selection.reasoning_source == :explicit_override
      assert selection.pinned
    end

    test "explicit opts override wins over issue label pin precedence" do
      issue = %Issue{
        id: "issue-1",
        identifier: "MIC-ROUTER-2",
        labels: ["model:gpt-5.6-sol"]
      }

      selection = DispatchRouter.materialize(:primary, issue, model: "gpt-5.6-terra")

      assert selection.model == "gpt-5.6-terra"
      assert selection.route_source == :explicit_override
      assert selection.pinned
    end

    test "blank dispatch opts never leak into the selection" do
      selection = DispatchRouter.materialize(:primary, nil, attempt: 3, worker_host: "worker-a", resumed: true)

      assert selection.model == "gpt-6-astra"
      assert selection.route_source == :default
      refute selection.pinned
    end
  end

  describe "worker_route/1" do
    test "projects the selection onto the lower-level route map" do
      selection = DispatchRouter.materialize(:primary, nil, model: "gpt-5.6-terra", reasoning_effort: "high")

      route = DispatchRouter.worker_route(selection)

      assert route == %{
               model: "gpt-5.6-terra",
               reasoning_effort: "high",
               model_source: :explicit_override,
               reasoning_source: :explicit_override,
               route_source: :explicit_override
             }

      overrides = WorkerRouting.thread_overrides(route)
      assert overrides["model"] == "gpt-5.6-terra"
      assert overrides["config"]["model_reasoning_effort"] == "high"
    end

    test "default projection drops intent and pinned so WorkerRouting route shape is unchanged" do
      selection = DispatchRouter.materialize(:primary, nil)

      route = DispatchRouter.worker_route(selection)

      assert MapSet.new(Map.keys(route)) ==
               MapSet.new([:model, :model_source, :reasoning_effort, :reasoning_source, :route_source])

      assert route.route_source == :default
    end
  end
end
