defmodule SymphonyElixir.AppServerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.WorkerEnvironment
  alias SymphonyElixir.DispatchRouter
  alias SymphonyElixir.RetryPolicy
  alias SymphonyElixir.TestSupport.FakeSSH

 # Symlink escape coverage runs with a real symlink when the host allows it and
 # with a directory junction otherwise; only an unavailable prerequisite skips it.
 @symlink_fixture_skip symlink_fixture_skip_reason()

 test "local shell resolution failure is returned before app-server initialization" do
   root = Path.join(System.tmp_dir!(), "symphony-shell-#{System.unique_integer([:positive])}")
   workspace = Path.join(root, "issue")
   missing_shell = Path.join(root, "missing-bash.exe")
   File.mkdir_p!(workspace)

   try do
     write_workflow_file!(Workflow.workflow_file_path(),
       workspace_root: root,
       codex_shell_executable: missing_shell
     )

     assert {:error, {:local_shell_unusable, ^missing_shell, _}} =
              AppServer.start_session(workspace)
   after
     File.rm_rf(root)
   end
 end

 test "local launch reaches app-server startup even when PATH has WSL launcher first" do
   test_root =
     Path.join(
       System.tmp_dir!(),
       "symphony-elixir-app-server-wsl-path-#{System.unique_integer([:positive])}"
     )

   previous_path = System.get_env("PATH")

   on_exit(fn ->
     restore_env("PATH", previous_path)
   end)

   try do
     System.put_env("PATH", "C:\\Windows\\System32;" <> (previous_path || ""))

     workspace_root = Path.join(test_root, "workspaces")
     workspace = Path.join(workspace_root, "MT-WSL-PATH")
     codex_binary = Path.join(test_root, "fake-codex")

     File.mkdir_p!(workspace)

     File.write!(codex_binary, """
     #!/bin/sh
     count=0
     while IFS= read -r line; do
       count=$((count + 1))
       case "$count" in
         1) printf '%s\\n' '{"id":1,"result":{}}' ;;
         2) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-wsl-path"}}}' ;;
         3) printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-wsl-path"}}}' ;;
         4) printf '%s\\n' '{"method":"turn/completed"}'; exit 0 ;;
         *) exit 0 ;;
       esac
    done
    """)

    File.chmod!(codex_binary, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{String.replace(codex_binary, "\\", "/")} app-server"
    )

    issue = %Issue{
       id: "issue-wsl-path",
       identifier: "MT-WSL-PATH",
       title: "Run with WSL first on PATH",
       description: "Validate Git Bash selection over WSL launcher",
       state: "In Progress",
       url: "https://example.org/issues/MT-WSL-PATH",
       labels: ["backend"]
     }

     assert {:ok, _result} = AppServer.run(workspace, "Run worker", issue)
   after
     File.rm_rf(test_root)
   end
 end

 test "app server rejects the workspace root and paths outside workspace root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-cwd-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-workspace-guard",
        identifier: "MT-999",
        title: "Validate workspace guard",
        description: "Ensure app-server refuses invalid cwd targets",
        state: "In Progress",
        url: "https://example.org/issues/MT-999",
        labels: ["backend"]
      }

      assert {:error, {:invalid_workspace_cwd, :workspace_root, _path}} =
               AppServer.run(workspace_root, "guard", issue)

      assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _path, _root}} =
               AppServer.run(outside_workspace, "guard", issue)
    after
      File.rm_rf(test_root)
    end
  end

  @tag skip: @symlink_fixture_skip
  test "app server rejects symlink escape cwd paths under the workspace root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-symlink-cwd-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")
      # The guard reports the expanded cwd, so keep the fixture path in that
      # canonical form; otherwise the pin below only holds where Path.expand does
      # not change separators or drive-letter case.
      symlink_workspace = Path.expand(Path.join(workspace_root, "MT-1000"))

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)
      link_dir_fixture!(outside_workspace, symlink_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-workspace-symlink-guard",
        identifier: "MT-1000",
        title: "Validate symlink workspace guard",
        description: "Ensure app-server refuses symlink escape cwd targets",
        state: "In Progress",
        url: "https://example.org/issues/MT-1000",
        labels: ["backend"]
      }

      assert {:error, {:invalid_workspace_cwd, :symlink_escape, ^symlink_workspace, _root}} =
               AppServer.run(symlink_workspace, "guard", issue)
    after
      remove_dir_link_fixtures!(test_root)
    end
  end

  test "turn timeout resets on stream updates and fires after silence" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-turn-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-TIMEOUT")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1) printf '%s\n' '{"id":1,"result":{}}' ;;
          2) ;;
          3) printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-timeout"}}}' ;;
          4)
            printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-timeout"}}}'
            sleep 0.15
            printf '%s\n' '{"method":"item/updated","params":{"item":{"id":"one"}}}'
            sleep 0.15
            printf '%s\n' '{"method":"item/updated","params":{"item":{"id":"two"}}}'
            sleep 0.15
            printf '%s\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *) exit 0 ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_turn_timeout_ms: 250
      )

      issue = %Issue{
        id: "issue-turn-timeout",
        identifier: "MT-TIMEOUT",
        title: "Stream timeout",
        description: "Keep active streams alive",
        state: "In Progress",
        url: "https://example.org/issues/MT-TIMEOUT",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "stream updates", issue)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1) printf '%s\n' '{"id":1,"result":{}}' ;;
          2) ;;
          3) printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-silent"}}}' ;;
          4)
            printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-silent"}}}'
            sleep 0.4
            printf '%s\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *) exit 0 ;;
        esac
      done
      """)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_turn_timeout_ms: 100
      )

      assert {:error, :turn_timeout} = AppServer.run(workspace, "silent turn", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server passes explicit turn sandbox policies through unchanged" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-supported-turn-policies-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-1001")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-supported-turn-policies.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-supported-turn-policies.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-1001"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-1001"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      issue = %Issue{
        id: "issue-supported-turn-policies",
        identifier: "MT-1001",
        title: "Validate explicit turn sandbox policy passthrough",
        description: "Ensure runtime startup forwards configured turn sandbox policies unchanged",
        state: "In Progress",
        url: "https://example.org/issues/MT-1001",
        labels: ["backend"]
      }

      policy_cases = [
        %{"type" => "dangerFullAccess"},
        %{"type" => "externalSandbox", "profile" => "remote-ci"},
        %{"type" => "workspaceWrite", "writableRoots" => ["relative/path"], "networkAccess" => true},
        %{"type" => "futureSandbox", "nested" => %{"flag" => true}}
      ]

      Enum.each(policy_cases, fn configured_policy ->
        File.rm(trace_file)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          codex_command: "#{codex_binary} app-server",
          codex_turn_sandbox_policy: configured_policy
        )

        assert {:ok, _result} = AppServer.run(workspace, "Validate supported turn policy", issue)

        trace = File.read!(trace_file)
        lines = String.split(trace, "\n", trim: true)

        assert Enum.any?(lines, fn line ->
                 if String.starts_with?(line, "JSON:") do
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()
                   |> then(fn payload ->
                     payload["method"] == "turn/start" &&
                       get_in(payload, ["params", "sandboxPolicy"]) == configured_policy
                   end)
                 else
                   false
                 end
               end)
      end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server marks request-for-input events as a hard failure" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-input-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-88")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-input.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-input.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-88\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-88\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/input_required\",\"id\":\"resp-1\",\"params\":{\"requiresInput\":true,\"reason\":\"blocked\"}}'
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-input",
        identifier: "MT-88",
        title: "Input needed",
        description: "Cannot satisfy codex input",
        state: "In Progress",
        url: "https://example.org/issues/MT-88",
        labels: ["backend"]
      }

      assert {:error, {:turn_input_required, payload}} =
               AppServer.run(workspace, "Needs input", issue)

      assert payload["method"] == "turn/input_required"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server treats MCP elicitation requests as hard input blockers" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-mcp-elicitation-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-188")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-188"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-188"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"mcpServer/elicitation/request","params":{"message":"Need operator input"}}'
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-mcp-elicitation",
        identifier: "MT-188",
        title: "MCP elicitation",
        description: "Cannot satisfy MCP input",
        state: "In Progress",
        url: "https://example.org/issues/MT-188",
        labels: ["backend"]
      }

      assert {:error, {:turn_input_required, payload}} =
               AppServer.run(workspace, "Needs MCP input", issue)

      assert payload["method"] == "mcpServer/elicitation/request"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server fails when command execution approval is required under safer defaults" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-approval-required-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-89")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-89"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-89"}}}'
            printf '%s\\n' '{"id":99,"method":"item/commandExecution/requestApproval","params":{"command":"gh pr view","cwd":"/tmp","reason":"need approval"}}'
            ;;
          *)
            sleep 1
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-approval-required",
        identifier: "MT-89",
        title: "Approval required",
        description: "Ensure safer defaults do not auto approve requests",
        state: "In Progress",
        url: "https://example.org/issues/MT-89",
        labels: ["backend"]
      }

      assert {:error, {:approval_required, payload}} =
               AppServer.run(workspace, "Handle approval request", issue)

      assert payload["method"] == "item/commandExecution/requestApproval"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server auto-approves command execution approval requests when approval policy is never" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-auto-approve-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-89")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-auto-approve.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-auto-approve.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-89\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-89\"}}}'
            printf '%s\\n' '{\"id\":99,\"method\":\"item/commandExecution/requestApproval\",\"params\":{\"command\":\"gh pr view\",\"cwd\":\"/tmp\",\"reason\":\"need approval\"}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-auto-approve",
        identifier: "MT-89",
        title: "Auto approve request",
        description: "Ensure app-server approval requests are handled automatically",
        state: "In Progress",
        url: "https://example.org/issues/MT-89",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Handle approval request", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 1 and
                   get_in(payload, ["params", "capabilities", "experimentalApi"]) == true
               else
                 false
               end
             end)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 2 and
                   case get_in(payload, ["params", "dynamicTools"]) do
                     [
                       %{
                         "description" => description,
                         "inputSchema" => %{"required" => ["query"]},
                         "name" => "linear_graphql"
                       }
                     ] ->
                       description =~ "Linear"

                     _ ->
                       false
                   end
               else
                 false
               end
             end)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 99 and get_in(payload, ["result", "decision"]) == "acceptForSession"
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server auto-approves MCP tool approval prompts when approval policy is never" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-user-input-auto-approve-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-717")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-tool-user-input-auto-approve.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-tool-user-input-auto-approve.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-717\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-717\"}}}'
            printf '%s\\n' '{\"id\":110,\"method\":\"item/tool/requestUserInput\",\"params\":{\"itemId\":\"call-717\",\"questions\":[{\"header\":\"Approve app tool call?\",\"id\":\"mcp_tool_call_approval_call-717\",\"isOther\":false,\"isSecret\":false,\"options\":[{\"description\":\"Run the tool and continue.\",\"label\":\"Approve Once\"},{\"description\":\"Run the tool and remember this choice for this session.\",\"label\":\"Approve this Session\"},{\"description\":\"Decline this tool call and continue.\",\"label\":\"Deny\"},{\"description\":\"Cancel this tool call\",\"label\":\"Cancel\"}],\"question\":\"The linear MCP server wants to run the tool \\\"Save issue\\\", which may modify or delete data. Allow this action?\"}],\"threadId\":\"thread-717\",\"turnId\":\"turn-717\"}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-tool-user-input-auto-approve",
        identifier: "MT-717",
        title: "Auto approve MCP tool request user input",
        description: "Ensure app tool approval prompts continue automatically",
        state: "In Progress",
        url: "https://example.org/issues/MT-717",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Handle tool approval prompt", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 110 and
                   get_in(payload, ["result", "answers", "mcp_tool_call_approval_call-717", "answers"]) ==
                     ["Approve this Session"]
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server blocks freeform tool input prompts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-user-input-required-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-718")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-718"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-718"}}}'
            printf '%s\\n' '{"id":111,"method":"item/tool/requestUserInput","params":{"itemId":"call-718","questions":[{"header":"Provide context","id":"freeform-718","isOther":false,"isSecret":false,"options":null,"question":"What comment should I post back to the issue?"}],"threadId":"thread-718","turnId":"turn-718"}}'
            ;;
          5)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-tool-user-input-required",
        identifier: "MT-718",
        title: "Non interactive tool input answer",
        description: "Ensure arbitrary tool prompts receive a generic answer",
        state: "In Progress",
        url: "https://example.org/issues/MT-718",
        labels: ["backend"]
      }

      assert {:error, {:turn_input_required, payload}} =
               AppServer.run(workspace, "Handle generic tool input", issue)

      assert payload["method"] == "item/tool/requestUserInput"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server blocks option-based tool input prompts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-user-input-options-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-719")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-719\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-719\"}}}'
            printf '%s\\n' '{\"id\":112,\"method\":\"item/tool/requestUserInput\",\"params\":{\"itemId\":\"call-719\",\"questions\":[{\"header\":\"Choose an action\",\"id\":\"options-719\",\"isOther\":false,\"isSecret\":false,\"options\":[{\"description\":\"Proceed with the requested action.\",\"label\":\"Allow\"},{\"description\":\"Do not proceed.\",\"label\":\"Deny\"}],\"question\":\"How should I proceed?\"}],\"threadId\":\"thread-719\",\"turnId\":\"turn-719\"}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-tool-user-input-options",
        identifier: "MT-719",
        title: "Option based tool input block",
        description: "Ensure option prompts require operator input",
        state: "In Progress",
        url: "https://example.org/issues/MT-719",
        labels: ["backend"]
      }

      assert {:error, {:turn_input_required, payload}} =
               AppServer.run(workspace, "Handle option based tool input", issue)

      assert payload["method"] == "item/tool/requestUserInput"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server rejects unsupported dynamic tool calls without stalling" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-call-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-90")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-tool-call.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-tool-call.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-90\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-90\"}}}'
            printf '%s\\n' '{\"id\":101,\"method\":\"item/tool/call\",\"params\":{\"tool\":\"some_tool\",\"callId\":\"call-90\",\"threadId\":\"thread-90\",\"turnId\":\"turn-90\",\"arguments\":{}}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-tool-call",
        identifier: "MT-90",
        title: "Unsupported tool call",
        description: "Ensure unsupported tool calls do not stall a turn",
        state: "In Progress",
        url: "https://example.org/issues/MT-90",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Reject unsupported tool calls", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 101 and
                   get_in(payload, ["result", "success"]) == false and
                   String.contains?(
                     get_in(payload, ["result", "output"]),
                     "Unsupported dynamic tool"
                   )
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server executes supported dynamic tool calls and returns the tool result" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-supported-tool-call-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-90A")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-supported-tool-call.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-supported-tool-call.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-90a\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-90a\"}}}'
            printf '%s\\n' '{\"id\":102,\"method\":\"item/tool/call\",\"params\":{\"name\":\"linear_graphql\",\"callId\":\"call-90a\",\"threadId\":\"thread-90a\",\"turnId\":\"turn-90a\",\"arguments\":{\"query\":\"query Viewer { viewer { id } }\",\"variables\":{\"includeTeams\":false}}}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-supported-tool-call",
        identifier: "MT-90A",
        title: "Supported tool call",
        description: "Ensure supported tool calls return tool output",
        state: "In Progress",
        url: "https://example.org/issues/MT-90A",
        labels: ["backend"]
      }

      test_pid = self()

      tool_executor = fn tool, arguments ->
        send(test_pid, {:tool_called, tool, arguments})

        %{
          "success" => true,
          "contentItems" => [
            %{
              "type" => "inputText",
              "text" => ~s({"data":{"viewer":{"id":"usr_123"}}})
            }
          ]
        }
      end

      assert {:ok, _result} =
               AppServer.run(workspace, "Handle supported tool calls", issue, tool_executor: tool_executor)

      assert_received {:tool_called, "linear_graphql",
                       %{
                         "query" => "query Viewer { viewer { id } }",
                         "variables" => %{"includeTeams" => false}
                       }}

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 102 and
                   get_in(payload, ["result", "success"]) == true and
                   get_in(payload, ["result", "output"]) ==
                     ~s({"data":{"viewer":{"id":"usr_123"}}})
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server emits tool_call_failed for supported tool failures" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-call-failed-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-90B")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-tool-call-failed.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-tool-call-failed.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-90b\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-90b\"}}}'
            printf '%s\\n' '{\"id\":103,\"method\":\"item/tool/call\",\"params\":{\"tool\":\"linear_graphql\",\"callId\":\"call-90b\",\"threadId\":\"thread-90b\",\"turnId\":\"turn-90b\",\"arguments\":{\"query\":\"query Viewer { viewer { id } }\"}}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-tool-call-failed",
        identifier: "MT-90B",
        title: "Tool call failed",
        description: "Ensure supported tool failures emit a distinct event",
        state: "In Progress",
        url: "https://example.org/issues/MT-90B",
        labels: ["backend"]
      }

      test_pid = self()

      tool_executor = fn tool, arguments ->
        send(test_pid, {:tool_called, tool, arguments})

        %{
          "success" => false,
          "contentItems" => [
            %{
              "type" => "inputText",
              "text" => ~s({"error":{"message":"boom"}})
            }
          ]
        }
      end

      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      assert {:ok, _result} =
               AppServer.run(workspace, "Handle failed tool calls", issue,
                 on_message: on_message,
                 tool_executor: tool_executor
               )

      assert_received {:tool_called, "linear_graphql", %{"query" => "query Viewer { viewer { id } }"}}

      assert_received {:app_server_message, %{event: :tool_call_failed, payload: %{"params" => %{"tool" => "linear_graphql"}}}}
    after
      File.rm_rf(test_root)
    end
  end

  test "app server buffers partial JSON lines until newline terminator" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-partial-line-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-91")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            padding=$(printf '%*s' 1100000 '' | tr ' ' a)
            printf '{"id":1,"result":{},"padding":"%s"}\\n' "$padding"
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-91"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-91"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-partial-line",
        identifier: "MT-91",
        title: "Partial line decode",
        description: "Ensure JSON parsing waits for newline-delimited messages",
        state: "In Progress",
        url: "https://example.org/issues/MT-91",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Validate newline-delimited buffering", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server captures codex side output and logs it through Logger" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-stderr-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-92")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-92"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-92"}}}'
            ;;
          4)
            printf '%s\\n' 'warning: this is stderr noise' >&2
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-stderr",
        identifier: "MT-92",
        title: "Capture stderr",
        description: "Ensure codex stderr is captured and logged",
        state: "In Progress",
        url: "https://example.org/issues/MT-92",
        labels: ["backend"]
      }

      test_pid = self()
      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      log =
        capture_log(fn ->
          assert {:ok, _result} =
                   AppServer.run(workspace, "Capture stderr log", issue, on_message: on_message)
        end)

      assert_received {:app_server_message, %{event: :turn_completed}}
      refute_received {:app_server_message, %{event: :malformed}}
      assert log =~ "Codex turn stream output: warning: this is stderr noise"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server emits malformed events for JSON-like protocol lines that fail to decode" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-malformed-protocol-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-93")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-93"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-93"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-malformed-protocol",
        identifier: "MT-93",
        title: "Malformed protocol frame",
        description: "Ensure malformed JSON-like frames are surfaced to the orchestrator",
        state: "In Progress",
        url: "https://example.org/issues/MT-93",
        labels: ["backend"]
      }

      test_pid = self()
      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      assert {:ok, _result} =
               AppServer.run(workspace, "Capture malformed protocol line", issue, on_message: on_message)

      assert_received {:app_server_message, %{event: :malformed, payload: "{\"method\":\"turn/completed\""}}
      assert_received {:app_server_message, %{event: :turn_completed}}
    after
      File.rm_rf(test_root)
    end
  end

  test "app server does not pass tracker credentials to the local Codex child" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-secret-env-#{System.unique_integer([:positive])}"
      )

    custom_secret_env = "SYMP_CUSTOM_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    profile_marker_env = "SYMP_TEST_BASH_PROFILE_LOADED_#{System.unique_integer([:positive])}"
    previous_secret = System.get_env("LINEAR_API_KEY")
    previous_custom_secret = System.get_env(custom_secret_env)
    previous_home = System.get_env("HOME")
    previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

    on_exit(fn ->
      restore_env("LINEAR_API_KEY", previous_secret)
      restore_env(custom_secret_env, previous_custom_secret)
      restore_env("HOME", previous_home)
      restore_env("SYMP_TEST_CODEx_TRACE", previous_trace)
    end)

    try do
      bash_home = Path.join(test_root, "bash-home")
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-SECRET")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-secret-env.trace")

      File.mkdir_p!(bash_home)
      File.mkdir_p!(workspace)

      File.write!(Path.join(bash_home, ".bash_profile"), """
      export LINEAR_API_KEY='profile-canonical-secret-that-must-not-reach-child'
      export #{custom_secret_env}='profile-custom-secret-that-must-not-reach-child'
      export #{profile_marker_env}=1
      export MIX_BUILD_PATH='profile-build-path'
      """)

      System.put_env("LINEAR_API_KEY", "canonical-secret-that-must-not-reach-child")
      System.put_env(custom_secret_env, "custom-secret-that-must-not-reach-child")
      System.put_env("HOME", bash_home)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="$SYMP_TEST_CODEx_TRACE"
      printf 'PROFILE_LOADED:%s\n' "$#{profile_marker_env}" >> "$trace_file"
      printf 'CANONICAL_SECRET:%s\n' "$LINEAR_API_KEY" >> "$trace_file"
      printf 'CUSTOM_SECRET:%s\n' "$#{custom_secret_env}" >> "$trace_file"
      printf 'MIX_BUILD_PATH:%s\n' "$MIX_BUILD_PATH" >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-secret"}}}'
            ;;
          3)
            printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-secret"}}}'
            ;;
          4)
            printf '%s\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        tracker_api_token: "$#{custom_secret_env}",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-secret-env",
        identifier: "MT-SECRET",
        title: "Keep tracker auth in Symphony",
        description: "Ensure the child cannot bypass the centrally-authenticated tool boundary",
        state: "In Progress",
        url: "https://example.org/issues/MT-SECRET",
        labels: ["security"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Do not inherit tracker auth", issue)
      assert File.read!(trace_file) =~ "PROFILE_LOADED:1\n"
      assert File.read!(trace_file) =~ "CANONICAL_SECRET:\n"
      assert File.read!(trace_file) =~ "CUSTOM_SECRET:\n"
      refute File.read!(trace_file) =~ "secret-that-must-not-reach-child"
      # Non-Windows workers keep their ambient environment: a Bash profile value
      # survives. The Windows workspace-rooted override is covered separately.
      assert File.read!(trace_file) =~ "MIX_BUILD_PATH:profile-build-path\n"
    after
      File.rm_rf(test_root)
    end
  end

  @tag skip: if(:os.type() == {:win32, :nt}, do: false, else: "Windows-only worker environment")
  test "app server gives local Windows workers workspace-rooted BEAM paths" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-worker-environment-#{System.unique_integer([:positive])}"
      )

    previous_home = System.get_env("HOME")
    previous_trace = System.get_env("SYMP_TEST_WORKER_ENV_TRACE")

    on_exit(fn ->
      restore_env("HOME", previous_home)
      restore_env("SYMP_TEST_WORKER_ENV_TRACE", previous_trace)
    end)

    try do
      bash_home = Path.join(test_root, "bash-home")
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-WORKER-ENV")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "worker-environment.trace")

      File.mkdir_p!(bash_home)
      File.mkdir_p!(workspace)

      # A host profile must not be able to point the worker back at ambient paths.
      File.write!(Path.join(bash_home, ".bash_profile"), """
      export MIX_BUILD_PATH='profile-build-path'
      export TMPDIR='profile-temp-path'
      """)

      System.put_env("HOME", bash_home)
      System.put_env("SYMP_TEST_WORKER_ENV_TRACE", trace_file)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="$SYMP_TEST_WORKER_ENV_TRACE"

      for name in MIX_BUILD_PATH MIX_DEPS_PATH HEX_HOME MIX_HOME ELIXIR_MAKE_CACHE_DIR REBAR_CACHE_DIR REBAR_GLOBAL_CONFIG_DIR TMPDIR TEMP TMP; do
        printf '%s:%s\\n' "$name" "$(printenv "$name")" >> "$trace_file"
      done

      count=0

      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1) printf '%s\\n' '{"id":1,"result":{}}' ;;
          2) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-worker-env"}}}' ;;
          3) printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-worker-env"}}}' ;;
          4) printf '%s\\n' '{"method":"turn/completed"}'; exit 0 ;;
          *) exit 0 ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      # The launcher runs the configured command through `bash -lc`, so the
      # command path must be bash-compatible on Windows.
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{String.replace(codex_binary, "\\", "/")} app-server"
      )

      issue = %Issue{
        id: "issue-worker-environment",
        identifier: "MT-WORKER-ENV",
        title: "Root BEAM paths in the workspace",
        description: "Ensure Windows workers keep Mix/Hex/temp state inside the issue workspace",
        state: "In Progress",
        url: "https://example.org/issues/MT-WORKER-ENV",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Root BEAM paths", issue)
      assert {:ok, worker_environment} = WorkerEnvironment.prepare(workspace)

      for {name, value} <- worker_environment do
        assert File.read!(trace_file) =~ "#{name}:#{value}\n"
      end

      refute File.read!(trace_file) =~ "profile-build-path"
      refute File.read!(trace_file) =~ "profile-temp-path"
    after
      File.rm_rf(test_root)
    end
  end

  @tag skip: if(:os.type() == {:win32, :nt}, do: false, else: "Windows-only worker environment")
  test "app server reports the workspace BEAM path that failed for a Windows worker" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-worker-environment-failure-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-WORKER-ENV-FAIL")
      collision = Path.join(workspace, ".mix_build")

      File.mkdir_p!(workspace)
      File.write!(collision, "not a directory")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-worker-environment-failure",
        identifier: "MT-WORKER-ENV-FAIL",
        title: "Report the failing BEAM path",
        description: "Ensure setup failures name the environment variable and path",
        state: "In Progress",
        url: "https://example.org/issues/MT-WORKER-ENV-FAIL",
        labels: ["backend"]
      }

      assert {:error, {:workspace_beam_environment_failed, "MIX_BUILD_PATH", path, reason}} =
               AppServer.run(workspace, "Root BEAM paths", issue)

      assert Path.basename(path) == ".mix_build"
      assert reason in [:eexist, :enotdir]
    after
      File.rm_rf(test_root)
    end
  end

  test "app server launches over ssh for remote workers" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-remote-ssh-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      remote_workspace = "/remote/workspaces/MT-REMOTE"

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)

      FakeSSH.install!(test_root, :jsonrpc, trace_file: trace_file)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "/remote/workspaces",
        codex_command: "fake-remote-codex app-server"
      )

      issue = %Issue{
        id: "issue-remote",
        identifier: "MT-REMOTE",
        title: "Run remote app server",
        description: "Validate ssh-backed codex startup",
        state: "In Progress",
        url: "https://example.org/issues/MT-REMOTE",
        labels: ["backend"]
      }

      assert {:ok, _result} =
               AppServer.run(
                 remote_workspace,
                 "Run remote worker",
                 issue,
                 worker_host: "worker-01:2200"
               )

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, &String.starts_with?(&1, "ARGV:"))
      assert argv_line =~ "-T -p 2200 worker-01 bash -lc"
      assert argv_line =~ "cd "
      assert argv_line =~ remote_workspace
      assert argv_line =~ "unset LINEAR_API_KEY"
      assert argv_line =~ "exec "
      assert argv_line =~ "fake-remote-codex app-server"

      expected_turn_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [remote_workspace],
        "readOnlyAccess" => %{"type" => "fullAccess"},
        "networkAccess" => false,
        "excludeTmpdirEnvVar" => false,
        "excludeSlashTmp" => false
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "cwd"]) == remote_workspace
                 end)
               else
                 false
               end
             end)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "cwd"]) == remote_workspace &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server consumes a pre-materialized fallback selection without changing session lifecycle" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-fallback-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-FALLBACK")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "thread-start.trace")

      File.mkdir_p!(workspace)

      fallback_model = "gpt-5.6-terra"
      fallback_reasoning = "high"

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        echo "$line" >> "#{trace_file}"
        case "$count" in
          1) printf '%s\\n' '{"id":1,"result":{}}' ;;
          2) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-fallback","model":"#{fallback_model}","reasoningEffort":"#{fallback_reasoning}"}}}' ;;
          3) printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-fallback"}}}' ;;
          4) printf '%s\\n' '{"method":"turn/completed"}'; exit 0 ;;
          *) exit 0 ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{String.replace(codex_binary, "\\", "/")} app-server",
        codex_fallback_enabled: true,
        codex_fallback_model: fallback_model,
        codex_fallback_reasoning_effort: fallback_reasoning
      )

      issue = %Issue{
        id: "issue-fallback",
        identifier: "MT-FALLBACK",
        title: "Consume a pre-materialized fallback selection",
        description: "Validate the DispatchRouter fallback seam end to end",
        state: "In Progress",
        url: "https://example.org/issues/MT-FALLBACK",
        labels: ["backend"]
      }

      selection = DispatchRouter.materialize(:fallback, issue)
      assert %DispatchRouter.Selection{route: :fallback, model: ^fallback_model} = selection

      assert {:ok, result} =
               AppServer.run(workspace, "Run fallback worker", issue, dispatch_selection: selection)

      assert result.thread_id == "thread-fallback"
      assert result.turn_id == "turn-fallback"
      assert result.session_id == "thread-fallback-turn-fallback"
      assert result.model == fallback_model
      assert result.reasoning_effort == fallback_reasoning
      assert result.model_source == :explicit_override
      assert result.reasoning_source == :explicit_override
      assert result.route_source == :explicit_override

      thread_start =
        File.read!(trace_file)
        |> String.split("\n", trim: true)
        |> Enum.find(&String.contains?(&1, "\"thread/start\""))

      payload = Jason.decode!(thread_start)

      # PathSafety canonicalizes the local workspace (drive-letter case and
      # separators on Windows), so compare the sent cwd in normalized form.
      assert payload["params"]["cwd"] |> String.replace("\\", "/") |> String.downcase() ==
               workspace |> String.replace("\\", "/") |> String.downcase()

      assert payload["params"]["model"] == fallback_model
      assert payload["params"]["config"]["model_reasoning_effort"] == fallback_reasoning
    after
      File.rm_rf(test_root)
    end
  end

  # MIC-195 Slice C precondition (C0 review finding): the presence of the
  # :dispatch_selection key is meaningful. These tests use a nonexistent codex
  # binary as a discriminator — a legacy re-resolution would attempt a spawn
  # and fail with a port error, while fail-closed must return
  # {:invalid_dispatch_selection, _} without ever attempting a session.
  describe "dispatch_selection precondition fails closed" do
    defp precondition_workspace_root(test_root) do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)
      workspace_root
    end

    defp precondition_issue do
      %Issue{
        id: "issue-precondition",
        identifier: "MT-PRECOND",
        title: "Dispatch selection precondition",
        description: "Invalid dispatch selections must never silently execute primary",
        state: "In Progress",
        url: "https://example.org/issues/MT-PRECOND",
        labels: ["backend"]
      }
    end

    test "absent dispatch_selection resolves through the legacy WorkerRouting path" do
      test_root =
        Path.join(System.tmp_dir!(), "symphony-elixir-precond-absent-#{System.unique_integer([:positive])}")

      try do
        workspace_root = precondition_workspace_root(test_root)
        workspace = Path.join(workspace_root, "MT-PRECOND")
        File.mkdir_p!(workspace)
        codex_binary = Path.join(test_root, "fake-codex")

        File.write!(codex_binary, """
        #!/bin/sh
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          case "$count" in
            1) printf '%s\\n' '{"id":1,"result":{}}' ;;
            2) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-precond"}}}' ;;
            *) exit 0 ;;
          esac
        done
        """)

        File.chmod!(codex_binary, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          codex_command: "#{String.replace(codex_binary, "\\", "/")} app-server",
          codex_fallback_enabled: true,
          codex_fallback_model: "gpt-5.6-sol"
        )

        issue = precondition_issue()

        # No :dispatch_selection key: legacy resolution must still be used, and
        # it must NOT pick up the configured fallback route.
        assert {:ok, session} = AppServer.start_session(workspace, issue: issue)
        assert session.model == "gpt-6-astra"
        assert session.route_source == :default
      after
        File.rm_rf(test_root)
      end
    end

    test "a leaked fallback materialization error tuple fails closed instead of starting a primary session" do
      test_root =
        Path.join(System.tmp_dir!(), "symphony-elixir-precond-tuple-#{System.unique_integer([:positive])}")

      try do
        workspace_root = precondition_workspace_root(test_root)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          # Any session attempt would fail with an unresolvable codex command,
          # never with the precondition error.
          codex_command: "definitely-missing-codex-binary-#{System.unique_integer([:positive])} app-server"
        )

        issue = precondition_issue()

        assert {:error, {:invalid_dispatch_selection, {:error, :fallback_disabled}}} =
                 AppServer.start_session(Path.join(workspace_root, "MT-PRECOND"),
                   issue: issue,
                   dispatch_selection: {:error, :fallback_disabled}
                 )
      after
        File.rm_rf(test_root)
      end
    end

    test "a malformed dispatch_selection fails closed instead of starting a primary session" do
      test_root =
        Path.join(System.tmp_dir!(), "symphony-elixir-precond-malformed-#{System.unique_integer([:positive])}")

      try do
        workspace_root = precondition_workspace_root(test_root)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          codex_command: "definitely-missing-codex-binary-#{System.unique_integer([:positive])} app-server"
        )

        issue = precondition_issue()
        malformed = %{model: "gpt-5.6-sol", reasoning_effort: "high"}

        assert {:error, {:invalid_dispatch_selection, ^malformed}} =
                 AppServer.start_session(Path.join(workspace_root, "MT-PRECOND"),
                   issue: issue,
                   dispatch_selection: malformed
                 )
      after
        File.rm_rf(test_root)
      end
    end

    test "an invalid dispatch_selection error is classified as a non-provider failure" do
      reason = {:invalid_dispatch_selection, {:error, :fallback_disabled}}
      assert AgentRunner.classify_failure(reason) == :transient_worker_failure
      refute reason |> AgentRunner.classify_failure() |> RetryPolicy.fallback_eligible_class?()
    end
  end
end
