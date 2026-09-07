defmodule SymphonyElixir.HumanAcceptance.EvidencePack do
  @moduledoc """
  Deterministic, evidence-only rendering of a version 1 acceptance snapshot.

  The post-review caller owns collection and authenticity of the snapshot and
  must serialize it against the current workspace. No prose is interpreted as
  a reviewer verdict, test result, or evidence of user-visible behavior.
  """

  @marker "<!-- symphony-human-acceptance:v1 -->"
  @target_fields ~w(repository workspace base_revision revision branch)

  @spec render(term()) :: %{body: String.t(), ready: boolean()}
  def render(input) do
    evidence = object(input)
    target = object(evidence["target"])
    reviewer = object(evidence["reviewer"])
    ready = current_pass?(evidence, target, reviewer)

    sections = [
      "# [HUMAN ACCEPTANCE]\n\n#{@marker}\n\n#{status(ready)}",
      section("WHAT CHANGED", sourced_list(evidence["summary"], 6)),
      section("SHAPE OF CHANGE", shape(evidence)),
      section("TEST EVIDENCE", tests(evidence["tests"])),
      section("INDEPENDENT REVIEW", review(reviewer, target, ready)),
      section("RISKS & LIMITS", risks(evidence)),
      media(evidence),
      section("ACCEPTANCE TARGET", target_text(target))
    ]

    %{body: sections |> Enum.reject(&is_nil/1) |> Enum.join("\n\n"), ready: ready}
  end

  defp current_pass?(evidence, target, reviewer) do
    evidence["schema_version"] == 1 and complete_target?(target) and
      reviewer["schema_version"] == 1 and reviewer["verdict"] == "PASS" and
      present?(reviewer["reviewer"]) and present?(reviewer["source"]) and
      reviewer["target"] == target
  end

  defp complete_target?(target) do
    Enum.all?(~w(repository workspace), &present?(target[&1])) and
      is_binary(target["base_revision"]) and
      Regex.match?(~r/\A[0-9a-f]{40}\z/, target["base_revision"]) and
      is_binary(target["revision"]) and
      Regex.match?(~r/\A(?:[0-9a-f]{40}|sha256:[0-9a-f]{64})\z/, target["revision"])
  end

  defp status(true), do: "REVIEW GATE PASSED — current-target independent PASS. Evidence limits remain listed below."
  defp status(false), do: "DRAFT — NOT READY for Human Acceptance: current-target independent PASS is NOT AVAILABLE."

  defp section(title, body), do: "## #{title}\n\n#{body}"

  defp sourced_list(value, limit) do
    items = list(value)
    rendered = items |> Enum.take(limit) |> Enum.map(&sourced/1)
    body = if rendered == [], do: "NOT AVAILABLE", else: Enum.map_join(rendered, "\n", &("- " <> &1))
    body <> omitted(items, limit)
  end

  defp sourced(value) do
    item = object(value)

    if present?(item["text"]) and present?(item["source"]) do
      "#{inline(item["text"])} (source: #{inline(item["source"])})"
    else
      "NOT AVAILABLE — missing text or source"
    end
  end

  defp shape(evidence) do
    supplied = object(evidence["shape"])
    kind = supplied["kind"]

    if kind in ~w(mermaid component_tree call_stack file_map pseudocode topology) and
         present?(supplied["content"]) and present?(supplied["source"]) do
      language = if kind == "mermaid", do: "mermaid", else: "text"
      "#{inline(kind)} (source: #{inline(supplied["source"])})\n\n" <> fence(supplied["content"], language)
    else
      "File map (#{inline(evidence["task_type"])}):\n\n" <> sourced_list(evidence["changed_files"], 12)
    end
  end

  defp tests(value) do
    items = list(value)

    case items do
      [] -> "NOT RUN — test evidence NOT AVAILABLE"
      _ -> Enum.map_join(Enum.take(items, 8), "\n\n", &test/1) <> omitted(items, 8)
    end
  end

  defp test(value) do
    item = object(value)
    result = if item["result"] in ["PASS", "FAIL", "NOT RUN"], do: item["result"], else: "NOT AVAILABLE"

    if present?(item["command"]) and present?(item["source"]) do
      "#{result} — #{inline(item["phase"])}; revision: #{inline(item["revision"])}; source: #{inline(item["source"])}\n\n" <>
        fence(item["command"], "text") <> "\n\nResult detail: #{inline(item["detail"])}"
    else
      "NOT RUN — command or evidence source NOT AVAILABLE"
    end
  end

  defp review(reviewer, target, ready) do
    match_status = if ready, do: "current target PASS", else: "NOT AVAILABLE (missing, invalid, non-PASS, or stale result)"

    "Gate: #{match_status}\n\n" <>
      "Supplied verdict: #{inline(reviewer["verdict"])}; reviewer: #{inline(reviewer["reviewer"])}; source: #{inline(reviewer["source"])}\n\n" <>
      "Current implementation revision: #{inline(target["revision"])}\n\n" <>
      "Reviewed target:\n\n#{target_text(object(reviewer["target"]))}\n\n" <>
      "Review findings: #{inline(reviewer["findings"])}"
  end

  defp risks(evidence) do
    sourced_list(evidence["risks"], 6) <>
      "\n\nExplicitly unchanged:\n\n" <>
      sourced_list(evidence["unchanged"], 6) <>
      "\n\nMissing fields above are evidence gaps. Supplied evidence is not independently re-executed by this generator. " <>
      "No issue transition, reviewer dispatch, or delivery is performed."
  end

  defp media(%{"task_type" => "frontend"} = evidence) do
    section("USER-VISIBLE EVIDENCE", sourced_list(evidence["ui_evidence"], 4))
  end

  defp media(_evidence), do: nil

  defp target_text(target) do
    Enum.map_join(@target_fields, "\n", fn key -> "- #{key}: #{inline(target[key])}" end)
  end

  defp inline(value) do
    if present?(value) do
      value
      |> String.replace(~r/[\r\n]+/, " ")
      |> String.replace(~r/[\\`*_{}\[\]<>#|]/, fn character -> "\\" <> character end)
    else
      "NOT AVAILABLE"
    end
  end

  defp fence(value, language) do
    # A longer fence preserves exact commands even when they contain backticks.
    longest = Regex.scan(~r/`+/, value) |> List.flatten() |> Enum.map(&String.length/1) |> Enum.max(fn -> 0 end)
    delimiter = String.duplicate("`", max(3, longest + 1))
    "#{delimiter}#{language}\n#{value}\n#{delimiter}"
  end

  defp omitted(items, limit) do
    if length(items) > limit, do: "\n\n#{length(items) - limit} additional entries omitted; consult source evidence.", else: ""
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp object(value) when is_map(value), do: value
  defp object(_value), do: %{}
  defp list(value) when is_list(value), do: value
  defp list(_value), do: []
end
