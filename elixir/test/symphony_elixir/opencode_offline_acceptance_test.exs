defmodule SymphonyElixir.OpenCodeOfflineAcceptanceTest do
  @moduledoc """
  M1-E reconciled: deterministic offline end-to-end acceptance suite for the
  OpenCode M1 pilot, asserted against the committed M1-D dispatch
  implementation.

  Provenance: originally authored at db1350c on the pre-assembly baseline
  (8b329e4) with three `integration_gate` flunks awaiting dispatch wiring.
  This reconciliation ports it onto the committed M1-D dispatch baseline
  (9ce11fd) WITHOUT importing the pending M1-C configuration remediation
  (4f1dc51) or the redactor remediation (be77946), and replaces every flunk
  with behavioral assertions against the real production path:
  `Orchestrator` dispatch-boundary harness selection, `AgentRunner` OpenCode
  worker branch, and the `OpenCode.Adapter`/`LaunchMarker` containment
  contracts. No gate is satisfied by a fixture router or a permissive
  alternative.

  Contract areas under test:
  1. Authorized issue selects OpenCode (pure policy AND production dispatch).
  2. Unauthorized or disabled OpenCode leaves ordinary Codex selection unchanged.
  3. Invalid explicitly selected OpenCode configuration fails closed.
  4. Launch identity and authority_root propagate through the exact adapter
     option names the dispatch path forwards.
  5. LaunchMarker blocks uncertain reuse and destructive cleanup.
  6. Mock OpenCode success reaches an authoritative completion decision.
  7. Nonzero exit, timeout, malformed JSONL and interrupted workers do not
     produce false success.
  8. Failed OpenCode execution never silently launches a Codex worker.
  9. WorkerEvent preserves chronological event order, token accounting and
     session identity.
  10. Credentials are redacted in observable failure evidence.
  11. Containment leaves zero orphaned processes, proven by OS process evidence.
  12. Fail-closed configuration contract: what the committed baseline already
     enforces is asserted; the null-rejection hardening from the pending M1-C
     remediation (4f1dc51) is recorded as explicitly pending tests.

  Categorization & tagging:
  - Default (untagged / runnable): tests exercising committed production
    modules directly (HarnessSelection, OpenCode.Adapter/Config, WorkerEvent,
    Redactor, LaunchMarker, WorkerContainment).
  - @tag :integration_gate: tests asserting the wired production dispatch
    pipeline (Orchestrator dispatch boundary + AgentRunner execution). These
    now pass against the committed M1-D implementation.
  - @tag :restart_required: the cold-restart durability test, which spawns a
    genuinely separate BEAM VM and proves the fence from disk state alone.

  Root-pinning discipline: this suite NEVER sets the
  `:launch_marker_root` app-env override. That override takes precedence over
  the `:root`/`:authority_root` option inside `LaunchMarker.root/1`, so an
  app-env override equal to the authority root would mask a production
  failure to consume `authority_root` at all. Every marker assertion in this
  suite resolves the store through the explicit `:root`/`:authority_root`
  option and, where the test proves pinning, additionally refutes marker
  existence under the live-configuration default root.
  """

  use SymphonyElixir.TestSupport

  Code.require_file("../support/mock_opencode.exs", __DIR__)
  Code.require_file("../support/opencode_worker_fixture.exs", __DIR__)

  alias SymphonyElixir.Config.Schema.OpenCode, as: OpenCodeSchema
  alias SymphonyElixir.{DispatchRouter, HarnessSelection, LaunchMarker, OpenCode, WorkerEvent}
  alias SymphonyElixir.OpenCode.{Adapter, Config, Redactor}
  alias SymphonyElixir.TestSupport.{MockOpenCode, OpenCodeWorkerFixture, ScratchProcess}
  alias SymphonyElixir.Tracker.Issue

  @moduletag :opencode_integration

  setup _context do
    root = create_temp_fixture_root!("opencode-acceptance")
    state_root = Path.join(root, "state")
    workspace_root = Path.join(root, "workspaces")
    File.mkdir_p!(state_root)
    File.mkdir_p!(workspace_root)

    mock_exe = MockOpenCode.ensure_built!()
    Application.put_env(:symphony_elixir, :opencode_executable, mock_exe)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :opencode_executable)
      remove_temp_fixture_root!(root)
    end)

    {:ok, root: root, state_root: state_root, workspace_root: workspace_root, mock_exe: mock_exe, issue: test_issue("ISSUE-ACC-1", "MIC-ACC-1")}
  end

  defp test_issue(id, identifier) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "OpenCode acceptance " <> identifier,
      description: "M1-E reconciled acceptance",
      state: "Todo",
      url: "https://example.org/issues/" <> identifier,
      dispatchable: true
    }
  end

  defp pilot(identifier, overrides \\ []) do
    %OpenCodeSchema{
      enabled: true,
      provider: "mockprovider",
      model: "mock-model",
      timeout_ms: 15_000,
      allowed_tools: ["read", "glob"],
      allowed_issues: [identifier]
    }
    |> Map.merge(Map.new(overrides))
  end

  defp enable_pilot!(issue, overrides \\ []) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [
          opencode_enabled: true,
          opencode_provider: "mockprovider",
          opencode_model: "mock-model",
          opencode_allowed_tools: ["read", "glob"],
          opencode_allowed_issues: [issue.identifier]
        ],
        overrides
      )
    )
  end

  # The workspace AgentRunner resolves for the issue, pre-created so the test
  # can seed the mock's control file before the launch. The dispatch's
  # `authority_root` IS the state root, mirroring the orchestrator's
  # boot-pinned semantics.
  defp prepare_workspace!(%{state_root: state_root}, %Issue{identifier: identifier}, control \\ []) do
    workspace = Path.join(state_root, SymphonyElixir.Workspace.workspace_key(identifier))
    File.mkdir_p!(workspace)

    unless control == [] do
      File.write!(Path.join(workspace, "opencode-mock-control.txt"), Enum.join(control, "\n"))
    end

    workspace
  end

  defp dispatch_opts(%{state_root: state_root}, pilot_struct, extra \\ []) do
    Keyword.merge(
      [
        harness: :opencode,
        opencode: pilot_struct,
        attempt: 1,
        authority_root: state_root
      ],
      extra
    )
  end

  defp drain_worker_mailbox(timeout_ms \\ 200) do
    receive do
      {:codex_worker_update, issue_id, update} -> [{:update, issue_id, update} | drain_worker_mailbox(timeout_ms)]
      {:worker_termination, issue_id, info} -> [{:termination, issue_id, info} | drain_worker_mailbox(timeout_ms)]
      {:worker_runtime_info, issue_id, info} -> [{:runtime_info, issue_id, info} | drain_worker_mailbox(timeout_ms)]
    after
      timeout_ms -> []
    end
  end

  defp wait_until(fun, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition was not met within #{timeout_ms}ms")
      else
        Process.sleep(50)
        wait_until(fun, timeout_ms)
      end
    end
  end

  defp termination_evidence(messages) do
    List.keyfind(messages, :termination, 0) || flunk("no termination evidence reached the recipient")
  end

  defp streamed_updates(messages) do
    messages |> Enum.filter(&match?({:update, _, _}, &1)) |> Enum.map(fn {:update, _, u} -> u end)
  end

  # ===========================================================================
  # 1. Authorized Issue Selection
  # ===========================================================================

  describe "1. Authorized Issue Selection" do
    test "pure policy: authorized issue selects OpenCode under valid configuration" do
      config = %OpenCodeSchema{
        enabled: true,
        provider: "anthropic",
        model: "claude-3-5-sonnet",
        allowed_tools: ["read", "bash"],
        allowed_issues: ["ISSUE-100", "issue-200"]
      }

      issue_upper = %Issue{id: "id_100", identifier: "ISSUE-100"}
      issue_lower = %Issue{id: "id_200", identifier: "issue-200"}
      issue_mixed = %Issue{id: "id_100_mix", identifier: "Issue-100"}

      assert {:opencode, :opencode_selected} = HarnessSelection.select(issue_upper, config)
      assert {:opencode, :opencode_selected} = HarnessSelection.select(issue_lower, config)
      assert {:opencode, :opencode_selected} = HarnessSelection.select(issue_mixed, config)
    end

    test "pure policy: raw settings map normalizes through schema changeset" do
      raw_map = %{
        "enabled" => true,
        "provider" => "anthropic",
        "model" => "claude-3-5-sonnet",
        "allowed_tools" => ["read", "edit"],
        "allowed_issues" => ["MIC-100"]
      }

      issue = %Issue{id: "mic_100", identifier: "MIC-100"}
      assert {:opencode, :opencode_selected} = HarnessSelection.select(issue, raw_map)
    end

    @tag :integration_gate
    test "integration gate: production dispatch selects and launches OpenCode for an authorized issue",
         context do
      %{issue: issue} = context
      prepare_workspace!(context, issue)
      enable_pilot!(issue)

      # The orchestrator's per-dispatch harness decision (the same function
      # spawn_issue_on_worker_host consults once per attempt) selects the
      # pinned pilot snapshot for the authorized issue.
      assert {:opencode, snapshot} = Orchestrator.dispatch_harness_for_test(issue)
      assert %OpenCodeSchema{} = snapshot
      assert snapshot.provider == "mockprovider"
      assert snapshot.model == "mock-model"
      assert snapshot.allowed_tools == ["read", "glob"]
      assert snapshot.timeout_ms > 0
      assert issue.identifier in snapshot.allowed_issues

      # The decision drives a real dispatch through AgentRunner: the mock
      # worker executes and streams OpenCode-marked events to the recipient.
      assert :ok = AgentRunner.run(issue, self(), dispatch_opts(context, snapshot))

      messages = drain_worker_mailbox()

      assert {:runtime_info, runtime_issue_id, %{workspace_path: workspace}} =
               List.keyfind(messages, :runtime_info, 0)

      assert runtime_issue_id == issue.id
      assert File.dir?(workspace)

      updates = streamed_updates(messages)
      assert Enum.map(updates, & &1.event) == [:step_start, :tool_use, :step_finish]

      for update <- updates do
        assert update.harness == :opencode
        assert update.successful_completion? == false
      end

      # The harness decision is not a route materialization: DispatchRouter
      # selections stay Codex-shaped with no worker_type field, so an OpenCode
      # dispatch cannot hide inside a route and a route cannot silently
      # substitute a worker type.
      selection = DispatchRouter.materialize(:primary, issue, [])
      assert %DispatchRouter.Selection{} = selection
      refute Map.has_key?(Map.from_struct(selection), :worker_type)
    end
  end

  # ===========================================================================
  # 2. Unauthorized and Disabled OpenCode Leaves Codex Unchanged
  # ===========================================================================

  describe "2. Unauthorized and Disabled OpenCode Leaves Codex Unchanged" do
    test "pure policy: disabled OpenCode defaults to Codex" do
      disabled_config = %OpenCodeSchema{
        enabled: false,
        provider: "anthropic",
        model: "claude-3-5-sonnet",
        allowed_tools: ["read"],
        allowed_issues: ["ISSUE-100"]
      }

      issue = %Issue{id: "issue_100", identifier: "ISSUE-100"}

      assert {:codex, :opencode_disabled} = HarnessSelection.select(issue, disabled_config)
      assert {:codex, :opencode_disabled} = HarnessSelection.select(issue, nil)
    end

    test "pure policy: issue not in allowlist defaults to Codex" do
      config = %OpenCodeSchema{
        enabled: true,
        provider: "anthropic",
        model: "claude-3-5-sonnet",
        allowed_tools: ["read"],
        allowed_issues: ["ISSUE-100"]
      }

      unauthorized_issue = %Issue{id: "issue_999", identifier: "ISSUE-999"}
      nil_id_issue = %Issue{id: "issue_nil", identifier: nil}
      empty_id_issue = %Issue{id: "issue_empty", identifier: " "}

      assert {:codex, :issue_not_authorized} = HarnessSelection.select(unauthorized_issue, config)
      assert {:codex, :issue_not_authorized} = HarnessSelection.select(nil_id_issue, config)
      assert {:codex, :issue_not_authorized} = HarnessSelection.select(empty_id_issue, config)
      assert {:codex, :issue_not_authorized} = HarnessSelection.select(nil, config)
    end

    test "production dispatch: unauthorized or disabled OpenCode leaves ordinary Codex selection unchanged",
         context do
      %{issue: issue} = context

      # Without an opencode section the dispatch boundary answers Codex.
      assert {:codex, :opencode_disabled} = Orchestrator.dispatch_harness_for_test(issue)

      # With an active pilot that does not allowlist this issue, the dispatch
      # boundary still answers Codex — specifically not-authorized.
      enable_pilot!(issue, opencode_allowed_issues: ["MIC-OTHER"])
      assert {:codex, :issue_not_authorized} = Orchestrator.dispatch_harness_for_test(issue)

      # The Codex route materialization itself is unchanged by the pilot.
      selection = DispatchRouter.materialize(:primary, issue, [])

      assert %DispatchRouter.Selection{} = selection
      assert selection.route == :primary
      assert is_binary(selection.model) and selection.model != ""
      assert is_binary(selection.reasoning_effort)
      refute selection.pinned
    end
  end

  # ===========================================================================
  # 3. Invalid OpenCode Configuration Fails Closed
  # ===========================================================================

  describe "3. Invalid OpenCode Configuration Fails Closed" do
    test "pure policy: missing provider, model, or tools fails closed to Codex" do
      issue = %Issue{id: "iss_1", identifier: "ISSUE-1"}

      no_provider = %OpenCodeSchema{
        enabled: true,
        provider: "",
        model: "claude-3-5-sonnet",
        allowed_tools: ["read"],
        allowed_issues: ["ISSUE-1"]
      }

      no_model = %OpenCodeSchema{
        enabled: true,
        provider: "anthropic",
        model: "",
        allowed_tools: ["read"],
        allowed_issues: ["ISSUE-1"]
      }

      empty_tools = %OpenCodeSchema{
        enabled: true,
        provider: "anthropic",
        model: "claude-3-5-sonnet",
        allowed_tools: [],
        allowed_issues: ["ISSUE-1"]
      }

      invalid_map = %{"enabled" => "not_a_boolean"}

      assert {:codex, :opencode_incomplete} = HarnessSelection.select(issue, no_provider)
      assert {:codex, :opencode_incomplete} = HarnessSelection.select(issue, no_model)
      assert {:codex, :opencode_incomplete} = HarnessSelection.select(issue, empty_tools)
      assert {:codex, :invalid_opencode_config} = HarnessSelection.select(issue, invalid_map)
      assert {:codex, :invalid_opencode_config} = HarnessSelection.select(issue, :invalid_term)
    end

    test "OpenCode.Config rejects wildcard, auto-approve, and unknown tool grants" do
      assert {:error, :unrestricted_permissions_forbidden} =
               Config.build(allowed_tools: ["*"])

      assert {:error, :unrestricted_permissions_forbidden} =
               Config.build(allowed_tools: ["all"])

      assert {:error, :unrestricted_permissions_forbidden} =
               Config.build(allowed_tools: ["auto"])

      assert {:error, :unrestricted_permissions_forbidden} =
               Config.build(allowed_tools: ["read"], unrestricted_permissions: true)

      assert {:error, :unrestricted_permissions_forbidden} =
               Config.build(allowed_tools: ["read"], auto_approve: true)

      assert {:error, {:unknown_tool_permission, ["unauthorized_exec"]}} =
               Config.build(allowed_tools: ["unauthorized_exec"])

      assert {:ok, config} = Config.build(allowed_tools: ["read", "bash"])
      assert config["permission"]["*"] == "deny"
      assert config["permission"]["read"] == "allow"
      assert config["permission"]["bash"] == "allow"
      assert config["permission"]["edit"] == "deny"
      assert config["tools"]["read"] == true
      assert config["tools"]["bash"] == true
      assert config["tools"]["edit"] == false
    end

    test "OpenCode.Adapter.validate_model_selection rejects bare models and forbids automatic fallback" do
      assert {:error, {:invalid_model_selection, message}} =
               Adapter.validate_model_selection(model: "claude-3-5-sonnet")

      assert message =~ "Automatic fallback is forbidden"

      assert {:error, :missing_model} =
               Adapter.validate_model_selection(provider: "anthropic")

      assert {:ok, {"anthropic", "claude-3-5-sonnet"}} =
               Adapter.validate_model_selection(provider: "anthropic", model: "claude-3-5-sonnet")
    end

    test "OpenCode.Adapter.start_session refuses launch with unrestricted permissions before spawn", %{
      workspace_root: wr
    } do
      mock_exe = MockOpenCode.ensure_built!()
      workspace = Path.join(wr, "refused-launch")
      File.mkdir_p!(workspace)

      assert {:error, :unrestricted_permissions_forbidden} =
               Adapter.start_session(workspace, "prompt",
                 provider: "anthropic",
                 model: "claude-3-5-sonnet",
                 executable: mock_exe,
                 allowed_tools: ["*"]
               )
    end
  end

  # ===========================================================================
  # 4. Launch Identity and Authority Root Propagation
  # ===========================================================================

  describe "4. Launch Identity and Authority Root Propagation" do
    test "contained OpenCode launch establishes identity, pins authority_root, and writes LaunchMarker before process",
         %{workspace_root: wr, state_root: authority} do
      mock_exe = MockOpenCode.ensure_built!()
      workspace = Path.join(wr, "propagation")
      File.mkdir_p!(workspace)
      issue_id = "ISSUE-PROP-#{System.unique_integer([:positive])}"

      opts = [
        issue_id: issue_id,
        attempt_id: 1,
        identifier: "PROP-1",
        authority_root: authority,
        provider: "anthropic",
        model: "claude-3-5-sonnet",
        executable: mock_exe
      ]

      assert {:ok, session} = Adapter.start_session(workspace, "--mock-mode=success", opts)

      # 1. Identity is constructed and carries authority_root
      assert is_map(session.identity)
      assert session.identity["issue_id"] == issue_id
      assert session.identity["authority_root"] == authority
      assert is_binary(session.identity["launch_id"])
      assert is_binary(session.identity["launch_id"])
      assert is_binary(session.identity["receipt_path"])
      assert session.identity["harness"] == "opencode"

      # 2. The durable LaunchMarker exists on disk under the authority root.
      # No `:launch_marker_root` app-env override is set by this suite, so
      # this path can only be produced by consuming the `:authority_root`
      # option — a production failure to forward it would land the marker in
      # the live-configuration default store and fail the assertions below.
      marker_path = LaunchMarker.marker_path(issue_id, root: authority)
      assert File.exists?(marker_path)
      refute File.exists?(LaunchMarker.marker_path(issue_id))

      # 3. The recorded marker verifies schema, issue identity and authority
      assert {:ok, marker} = LaunchMarker.read(issue_id, root: authority)
      assert marker["schema_version"] == 1
      assert marker["issue_id"] == issue_id
      assert marker["identifier"] == "PROP-1"
      assert marker["attempt_id"] == 1
      assert marker["worker_identity"]["authority_root"] == authority
      assert marker["worker_identity"]["harness"] == "opencode"
      assert marker["worker_identity"]["wrapper_pid"] == session.identity["wrapper_pid"]

      # 4. Clean stop collects a positive termination receipt and clears the
      # marker from the authority-rooted store
      confirmation = Adapter.stop_session(session)
      assert confirmation.status == :TERMINATED_CONFIRMED
      assert confirmation.receipt["tree_drained"] == true
      refute File.exists?(marker_path)
    end

    test "adapter launch opts contract pins the exact option names the dispatch path forwards",
         %{workspace_root: wr, state_root: authority} do
      mock_exe = MockOpenCode.ensure_built!()
      workspace = Path.join(wr, "opts-contract")
      File.mkdir_p!(workspace)
      issue_id = "ISSUE-OPTS-#{System.unique_integer([:positive])}"

      # Sentinel values for every launch option the AgentRunner OpenCode
      # branch forwards to the adapter.
      opts = [
        issue_id: issue_id,
        identifier: "OPT-SENTINEL",
        attempt_id: 7,
        provider: "mockprovider",
        model: "mock-model",
        allowed_tools: ["read", "glob"],
        timeout_ms: 60_000,
        authority_root: authority,
        executable: mock_exe
      ]

      assert {:ok, session} = Adapter.start_session(workspace, "--mock-mode=success", opts)

      # `provider:` and `model:` are consumed as the pinned launch identity
      assert session.provider == "mockprovider"
      assert session.model == "mock-model"

      # `allowed_tools:` materializes as the deny-by-default permission map
      # in the isolated per-launch config written for the worker
      config_path = Path.join(session.dirs.config, "opencode.json")
      assert File.exists?(config_path)

      assert {:ok, launch_config} = Jason.decode(File.read!(config_path))
      assert launch_config["permission"]["*"] == "deny"
      assert launch_config["permission"]["read"] == "allow"
      assert launch_config["permission"]["glob"] == "allow"
      assert launch_config["permission"]["edit"] == "deny"
      assert launch_config["tools"]["read"] == true
      assert launch_config["tools"]["glob"] == true
      assert launch_config["tools"]["edit"] == false

      # `issue_id:`/`identifier:`/`attempt_id:`/`authority_root:` land in the
      # durable marker exactly as forwarded (the timeout_ms: effect is pinned
      # by the bounded-timeout test in section 7)
      assert {:ok, marker} = LaunchMarker.read(issue_id, root: authority)
      assert marker["issue_id"] == issue_id
      assert marker["identifier"] == "OPT-SENTINEL"
      assert marker["attempt_id"] == 7
      assert marker["worker_identity"]["authority_root"] == authority
      assert marker["worker_identity"]["attempt_id"] == 7

      assert %{status: :TERMINATED_CONFIRMED} = Adapter.stop_session(session)
    end

    test "pre-launch failure clears recorded marker on never_spawned evidence", %{
      state_root: authority
    } do
      issue_id = "ISSUE-NEVER-SPAWNED-#{System.unique_integer([:positive])}"

      identity = %{
        "issue_id" => issue_id,
        "launch_id" => "launch_never_spawned",
        "workspace" => "C:/dummy/workspace",
        "receipt_path" => Path.join(authority, "receipt_dummy.json"),
        "authority_root" => authority
      }

      assert :ok = LaunchMarker.record(identity, identifier: "NEVER-1", attempt_id: 1, root: authority)

      marker_path = LaunchMarker.marker_path(issue_id, root: authority)
      assert File.exists?(marker_path)

      assert :ok = LaunchMarker.clear(identity, root: authority)
      refute File.exists?(marker_path)
    end
  end

  # ===========================================================================
  # 5. LaunchMarker Blocks Uncertain Reuse and Destructive Cleanup
  # ===========================================================================

  describe "5. LaunchMarker Blocks Uncertain Reuse and Destructive Cleanup" do
    test "unproven active worker launch blocks reuse and cleanup gates", %{state_root: authority} do
      issue_id = "ISSUE-GATE-#{System.unique_integer([:positive])}"

      mock_identity = %{
        "issue_id" => issue_id,
        "launch_id" => "launch_mock_1",
        "workspace" => "C:/dummy/workspace",
        "receipt_path" => Path.join(authority, "receipt_missing.json"),
        "authority_root" => authority
      }

      assert :ok = LaunchMarker.record(mock_identity, identifier: "GATE-1", attempt_id: 1, root: authority)

      assert {:blocked, :worker_termination_unproven} = LaunchMarker.reuse_gate(issue_id, root: authority)
      assert {:blocked, :worker_termination_unproven} = LaunchMarker.cleanup_gate(issue_id, root: authority)
      assert {:error, :unknown} = LaunchMarker.fence_verdict(issue_id, root: authority)
    end

    test "corrupt or unreadable marker fails closed for reuse and cleanup", %{state_root: authority} do
      issue_id = "ISSUE-CORRUPT-#{System.unique_integer([:positive])}"
      marker_path = LaunchMarker.marker_path(issue_id, root: authority)
      File.mkdir_p!(Path.dirname(marker_path))

      File.write!(marker_path, "{schema_version: invalid json")

      assert {:error, :corrupt} = LaunchMarker.read(issue_id, root: authority)
      assert {:blocked, :launch_marker_unreadable} = LaunchMarker.reuse_gate(issue_id, root: authority)
      assert {:blocked, :launch_marker_unreadable} = LaunchMarker.cleanup_gate(issue_id, root: authority)
    end

    test "unconfirmed termination preserves the marker on disk and keeps the gates closed",
         %{workspace_root: wr, state_root: authority} do
      mock_exe = MockOpenCode.ensure_built!()
      workspace = Path.join(wr, "unconfirmed-termination")
      File.mkdir_p!(workspace)
      issue_id = "ISSUE-UNCONFIRMED-#{System.unique_integer([:positive])}"

      opts = [
        issue_id: issue_id,
        attempt_id: 1,
        identifier: "UNCONFIRMED-1",
        authority_root: authority,
        provider: "anthropic",
        model: "claude-3-5-sonnet",
        executable: mock_exe
      ]

      assert {:ok, session} = Adapter.start_session(workspace, "--mock-mode=stalled", opts)

      marker_path = LaunchMarker.marker_path(issue_id, root: authority)
      wait_until(fn -> File.exists?(marker_path) end)

      # Hard-kill the containment wrapper so it cannot write a death
      # receipt: the next stop can then only conclude TERMINATION_UNCONFIRMED.
      wrapper_pid = session.identity["wrapper_pid"]

      assert {_, 0} =
               System.cmd("taskkill", ["/F", "/T", "/PID", to_string(wrapper_pid)], stderr_to_stdout: true)

      confirmation = Adapter.stop_session(session)
      assert confirmation.status == :TERMINATION_UNCONFIRMED

      # The marker is retained as fence evidence and both gates stay closed
      assert File.exists?(marker_path)
      assert {:blocked, :worker_termination_unproven} = LaunchMarker.reuse_gate(issue_id, root: authority)
      assert {:blocked, :worker_termination_unproven} = LaunchMarker.cleanup_gate(issue_id, root: authority)
    end

    @tag :restart_required
    test "restart boundary: a genuinely separate BEAM VM recovers the fence from disk alone",
         %{state_root: authority} do
      issue_id = "ISSUE-RESTART-#{System.unique_integer([:positive])}"

      mock_identity = %{
        "issue_id" => issue_id,
        "launch_id" => "launch_pre_restart",
        "workspace" => "C:/workspace/pre_restart",
        "receipt_path" => Path.join(authority, "receipt_pre_restart.json"),
        "authority_root" => authority
      }

      assert :ok = LaunchMarker.record(mock_identity, identifier: "RESTART-1", attempt_id: 1, root: authority)

      # A fresh `mix run` VM boots a new BEAM instance with no in-memory
      # state and no app-env marker override; the marker file and the gates
      # below are answered purely from the durable disk store. The probe is
      # written to a file because the Windows argv layer truncates multiline
      # `mix run -e` scripts at the first newline.
      script_path = Path.join(authority, "restart_probe.exs")

      File.write!(script_path, """
      issue_id = #{inspect(issue_id)}
      root = #{inspect(authority)}
      {:ok, marker} = SymphonyElixir.LaunchMarker.read(issue_id, root: root)
      IO.puts("RESTART_MARKER_LAUNCH_ID=" <> marker["launch_id"])
      IO.puts("RESTART_REUSE_GATE=" <> inspect(SymphonyElixir.LaunchMarker.reuse_gate(issue_id, root: root)))
      IO.puts("RESTART_CLEANUP_GATE=" <> inspect(SymphonyElixir.LaunchMarker.cleanup_gate(issue_id, root: root)))
      """)

      {output, exit_status} =
        System.cmd("mix", ["run", script_path],
          cd: File.cwd!(),
          env: %{"MIX_ENV" => "test"},
          stderr_to_stdout: true
        )

      assert exit_status == 0,
             "separate-BEAM restart probe failed:\n#{output}"

      assert output =~ "RESTART_MARKER_LAUNCH_ID=launch_pre_restart"
      assert output =~ "RESTART_REUSE_GATE={:blocked, :worker_termination_unproven}"
      assert output =~ "RESTART_CLEANUP_GATE={:blocked, :worker_termination_unproven}"
    end
  end

  # ===========================================================================
  # 6. Mock OpenCode Success & Authoritative Completion Decision
  # ===========================================================================

  describe "6. Mock OpenCode Success & Authoritative Completion Decision" do
    test "mock OpenCode success completes protocol, drains tree, and yields positive termination receipt",
         %{workspace_root: wr, state_root: authority} do
      mock_exe = MockOpenCode.ensure_built!()
      workspace = Path.join(wr, "completion")
      File.mkdir_p!(workspace)
      issue_id = "ISSUE-COMPLETION-#{System.unique_integer([:positive])}"

      opts = [
        provider: "anthropic",
        model: "claude-3-5-sonnet",
        executable: mock_exe,
        issue_id: issue_id,
        attempt_id: 1,
        identifier: "COMPLETION-1",
        authority_root: authority
      ]

      assert {:ok, result} = OpenCode.run(workspace, "--mock-mode=success", opts)

      # Protocol completion state
      assert result.completion_state == :completed
      assert result.exit_code == 0
      assert result.failure_evidence == []

      # Termination confirmation and receipt
      assert result.termination.status == :TERMINATED_CONFIRMED
      assert result.termination.receipt["tree_drained"] == true
      assert result.termination.receipt["terminal_reason"] == "NATURAL_EXIT"

      # Usage accounting
      assert result.usage.input_tokens > 0
      assert result.usage.output_tokens > 0
      assert result.usage.total_tokens > 0

      # Marker cleared after positive completion, from the authority store
      refute File.exists?(LaunchMarker.marker_path(issue_id, root: authority))
    end

    test "WorkerEvent terminal step_finish is observational and does not grant completion authority" do
      terminal_json =
        ~s({"type":"step_finish","timestamp":1700000000200,"sessionID":"ses_term","part":{"type":"step-finish","id":"step_f1","sessionID":"ses_term","messageID":"msg_01","reason":"stop","cost":0.005,"tokens":{"input":100,"output":200,"reasoning":25,"cache":{"read":50,"write":10}}}})

      event = WorkerEvent.from_opencode(terminal_json)

      assert event.event == :step_finish
      assert event.terminal? == true
      assert event.harness == :opencode
      assert event.session_id == "ses_term"

      # Observational terminal events never confer completion authority
      refute Map.get(event.metadata, :completion_authority, false)
    end

    @tag :integration_gate
    test "integration gate: AgentRunner executes OpenCode to an authoritative completion decision",
         context do
      %{issue: issue, state_root: state_root} = context
      prepare_workspace!(context, issue, ["sleep=1200"])
      enable_pilot!(issue)

      # The production dispatch options, with a sentinel attempt number that
      # must survive into the durable launch identity.
      opts = dispatch_opts(context, pilot(issue.identifier), attempt: 2)
      recipient = self()

      runner =
        Task.async(fn ->
          AgentRunner.run(issue, recipient, opts)
        end)

      # While the worker is live, the durable marker carries the exact
      # identity the dispatch forwarded (option names pinned end-to-end).
      marker_path = LaunchMarker.marker_path(issue.id, root: state_root)
      wait_until(fn -> File.exists?(marker_path) end)

      assert {:ok, marker} = LaunchMarker.read(issue.id, root: state_root)
      assert marker["issue_id"] == issue.id
      assert marker["identifier"] == issue.identifier
      assert marker["attempt_id"] == 2
      assert marker["worker_identity"]["authority_root"] == state_root
      assert marker["worker_identity"]["harness"] == "opencode"

      # A live OpenCode launch fences the issue for any harness
      assert {:blocked, :worker_termination_unproven} = LaunchMarker.reuse_gate(issue.id, root: state_root)

      assert :ok = Task.await(runner, 30_000)

      messages = drain_worker_mailbox()

      # Streaming events stayed harness-marked and never claimed completion:
      # recipient-side authority for success is the run result's containment
      # evidence, never the event stream.
      updates = streamed_updates(messages)
      assert updates != []

      for update <- updates do
        assert update.harness == :opencode
        assert update.successful_completion? == false
      end

      final = List.last(updates)
      assert final.terminal? == true
      assert final.usage_accounting == :cumulative
      assert get_in(final, [:tokenUsage, :total, :totalTokens]) == 300

      # The authoritative completion decision required containment evidence:
      # the adapter's TERMINATED_CONFIRMED confirmation reached the recipient
      # before the task exited, and the fence re-admits the issue.
      {:termination, termination_issue_id, %{worker_termination: termination}} =
        termination_evidence(messages)

      assert termination_issue_id == issue.id
      assert %{status: :TERMINATED_CONFIRMED} = termination

      wait_until(fn -> not File.exists?(marker_path) end)
      assert LaunchMarker.reuse_gate(issue.id, root: state_root) == :allowed
    end
  end

  # ===========================================================================
  # 7. Nonzero Exit, Timeout, Malformed JSONL & Interrupted Workers
  # ===========================================================================

  describe "7. Nonzero Exit, Timeout, Malformed JSONL & Interrupted Workers Fail Closed" do
    test "nonzero exit code fails closed and reports process exit evidence",
         %{workspace_root: wr, state_root: authority} do
      mock_exe = MockOpenCode.ensure_built!()
      workspace = Path.join(wr, "nonzero-exit")
      File.mkdir_p!(workspace)
      issue_id = "ISSUE-FAIL-#{System.unique_integer([:positive])}"

      opts = [
        provider: "anthropic",
        model: "claude-3-5-sonnet",
        executable: mock_exe,
        issue_id: issue_id,
        attempt_id: 1,
        identifier: "FAIL-1",
        authority_root: authority
      ]

      assert {:error, {reason, result}} = OpenCode.run(workspace, "--mock-mode=error", opts)

      assert result.exit_code == 1
      assert result.completion_state == :failed
      assert result.failure_evidence != []

      # Pinned classification through the OpenCode taxonomy (not a Codex
      # reason mapping): the mock's provider error is model_unavailable
      assert reason != nil
      assert result.failure_info.failure_class == :model_unavailable
    end

    test "stalled worker reaches the bounded timeout pinned by timeout_ms, kills the tree, and confirms termination",
         %{workspace_root: wr, state_root: authority} do
      mock_exe = MockOpenCode.ensure_built!()
      workspace = Path.join(wr, "timeout")
      File.mkdir_p!(workspace)
      issue_id = "ISSUE-TIMEOUT-#{System.unique_integer([:positive])}"

      opts = [
        provider: "anthropic",
        model: "claude-3-5-sonnet",
        executable: mock_exe,
        timeout_ms: 300,
        issue_id: issue_id,
        attempt_id: 1,
        identifier: "TIMEOUT-1",
        authority_root: authority
      ]

      assert {:error, {:timeout, result}} = OpenCode.run(workspace, "--mock-mode=stalled", opts)

      # Pinned classification: a timeout is runtime_unavailable in the
      # OpenCode failure taxonomy, with the sentinel exit status 253
      assert result.failure_info.failure_class == :runtime_unavailable
      assert result.exit_code == 253
      assert result.termination.status == :TERMINATED_CONFIRMED
      assert result.termination.receipt["tree_drained"] == true
      assert result.completion_state == :failed
    end

    test "malformed JSONL prevents false success and captures pinned failure evidence",
         %{workspace_root: wr, state_root: authority} do
      mock_exe = MockOpenCode.ensure_built!()
      workspace = Path.join(wr, "malformed")
      File.mkdir_p!(workspace)
      issue_id = "ISSUE-MALFORMED-#{System.unique_integer([:positive])}"

      opts = [
        provider: "anthropic",
        model: "claude-3-5-sonnet",
        executable: mock_exe,
        issue_id: issue_id,
        attempt_id: 1,
        identifier: "MALFORMED-1",
        authority_root: authority
      ]

      assert {:error, {_reason, result}} = OpenCode.run(workspace, "--mock-mode=malformed", opts)

      assert result.completion_state == :failed

      # Pinned evidence shape: every malformed stream line lands in the
      # failure evidence as a redacted 3-tuple, classified persistent
      assert malformed = Enum.find(result.failure_evidence, &match?({:malformed_json_line, _, _}, &1))
      assert {:malformed_json_line, line, _detail} = malformed
      assert is_binary(line) and line != ""
      assert result.failure_info.failure_class == :persistent_worker_failure

      # The parser normalizes an undecodable line to an observational raw
      # event that never claims terminal authority
      broken_line = "{not-json-line"
      event = WorkerEvent.from_opencode(broken_line)
      assert event.event == :raw
      assert event.event_type == :malformed_json
      refute event.terminal?
    end

    test "interrupted worker with abrupt exit 130 and missing terminal event fails closed",
         %{workspace_root: wr, state_root: authority} do
      mock_exe = MockOpenCode.ensure_built!()
      workspace = Path.join(wr, "interrupted")
      File.mkdir_p!(workspace)
      issue_id = "ISSUE-INTERRUPTED-#{System.unique_integer([:positive])}"

      opts = [
        provider: "anthropic",
        model: "claude-3-5-sonnet",
        executable: mock_exe,
        issue_id: issue_id,
        attempt_id: 1,
        identifier: "INTERRUPTED-1",
        authority_root: authority
      ]

      assert {:error, {{:process_exit, 130}, result}} =
               OpenCode.run(workspace, "--mock-mode=interrupted", opts)

      # Pinned classification: an abrupt worker process exit is a transient
      # worker failure inside the retry envelope, never a success
      assert result.exit_code == 130
      assert result.completion_state == :failed
      assert result.failure_info.failure_class == :transient_worker_failure
      assert result.termination.status == :TERMINATED_CONFIRMED
    end
  end

  # ===========================================================================
  # 8. Failed OpenCode Execution Never Silently Launches Codex
  # ===========================================================================

  describe "8. Failed OpenCode Execution Never Silently Launches Codex" do
    test "pure policy: OpenCode failure produces no automatic provider or Codex fallback" do
      config = %OpenCodeSchema{
        enabled: true,
        provider: "anthropic",
        model: "claude-3-5-sonnet",
        allowed_tools: ["read"],
        allowed_issues: ["ISSUE-NOFALLBACK"]
      }

      issue = %Issue{id: "issue_nofallback", identifier: "ISSUE-NOFALLBACK"}

      assert {:opencode, :opencode_selected} = HarnessSelection.select(issue, config)

      # The selector's contract has no fallback arm: every non-selection
      # outcome is {:codex, reason}, and the launch boundary (section 12)
      # rejects anything but the pinned snapshot.
      assert {:codex, :opencode_disabled} = HarnessSelection.select(issue, nil)
    end

    @tag :integration_gate
    test "integration gate: the orchestrator retry loop retains the OpenCode harness and never substitutes Codex",
         context do
      %{issue: issue, state_root: state_root} = context
      prepare_workspace!(context, issue, ["mode=error"])
      enable_pilot!(issue)

      # Attempt 1 fails inside the worker (mock provider error). The failure
      # classifies through OpenCode.Failure — a taxonomy the Codex AppServer
      # reason mapper cannot produce — and publishes termination evidence.
      error =
        assert_raise AgentRunner.FailureError, fn ->
          AgentRunner.run(issue, self(), dispatch_opts(context, pilot(issue.identifier)))
        end

      assert error.failure_class == :model_unavailable
      assert is_map(error.failure_info)
      assert error.failure_info.failure_class == :model_unavailable

      messages = drain_worker_mailbox()
      {:termination, termination_issue_id, %{worker_termination: termination}} = termination_evidence(messages)
      assert termination_issue_id == issue.id
      assert %{status: :TERMINATED_CONFIRMED} = termination

      # The failed attempt drained its tree and re-admitted the fence
      wait_until(fn -> not File.exists?(LaunchMarker.marker_path(issue.id, root: state_root)) end)
      assert LaunchMarker.reuse_gate(issue.id, root: state_root) == :allowed

      # The retry envelope's latched :fallback route says Codex...
      state = %Orchestrator.State{}
      state = put_in(state.retry_history[issue.id], %{route: :fallback, primary_failure_count: 2})
      assert Orchestrator.next_dispatch_route_for_test(state, issue.id) == :fallback

      # ...but the harness decision is re-evaluated per dispatch attempt from
      # configuration and stays OpenCode: no silent Codex substitution.
      assert {:opencode, _snapshot} = Orchestrator.dispatch_harness_for_test(issue)

      # The retried dispatch executes the mock OpenCode worker again and
      # streams only OpenCode-marked events. The control file is rewritten
      # with the recovered mode so the retry succeeds.
      prepare_workspace!(context, issue, ["mode=success"])
      opts = dispatch_opts(context, pilot(issue.identifier), attempt: 2)

      assert :ok = AgentRunner.run(issue, self(), opts)

      retry_updates = streamed_updates(drain_worker_mailbox())
      assert retry_updates != []

      for update <- retry_updates do
        assert update.harness == :opencode
      end
    end
  end

  # ===========================================================================
  # 9. WorkerEvent Ordering, Token Accounting, and Session Identity
  # ===========================================================================

  describe "9. WorkerEvent Ordering, Token Accounting, and Session Identity" do
    test "WorkerEvent normalizes multi-step stream and preserves cumulative token accounting" do
      jsonl = OpenCodeWorkerFixture.multi_step_jsonl(session_id: "ses_multi_test")
      lines = String.split(jsonl, ["\r\n", "\n"], trim: true)

      events = Enum.map(lines, &WorkerEvent.from_opencode/1)
      assert length(events) == 5

      e1 = Enum.at(events, 0)
      assert e1.event == :step_start
      assert e1.session_id == "ses_multi_test"
      refute e1.terminal?

      e2 = Enum.at(events, 1)
      assert e2.event == :step_finish
      refute e2.terminal?
      assert e2.usage.input_tokens == 40
      assert e2.usage.output_tokens == 60
      assert e2.usage.reasoning_tokens == 10
      assert e2.usage.cache_read_tokens == 5
      assert e2.usage.cache_write_tokens == 5
      assert e2.usage.cost == 0.002

      e5 = Enum.at(events, 4)
      assert e5.event == :step_finish
      assert e5.terminal?
      assert e5.usage.input_tokens == 60
      assert e5.usage.output_tokens == 90
      assert e5.usage.cost == 0.003

      total_in = e2.usage.input_tokens + e5.usage.input_tokens
      total_out = e2.usage.output_tokens + e5.usage.output_tokens
      total_cost = e2.usage.cost + e5.usage.cost

      assert total_in == 100
      assert total_out == 150
      assert total_cost == 0.005
    end

    test "WorkerEvent timestamp classification preserves chronological ordering" do
      t1 = ~U[2026-10-10 10:00:00Z]
      t2 = ~U[2026-10-10 10:00:05Z]

      assert {:fresh, ^t2} = WorkerEvent.classify_activity_timestamp(t1, t2)
      assert {:fresh, ^t1} = WorkerEvent.classify_activity_timestamp(t1, t1)
      assert :stale = WorkerEvent.classify_activity_timestamp(t2, t1)
      assert :invalid = WorkerEvent.classify_activity_timestamp(t1, nil)
    end

    test "WorkerEvent callback enforces session identity lock and rejects conflicting sessions" do
      issue_id = "ISSUE-SES-LOCK-1"
      recipient = self()

      cb = WorkerEvent.callback(recipient, issue_id, session_id: "ses_initial_123")

      # 1. Matching session event is accepted and delivered to recipient
      event_valid =
        WorkerEvent.from_opencode(~s({"type":"step_start","timestamp":1700000000000,"sessionID":"ses_initial_123","part":{"type":"step-start","id":"s1","messageID":"m1"}}))

      cb.(event_valid)
      assert_receive {:codex_worker_update, ^issue_id, update1}
      assert update1.session_id == "ses_initial_123"

      # 2. Conflicting session event is rejected by the accumulator and never delivered
      event_conflict =
        WorkerEvent.from_opencode(~s({"type":"step_start","timestamp":1700000000005,"sessionID":"ses_different_999","part":{"type":"step-start","id":"s2","messageID":"m2"}}))

      cb.(event_conflict)
      refute_receive {:codex_worker_update, ^issue_id, _update2}, 100

      # 3. The lock survives the conflict: a later matching event is still
      # delivered, with the accumulator session unchanged
      event_valid_late =
        WorkerEvent.from_opencode(~s({"type":"step_finish","timestamp":1700000000010,"sessionID":"ses_initial_123","part":{"type":"step-finish","id":"s3","messageID":"m3","reason":"stop"}}))

      cb.(event_valid_late)
      assert_receive {:codex_worker_update, ^issue_id, update3}
      assert update3.session_id == "ses_initial_123"

      refute_receive {:codex_worker_update, ^issue_id, _update4}, 100
    end
  end

  # ===========================================================================
  # 10. Credential Redaction in Observable Failure Evidence
  # ===========================================================================

  describe "10. Credential Redaction in Observable Failure Evidence" do
    test "observable failure evidence in malformed-secret mock is completely redacted",
         %{workspace_root: wr, state_root: authority} do
      mock_exe = MockOpenCode.ensure_built!()
      markers = OpenCodeWorkerFixture.raw_secret_markers()
      workspace = Path.join(wr, "redact-malformed")
      File.mkdir_p!(workspace)
      issue_id = "ISSUE-REDACT-MALFORMED-#{System.unique_integer([:positive])}"

      opts = [
        provider: "anthropic",
        model: "claude-3-5-sonnet",
        executable: mock_exe,
        issue_id: issue_id,
        attempt_id: 1,
        identifier: "REDACT-MALFORMED-1",
        authority_root: authority
      ]

      assert {:error, {_reason, result}} = OpenCode.run(workspace, "--mock-mode=malformed-secret", opts)

      assert is_binary(result.stderr)
      refute result.stderr =~ markers.anthropic
      refute result.stderr =~ markers.linear

      failure_str = inspect(result.failure_evidence)
      assert failure_str =~ "[redacted]"
      refute failure_str =~ markers.anthropic
      refute failure_str =~ markers.linear
    end

    test "observable output and stderr in secret mock mode are completely redacted",
         %{workspace_root: wr, state_root: authority} do
      mock_exe = MockOpenCode.ensure_built!()
      markers = OpenCodeWorkerFixture.raw_secret_markers()
      workspace = Path.join(wr, "redact-secret")
      File.mkdir_p!(workspace)
      issue_id = "ISSUE-REDACT-SECRET-#{System.unique_integer([:positive])}"

      opts = [
        provider: "anthropic",
        model: "claude-3-5-sonnet",
        executable: mock_exe,
        issue_id: issue_id,
        attempt_id: 1,
        identifier: "REDACT-SECRET-1",
        authority_root: authority
      ]

      assert {:ok, result} = OpenCode.run(workspace, "--mock-mode=secret", opts)

      payload = inspect(result)
      refute payload =~ markers.anthropic
      refute payload =~ markers.linear

      assert result.stderr =~ "[redacted]"
      refute result.stderr =~ markers.anthropic
      refute result.stderr =~ markers.linear
    end

    test "OpenCode.Redactor sanitizes authorization tokens, API keys, and credentials across data structures" do
      raw_text = """
      Authorization: Bearer sk-ant-api03-secretvalue123456789
      LINEAR_API_KEY=lin_api_abcdefghijklmnopqrstuvwxyz
      Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.e30.t-IDcSemACt8x4iTMCda8Yhe3iZaWbvV5XKSTbuAn0M
      ghp_123456789012345678901234567890123456
      xoxb-1234567890-123456789012-abcdef1234567890abcdef12
      AKIAIOSFODNN7EXAMPLE
      api_key: "sk-mysecretkey12345678"
      """

      redacted = Redactor.redact(raw_text)

      assert is_binary(redacted)
      assert redacted =~ "[redacted]"
      refute redacted =~ "sk-ant-api03"
      refute redacted =~ "lin_api_"
      refute redacted =~ "ghp_"
      refute redacted =~ "xoxb-"
      refute redacted =~ "AKIA"
      refute redacted =~ "sk-mysecretkey"

      nested = %{
        error: "failed with key",
        detail: [
          %{secret: "sk-ant-api03-nestedsecret123456"},
          "bearer sk-1234567890abcdef"
        ]
      }

      redacted_map = Redactor.redact(nested)
      refute inspect(redacted_map) =~ "sk-ant-api03"
      refute inspect(redacted_map) =~ "sk-1234567890abcdef"
      assert inspect(redacted_map) =~ "[redacted]"
    end
  end

  # ===========================================================================
  # 11. Process Containment & Zero Orphaned Processes
  # ===========================================================================

  describe "11. Process Containment & Zero Orphaned Processes" do
    test "Job Object containment kills the worker and its spawned grandchild with zero orphan processes, proven by OS process evidence",
         %{workspace_root: wr, state_root: authority} do
      workspace = Path.join(wr, "orphans")
      File.mkdir_p!(workspace)
      issue_id = "ISSUE-ORPHAN-#{System.unique_integer([:positive])}"
      ScratchProcess.ensure_built!()
      grandchild_exe = ScratchProcess.scratch_exe()

      grandchild_pid_file = Path.join(workspace, "opencode-grandchild.pid")

      session =
        OpenCodeWorkerFixture.spawn_contained_worker(
          workspace: workspace,
          issue_id: issue_id,
          attempt_id: 1,
          authority_root: authority,
          mock_args: [
            "--mock-mode=stalled",
            "--mock-grandchild-exe=" <> grandchild_exe,
            "--mock-grandchild-args=--id orphan_grandchild --scratch " <>
              workspace <>
              " --heartbeat-ms 200"
          ]
        )

      # The grandchild really started and is really alive as an OS process
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

      # Contained stop kills the whole tree with a positive receipt
      confirmation = OpenCodeWorkerFixture.stop_and_confirm_worker(session, 3000)
      assert confirmation.status == :TERMINATED_CONFIRMED
      assert confirmation.receipt["tree_drained"] == true

      # Real process/receipt evidence: the wrapper AND the grandchild are
      # positively gone from the OS process table
      assert OpenCodeWorkerFixture.assert_no_orphaned_processes([
               session.wrapper_pid,
               grandchild_pid
             ]) == :ok
    end
  end

  # ===========================================================================
  # 12. Fail-Closed Configuration Contract (M1-C hardening)
  # ===========================================================================

  # What the committed baseline already enforces is asserted below. The
  # explicit-null schema rejection comes from the pending M1-C remediation
  # (4f1dc51: "Fail closed on explicit null OpenCode enabled and timeout
  # values") and is recorded as explicitly skipped tests with concrete
  # assertions until that revision is reviewed and integrated.
  describe "12. Fail-Closed Configuration Contract" do
    test "selection fails closed on a null or disabled enabled flag" do
      issue = %Issue{id: "issue_null_enabled", identifier: "MIC-NULL-ENABLED"}

      null_enabled_struct = %OpenCodeSchema{
        enabled: nil,
        provider: "mockprovider",
        model: "mock-model",
        allowed_tools: ["read"],
        allowed_issues: ["MIC-NULL-ENABLED"]
      }

      # On the committed baseline a null enabled flag never selects OpenCode
      assert {:codex, :opencode_disabled} = HarnessSelection.select(issue, null_enabled_struct)
      assert {:codex, :opencode_disabled} = HarnessSelection.select(issue, %{"enabled" => nil})
    end

    test "launch boundary rejects an unbounded pilot snapshot fail-closed", context do
      %{issue: issue, state_root: state_root} = context
      prepare_workspace!(context, issue)
      enable_pilot!(issue)

      # A hand-built snapshot with a null timeout would authorize an
      # unbounded execution; the AgentRunner launch boundary refuses it.
      unbounded = pilot(issue.identifier, timeout_ms: nil)

      error =
        assert_raise AgentRunner.FailureError, fn ->
          AgentRunner.run(issue, self(), dispatch_opts(context, unbounded))
        end

      assert {:opencode_launch_settings_invalid, ^unbounded} = error.reason

      # The refused launch is conclusively never-started and strands no marker
      messages = drain_worker_mailbox()
      {:termination, _issue_id, %{termination_expectation: :NEVER_STARTED}} = termination_evidence(messages)
      refute File.exists?(LaunchMarker.marker_path(issue.id, root: state_root))
    end

    # Pending 4f1dc51 contract: OpenCode.changeset/2 rejects an explicit null
    # `enabled` ("must not be null: explicit true or false required") and an
    # explicit null `timeout_ms` ("must not be null") for map and struct
    # inputs alike. On this baseline the changeset still accepts the null, so
    # the tests below are explicitly skipped until that revision is reviewed
    # and integrated — remove the skip tags then. (4f1dc51 surfaces the same
    # rejection through OpenCode.validate/1, which does not exist here.)
    @null_base %{
      "provider" => "mockprovider",
      "model" => "mock-model",
      "timeout_ms" => 600_000,
      "allowed_tools" => ["read"],
      "allowed_issues" => ["MIC-NULL-1"]
    }
    @null_base_struct %OpenCodeSchema{
      provider: "mockprovider",
      model: "mock-model",
      timeout_ms: 600_000,
      allowed_tools: ["read"],
      allowed_issues: ["MIC-NULL-1"]
    }

    @tag skip: "pending 4f1dc51: explicit-null schema rejection is not on this baseline"
    test "schema rejects an explicit null enabled for map and struct input (pending 4f1dc51)" do
      for section <- [Map.put(@null_base, "enabled", nil), %{@null_base_struct | enabled: nil}] do
        changeset = OpenCodeSchema.changeset(section, %{})
        refute changeset.valid?
        assert null_errors(changeset)[:enabled] == ["must not be null: explicit true or false required"]
      end
    end

    @tag skip: "pending 4f1dc51: explicit-null schema rejection is not on this baseline"
    test "schema rejects an explicit null timeout_ms for map and struct input (pending 4f1dc51)" do
      for section <- [
            Map.merge(@null_base, %{"enabled" => true, "timeout_ms" => nil}),
            %{@null_base_struct | enabled: true, timeout_ms: nil}
          ] do
        changeset = OpenCodeSchema.changeset(section, %{})
        refute changeset.valid?
        assert null_errors(changeset)[:timeout_ms] == ["must not be null"]
      end
    end

    @tag skip: "pending 4f1dc51: explicit-null schema rejection is not on this baseline"
    test "a null-only section reports both fields instead of falling back to defaults (pending 4f1dc51)" do
      changeset = OpenCodeSchema.changeset(%OpenCodeSchema{}, %{"enabled" => nil, "timeout_ms" => nil})
      refute changeset.valid?

      assert null_errors(changeset) == %{
               enabled: ["must not be null: explicit true or false required"],
               timeout_ms: ["must not be null"]
             }
    end

    defp null_errors(changeset) do
      Enum.reduce(changeset.errors, %{}, fn {field, {message, _}}, acc ->
        Map.update(acc, field, [message], &[message | &1])
      end)
    end
  end
end
