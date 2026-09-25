defmodule SymphonyElixir.SourceCanonicalityTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.RepositoryRouter
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Workflow

  @canonical_source_path "C:/Users/micha/symphony-source"
  @canonical_remote "https://github.com/datawarsaw/symphony.git"
  @unrelated_upstream_path "C:/Users/micha/symphony"
  @canonical_workstation_ops_path "C:/AI/agent-platform/workstation-ops-mcp"
  @canonical_workstation_ops_remote "https://github.com/datawarsaw/workstation-ops-mcp.git"
  @stale_workstation_ops_path "C:/AI/workstation-ops-mcp"

  test "repo:symphony-runtime resolves to the canonical implementation source" do
    assert {:ok, settings} = shipped_settings()

    issue = %Issue{id: "canonicality-check", identifier: "CANON-1", labels: ["repo:symphony-runtime"]}

    assert {:ok, route} = RepositoryRouter.resolve(issue, settings.routing)
    assert route.target == "symphony-runtime"
    assert route.source_path == @canonical_source_path
    assert route.default_branch == "main"
    # The origin pin makes source selection mechanically verifiable: workspace
    # preparation fails closed unless the checkout's origin is this repository.
    assert route.remote == @canonical_remote
  end

  test "routing never selects the unrelated openai/symphony upstream clone" do
    assert {:ok, settings} = shipped_settings()

    for target <- Map.keys(settings.routing.targets) do
      issue = %Issue{id: "canonicality-check", identifier: "CANON-1", labels: ["repo:#{target}"]}

      assert {:ok, route} = RepositoryRouter.resolve(issue, settings.routing),
             "target #{inspect(target)} did not resolve"

      refute route.source_path == @unrelated_upstream_path,
             "target #{inspect(target)} selects the unrelated openai/symphony upstream clone"
    end
  end

  test "repo:agent-platform-workstation-ops resolves to the canonical workstation-ops checkout" do
    assert {:ok, settings} = shipped_settings()

    issue = %Issue{
      id: "canonicality-check",
      identifier: "CANON-1",
      labels: ["repo:agent-platform-workstation-ops"]
    }

    assert {:ok, route} = RepositoryRouter.resolve(issue, settings.routing)
    assert route.target == "agent-platform-workstation-ops"
    assert route.source_path == @canonical_workstation_ops_path
    assert route.default_branch == "main"
    # The origin pin makes source selection mechanically verifiable: workspace
    # preparation fails closed unless the checkout's origin is this repository.
    assert route.remote == @canonical_workstation_ops_remote
  end

  test "routing never selects the stale workstation-ops path" do
    assert {:ok, settings} = shipped_settings()

    for target <- Map.keys(settings.routing.targets) do
      issue = %Issue{id: "canonicality-check", identifier: "CANON-1", labels: ["repo:#{target}"]}

      assert {:ok, route} = RepositoryRouter.resolve(issue, settings.routing),
             "target #{inspect(target)} did not resolve"

      refute route.source_path == @stale_workstation_ops_path,
             "target #{inspect(target)} selects the stale workstation-ops path"
    end
  end

  defp shipped_settings do
    shipped_workflow = Path.expand("WORKFLOW.md", File.cwd!())
    assert File.exists?(shipped_workflow), "shipped WORKFLOW.md missing at #{shipped_workflow}"

    with {:ok, %{config: config}} <- Workflow.load(shipped_workflow) do
      Schema.parse(config)
    end
  end
end
