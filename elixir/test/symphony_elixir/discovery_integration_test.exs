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

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp evidence_path(issue) do
    {:ok, input} = Discovery.snapshot(issue)
    Path.join([Config.local_workspace_root(), ".discovery-results", digest(issue.id), digest(input) <> ".json"])
  end

  defp retained_receipt(issue) do
    path = evidence_path(issue)
    assert File.regular?(path), "expected retained Discovery evidence at #{path}"
    path |> File.read!() |> Jason.decode!()
  end

  defp retain(issue, status, output) do
    {:ok, input} = Discovery.snapshot(issue)
    path = evidence_path(issue)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(%{input_sha256: digest(input), status: status, output: output, provider: "xai", model: "xai/grok-4.6", reasoning: "medium", lane: "primary"}))
    path
  end

  # Rewrites the workflow codex command between polls. The command is not part of the
  # cache key, so the frozen issue input stays byte-identical.
  defp point_codex_command_at(command) do
    path = Workflow.workflow_file_path()
    workflow = Regex.replace(~r/^  command:.*$/m, File.read!(path), fn _ -> "  command: " <> Jason.encode!(command) end)
    File.write!(path, workflow)
    WorkflowStore.force_reload()
  end

  defp discovery_command(issue) do
    python = System.find_executable("python") || System.find_executable("python3")
    assert is_binary(python), "Python is required for the deterministic protocol peer"
    script = Path.expand("../fixtures/discovery_app_server.py", __DIR__)
    fixture = Path.expand("../fixtures/discovery-ready.txt", __DIR__)
    {:ok, route} = SymphonyElixir.RepositoryRouter.resolve(issue, Config.settings!().routing)
    Enum.map_join([python, "-u", script, fixture, route.source_path], " ", &shell_quote/1)
  end

  # A provider peer that swallows the handshake and dies without answering records a
  # deterministic infrastructure failure instead of a semantic verdict.
  defp technical_failure_command do
    python = System.find_executable("python") || System.find_executable("python3")
    assert is_binary(python), "Python is required for the deterministic protocol peer"
    Enum.map_join([python, "-u", "-c", "import sys; sys.stdin.readline(); sys.exit(3)"], " ", &shell_quote/1)
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

  test "persisted TECHNICAL_FAILURE is forensic evidence, never a terminal cache hit", %{issue: issue} do
    # The provider peer dies mid-handshake, so the first poll records an infra failure.
    point_codex_command_at(technical_failure_command())

    assert :ok = Discovery.run(issue, self())
    assert_receive {:discovery_completed, "discovery-issue", "TECHNICAL_FAILURE"}, 5_000
    assert retained_receipt(issue)["status"] == "TECHNICAL_FAILURE"

    # The provider recovers between polls while the frozen input stays unchanged, so a
    # cached failure would be returned forever: the lane must re-enter execution.
    point_codex_command_at(discovery_command(issue))

    assert :ok = Discovery.run(issue, self())
    assert_receive {:discovery_completed, "discovery-issue", "READY"}, 5_000
    assert retained_receipt(issue)["status"] == "READY"
  end

  test "retained READY stays a cache hit without re-entering execution", %{issue: issue} do
    point_codex_command_at(discovery_command(issue))

    assert :ok = Discovery.run(issue, self())
    assert_receive {:discovery_completed, "discovery-issue", "READY"}, 5_000
    retained = retained_receipt(issue)
    assert retained["status"] == "READY"

    # The provider is unreachable now, so any execution would replace the retained
    # verdict instead of returning it.
    point_codex_command_at("must-not-launch-discovery-cache")

    assert :ok = Discovery.run(issue, self())
    assert_receive {:discovery_completed, "discovery-issue", "READY"}, 5_000
    assert retained_receipt(issue) == retained
  end

  test "retained deterministic verdicts stay a cache hit without re-entering execution", %{issue: issue} do
    path = retain(issue, "NEEDS_RESEARCH", "Preserved NEEDS_RESEARCH evidence")
    retained = path |> File.read!() |> Jason.decode!()

    # The configured command cannot launch, so executing again would replace this
    # verdict with a technical failure.
    assert :ok = Discovery.run(issue, self())
    assert_receive {:discovery_completed, "discovery-issue", "NEEDS_RESEARCH"}, 5_000
    assert path |> File.read!() |> Jason.decode!() == retained
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
    retain(issue, "READY", String.replace(ready, ~r/^REPO: .+$/m, "REPO: /wrong/repo"))
    assert {:error, :invalid_discovery_handoff} = Discovery.implementation_issue(issue)
  end

  test "READY binding accepts a descriptive REPO field that names the canonical source once", %{issue: issue, ready: ready} do
    source = Config.settings!().routing.targets["symphony"]["source_path"]
    slashy = String.replace(source, "\\", "/")

    accepted = [
      "REPO: " <> slashy,
      "REPO: " <> String.replace(slashy, "/", <<92>>),
      "REPO: symphony-runtime (" <> <<96>> <> slashy <> <<96>> <> ", Elixir app)"
    ]

    Enum.each(accepted, fn repo ->
      retain(issue, "READY", String.replace(ready, ~r/^REPO: .+$/m, fn _ -> repo end))
      assert {:ok, handed_off} = Discovery.implementation_issue(%{issue | state: "Todo"})
      assert String.starts_with?(handed_off.description, "TODO HANDOFF")
    end)
  end

  test "READY binding rejects unsafe or ambiguous REPO fields", %{issue: issue, ready: ready} do
    source = Config.settings!().routing.targets["symphony"]["source_path"]
    slashy = String.replace(source, "\\", "/")

    rejected = [
      "REPO: /wrong/repo",
      "REPO: " <> slashy <> "-evil",
      "REPO: " <> slashy <> " and " <> slashy,
      "REPO: " <> slashy <> " plus C:/Windows/System32",
      "REPO: " <> slashy <> "/../secret",
      "REPO: symphony-runtime"
    ]

    Enum.each(rejected, fn repo ->
      retain(issue, "READY", String.replace(ready, ~r/^REPO: .+$/m, fn _ -> repo end))
      assert {:error, :invalid_discovery_handoff} = Discovery.implementation_issue(%{issue | state: "Todo"})
    end)
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

  test "Discovery forwards app-server activity to the orchestrator so the watchdog sees life", %{issue: issue} do
    python = System.find_executable("python") || System.find_executable("python3")
    assert is_binary(python), "Python is required for the deterministic protocol peer"
    script = Path.expand("../fixtures/discovery_app_server.py", __DIR__)
    fixture = Path.expand("../fixtures/discovery-ready.txt", __DIR__)
    {:ok, route} = SymphonyElixir.RepositoryRouter.resolve(issue, Config.settings!().routing)
    command = Enum.map_join([python, "-u", script, fixture, route.source_path], " ", &shell_quote/1)
    path = Workflow.workflow_file_path()
    workflow = Regex.replace(~r/^  command:.*$/m, File.read!(path), fn _ -> "  command: " <> Jason.encode!(command) end)
    File.write!(path, workflow)
    WorkflowStore.force_reload()

    assert :ok = AgentRunner.run(issue, self())

    assert_receive {:codex_worker_update, "discovery-issue", %{event: :session_started} = activity}, 5_000
    %{session_id: session_id, timestamp: %DateTime{}} = activity

    assert is_binary(session_id)
    assert session_id == "discovery-thread-discovery-turn"

    assert_receive {:codex_worker_update, "discovery-issue", %{event: event, timestamp: %DateTime{}}},
                   5_000

    assert event in [:turn_completed, :tool_call_failed, :notification]
    assert_receive {:discovery_completed, "discovery-issue", "READY"}, 5_000
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

  defp publication_peer(mode \\ :normal) do
    {:ok, peer} = Agent.start_link(fn -> %{comments: %{}, calls: [], mode: mode} end)

    graphql = fn query, variables ->
      Agent.get_and_update(peer, &publication_response(query, variables, &1))
    end

    {peer, graphql}
  end

  defp publication_response(query, variables, state) do
    state = %{state | calls: [{query, variables} | state.calls]}

    if String.starts_with?(query, "query ") do
      nodes = List.wrap(state.comments[variables.id])
      {{:ok, %{"data" => %{"comments" => %{"nodes" => nodes}}}}, state}
    else
      assert String.starts_with?(query, "mutation SymphonyDiscoveryCommentCreate")
      assert Enum.sort(Map.keys(variables.input)) == [:body, :doNotSubscribeToIssue, :id, :issueId]
      input = variables.input
      comment = %{"id" => input.id, "body" => input.body, "issue" => %{"id" => input.issueId}}
      publication_create(state, comment)
    end
  end

  defp publication_create(%{mode: :reject} = state, _comment),
    do: {{:ok, %{"errors" => [%{"message" => "Denied"}]}}, state}

  defp publication_create(state, comment) do
    if Map.has_key?(state.comments, comment["id"]) do
      {{:ok, %{"errors" => [%{"message" => "Duplicate ID"}]}}, state}
    else
      result =
        if state.mode == :lost_response,
          do: {:error, :timeout},
          else: {:ok, %{"data" => %{"commentCreate" => %{"success" => true, "comment" => comment}}}}

      {result, %{state | comments: Map.put(state.comments, comment["id"], comment)}}
    end
  end

  test "validated retained READY publishes once across retries without lifecycle or description writes", %{issue: issue, ready: ready} do
    path = retain(issue, "READY", ready)
    original = File.read!(path)
    {peer, graphql} = publication_peer()
    assert :ok = Discovery.run(issue, self(), publication_graphql: graphql)
    assert_receive {:discovery_completed, "discovery-issue", "READY"}
    assert :ok = Discovery.run(issue, self(), publication_graphql: graphql)
    state = Agent.get(peer, & &1)
    assert map_size(state.comments) == 1
    [comment] = Map.values(state.comments)
    assert comment["issue"]["id"] == issue.id
    assert comment["body"] =~ "## Discovery\n\nVERDICT: READY"
    assert comment["body"] =~ "### Recommendation\nExtend the existing runner."
    assert comment["body"] =~ "### Dependencies"
    assert comment["body"] =~ "### Acceptance criteria"
    assert comment["body"] =~ "TODO HANDOFF"
    assert comment["body"] =~ "- Provider: xAI"
    assert comment["body"] =~ "- Model: xai/grok-4.6"
    assert comment["body"] =~ "- Reasoning: medium"
    assert comment["body"] =~ "- Duration: unavailable"
    assert comment["body"] =~ "- Fallback: NO"
    assert comment["body"] =~ "- Subagents: 0"
    assert Enum.count(state.calls, fn {q, _} -> String.starts_with?(q, "mutation ") end) == 1
    assert File.read!(path) == original
    assert issue.state == "Discovery"
    assert issue.description == "Inspect the bounded lane"
    refute_receive {:codex_worker_update, _, _}
  end

  test "all validated non-READY outcomes publish with an appropriate next action", %{issue: issue, ready: ready} do
    for verdict <- ~w(NEEDS_RESEARCH NEEDS_DECISION BLOCKED DROP SPLIT) do
      text = ready |> String.split("TODO HANDOFF") |> hd() |> String.replace("VERDICT: READY", "VERDICT: " <> verdict)
      text = if verdict == "SPLIT", do: split_result(text), else: text
      retain(issue, verdict, text)
      {peer, graphql} = publication_peer()
      assert :ok = Discovery.run(issue, self(), publication_graphql: graphql)
      [comment] = peer |> Agent.get(&Map.values(&1.comments))
      assert comment["body"] =~ "VERDICT: #{verdict}"
      refute comment["body"] =~ "TODO HANDOFF"
      if verdict == "SPLIT", do: assert(comment["body"] =~ "SPLIT PROPOSAL")
    end
  end

  defp split_result(brief) do
    String.replace(brief, "SPLIT REQUIRED: NO", "SPLIT REQUIRED: YES") <>
      "\nSPLIT PROPOSAL\n\nPARENT ISSUE\nMIC-TEST\n\nWHY SPLIT\nSeparate owners.\n" <>
      Enum.map_join(1..2, "\n", fn n ->
        "\nCHILD #{n}\nTITLE: Bounded child #{n}\nDESTINATION: repo\nOBJECTIVE: Single outcome\nACCEPTANCE: Observable result\nDEPENDS ON: NONE\n"
      end) <> "\nPARENT COMPLETION CONDITION\nBoth children pass.\n"
  end

  test "malformed, mismatched and unbound retained evidence never reaches Linear", %{issue: issue, ready: ready} do
    source = Config.settings!().routing.targets["symphony"]["source_path"]

    bad = [
      {"READY", "VERDICT: READY"},
      {"BLOCKED", ready},
      {"INVALID", ready},
      {"READY", String.replace(ready, "MIC-TEST", "MIC-OTHER")},
      {"READY", String.replace(ready, "REPO: ", "REPO: /wrong/")},
      {"READY", String.replace(ready, source, source <> "-evil")},
      {"READY", String.replace(ready, "REPO: " <> source, "REPO: " <> source <> " plus /etc/other")},
      {"DROP", ready |> String.split("TODO HANDOFF") |> hd() |> String.replace("READY", "DROP") |> String.replace("MIC-TEST", "MIC-OTHER")},
      {"SPLIT",
       ready |> String.split("TODO HANDOFF") |> hd() |> String.replace("VERDICT: READY", "VERDICT: SPLIT") |> split_result() |> String.replace("PARENT ISSUE\nMIC-TEST", "PARENT ISSUE\nMIC-OTHER")}
    ]

    {peer, graphql} = publication_peer()

    for {status, text} <- bad do
      retain(issue, status, text)
      assert :ok = Discovery.run(issue, self(), publication_graphql: graphql)
    end

    assert Agent.get(peer, & &1.calls) == []
  end

  test "failed publication retries retained result and recovers a lost create response", %{issue: issue, ready: ready} do
    retain(issue, "READY", ready)
    {peer, graphql} = publication_peer(:reject)
    assert {:error, :discovery_comment_publish_failed} = Discovery.run(issue, self(), publication_graphql: graphql)
    refute_receive {:discovery_completed, _, _}
    Agent.update(peer, &%{&1 | mode: :lost_response})
    assert :ok = Discovery.run(issue, self(), publication_graphql: graphql)
    assert :ok = Discovery.run(issue, self(), publication_graphql: graphql)
    assert Agent.get(peer, &map_size(&1.comments)) == 1
    refute_receive {:codex_worker_update, _, _}
  end

  test "new validated result preserves old comment and stable authority despite old retry", %{issue: issue, ready: ready} do
    path = retain(issue, "READY", ready)
    first = path |> File.read!() |> Jason.decode!() |> Map.put("completed_at", "2026-09-08T01:00:00Z")
    File.write!(path, Jason.encode!(first))
    {peer, graphql} = publication_peer()
    assert :ok = Discovery.run(issue, self(), publication_graphql: graphql)
    second = first |> Map.put("completed_at", "2026-09-08T02:00:00Z") |> Map.put("output", String.replace(ready, "Extend the existing runner.", "Extend the runner with a bounded publisher."))
    File.write!(path, Jason.encode!(second))
    assert :ok = Discovery.run(issue, self(), publication_graphql: graphql)
    File.write!(path, Jason.encode!(first))
    assert :ok = Discovery.run(issue, self(), publication_graphql: graphql)
    comments = Agent.get(peer, &Map.values(&1.comments))
    assert length(comments) == 2
    assert Enum.all?(comments, &String.contains?(&1["body"], "Publication time does not change authority."))
    assert Enum.any?(comments, &String.contains?(&1["body"], "2026-09-08T02:00:00Z"))
  end

  test "retained fallback metadata and duration survive cached publication", %{issue: issue, ready: ready} do
    path = retain(issue, "READY", ready)
    receipt = path |> File.read!() |> Jason.decode!()

    receipt =
      Map.merge(receipt, %{"provider" => "google-antigravity", "model" => "google-antigravity/gemini-3.8-flash", "lane" => "fallback", "fallback_reason" => "rate_limit", "duration_ms" => 442_123})

    File.write!(path, Jason.encode!(receipt))
    {peer, graphql} = publication_peer()
    assert :ok = Discovery.run(issue, self(), publication_graphql: graphql)
    [comment] = Agent.get(peer, &Map.values(&1.comments))
    assert comment["body"] =~ "- Model: google-antigravity/gemini-3.8-flash"
    assert comment["body"] =~ "- Reasoning: medium"
    assert comment["body"] =~ "- Duration: 442.1s"
    assert comment["body"] =~ "- Fallback: YES (rate_limit)"
  end

  test "read failures and conflicting comments fail closed without mutations", %{issue: issue, ready: ready} do
    retain(issue, "READY", ready)

    failing = fn query, _ ->
      assert String.starts_with?(query, "query ")
      {:error, :timeout}
    end

    assert {:error, :discovery_comment_read_failed} = Discovery.run(issue, self(), publication_graphql: failing)
    {peer, graphql} = publication_peer()
    assert :ok = Discovery.run(issue, self(), publication_graphql: graphql)

    Agent.update(peer, fn state ->
      comments = Map.new(state.comments, fn {id, comment} -> {id, Map.put(comment, "body", "Edited by someone else")} end)
      %{state | comments: comments, calls: []}
    end)

    assert {:error, :discovery_comment_conflict} = Discovery.run(issue, self(), publication_graphql: graphql)
    assert Enum.all?(Agent.get(peer, & &1.calls), fn {q, _} -> String.starts_with?(q, "query ") end)
  end

  test "optional metadata never prevents publication", %{issue: issue, ready: ready} do
    path = retain(issue, "READY", ready)
    receipt = path |> File.read!() |> Jason.decode!() |> Map.drop(~w(provider model reasoning lane fallback_reason))
    File.write!(path, Jason.encode!(receipt))
    {peer, graphql} = publication_peer()
    assert :ok = Discovery.run(issue, self(), publication_graphql: graphql)
    [comment] = Agent.get(peer, &Map.values(&1.comments))
    assert comment["body"] =~ "- Provider: unavailable"
    assert comment["body"] =~ "- Fallback: unavailable"
  end

  test "concurrent publication retries use a single authoritative comment", %{issue: issue, ready: ready} do
    retain(issue, "READY", ready)
    {peer, graphql} = publication_peer()
    tasks = for _ <- 1..2, do: Task.async(fn -> Discovery.run(issue, nil, publication_graphql: graphql) end)
    assert Enum.map(tasks, &Task.await/1) == [:ok, :ok]
    assert Agent.get(peer, &map_size(&1.comments)) == 1
  end
end
