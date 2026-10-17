defmodule SymphonyElixir.OpenCodeCredentialPreflightTest do
  @moduledoc """
  PILOT-AUTH-F: offline credential presence preflight for the OpenCode pilot.

  Every credential in this suite is a synthetic placeholder. No test
  authenticates, contacts a provider, or runs a real OpenCode binary:
  adapter-level cases drive the committed C# mock, and every assertion
  depends only on presence-driven accept/reject decisions and on variable
  NAMES in error reasons — never on credential values.
  """

  use SymphonyElixir.TestSupport

  Code.require_file("../support/mock_opencode.exs", __DIR__)

  alias SymphonyElixir.OpenCode
  alias SymphonyElixir.OpenCode.{Adapter, Environment, Failure}
  alias SymphonyElixir.TestSupport.MockOpenCode

  @synthetic_anthropic "sk-ant-synthetic-preflight-placeholder"
  @synthetic_openai "sk-openai-synthetic-preflight-placeholder"
  @synthetic_redirect "https://synthetic-redirect.example.invalid/api"

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "opencode-preflight-ws-#{System.unique_integer([:positive])}")

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

  defp without_anthropic(fun), do: with_credential_env(%{"ANTHROPIC_API_KEY" => nil}, fun)

  defp without_openai(fun) do
    with_credential_env(
      %{
        "OPENAI_API_KEY" => nil,
        "OPENAI_BASE_URL" => nil,
        "OPENAI_ORG_ID" => nil,
        "OPENAI_PROJECT_ID" => nil
      },
      fun
    )
  end

  # ===========================================================================
  # 1. Preflight unit contract (pure, presence-only)
  # ===========================================================================

  describe "preflight_provider_credentials/2" do
    test "accepts a mapped provider with a synthetic credential in the BEAM environment" do
      with_credential_env(%{"ANTHROPIC_API_KEY" => @synthetic_anthropic}, fn ->
        assert :ok = Environment.preflight_provider_credentials("anthropic")
      end)
    end

    test "accepts a caller-supplied synthetic credential and normalizes the provider identifier" do
      without_anthropic(fn ->
        assert :ok =
                 Environment.preflight_provider_credentials("  Anthropic ",
                   provider_auth: %{"ANTHROPIC_API_KEY" => @synthetic_anthropic}
                 )
      end)
    end

    test "rejects unmapped provider identifiers before launch" do
      with_credential_env(%{"ANTHROPIC_API_KEY" => @synthetic_anthropic}, fn ->
        assert {:error, {:unsupported_provider, "mockprovider"}} =
                 Environment.preflight_provider_credentials("mockprovider")

        assert {:error, {:unsupported_provider, ""}} =
                 Environment.preflight_provider_credentials("   ")
      end)
    end

    test "rejects a mapped provider with no nonempty credential variable" do
      without_anthropic(fn ->
        assert {:error, {:missing_provider_credential, "anthropic"}} =
                 Environment.preflight_provider_credentials("anthropic")
      end)
    end

    test "empty-string credential values do not satisfy presence" do
      with_credential_env(%{"ANTHROPIC_API_KEY" => ""}, fn ->
        assert {:error, {:missing_provider_credential, "anthropic"}} =
                 Environment.preflight_provider_credentials("anthropic")
      end)
    end

    test "an endpoint/base-URL variable alone never satisfies credential presence" do
      without_openai(fn ->
        # Authorized endpoint, still no credential: refused for the missing
        # credential, proving endpoint keys are not credentials.
        assert {:error, {:missing_provider_credential, "openai"}} =
                 Environment.preflight_provider_credentials("openai",
                   provider_auth: %{"OPENAI_BASE_URL" => @synthetic_redirect}
                 )

        # Ambient endpoint only: same refusal.
        with_credential_env(%{"OPENAI_BASE_URL" => @synthetic_redirect}, fn ->
          assert {:error, {:missing_provider_credential, "openai"}} =
                   Environment.preflight_provider_credentials("openai")
        end)
      end)
    end

    test "rejects an ambient endpoint override that could redirect credentials" do
      without_openai(fn ->
        with_credential_env(
          %{"OPENAI_API_KEY" => @synthetic_openai, "OPENAI_BASE_URL" => @synthetic_redirect},
          fn ->
            assert {:error, {:unexpected_endpoint_override, "OPENAI_BASE_URL"}} =
                     Environment.preflight_provider_credentials("openai")
          end
        )
      end)
    end

    test "azure endpoint and databricks host overrides are endpoint-shaped" do
      with_credential_env(
        %{
          "AZURE_OPENAI_API_KEY" => "synthetic-azure-placeholder",
          "AZURE_OPENAI_ENDPOINT" => @synthetic_redirect,
          "DATABRICKS_TOKEN" => "synthetic-databricks-placeholder",
          "DATABRICKS_HOST" => @synthetic_redirect
        },
        fn ->
          assert {:error, {:unexpected_endpoint_override, "AZURE_OPENAI_ENDPOINT"}} =
                   Environment.preflight_provider_credentials("azure")

          assert {:error, {:unexpected_endpoint_override, "DATABRICKS_HOST"}} =
                   Environment.preflight_provider_credentials("databricks")
        end
      )
    end

    test "accepts an endpoint override explicitly supplied through provider_auth" do
      without_openai(fn ->
        with_credential_env(%{"OPENAI_BASE_URL" => @synthetic_redirect}, fn ->
          assert :ok =
                   Environment.preflight_provider_credentials("openai",
                     provider_auth: %{
                       "OPENAI_API_KEY" => @synthetic_openai,
                       "OPENAI_BASE_URL" => @synthetic_redirect
                     }
                   )
        end)
      end)
    end

    test "error reasons never contain credential values" do
      without_openai(fn ->
        with_credential_env(
          %{"OPENAI_API_KEY" => @synthetic_openai, "OPENAI_BASE_URL" => @synthetic_redirect},
          fn ->
            errors = [
              elem(Environment.preflight_provider_credentials("openai"), 1),
              elem(Environment.preflight_provider_credentials("azure"), 1)
            ]

            Enum.each(errors, fn reason ->
              refute inspect(reason) =~ @synthetic_openai
              refute inspect(reason) =~ @synthetic_redirect
            end)
          end
        )
      end)
    end
  end

  # ===========================================================================
  # 2. build_port_env shares the same preflight (single mapping source)
  # ===========================================================================

  describe "build_port_env/3 preflight integration" do
    test "refuses an unmapped provider", %{workspace: workspace} do
      with_credential_env(%{"ANTHROPIC_API_KEY" => @synthetic_anthropic}, fn ->
        {:ok, dirs} = Environment.prepare_directories(workspace, "preflight-unmapped")

        assert {:error, {:unsupported_provider, "mockprovider"}} =
                 Environment.build_port_env("mockprovider", dirs)
      end)
    end

    test "refuses a mapped provider without credentials", %{workspace: workspace} do
      {:ok, dirs} = Environment.prepare_directories(workspace, "preflight-missing")

      without_anthropic(fn ->
        assert {:error, {:missing_provider_credential, "anthropic"}} =
                 Environment.build_port_env("anthropic", dirs)
      end)
    end

    test "refuses an ambient endpoint override before building the child env", %{workspace: workspace} do
      without_openai(fn ->
        with_credential_env(
          %{"OPENAI_API_KEY" => @synthetic_openai, "OPENAI_BASE_URL" => @synthetic_redirect},
          fn ->
            {:ok, dirs} = Environment.prepare_directories(workspace, "preflight-endpoint")

            assert {:error, {:unexpected_endpoint_override, "OPENAI_BASE_URL"}} =
                     Environment.build_port_env("openai", dirs)
          end
        )
      end)
    end

    test "carries the resolved synthetic credential and denies competitor keys", %{workspace: workspace} do
      with_credential_env(%{"ANTHROPIC_API_KEY" => @synthetic_anthropic}, fn ->
        {:ok, dirs} = Environment.prepare_directories(workspace, "preflight-carry")
        {:ok, port_env} = Environment.build_port_env("anthropic", dirs)

        env_map = Map.new(port_env, fn {k, v} -> {List.to_string(k), v} end)
        assert env_map["ANTHROPIC_API_KEY"] == String.to_charlist(@synthetic_anthropic)
        assert env_map["OPENAI_API_KEY"] == false
        assert env_map["LINEAR_API_KEY"] == false
      end)
    end
  end

  # ===========================================================================
  # 3. Adapter placement: before child-process creation and per-launch
  # ===========================================================================

  describe "Adapter.start_session preflight placement" do
    @describetag :windows_only
    @describetag :opencode_integration

    test "refuses a credentialless launch before any launch artifact or child exists", %{
      workspace: workspace
    } do
      mock_exe = MockOpenCode.ensure_built!()

      without_anthropic(fn ->
        assert {:error, {:missing_provider_credential, "anthropic"}} =
                 Adapter.start_session(workspace, "hello",
                   provider: "anthropic",
                   model: "claude-3-5-sonnet",
                   executable: mock_exe,
                   launch_id: "preflight-no-cred"
                 )

        # The preflight runs before directory/config/marker creation: nothing
        # for this launch id may exist on disk, and no child process ran.
        refute File.exists?(Path.join([workspace, ".symphony-state", "opencode", "preflight-no-cred"]))
      end)
    end

    test "refuses an unmapped provider before launch", %{workspace: workspace} do
      mock_exe = MockOpenCode.ensure_built!()

      with_credential_env(%{"ANTHROPIC_API_KEY" => @synthetic_anthropic}, fn ->
        assert {:error, {:unsupported_provider, "mockprovider"}} =
                 Adapter.start_session(workspace, "hello",
                   provider: "mockprovider",
                   model: "mock-model",
                   executable: mock_exe,
                   launch_id: "preflight-unmapped-provider"
                 )

        refute File.exists?(Path.join([workspace, ".symphony-state", "opencode", "preflight-unmapped-provider"]))
      end)
    end

    test "refuses an ambient endpoint override even with a credential present", %{workspace: workspace} do
      mock_exe = MockOpenCode.ensure_built!()

      without_openai(fn ->
        with_credential_env(
          %{"OPENAI_API_KEY" => @synthetic_openai, "OPENAI_BASE_URL" => @synthetic_redirect},
          fn ->
            assert {:error, {:unexpected_endpoint_override, "OPENAI_BASE_URL"}} =
                     Adapter.start_session(workspace, "hello",
                       provider: "openai",
                       model: "gpt-4o",
                       executable: mock_exe,
                       launch_id: "preflight-endpoint-adapter"
                     )
          end
        )
      end)
    end

    test "re-evaluates credential presence on every launch after environment changes", %{
      workspace: workspace
    } do
      mock_exe = MockOpenCode.ensure_built!()

      opts = [
        provider: "anthropic",
        model: "claude-3-5-sonnet",
        executable: mock_exe
      ]

      # No credential yet: refused. The pilot snapshot/configuration is not
      # cached anywhere — the next attempt must re-read the live environment
      # the way a post-reload re-dispatch does.
      without_anthropic(fn ->
        assert {:error, {:missing_provider_credential, "anthropic"}} =
                 Adapter.start_session(workspace, "first", opts)
      end)

      session =
        with_credential_env(%{"ANTHROPIC_API_KEY" => @synthetic_anthropic}, fn ->
          assert {:ok, session} = Adapter.start_session(workspace, "second", opts)
          session
        end)

      # Identity stays pinned to the operator's selection on the accepted
      # launch: same provider and model, no substitution.
      assert session.provider == "anthropic"
      assert session.model == "claude-3-5-sonnet"
      Adapter.stop_session(session)

      without_anthropic(fn ->
        assert {:error, {:missing_provider_credential, "anthropic"}} =
                 Adapter.start_session(workspace, "third", opts)
      end)
    end

    test "failure classification parks preflight rejections without retry churn" do
      assert :persistent_worker_failure = Failure.classify({:unsupported_provider, "mockprovider"})

      assert :persistent_worker_failure =
               Failure.classify({:missing_provider_credential, "anthropic"})

      assert :persistent_worker_failure =
               Failure.classify({:unexpected_endpoint_override, "OPENAI_BASE_URL"})
    end

    test "failure messages name providers and variables but never credential values" do
      without_openai(fn ->
        with_credential_env(
          %{"OPENAI_API_KEY" => @synthetic_openai, "OPENAI_BASE_URL" => @synthetic_redirect},
          fn ->
            {:error, reason} = OpenCode.run("/nonexistent-preflight-dir", "prompt", provider: "openai", model: "gpt-4o")

            info = Failure.failure_info(reason)
            assert info.message =~ "OPENAI_BASE_URL"
            assert inspect(reason) =~ "OPENAI_BASE_URL"
            refute info.message =~ @synthetic_openai
            refute info.message =~ @synthetic_redirect
            refute inspect(info.raw) =~ @synthetic_redirect
          end
        )
      end)
    end
  end
end
