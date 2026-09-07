defmodule SymphonyElixir.HumanAcceptance do
  @moduledoc """
  Publishes Symphony's dedicated Human Acceptance evidence-pack comment to Linear.

  Calls for the same issue must be serialized by the caller. Linear comment publication and any
  later workflow-state change are separate provider operations, so this module cannot make those
  operations atomic. It intentionally performs no issue-state transition or dispatch work.
  """

  alias SymphonyElixir.HumanAcceptance.EvidencePack
  alias SymphonyElixir.Linear.Client

  @marker "<!-- symphony-human-acceptance:v1 -->"
  @page_size 50
  @allowed_states MapSet.new(["in review", "human acceptance"])

  @issue_query """
  query SymphonyHumanAcceptanceIssue($issueId: String!, $after: String) {
    issue(id: $issueId) {
      id
      state { name }
      comments(first: #{@page_size}, after: $after) {
        nodes { id body resolvedAt }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
  """

  @comment_create_mutation """
  mutation SymphonyCreateHumanAcceptanceComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
      comment { id }
    }
  }
  """

  @comment_update_mutation """
  mutation SymphonyUpdateHumanAcceptanceComment($commentId: String!, $body: String!) {
    commentUpdate(id: $commentId, input: {body: $body}) {
      success
      comment { id }
    }
  }
  """

  @type publish_result :: {:ok, %{comment_id: String.t(), ready: boolean()}} | {:error, term()}

  def publish(issue_id, evidence, opts \\ [])

  @spec publish(String.t(), term(), keyword()) :: publish_result()
  def publish(issue_id, evidence, opts) when is_binary(issue_id) and is_list(opts) do
    with {:ok, issue_id} <- nonempty_issue_id(issue_id),
         {:ok, issue} <- fetch_issue_and_comments(issue_id, client(opts), client_opts(opts)),
         :ok <- allowed_state(issue),
         %{body: body, ready: ready} <- EvidencePack.render(evidence),
         {:ok, comment_id} <- publish_comment(issue.id, body, issue.comments, client(opts), client_opts(opts)) do
      {:ok, %{comment_id: comment_id, ready: ready}}
    end
  end

  def publish(_issue_id, _evidence, _opts), do: {:error, :invalid_publish_arguments}

  defp client(opts), do: Keyword.get(opts, :linear_client, &Client.graphql/3)
  defp client_opts(opts), do: Keyword.take(opts, [:tracker_settings])

  defp nonempty_issue_id(issue_id) do
    case String.trim(issue_id) do
      "" -> {:error, :missing_issue_id}
      id -> {:ok, id}
    end
  end

  defp fetch_issue_and_comments(issue_id, linear_client, client_opts) do
    fetch_issue_and_comments(issue_id, linear_client, client_opts, nil, nil, [], [])
  end

  defp fetch_issue_and_comments(issue_id, linear_client, client_opts, cursor, expected_state, comments, seen_cursors) do
    with {:ok, response} <- request(linear_client, @issue_query, %{issueId: issue_id, after: cursor}, client_opts),
         {:ok, issue, page} <- decode_issue_page(response),
         :ok <- same_state(expected_state, issue.state) do
      updated_comments = comments ++ active_comments(page.nodes)

      case next_cursor(page.page_info, seen_cursors) do
        {:ok, next_cursor} ->
          fetch_issue_and_comments(
            issue_id,
            linear_client,
            client_opts,
            next_cursor,
            issue.state,
            updated_comments,
            [next_cursor | seen_cursors]
          )

        :done ->
          {:ok, %{id: issue.id, state: issue.state, comments: updated_comments}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp request(linear_client, query, variables, client_opts) do
    case linear_client.(query, variables, client_opts) do
      {:ok, %{"errors" => errors}} when is_list(errors) and errors != [] -> {:error, {:linear_graphql_errors, errors}}
      {:ok, response} when is_map(response) -> {:ok, response}
      {:ok, _response} -> {:error, :linear_invalid_response}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:linear_invalid_result, other}}
    end
  end

  defp decode_issue_page(%{
         "data" => %{
           "issue" => %{
             "id" => issue_id,
             "state" => %{"name" => state},
             "comments" => %{"nodes" => nodes, "pageInfo" => page_info}
           }
         }
       })
       when is_binary(issue_id) and issue_id != "" and is_binary(state) and is_list(nodes) and is_map(page_info) do
    {:ok, %{id: issue_id, state: state}, %{nodes: nodes, page_info: page_info}}
  end

  defp decode_issue_page(%{"data" => %{"issue" => nil}}), do: {:error, :linear_issue_not_found}
  defp decode_issue_page(_response), do: {:error, :linear_invalid_issue_response}

  defp same_state(nil, _state), do: :ok
  defp same_state(state, state), do: :ok
  defp same_state(_expected, _actual), do: {:error, :linear_issue_state_changed_during_read}

  defp active_comments(nodes) do
    Enum.filter(nodes, fn
      %{"id" => id, "body" => body, "resolvedAt" => nil} when is_binary(id) and is_binary(body) -> true
      _ -> false
    end)
  end

  defp next_cursor(%{"hasNextPage" => false}, _seen_cursors), do: :done

  defp next_cursor(%{"hasNextPage" => true, "endCursor" => cursor}, seen_cursors) when is_binary(cursor) and cursor != "" do
    if cursor in seen_cursors, do: {:error, :linear_repeated_comments_cursor}, else: {:ok, cursor}
  end

  defp next_cursor(%{"hasNextPage" => true}, _seen_cursors), do: {:error, :linear_missing_comments_cursor}
  defp next_cursor(_page_info, _seen_cursors), do: {:error, :linear_invalid_comments_page_info}

  defp allowed_state(%{state: state}) when is_binary(state) do
    if MapSet.member?(@allowed_states, normalize_state(state)), do: :ok, else: {:error, {:invalid_issue_state, state}}
  end

  defp publish_comment(issue_id, body, comments, linear_client, client_opts) do
    case Enum.filter(comments, &owned_comment?/1) do
      [] ->
        with {:ok, response} <-
               request(
                 linear_client,
                 @comment_create_mutation,
                 %{issueId: issue_id, body: body},
                 client_opts
               ) do
          mutation_comment_id(response, "commentCreate")
        end

      [%{"id" => comment_id}] ->
        with {:ok, response} <-
               request(
                 linear_client,
                 @comment_update_mutation,
                 %{commentId: comment_id, body: body},
                 client_opts
               ) do
          mutation_comment_id(response, "commentUpdate")
        end

      _many ->
        {:error, :multiple_active_human_acceptance_comments}
    end
  end

  defp mutation_comment_id(
         %{"data" => %{"commentCreate" => %{"success" => true, "comment" => %{"id" => id}}}},
         "commentCreate"
       )
       when is_binary(id),
       do: {:ok, id}

  defp mutation_comment_id(
         %{"data" => %{"commentUpdate" => %{"success" => true, "comment" => %{"id" => id}}}},
         "commentUpdate"
       )
       when is_binary(id),
       do: {:ok, id}

  defp mutation_comment_id(
         %{"data" => %{"commentCreate" => %{"success" => false}}},
         "commentCreate"
       ),
       do: {:error, :linear_comment_mutation_failed}

  defp mutation_comment_id(
         %{"data" => %{"commentUpdate" => %{"success" => false}}},
         "commentUpdate"
       ),
       do: {:error, :linear_comment_mutation_failed}

  defp mutation_comment_id(_response, _operation), do: {:error, :linear_invalid_comment_mutation_response}

  defp normalize_state(state), do: state |> String.trim() |> String.downcase()

  defp owned_comment?(%{"body" => body}) when is_binary(body) do
    body
    |> String.replace("\r\n", "\n")
    |> String.starts_with?("# [HUMAN ACCEPTANCE]\n\n#{@marker}\n")
  end

  defp owned_comment?(_comment), do: false
end
