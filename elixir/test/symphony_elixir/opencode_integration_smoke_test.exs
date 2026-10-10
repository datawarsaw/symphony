defmodule SymphonyElixir.OpenCodeIntegrationSmokeTest do
  @moduledoc """
  M1 Integration-dependent smoke test suite for Symphony's OpenCode worker integration.

  ISOLATION NOTE:
  These checks verify the complete production integration between Symphony,
  OpenCode.Adapter (candidate 5df80de9 / da78cbf), and WorkerEvent (candidate c89905c1).
  On the accepted baseline (c90e2ad7), these production modules are not yet merged.
  Per the harness contract:
  - Integration tests are isolated under the `:opencode_integration` tag.
  - They are NOT silently disabled or marked as passed.
  - When run against the baseline, they fail explicitly identifying the exact
    unmerged integration dependencies awaiting wiring.
  - When the integration branch is merged, they run and pass automatically.

  Gates that must go green only after the production modules are assembled:
  - `SymphonyElixir.OpenCode.Adapter` is loaded and can start/stop the mock
    behind `LaunchMarker`.
  - `SymphonyElixir.OpenCode` runs the mock and returns a completed summary.
  - `SymphonyElixir.WorkerEvent.from_opencode/1` normalizes the multi-step stream.
  - `SymphonyElixir.OpenCode.Redactor.redact/1` removes the raw secrets emitted
    by both `malformed-secret` and `secret` mock modes.
  - `SymphonyElixir.OpenCode.Adapter.validate_model_selection/1` rejects a bare
    model. That is the no-fallback guarantee. The `error` mock's nonzero exit
    does not satisfy it.
  - The production selector — `SymphonyElixir.HarnessSelection`, wired into the
    orchestrator dispatch boundary (M1-D) — chooses an OpenCode worker from
    explicit configuration and returns the Codex default when OpenCode is
    disabled. `OpenCodeWorkerFixture.resolve_worker_route/2` is fixture-only
    and must not satisfy that gate.
  """

  use SymphonyElixir.TestSupport

  @moduletag :opencode_integration

  Code.require_file("../support/mock_opencode.exs", __DIR__)
  Code.require_file("../support/opencode_worker_fixture.exs", __DIR__)

  alias SymphonyElixir.LaunchMarker
  alias SymphonyElixir.TestSupport.MockOpenCode
  alias SymphonyElixir.TestSupport.OpenCodeWorkerFixture

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "opencode-integration-ws-#{System.unique_integer([:positive])}")

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
  # Integration Dependency Verification
  # ===========================================================================

  describe "M1 Integration Dependencies" do
    test "OpenCode adapter production module is loaded" do
      assert Code.ensure_loaded?(SymphonyElixir.OpenCode.Adapter),
             "M1 INTEGRATION BLOCKED: SymphonyElixir.OpenCode.Adapter (5df80de / da78cbf) not yet merged into baseline"
    end

    test "WorkerEvent harness-neutral event contract module is loaded" do
      assert Code.ensure_loaded?(SymphonyElixir.WorkerEvent),
             "M1 INTEGRATION BLOCKED: SymphonyElixir.WorkerEvent (c89905c) not yet merged into baseline"
    end
  end

  # ===========================================================================
  # End-to-End Adapter & Event Contract Integration
  # ===========================================================================

  describe "End-to-End OpenCode Adapter Integration" do
    test "production OpenCode.run executes mock worker with deny-by-default config", %{workspace: ws} do
      assert Code.ensure_loaded?(SymphonyElixir.OpenCode),
             "M1 INTEGRATION BLOCKED: SymphonyElixir.OpenCode module not loaded"

      mock_exe = MockOpenCode.ensure_built!()

      # When wired, executes the production OpenCode runner
      run_fn = fn ->
        apply(SymphonyElixir.OpenCode, :run, [
          ws,
          "test prompt",
          [
            provider: "anthropic",
            model: "claude-3-5-sonnet",
            executable: mock_exe,
            mock_mode: "success"
          ]
        ])
      end

      # i1 adapter contract: the run summary reports the completion state as
      # `:completion_state` (required key of run_result); success additionally
      # requires clean JSONL, exit 0 and TERMINATED_CONFIRMED containment
      # evidence, which run/3 has already verified before returning :ok.
      assert {:ok, summary} = run_fn.()
      assert summary.completion_state == :completed
      assert summary.usage.total_tokens > 0
    end

    test "production OpenCode.Adapter gates launches behind durable LaunchMarker", %{
      workspace: ws,
      marker_root: mr
    } do
      assert Code.ensure_loaded?(SymphonyElixir.OpenCode.Adapter),
             "M1 INTEGRATION BLOCKED: SymphonyElixir.OpenCode.Adapter module not loaded"

      mock_exe = MockOpenCode.ensure_built!()
      issue_id = "ISSUE-OC-GATE-#{System.unique_integer([:positive])}"

      # i1 adapter contract: the adapter derives the fenceable identity from
      # the issue-keyed launch opts (`issue_id:`/`attempt_id:`/`identifier:`)
      # and records the marker into the store pinned by `:authority_root`
      # (the app-env `launch_marker_root` override in this test) BEFORE the
      # child process exists.
      session_opts = [
        provider: "anthropic",
        model: "claude-3-5-sonnet",
        executable: mock_exe,
        issue_id: issue_id,
        attempt_id: 1,
        identifier: "OC-GATE",
        authority_root: ws
      ]

      assert {:ok, session} = SymphonyElixir.OpenCode.Adapter.start_session(ws, "prompt", session_opts)

      # Marker must exist during active session and name the OpenCode harness
      marker_path = LaunchMarker.marker_path(issue_id, root: mr)
      assert File.exists?(marker_path)

      assert {:ok, marker} = LaunchMarker.read(issue_id, root: mr)
      assert marker["worker_identity"]["harness"] == "opencode"
      assert marker["issue_id"] == issue_id

      # Clean stop clears marker
      assert %{status: :TERMINATED_CONFIRMED} = SymphonyElixir.OpenCode.Adapter.stop_session(session)
      refute File.exists?(marker_path)
    end

    test "WorkerEvent.from_opencode normalizes mock event stream and token accounting" do
      assert Code.ensure_loaded?(SymphonyElixir.WorkerEvent),
             "M1 INTEGRATION BLOCKED: SymphonyElixir.WorkerEvent module not loaded"

      worker_event_mod = SymphonyElixir.WorkerEvent

      jsonl = OpenCodeWorkerFixture.multi_step_jsonl()
      lines = String.split(jsonl, ["\r\n", "\n"], trim: true)

      events =
        Enum.map(lines, fn line ->
          apply(worker_event_mod, :from_opencode, [line])
        end)

      # Check normalization
      assert length(events) == 5

      # Step 1 finish must be non-terminal (reason: tool-calls)
      step_1_finish = Enum.at(events, 1)
      assert step_1_finish.event == :step_finish
      refute step_1_finish.terminal?

      # Step 2 finish must be terminal (reason: stop)
      step_2_finish = Enum.at(events, 4)
      assert step_2_finish.event == :step_finish
      assert step_2_finish.terminal?
      assert step_2_finish.usage.output_tokens == 90
    end
  end

  describe "Sanitization, no-fallback, and production routing gates" do
    test "production redactor sanitizes malformed-secret and secret mock output", %{workspace: ws} do
      assert Code.ensure_loaded?(SymphonyElixir.OpenCode.Redactor),
             "M1 INTEGRATION BLOCKED: SymphonyElixir.OpenCode.Redactor.redact/1 is not assembled. " <>
               "Standalone malformed-secret and secret tests only prove the mock emits raw secrets. " <>
               "Do not count raw fixture output as redacted."

      markers = OpenCodeWorkerFixture.raw_secret_markers()

      {malformed, malformed_exit} =
        OpenCodeWorkerFixture.run_mock_direct(ws, ["--mock-mode=malformed-secret"])

      {secret, secret_exit} = OpenCodeWorkerFixture.run_mock_direct(ws, ["--mock-mode=secret"])

      assert malformed_exit == 0
      assert secret_exit == 0
      assert malformed =~ markers.anthropic
      assert secret =~ markers.linear

      for raw <- [malformed, secret] do
        redacted = apply(SymphonyElixir.OpenCode.Redactor, :redact, [raw])
        assert is_binary(redacted)
        assert redacted =~ "[redacted]"
        refute redacted =~ markers.anthropic
        refute redacted =~ markers.linear
      end
    end

    test "production adapter forbids automatic provider fallback" do
      assert Code.ensure_loaded?(SymphonyElixir.OpenCode.Adapter),
             "M1 INTEGRATION BLOCKED: SymphonyElixir.OpenCode.Adapter.validate_model_selection/1 " <>
               "is not assembled. The error mock's nonzero exit and error event are observed " <>
               "process failure only and are not the no-fallback guarantee."

      assert function_exported?(SymphonyElixir.OpenCode.Adapter, :validate_model_selection, 1),
             "M1 INTEGRATION BLOCKED: validate_model_selection/1 is missing from the assembled adapter"

      assert {:error, {:invalid_model_selection, message}} =
               apply(SymphonyElixir.OpenCode.Adapter, :validate_model_selection, [
                 [model: "claude-3-5-sonnet"]
               ])

      assert message =~ "Automatic fallback is forbidden"
    end

    test "production OpenCode worker selection is not the fixture router" do
      # M1-D gate: the production selector is SymphonyElixir.HarnessSelection,
      # wired into the orchestrator's dispatch boundary (one decision per
      # dispatch attempt). It authorizes OpenCode from explicit configuration
      # (enabled + pinned provider/model + tool allowlist + per-issue
      # allowlist) and answers Codex for everything else. The fixture router
      # `OpenCodeWorkerFixture.resolve_worker_route/2` is fixture-only and
      # must not satisfy this gate.
      assert Code.ensure_loaded?(SymphonyElixir.HarnessSelection),
             "M1 INTEGRATION BLOCKED: SymphonyElixir.HarnessSelection is not assembled"

      assert function_exported?(SymphonyElixir.HarnessSelection, :select, 2),
             "M1 INTEGRATION BLOCKED: HarnessSelection.select/2 is missing from the assembled tree"

      pilot = %{
        "enabled" => true,
        "provider" => "opencode-go",
        "model" => "muse-spark-1.3-contributor",
        "allowed_tools" => ["read"],
        "allowed_issues" => ["MIC-SEL-1"]
      }

      authorized = %Issue{id: "issue-sel-1", identifier: "MIC-SEL-1", labels: ["worker:opencode"]}
      unauthorized = %Issue{id: "issue-sel-2", identifier: "MIC-SEL-2", labels: ["worker:opencode"]}

      # The production selector chooses OpenCode only for the authorized issue
      assert {:opencode, :opencode_selected} = SymphonyElixir.HarnessSelection.select(authorized, pilot)

      # A label alone never selects OpenCode: authorization is configuration
      assert {:codex, :issue_not_authorized} = SymphonyElixir.HarnessSelection.select(unauthorized, pilot)

      # Disabled or absent configuration keeps the Codex default
      assert {:codex, :opencode_disabled} = SymphonyElixir.HarnessSelection.select(authorized, nil)
      assert {:codex, :opencode_disabled} = SymphonyElixir.HarnessSelection.select(authorized, %{"enabled" => false})

      # The dispatch boundary consumes the selector: with the pilot section
      # configured, the orchestrator's per-dispatch decision selects OpenCode
      # for the authorized issue and Codex for every other issue.
      write_workflow_file!(
        Workflow.workflow_file_path(),
        opencode_enabled: true,
        opencode_provider: "opencode-go",
        opencode_model: "muse-spark-1.3-contributor",
        opencode_allowed_tools: ["read"],
        opencode_allowed_issues: ["MIC-SEL-1"]
      )

      assert {:opencode, pilot_selection} = Orchestrator.dispatch_harness_for_test(authorized)
      assert pilot_selection.provider == "opencode-go"
      assert pilot_selection.model == "muse-spark-1.3-contributor"

      assert {:codex, :issue_not_authorized} = Orchestrator.dispatch_harness_for_test(unauthorized)

      # Route materialization stays Codex-shaped: harness selection is a
      # separate dispatch decision, not a Selection field.
      selection = SymphonyElixir.DispatchRouter.materialize(:primary, authorized, [])
      refute Map.has_key?(Map.from_struct(selection), :worker_type)
    end
  end
end
