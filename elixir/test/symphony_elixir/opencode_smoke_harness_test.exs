defmodule SymphonyElixir.OpenCodeSmokeHarnessTest do
  use SymphonyElixir.TestSupport

  Code.require_file("../support/mock_opencode.exs", __DIR__)
  Code.require_file("../support/opencode_worker_fixture.exs", __DIR__)
  Code.require_file("../support/scratch_process.exs", __DIR__)

  alias SymphonyElixir.LaunchMarker
  # alias SymphonyElixir.TestSupport.MockOpenCode
  alias SymphonyElixir.TestSupport.OpenCodeWorkerFixture
  alias SymphonyElixir.TestSupport.ScratchProcess
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.WorkerContainment
  alias SymphonyElixir.DispatchRouter

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "opencode-harness-ws-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)

    marker_root = Path.join(workspace, ".symphony-state/launches")
    File.mkdir_p!(marker_root)
    Application.put_env(:symphony_elixir, :launch_marker_root, marker_root)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :launch_marker_root)
      File.rm_rf(workspace)
    end)

    {:ok, workspace: workspace, marker_root: marker_root}
  end

  # ===========================================================================
  # 1. Deterministic Fixture Build & Capabilities
  # ===========================================================================

  describe "Fixture Build & Baseline" do
    test "mock_opencode binary compiles deterministically and exists" do
      exe = OpenCodeWorkerFixture.ensure_built!()
      assert is_binary(exe)
      assert File.exists?(exe)
      assert String.ends_with?(exe, "mock_opencode.exe")
    end
  end

  # ===========================================================================
  # 2. Execution Simulations (Single-turn, Multi-step, Tool Failure, Malformed, Stalled, Interrupted)
  # ===========================================================================

  describe "Execution Simulations" do
    test "simulates successful single-turn execution with terminal step_finish", %{workspace: ws} do
      {output, exit_code} =
        OpenCodeWorkerFixture.run_mock_direct(ws, [
          "--mock-mode=success",
          "--mock-session-id=ses_single_turn",
          "--mock-tokens-in=120",
          "--mock-tokens-out=240",
          "--mock-tokens-reasoning=30"
        ])

      assert exit_code == 0
      lines = String.split(output, ["\r\n", "\n"], trim: true)
      json_lines = Enum.filter(lines, &String.starts_with?(&1, "{"))

      assert length(json_lines) == 3
      [step_start, tool_use, step_finish] = Enum.map(json_lines, &Jason.decode!/1)

      assert step_start["type"] == "step_start"
      assert step_start["sessionID"] == "ses_single_turn"

      assert tool_use["type"] == "tool_use"
      assert tool_use["part"]["state"]["status"] == "completed"

      assert step_finish["type"] == "step_finish"
      assert step_finish["part"]["reason"] == "stop"
      assert step_finish["part"]["tokens"]["input"] == 120
      assert step_finish["part"]["tokens"]["output"] == 240
      assert step_finish["part"]["tokens"]["reasoning"] == 30
    end

    test "simulates multi-step execution with cumulative token accounting", %{workspace: ws} do
      {output, exit_code} =
        OpenCodeWorkerFixture.run_mock_direct(ws, [
          "--mock-mode=multi-step",
          "--mock-session-id=ses_multi_step"
        ])

      assert exit_code == 0

      usage = OpenCodeWorkerFixture.calculate_cumulative_usage(output)

      # Step 1: in=40, out=60, reas=10, cache_r=5, cache_w=5, cost=0.002
      # Step 2: in=60, out=90, reas=15, cache_r=10, cache_w=5, cost=0.003
      assert usage.input_tokens == 100
      assert usage.output_tokens == 150
      assert usage.reasoning_tokens == 25
      assert usage.cache_read_tokens == 15
      assert usage.cache_write_tokens == 10
      assert usage.total_tokens == 250
      assert usage.cost == 0.005
    end

    test "simulates tool failure with error state in tool_use event", %{workspace: ws} do
      {output, exit_code} =
        OpenCodeWorkerFixture.run_mock_direct(ws, [
          "--mock-mode=tool-failure",
          "--mock-session-id=ses_tool_fail"
        ])

      assert exit_code == 0
      lines = String.split(output, ["\r\n", "\n"], trim: true)
      json_lines = Enum.filter(lines, &String.starts_with?(&1, "{"))

      tool_event =
        Enum.find_value(json_lines, fn line ->
          case Jason.decode(line) do
            {:ok, %{"type" => "tool_use"} = map} -> map
            _ -> nil
          end
        end)

      assert tool_event != nil
      assert tool_event["part"]["state"]["status"] == "error"
      assert tool_event["part"]["state"]["error"] == "permission denied"
    end

    test "malformed-secret fixture emits raw secrets and does not redact them", %{workspace: ws} do
      {output, exit_code} =
        OpenCodeWorkerFixture.run_mock_direct(ws, [
          "--mock-mode=malformed-secret"
        ])

      assert exit_code == 0
      lines = String.split(output, ["\r\n", "\n"], trim: true)

      markers = OpenCodeWorkerFixture.raw_secret_markers()

      broken =
        Enum.find(lines, fn line ->
          String.contains?(line, markers.anthropic) and String.contains?(line, "LINEAR_API_KEY=")
        end)

      assert is_binary(broken)
      assert broken =~ markers.linear
      assert {:error, _reason} = Jason.decode(broken)
      refute output =~ "[redacted]"

      # The mock still appends a valid terminal line. Decoding that line here
      # is not the production parser, and the raw secret above was not removed.
      valid_finishes =
        Enum.filter(lines, fn line ->
          case Jason.decode(line) do
            {:ok, %{"type" => "step_finish"}} -> true
            _ -> false
          end
        end)

      assert length(valid_finishes) >= 1
    end

    test "secret fixture emits raw secrets on stdout and stderr", %{workspace: ws} do
      {output, exit_code} =
        OpenCodeWorkerFixture.run_mock_direct(ws, [
          "--mock-mode=secret"
        ])

      assert exit_code == 0
      markers = OpenCodeWorkerFixture.raw_secret_markers()
      lines = output_lines(output)

      assert output =~ markers.anthropic
      assert output =~ "LINEAR_API_KEY="
      assert output =~ markers.linear
      assert output =~ "stderr " <> markers.anthropic
      refute output =~ "[redacted]"

      secret_tool =
        Enum.find_value(lines, fn line ->
          case Jason.decode(line) do
            {:ok, %{"type" => "tool_use"} = map} -> map
            _ -> nil
          end
        end)

      assert secret_tool["part"]["state"]["output"] =~ markers.anthropic
      assert secret_tool["part"]["state"]["output"] =~ markers.linear
    end

    test "error mode observes a nonzero exit and error event without proving no-fallback", %{
      workspace: ws
    } do
      {output, exit_code} =
        OpenCodeWorkerFixture.run_mock_direct(ws, [
          "--mock-mode=error"
        ])

      assert exit_code == 1

      assert OpenCodeWorkerFixture.process_failure_scope() == %{
               observed: :process_failure,
               production_no_fallback: :unwired
             }

      error_event =
        Enum.find_value(output_lines(output), fn line ->
          case Jason.decode(line) do
            {:ok, %{"type" => "error"} = map} -> map
            _ -> nil
          end
        end)

      assert error_event["error"]["name"] == "ModelNotFoundError"
      assert error_event["error"]["data"]["message"] =~ "Model not found"

      refute Enum.any?(output_lines(output), fn line ->
               case Jason.decode(line) do
                 {:ok, %{"type" => "step_finish"}} -> true
                 _ -> false
               end
             end)
    end

    test "simulates interrupted execution with non-zero exit and missing terminal event", %{workspace: ws} do
      {output, exit_code} =
        OpenCodeWorkerFixture.run_mock_direct(ws, [
          "--mock-mode=interrupted",
          "--mock-exit-code=130"
        ])

      assert exit_code == 130
      lines = String.split(output, ["\r\n", "\n"], trim: true)
      json_lines = Enum.filter(lines, &String.starts_with?(&1, "{"))

      # Never emitted a step_finish event
      refute Enum.any?(json_lines, fn l ->
               case Jason.decode(l) do
                 {:ok, %{"type" => "step_finish"}} -> true
                 _ -> false
               end
             end)
    end
  end

  # ===========================================================================
  # 3. Process Containment, Positive Death & Zero Orphaned Processes
  # ===========================================================================

  describe "Process Containment & Zero Orphaned Processes" do
    test "confirmed termination under Windows Job Object produces conclusive receipt", %{workspace: ws} do
      issue_id = "ISSUE-MOCK-CONFIRMED-#{System.unique_integer([:positive])}"

      session =
        OpenCodeWorkerFixture.spawn_contained_worker(
          workspace: ws,
          issue_id: issue_id,
          mock_args: ["--mock-mode=success"]
        )

      assert is_port(session.port)
      assert is_integer(session.wrapper_pid)

      confirmation = OpenCodeWorkerFixture.stop_and_confirm_worker(session, 3000)

      assert confirmation.status == :TERMINATED_CONFIRMED
      assert confirmation.receipt["tree_drained"] == true
      assert confirmation.receipt["terminal_reason"] in ["NATURAL_EXIT", "COOPERATIVE_EXIT"]

      # Both wrapper and worker are dead
      assert OpenCodeWorkerFixture.assert_no_orphaned_processes([session.wrapper_pid]) == :ok
    end

    test "unconfirmed termination fails closed and preserves LaunchMarker", %{workspace: ws, marker_root: mr} do
      issue_id = "ISSUE-MOCK-UNCONFIRMED-#{System.unique_integer([:positive])}"

      # Simulate an unconfirmed receipt (e.g. tree_drained: false)
      receipt_path = Path.join(ws, "unconfirmed.receipt.json")

      File.write!(
        receipt_path,
        Jason.encode!(%{
          "schema_version" => 1,
          "launch_id" => "mock-launch-fail",
          "tree_drained" => false,
          "terminal_reason" => "CRASH",
          "termination_mode" => "hard_kill",
          "child_exit_code" => 1
        })
      )

      identity =
        WorkerContainment.new_identity(
          issue_id: issue_id,
          attempt_id: 1,
          workspace: ws,
          worker_host: nil
        )
        |> Map.put("receipt_path", receipt_path)

      # Record LaunchMarker before launch
      :ok = LaunchMarker.record(identity, identifier: issue_id, root: mr)

      # Classify receipt -> unconfirmed
      parsed = WorkerContainment.parse_receipt(receipt_path)
      assert {:ok, receipt_map} = parsed
      assert WorkerContainment.classify_receipt(receipt_map) == :TERMINATION_UNCONFIRMED

      # Because termination is unconfirmed, marker must NOT be cleared!
      # Subsequent reuse and cleanup gates must fail closed!
      assert {:blocked, _reason} = LaunchMarker.reuse_gate(issue_id, root: mr)
      assert {:blocked, _reason} = LaunchMarker.cleanup_gate(issue_id, root: mr)
    end

    test "Job Object containment kills worker and spawned grandchild with zero orphaned processes", %{workspace: ws} do
      issue_id = "ISSUE-MOCK-ORPHAN-#{System.unique_integer([:positive])}"
      ScratchProcess.ensure_built!()
      grandchild_exe = ScratchProcess.scratch_exe()

      grandchild_pid_file = Path.join(ws, "opencode-grandchild.pid")

      session =
        OpenCodeWorkerFixture.spawn_contained_worker(
          workspace: ws,
          issue_id: issue_id,
          mock_args: [
            "--mock-mode=stalled",
            "--mock-grandchild-exe=" <> grandchild_exe,
            "--mock-grandchild-args=--id grandchild_test --scratch " <> ws <> " --heartbeat-ms 200"
          ]
        )

      # Wait for grandchild PID to be written
      grandchild_pid =
        Enum.find_value(1..30, fn _ ->
          if File.exists?(grandchild_pid_file) do
            case File.read(grandchild_pid_file) do
              {:ok, pid_str} ->
                case Integer.parse(String.trim(pid_str)) do
                  {pid, _} -> pid
                  _ -> nil
                end

              _ ->
                nil
            end
          else
            Process.sleep(100)
            nil
          end
        end)

      assert is_integer(grandchild_pid)
      assert OpenCodeWorkerFixture.pid_liveness(grandchild_pid) == :alive

      # Now stop and confirm the parent session through Job Object containment
      confirmation = OpenCodeWorkerFixture.stop_and_confirm_worker(session, 2000)

      assert confirmation.status == :TERMINATED_CONFIRMED
      assert confirmation.receipt["tree_drained"] == true

      # Both parent wrapper AND grandchild process must be dead!
      assert OpenCodeWorkerFixture.assert_no_orphaned_processes([session.wrapper_pid, grandchild_pid]) == :ok
    end
  end

  describe "PID liveness probe" do
    test "tasklist failure is unknown and is not treated as a clean tree" do
      failing = fn _args -> {"tasklist failed", 1} end
      quoted_other = fn _args -> {~S["other.exe","11","Console","1","1 K"], 0} end
      empty = fn _args -> {"", 0} end
      missing = fn _args -> raise "tasklist missing" end
      healthy_miss = fn _args -> {"INFO: No tasks are running which match the specified criteria.", 0} end
      alive = fn _args -> {~S["mock_opencode.exe","4242","Console"], 0} end

      assert OpenCodeWorkerFixture.pid_liveness(4242, probe: failing) == :unknown
      assert OpenCodeWorkerFixture.pid_liveness(4242, probe: quoted_other) == :unknown
      assert OpenCodeWorkerFixture.pid_liveness(4242, probe: empty) == :unknown
      assert OpenCodeWorkerFixture.pid_liveness(4242, probe: missing) == :unknown
      assert OpenCodeWorkerFixture.pid_liveness(0, probe: healthy_miss) == :unknown
      assert OpenCodeWorkerFixture.pid_liveness(4242, probe: healthy_miss) == :gone
      assert OpenCodeWorkerFixture.pid_liveness(4242, probe: alive) == :alive

      assert {:probe_unknown, [4242]} =
               OpenCodeWorkerFixture.assert_no_orphaned_processes([4242],
                 timeout_ms: 0,
                 probe: failing
               )
    end
  end

  # ===========================================================================
  # 4. LaunchMarker Lifecycle & Fence Semantics
  # ===========================================================================

  describe "LaunchMarker Lifecycle" do
    test "marker is recorded prior to spawn and cleared only on confirmed termination", %{
      workspace: ws,
      marker_root: mr
    } do
      issue_id = "ISSUE-MARKER-CYCLE-#{System.unique_integer([:positive])}"

      session =
        OpenCodeWorkerFixture.spawn_contained_worker(
          workspace: ws,
          issue_id: issue_id,
          authority_root: mr,
          mock_args: ["--mock-mode=success"]
        )

      # Marker must exist while worker is running
      marker_path = LaunchMarker.marker_path(issue_id, root: mr)
      assert File.exists?(marker_path)

      assert {:ok, stored} = LaunchMarker.read(issue_id, root: mr)
      assert stored["issue_id"] == issue_id
      assert stored["worker_identity"]["wrapper_pid"] == to_string(session.wrapper_pid)

      # Stop and confirm
      confirmation = OpenCodeWorkerFixture.stop_and_confirm_worker(session, 2000)
      assert confirmation.status == :TERMINATED_CONFIRMED

      # Clear marker on confirmed death
      :ok = LaunchMarker.clear(session.identity, root: mr)

      refute File.exists?(marker_path)
      assert LaunchMarker.reuse_gate(issue_id, root: mr) == :allowed
    end

    test "simulated interruption keeps the LaunchMarker blocked and is not BEAM recovery", %{
      workspace: ws,
      marker_root: mr
    } do
      issue_id = "ISSUE-INTERRUPTED-#{System.unique_integer([:positive])}"

      identity =
        WorkerContainment.new_identity(
          issue_id: issue_id,
          attempt_id: 1,
          workspace: ws,
          worker_host: nil
        )

      :ok = LaunchMarker.record(identity, identifier: issue_id, root: mr)

      :ok =
        LaunchMarker.record_wrapper_identity(
          Map.put(identity, "wrapper_pid", "999999"),
          identifier: issue_id,
          root: mr
        )

      {output, exit_code} =
        OpenCodeWorkerFixture.run_mock_direct(ws, [
          "--mock-mode=interrupted",
          "--mock-exit-code=130"
        ])

      assert exit_code == 130
      assert output =~ "partial text before sudden interruption"

      refute Enum.any?(output_lines(output), fn line ->
               case Jason.decode(line) do
                 {:ok, %{"type" => "step_finish"}} -> true
                 _ -> false
               end
             end)

      assert {:ok, stored} = LaunchMarker.read(issue_id, root: mr)
      assert stored["issue_id"] == issue_id
      assert stored["worker_identity"]["wrapper_pid"] == "999999"
      assert LaunchMarker.fence_verdict(issue_id, root: mr) == {:error, :unknown}

      assert LaunchMarker.reuse_gate(issue_id, root: mr) ==
               {:blocked, :worker_termination_unproven}

      assert LaunchMarker.cleanup_gate(issue_id, root: mr) ==
               {:blocked, :worker_termination_unproven}

      assert File.exists?(LaunchMarker.marker_path(issue_id, root: mr))

      assert OpenCodeWorkerFixture.interruption_scope() == %{
               kind: :simulated_process_exit,
               beam_restart_recovery: :not_exercised
             }
    end
  end

  # ===========================================================================
  # 5. Routing Resolution & Codex Rollback
  # ===========================================================================

  describe "Routing & Codex Rollback" do
    test "routes to OpenCode worker when explicitly enabled and labeled" do
      issue = %Issue{
        id: "issue-1",
        identifier: "MIC-OC-1",
        labels: ["worker:opencode", "model:claude-3-5-sonnet"]
      }

      route = OpenCodeWorkerFixture.resolve_worker_route([opencode_enabled: true], issue)

      assert route.worker_type == :opencode
      assert route.authority == :fixture_only
      assert route.production_dispatch_router == :not_consulted
      assert route.model == "claude-3-5-sonnet"
      assert route.route_source == :explicit_override
    end

    test "rolls back cleanly to Codex route when opencode is disabled" do
      issue = %Issue{
        id: "issue-2",
        identifier: "MIC-OC-2",
        labels: ["worker:opencode", "model:claude-3-5-sonnet"]
      }

      # opencode_enabled: false
      route = OpenCodeWorkerFixture.resolve_worker_route([opencode_enabled: false], issue)

      assert route.authority == :fixture_only
      assert route.production_dispatch_router == :not_consulted
      assert route.worker_type == :codex
      assert route.model == "gpt-6-astra"
      assert route.reasoning_effort == "medium"
      assert route.route_source == :default
    end

    test "opts override wins over issue labels in routing resolution" do
      issue = %Issue{
        id: "issue-3",
        identifier: "MIC-OC-3",
        labels: ["worker:opencode", "model:claude-3-haiku"]
      }

      route =
        OpenCodeWorkerFixture.resolve_worker_route(
          [opencode_enabled: true, model: "claude-3-5-sonnet"],
          issue
        )

      assert route.worker_type == :opencode
      assert route.authority == :fixture_only
      assert route.model == "claude-3-5-sonnet"
    end

    test "production DispatchRouter selection is not the fixture route" do
      issue = %Issue{
        id: "issue-router",
        identifier: "MIC-OC-R",
        labels: ["worker:opencode", "model:claude-3-5-sonnet"]
      }

      fixture_route = OpenCodeWorkerFixture.resolve_worker_route([opencode_enabled: true], issue)
      assert fixture_route.worker_type == :opencode
      assert fixture_route.authority == :fixture_only
      assert fixture_route.production_dispatch_router == :not_consulted

      selection = DispatchRouter.materialize(:primary, issue, [])

      assert %DispatchRouter.Selection{route: :primary} = selection
      refute Map.has_key?(Map.from_struct(selection), :worker_type)
      assert selection.model == "claude-3-5-sonnet"
      assert selection.route_source == :explicit_override
    end
  end

  defp output_lines(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim_trailing(&1, "\r"))
    |> Enum.reject(&(&1 == ""))
  end
end
