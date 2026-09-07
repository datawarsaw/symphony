defmodule SymphonyElixir.Discovery.Contract do
  @moduledoc "Validates the installed Discovery Gate text contract without interpreting verdicts as failures."

  @verdicts ~w(READY NEEDS_RESEARCH NEEDS_DECISION SPLIT BLOCKED DROP)
  @brief [
    "ISSUE",
    "PROBLEM",
    "CURRENT STATE",
    "REAL ACTION / OWNERSHIP PATH",
    "ARCHITECTURE FIT",
    "DEPENDENCIES",
    "DESTINATION / REPO",
    "OPTIONS",
    "RECOMMENDATION",
    "ACCEPTANCE CRITERIA",
    "INVARIANTS / REGRESSION RISKS",
    "OPEN QUESTIONS",
    "PROPOSED IMPLEMENTATION SCOPE",
    "OUT OF SCOPE",
    "VERDICT RATIONALE"
  ]
  @handoff [
    "ISSUE",
    "OBJECTIVE",
    "DESTINATION",
    "IMPLEMENTATION CONTRACT",
    "ACCEPTANCE CRITERIA",
    "PRESERVE",
    "CONFIG / SECRETS",
    "DEPENDENCIES RESOLVED",
    "OUT OF SCOPE",
    "VERIFICATION",
    "STOP CONDITIONS"
  ]

  @spec parse(String.t()) :: {:ok, map()} | {:error, term()}
  def parse(text) when is_binary(text) do
    text = String.replace(text, "\r\n", "\n") |> String.trim()

    with true <- occurrences(text, "DISCOVERY BRIEF") == 1,
         true <- String.starts_with?(text, "DISCOVERY BRIEF\n"),
         [brief | tail] <- Regex.split(~r/^TODO HANDOFF$|^SPLIT PROPOSAL$/m, text),
         :ok <- sections(brief, @brief),
         {:ok, verdict} <- field(brief, "VERDICT", @verdicts),
         {:ok, split} <- field(brief, "SPLIT REQUIRED", ~w(YES NO)),
         {:ok, size} <- field(brief, "IMPLEMENTATION SIZE", ~w(SMALL MEDIUM LARGE)),
         {:ok, surface} <- field(brief, "EXPECTED CONTEXT SURFACE", ~w(BOUNDED BROAD)),
         {:ok, research} <- field(brief, "RESEARCH REQUIRED", ~w(YES NO)),
         {:ok, "0"} <- field(brief, "SUBAGENTS USED", ["0"]),
         true <- Regex.match?(~r/^INDEPENDENT SUBSYSTEMS: \d+\s*.+$/m, brief),
         true <- Regex.match?(~r/^INTERNAL:\s*\n\S/m, brief),
         true <- Regex.match?(~r/^EXTERNAL:\s*\n\S/m, brief),
         :ok <- attachment(verdict, split, text, tail),
         true <- verdict != "READY" or (not (size == "LARGE" and surface == "BROAD") and research == "NO"),
         true <- verdict != "READY" or (same_identity?(brief, hd(tail)) and same_shape?(brief, hd(tail))) do
      {:ok, %{verdict: verdict, brief: String.trim(brief), output: text, handoff: if(verdict == "READY", do: "TODO HANDOFF" <> hd(tail), else: nil)}}
    else
      _ -> {:error, :invalid_discovery_contract}
    end
  end

  defp attachment("READY", "NO", text, [handoff]) do
    with true <- occurrences(text, "TODO HANDOFF") == 1 and occurrences(text, "SPLIT PROPOSAL") == 0,
         :ok <- sections(handoff, @handoff),
         {:ok, "NO"} <- field(handoff, "SPLIT REQUIRED", ["NO"]),
         {:ok, "DISABLED"} <- field(handoff, "SUBAGENTS", ["DISABLED"]),
         {:ok, _} <- field(handoff, "IMPLEMENTATION SIZE", ~w(SMALL MEDIUM LARGE)),
         {:ok, _} <- field(handoff, "EXPECTED CONTEXT SURFACE", ~w(BOUNDED BROAD)),
         true <- Regex.match?(~r/^REPO: \S.+$/m, handoff),
         true <- Regex.match?(~r/^WORKING AREA: \S.+$/m, handoff),
         true <- String.contains?(handoff, "Discovery") and String.contains?(handoff, "SPLIT") do
      :ok
    else
      _ -> :error
    end
  end

  defp attachment("SPLIT", "YES", text, [proposal]) do
    with true <- occurrences(text, "SPLIT PROPOSAL") == 1 and occurrences(text, "TODO HANDOFF") == 0,
         :ok <- sections(proposal, ["PARENT ISSUE", "WHY SPLIT", "CHILD 1", "CHILD 2", "PARENT COMPLETION CONDITION"]),
         children <- Regex.split(~r/^CHILD \d+$/m, proposal) |> tl(),
         true <- Enum.all?(children, &valid_child?/1) do
      :ok
    else
      _ -> :error
    end
  end

  defp attachment(verdict, _split, _text, []) when verdict in @verdicts and verdict not in ["READY", "SPLIT"], do: :ok
  defp attachment(_, _, _, _), do: :error

  defp occurrences(text, heading), do: length(Regex.scan(Regex.compile!("^" <> Regex.escape(heading) <> "$", "m"), text))

  defp valid_child?(child) do
    Enum.all?(~w(TITLE DESTINATION OBJECTIVE ACCEPTANCE) ++ ["DEPENDS ON"], fn key ->
      Regex.match?(Regex.compile!("^" <> key <> ": \\S.+$", "m"), child)
    end)
  end

  defp sections(text, headings) do
    valid = Enum.all?(headings, fn heading -> valid_section?(text, heading) end)
    if valid, do: :ok, else: :error
  end

  defp valid_section?(text, heading) do
    body = section(text, heading)
    occurrences(text, heading) == 1 and body != "" and not Regex.match?(~r/<[^>]+>/, body)
  end

  defp section(text, heading) do
    boundaries = (@brief ++ @handoff ++ ["PARENT ISSUE", "WHY SPLIT", "PARENT COMPLETION CONDITION"]) |> Enum.uniq() |> Enum.map_join("|", &Regex.escape/1)

    pattern =
      "^" <>
        Regex.escape(heading) <>
        "\\n(.*?)(?=^(?:" <>
        boundaries <>
        "|CHILD [0-9]+)$|^(?:RESEARCH REQUIRED|IMPLEMENTATION SIZE|EXPECTED CONTEXT SURFACE|INDEPENDENT SUBSYSTEMS|SPLIT REQUIRED|VERDICT|SUBAGENTS USED|SUBAGENTS): .+$|\\z)"

    case Regex.run(Regex.compile!(pattern, "ms"), text) do
      [_, body] -> String.trim(body)
      _ -> ""
    end
  end

  defp same_shape?(brief, handoff) do
    Enum.all?(
      [
        {"IMPLEMENTATION SIZE", ~w(SMALL MEDIUM LARGE)},
        {"EXPECTED CONTEXT SURFACE", ~w(BOUNDED BROAD)}
      ],
      fn {key, values} -> field(brief, key, values) == field(handoff, key, values) end
    )
  end

  defp same_identity?(brief, handoff), do: section(brief, "ISSUE") == section(handoff, "ISSUE")

  defp field(text, key, allowed) do
    case Regex.scan(Regex.compile!("^" <> Regex.escape(key) <> ": (.+)$", "m"), text) do
      [[_, value]] -> if value in allowed, do: {:ok, value}, else: :error
      _ -> :error
    end
  end
end
