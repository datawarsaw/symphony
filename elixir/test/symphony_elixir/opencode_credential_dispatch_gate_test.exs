defmodule SymphonyElixir.OpenCodeCredentialDispatchGateTest do
  @moduledoc """
  PILOT-CRED-PREFLIGHT: the orchestrator's pre-dispatch credential
  availability gate for armed OpenCode dispatches.

  The adapter's credential presence preflight already refuses a launch before
  any directory, config, marker, or process exists — but by then the
  orchestrator has claimed the issue, spawned the worker task, and consumed
  the single attempt. This suite covers the gate one step earlier: an
  OpenCode dispatch whose provider credential cannot be resolved is deferred
  before the attempt is consumed at all.

  Invariants under test:

  - a missing (or empty, i.e. unusable) provider credential defers the
    dispatch: no spawn, no claim, no harness pin commit, no park, no blocked
    entry, no retry timer — the issue stays a poll candidate;
  - the deferral never disturbs a pre-existing OpenCode harness pin;
  - a valid synthetic credential dispatches exactly as before the gate;
  - every other preflight refusal (unmapped provider) is deliberately NOT
    deferred: today's downstream behavior is preserved, so the gate stays
    narrow;
  - no test authenticates, contacts a provider, or runs a real OpenCode
    binary: launches target the locally compiled mock through the
    `:opencode_executable` app-env seam and every credential in play is a
    synthetic placeholder. Assertions depend only on presence-driven
    decisions and variable NAMES — never credential values.
  """

  use SymphonyElixir.TestSupport

  Code.require_file("../support/mock_opencode.exs", __DIR__)

  alias SymphonyElixir.LaunchMarker
  alias SymphonyElixir.OpenCode
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.TestSupport.MockOpenCode
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Workspace

  @synthetic_credential "sk-ant-synthetic-dispatch-gate-placeholder"

  setup do
    fixture = dispatch_fixture!()

    saved_credential = System.get_env("ANTHROPIC_API_KEY")

    on_exit(fn ->
      restore_env("ANTHROPIC_API_KEY", saved_credential)
      Application.delete_env(:symphony_elixir, :launch_marker_root)
      Application.delete_env(:symphony_elixir, :worker_termination_receipt_root)
      remove_temp_fixture_root!(fixture.test_root)
    end)

    {:ok, fixture: fixture, issue: active_issue("issue-gate-1", "MIC-GATE-1")}
  end

  # -- the gate defers, and deferral consumes nothing --------------------------

  test "a missing provider credential defers dispatch without consuming the single attempt", %{
    fixture: fixture,
    issue: issue
  } do
    write_pilot_workflow!(fixture, issue)

    {:ok, sup} = start_test_task_supervisor("missing-credential")

    next =
      with_credential_env(%{"ANTHROPIC_API_KEY" => nil}, fn ->
        Orchestrator.dispatch_issue_for_test(runtime_state(sup), issue)
      end)

    # Nothing was consumed: no running worker, no claim, no park, no blocked
    # entry, no retry timer, and no harness pin was committed for the
    # deferred dispatch.
    refute Map.has_key?(next.running, issue.id)
    refute MapSet.member?(next.claimed, issue.id)
    refute Map.has_key?(next.parked, issue.id)
    refute Map.has_key?(next.blocked, issue.id)
    assert next.retry_attempts == %{}
    refute Map.has_key?(next.harness_pins, issue.id)

    # No task was ever spawned and no worker evidence of any kind reached the
    # recipient.
    assert Task.Supervisor.children(sup) == []
    assert drain_worker_mailbox() == []

    # The issue is still an ordinary queue candidate: the next poll cycle
    # re-runs the gate and dispatches normally once the credential exists.
    assert Orchestrator.should_dispatch_issue_for_test(issue, next)

    # No launch artifact exists: no workspace, no stranded marker.
    refute File.exists?(Path.join(fixture.workspace_root, Workspace.workspace_key(issue)))
    refute File.exists?(LaunchMarker.marker_path(issue.id))
  end

  test "an empty credential value is an unusable source and defers dispatch the same way", %{
    fixture: fixture,
    issue: issue
  } do
    write_pilot_workflow!(fixture, issue)

    {:ok, sup} = start_test_task_supervisor("empty-credential")

    next =
      with_credential_env(%{"ANTHROPIC_API_KEY" => ""}, fn ->
        Orchestrator.dispatch_issue_for_test(runtime_state(sup), issue)
      end)

    refute Map.has_key?(next.running, issue.id)
    refute MapSet.member?(next.claimed, issue.id)
    refute Map.has_key?(next.parked, issue.id)
    assert next.retry_attempts == %{}
    assert Task.Supervisor.children(sup) == []
    assert Orchestrator.should_dispatch_issue_for_test(issue, next)
  end

  test "the deferral leaves a pre-existing OpenCode harness pin untouched", %{
    fixture: fixture,
    issue: issue
  } do
    write_pilot_workflow!(fixture, issue)

    {:ok, sup} = start_test_task_supervisor("pinned-deferral")

    pin = %{harness: :opencode, authority: :pinned, evidence: "dispatch:opencode_selected"}
    state = %{runtime_state(sup) | harness_pins: %{issue.id => pin}}

    next =
      with_credential_env(%{"ANTHROPIC_API_KEY" => nil}, fn ->
        Orchestrator.dispatch_issue_for_test(state, issue)
      end)

    # Deferred, and the durable harness authority survives unchanged for the
    # dispatch that will happen once the credential is supplied.
    refute Map.has_key?(next.running, issue.id)
    assert next.harness_pins[issue.id] == pin
    assert Task.Supervisor.children(sup) == []
    assert Orchestrator.should_dispatch_issue_for_test(issue, next)
  end

  # -- readiness: the gate passes and dispatch is unchanged --------------------

  test "a valid synthetic credential dispatches exactly as before the gate", %{
    fixture: fixture,
    issue: issue
  } do
    write_pilot_workflow!(fixture, issue)
    Application.put_env(:symphony_elixir, :opencode_executable, MockOpenCode.ensure_built!())
    on_exit(fn -> Application.delete_env(:symphony_elixir, :opencode_executable) end)

    {:ok, sup} = start_test_task_supervisor("valid-credential")

    next =
      with_credential_env(%{"ANTHROPIC_API_KEY" => @synthetic_credential}, fn ->
        Orchestrator.dispatch_issue_for_test(runtime_state(sup), issue)
      end)

    # The authorized local dispatch is unchanged: spawn, claim, and the
    # harness pin commit all happened.
    running = Map.get(next.running, issue.id) || flunk("issue was not dispatched")
    assert running.harness == :opencode
    assert running.worker_host == nil
    assert MapSet.member?(next.claimed, issue.id)
    assert next.harness_pins[issue.id][:harness] == :opencode
    refute Map.has_key?(next.parked, issue.id)

    # The contained mock worker runs to completion and the task drains; the
    # launch pipeline really created the workspace.
    wait_until(fn -> Task.Supervisor.children(sup) == [] end, 30_000)
    assert File.exists?(Path.join(fixture.workspace_root, Workspace.workspace_key(issue)))

    drain_worker_mailbox()

    drain_worker_mailbox()
  end

  # -- narrowness: non-availability refusals are not deferred ------------------

  test "an unmapped provider is not deferred by the availability gate", %{
    fixture: fixture,
    issue: issue
  } do
    # "opencode" (the separately billed Zen provider) is deliberately unmapped
    # in the credential allowlist. That is a configuration refusal, not a
    # missing credential: the gate must not defer, and today's downstream
    # behavior (the adapter refusing the launch inside the attempt) applies.
    write_pilot_workflow!(fixture, issue, opencode_provider: "opencode")

    {:ok, sup} = start_test_task_supervisor("unmapped-provider")

    next =
      with_credential_env(%{"ANTHROPIC_API_KEY" => @synthetic_credential}, fn ->
        Orchestrator.dispatch_issue_for_test(runtime_state(sup), issue)
      end)

    # The dispatch reached the spawn: the single-attempt semantics downstream
    # are exactly what they were before the gate existed.
    assert Map.get(next.running, issue.id), "expected the dispatch to reach the spawn"
    assert MapSet.member?(next.claimed, issue.id)

    wait_until(fn -> Task.Supervisor.children(sup) == [] end, 30_000)
    drain_worker_mailbox()
  end

  # -- the underlying availability check, through the new public surface -------

  test "preflight_provider_credentials resolves presence from the ambient environment" do
    with_credential_env(%{"ANTHROPIC_API_KEY" => @synthetic_credential}, fn ->
      assert :ok = OpenCode.preflight_provider_credentials("anthropic")
    end)

    # Missing ambient credential: refused with provider and variable names
    # only — never a credential value.
    with_credential_env(%{"ANTHROPIC_API_KEY" => nil}, fn ->
      assert {:error, {:missing_provider_credential, "anthropic"}} =
               OpenCode.preflight_provider_credentials("anthropic")
    end)
  end

  # ===========================================================================
  # Fixtures and helpers
  # ===========================================================================

  # Applies key => value (nil deletes) and restores the prior BEAM
  # environment afterwards, so gate decisions are deterministic no matter
  # which ambient credentials the host machine carries.
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

  defp test_issue(id, identifier) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "OpenCode credential gate " <> identifier,
      description: "PILOT-CRED-PREFLIGHT dispatch gate",
      state: "Todo",
      url: "https://example.org/issues/" <> identifier,
      dispatchable: true
    }
  end

  defp active_issue(id, identifier) do
    %{test_issue(id, identifier) | state: "In Progress", labels: ["repo:symphony-runtime"]}
  end

  defp write_pilot_workflow!(fixture, issue, overrides \\ []) do
    base =
      [
        tracker_kind: "memory",
        workspace_root: fixture.workspace_root,
        routing: routing_config(fixture),
        opencode_enabled: true,
        opencode_provider: "anthropic",
        opencode_model: "mock-model",
        opencode_allowed_tools: ["read", "glob"],
        opencode_allowed_issues: [issue.identifier]
      ]

    write_workflow_file!(Workflow.workflow_file_path(), Keyword.merge(base, overrides))
  end

  # A dispatch fixture mirroring the host-eligibility pattern: a real
  # source/remote git pair so workspace classification resolves, plus pinned
  # durable-state roots so markers and receipts stay inside the fixture tree.
  defp dispatch_fixture! do
    test_root = create_temp_fixture_root!("symphony-opencode-credential-gate")
    on_exit(fn -> remove_temp_fixture_root!(test_root) end)
    fixture = setup_source_fixture!(test_root)

    Application.put_env(:symphony_elixir, :launch_marker_root, Path.join(test_root, "launches"))
    Application.put_env(:symphony_elixir, :worker_termination_receipt_root, Path.join(test_root, "receipts"))

    defaults = [
      tracker_kind: "memory",
      workspace_root: fixture.workspace_root,
      routing: routing_config(fixture)
    ]

    workflow_file = Workflow.workflow_file_path()
    File.mkdir_p!(Path.dirname(workflow_file))
    write_workflow_file!(workflow_file, defaults)

    File.mkdir_p!(fixture.workspace_root)
    Map.put(fixture, :test_root, test_root)
  end

  defp setup_source_fixture!(test_root) do
    File.mkdir_p!(test_root)

    remote_repo = Path.join(test_root, "remote.git") |> String.replace("\\", "/")
    source_repo = Path.join(test_root, "source") |> String.replace("\\", "/")
    workspace_root = Path.join(test_root, "workspaces") |> String.replace("\\", "/")

    git!(["init", "--bare", remote_repo])
    git!(["init", "-b", "main", source_repo])
    git!(["-C", source_repo, "config", "user.name", "Test User"])
    git!(["-C", source_repo, "config", "user.email", "test@example.com"])
    File.write!(Path.join(source_repo, "README.md"), "initial content\n")
    git!(["-C", source_repo, "add", "README.md"])
    git!(["-C", source_repo, "commit", "-m", "initial commit"])
    git!(["-C", source_repo, "remote", "add", "origin", remote_repo])
    git!(["-C", source_repo, "push", "-u", "origin", "main"])

    %{remote_repo: remote_repo, source_repo: source_repo, workspace_root: workspace_root}
  end

  defp git!(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, code} -> flunk("git #{Enum.join(args, " ")} failed (#{code}): #{output}")
    end
  end

  defp routing_config(fixture) do
    %{
      target_label_prefix: "repo:",
      default_branch: "main",
      targets: %{
        "symphony-runtime" => %{source_path: fixture.source_repo, remote: fixture.remote_repo}
      }
    }
  end

  defp start_test_task_supervisor(suffix) do
    name = Module.concat(__MODULE__, :"CredentialGateSup_#{suffix}_#{System.unique_integer([:positive])}")
    {:ok, sup} = Task.Supervisor.start_link(name: name)

    on_exit(fn ->
      if Process.whereis(name) do
        try do
          GenServer.stop(name)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    {:ok, sup}
  end

  # A fresh runtime state, exactly as the host-eligibility dispatch tests
  # build it.
  defp runtime_state(supervisor) do
    %Orchestrator.State{
      task_supervisor: supervisor,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }
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

  defp wait_until(fun, timeout_ms) do
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
end
