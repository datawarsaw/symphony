defmodule SymphonyElixir.SourceCanonicalityTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.RepositoryRouter
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Workflow

  @canonical_source_path "C:/Users/micha/symphony-source"
  @canonical_remote "https://github.com/datawarsaw/symphony.git"
  @unrelated_upstream_path "C:/Users/micha/symphony"

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

  defp shipped_settings do
    shipped_workflow = Path.expand("WORKFLOW.md", File.cwd!())
    assert File.exists?(shipped_workflow), "shipped WORKFLOW.md missing at #{shipped_workflow}"

    with {:ok, %{config: config}} <- Workflow.load(shipped_workflow) do
      Schema.parse(config)
    end
  end
end
