defmodule SymphonyElixir.OpenCodeTest do
  use SymphonyElixir.TestSupport

  Code.require_file("../support/mock_opencode.exs", __DIR__)

  alias SymphonyElixir.FailureClass
  alias SymphonyElixir.LaunchMarker
  alias SymphonyElixir.OpenCode
  alias SymphonyElixir.OpenCode.{Adapter, Config, Environment, Failure, Parser, Redactor}
  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.TestSupport.MockOpenCode
  alias SymphonyElixir.WorkerContainment

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "opencode-test-workspace-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)

    # PILOT-AUTH-F: launches in this suite pass through the production
    # credential presence preflight; a synthetic placeholder satisfies it
    # offline without authenticating or contacting any provider.
    saved_credential = System.get_env("ANTHROPIC_API_KEY")
    System.put_env("ANTHROPIC_API_KEY", "sk-ant-synthetic-test-placeholder")

    on_exit(fn ->
      restore_env("ANTHROPIC_API_KEY", saved_credential)
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
      refute Map.has_key?(config["permission"], "*")
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
      refute Map.has_key?(config["permission"], "*")

      # Deny-by-default is explicit: every unlisted known tool carries its own
      # deny rule (15 known tools, 2 allowed here).
      assert Enum.count(config["permission"], fn {_tool, action} -> action == "deny" end) == 13
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
      refute Map.has_key?(parsed["permission"], "*")
    end
  end

  # ===========================================================================
  # 1b. Resolved tool validation (PILOT-TOOL-CONFIG-FIX)
  #
  # opencode 1.18.28 resolves a document combining a tools object with a
  # wildcard-denied permission map ("*" => "deny") to a worker agent with
  # every tool disabled — the R3 live failure. The generated document carries
  # no wildcard, and Config.verify_resolved_tools/2 proves the installed CLI
  # resolves it with exactly the intended tool enablement, fail-closed.
  # ===========================================================================

  describe "Resolved tool validation" do
    @pilot_allowlist [:read, :edit]

    @pilot_permission %{
      "read" => "allow",
      "edit" => "allow",
      "glob" => "deny",
      "grep" => "deny",
      "list" => "deny",
      "bash" => "deny",
      "task" => "deny",
      "external_directory" => "deny",
      "todowrite" => "deny",
      "question" => "deny",
      "webfetch" => "deny",
      "websearch" => "deny",
      "lsp" => "deny",
      "doom_loop" => "deny",
      "skill" => "deny"
    }

    test "the generated pilot document keeps explicit deny rules without a permission wildcard" do
      {:ok, config} = Config.build(allowed_tools: @pilot_allowlist)

      refute Map.has_key?(config["permission"], "*")
      assert config["permission"] == @pilot_permission
      assert config["tools"] == %{
               "read" => true,
               "edit" => true,
               "glob" => false,
               "grep" => false,
               "list" => false,
               "bash" => false,
               "task" => false,
               "external_directory" => false,
               "todowrite" => false,
               "question" => false,
               "webfetch" => false,
               "websearch" => false,
               "lsp" => false,
               "doom_loop" => false,
               "skill" => false
             }
    end

    test "the R3 wildcard-denied document fails closed before any process runs" do
      {:ok, config} = Config.build(allowed_tools: @pilot_allowlist)
      r3_document = Map.update!(config, "permission", &Map.put(&1, "*", "deny"))

      assert {:error, :wildcard_permission_forbidden} =
               Config.verify_resolved_tools(r3_document, executable: "unused-opencode.exe")
    end

    test "the resolution probe fails closed when no OpenCode executable can be resolved" do
      {:ok, config} = Config.build(allowed_tools: @pilot_allowlist)

      assert {:error, {:executable_not_found, _}} =
               Config.verify_resolved_tools(config, executable: "definitely-not-opencode.exe")
    end

    @tag :windows_only
    test "installed OpenCode resolves the pilot document with read/edit enabled and the rest disabled" do
      {:ok, config} = Config.build(allowed_tools: @pilot_allowlist)

      assert :ok = Config.verify_resolved_tools(config, timeout_ms: 60_000)
    end

    @tag :windows_only
    test "installed OpenCode resolves a deny-all document with no executable tools" do
      {:ok, config} = Config.build(allowed_tools: [])

      assert :ok = Config.verify_resolved_tools(config, timeout_ms: 60_000)
    end

    @tag :windows_only
    test "the validation fails when the installed CLI resolves an enabled tool as disabled" do
      # tools claims bash is enabled while permission denies it: the resolved
      # agent must not be blessed, catching any future tools/permission drift.
      {:ok, config} = Config.build(allowed_tools: @pilot_allowlist)
      inconsistent = put_in(config, ["tools", "bash"], true)

      assert {:error, {:resolved_tools_disabled, ["bash"]}} =
               Config.verify_resolved_tools(inconsistent, timeout_ms: 60_000)
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
            "reason" => "stop",
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
      assert res.usage.total_tokens == 235
      assert res.usage.reasoning_tokens == 20
      assert res.usage.cache_read_tokens == 10
      assert res.usage.cache_write_tokens == 5
      assert res.usage.cost == 0.003
    end

    test "handles severe fragmentation across arbitrary byte boundaries" do
      raw_stream =
        ~s({"type":"step_start","timestamp":100,"sessionID":"ses_frag"}\r\n) <>
          ~s({"type":"tool_use","timestamp":200,"sessionID":"ses_frag","part":{"tool":"edit","callID":"c1","messageID":"m1","state":{"status":"completed"}}}\n) <>
          ~s({"type":"step_finish","timestamp":300,"sessionID":"ses_frag","part":{"messageID":"m1","reason":"stop","tokens":{"input":12,"output":34}}}\r\n)

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
  # 4a. Token Usage Accounting (OpenCode 1.18.28 wire contract)
  # ===========================================================================

  describe "Token usage accounting (OpenCode wire contract)" do
    # Wire semantics verified against OpenCode 1.18.28 source: part.tokens
    # carries five non-overlapping categories — input is the non-cached input,
    # output is the visible output (reasoning excluded), and cache read/write
    # sit outside input. The v1.18.28 step-finish wire carries no total; when
    # one is supplied it is inclusive of all five categories and is the
    # source of truth, never summed on top of them.
    test "missing total sums input, output, reasoning and cache categories" do
      stream =
        step_finish_tokens_line(%{
          "input" => 50,
          "output" => 150,
          "reasoning" => 20,
          "cache" => %{"read" => 10, "write" => 5}
        })

      usage = parse_step_usage(stream)

      assert usage.total_tokens == 235
    end

    test "explicit total is honored and not added on top of the categories" do
      stream =
        step_finish_tokens_line(%{
          "input" => 50,
          "output" => 150,
          "reasoning" => 20,
          "cache" => %{"read" => 10, "write" => 5},
          "total" => 240
        })

      usage = parse_step_usage(stream)

      assert usage.total_tokens == 240
      assert usage.input_tokens == 50
      assert usage.output_tokens == 150
      assert usage.reasoning_tokens == 20
      assert usage.cache_read_tokens == 10
      assert usage.cache_write_tokens == 5
    end

    test "cache read and write tokens count toward the total" do
      stream =
        step_finish_tokens_line(%{
          "input" => 100,
          "output" => 200,
          "cache" => %{"read" => 4_000, "write" => 1_000}
        })

      usage = parse_step_usage(stream)

      assert usage.cache_read_tokens == 4_000
      assert usage.cache_write_tokens == 1_000
      assert usage.total_tokens == 5_300
    end

    test "reasoning tokens count toward the total" do
      stream =
        step_finish_tokens_line(%{"input" => 100, "output" => 200, "reasoning" => 2_000})

      usage = parse_step_usage(stream)

      assert usage.reasoning_tokens == 2_000
      assert usage.total_tokens == 2_300
    end

    test "explicit total of 0 is honored and not treated as missing" do
      stream =
        step_finish_tokens_line(%{
          "input" => 50,
          "output" => 150,
          "reasoning" => 20,
          "cache" => %{"read" => 10, "write" => 5},
          "total" => 0
        })

      usage = parse_step_usage(stream)

      assert usage.total_tokens == 0
      assert usage.input_tokens == 50
      assert usage.output_tokens == 150
      assert usage.reasoning_tokens == 20
    end

    test "malformed totals fall back to the additive category sum" do
      for malformed <- ["240", -5, 12.5, nil] do
        stream =
          step_finish_tokens_line(%{
            "input" => 50,
            "output" => 150,
            "reasoning" => 20,
            "cache" => %{"read" => 10, "write" => 5},
            "total" => malformed
          })

        usage = parse_step_usage(stream)
        assert usage.total_tokens == 235, "expected additive fallback for total: #{inspect(malformed)}"
      end
    end

    test "multi-step cumulative total sums the per-step totals" do
      stream =
        step_finish_tokens_line(%{"input" => 40, "output" => 60, "reasoning" => 10, "cache" => %{"read" => 5, "write" => 5}},
          reason: "tool-calls",
          part_id: "step_f1",
          message_id: "msg_1"
        ) <>
          step_finish_tokens_line(%{"input" => 60, "output" => 90, "reasoning" => 15, "cache" => %{"read" => 10, "write" => 5}},
            part_id: "step_f2",
            message_id: "msg_2"
          )

      usage = parse_step_usage(stream)

      assert usage.input_tokens == 100
      assert usage.output_tokens == 150
      assert usage.total_tokens == 300
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
      assert Failure.classify("error 403") == :persistent_worker_failure

      assert Failure.classify(%{"status" => 403, "data" => %{"message" => "provider refused"}}) ==
               :persistent_worker_failure

      assert Failure.classify("processed 403 files") == :transient_worker_failure
      assert Failure.classify("room 403 was empty") == :transient_worker_failure
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
      assert result.usage.total_tokens == 385
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

  # ===========================================================================
  # 7. M1-G1 LaunchMarker Safety Gate
  # ===========================================================================

  describe "M1-G1 LaunchMarker Safety Gate" do
    setup %{workspace: workspace} do
      state_root = SymphonyElixir.TestSupport.create_temp_fixture_root!("opencode-launchmarker")

      Application.put_env(:symphony_elixir, :launch_marker_root, Path.join(state_root, "launches"))
      Application.put_env(:symphony_elixir, :worker_termination_receipt_root, Path.join(state_root, "receipts"))

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :launch_marker_root)
        Application.delete_env(:symphony_elixir, :worker_termination_receipt_root)
        SymphonyElixir.TestSupport.remove_temp_fixture_root!(state_root)
      end)

      {:ok, state_root: state_root, workspace: workspace}
    end

    @tag :windows_only
    test "contained launch records the durable marker before the worker can run, bound to issue, attempt, workspace and containment identity", %{workspace: workspace} do
      mock_exe = MockOpenCode.ensure_built!()
      issue_id = "issue-opencode-marker-bind"
      {:ok, canonical} = PathSafety.canonicalize(workspace)
      receipts = Application.fetch_env!(:symphony_elixir, :worker_termination_receipt_root)

      assert {:ok, session} =
               Adapter.start_session(workspace, "--mock-mode=hang",
                 provider: "anthropic",
                 model: "claude-3-5-sonnet",
                 executable: mock_exe,
                 issue_id: issue_id,
                 attempt_id: 7,
                 identifier: "MT-OP-1"
               )

      # The marker is already durable when the session exists: it was written
      # before the port could spawn the worker.
      assert {:ok, marker} = LaunchMarker.read(issue_id)
      assert marker["schema_version"] == 1
      assert marker["issue_id"] == issue_id
      assert marker["identifier"] == "MT-OP-1"
      assert marker["attempt_id"] == 7
      assert marker["workspace"] == canonical
      assert marker["workspace_key"] == Path.basename(canonical)
      assert marker["launch_id"] == session.identity["launch_id"]
      assert marker["worker_identity"]["launch_id"] == session.identity["launch_id"]
      assert marker["worker_identity"]["receipt_path"] == session.identity["receipt_path"]

      assert marker["worker_identity"]["receipt_path"] ==
               Path.join(receipts, session.identity["launch_id"] <> ".json")

      assert marker["worker_identity"]["wrapper_pid"] == session.identity["wrapper_pid"]
      assert is_binary(marker["worker_identity"]["wrapper_pid"])
      assert is_nil(marker["worker_host"])

      # While the worker is alive there is no termination receipt, so the
      # reuse and cleanup fences must fail closed on the marker.
      assert {:blocked, :worker_termination_unproven} = LaunchMarker.reuse_gate(issue_id)
      assert {:blocked, :worker_termination_unproven} = LaunchMarker.cleanup_gate(issue_id)

      assert %{status: :TERMINATED_CONFIRMED} = Adapter.stop_session(session)
    end

    @tag :windows_only
    test "marker write failure refuses the launch before any process is spawned", %{workspace: workspace} do
      mock_exe = MockOpenCode.ensure_built!()

      blocked_root = Path.join(workspace, "marker-root-not-a-directory")
      File.write!(blocked_root, "x")
      Application.put_env(:symphony_elixir, :launch_marker_root, Path.join(blocked_root, "launches"))

      assert {:error, {:launch_marker_write_failed, _detail}} =
               Adapter.start_session(workspace, "--mock-mode=hang",
                 provider: "anthropic",
                 model: "claude-3-5-sonnet",
                 executable: mock_exe,
                 issue_id: "issue-opencode-marker-refused",
                 attempt_id: 1
               )

      # Nothing was spawned: no wrapper ever ran, so no receipt store exists.
      receipts = Application.fetch_env!(:symphony_elixir, :worker_termination_receipt_root)
      assert {:error, :enoent} = File.ls(receipts)
    end

    @tag :windows_only
    test "pre-launch port failure clears the marker on conclusive never-spawned evidence", %{workspace: workspace} do
      mock_exe = MockOpenCode.ensure_built!()
      issue_id = "issue-opencode-never-spawned"

      Application.put_env(:symphony_elixir, :jobrun_helper_path, Path.join(workspace, "missing-jobrun.exe"))
      on_exit(fn -> Application.delete_env(:symphony_elixir, :jobrun_helper_path) end)

      assert {:error, {:jobrun_helper_missing, _path}} =
               Adapter.start_session(workspace, "Test prompt",
                 provider: "anthropic",
                 model: "claude-3-5-sonnet",
                 executable: mock_exe,
                 issue_id: issue_id,
                 attempt_id: 1
               )

      # Port.open never succeeded, so the pre-launch marker must not strand
      # the issue behind an unprovable fence.
      assert {:error, :not_found} = LaunchMarker.read(issue_id)
      assert :allowed = LaunchMarker.reuse_gate(issue_id)
      assert :allowed = LaunchMarker.cleanup_gate(issue_id)
    end

    @tag :windows_only
    test "confirmed termination clears the marker so the workspace stays reusable", %{workspace: workspace} do
      issue_id = "issue-opencode-confirmed-clear"

      assert {:ok, _result} =
               run_mock(workspace, "Test prompt", issue_id: issue_id, attempt_id: 2, identifier: "MT-OP-2")

      # A successful run required TERMINATED_CONFIRMED termination evidence,
      # which is exactly the fence-accepted bar for clearing the marker.
      assert {:error, :not_found} = LaunchMarker.read(issue_id)
      assert :allowed = LaunchMarker.reuse_gate(issue_id)
      assert :allowed = LaunchMarker.cleanup_gate(issue_id)
    end

    @tag :windows_only
    test "unconfirmed termination keeps the marker and fails the reuse and cleanup gates closed", %{workspace: workspace} do
      issue_id = "issue-opencode-unconfirmed"
      receipts = Application.fetch_env!(:symphony_elixir, :worker_termination_receipt_root)

      # Break the receipt store before the launch: the wrapper's best-effort
      # receipt write fails, so worker death can never be positively proven.
      File.write!(receipts, "x")

      assert {:error, {:termination_unconfirmed, result}} =
               run_mock(workspace, "Test prompt", issue_id: issue_id, attempt_id: 3, identifier: "MT-OP-3")

      assert result.termination.status == :TERMINATION_UNCONFIRMED

      # The marker survives as the durable fence: unknown termination must
      # block workspace reuse and destructive cleanup.
      assert {:ok, marker} = LaunchMarker.read(issue_id)
      assert marker["issue_id"] == issue_id
      assert {:blocked, :worker_termination_unproven} = LaunchMarker.reuse_gate(issue_id)
      assert {:blocked, :worker_termination_unproven} = LaunchMarker.cleanup_gate(issue_id)
    end

    @tag :windows_only
    test "BEAM interruption leaves a recoverable marker: fail closed until the wrapper receipt proves drain", %{workspace: workspace} do
      mock_exe = MockOpenCode.ensure_built!()
      issue_id = "issue-opencode-beam-interrupted"

      assert {:ok, session} =
               Adapter.start_session(workspace, "--mock-mode=hang",
                 provider: "anthropic",
                 model: "claude-3-5-sonnet",
                 executable: mock_exe,
                 issue_id: issue_id,
                 attempt_id: 4,
                 identifier: "MT-OP-4"
               )

      assert {:ok, _marker} = LaunchMarker.read(issue_id)

      # Simulated BEAM death before the wrapper could prove termination: no
      # receipt exists yet, so the next boot must fail closed on the marker.
      assert {:blocked, :worker_termination_unproven} = LaunchMarker.reuse_gate(issue_id)
      assert {:error, :unknown} = LaunchMarker.fence_verdict(issue_id)

      # BEAM death tears the port down (stdin EOF) exactly like a restart:
      # the wrapper drains the Job on its own and writes the receipt.
      Port.close(session.port)
      identity = session.identity
      wait_until(fn -> File.exists?(identity["receipt_path"]) end, 15_000)

      # The durable marker plus the wrapper receipt positively prove death,
      # so the next boot may reuse the workspace.
      assert {:ok, :dead} = LaunchMarker.fence_verdict(issue_id)
      assert :allowed = LaunchMarker.reuse_gate(issue_id)

      # The marker itself survives the interruption; a later confirmed stop
      # clears it exactly once (idempotent cleanup).
      assert {:ok, _survivor} = LaunchMarker.read(issue_id)
      assert %{status: :TERMINATED_CONFIRMED} = Adapter.stop_session(session)
      assert Adapter.stop_session(session).status == :TERMINATED_CONFIRMED
      assert {:error, :not_found} = LaunchMarker.read(issue_id)
    end

    @tag :windows_only
    test "contained launch without an issue id proceeds unfenced with a visible warning", %{workspace: workspace} do
      mock_exe = MockOpenCode.ensure_built!()

      {{:ok, session}, capture} =
        with_log(fn ->
          Adapter.start_session(workspace, "--mock-mode=hang",
            provider: "anthropic",
            model: "claude-3-5-sonnet",
            executable: mock_exe
          )
        end)

      assert capture =~ "cannot be fenced by a launch marker"

      # No marker exists for the unfenced launch.
      launches = Application.fetch_env!(:symphony_elixir, :launch_marker_root)
      assert {:error, :enoent} = File.ls(launches)

      assert %{status: :TERMINATED_CONFIRMED} = Adapter.stop_session(session)
    end

    test "remote-worker launch is refused before containment, marker, or process", %{workspace: workspace} do
      mock_exe = MockOpenCode.ensure_built!()

      # M1-H-F: the adapter has no SSH execution path, so a launch naming a
      # remote worker host is refused outright instead of silently running
      # the child locally and uncontained under a remote host's slot.
      assert {:error, {:opencode_remote_host_ineligible, "worker-1"}} =
               Adapter.start_session(workspace, "--mock-mode=hang",
                 provider: "anthropic",
                 model: "claude-3-5-sonnet",
                 executable: mock_exe,
                 worker_host: "worker-1"
               )

      refute WorkerContainment.contained_launch?("worker-1")

      # No marker exists for a refused launch.
      launches = Application.fetch_env!(:symphony_elixir, :launch_marker_root)
      assert {:error, :enoent} = File.ls(launches)
    end
  end

  describe "OpenCode 1.18.28 completion contract" do
    test "successful single-step turn completes on terminal step_finish without session.status" do
      stream =
        step_start_event("ses_c1", "msg_1") <>
          tool_use_completed_event("ses_c1", "msg_1", "read", "call_1", "file contents") <>
          step_finish_event("ses_c1", "msg_1", "stop", 50, 150)

      result =
        Parser.new()
        |> Parser.feed(stream)
        |> Parser.finish(0)
        |> Parser.to_result()

      assert result.completion_state == :completed
      assert result.failure_evidence == []
      assert result.session_id == "ses_c1"
      assert result.message_ids == ["msg_1"]
      assert result.usage.input_tokens == 50
      assert result.usage.output_tokens == 150
    end

    test "successful multi-step turn completes only after the terminal step_finish" do
      stream =
        step_start_event("ses_c2", "msg_1") <>
          step_finish_event("ses_c2", "msg_1", "tool-calls", 40, 60) <>
          tool_use_completed_event("ses_c2", "msg_1", "read", "call_1", "data") <>
          step_start_event("ses_c2", "msg_2") <>
          step_finish_event("ses_c2", "msg_2", "stop", 60, 90)

      result =
        Parser.new()
        |> Parser.feed(stream)
        |> Parser.finish(0)
        |> Parser.to_result()

      assert result.completion_state == :completed
      assert result.failure_evidence == []
      assert result.message_ids == ["msg_1", "msg_2"]
      assert result.usage.input_tokens == 100
      assert result.usage.output_tokens == 150
      assert result.usage.total_tokens == 250
    end

    test "intermediate tool-calls step_finish does not complete the turn until the terminal finish" do
      stream =
        step_start_event("ses_c3", "msg_1") <>
          step_finish_event("ses_c3", "msg_1", "tool-calls", 40, 60)

      mid_state = Parser.new() |> Parser.feed(stream)
      assert mid_state.completion_state == :running

      result =
        mid_state
        |> Parser.feed(step_finish_event("ses_c3", "msg_1", "stop", 10, 20))
        |> Parser.finish(0)
        |> Parser.to_result()

      assert result.completion_state == :completed
    end

    test "tool-calls without terminal completion fails closed even with exit 0" do
      stream =
        step_start_event("ses_c4", "msg_1") <>
          step_finish_event("ses_c4", "msg_1", "tool-calls", 40, 60) <>
          tool_use_completed_event("ses_c4", "msg_1", "read", "call_1", "data")

      result =
        Parser.new()
        |> Parser.feed(stream)
        |> Parser.finish(0)
        |> Parser.to_result()

      assert result.completion_state == :failed
      assert {:incomplete_stream, :missing_completion_event} in result.failure_evidence
    end

    test "tool error preserves protocol completion on terminal step_finish while recording tool failure" do
      stream =
        tool_use_error_event("ses_c5", "msg_1", "bash", "call_1", "permission denied") <>
          step_finish_event("ses_c5", "msg_1", "stop", 10, 20)

      result =
        Parser.new()
        |> Parser.feed(stream)
        |> Parser.finish(0)
        |> Parser.to_result()

      assert result.completion_state == :completed
      assert result.failure_evidence == []
      assert {:tool_error, "bash", "permission denied"} in result.tool_failures
    end

    test "malformed JSON with a secret never leaks it and retains no decoder struct" do
      secret = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz"
      linear = "lin_api_abcdefghijklmnopqrstuvwxyz"

      malformed =
        ~s({"type":"tool_use","broken":"#{secret} LINEAR_API_KEY=#{linear}) <>
          " trailing data"

      result =
        Parser.new()
        |> Parser.feed(malformed <> "\n")
        |> Parser.feed(step_finish_event("ses_c6", "msg_1", "stop", 10, 20))
        |> Parser.finish(0)
        |> Parser.to_result()

      assert result.completion_state == :failed
      assert [{:malformed_json_line, line, detail}] = result.failure_evidence

      assert is_binary(line)
      assert line =~ "[redacted]"
      refute line =~ secret
      refute line =~ linear
      assert byte_size(line) <= 4_096 + byte_size("…[truncated]")

      assert is_map(detail)
      assert inspect(detail) =~ "position"
      refute inspect(detail) =~ secret
      refute inspect(detail) =~ "Jason.DecodeError"
      refute inspect(result) =~ secret
      refute inspect(result) =~ "Jason.DecodeError"

      failure_info = Failure.failure_info({:malformed_json_line, line, detail})
      assert failure_info.failure_class == :persistent_worker_failure
      refute inspect(failure_info) =~ secret
      refute inspect(failure_info) =~ "Jason.DecodeError"
    end

    test "session.status idle alone does not complete a turn" do
      idle =
        Jason.encode!(%{
          "type" => "session.status",
          "sessionID" => "ses_idle",
          "status" => %{"type" => "idle"}
        }) <> "\n"

      result =
        Parser.new()
        |> Parser.feed(idle)
        |> Parser.finish(0)
        |> Parser.to_result()

      assert result.completion_state == :failed
      assert {:incomplete_stream, :missing_completion_event} in result.failure_evidence
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

    test "a tool error preserves protocol completion when a later terminal step_finish arrives" do
      stream =
        tool_use_error_event("ses_tool", "msg_1", "bash", "c1", "permission denied") <>
          step_finish_event("ses_tool", "msg_1", "stop", 10, 20)

      result =
        Parser.new()
        |> Parser.feed(stream)
        |> Parser.finish(0)
        |> Parser.to_result()

      assert result.completion_state == :completed
      assert result.failure_evidence == []
      assert {:tool_error, "bash", "permission denied"} in result.tool_failures
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
        |> Parser.feed(event <> step_finish_event("ses_secret", "m1", "stop", 1, 1))
        |> Parser.finish(0)
        |> Parser.to_result()

      rendered = hd(result.tool_events).output
      refute rendered =~ secret
      assert String.ends_with?(rendered, "…[truncated]")
      assert byte_size(rendered) <= 4_096
    end

    test "truncation across multibyte UTF-8 codepoint boundaries stays valid UTF-8 within byte budget" do
      # Test 2-byte characters (e.g. "ą" = 2 bytes)
      for prefix_len <- 0..3 do
        prefix = String.duplicate("x", prefix_len)
        input = prefix <> String.duplicate("ą", 2_500)
        bounded = Redactor.redact(input)

        assert String.valid?(bounded)
        assert String.ends_with?(bounded, "…[truncated]")
        assert byte_size(bounded) <= 4_096
        assert match?({:ok, _}, Jason.encode(bounded))
      end

      # Test 3-byte characters (e.g. "€" = 3 bytes)
      for prefix_len <- 0..4 do
        prefix = String.duplicate("x", prefix_len)
        input = prefix <> String.duplicate("€", 1_800)
        bounded = Redactor.redact(input)

        assert String.valid?(bounded)
        assert String.ends_with?(bounded, "…[truncated]")
        assert byte_size(bounded) <= 4_096
        assert match?({:ok, _}, Jason.encode(bounded))
      end

      # Test 4-byte characters (e.g. "🎉" = 4 bytes)
      for prefix_len <- 0..5 do
        prefix = String.duplicate("x", prefix_len)
        input = prefix <> String.duplicate("🎉", 1_500)
        bounded = Redactor.redact(input)

        assert String.valid?(bounded)
        assert String.ends_with?(bounded, "…[truncated]")
        assert byte_size(bounded) <= 4_096
        assert match?({:ok, _}, Jason.encode(bounded))
      end
    end

    test "malformed non-UTF-8 input is sanitized to valid UTF-8 and JSON-encodable without leaking secrets" do
      secret = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz"
      bearer = "Bearer my-secret-auth-token-12345"

      cases = [
        <<0xFF, 0xFE>> <> secret <> <<0x80>>,
        <<0x80, 0x81, 0x82>> <> bearer <> <<0x83>>,
        <<0xC0, 0xAF>> <> secret <> <<0xFF>>,
        <<0xED, 0xA0, 0x80>> <> " some data " <> bearer
      ]

      for malformed <- cases do
        redacted = Redactor.redact(malformed)

        assert String.valid?(redacted)
        assert match?({:ok, _}, Jason.encode(redacted))
        assert byte_size(redacted) <= 4_096
        refute redacted =~ secret
        refute redacted =~ "my-secret-auth-token"
        assert redacted =~ "[redacted]"
        assert redacted =~ "\uFFFD"
      end
    end

    test "malformed chardata with invalid bytes and list-shaped RestData is sanitized to valid UTF-8 with replacement characters" do
      secret = "sk-ant-api03-chardata-secret-xyz"

      chardata = [
        <<0xFF, 0xFE>>,
        ["hello ", <<0x80>>, secret],
        [10_000_000, " more "]
      ]

      redacted = Redactor.redact(chardata)
      assert is_list(redacted)
      assert match?({:ok, _}, Jason.encode(redacted))

      sanitized = Redactor.ensure_valid_utf8(chardata)
      assert is_binary(sanitized)
      assert String.valid?(sanitized)
      assert sanitized =~ "\uFFFD"
      assert match?({:ok, _}, Jason.encode(sanitized))

      sanitized_iodata = Redactor.sanitize_utf8([<<0xFF>>, <<0xFE>>, "ok"], [])
      bin = IO.iodata_to_binary(sanitized_iodata)
      assert String.valid?(bin)
      assert bin =~ "\uFFFD"
      assert bin =~ "ok"
    end

    test "pathological long invalid input runs in bounded time and memory without amplification" do
      secret = "sk-ant-api03-boundary-secret-9876543210"
      large_invalid = :binary.copy(<<0xFF>>, 500_000)
      large_with_secret = :binary.copy(<<0xFF>>, 100_000) <> secret <> :binary.copy(<<0xFE>>, 100_000)

      {elapsed_micro_1, redacted_1} =
        :timer.tc(fn -> Redactor.redact(large_invalid) end)

      assert is_binary(redacted_1)
      assert String.valid?(redacted_1)
      assert byte_size(redacted_1) <= 4_096
      assert String.ends_with?(redacted_1, "…[truncated]")
      assert redacted_1 =~ "\uFFFD"
      assert match?({:ok, _}, Jason.encode(redacted_1))
      assert elapsed_micro_1 < 250_000

      {elapsed_micro_2, redacted_2} =
        :timer.tc(fn -> Redactor.redact(large_with_secret) end)

      assert is_binary(redacted_2)
      assert String.valid?(redacted_2)
      assert byte_size(redacted_2) <= 4_096
      refute redacted_2 =~ secret
      assert match?({:ok, _}, Jason.encode(redacted_2))
      assert elapsed_micro_2 < 250_000
    end

    test "hardened token redaction scrubs secrets with word-character prefixes bypassing word boundaries" do
      secrets = [
        {"sk-ant-api03-abcdefghijklmnopqrstuvwxyz", "prefix_sk-ant-api03-abcdefghijklmnopqrstuvwxyz"},
        {"sk-ant-api03-abcdefghijklmnopqrstuvwxyz", "wordsk-ant-api03-abcdefghijklmnopqrstuvwxyz"},
        {"ghp_12345678901234567890", "var_ghp_12345678901234567890"},
        {"ghp_12345678901234567890", "tokenghp_12345678901234567890"},
        {"lin_api_abcdefghijklmnopqrstuvwxyz", "env_lin_api_abcdefghijklmnopqrstuvwxyz"},
        {"AKIA1234567890123456", "aws_AKIA1234567890123456"},
        {"xoxb-1234567890123", "slack_xoxb-1234567890123"},
        {"sk-openai-key-secret-123456", "my_sk-openai-key-secret-123456"},
        {"my-secret-bearer-token", "auth_bearer my-secret-bearer-token"},
        {"secret_pass_1234", "db_password=secret_pass_1234"},
        {"api_val_5678", "my_api_key=api_val_5678"}
      ]

      for {raw_secret, glued} <- secrets do
        redacted = Redactor.redact(glued)
        refute redacted =~ raw_secret
        assert redacted =~ "[redacted]"
        assert String.valid?(redacted)
        assert match?({:ok, _}, Jason.encode(redacted))
      end
    end

    test "repeated redaction is idempotent and preserves valid bounds" do
      inputs = [
        "already normal text",
        <<0xFF, 0xFE>> <> "sk-ant-api03-abcdefghijklmnopqrstuvwxyz" <> <<0x80>>,
        String.duplicate("long text with secret sk-ant-api03-abcdefghijklmnopqrstuvwxyz ", 200),
        "glued_ghp_12345678901234567890 and var_lin_api_12345678901234"
      ]

      for input <- inputs do
        once = Redactor.redact(input)
        twice = Redactor.redact(once)
        thrice = Redactor.redact(twice)

        assert twice == once
        assert thrice == once
        assert String.valid?(twice)
        assert byte_size(twice) <= 4_096
        assert match?({:ok, _}, Jason.encode(twice))
      end
    end

    test "oversized output and boundary-spanning secrets are scrubbed and bounded within 4096 bytes" do
      secret1 = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz"
      secret2 = "lin_api_abcdefghijklmnopqrstuvwxyz"
      secret3 = "ghp_12345678901234567890"

      prefix = String.duplicate("🚀", 1_000)
      input = prefix <> secret1 <> " " <> secret2 <> " " <> String.duplicate("語", 2_000) <> secret3

      redacted = Redactor.redact(input)

      assert String.valid?(redacted)
      assert String.ends_with?(redacted, "…[truncated]")
      assert byte_size(redacted) <= 4_096
      assert match?({:ok, _}, Jason.encode(redacted))
      refute redacted =~ secret1
      refute redacted =~ secret2
      refute redacted =~ secret3
    end

    test "parser malformed lines with non-UTF-8 bytes and secrets fail closed with sanitized JSON-encodable evidence" do
      secret = "sk-ant-api03-malformed-line-secret-xyz"
      malformed_chunk = ~s({"type": ") <> <<0xFF, 0xFE>> <> secret <> "\n"

      result =
        Parser.new()
        |> Parser.feed(malformed_chunk)
        |> Parser.finish(0)
        |> Parser.to_result()

      assert result.completion_state == :failed
      assert [{:malformed_json_line, line, detail}] = result.failure_evidence

      assert is_binary(line)
      assert String.valid?(line)
      assert match?({:ok, _}, Jason.encode(line))
      refute line =~ secret
      assert line =~ "[redacted]"

      assert is_map(detail)
      assert match?({:ok, _}, Jason.encode(detail))
    end

    test "failure classification sanitizes malformed multibyte error messages and secrets" do
      secret = "sk-ant-api03-failure-info-secret-12345"
      reason = "connection error: " <> <<0xFF, 0xFE>> <> secret <> " " <> String.duplicate("€", 2_000)

      info = Failure.failure_info(reason)

      assert is_binary(info.message)
      assert String.valid?(info.message)
      assert byte_size(info.message) <= 4_096
      assert match?({:ok, _}, Jason.encode(info.message))
      refute info.message =~ secret

      assert is_binary(info.raw)
      assert String.valid?(info.raw)
      assert byte_size(info.raw) <= 4_096
      assert match?({:ok, _}, Jason.encode(info.raw))
      refute info.raw =~ secret

      assert match?({:ok, _}, Jason.encode(info))
    end
  end

  describe "Process boundary regressions" do
    @tag :windows_only
    test "a multi-step turn succeeds only after the terminal step_finish", %{workspace: workspace} do
      assert {:ok, result} = run_mock(workspace, "--mock-mode=multi-step")

      assert result.exit_code == 0
      assert result.completion_state == :completed
      assert result.failure_evidence == []
      assert result.session_id == "ses_mock_123"
      assert result.message_ids == ["msg_01", "msg_02"]
      assert result.usage.input_tokens == 100
      assert result.usage.output_tokens == 150
      assert result.usage.total_tokens == 300
      assert abs(result.usage.cost - 0.005) < 1.0e-9
    end

    @tag :windows_only
    test "tool-calls without terminal completion is not success even with exit 0", %{workspace: workspace} do
      assert {:error, {{:incomplete_stream, :missing_completion_event}, result}} =
               run_mock(workspace, "--mock-mode=tool-calls-only")

      assert result.exit_code == 0
      assert result.completion_state == :failed
      assert result.usage.input_tokens == 40
      assert result.failure_info.failure_class == :persistent_worker_failure
    end

    @tag :windows_only
    test "malformed JSON with secrets exposes nothing in results, callbacks, or failure info", %{
      workspace: workspace
    } do
      secret = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz"
      linear = "lin_api_abcdefghijklmnopqrstuvwxyz"
      {:ok, agent} = Agent.start_link(fn -> [] end)

      assert {:error, {{:malformed_json_line, line, detail}, result}} =
               run_mock(workspace, "--mock-mode=malformed-secret", on_event: fn event -> Agent.update(agent, &[event | &1]) end)

      payload = inspect(result) <> inspect(Agent.get(agent, & &1)) <> inspect(result.failure_info)
      refute payload =~ secret
      refute payload =~ linear
      refute payload =~ "Jason.DecodeError"

      assert is_binary(line)
      assert line =~ "[redacted]"
      assert is_map(detail)
      assert result.exit_code == 0
      assert result.completion_state == :failed
      assert result.failure_info.failure_class == :persistent_worker_failure
    end

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
      assert tool_error.completion_state == :completed
      assert tool_error.failure_evidence == []
      assert {:tool_error, "read", "permission denied"} in tool_error.tool_failures
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
        refute Map.has_key?(parsed["permission"] || %{}, "*")
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

  defp step_start_event(session_id, message_id) do
    Jason.encode!(%{
      "type" => "step_start",
      "timestamp" => 1,
      "sessionID" => session_id,
      "part" => %{
        "type" => "step-start",
        "id" => "step_s1",
        "sessionID" => session_id,
        "messageID" => message_id
      }
    }) <> "\n"
  end

  defp step_finish_event(session_id, message_id, reason, input, output) do
    Jason.encode!(%{
      "type" => "step_finish",
      "timestamp" => 2,
      "sessionID" => session_id,
      "part" => %{
        "type" => "step-finish",
        "id" => "step_f1",
        "sessionID" => session_id,
        "messageID" => message_id,
        "reason" => reason,
        "cost" => 0.001,
        "tokens" => %{
          "input" => input,
          "output" => output,
          "reasoning" => 0,
          "cache" => %{"read" => 0, "write" => 0}
        }
      }
    }) <> "\n"
  end

  defp step_finish_tokens_line(tokens, opts \\ []) do
    Jason.encode!(%{
      "type" => "step_finish",
      "timestamp" => 2,
      "sessionID" => Keyword.get(opts, :session_id, "ses_acc"),
      "part" => %{
        "type" => "step-finish",
        "id" => Keyword.get(opts, :part_id, "step_f1"),
        "messageID" => Keyword.get(opts, :message_id, "msg_1"),
        "reason" => Keyword.get(opts, :reason, "stop"),
        "cost" => Keyword.get(opts, :cost, 0.001),
        "tokens" => tokens
      }
    }) <> "\n"
  end

  defp parse_step_usage(stream) do
    Parser.new()
    |> Parser.feed(stream)
    |> Parser.finish(0)
    |> Parser.to_result()
    |> Map.get(:usage)
  end

  defp tool_use_completed_event(session_id, message_id, tool, call_id, output) do
    Jason.encode!(%{
      "type" => "tool_use",
      "timestamp" => 2,
      "sessionID" => session_id,
      "part" => %{
        "type" => "tool",
        "id" => "toolu_1",
        "sessionID" => session_id,
        "messageID" => message_id,
        "tool" => tool,
        "callID" => call_id,
        "state" => %{"status" => "completed", "output" => output}
      }
    }) <> "\n"
  end

  defp tool_use_error_event(session_id, message_id, tool, call_id, error) do
    Jason.encode!(%{
      "type" => "tool_use",
      "timestamp" => 2,
      "sessionID" => session_id,
      "part" => %{
        "type" => "tool",
        "id" => "toolu_1",
        "sessionID" => session_id,
        "messageID" => message_id,
        "tool" => tool,
        "callID" => call_id,
        "state" => %{"status" => "error", "error" => error}
      }
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

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline, timeout_ms)
  end

  defp do_wait_until(fun, deadline, timeout_ms) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition was not met within #{timeout_ms}ms")
      else
        Process.sleep(50)
        do_wait_until(fun, deadline, timeout_ms)
      end
    end
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
