defmodule SymphonyElixir.HumanAcceptanceTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.HumanAcceptance

  @marker "<!-- symphony-human-acceptance:v1 -->"

  test "creates the sole active evidence-pack comment and returns renderer readiness" do
    test_pid = self()

    client = fn query, variables, opts ->
      send(test_pid, {:linear, query, variables, opts})

      cond do
        String.contains?(query, "SymphonyHumanAcceptanceIssue") ->
          {:ok, issue_response("In Review", [], false)}

        String.contains?(query, "SymphonyCreateHumanAcceptanceComment") ->
          assert variables.issueId == "uuid-1"
          assert variables.body =~ @marker
          {:ok, %{"data" => %{"commentCreate" => %{"success" => true, "comment" => %{"id" => "comment-1"}}}}}
      end
    end

    assert {:ok, %{comment_id: "comment-1", ready: true}} =
             HumanAcceptance.publish("issue-1", ready_evidence(), linear_client: client, tracker_settings: :snapshot)

    assert_received {:linear, issue_query, %{after: nil, issueId: "issue-1"}, [tracker_settings: :snapshot]}
    assert issue_query =~ "$issueId: String!"
  end

  test "updates the one active owned comment without touching a workpad" do
    test_pid = self()

    workpad = %{
      "id" => "workpad",
      "body" => "## Codex Workpad\n\nExample only:\n# [HUMAN ACCEPTANCE]\n\n#{@marker}",
      "resolvedAt" => nil
    }

    owned = %{"id" => "owned", "body" => "# [HUMAN ACCEPTANCE]\n\n#{@marker}\n\nold", "resolvedAt" => nil}

    client = fn query, variables, _opts ->
      send(test_pid, {:linear, query, variables})

      cond do
        String.contains?(query, "SymphonyHumanAcceptanceIssue") ->
          {:ok, issue_response("Human Acceptance", [workpad, owned], false)}

        String.contains?(query, "SymphonyUpdateHumanAcceptanceComment") ->
          {:ok,
           %{
             "data" => %{
               "commentUpdate" => %{"success" => true, "comment" => %{"id" => "owned"}}
             }
           }}
      end
    end

    assert {:ok, %{comment_id: "owned", ready: false}} = HumanAcceptance.publish("issue-1", %{}, linear_client: client)
    assert_received {:linear, update, %{commentId: "owned", body: body}}
    assert update =~ "SymphonyUpdateHumanAcceptanceComment"
    assert body =~ @marker
    refute_received {:linear, _, %{issueId: "issue-1", body: _}}
  end

  test "reads all comment pages and rejects more than one active owned comment" do
    client = fn _query, variables, _opts ->
      case variables.after do
        nil ->
          {:ok, issue_response("In Review", [owned_comment("one")], true, "page-2")}

        "page-2" ->
          {:ok, issue_response("In Review", [owned_comment("two")], false)}
      end
    end

    assert {:error, :multiple_active_human_acceptance_comments} =
             HumanAcceptance.publish("issue-1", %{}, linear_client: client)
  end

  test "does not render or write outside In Review or Human Acceptance" do
    test_pid = self()

    client = fn _query, _variables, _opts ->
      send(test_pid, :linear_called)
      {:ok, issue_response("In Progress", [], false)}
    end

    assert {:error, {:invalid_issue_state, "In Progress"}} =
             HumanAcceptance.publish("issue-1", %{}, linear_client: client)

    assert_received :linear_called
    refute_received :linear_called
  end

  test "preserves GraphQL errors and performs no comment write" do
    client = fn _query, _variables, _opts -> {:ok, %{"errors" => [%{"message" => "denied"}]}} end

    assert {:error, {:linear_graphql_errors, [%{"message" => "denied"}]}} =
             HumanAcceptance.publish("issue-1", %{}, linear_client: client)
  end

  test "returns mutation failure without reporting publication" do
    client = fn query, _variables, _opts ->
      if String.contains?(query, "SymphonyHumanAcceptanceIssue") do
        {:ok, issue_response("In Review", [], false)}
      else
        {:ok, %{"data" => %{"commentCreate" => %{"success" => false, "comment" => nil}}}}
      end
    end

    assert {:error, :linear_comment_mutation_failed} =
             HumanAcceptance.publish("issue-1", %{}, linear_client: client)
  end

  test "fails closed when Linear repeats a comments cursor" do
    client = fn _query, variables, _opts ->
      {:ok, issue_response("In Review", [], true, variables.after || "cursor-1")}
    end

    assert {:error, :linear_repeated_comments_cursor} =
             HumanAcceptance.publish("issue-1", %{}, linear_client: client)
  end

  defp issue_response(state, nodes, has_next_page, end_cursor \\ nil) do
    %{
      "data" => %{
        "issue" => %{
          "id" => "uuid-1",
          "state" => %{"name" => state},
          "comments" => %{
            "nodes" => nodes,
            "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}
          }
        }
      }
    }
  end

  defp ready_evidence do
    target = %{
      "repository" => "symphony-runtime",
      "workspace" => "C:/work/MIC-185",
      "base_revision" => String.duplicate("a", 40),
      "revision" => String.duplicate("b", 40),
      "branch" => "symphony/MIC-185"
    }

    %{
      "schema_version" => 1,
      "target" => target,
      "reviewer" => %{
        "schema_version" => 1,
        "verdict" => "PASS",
        "reviewer" => "fixture-reviewer",
        "source" => "fixture",
        "target" => target
      }
    }
  end

  defp owned_comment(id) do
    %{"id" => id, "body" => "# [HUMAN ACCEPTANCE]\n\n#{@marker}\n\nold", "resolvedAt" => nil}
  end
end
