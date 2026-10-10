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
  - A production selector, distinct from `OpenCodeWorkerFixture.resolve_worker_route/2`,
    chooses an OpenCode worker from an explicit label or config and returns the
    Codex default when OpenCode is disabled. Baseline `DispatchRouter.materialize/3`
    only accepts `:primary` and `:fallback`.
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

      assert {:ok, summary} = run_fn.()
      assert summary.status == :completed
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

      # Verify production start_session records marker before process and cleans up
      adapter_mod = SymphonyElixir.OpenCode.Adapter

      identity =
        SymphonyElixir.WorkerContainment.new_identity(
          issue_id: issue_id,
          attempt_id: 1,
          workspace: ws,
          worker_host: nil
        )

      session_opts = [
        provider: "anthropic",
        model: "claude-3-5-sonnet",
        executable: mock_exe,
        identity: identity,
        authority_root: mr
      ]

      assert {:ok, session} = apply(adapter_mod, :start_session, [ws, "prompt", session_opts])

      # Marker must exist during active session
      marker_path = LaunchMarker.marker_path(issue_id, root: mr)
      assert File.exists?(marker_path)

      # Clean stop clears marker
      assert %{status: :TERMINATED_CONFIRMED} = apply(adapter_mod, :stop_session, [session])
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
      flunk(
        "M1 INTEGRATION BLOCKED: production DispatchRouter selection of an OpenCode worker is not assembled. " <>
          "Baseline DispatchRouter.materialize/3 accepts only :primary and :fallback and returns a Codex Selection " <>
          "with no worker_type. Gate after assembly: the production selector must choose worker_type :opencode from " <>
          "an explicit label or config, and must return the Codex default when OpenCode is disabled. " <>
          "OpenCodeWorkerFixture.resolve_worker_route/2 is fixture-only and must not satisfy this gate."
      )
    end
  end
end
