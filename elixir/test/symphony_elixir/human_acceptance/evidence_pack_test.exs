defmodule SymphonyElixir.HumanAcceptance.EvidencePackTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.HumanAcceptance.EvidencePack

  test "missing and malformed snapshots are explicit drafts, never invented evidence" do
    for input <- [nil, [], "PASS", %{}, %{"reviewer" => "PASS"}] do
      assert %{ready: false, body: body} = EvidencePack.render(input)
      assert body =~ "DRAFT — NOT READY"
      assert body =~ "NOT RUN — test evidence NOT AVAILABLE"
      assert body =~ "# [HUMAN ACCEPTANCE]"
      assert body =~ "## ACCEPTANCE TARGET"
      refute body =~ "## USER-VISIBLE EVIDENCE"
    end
  end

  test "only structured independent PASS for the exact complete target clears the gate" do
    evidence = snapshot()
    assert %{ready: true, body: body} = EvidencePack.render(evidence)
    assert body =~ "REVIEW GATE PASSED"
    assert body =~ evidence["target"]["revision"]

    for verdict <- ["FAIL", "pass", nil, true] do
      refute EvidencePack.render(put_in(evidence, ["reviewer", "verdict"], verdict)).ready
    end

    for field <- ~w(repository workspace revision base_revision branch) do
      stale = put_in(evidence, ["reviewer", "target", field], "stale")
      refute EvidencePack.render(stale).ready
    end

    for field <- ~w(reviewer source schema_version) do
      refute EvidencePack.render(update_in(evidence, ["reviewer"], &Map.delete(&1, field))).ready
    end

    refute EvidencePack.render(Map.put(evidence, "schema_version", 2)).ready

    for field <- ~w(repository workspace revision base_revision) do
      target = Map.put(evidence["target"], field, "")
      invalid = evidence |> Map.put("target", target) |> put_in(["reviewer", "target"], target)
      refute EvidencePack.render(invalid).ready
    end
  end

  test "backend summary, supplied Mermaid, exact commands and before/after results preserve their sources" do
    evidence =
      snapshot()
      |> Map.merge(%{
        "summary" => [%{"text" => "Reject stale review", "source" => "workpad:12"}],
        "shape" => %{"kind" => "mermaid", "content" => "graph LR\n  Review --> Pack", "source" => "diff:service.ex"},
        "tests" => [
          %{"command" => "mix test path:12 --seed 1", "result" => "FAIL", "phase" => "before", "source" => "run:1", "detail" => "1 failure"},
          %{"command" => "mix test path:12 --seed 1", "result" => "PASS", "phase" => "regression", "source" => "run:2"}
        ]
      })

    body = EvidencePack.render(evidence).body
    assert body =~ "Reject stale review (source: workpad:12)"
    assert body =~ "```mermaid\ngraph LR\n  Review --> Pack\n```"
    assert body =~ "FAIL — before"
    assert body =~ "PASS — regression"
    assert body =~ "mix test path:12 --seed 1"
    assert body =~ "1 failure"
  end

  test "task types select supplied topology, call stack, tree or file map without fabricating diagrams" do
    for {task_type, kind} <- [{"infra", "topology"}, {"bugfix", "call_stack"}, {"frontend", "component_tree"}, {"backend", "pseudocode"}] do
      evidence = Map.merge(snapshot(), %{"task_type" => task_type, "shape" => %{"kind" => kind, "content" => "A -> B", "source" => "diff"}})
      assert EvidencePack.render(evidence).body =~ "A -> B"
    end

    evidence = Map.merge(snapshot(), %{"task_type" => "trivial", "changed_files" => [%{"text" => "README.md", "source" => "git diff --name-only"}]})
    body = EvidencePack.render(evidence).body
    assert body =~ "File map (trivial)"
    assert body =~ "README.md"
    refute body =~ "```mermaid"
  end

  test "UI media is optional and only supplied frontend receipts are rendered" do
    evidence = Map.put(snapshot(), "ui_evidence", [%{"text" => "https://example.test/trace.zip", "source" => "configured Playwright run 1"}])
    refute EvidencePack.render(evidence).body =~ "trace.zip"
    assert EvidencePack.render(Map.put(evidence, "task_type", "frontend")).body =~ "trace.zip"
    assert EvidencePack.render(%{"task_type" => "frontend"}).body =~ "## USER-VISIBLE EVIDENCE\n\nNOT AVAILABLE"
  end

  test "malformed evidence does not claim a test result and missing provenance is explicit" do
    evidence = %{
      "summary" => [%{"text" => "Unsupported claim"}],
      "tests" => [nil, %{"command" => "test", "source" => "run", "result" => "probably passed"}],
      "shape" => %{"kind" => "mermaid", "content" => "invented"}
    }

    body = EvidencePack.render(evidence).body
    refute body =~ "Unsupported claim"
    refute body =~ "invented"
    refute body =~ "probably passed"
    assert body =~ "NOT RUN — command or evidence source NOT AVAILABLE"
  end

  test "bounded entries disclose omissions and command fences preserve exact backticks" do
    entries = for i <- 1..15, do: %{"text" => "change #{i}", "source" => "diff"}
    evidence = %{"summary" => entries, "tests" => [%{"command" => "echo ```\nline 2", "result" => "PASS", "source" => "run"}]}
    body = EvidencePack.render(evidence).body
    assert body =~ "9 additional entries omitted"
    refute body =~ "change 7"
    assert body =~ "````text\necho ```\nline 2\n````"
  end

  test "inline evidence preserves every Markdown metacharacter with one escape prefix" do
    characters = ["\\", "`", "*", "_", "{", "}", "[", "]", "<", ">", "#", "|"]

    for character <- characters do
      value = "before" <> character <> "after"
      escaped = "before" <> "\\" <> character <> "after"
      evidence = %{"summary" => [%{"text" => value, "source" => value}]}
      body = EvidencePack.render(evidence).body

      assert body =~ "## WHAT CHANGED\n\n- #{escaped} (source: #{escaped})\n\n"
    end

    body = EvidencePack.render(%{"changed_files" => [%{"text" => "human_acceptance.ex", "source" => "diff"}]}).body
    assert body =~ "- human\\_acceptance.ex (source: diff)"
  end

  defp snapshot do
    target = %{
      "repository" => "symphony-runtime",
      "workspace" => "C:/work/MIC-185",
      "base_revision" => String.duplicate("a", 40),
      "revision" => "sha256:" <> String.duplicate("b", 64),
      "branch" => "prepared"
    }

    %{
      "schema_version" => 1,
      "task_type" => "backend",
      "target" => target,
      "reviewer" => %{"schema_version" => 1, "verdict" => "PASS", "reviewer" => "independent-reviewer", "source" => "review:1", "target" => target}
    }
  end
end
