defmodule SymphonyElixir.OpenCodeConfigTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema.OpenCode
  alias SymphonyElixir.HarnessSelection
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Workflow

  @valid_pilot [
    opencode_enabled: true,
    opencode_provider: "opencode-go",
    opencode_model: "muse-spark-1.3-contributor",
    opencode_timeout_ms: 600_000,
    opencode_allowed_tools: ["read", "grep", "edit"],
    opencode_allowed_issues: ["MIC-300"]
  ]

  describe "opencode configuration contract" do
    test "the section is disabled by default and carries only pilot identity" do
      settings = Config.settings!()

      assert %OpenCode{} = settings.opencode
      refute settings.opencode.enabled
      assert settings.opencode.provider == nil
      assert settings.opencode.model == nil
      assert settings.opencode.timeout_ms == 900_000
      assert settings.opencode.allowed_tools == []
      assert settings.opencode.allowed_issues == []

      assert settings.opencode
             |> Map.from_struct()
             |> Map.keys()
             |> Enum.sort() ==
               [:allowed_issues, :allowed_tools, :enabled, :model, :provider, :timeout_ms]
    end

    test "an explicit pilot validates and normalizes its allowlists" do
      write_workflow_file!(Workflow.workflow_file_path(),
        opencode_enabled: true,
        opencode_provider: " opencode-go ",
        opencode_model: "muse-spark-1.3-contributor",
        opencode_timeout_ms: 600_000,
        opencode_allowed_tools: ["read", "read", " grep "],
        opencode_allowed_issues: ["MIC-300", " MIC-300 "]
      )

      assert :ok = Config.validate!()

      opencode = Config.settings!().opencode
      assert opencode.enabled
      assert opencode.provider == "opencode-go"
      assert opencode.timeout_ms == 600_000
      assert opencode.allowed_tools == ["read", "grep"]
      assert opencode.allowed_issues == ["MIC-300"]
    end

    test "enabling the harness without an explicit identity or tool allowlist is rejected" do
      write_workflow_file!(Workflow.workflow_file_path(), opencode_enabled: true)

      assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
      assert message =~ "opencode.provider"
      assert message =~ "opencode.model"
      assert message =~ "opencode.allowed_tools"
    end

    test "a blank provider is rejected even when the model is set" do
      write_workflow_file!(
        Workflow.workflow_file_path(),
        Keyword.merge(@valid_pilot, opencode_provider: "   ")
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
      assert message =~ "opencode.provider"
      refute message =~ "opencode.model"
    end

    test "an enabled section without any allowed tool is rejected" do
      write_workflow_file!(
        Workflow.workflow_file_path(),
        Keyword.merge(@valid_pilot, opencode_allowed_tools: [])
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
      assert message =~ "opencode.allowed_tools"
    end

    test "an unrestricted tool grant is rejected" do
      for tools <- [["*"], ["read", "all"], ["Any"]] do
        write_workflow_file!(
          Workflow.workflow_file_path(),
          Keyword.merge(@valid_pilot, opencode_allowed_tools: tools)
        )

        assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
        assert message =~ "opencode.allowed_tools"
        assert message =~ "unrestricted"
      end
    end

    test "an unrestricted tool grant is rejected even while the harness is disabled" do
      write_workflow_file!(Workflow.workflow_file_path(),
        opencode_enabled: false,
        opencode_allowed_tools: ["*"]
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
      assert message =~ "unrestricted"
    end

    test "a non-positive or non-numeric execution timeout is rejected" do
      write_workflow_file!(
        Workflow.workflow_file_path(),
        Keyword.merge(@valid_pilot, opencode_timeout_ms: 0)
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
      assert message =~ "opencode.timeout_ms"

      write_workflow_file!(
        Workflow.workflow_file_path(),
        Keyword.merge(@valid_pilot, opencode_timeout_ms: "soon")
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
      assert message =~ "opencode.timeout_ms"
    end

    test "blank allowlist entries are rejected" do
      write_workflow_file!(
        Workflow.workflow_file_path(),
        Keyword.merge(@valid_pilot,
          opencode_allowed_tools: ["read", "  "],
          opencode_allowed_issues: ["MIC-300", ""]
        )
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
      assert message =~ "opencode.allowed_tools entries must not be blank"
      assert message =~ "opencode.allowed_issues entries must not be blank"
    end

    test "a disabled section accepts an omitted identity and authorizes nothing" do
      write_workflow_file!(Workflow.workflow_file_path(),
        opencode_enabled: false,
        opencode_provider: "   "
      )

      assert :ok = Config.validate!()

      opencode = Config.settings!().opencode
      refute opencode.enabled
      assert opencode.provider == nil
      assert opencode.timeout_ms == 900_000
    end
  end

  describe "opencode configuration to harness policy" do
    test "an absent section keeps Codex for an otherwise eligible issue" do
      assert :ok = Config.validate!()

      issue = %Issue{id: "issue-1", identifier: "MIC-300", dispatchable: true}

      assert {:codex, :opencode_disabled} =
               HarnessSelection.select(issue, Config.settings!().opencode)
    end

    test "the parsed pilot selects OpenCode only for an authorized issue" do
      write_workflow_file!(Workflow.workflow_file_path(), @valid_pilot)

      assert :ok = Config.validate!()
      opencode = Config.settings!().opencode

      authorized = %Issue{id: "issue-1", identifier: "MIC-300", dispatchable: true}
      unauthorized = %Issue{id: "issue-2", identifier: "MIC-301", dispatchable: true}

      assert {:opencode, :opencode_selected} = HarnessSelection.select(authorized, opencode)
      assert {:codex, :issue_not_authorized} = HarnessSelection.select(unauthorized, opencode)
    end

    test "an enabled section with an empty issue allowlist authorizes no issue" do
      write_workflow_file!(
        Workflow.workflow_file_path(),
        Keyword.merge(@valid_pilot, opencode_allowed_issues: [])
      )

      assert :ok = Config.validate!()

      opencode = Config.settings!().opencode
      assert opencode.allowed_issues == []

      issue = %Issue{id: "issue-1", identifier: "MIC-300", dispatchable: true}

      assert {:codex, :issue_not_authorized} = HarnessSelection.select(issue, opencode)
    end
  end
end
