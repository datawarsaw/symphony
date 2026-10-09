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

    test "unknown tool permissions fail closed" do
      assert {:error, {:unknown_tool_permission, ["shell"]}} =
               Config.build(allowed_tools: ["shell", "read"])
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
      assert File.dir?(dirs.home)
      assert File.dir?(dirs.managed)
      assert File.dir?(dirs.xdg_config)

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
      assert env_map["XDG_DATA_HOME"] == String.to_charlist(dirs.xdg_data)
      assert env_map["XDG_CACHE_HOME"] == String.to_charlist(dirs.xdg_cache)
      assert env_map["XDG_CONFIG_HOME"] == String.to_charlist(dirs.xdg_config)
      assert env_map["XDG_STATE_HOME"] == String.to_charlist(dirs.xdg_state)
      assert env_map["OPENCODE_CONFIG_DIR"] == String.to_charlist(dirs.config)
      assert env_map["HOME"] == String.to_charlist(dirs.home)
      assert env_map["USERPROFILE"] == String.to_charlist(dirs.home)
      assert env_map["OPENCODE_DISABLE_PROJECT_CONFIG"] == ~c"1"
      assert env_map["OPENCODE_PERMISSION"] == false
      assert env_map["OPENCODE_CONFIG"] == false
      assert env_map["OPENCODE_CONFIG_CONTENT"] == false
      assert env_map["TMP"] == String.to_charlist(dirs.tmp)

      if match?({:win32, _}, :os.type()) do
        assert Enum.any?(env_map, fn {key, value} ->
                 String.downcase(key) == "path" and is_list(value)
               end)

        assert Enum.any?(env_map, fn {key, value} ->
                 String.downcase(key) == "systemroot" and is_list(value)
               end)
      end

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
               "--",
               "Solve issue"
             ]

      assert Enum.take(Adapter.build_opencode_args("anthropic", "claude", workspace, "--auto", []), -2) ==
               ["--", "--auto"]

      assert Enum.take(Adapter.build_opencode_args("anthropic", "claude", workspace, "-leading", []), -2) ==
               ["--", "-leading"]
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
        |> Parser.feed(idle_event("ses_1"))
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
          ~s({"type":"step_finish","timestamp":300,"sessionID":"ses_frag","part":{"messageID":"m1","tokens":{"input":12,"output":34}}}\r\n) <>
          idle_event("ses_frag")

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
      assert res.completion_state == :failed
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

    test "missing executable is infrastructure and ambiguous text is not over-classified" do
      assert Failure.classify(:opencode_executable_not_found) == :probe_infrastructure_error
      assert Failure.classify("The author revised section 4012") == :transient_worker_failure
      assert Failure.classify("processed 500 files") == :transient_worker_failure
      assert Failure.classify("status 401") == :auth_unavailable
      assert Failure.classify("unauthorized") == :auth_unavailable
      assert Failure.classify("HTTP 403 Forbidden") == :persistent_worker_failure
      assert Failure.classify("unauthorized permission denied") == :persistent_worker_failure
      assert Failure.classify("permission denied") == :persistent_worker_failure

      secret = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz"
      info = Failure.failure_info({:tool_error, "read", secret})
      refute inspect(info) =~ secret
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
      assert result.failure_evidence == []
      assert result.stderr =~ "not-json-stderr-marker"

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

      if WorkerContainment.containment_active?() do
        assert {:os_pid, os_pid} = :erlang.port_info(session.port, :os_pid)
        assert session.identity["wrapper_pid"] == Integer.to_string(os_pid)
      end

      # Stop the session forcefully
      confirmation = Adapter.stop_session(session)
      assert Adapter.stop_session(session) == confirmation

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

  describe "Completion evidence and redaction" do
    test "exit 0 without a completion event fails closed" do
      state =
        Parser.new()
        |> Parser.feed(~s({"type":"step_start","sessionID":"ses_partial"}\n))
        |> Parser.finish(0)

      result = Parser.to_result(state)
      assert result.completion_state == :failed
      assert {:incomplete_stream, :missing_completion_event} in result.failure_evidence
    end

    test "a tool error stays failed when a later idle event arrives" do
      stream =
        ~s({"type":"tool_use","sessionID":"ses_tool","part":{"tool":"bash","callID":"c1","state":{"status":"error","error":"permission denied"}}}\n) <>
          idle_event("ses_tool")

      result =
        Parser.new()
        |> Parser.feed(stream)
        |> Parser.finish(0)
        |> Parser.to_result()

      assert result.completion_state == :failed
      assert {:tool_error, "bash", "permission denied"} in result.failure_evidence
    end

    test "tool output is redacted and bounded" do
      secret = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz"
      output = secret <> " " <> String.duplicate("a", 5_000)

      event =
        Jason.encode!(%{
          "type" => "tool_use",
          "sessionID" => "ses_secret",
          "part" => %{
            "tool" => "read",
            "callID" => "c1",
            "messageID" => "m1",
            "state" => %{"status" => "completed", "output" => output}
          }
        }) <> "\n"

      result =
        Parser.new()
        |> Parser.feed(event <> idle_event("ses_secret"))
        |> Parser.finish(0)
        |> Parser.to_result()

      rendered = hd(result.tool_events).output
      refute rendered =~ secret
      assert String.ends_with?(rendered, "…[truncated]")
      assert byte_size(rendered) <= 4_096 + byte_size("…[truncated]")
    end
  end

  describe "Process boundary regressions" do
    @tag :windows_only
    test "the child receives stdin EOF before OpenCode would block", %{workspace: workspace} do
      assert {:ok, result} = run_mock(workspace, "--mock-mode=stdin", timeout_ms: 5_000)
      assert result.completion_state == :completed
      assert result.exit_code == 0
    end

    @tag :windows_only
    test "the child environment is an allowlist and keeps only the selected provider", %{
      workspace: workspace
    } do
      linear = "lin_api_parentsecretvalue"
      openai = "sk-parent-openai-secret"
      anthropic = "sk-ant-parent-selected"
      sentinel = "should-not-pass"

      with_restored_env(
        [
          "LINEAR_API_KEY",
          "OPENAI_API_KEY",
          "ANTHROPIC_API_KEY",
          "OPENCODE_PERMISSION",
          "OPENCODE_CONFIG_CONTENT",
          "OPENCODE_INHERITED_SENTINEL"
        ],
        fn ->
          System.put_env("LINEAR_API_KEY", linear)
          System.put_env("OPENAI_API_KEY", openai)
          System.put_env("ANTHROPIC_API_KEY", anthropic)
          System.put_env("OPENCODE_PERMISSION", ~s({"*":"allow","bash":"allow"}))
          System.put_env("OPENCODE_CONFIG_CONTENT", ~s({"permission":{"bash":"allow"}}))
          System.put_env("OPENCODE_INHERITED_SENTINEL", sentinel)

          assert {:ok, _} = run_mock(workspace, "--mock-mode=env")
        end
      )

      path = Path.join(workspace, "opencode-child-evidence.json")
      raw = File.read!(path)
      evidence = Jason.decode!(raw)

      assert evidence["ANTHROPIC_API_KEY"] == true
      assert evidence["LINEAR_API_KEY"] == false
      assert evidence["OPENAI_API_KEY"] == false
      assert evidence["OPENCODE_PERMISSION"] == false
      assert evidence["OPENCODE_CONFIG_CONTENT"] == false
      assert evidence["OPENCODE_DISABLE_PROJECT_CONFIG"] == true
      assert evidence["OPENCODE_INHERITED_SENTINEL"] == false
      refute raw =~ linear
      refute raw =~ openai
      refute raw =~ anthropic
      refute raw =~ sentinel
    end

    @tag :windows_only
    test "unauthorized provider credentials are rejected before launch", %{workspace: workspace} do
      mock_exe = MockOpenCode.ensure_built!()

      assert {:error, {:unauthorized_credential, "OPENAI_API_KEY"}} =
               Adapter.start_session(
                 workspace,
                 "hello",
                 provider: "anthropic",
                 model: "claude-3-5-sonnet",
                 executable: mock_exe,
                 provider_auth: %{"OPENAI_API_KEY" => "not-allowed"}
               )
    end

    @tag :windows_only
    test "unknown tool permissions are rejected before launch", %{workspace: workspace} do
      mock_exe = MockOpenCode.ensure_built!()

      assert {:error, {:unknown_tool_permission, ["shell"]}} =
               Adapter.start_session(
                 workspace,
                 "hello",
                 provider: "anthropic",
                 model: "claude-3-5-sonnet",
                 executable: mock_exe,
                 allowed_tools: ["shell"]
               )
    end

    @tag :windows_only
    test "prompts that look like options stay behind --", %{workspace: workspace} do
      Enum.each(["--auto", "-leading", "hello world"], fn prompt ->
        File.write!(Path.join(workspace, "opencode-mock-control.txt"), "mode=argv\n")

        assert {:ok, _} = run_mock(workspace, prompt)

        args = Jason.decode!(File.read!(Path.join(workspace, "opencode-argv.json")))["args"]
        index = Enum.find_index(args, &(&1 == "--"))
        assert is_integer(index)
        assert Enum.at(args, index + 1) == prompt
      end)
    end

    @tag :windows_only
    test "exit 0 without completion, malformed JSON, or a tool error is not success", %{
      workspace: workspace
    } do
      assert {:error, {{:incomplete_stream, :missing_completion_event}, partial}} =
               run_mock(workspace, "--mock-mode=partial")

      assert partial.exit_code == 0
      assert partial.completion_state == :failed

      assert {:error, {{:malformed_json_line, _line, _reason}, malformed}} =
               run_mock(workspace, "--mock-mode=malformed")

      assert malformed.exit_code == 0
      assert malformed.completion_state == :failed

      assert {:error, {{:tool_error, "read", "permission denied"}, tool_error}} =
               run_mock(workspace, "--mock-mode=tool-error")

      assert tool_error.exit_code == 0
      assert tool_error.completion_state == :failed
      assert tool_error.failure_info.failure_class == :persistent_worker_failure
    end

    @tag :windows_only
    test "tool output, callbacks, and stderr do not expose secrets", %{workspace: workspace} do
      secret = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz"
      linear = "lin_api_abcdefghijklmnopqrstuvwxyz"
      {:ok, agent} = Agent.start_link(fn -> [] end)

      assert {:ok, result} =
               run_mock(workspace, "--mock-mode=secret", on_event: fn event -> Agent.update(agent, &[event | &1]) end)

      payload = inspect(result) <> inspect(Agent.get(agent, & &1))
      refute payload =~ secret
      refute payload =~ linear
      assert result.stderr =~ "[redacted]"
      refute result.stderr =~ secret
    end

    @tag :windows_only
    test "unconfirmed termination does not return success", %{workspace: workspace} do
      assert WorkerContainment.containment_active?()
      authority = Path.join(workspace, "authority-not-a-directory")
      File.write!(authority, "x")

      assert {:error, {:termination_unconfirmed, result}} =
               run_mock(workspace, "Test prompt", authority_root: authority)

      assert result.exit_code == 0
      assert result.completion_state == :completed
      assert result.failure_evidence == []
      assert result.termination.status == :TERMINATION_UNCONFIRMED
    end

    @tag :windows_only
    test "real OpenCode 1.18.28 keeps hostile project and parent overrides denied", %{
      workspace: workspace
    } do
      exe =
        case Adapter.resolve_executable([]) do
          {:ok, path} -> path
          {:error, reason} -> flunk("opencode executable unavailable: #{inspect(reason)}")
        end

      {version, 0} = System.cmd(exe, ["--version"], stderr_to_stdout: true)
      assert version =~ "1.18.28"

      File.write!(
        Path.join(workspace, "opencode.json"),
        ~s({"permission":{"*":"allow","bash":"allow","edit":"allow"}})
      )

      {:ok, dirs} = Environment.prepare_directories(workspace, "real-config-launch")
      assert {:ok, _} = Config.write_config(dirs, allowed_tools: ["read"])

      with_restored_env(["OPENCODE_PERMISSION", "OPENCODE_CONFIG", "OPENCODE_CONFIG_CONTENT"], fn ->
        outside = Path.join(workspace, "hostile-override.json")
        File.write!(outside, ~s({"permission":{"*":"allow","bash":"allow"}}))
        System.put_env("OPENCODE_PERMISSION", ~s({"*":"allow","bash":"allow","edit":"allow"}))
        System.put_env("OPENCODE_CONFIG_CONTENT", ~s({"permission":{"bash":"allow","edit":"allow"}}))
        System.put_env("OPENCODE_CONFIG", outside)

        {:ok, port_env} = Environment.build_port_env("anthropic", dirs, [])

        env =
          Enum.map(port_env, fn
            {key, false} -> {List.to_string(key), nil}
            {key, value} -> {List.to_string(key), List.to_string(value)}
          end)

        {config_out, config_status} =
          System.cmd(exe, ["debug", "config", "--pure"], cd: workspace, env: env, stderr_to_stdout: true)

        assert config_status == 0
        parsed = Jason.decode!(config_out)
        assert parsed["permission"]["*"] == "deny"
        assert parsed["permission"]["bash"] == "deny"
        assert parsed["permission"]["edit"] == "deny"
        assert parsed["permission"]["read"] == "allow"

        {paths_out, paths_status} =
          System.cmd(exe, ["debug", "paths", "--pure"], cd: workspace, env: env, stderr_to_stdout: true)

        assert paths_status == 0
        normalized = paths_out |> String.replace("\\", "/") |> String.downcase()
        home = dirs.home |> String.replace("\\", "/") |> String.downcase()
        config = dirs.xdg_config |> Path.join("opencode") |> String.replace("\\", "/") |> String.downcase()
        user_home = System.user_home!() |> String.replace("\\", "/") |> String.downcase()

        assert normalized =~ home
        assert normalized =~ config
        refute normalized =~ user_home <> "/.config"
        refute normalized =~ user_home <> "/.opencode"
      end)
    end
  end

  defp idle_event(session_id) do
    Jason.encode!(%{
      "type" => "session.status",
      "timestamp" => 4,
      "sessionID" => session_id,
      "status" => %{"type" => "idle"}
    }) <> "\n"
  end

  defp run_mock(workspace, prompt, extra \\ []) do
    mock_exe = MockOpenCode.ensure_built!()

    OpenCode.run(
      workspace,
      prompt,
      Keyword.merge(
        [
          provider: "anthropic",
          model: "claude-3-5-sonnet",
          executable: mock_exe,
          timeout_ms: 8_000
        ],
        extra
      )
    )
  end

  defp with_restored_env(keys, fun) do
    previous = Map.new(keys, &{&1, System.get_env(&1)})

    try do
      fun.()
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end
end
