defmodule SymphonyElixir.WorkerRoutingTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Codex.WorkerRouting
  alias SymphonyElixir.Discovery.Session, as: DiscoverySession
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Workflow

  describe "worker routing resolution" do
    test "normal worker default resolves to gpt-6-astra with medium reasoning effort" do
      route = WorkerRouting.resolve()
      assert route.model == "gpt-6-astra"
      assert route.reasoning_effort == "medium"
      assert route.model_source == :default
      assert route.reasoning_source == :default
      assert route.route_source == :default

      overrides = WorkerRouting.thread_overrides(route)
      assert overrides["model"] == "gpt-6-astra"
      assert overrides["config"]["model_reasoning_effort"] == "medium"
    end

    test "explicit model override in opts wins over default" do
      route = WorkerRouting.resolve(model: "gpt-5.6-terra")
      assert route.model == "gpt-5.6-terra"
      assert route.reasoning_effort == "medium"
      assert route.model_source == :explicit_override
      assert route.reasoning_source == :default
      assert route.route_source == :explicit_override

      overrides = WorkerRouting.thread_overrides(route)
      assert overrides["model"] == "gpt-5.6-terra"
      assert overrides["config"]["model_reasoning_effort"] == "medium"
    end

    test "explicit model override in issue label wins over default" do
      issue = %Issue{
        id: "issue-1",
        identifier: "MIC-OVERRIDE-1",
        labels: ["backend", "model:gpt-5.6-sol"]
      }

      route = WorkerRouting.resolve([], issue)
      assert route.model == "gpt-5.6-sol"
      assert route.reasoning_effort == "medium"
      assert route.model_source == :explicit_override
      assert route.reasoning_source == :default
      assert route.route_source == :explicit_override
    end

    test "explicit reasoning override in opts wins over default" do
      route = WorkerRouting.resolve(reasoning_effort: "high")
      assert route.model == "gpt-6-astra"
      assert route.reasoning_effort == "high"
      assert route.model_source == :default
      assert route.reasoning_source == :explicit_override
      assert route.route_source == :explicit_override

      overrides = WorkerRouting.thread_overrides(route)
      assert overrides["model"] == "gpt-6-astra"
      assert overrides["config"]["model_reasoning_effort"] == "high"
    end

    test "explicit reasoning override in issue label wins over default" do
      issue = %Issue{
        id: "issue-2",
        identifier: "MIC-OVERRIDE-2",
        labels: ["reasoning:xhigh"]
      }

      route = WorkerRouting.resolve([], issue)
      assert route.model == "gpt-6-astra"
      assert route.reasoning_effort == "xhigh"
      assert route.model_source == :default
      assert route.reasoning_source == :explicit_override
      assert route.route_source == :explicit_override
    end

    test "explicit model and reasoning overrides simultaneously apply" do
      issue = %Issue{
        id: "issue-3",
        identifier: "MIC-OVERRIDE-3",
        labels: ["model:gpt-5.6-terra", "reasoning:low"]
      }

      route = WorkerRouting.resolve([], issue)
      assert route.model == "gpt-5.6-terra"
      assert route.reasoning_effort == "low"
      assert route.model_source == :explicit_override
      assert route.reasoning_source == :explicit_override
      assert route.route_source == :explicit_override
    end

    test "reviewer/provider-diversity route remains unchanged and distinct from worker default" do
      primary = DiscoverySession.primary()
      assert primary.provider == "xai"
      assert primary.model == "xai/grok-4.6"
      assert primary.reasoning == "medium"

      fallback = DiscoverySession.fallback()
      assert fallback.provider == "google-antigravity"
      assert fallback.model == "google-antigravity/gemini-3.8-flash"
      assert fallback.reasoning == "medium"

      worker = WorkerRouting.resolve()
      assert worker.model == "gpt-6-astra"
      refute worker.model == primary.model
      refute worker.model == fallback.model
    end

    test "command line model and reasoning parser extracts correctly" do
      assert WorkerRouting.parse_model_from_command("codex --config 'model=\"gpt-6-astra\"' app-server") ==
               "gpt-6-astra"

      assert WorkerRouting.parse_model_from_command("codex -m gpt-5.6-sol app-server") ==
               "gpt-5.6-sol"

      assert WorkerRouting.parse_reasoning_from_command(
               "codex --config model_reasoning_effort=high app-server"
             ) == "high"
    end
  end

  describe "selection validation and fail-closed safety" do
    test "explicit model override fails closed when app-server selects different model (no silent fallback)" do
      route = WorkerRouting.resolve(model: "gpt-5.6-terra")
      response = %{"model" => "gpt-5.5"}

      assert {:error, {:model_override_unfulfilled, expected: "gpt-5.6-terra", actual: "gpt-5.5"}} ==
               WorkerRouting.validate_selection(response, route)
    end

    test "explicit model override succeeds when app-server matches requested model" do
      route = WorkerRouting.resolve(model: "gpt-6-astra")
      response = %{"model" => "gpt-6-astra", "reasoningEffort" => "medium"}

      assert {:ok, %{model: "gpt-6-astra", reasoning_effort: "medium"}} ==
               WorkerRouting.validate_selection(response, route)
    end

    test "default model selection adopts returned app-server model and reasoning" do
      route = WorkerRouting.resolve()
      response = %{"model" => "gpt-6-astra", "reasoningEffort" => "medium"}

      assert {:ok, %{model: "gpt-6-astra", reasoning_effort: "medium"}} ==
               WorkerRouting.validate_selection(response, route)
    end

    test "handles response with nested thread payload" do
      route = WorkerRouting.resolve()
      response = %{"thread" => %{"id" => "thread-1", "model" => "gpt-6-astra", "reasoningEffort" => "medium"}}

      assert {:ok, %{model: "gpt-6-astra", reasoning_effort: "medium"}} ==
               WorkerRouting.validate_selection(response, route)
    end
  end

  describe "workflow and delivery gates safety" do
    test "shipped WORKFLOW.md sets default command to gpt-6-astra and medium reasoning" do
      assert {:ok, %{config: config}} = Workflow.load(Path.expand("../../WORKFLOW.md", __DIR__))
      assert config["codex"]["command"] =~ "model=\"gpt-6-astra\""
      assert config["codex"]["command"] =~ "model_reasoning_effort=medium"
      assert config["codex"]["default_model"] == "gpt-6-astra"
      assert config["codex"]["default_reasoning_effort"] == "medium"
    end

    test "human acceptance and delivery gates remain preserved" do
      assert {:ok, %{config: config}} = Workflow.load(Path.expand("../../WORKFLOW.md", __DIR__))
      refute "In Review" in config["tracker"]["active_states"]
      refute "Merging" in config["tracker"]["active_states"]
      assert config["codex"]["approval_policy"] == "never"
      assert config["codex"]["thread_sandbox"] == "workspace-write"
    end
  end
end
