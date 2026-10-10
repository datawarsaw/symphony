defmodule SymphonyElixir.HarnessSelectionTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema.OpenCode
  alias SymphonyElixir.HarnessSelection
  alias SymphonyElixir.Tracker.Issue

  @authorized_issue %Issue{id: "issue-300", identifier: "MIC-300", dispatchable: true}
  @other_issue %Issue{id: "issue-301", identifier: "MIC-301", dispatchable: true}

  @pilot %OpenCode{
    enabled: true,
    provider: "opencode-go",
    model: "muse-spark-1.3-contributor",
    timeout_ms: 900_000,
    allowed_tools: ["read", "grep"],
    allowed_issues: ["MIC-300"]
  }

  describe "select/2 disabled default" do
    test "a disabled section keeps Codex for every issue" do
      assert {:codex, :opencode_disabled} = HarnessSelection.select(@authorized_issue, %OpenCode{})
      assert {:codex, :opencode_disabled} = HarnessSelection.select(nil, %OpenCode{})
    end

    test "a missing section keeps Codex" do
      assert {:codex, :opencode_disabled} = HarnessSelection.select(@authorized_issue, nil)
    end
  end

  describe "select/2 fail-closed configuration" do
    test "an enabled pilot without an explicit provider and model refuses an authorized issue" do
      incomplete = %OpenCode{
        enabled: true,
        allowed_tools: ["read"],
        allowed_issues: ["MIC-300"]
      }

      assert {:error, :invalid_opencode_config} =
               HarnessSelection.select(@authorized_issue, incomplete)
    end

    test "an enabled pilot without any allowed tool refuses an authorized issue" do
      no_tools = %{@pilot | allowed_tools: []}

      assert {:error, :invalid_opencode_config} =
               HarnessSelection.select(@authorized_issue, no_tools)
    end

    test "a blank tool entry never grants the harness" do
      blank_tool = %{@pilot | allowed_tools: [""]}

      assert {:error, :invalid_opencode_config} =
               HarnessSelection.select(@authorized_issue, blank_tool)
    end

    test "a hand-built struct cannot bypass the tool or timeout checks" do
      invalid_sections = [
        %{@pilot | allowed_tools: ["*"]},
        %{@pilot | allowed_tools: ["teleport"]},
        %{@pilot | timeout_ms: 0},
        %{@pilot | timeout_ms: 3_600_001}
      ]

      for section <- invalid_sections do
        assert {:error, :invalid_opencode_config} =
                 HarnessSelection.select(@authorized_issue, section)
      end
    end

    test "an invalid section for an issue outside its scope stays on Codex" do
      invalid = %{@pilot | allowed_tools: ["*"]}

      assert {:codex, :invalid_opencode_config} =
               HarnessSelection.select(@other_issue, invalid)
    end

    test "a map the schema rejects refuses an authorized issue" do
      assert {:error, :invalid_opencode_config} =
               HarnessSelection.select(@authorized_issue, %{enabled: true, allowed_issues: ["MIC-300"]})
    end

    test "a non-map configuration stays on Codex" do
      assert {:codex, :invalid_opencode_config} =
               HarnessSelection.select(@authorized_issue, :missing)
    end
  end

  describe "select/2 issue authorization" do
    test "an unauthorized issue stays on Codex" do
      assert {:codex, :issue_not_authorized} = HarnessSelection.select(@other_issue, @pilot)
    end

    test "an empty issue allowlist authorizes no issue" do
      no_issues = %{@pilot | allowed_issues: []}

      assert {:codex, :issue_not_authorized} = HarnessSelection.select(@authorized_issue, no_issues)
    end

    test "a missing or blank issue identifier stays on Codex" do
      assert {:codex, :issue_not_authorized} = HarnessSelection.select(nil, @pilot)

      blank_identifier = %Issue{id: "issue-302", identifier: "   "}
      assert {:codex, :issue_not_authorized} = HarnessSelection.select(blank_identifier, @pilot)

      assert {:codex, :issue_not_authorized} = HarnessSelection.select(%{identifier: "MIC-300"}, @pilot)
    end
  end

  describe "select/2 authorized selection" do
    test "an authorized issue selects OpenCode" do
      assert {:opencode, :opencode_selected} = HarnessSelection.select(@authorized_issue, @pilot)
    end

    test "authorization ignores case and surrounding whitespace" do
      spaced = %Issue{id: "issue-303", identifier: " mic-300 "}

      assert {:opencode, :opencode_selected} = HarnessSelection.select(spaced, @pilot)
    end

    test "a plain map configuration is normalized through the schema" do
      config = %{
        "enabled" => true,
        "provider" => "opencode-go",
        "model" => "muse-spark-1.3-contributor",
        "timeout_ms" => 120_000,
        "allowed_tools" => ["read"],
        "allowed_issues" => ["MIC-300"]
      }

      assert {:opencode, :opencode_selected} = HarnessSelection.select(@authorized_issue, config)
    end
  end

  describe "module ownership" do
    test "the policy is pure: no launch, state, configuration, or fallback surface" do
      source = File.read!(Path.expand("../../lib/symphony_elixir/harness_selection.ex", __DIR__))
      definition = ~r/^\s*def(p)?\s+([a-zA-Z_?!][a-zA-Z_?!0-9]*)/

      public_names =
        source
        |> String.split("\n")
        |> Enum.flat_map(fn line ->
          case Regex.run(definition, line) do
            [_, "", name] -> [String.to_atom(name)]
            _ -> []
          end
        end)

      assert public_names == [:select]

      refute Regex.match?(~r/System\.cmd|Port\.open|:os\.cmd|Task\.|GenServer|Process\.|Supervisor/, source)
      refute Regex.match?(~r/File\.|:file\.|Config\.settings|Application\.get_env|Ecto\.Repo/, source)
      refute Regex.match?(~r/fallback_provider|next_provider|alternate_provider|provider_fallback/, source)
    end
  end
end
