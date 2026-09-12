defmodule SymphonyElixir.DispatchRouterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.WorkerRouting
  alias SymphonyElixir.DispatchRouter
  alias SymphonyElixir.Tracker.Issue

  describe "materialize/3 primary intent" do
    test "primary intent resolves the configured default route" do
      selection = DispatchRouter.materialize(:primary, nil)

      assert selection.route == :primary
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

    test "worker host is never materialized into the selection for either route" do
      primary = DispatchRouter.materialize(:primary, nil, worker_host: "worker-a", attempt: 2)
      refute Map.has_key?(Map.from_struct(primary), :worker_host)

      write_workflow_file!(Workflow.workflow_file_path(),
        codex_fallback_enabled: true,
        codex_fallback_model: "gpt-5.6-terra"
      )

      fallback = DispatchRouter.materialize(:fallback, nil, worker_host: "worker-a", attempt: 2)
      assert %DispatchRouter.Selection{} = fallback
      refute Map.has_key?(Map.from_struct(fallback), :worker_host)
    end
  end

  describe "materialize/3 fallback intent" do
    test "explicit :fallback is rejected while the fallback seam is disabled" do
      assert {:error, :fallback_disabled} = DispatchRouter.materialize(:fallback, nil)
    end

    test "explicit :fallback is rejected when the fallback model is missing" do
      write_workflow_file!(Workflow.workflow_file_path(),
        codex_fallback_enabled: true,
        codex_fallback_model: nil
      )

      assert {:error, {:invalid_route_selection, :missing_model}} =
               DispatchRouter.materialize(:fallback, nil)
    end

    test "explicit :fallback resolves the configured fallback model when enabled" do
      write_workflow_file!(Workflow.workflow_file_path(),
        codex_fallback_enabled: true,
        codex_fallback_model: "gpt-5.6-terra"
      )

      selection = DispatchRouter.materialize(:fallback, nil)

      assert %DispatchRouter.Selection{} = selection
      assert selection.route == :fallback
      assert selection.model == "gpt-5.6-terra"
      assert selection.reasoning_effort == "medium"
      assert selection.model_source == :fallback_config
      assert selection.reasoning_source == :fallback_config
      assert selection.route_source == :explicit_override
      refute selection.pinned
    end

    test "configured fallback reasoning effort is applied to the fallback selection" do
      write_workflow_file!(Workflow.workflow_file_path(),
        codex_fallback_enabled: true,
        codex_fallback_model: "gpt-5.6-terra",
        codex_fallback_reasoning_effort: "high"
      )

      selection = DispatchRouter.materialize(:fallback, nil)

      assert selection.reasoning_effort == "high"
      assert selection.reasoning_source == :fallback_config
    end

    test "invalid fallback selection propagates the WorkerRouting validation error" do
      write_workflow_file!(Workflow.workflow_file_path(),
        codex_fallback_enabled: true,
        codex_fallback_model: "gpt-5.6-terra",
        codex_fallback_reasoning_effort: "ludicrous"
      )

      assert {:error, {:invalid_route_selection, {:invalid_reasoning_effort, "ludicrous"}}} =
               DispatchRouter.materialize(:fallback, nil)
    end

    test "dispatch pin stays visible on the fallback selection without being applied to it" do
      write_workflow_file!(Workflow.workflow_file_path(),
        codex_fallback_enabled: true,
        codex_fallback_model: "gpt-5.6-terra"
      )

      issue = %Issue{
        id: "issue-pin",
        identifier: "MIC-ROUTER-PIN",
        labels: ["model:gpt-5.6-sol"]
      }

      selection = DispatchRouter.materialize(:fallback, issue)

      assert selection.route == :fallback
      assert selection.pinned
      assert selection.model == "gpt-5.6-terra"
      assert selection.model_source == :fallback_config
    end
  end

  describe "materialize/3 invalid intent" do
    test "unknown route intents fail closed without coercion" do
      assert_raise FunctionClauseError, fn -> DispatchRouter.materialize(:secondary, nil) end
      assert_raise FunctionClauseError, fn -> DispatchRouter.materialize("primary", nil) end
      assert_raise FunctionClauseError, fn -> DispatchRouter.materialize("fallback", nil) end
      assert_raise FunctionClauseError, fn -> DispatchRouter.materialize(nil, nil) end
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

    test "default projection drops route and pinned so WorkerRouting route shape is unchanged" do
      selection = DispatchRouter.materialize(:primary, nil)

      route = DispatchRouter.worker_route(selection)

      assert MapSet.new(Map.keys(route)) ==
               MapSet.new([:model, :model_source, :reasoning_effort, :reasoning_source, :route_source])

      assert route.route_source == :default
    end

    test "fallback selection projects as an explicit override so thread-start validation stays fail-closed" do
      write_workflow_file!(Workflow.workflow_file_path(),
        codex_fallback_enabled: true,
        codex_fallback_model: "gpt-5.6-terra",
        codex_fallback_reasoning_effort: "high"
      )

      selection = DispatchRouter.materialize(:fallback, nil)

      route = DispatchRouter.worker_route(selection)

      assert MapSet.new(Map.keys(route)) ==
               MapSet.new([:model, :model_source, :reasoning_effort, :reasoning_source, :route_source])

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

      assert {:error, {:model_override_unfulfilled, expected: "gpt-5.6-terra", actual: "gpt-6-astra"}} ==
               WorkerRouting.validate_selection(%{"model" => "gpt-6-astra"}, route)
    end
  end

  describe "module ownership" do
    test "DispatchRouter exposes no retry, threshold, or failure-count policy surface" do
      source = File.read!(Path.expand("../../lib/symphony_elixir/dispatch_router.ex", __DIR__))
      definition = ~r/^\s*def(p)?\s+([a-zA-Z_?!][a-zA-Z_?!0-9]*)/

      {public, private} =
        source
        |> String.split("\n")
        |> Enum.flat_map(fn line ->
          case Regex.run(definition, line) do
            [_, "", name] -> [{String.to_atom(name), :public}]
            [_, "p", name] -> [{String.to_atom(name), :private}]
            _ -> []
          end
        end)
        |> Enum.split_with(&match?({_name, :public}, &1))

      assert Enum.sort(Enum.map(public, &elem(&1, 0))) == [:materialize, :worker_route]

      policy_definitions =
        Enum.map(public ++ private, &elem(&1, 0))
        |> Enum.filter(&Regex.match?(~r/retry|threshold|failure_count|eligib|park/i, Atom.to_string(&1)))

      assert policy_definitions == []
    end
  end
end
