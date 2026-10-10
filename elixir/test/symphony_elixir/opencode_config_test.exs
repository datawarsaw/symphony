defmodule SymphonyElixir.OpenCodeConfigTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema.OpenCode
  alias SymphonyElixir.HarnessSelection
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Workflow

  # The OpenCode adapter candidate (5df80de / da78cbf) is developed on its own
  # branch. When it is present, the tool contract below is compared against it.
  @adapter_contract_module SymphonyElixir.OpenCode.Config

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

    test "an execution timeout above the supported execution budget is rejected" do
      for timeout_ms <- [3_600_001, 86_400_000] do
        write_workflow_file!(
          Workflow.workflow_file_path(),
          Keyword.merge(@valid_pilot, opencode_timeout_ms: timeout_ms)
        )

        assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
        assert message =~ "opencode.timeout_ms"
      end
    end

    test "the upper bound keeps the largest practical pilot budget valid" do
      write_workflow_file!(
        Workflow.workflow_file_path(),
        Keyword.merge(@valid_pilot, opencode_timeout_ms: 3_600_000)
      )

      assert :ok = Config.validate!()
      assert Config.settings!().opencode.timeout_ms == 3_600_000
    end

    test "a tool name outside the OpenCode adapter contract is rejected" do
      for tools <- [["teleport"], ["read", "execute"], ["Read"]] do
        write_workflow_file!(
          Workflow.workflow_file_path(),
          Keyword.merge(@valid_pilot, opencode_allowed_tools: tools)
        )

        assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
        assert message =~ "opencode.allowed_tools"
        assert message =~ "OpenCode adapter contract"
      end
    end

    test "an unknown tool name is rejected even while the harness is disabled" do
      write_workflow_file!(Workflow.workflow_file_path(),
        opencode_enabled: false,
        opencode_allowed_tools: ["teleport"]
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
      assert message =~ "OpenCode adapter contract"
    end

    test "a hand-built section is re-validated instead of trusted" do
      assert {:ok, %OpenCode{}} = OpenCode.validate(%OpenCode{})

      rejected = [
        %OpenCode{enabled: false, allowed_tools: ["*"]},
        %OpenCode{enabled: false, timeout_ms: 0},
        %OpenCode{enabled: false, allowed_tools: ["teleport"]},
        %OpenCode{enabled: true, allowed_tools: ["read"]}
      ]

      for section <- rejected do
        assert {:error, _changeset} = OpenCode.validate(section)
      end
    end

    test "the declared tool contract is a unique, non-empty list" do
      contract = OpenCode.known_tool_names()

      assert is_list(contract)
      refute contract == []
      assert contract == Enum.uniq(contract)
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

  describe "opencode explicit null validation" do
    @null_base %{
      "provider" => "opencode-go",
      "model" => "muse-spark-1.3-contributor",
      "timeout_ms" => 600_000,
      "allowed_tools" => ["read"],
      "allowed_issues" => ["MIC-300"]
    }
    @null_base_struct %OpenCode{
      provider: "opencode-go",
      model: "muse-spark-1.3-contributor",
      timeout_ms: 600_000,
      allowed_tools: ["read"],
      allowed_issues: ["MIC-300"]
    }

    test "an explicit null enabled is rejected for maps and structs alike" do
      for section <- [Map.put(@null_base, "enabled", nil), %{@null_base_struct | enabled: nil}] do
        assert {:error, changeset} = OpenCode.validate(section)
        assert null_errors(changeset) == %{enabled: ["must not be null: explicit true or false required"]}
      end
    end

    test "an explicit null timeout_ms is rejected for maps and structs alike" do
      for section <- [
            Map.merge(@null_base, %{"enabled" => true, "timeout_ms" => nil}),
            %{@null_base_struct | enabled: true, timeout_ms: nil}
          ] do
        assert {:error, changeset} = OpenCode.validate(section)
        assert null_errors(changeset) == %{timeout_ms: ["must not be null"]}
      end
    end

    test "a null-only section reports both fields instead of falling back to defaults" do
      assert {:error, changeset} = OpenCode.validate(%{"enabled" => nil, "timeout_ms" => nil})

      assert null_errors(changeset) == %{
               enabled: ["must not be null: explicit true or false required"],
               timeout_ms: ["must not be null"]
             }
    end

    test "absent values are not nulls and keep the disabled defaults" do
      assert {:ok, opencode} = OpenCode.validate(%{})
      assert %OpenCode{} = opencode
      refute opencode.enabled
      assert opencode.timeout_ms == 900_000
      assert opencode.allowed_tools == []
      assert opencode.allowed_issues == []
    end

    test "explicit valid values keep validating for maps and structs alike" do
      valid_map = Map.put(@null_base, "enabled", true)
      valid_struct = %{@null_base_struct | enabled: true}

      assert {:ok, from_map} = OpenCode.validate(valid_map)
      assert {:ok, from_struct} = OpenCode.validate(valid_struct)

      assert from_map == from_struct
      assert from_map.enabled
      assert from_map.timeout_ms == 600_000
    end
  end

  describe "opencode YAML null semantics through Schema.parse" do
    test "a YAML null means absent and keeps the safe defaults" do
      write_workflow_file!(Workflow.workflow_file_path(),
        opencode_enabled: nil,
        opencode_provider: "opencode-go",
        opencode_model: "muse-spark-1.3-contributor",
        opencode_timeout_ms: nil,
        opencode_allowed_tools: ["read"],
        opencode_allowed_issues: ["MIC-300"]
      )

      assert :ok = Config.validate!()

      opencode = Config.settings!().opencode
      refute opencode.enabled
      assert opencode.timeout_ms == 900_000

      assert {:codex, :opencode_disabled} =
               HarnessSelection.select(
                 %Issue{id: "issue-1", identifier: "MIC-300", dispatchable: true},
                 opencode
               )
    end

    test "a YAML null never lifts the enabled identity requirements" do
      write_workflow_file!(Workflow.workflow_file_path(),
        opencode_enabled: true,
        opencode_provider: nil,
        opencode_model: nil,
        opencode_timeout_ms: nil,
        opencode_allowed_tools: nil,
        opencode_allowed_issues: nil
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
      assert message =~ "opencode.provider"
      assert message =~ "opencode.model"
      assert message =~ "opencode.allowed_tools"
    end
  end

  # The adapter candidate is developed on its own branch. While it is absent
  # this block is not compiled, so the declared contract is only checked for
  # shape; as soon as the adapter is present the two tool sets must match.
  if Code.ensure_loaded?(@adapter_contract_module) do
    describe "OpenCode adapter tool contract" do
      test "the declared contract matches the adapter's accepted tool set" do
        contract = OpenCode.known_tool_names()

        assert {:ok, adapter_config} = @adapter_contract_module.build(allowed_tools: contract)

        assert adapter_config["tools"] |> Map.keys() |> Enum.sort() == Enum.sort(contract)

        assert {:error, {:unknown_tool_permission, ["teleport"]}} =
                 @adapter_contract_module.build(allowed_tools: ["teleport"])
      end
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

  defp null_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end
end
