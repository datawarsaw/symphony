defmodule SymphonyElixir.OpenCodeGoCredentialTest do
  @moduledoc """
  PILOT-GO-AUTH-F: native credential support for the `opencode-go` provider.

  Every credential in this suite is a synthetic placeholder. No test
  authenticates, contacts a provider, or runs a real OpenCode binary:
  adapter-level cases drive the committed C# mock, and every assertion
  depends only on presence-driven accept/reject decisions, variable NAMES
  in error reasons, and presence booleans in child evidence — never on
  credential values.
  """

  use SymphonyElixir.TestSupport

  Code.require_file("../support/mock_opencode.exs", __DIR__)

  alias SymphonyElixir.OpenCode
  alias SymphonyElixir.OpenCode.{Adapter, Environment, Failure}
  alias SymphonyElixir.TestSupport.MockOpenCode

  @synthetic_go_key "sk-opencode-go-synthetic-placeholder"
  @synthetic_anthropic "sk-ant-synthetic-go-suite-placeholder"
  @synthetic_openai "sk-openai-synthetic-go-suite-placeholder"

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "opencode-go-credential-ws-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    {:ok, workspace: workspace}
  end

  # Applies key => value (nil deletes) and restores the prior BEAM
  # environment afterwards, so preflight decisions are deterministic no
  # matter which ambient credentials the host machine carries.
  defp with_credential_env(overrides, fun) do
    saved = Map.new(Map.keys(overrides), &{&1, System.get_env(&1)})

    Enum.each(overrides, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)

    try do
      fun.()
    after
      Enum.each(saved, fn {key, value} -> restore_env(key, value) end)
    end
  end

  defp without_go_key(fun), do: with_credential_env(%{"OPENCODE_API_KEY" => nil}, fun)

  # ===========================================================================
  # 1. Native mapping: opencode-go only, never the opencode Zen provider
  # ===========================================================================

  describe "provider credential mapping" do
    test "opencode-go maps to exactly OPENCODE_API_KEY" do
      assert {:ok, ["OPENCODE_API_KEY"]} = Environment.provider_auth_keys("opencode-go")
    end

    test "normalizes the provider identifier case and surrounding blanks" do
      assert {:ok, ["OPENCODE_API_KEY"]} = Environment.provider_auth_keys("  OpenCode-Go ")
    end

    test "the separately billed opencode Zen provider is deliberately unmapped" do
      with_credential_env(%{"OPENCODE_API_KEY" => @synthetic_go_key}, fn ->
        assert {:error, {:unsupported_provider, "opencode"}} =
                 Environment.provider_auth_keys("opencode")

        assert {:error, {:unsupported_provider, "opencode"}} =
                 Environment.preflight_provider_credentials("opencode")
      end)
    end
  end

  # ===========================================================================
  # 2. Preflight: synthetic key present, missing, empty
  # ===========================================================================

  describe "preflight_provider_credentials/2 for opencode-go" do
    test "accepts a synthetic ambient OPENCODE_API_KEY" do
      with_credential_env(%{"OPENCODE_API_KEY" => @synthetic_go_key}, fn ->
        assert :ok = Environment.preflight_provider_credentials("opencode-go")
      end)
    end

    test "accepts a caller-supplied synthetic key through provider_auth" do
      without_go_key(fn ->
        assert :ok =
                 Environment.preflight_provider_credentials("opencode-go",
                   provider_auth: %{"OPENCODE_API_KEY" => @synthetic_go_key}
                 )
      end)
    end

    test "refuses a missing key" do
      without_go_key(fn ->
        assert {:error, {:missing_provider_credential, "opencode-go"}} =
                 Environment.preflight_provider_credentials("opencode-go")
      end)
    end

    test "an empty-string key does not satisfy presence" do
      with_credential_env(%{"OPENCODE_API_KEY" => ""}, fn ->
        assert {:error, {:missing_provider_credential, "opencode-go"}} =
                 Environment.preflight_provider_credentials("opencode-go")
      end)
    end

    test "refuses credentials requested for variables outside the Go allowlist" do
      with_credential_env(%{"OPENCODE_API_KEY" => @synthetic_go_key}, fn ->
        assert {:error, {:unauthorized_credential, "OPENAI_API_KEY"}} =
                 Environment.preflight_provider_credentials("opencode-go",
                   provider_auth: %{"OPENAI_API_KEY" => @synthetic_openai}
                 )
      end)
    end
  end

  # ===========================================================================
  # 3. build_port_env: the key travels only with the opencode-go launch
  # ===========================================================================

  describe "build_port_env/3 Go credential isolation" do
    test "an opencode-go launch carries the key and denies competitor secrets", %{workspace: workspace} do
      with_credential_env(
        %{
          "OPENCODE_API_KEY" => @synthetic_go_key,
          "OPENAI_API_KEY" => @synthetic_openai,
          "ANTHROPIC_API_KEY" => @synthetic_anthropic
        },
        fn ->
          {:ok, dirs} = Environment.prepare_directories(workspace, "go-carry")
          {:ok, port_env} = Environment.build_port_env("opencode-go", dirs)

          env_map = Map.new(port_env, fn {k, v} -> {List.to_string(k), v} end)
          assert env_map["OPENCODE_API_KEY"] == String.to_charlist(@synthetic_go_key)
          assert env_map["OPENAI_API_KEY"] == false
          assert env_map["ANTHROPIC_API_KEY"] == false
          assert env_map["CODEX_API_KEY"] == false
          assert env_map["LINEAR_API_KEY"] == false
          assert env_map["OPENCODE_AUTH_CONTENT"] == false
        end
      )
    end

    test "every competing provider launch denies the Go key", %{workspace: workspace} do
      with_credential_env(
        %{
          "OPENCODE_API_KEY" => @synthetic_go_key,
          "ANTHROPIC_API_KEY" => @synthetic_anthropic,
          "OPENAI_API_KEY" => @synthetic_openai,
          "CODEX_API_KEY" => "codex-synthetic-go-suite-placeholder"
        },
        fn ->
          Enum.each(["anthropic", "openai", "codex"], fn provider ->
            {:ok, dirs} = Environment.prepare_directories(workspace, "go-deny-#{provider}")
            {:ok, port_env} = Environment.build_port_env(provider, dirs)

            env_map = Map.new(port_env, fn {k, v} -> {List.to_string(k), v} end)

            assert env_map["OPENCODE_API_KEY"] == false,
                   "OPENCODE_API_KEY leaked into a #{provider} launch"
          end)
        end
      )
    end
  end

  # ===========================================================================
  # 4. No secret leakage: errors and failure info name variables, never values
  # ===========================================================================

  describe "secret hygiene" do
    test "error reasons never contain the synthetic key value" do
      without_go_key(fn ->
        errors = [
          elem(Environment.preflight_provider_credentials("opencode-go"), 1),
          elem(Environment.preflight_provider_credentials("opencode"), 1)
        ]

        Enum.each(errors, fn reason ->
          refute inspect(reason) =~ @synthetic_go_key
        end)
      end)
    end

    test "failure messages name the provider but never the key value" do
      without_go_key(fn ->
        {:error, reason} =
          OpenCode.run("/nonexistent-go-credential-dir", "prompt",
            provider: "opencode-go",
            model: "mock-model"
          )

        assert {:missing_provider_credential, "opencode-go"} = reason

        info = Failure.failure_info(reason)
        assert info.message =~ "opencode-go"
        refute info.message =~ @synthetic_go_key
        refute inspect(info.raw) =~ @synthetic_go_key
      end)
    end

    test "prelaunch refusals classify as persistent worker failures" do
      assert :persistent_worker_failure =
               Failure.classify({:missing_provider_credential, "opencode-go"})

      assert :persistent_worker_failure = Failure.classify({:unsupported_provider, "opencode"})

      assert :persistent_worker_failure =
               Failure.classify({:unauthorized_credential, "OPENCODE_API_KEY"})
    end
  end

  # ===========================================================================
  # 5. Adapter: refusal before process creation, mock launch with identity
  # ===========================================================================

  describe "Adapter opencode-go launches" do
    @describetag :windows_only
    @describetag :opencode_integration

    test "refuses a keyless opencode-go launch before any launch artifact or child exists", %{
      workspace: workspace
    } do
      mock_exe = MockOpenCode.ensure_built!()

      without_go_key(fn ->
        assert {:error, {:missing_provider_credential, "opencode-go"}} =
                 Adapter.start_session(workspace, "hello",
                   provider: "opencode-go",
                   model: "mock-model",
                   executable: mock_exe,
                   launch_id: "go-no-cred"
                 )

        # The preflight runs before directory/config/marker creation: nothing
        # for this launch id may exist on disk, and no child process ran.
        refute File.exists?(Path.join([workspace, ".symphony-state", "opencode", "go-no-cred"]))
      end)
    end

    test "refuses the opencode Zen provider with the Go key present", %{workspace: workspace} do
      mock_exe = MockOpenCode.ensure_built!()

      with_credential_env(%{"OPENCODE_API_KEY" => @synthetic_go_key}, fn ->
        assert {:error, {:unsupported_provider, "opencode"}} =
                 Adapter.start_session(workspace, "hello",
                   provider: "opencode",
                   model: "mock-model",
                   executable: mock_exe,
                   launch_id: "go-zen-refused"
                 )

        refute File.exists?(Path.join([workspace, ".symphony-state", "opencode", "go-zen-refused"]))
      end)
    end

    test "a mock launch with the key present pins the opencode-go identity", %{workspace: workspace} do
      mock_exe = MockOpenCode.ensure_built!()

      session =
        with_credential_env(%{"OPENCODE_API_KEY" => @synthetic_go_key}, fn ->
          assert {:ok, session} =
                   Adapter.start_session(workspace, "hello",
                     provider: "opencode-go",
                     model: "mock-model",
                     executable: mock_exe,
                     launch_id: "go-identity"
                   )

          session
        end)

      # Identity stays pinned to the operator's selection: the native Go
      # provider and model, no substitution.
      assert session.provider == "opencode-go"
      assert session.model == "mock-model"
      assert session.launch_id == "go-identity"

      Adapter.stop_session(session)
    end

    test "the mock child receives only the Go key, and no key value reaches evidence", %{
      workspace: workspace
    } do
      mock_exe = MockOpenCode.ensure_built!()

      with_credential_env(
        %{
          "OPENCODE_API_KEY" => @synthetic_go_key,
          "ANTHROPIC_API_KEY" => @synthetic_anthropic,
          "OPENAI_API_KEY" => @synthetic_openai,
          "LINEAR_API_KEY" => "linear-synthetic-go-suite-placeholder"
        },
        fn ->
          assert {:ok, result} =
                   OpenCode.run(workspace, "--mock-mode=env",
                     provider: "opencode-go",
                     model: "mock-model",
                     executable: mock_exe,
                     timeout_ms: 8_000
                   )

          assert result.completion_state == :completed

          path = Path.join(workspace, "opencode-child-evidence.json")
          raw = File.read!(path)
          evidence = Jason.decode!(raw)

          # Presence booleans only: the selected provider's key is visible to
          # the child, competitor and tracker secrets are not, and no value
          # is ever written into the evidence file.
          assert evidence["OPENCODE_API_KEY"] == true
          assert evidence["ANTHROPIC_API_KEY"] == false
          assert evidence["OPENAI_API_KEY"] == false
          assert evidence["LINEAR_API_KEY"] == false
          refute raw =~ @synthetic_go_key
          refute raw =~ @synthetic_anthropic
          refute raw =~ @synthetic_openai
        end
      )
    end
  end
end
