defmodule SymphonyElixir.DiscoveryIntegrationTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Discovery
  @ready File.read!(Path.expand("../fixtures/discovery-ready.txt", __DIR__))

  setup do
    root = Path.dirname(Workflow.workflow_file_path())
    source = Path.join(root, "source")
    File.mkdir_p!(source)
    skill = Path.join(root, "skill/SKILL.md")
    File.mkdir_p!(Path.join(root, "skill/references"))
    File.write!(skill, "Read-only Discovery. SUBAGENTS: DISABLED")
    File.write!(Path.join(root, "skill/references/discovery-contract.md"), "DISCOVERY BRIEF and TODO HANDOFF")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      poll_interval_ms: 600_000,
      workspace_root: Path.join(root, "workspaces"),
      routing: %{"targets" => %{"symphony" => %{"source_path" => source}}},
      hooks_before_run: "exit 77",
      hooks_after_run: "exit 78",
      codex_command: "must-not-launch-discovery-cache"
    )

    body = File.read!(Workflow.workflow_file_path())
    body = String.replace(body, "---", "---\ndiscovery:\n  enabled: true\n  skill_path: #{Jason.encode!(skill)}", global: false)
    File.write!(Workflow.workflow_file_path(), body)
    WorkflowStore.force_reload()

    issue = %Issue{
      id: "discovery-issue",
      identifier: "MIC-TEST",
      title: "Dedicated Discovery worker",
      description: "Inspect the bounded lane",
      state: "Discovery",
      labels: ["repo:symphony"],
      dispatchable: true,
      parent: %{"identifier" => "MIC-PARENT"},
      project: %{"name" => "Symphony"}
    }

    %{issue: issue, ready: String.replace(@ready, "C:/repo/symphony", source)}
  end

  defp retain(issue, status, output) do
    {:ok, input} = Discovery.snapshot(issue)
    digest = fn text -> :crypto.hash(:sha256, text) |> Base.encode16(case: :lower) end
    path = Path.join([Config.local_workspace_root(), ".discovery-results", digest.(issue.id), digest.(input) <> ".json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(%{input_sha256: digest.(input), status: status, output: output, provider: "xai", model: "xai/grok-4.6", reasoning: "medium", lane: "primary"}))
    path
  end

  test "snapshot is stable across the Discovery to Todo state change and includes only task context", %{issue: issue} do
    assert {:ok, input} = Discovery.snapshot(issue)
    assert {:ok, ^input} = Discovery.snapshot(%{issue | state: "Todo"})
    assert input =~ "MIC-PARENT"
    assert input =~ "repo:symphony"
    assert input =~ "Human Acceptance"
    assert Config.settings!().tracker.active_states == ["Todo", "In Progress", "Discovery"]
  end

  test "cached Discovery survives restart without entering hooks or implementation", %{issue: issue, ready: ready} do
    retain(issue, "READY", ready)
    assert :ok = AgentRunner.run(issue, self())
    assert_receive {:discovery_completed, "discovery-issue", "READY"}
    assert :ok = AgentRunner.run(issue, self())
    assert_receive {:discovery_completed, "discovery-issue", "READY"}
    {:ok, handed_off} = Discovery.implementation_issue(%{issue | state: "Todo"})
    assert String.starts_with?(handed_off.description, "TODO HANDOFF")
    refute handed_off.description =~ "DISCOVERY BRIEF"
  end

  test "non-ready, malformed, stale and wrong-repository handoffs cannot enter implementation", %{issue: issue, ready: ready} do
    for verdict <- ~w(SPLIT NEEDS_RESEARCH NEEDS_DECISION BLOCKED DROP INVALID) do
      retain(issue, verdict, "Preserved #{verdict} evidence")
      assert :ok = AgentRunner.run(issue, self())
      assert_receive {:discovery_completed, "discovery-issue", ^verdict}
      assert {:error, :discovery_not_ready} = Discovery.implementation_issue(%{issue | state: "Todo"})
    end

    retain(issue, "READY", "TODO HANDOFF")
    assert {:error, :invalid_discovery_handoff} = Discovery.implementation_issue(issue)
    retain(issue, "READY", ready)
    changed = %{issue | title: "Changed scope", state: "Todo"}
    assert {:error, :stale_discovery_handoff} = Discovery.implementation_issue(changed)
    retain(issue, "READY", String.replace(ready, "REPO: ", "REPO: /wrong/"))
    assert {:error, :invalid_discovery_handoff} = Discovery.implementation_issue(issue)
  end

  test "successful Discovery completion parks in the real orchestrator without continuation retry", %{issue: issue} do
    pid = start_supervised!({Orchestrator, name: Module.concat(__MODULE__, :Completion)})
    ref = make_ref()

    entry = %{
      pid: self(),
      ref: ref,
      issue: issue,
      identifier: issue.identifier,
      started_at: DateTime.utc_now(),
      session_id: nil,
      turn_count: 0
    }

    :sys.replace_state(pid, fn state -> %{state | running: %{issue.id => entry}, claimed: MapSet.new([issue.id])} end)
    send(pid, {:discovery_completed, issue.id, "SPLIT"})
    send(pid, {:DOWN, ref, :process, self(), :normal})
    state = :sys.get_state(pid)
    assert state.blocked[issue.id].discovery_result == "SPLIT"
    assert state.retry_attempts == %{}
    assert state.running == %{}
    assert state.blocked[issue.id].issue.state == "Discovery"
  end

  test "disabled lane retains default active states and rejects Discovery dispatch", %{issue: issue} do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    assert Config.settings!().tracker.active_states == ["Todo", "In Progress"]
    assert {:ok, ^issue} = Discovery.implementation_issue(issue)
    assert_raise RuntimeError, ~r/discovery_lane_unavailable/, fn -> AgentRunner.run(issue, self()) end
  end

  test "uncached lane uses a real protocol process and denies attempted lifecycle tool calls", %{issue: issue} do
    python = System.find_executable("python") || System.find_executable("python3")
    assert is_binary(python), "Python is required for the deterministic protocol peer"
    script = Path.expand("../fixtures/discovery_app_server.py", __DIR__)
    fixture = Path.expand("../fixtures/discovery-ready.txt", __DIR__)
    {:ok, route} = SymphonyElixir.RepositoryRouter.resolve(issue, Config.settings!().routing)
    command = Enum.map_join([python, "-u", script, fixture, route.source_path], " ", &shell_quote/1)
    path = Workflow.workflow_file_path()
    workflow = File.read!(path)
    workflow = Regex.replace(~r/^  command:.*$/m, workflow, fn _ -> "  command: " <> Jason.encode!(command) end)
    File.write!(path, workflow)
    WorkflowStore.force_reload()
    assert :ok = AgentRunner.run(issue, self())
    assert_receive {:discovery_completed, "discovery-issue", "READY"}, 5_000
    assert {:ok, %{description: handoff}} = Discovery.implementation_issue(%{issue | state: "Todo"})
    assert String.starts_with?(handoff, "TODO HANDOFF")
  end

  test "protocol rate-limit exhaustion uses Gemini with identical input and discards partial output", %{issue: issue} do
    python = System.find_executable("python") || System.find_executable("python3")
    script = Path.expand("../fixtures/discovery_app_server.py", __DIR__)
    fixture = Path.expand("../fixtures/discovery-ready.txt", __DIR__)
    {:ok, route} = SymphonyElixir.RepositoryRouter.resolve(issue, Config.settings!().routing)
    path = Workflow.workflow_file_path()
    log = Path.join(Path.dirname(path), "attempts.jsonl")
    args = [python, "-u", script, fixture, route.source_path, "rate-limit", log]
    command = Enum.map_join(args, " ", &shell_quote/1)

    workflow =
      Regex.replace(~r/^  command:.*$/m, File.read!(path), fn _ ->
        "  command: " <> Jason.encode!(command)
      end)

    File.write!(path, workflow)
    WorkflowStore.force_reload()
    assert :ok = AgentRunner.run(issue, self())
    assert_receive {:discovery_completed, "discovery-issue", "READY"}, 5_000
    attempts = log |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    assert Enum.map(attempts, & &1["model"]) == [
             "xai/grok-4.6",
             "xai/grok-4.6",
             "google-antigravity/gemini-3.8-flash"
           ]

    {:ok, input} = Discovery.snapshot(issue)
    assert Enum.all?(attempts, &(&1["input"] == input))
    [receipt] = Path.wildcard(Path.join(Config.local_workspace_root(), ".discovery-results/*/*.json"))
    result = receipt |> File.read!() |> Jason.decode!()
    assert result["lane"] == "fallback"
    assert result["fallback_reason"] == "rate_limit"
    refute result["output"] =~ "partial primary output"
  end

  defp shell_quote(value) do
    "'" <> (value |> String.replace("\\", "/") |> String.replace("'", "'\"'\"'")) <> "'"
  end
end
