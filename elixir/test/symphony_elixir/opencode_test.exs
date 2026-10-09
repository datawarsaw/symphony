defmodule SymphonyElixir.OpenCodeTest do
  use SymphonyElixir.TestSupport

  Code.require_file("../support/mock_opencode.exs", __DIR__)

  alias SymphonyElixir.FailureClass
  alias SymphonyElixir.OpenCode
  alias SymphonyElixir.OpenCode.{Adapter, Config, Environment, Failure, Parser}
  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.TestSupport.MockOpenCode
  alias SymphonyElixir.WorkerContainment

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "opencode-test-workspace-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)

    on_exit(fn ->
      File.rm_rf(workspace)
    end)

    {:ok, workspace: workspace}
  end

  # ===========================================================================
  # 1. Config & Permission Denial (Deny-by-default)
  # ===========================================================================

  describe "Config & Permission Denial" do
    test "config generation sets deny-by-default for all tools and disables plugins" do
      {:ok, config} = Config.build()

      assert config["$schema"] == "https://opencode.ai/config.json"
      assert config["plugin"] == []
      assert is_map(config["permission"])
      assert config["permission"]["*"] == "deny"
      assert config["permission"]["read"] == "deny"
      assert config["permission"]["edit"] == "deny"
      assert config["permission"]["bash"] == "deny"
      assert config["permission"]["task"] == "deny"
      assert config["permission"]["websearch"] == "deny"
    end

    test "config generation allows only explicitly listed tools and denies the rest" do
      {:ok, config} = Config.build(allowed_tools: ["read", "glob"])

      assert config["permission"]["read"] == "allow"
      assert config["permission"]["glob"] == "allow"
      assert config["permission"]["edit"] == "deny"
      assert config["permission"]["bash"] == "deny"
      assert config["permission"]["*"] == "deny"
    end

    test "unrestricted permissions fail closed" do
      assert {:error, :unrestricted_permissions_forbidden} =
               Config.build(allowed_tools: ["*"])

      assert {:error, :unrestricted_permissions_forbidden} =
               Config.build(allowed_tools: ["all"])

      assert {:error, :unrestricted_permissions_forbidden} =
               Config.build(unrestricted_permissions: true)

      assert {:error, :unrestricted_permissions_forbidden} =
               Config.build(auto_approve: true)
    end

    test "write_config writes valid JSON in both config root and opencode subfolder", %{workspace: workspace} do
      config_dir = Path.join(workspace, "config")
      File.mkdir_p!(config_dir)

      assert {:ok, sub_file} = Config.write_config(config_dir, allowed_tools: [:read])
      assert File.exists?(sub_file)

      root_file = Path.join(config_dir, "opencode.json")
      assert File.exists?(root_file)

      parsed = Jason.decode!(File.read!(sub_file))
      assert parsed["permission"]["read"] == "allow"
      assert parsed["permission"]["bash"] == "deny"
      assert parsed["permission"]["*"] == "deny"
    end
  end

  # ===========================================================================
  # 2. Environment Isolation & Credential Scrubbing
  # ===========================================================================

  describe "Environment Isolation & Credential Scrubbing" do
    test "prepare_directories creates isolated subtree under workspace", %{workspace: workspace} do
      launch_id = "test-launch-1"
      assert {:ok, dirs} = Environment.prepare_directories(workspace, launch_id)
      assert {:ok, canonical_workspace} = PathSafety.canonicalize(workspace)

      assert File.dir?(dirs.data)
      assert File.dir?(dirs.cache)
      assert File.dir?(dirs.state)
      assert File.dir?(dirs.config)
      assert File.dir?(dirs.tmp)

      # Verify contained within workspace
      assert String.starts_with?(dirs.data, canonical_workspace)
      assert String.starts_with?(dirs.cache, canonical_workspace)
      assert String.starts_with?(dirs.config, canonical_workspace)
    end

    test "prepare_directories fails closed on non-existent workspace" do
      missing = Path.join(System.tmp_dir!(), "missing-workspace-#{System.unique_integer([:positive])}")
      assert {:error, _} = Environment.prepare_directories(missing, "launch-1")
    end

    test "build_port_env scrubs all tracker secrets and competitor provider keys", %{workspace: workspace} do
      launch_id = "test-launch-2"
      {:ok, dirs} = Environment.prepare_directories(workspace, launch_id)

      # Launching with provider 'anthropic'
      {:ok, port_env} = Environment.build_port_env("anthropic", dirs)

      env_map = Map.new(port_env, fn {k, v} -> {List.to_string(k), v} end)

      # Tracker secrets must be scrubbed (set to false)
      assert env_map["LINEAR_API_KEY"] == false
      assert env_map["JIRA_API_TOKEN"] == false
      assert env_map["GITHUB_TOKEN"] == false
      assert env_map["GITLAB_TOKEN"] == false
      assert env_map["ASANA_ACCESS_TOKEN"] == false
      assert env_map["STITCH_API_KEY"] == false

      # Competitor provider keys must be scrubbed (set to false)
      assert env_map["OPENAI_API_KEY"] == false
      assert env_map["GOOGLE_API_KEY"] == false
      assert env_map["XAI_API_KEY"] == false
      assert env_map["DATABRICKS_TOKEN"] == false
      assert env_map["CLOUDFLARE_API_TOKEN"] == false

      # Isolated XDG and TMP directories must be set
      assert env_map["XDG_DATA_HOME"] == String.to_charlist(dirs.data)
      assert env_map["XDG_CACHE_HOME"] == String.to_charlist(dirs.cache)
      assert env_map["XDG_CONFIG_HOME"] == String.to_charlist(dirs.config)
      assert env_map["XDG_STATE_HOME"] == String.to_charlist(dirs.state)
      assert env_map["TMP"] == String.to_charlist(dirs.tmp)
      assert env_map["TEMP"] == String.to_charlist(dirs.tmp)
      assert env_map["TMPDIR"] == String.to_charlist(dirs.tmp)
    end

    test "build_port_env preserves explicit caller-supplied provider auth", %{workspace: workspace} do
      launch_id = "test-launch-3"
      {:ok, dirs} = Environment.prepare_directories(workspace, launch_id)

      caller_auth = %{"ANTHROPIC_API_KEY" => "sk-ant-test-key"}
      {:ok, port_env} = Environment.build_port_env("anthropic", dirs, provider_auth: caller_auth)

      env_map = Map.new(port_env, fn {k, v} -> {List.to_string(k), v} end)

      assert env_map["ANTHROPIC_API_KEY"] == ~c"sk-ant-test-key"
      assert env_map["OPENAI_API_KEY"] == false
      assert env_map["LINEAR_API_KEY"] == false
    end
  end

  # ===========================================================================
  # 3. Model Routing & Fallback Prohibition
  # ===========================================================================

  describe "Model Routing" do
    test "validates explicit provider/model selection" do
      assert {:ok, {"anthropic", "claude-3-5-sonnet"}} =
               Adapter.validate_model_selection(model: "anthropic/claude-3-5-sonnet")

      assert {:ok, {"openai", "gpt-4o"}} =
               Adapter.validate_model_selection(provider: "openai", model: "gpt-4o")

      assert {:ok, {"google", "gemini-2.0-flash"}} =
               Adapter.validate_model_selection(provider: "google", model: "google/gemini-2.0-flash")
    end

    test "bare model without provider fails closed (forbids automatic fallback)" do
      assert {:error, {:invalid_model_selection, msg}} =
               Adapter.validate_model_selection(model: "claude-3-5-sonnet")

      assert msg =~ "provider/model"
      assert msg =~ "fallback is forbidden"

      assert {:error, {:invalid_model_selection, _}} =
               Adapter.validate_model_selection(model: "gpt-4o")
    end

    test "missing or empty model fails closed" do
      assert {:error, :missing_model} = Adapter.validate_model_selection([])
      assert {:error, :missing_model} = Adapter.validate_model_selection(model: "")
      assert {:error, :missing_model} = Adapter.validate_model_selection(model: nil)
    end

    test "builds correct non-interactive OpenCode CLI arguments", %{workspace: workspace} do
      args =
        Adapter.build_opencode_args(
          "anthropic",
          "claude-3-5-sonnet",
          workspace,
          "Solve issue",
          variant: "high",
          title: "Run 1"
        )

      assert args == [
               "run",
               "--format",
               "json",
               "-m",
               "anthropic/claude-3-5-sonnet",
               "--dir",
               workspace,
               "--pure",
               "--variant",
               "high",
               "--title",
               "Run 1",
               "Solve issue"
             ]
    end
  end

  # ===========================================================================
  # 4. Incremental JSONL Parsing & Fragmentation
  # ===========================================================================

  describe "Incremental JSONL Parsing & Fragmentation" do
    test "parses complete JSONL events" do
      event1 = Jason.encode!(%{"type" => "step_start", "timestamp" => 1, "sessionID" => "ses_1"}) <> "\n"
      event2 =
        Jason.encode!(%{
          "type" => "tool_use",
          "timestamp" => 2,
          "sessionID" => "ses_1",
          "part" => %{
            "tool" => "read",
            "callID" => "call_1",
            "messageID" => "msg_1",
            "state" => %{"status" => "completed", "output" => "data"}
          }
        }) <> "\n"
      event3 =
        Jason.encode!(%{
          "type" => "step_finish",
          "timestamp" => 3,
          "sessionID" => "ses_1",
          "part" => %{
            "messageID" => "msg_1",
            "tokens" => %{"input" => 50, "output" => 150, "reasoning" => 20, "cache" => %{"read" => 10, "write" => 5}},
            "cost" => 0.003
          }
        }) <> "\n"

      state =
        Parser.new()
        |> Parser.feed(event1)
        |> Parser.feed(event2)
        |> Parser.feed(event3)
        |> Parser.finish(0)

      res = Parser.to_result(state)

      assert res.session_id == "ses_1"
      assert res.message_ids == ["msg_1"]
      assert length(res.tool_events) == 1
      assert hd(res.tool_events).tool == "read"
      assert hd(res.tool_events).status == "completed"
      assert res.completion_state == :completed

      assert res.usage.input_tokens == 50
      assert res.usage.output_tokens == 150
      assert res.usage.total_tokens == 200
      assert res.usage.reasoning_tokens == 20
      assert res.usage.cache_read_tokens == 10
      assert res.usage.cache_write_tokens == 5
      assert res.usage.cost == 0.003
    end

    test "handles severe fragmentation across arbitrary byte boundaries" do
      raw_stream =
        ~s({"type":"step_start","timestamp":100,"sessionID":"ses_frag"}\r\n) <>
        ~s({"type":"tool_use","timestamp":200,"sessionID":"ses_frag","part":{"tool":"edit","callID":"c1","messageID":"m1","state":{"status":"completed"}}}\n) <>
        ~s({"type":"step_finish","timestamp":300,"sessionID":"ses_frag","part":{"messageID":"m1","tokens":{"input":12,"output":34}}}\r\n)

      # Split into 3-byte chunks to test heavy fragmentation
      chunks =
        for <<chunk::binary-size(3) <- raw_stream>>, do: chunk

      remainder_len = rem(byte_size(raw_stream), 3)
      all_chunks =
        if remainder_len > 0 do
          tail = :binary.part(raw_stream, byte_size(raw_stream) - remainder_len, remainder_len)
          chunks ++ [tail]
        else
          chunks
        end

      final_state =
        Enum.reduce(all_chunks, Parser.new(), fn chunk, acc ->
          Parser.feed(acc, chunk)
        end)
        |> Parser.finish(0)

      res = Parser.to_result(final_state)

      assert res.session_id == "ses_frag"
      assert res.message_ids == ["m1"]
      assert length(res.tool_events) == 1
      assert hd(res.tool_events).tool == "edit"
      assert res.usage.input_tokens == 12
      assert res.usage.output_tokens == 34
      assert res.usage.total_tokens == 46
      assert res.failure_evidence == []
      assert res.completion_state == :completed
    end

    test "malformed non-JSON lines are captured in failure_evidence without crashing" do
      stream =
        "garbage line not json\n" <>
        ~s({"type":"step_start","timestamp":100,"sessionID":"ses_clean"}\n) <>
        "another corrupt {line\n"

      state =
        Parser.new()
        |> Parser.feed(stream)
        |> Parser.finish(0)

      res = Parser.to_result(state)

      assert res.session_id == "ses_clean"
      assert length(res.failure_evidence) == 2
      assert Enum.all?(res.failure_evidence, fn {:malformed_json_line, line, _} -> is_binary(line) end)
    end

    test "error events set completion_state to :failed and capture evidence" do
      err_json =
        Jason.encode!(%{
          "type" => "error",
          "sessionID" => "ses_err",
          "error" => %{"name" => "ModelNotFoundError", "data" => %{"message" => "Model not found: foo/bar"}}
        }) <> "\n"

      state =
        Parser.new()
        |> Parser.feed(err_json)
        |> Parser.finish(1)

      res = Parser.to_result(state)

      assert res.completion_state == :failed
      assert length(res.failure_evidence) >= 1
      assert Enum.any?(res.failure_evidence, fn
        {:error_event, err} -> err["name"] == "ModelNotFoundError"
        _ -> false
      end)
    end
  end

  # ===========================================================================
  # 5. Failure Taxonomy Mapping
  # ===========================================================================

  describe "Failure Taxonomy Mapping" do
    test "maps model unavailable errors" do
      err = %{"name" => "ModelNotFoundError", "data" => %{"message" => "Model not found: vendor/x"}}
      assert Failure.classify(err) == :model_unavailable
      assert FailureClass.classify(Failure.failure_info(err)) == :model_unavailable
    end

    test "maps auth errors" do
      err = %{"name" => "AuthError", "data" => %{"message" => "Invalid API key"}}
      assert Failure.classify(err) == :auth_unavailable
      assert FailureClass.classify(Failure.failure_info(err)) == :auth_unavailable

      assert Failure.classify("unauthorized: 401") == :auth_unavailable
    end

    test "maps rate limit errors" do
      err = %{"name" => "RateLimitError", "status" => 429, "data" => %{"message" => "Rate limit exceeded"}}
      assert Failure.classify(err) == :provider_rate_limit
      assert FailureClass.classify(Failure.failure_info(err)) == :provider_rate_limit
    end

    test "maps quota errors" do
      err = %{"name" => "QuotaExceededError", "data" => %{"message" => "Insufficient quota remaining"}}
      assert Failure.classify(err) == :provider_quota
      assert FailureClass.classify(Failure.failure_info(err)) == :provider_quota
    end

    test "maps provider outage errors" do
      err = %{"status" => 503, "data" => %{"message" => "Service Unavailable"}}
      assert Failure.classify(err) == :provider_outage
      assert FailureClass.classify(Failure.failure_info(err)) == :provider_outage
    end

    test "maps timeout errors" do
      assert Failure.classify(:timeout) == :runtime_unavailable
      assert Failure.classify({:timeout, %{}}) == :runtime_unavailable
      assert Failure.classify("request timed out") == :runtime_unavailable
    end

    test "maps permission denials and fallback violations to persistent_worker_failure" do
      assert Failure.classify(:unrestricted_permissions_forbidden) == :persistent_worker_failure
      assert Failure.classify(:missing_provider) == :persistent_worker_failure
      assert Failure.classify(:missing_model) == :persistent_worker_failure
      assert Failure.classify({:permission_denied, "read"}) == :persistent_worker_failure
      assert Failure.classify({:tool_error, "bash", "permission auto-rejected"}) == :persistent_worker_failure
    end

    test "maps environment and infrastructure errors" do
      assert Failure.classify({:workspace_not_a_directory, "bad"}) == :probe_environment_error
      assert Failure.classify({:outside_workspace, "a", "b"}) == :probe_environment_error
      assert Failure.classify({:executable_not_found, "opencode"}) == :probe_infrastructure_error
      assert Failure.classify({:jobrun_helper_missing, "exe"}) == :probe_infrastructure_error
    end
  end

  # ===========================================================================
  # 6. Windows Job Object Containment & Process Termination
  # ===========================================================================

  describe "Windows Job Object Containment & Process Termination" do
    @tag :windows_only
    test "natural process exit under containment records receipt with NATURAL_EXIT and TERMINATED_CONFIRMED", %{workspace: workspace} do
      mock_exe = MockOpenCode.ensure_built!()

      assert {:ok, result} =
               OpenCode.run(
                 workspace,
                 "Test prompt",
                 provider: "anthropic",
                 model: "claude-3-5-sonnet",
                 executable: mock_exe
               )

      assert result.session_id == "ses_mock_123"
      assert result.message_ids == ["msg_01"]
      assert length(result.tool_events) == 1
      assert hd(result.tool_events).tool == "read"
      assert result.usage.total_tokens == 300
      assert result.completion_state == :completed
      assert result.exit_code == 0

      # Containment confirmation check
      if WorkerContainment.containment_active?() do
        assert result.termination.status == :TERMINATED_CONFIRMED
        assert result.termination.receipt["terminal_reason"] == "NATURAL_EXIT"
        assert result.termination.receipt["tree_drained"] == true
        assert result.termination.receipt["child_exit_code"] == 0
      end
    end

    @tag :windows_only
    test "forced process termination under containment kills entire process tree and records TERMINATED_CONFIRMED", %{workspace: workspace} do
      mock_exe = MockOpenCode.ensure_built!()

      # Start session with hang mode so it sleeps
      assert {:ok, session} =
               Adapter.start_session(
                 workspace,
                 "--mock-mode=hang",
                 provider: "anthropic",
                 model: "claude-3-5-sonnet",
                 executable: mock_exe
               )

      # Give the process a moment to launch into the Job Object
      Process.sleep(200)

      # Stop the session forcefully
      confirmation = Adapter.stop_session(session)

      if WorkerContainment.containment_active?() do
        assert confirmation.status == :TERMINATED_CONFIRMED
        assert confirmation.receipt["tree_drained"] == true
        assert confirmation.receipt["terminal_reason"] in ["COOPERATIVE_EXIT", "HARD_JOB_TERMINATION"]
      end
    end

    @tag :windows_only
    test "error run captures failure info and fails closed", %{workspace: workspace} do
      mock_exe = MockOpenCode.ensure_built!()

      assert {:error, {_reason, result}} =
               OpenCode.run(
                 workspace,
                 "--mock-mode=error",
                 provider: "anthropic",
                 model: "claude-3-5-sonnet",
                 executable: mock_exe
               )

      assert result.completion_state == :failed
      assert result.failure_info.failure_class == :model_unavailable
    end
  end
end
