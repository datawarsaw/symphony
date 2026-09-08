defmodule SymphonyElixir.Discovery.Publication do
  @moduledoc "Host-owned immutable Linear publication of validated retained Discovery evidence."

  alias SymphonyElixir.Discovery.Contract
  alias SymphonyElixir.Linear.Client

  @lookup """
  query SymphonyDiscoveryComment($id: ID!) {
    comments(filter: {id: {eq: $id}}, first: 1, includeArchived: true) {
      nodes { id body issue { id } }
    }
  }
  """
  @create """
  mutation SymphonyDiscoveryCommentCreate($input: CommentCreateInput!) {
    commentCreate(input: $input) { success comment { id body issue { id } } }
  }
  """

  @doc false
  @spec publish(String.t(), String.t(), map(), map(), keyword()) :: :ok | {:error, term()}
  def publish(issue_id, input, evidence, parsed, opts \\ []) do
    graphql = Keyword.get(opts, :publication_graphql, &Client.graphql/2)
    result_id = digest(Jason.encode!([issue_id, input, evidence.output, evidence.completed_at]))
    id = comment_id(result_id)
    body = render(evidence, parsed, result_id)
    expected = %{"id" => id, "body" => body, "issue" => %{"id" => issue_id}}

    case lookup(graphql, id) do
      {:ok, nil} -> create(graphql, expected)
      {:ok, ^expected} -> :ok
      {:ok, _} -> {:error, :discovery_comment_conflict}
      error -> error
    end
  end

  defp lookup(graphql, id) do
    case graphql.(@lookup, %{id: id}) do
      {:ok, %{"errors" => errors}} when errors != [] -> {:error, :discovery_comment_read_failed}
      {:ok, %{"data" => %{"comments" => %{"nodes" => []}}}} -> {:ok, nil}
      {:ok, %{"data" => %{"comments" => %{"nodes" => [comment]}}}} -> {:ok, comment}
      _ -> {:error, :discovery_comment_read_failed}
    end
  end

  defp create(graphql, %{"id" => id, "body" => body, "issue" => %{"id" => issue_id}} = expected) do
    result = graphql.(@create, %{input: %{id: id, issueId: issue_id, body: body, doNotSubscribeToIssue: true}})

    case result do
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true, "comment" => ^expected}}} = response}
      when not is_map_key(response, "errors") ->
        :ok

      _ ->
        # Covers a committed mutation whose response was lost, including a duplicate-ID race.
        case lookup(graphql, id) do
          {:ok, ^expected} -> :ok
          _ -> {:error, :discovery_comment_publish_failed}
        end
    end
  end

  defp render(evidence, parsed, result_id) do
    fields =
      Enum.map_join(["VERDICT", "IMPLEMENTATION SIZE", "EXPECTED CONTEXT SURFACE", "SPLIT REQUIRED"], "\n", fn key ->
        [line] = Regex.run(Regex.compile!("^" <> key <> ": .+$", "m"), parsed.brief)
        line
      end)

    """
    ## Discovery

    #{fields}

    ### Recommendation
    #{excerpt(Contract.section(parsed.brief, "RECOMMENDATION"), 700)}

    ### Key findings
    #{excerpt(Contract.section(parsed.brief, "CURRENT STATE"), 450)}
    #{excerpt(Contract.section(parsed.brief, "ARCHITECTURE FIT"), 450)}

    ### Dependencies
    #{excerpt(Contract.section(parsed.brief, "DEPENDENCIES"), 700)}

    ### Acceptance criteria
    #{excerpt(Contract.section(parsed.brief, "ACCEPTANCE CRITERIA"), 900)}

    ### Handoff
    #{handoff(parsed)}

    ### Runtime
    - Provider: #{provider(evidence[:provider])}
    - Model: #{metadata(evidence[:model])}
    - Reasoning: #{metadata(evidence[:reasoning])}
    - Duration: #{duration(evidence[:duration_ms])}
    - Fallback: #{fallback(evidence)}
    - Subagents: 0

    Symphony-validated result: #{evidence.completed_at}
    Result ID: #{result_id}
    Authority: the result with the latest result timestamp supersedes earlier results; use Result ID lexical order to break timestamp ties. Publication time does not change authority. Earlier comments remain audit history.
    """
    |> String.replace("\r\n", "\n")
    |> String.trim()
  end

  defp handoff(%{verdict: "READY", handoff: text}) do
    "TODO HANDOFF\n" <>
      excerpt(Contract.section(text, "OBJECTIVE"), 350) <>
      "\n" <>
      excerpt(Contract.section(text, "IMPLEMENTATION CONTRACT"), 650) <>
      "\nVerification: " <>
      excerpt(Contract.section(text, "VERIFICATION"), 400) <>
      "\nA separate lifecycle decision is required before implementation."
  end

  defp handoff(%{verdict: "SPLIT", output: text}) do
    "SPLIT PROPOSAL — review and create bounded child issues separately.\n" <>
      excerpt(text |> String.split("\nSPLIT PROPOSAL") |> List.last(), 1_200)
  end

  defp handoff(parsed) do
    "Resolve the #{parsed.verdict} outcome before any implementation.\n" <>
      excerpt(Contract.section(parsed.brief, "VERDICT RATIONALE"), 600)
  end

  defp excerpt(text, limit) do
    if String.length(text) > limit, do: String.slice(text, 0, limit) <> " … [abridged; full result retained by Symphony]", else: text
  end

  defp provider("xai"), do: "xAI"
  defp provider(value), do: metadata(value)
  defp metadata(value) when is_binary(value) and value != "", do: value |> String.replace(~r/[\r\n]/, " ") |> String.slice(0, 160)
  defp metadata(_), do: "unavailable"
  defp duration(ms) when is_integer(ms) and ms >= 0, do: "#{Float.round(ms / 1_000, 1)}s"
  defp duration(_), do: "unavailable"

  defp fallback(%{lane: lane} = evidence) when lane in [:fallback, "fallback"],
    do: "YES (#{metadata(to_string(evidence[:fallback_reason] || "reason unavailable"))})"

  defp fallback(%{lane: lane}) when lane in [:primary, "primary"], do: "NO"
  defp fallback(_), do: "unavailable"

  defp digest(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  # Linear requires UUID v4 shape. Stable digest bits make concurrent retries use one identifier.
  defp comment_id(<<a::binary-size(8), b::binary-size(4), _::binary-size(1), c::binary-size(3), _::binary-size(1), d::binary-size(3), e::binary-size(12), _::binary>>) do
    "#{a}-#{b}-4#{c}-8#{d}-#{e}"
  end
end
