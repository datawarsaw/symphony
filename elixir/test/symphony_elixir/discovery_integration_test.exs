defmodule SymphonyElixir.DiscoveryIntegrationTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{Discovery, LaunchMarker, RetryStore, WorkerContainment, WorkerFence}
  @ready File.read!(Path.expand("../fixtures/discovery-ready.txt", __DIR__))

  # Managed worker containment is a Windows-only launch class; on other hosts
  # the Discovery launch fence has no managed worker to exercise.
  @fence_skip if(match?({:win32, _}, :os.type()),
                do: false,
                else: "Managed worker containment is Windows-only; the Discovery launch fence is not exercised on this host"
              )

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

    File.write!(
      path,
      Jason.encode!(%{input_sha256: digest(input), status: status, output: output, provider: "OpenDesign", model: "OpenDesign/deepseek-v4.1-flash", reasoning: "medium", lane: "primary"})
    )

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

  @tag skip: @fence_skip
  test "real provider failure cannot mask an unconfirmed stop or overwrite its original launch", %{issue: issue} do
    reset_fence_env!()
    root = Path.dirname(Workflow.workflow_file_path())
    log = Path.join(root, "unconfirmed-launches.jsonl")
    helper = mismatched_receipt_helper!(root)
    previous = Application.get_env(:symphony_elixir, :jobrun_helper_path)
    Application.put_env(:symphony_elixir, :jobrun_helper_path, helper)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:symphony_elixir, :jobrun_helper_path),
        else: Application.put_env(:symphony_elixir, :jobrun_helper_path, previous)
    end)

    point_codex_command_at(discovery_command(issue) <> " fail-all " <> shell_quote(log))

    assert {:error, {:discovery_technical_failure, :worker_termination_unconfirmed}} =
             Discovery.run(issue, self(), sleep: fn _ -> :ok end)

    assert [started] = File.read!(log) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert started["model"] == "OpenDesign/deepseek-v4.1-flash"
    assert {:ok, marker} = LaunchMarker.read(issue.id)
    original = File.read!(LaunchMarker.marker_path(issue.id))
    assert {:error, :unknown} = WorkerFence.confirm_termination_receipt(marker["worker_identity"])
    assert retained_receipt(issue)["status"] == "TECHNICAL_FAILURE"
    refute_receive {:discovery_completed, _, _}
    assert {:error, {:discovery_technical_failure, _}} = Discovery.run(issue, self())
    assert File.read!(LaunchMarker.marker_path(issue.id)) == original
    assert length(String.split(File.read!(log), "\n", trim: true)) == 1
  end

  @tag skip: @fence_skip
  test "both real providers fail with confirmed drain and enter the Orchestrator retry envelope", %{issue: issue} do
    reset_fence_env!()
    fence_launch_helper!()
    root = Path.dirname(Workflow.workflow_file_path())
    log = Path.join(root, "failed-providers.jsonl")
    point_codex_command_at(discovery_command(issue) <> " fail-all " <> shell_quote(log))
    owner = self()
    task = Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn -> AgentRunner.run(issue, owner, sleep: fn _ -> :ok end) end)

    state = %Orchestrator.State{
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      running: %{
        issue.id => %{
          pid: task.pid,
          ref: task.ref,
          issue: issue,
          identifier: issue.identifier,
          started_at: DateTime.utc_now(),
          termination_expectation: :MANAGED_CONFIRMATION_REQUIRED,
          last_codex_message: nil,
          last_codex_event: nil,
          last_codex_timestamp: nil,
          session_id: nil,
          codex_app_server_pid: nil,
          codex_input_tokens: 0,
          codex_output_tokens: 0,
          codex_total_tokens: 0,
          codex_last_reported_input_tokens: 0,
          codex_last_reported_output_tokens: 0,
          codex_last_reported_total_tokens: 0,
          turn_count: 0
        }
      }
    }

    state = await_agent_down(state, task.ref)
    assert state.completed == MapSet.new()
    assert state.blocked == %{}
    assert state.parked == %{}
    assert state.retry_history[issue.id].attempt_count == 1
    retry = Map.fetch!(state.retry_attempts, issue.id)
    Process.cancel_timer(retry.timer_ref)
    assert {:ok, record} = RetryStore.read_record(Application.fetch_env!(:symphony_elixir, :retry_store_root), issue.id)
    assert record["status"] == "retrying"
    assert {:ok, :dead} = WorkerFence.confirm_termination_receipt(record["worker_identity"])
    launches = File.read!(log) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert Enum.map(launches, & &1["model"]) == ["OpenDesign/deepseek-v4.1-flash", "OpenDesign/deepseek-v4.1-flash", "google-antigravity/gemini-3.8-flash"]
    refute_receive {:discovery_completed, _, _}
  end

  defp await_agent_down(state, ref) do
    receive do
      {:DOWN, ^ref, :process, _, reason} = message ->
        refute reason == :normal
        {:noreply, next} = Orchestrator.handle_info(message, state)
        next

      message ->
        {:noreply, next} = Orchestrator.handle_info(message, state)
        await_agent_down(next, ref)
    after
      15_000 -> flunk("offline AgentRunner did not finish")
    end
  end

  # A private fixture build corrupts only its receipt binding. It retains the
  # production Job Object containment code and never changes the shared helper.
  defp mismatched_receipt_helper!(root) do
    source = Path.join(root, "mismatched-jobrun.cs")
    exe = Path.join(root, "mismatched-jobrun.exe")
    code = File.read!(Path.expand("priv/windows/jobrun/jobrun.cs"))
    assert code =~ ~s|AppendField(sb, "launch_id", launchId, false);|
    File.write!(source, String.replace(code, ~s|AppendField(sb, "launch_id", launchId, false);|, ~s|AppendField(sb, "launch_id", "fixture-mismatched-launch", false);|))
    csc = Path.join([System.fetch_env!("WINDIR"), "Microsoft.NET/Framework64/v4.0.30319/csc.exe"])
    {output, status} = System.cmd(csc, ["/nologo", "/out:" <> String.replace(exe, "/", "\\"), String.replace(source, "/", "\\")], stderr_to_stdout: true)
    assert status == 0, output
    File.write!(exe <> ".sha256", digest(File.read!(exe)))
    exe
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

  test "persisted TECHNICAL_FAILURE is forensic evidence and re-enters the scheduler failure path", %{issue: issue} do
    # The provider peer dies mid-handshake, so the first poll records an infra failure.
    point_codex_command_at(technical_failure_command())

    assert {:error, {:discovery_technical_failure, failure}} = Discovery.run(issue, self())
    assert failure in [nil, "infrastructure", :infrastructure]
    refute_receive {:discovery_completed, "discovery-issue", _}
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

  # Builds the immutable input the lane would have produced under a given primary route.
  # Used to place receipts where an earlier provider/model route would have written them.
  defp input_for_route(issue, route) do
    skill = File.read!(Config.settings!().discovery.skill_path)
    contract = File.read!(Path.join(Path.dirname(Config.settings!().discovery.skill_path), "references/discovery-contract.md"))
    {:ok, resolved} = SymphonyElixir.RepositoryRouter.resolve(issue, Config.settings!().routing)
    Discovery.immutable_input(issue, Map.from_struct(resolved), route, skill, contract)
  end

  defp old_route, do: %{provider: "xai", model: "xai/grok-4.6", reasoning: "medium"}

  defp old_route_evidence_path(issue) do
    input = input_for_route(issue, old_route())
    Path.join([Config.local_workspace_root(), ".discovery-results", digest(issue.id), digest(input) <> ".json"])
  end

  # Simulates a receipt retained by an earlier provider/model route: it is a valid READY
  # result, but it was generated for a different effective route.
  defp retain_old_route_receipt(issue, output) do
    input = input_for_route(issue, old_route())
    path = old_route_evidence_path(issue)
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{
        input_sha256: digest(input),
        status: "READY",
        output: output,
        provider: "xai",
        model: "xai/grok-4.6",
        reasoning: "medium",
        lane: "primary"
      })
    )

    path
  end

  test "a retained receipt from an earlier provider route is never reused as current evidence", %{issue: issue, ready: ready} do
    old_path = retain_old_route_receipt(issue, ready)
    old_bytes = File.read!(old_path)

    # Route identity is part of the immutable input, so the current route resolves a
    # different evidence path than the earlier route wrote.
    {:ok, current_input} = Discovery.snapshot(issue)
    refute current_input == input_for_route(issue, old_route())
    refute evidence_path(issue) == old_path

    # The existing stale-handoff safeguard stays effective: the issue's result directory
    # holds evidence, but none matching the current input, so implementation fails closed
    # instead of consuming the earlier route's handoff.
    assert {:error, :stale_discovery_handoff} = Discovery.implementation_issue(%{issue | state: "Todo"})

    # The lane must likewise find no current-route evidence, execute, and record a
    # technical failure for the CURRENT route rather than returning the earlier READY.
    # The deterministic peer swallows the handshake and exits 3, so the infrastructure
    # failure is recorded without racing the handshake write: a command that cannot be
    # launched at all dies before the initialize write and surfaces as an :epipe.
    point_codex_command_at(technical_failure_command())

    assert {:error, {:discovery_technical_failure, _}} = Discovery.run(issue, self())
    refute_receive {:discovery_completed, "discovery-issue", _}
    refute_received {:discovery_completed, "discovery-issue", "READY"}
    assert File.read!(old_path) == old_bytes
  end

  test "an earlier route receipt is never republished as current-route evidence", %{issue: issue, ready: ready} do
    retain_old_route_receipt(issue, ready)
    {peer, graphql} = publication_peer()

    # The deterministic peer swallows the handshake and exits 3 instead of answering, so
    # the current route provably re-executes and records its own technical failure. The
    # default command cannot be launched at all, which would fail as an :epipe during the
    # initialize write rather than as a classified infrastructure failure.
    point_codex_command_at(technical_failure_command())

    assert {:error, {:discovery_technical_failure, _}} = Discovery.run(issue, self(), publication_graphql: graphql)
    refute_received {:discovery_completed, "discovery-issue", "READY"}

    # The current route really re-executed and recorded its own failure, then
    # returned it to the scheduler instead of reporting Discovery completion.
    refute_receive {:discovery_completed, "discovery-issue", _}
    assert retained_receipt(issue)["status"] == "TECHNICAL_FAILURE"

    assert Agent.get(peer, & &1.calls) == []
    assert Agent.get(peer, &map_size(&1.comments)) == 0
  end

  test "the current route still reuses its own retained receipt unchanged", %{issue: issue, ready: ready} do
    retain(issue, "READY", ready)
    {peer, graphql} = publication_peer()
    assert :ok = Discovery.run(issue, self(), publication_graphql: graphql)
    assert_receive {:discovery_completed, "discovery-issue", "READY"}
    assert Agent.get(peer, &map_size(&1.comments)) == 1
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
    assert_raise AgentRunner.FailureError, ~r/discovery_lane_unavailable/, fn -> AgentRunner.run(issue, self()) end
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

  # MIC-223 Discovery launch fence over the real launch path: the deterministic
  # protocol peer is wrapped in a probe that witnesses the durable launch marker
  # from inside the worker process at its first instruction, binding these
  # regressions to what the worker actually observed at launch time.

  @tag skip: @fence_skip
  @tag timeout: 120_000
  test "Discovery's live-store launch writes the issue-keyed marker before the worker's first instruction",
       %{issue: issue} do
    reset_fence_env!()
    fence_launch_helper!()
    issue = fence_issue!(issue, "live")
    witness_path = Path.join(Config.local_workspace_root(), "fence-witness-live.json")
    marker_path = LaunchMarker.marker_path(issue.id)

    point_codex_command_at(fence_probe_command(issue, marker_path, witness_path, "-"))

    assert :ok = AgentRunner.run(issue, self())
    assert_receive {:discovery_completed, issue_id, "READY"}, 5_000
    assert issue_id == issue.id

    witness = fence_witness!(witness_path)
    marker = witnessed_marker!(witness, issue)
    identity = marker["worker_identity"]

    assert normalized_path(witness["marker_path"]) == normalized_path(marker_path)

    assert String.starts_with?(normalized_path(marker_path), normalized_path(Config.local_workspace_root())),
           "the live-store marker must resolve under the configured workspace root"

    assert witness["receipt_exists_at_start"] == false

    wait_until(10_000, fn -> match?({:ok, :dead}, WorkerFence.confirm_termination_receipt(identity)) end)
  end

  @tag skip: @fence_skip
  @tag timeout: 120_000
  test "Discovery pins the launch marker and receipt identity to the authority root, not live configuration",
       %{issue: issue} do
    reset_fence_env!()
    fence_launch_helper!()
    issue = fence_issue!(issue, "pinned")
    root = fence_fixture_root!("discovery-fence-pinned")
    witness_path = Path.join(root, "fence-witness-pinned.json")
    marker_path = LaunchMarker.marker_path(issue.id, root: root)

    fence_workflow!()
    live = Config.local_workspace_root()
    point_codex_command_at(fence_probe_command(issue, marker_path, witness_path, "-"))

    assert :ok = AgentRunner.run(issue, self(), authority_root: root)
    assert_receive {:discovery_completed, issue_id, "READY"}, 5_000
    assert issue_id == issue.id

    witness = fence_witness!(witness_path)
    marker = witnessed_marker!(witness, issue)
    identity = marker["worker_identity"]

    assert normalized_path(witness["marker_path"]) == normalized_path(marker_path)
    assert identity["authority_root"] == root
    assert normalized_path(Path.dirname(identity["receipt_path"])) == normalized_path(WorkerContainment.receipt_dir(root))
    assert Path.basename(identity["receipt_path"]) == identity["launch_id"] <> ".json"
    assert witness["receipt_exists_at_start"] == false

    # Live resolution finds nothing: an unpinned store would answer every fence
    # from the wrong root — the fail-open trap the pinning closes.
    refute File.exists?(marker_path_under(live, issue.id))
    assert {:error, :not_found} = LaunchMarker.read(issue.id)
    assert :allowed = LaunchMarker.reuse_gate(issue.id)

    # The wrapper's drain proof lands under the pinned root and opens the gate.
    wait_until(10_000, fn -> match?({:ok, :dead}, WorkerFence.confirm_termination_receipt(identity)) end)
    wait_until(10_000, fn -> LaunchMarker.reuse_gate(issue.id, root: root) == :allowed end)
    assert {:ok, receipt} = WorkerContainment.parse_receipt(identity["receipt_path"])
    assert receipt["launch_id"] == identity["launch_id"]
    assert WorkerContainment.classify_receipt(receipt) == :TERMINATED_CONFIRMED
  end

  @tag skip: @fence_skip
  @tag timeout: 120_000
  test "a pinned Discovery launch stays fenced at the authority root across an A to B workflow reload",
       %{issue: issue} do
    reset_fence_env!()
    fence_launch_helper!()
    issue = fence_issue!(issue, "reload")
    root_a = fence_fixture_root!("discovery-fence-reload-a")
    root_b = fence_fixture_root!("discovery-fence-reload-b")
    witness_path = Path.join(root_a, "fence-witness-reload.json")
    release_path = Path.join(root_a, "fence-release-reload")
    marker_path = LaunchMarker.marker_path(issue.id, root: root_a)

    fence_workflow!()
    point_codex_command_at(fence_probe_command(issue, marker_path, witness_path, release_path))

    test_pid = self()
    task = Task.async(fn -> Discovery.run(issue, test_pid, authority_root: root_a) end)

    witness = fence_witness!(witness_path)
    marker = witnessed_marker!(witness, issue)
    identity = marker["worker_identity"]

    # The held worker is alive and its death unproven: the pinned fence refuses.
    assert {:ok, disk_marker} = LaunchMarker.read(issue.id, root: root_a)
    assert disk_marker["issue_id"] == issue.id
    assert {:blocked, :worker_termination_unproven} = LaunchMarker.reuse_gate(issue.id, root: root_a)

    # Configuration reloads A -> B while the launch is live.
    point_workspace_root_at(root_b)

    # Live reads now resolve under B where nothing exists (the unpinned gate
    # fails open); the pinned gates still answer from A with the unproven launch.
    assert {:error, :not_found} = LaunchMarker.read(issue.id)
    assert :allowed = LaunchMarker.reuse_gate(issue.id)
    assert {:blocked, :worker_termination_unproven} = LaunchMarker.reuse_gate(issue.id, root: root_a)
    assert {:blocked, :worker_termination_unproven} = LaunchMarker.cleanup_gate(issue.id, root: root_a)
    refute File.exists?(marker_path_under(root_b, issue.id))

    # Release the worker; its pinned receipt proof opens the pinned gate.
    File.write!(release_path, "release\n")
    assert :ok = Task.await(task, 30_000)
    assert_receive {:discovery_completed, issue_id, "READY"}, 5_000
    assert issue_id == issue.id

    wait_until(10_000, fn -> match?({:ok, :dead}, WorkerFence.confirm_termination_receipt(identity)) end)
    wait_until(10_000, fn -> LaunchMarker.reuse_gate(issue.id, root: root_a) == :allowed end)
  end

  @tag skip: @fence_skip
  @tag timeout: 120_000
  test "an abruptly killed Discovery launcher leaves the pinned fence standing until receipt proof lands",
       %{issue: issue} do
    reset_fence_env!()
    fence_launch_helper!()
    issue = fence_issue!(issue, "kill")
    root = fence_fixture_root!("discovery-fence-kill")
    witness_path = Path.join(root, "fence-witness-kill.json")
    # This path is never created: the worker stays held through the kill until
    # its bounded hold deadline (kept short so the kill scenario stays quick).
    hold_path = Path.join(root, "fence-hold-kill")
    marker_path = LaunchMarker.marker_path(issue.id, root: root)

    fence_workflow!()
    point_codex_command_at(fence_probe_command(issue, marker_path, witness_path, hold_path, 5))

    {:ok, supervisor} = Task.Supervisor.start_link()
    task = Task.Supervisor.async_nolink(supervisor, fn -> Discovery.run(issue, nil, authority_root: root) end)

    witness = fence_witness!(witness_path)
    marker = witnessed_marker!(witness, issue)
    identity = marker["worker_identity"]
    receipt_path = identity["receipt_path"]

    assert {:blocked, :worker_termination_unproven} = LaunchMarker.reuse_gate(issue.id, root: root)

    # BEAM-side death of the launcher: the port owner is killed, not drained.
    ref = Process.monitor(task.pid)
    _ = Task.shutdown(task, :brutal_kill)
    assert_receive {:DOWN, ^ref, :process, _, :killed}

    # The abrupt death is not proof of worker death: the durable marker stands
    # (no live code path clears it) and the fence keeps refusing.
    assert File.regular?(marker_path)
    assert {:ok, disk_marker} = LaunchMarker.read(issue.id, root: root)
    assert disk_marker["launch_id"] == identity["launch_id"]

    # Only durable receipt evidence opens the gate. The wrapper survives BEAM
    # death, but the worker cannot see the broken pipe as EOF while the unread
    # initialize request still sits in it; it exits at its bounded hold
    # deadline, the wrapper drains the job tree, and its receipt lands under
    # the pinned root.
    wait_until(15_000, fn -> LaunchMarker.reuse_gate(issue.id, root: root) == :allowed end)
    assert {:ok, receipt} = WorkerContainment.parse_receipt(receipt_path)
    assert receipt["launch_id"] == identity["launch_id"]
    assert WorkerContainment.classify_receipt(receipt) == :TERMINATED_CONFIRMED

    # The gate opened on the receipt evidence while the marker still names the
    # launch — never through deletion or a runtime restart.
    assert {:ok, standing} = LaunchMarker.read(issue.id, root: root)
    assert standing["launch_id"] == identity["launch_id"]
  end

  defp reset_fence_env! do
    Application.delete_env(:symphony_elixir, :launch_marker_root)
    Application.delete_env(:symphony_elixir, :worker_termination_receipt_root)
    :ok
  end

  # Agent sandboxes on some hosts confine any process whose image lives under
  # the workspace root to writes under that same root. The fence tests must
  # launch the real helper while the worker writes its witness and receipt
  # under fixture roots in the system temp directory, so point the launcher at
  # a byte-identical copy of the verified helper outside the workspace. The
  # copy carries the same .sha256 sidecar and is hash-verified by
  # WorkerContainment.helper_path/0 exactly like the original, so the launch
  # path, its checks, and every assertion stay unchanged.
  defp fence_launch_helper! do
    {:ok, helper} = WorkerContainment.helper_path()
    dir = Path.join(System.tmp_dir!(), "symphony-fence-jobrun-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    copy = Path.join(dir, "jobrun.exe")
    File.cp!(helper, copy)
    File.cp!(helper <> ".sha256", copy <> ".sha256")
    previous = Application.get_env(:symphony_elixir, :jobrun_helper_path)
    Application.put_env(:symphony_elixir, :jobrun_helper_path, copy)

    on_exit(fn ->
      if is_binary(previous) do
        Application.put_env(:symphony_elixir, :jobrun_helper_path, previous)
      else
        Application.delete_env(:symphony_elixir, :jobrun_helper_path)
      end

      File.rm_rf(dir)
    end)

    :ok
  end

  # A per-test issue id keeps the live store's Discovery evidence from turning
  # these launches into cache hits of another test's retained evidence.
  defp fence_issue!(issue, label) do
    %{issue | id: "discovery-fence-#{label}-#{System.unique_integer([:positive])}"}
  end

  defp fence_fixture_root!(label) do
    root = Path.join(System.tmp_dir!(), "#{label}-#{System.unique_integer([:positive])}")
    File.rm_rf!(root)
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  # Rewrites the per-test workflow into the pinned-containment shape the fence
  # tests need. write_workflow_file!/2 regenerates the file and drops the
  # discovery section the setup injected, so re-inject it before reloading.
  defp fence_workflow! do
    path = Workflow.workflow_file_path()
    root = Path.dirname(path)
    skill = Path.join(root, "skill/SKILL.md")

    write_workflow_file!(path,
      tracker_kind: "memory",
      poll_interval_ms: 600_000,
      workspace_root: Path.join(root, "workspaces"),
      routing: %{"targets" => %{"symphony" => %{"source_path" => Path.join(root, "source")}}},
      hooks_before_run: "exit 77",
      hooks_after_run: "exit 78",
      codex_read_timeout_ms: 30_000,
      codex_worker_termination_grace_ms: 250,
      codex_command: "must-not-launch-discovery-fence"
    )

    body = File.read!(path)

    body =
      String.replace(body, "---", "---\ndiscovery:\n  enabled: true\n  skill_path: #{Jason.encode!(skill)}", global: false)

    File.write!(path, body)
    WorkflowStore.force_reload()
    :ok
  end

  # The Discovery codex command: the fence probe wrapping the deterministic
  # protocol peer, with the issue-keyed marker path it must witness. A hold
  # timeout keeps a held worker's bounded hold short for kill scenarios.
  defp fence_probe_command(issue, marker_path, witness_path, hold_path, hold_timeout_seconds \\ nil) do
    python = System.find_executable("python") || System.find_executable("python3")
    assert is_binary(python), "Python is required for the deterministic protocol peer"
    probe = Path.expand("../fixtures/discovery_fence_probe.py", __DIR__)
    peer = Path.expand("../fixtures/discovery_app_server.py", __DIR__)
    fixture = Path.expand("../fixtures/discovery-ready.txt", __DIR__)
    {:ok, route} = SymphonyElixir.RepositoryRouter.resolve(issue, Config.settings!().routing)
    args = [python, "-u", probe, marker_path, witness_path, hold_path, peer, fixture, route.source_path]
    args = if hold_timeout_seconds, do: args ++ [to_string(hold_timeout_seconds)], else: args
    Enum.map_join(args, " ", &shell_quote/1)
  end

  # Moves the workflow's workspace root (the A -> B reload) without disturbing
  # the injected discovery section; mirrors TestSupport's YAML string quoting.
  defp point_workspace_root_at(root) do
    path = Workflow.workflow_file_path()

    quoted =
      "\"" <> (root |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")) <> "\""

    workflow = Regex.replace(~r/^  root:.*$/m, File.read!(path), fn _ -> "  root: " <> quoted end)
    File.write!(path, workflow)
    WorkflowStore.force_reload()
    :ok
  end

  # The probe's witness, recorded before any protocol activity: the marker
  # content the worker process observed (or that it was absent).
  defp fence_witness!(path) do
    wait_until(15_000, fn -> File.regular?(path) end)
    path |> File.read!() |> Jason.decode!()
  end

  defp witnessed_marker!(witness, issue) do
    assert witness["exists"],
           "the worker started without an issue-keyed launch marker at #{witness["marker_path"]}"

    marker = Jason.decode!(witness["content"])
    assert marker["schema_version"] == 1
    assert marker["issue_id"] == issue.id
    assert is_binary(marker["worker_identity"]["launch_id"])
    assert marker["worker_identity"]["launch_id"] != ""
    marker
  end

  defp marker_path_under(root, issue_id) do
    Path.join([root, ".symphony-state", "launches", RetryStore.safe_issue_id(issue_id) <> ".json"])
  end

  defp normalized_path(path), do: path |> String.replace("\\", "/") |> String.downcase()

  defp wait_until(timeout, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(deadline, fun)
  end

  defp do_wait_until(deadline, fun) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition not met in time")
      else
        Process.sleep(50)
        do_wait_until(deadline, fun)
      end
    end
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
             "OpenDesign/deepseek-v4.1-flash",
             "OpenDesign/deepseek-v4.1-flash",
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
    assert comment["body"] =~ "- Provider: OpenDesign"
    assert comment["body"] =~ "- Model: OpenDesign/deepseek-v4.1-flash"
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

  test "narration echoing the issue identity never invalidates a legitimate READY receipt", %{issue: issue, ready: ready} do
    # A worker that narrates the issue identity before emitting its brief. Identity
    # binding must scan the validated contract region, not the raw output: an echoed
    # "ISSUE" line in discarded narration otherwise inflates the two required identity
    # matches and rejects a legitimate READY result.
    narrated = "ISSUE\nMIC-TEST\n\n" <> ready
    retain(issue, "READY", narrated)

    assert {:ok, handed_off} = Discovery.implementation_issue(%{issue | state: "Todo"})
    assert String.starts_with?(handed_off.description, "TODO HANDOFF")

    # The same result still publishes: the briefing identity is read from the brief.
    {peer, graphql} = publication_peer()
    assert :ok = Discovery.run(issue, self(), publication_graphql: graphql)
    assert Agent.get(peer, &map_size(&1.comments)) == 1
  end

  test "narration cannot spoof the parent identity that authorizes SPLIT publication", %{issue: issue, ready: ready} do
    # The proposal itself belongs to MIC-OTHER. The leading narration claims the real
    # parent issue, which under a first-match scan of the raw output would authorize
    # publishing a proposal for a different parent.
    foreign =
      ready
      |> String.split("TODO HANDOFF")
      |> hd()
      |> String.replace("VERDICT: READY", "VERDICT: SPLIT")
      |> split_result()
      |> String.replace("PARENT ISSUE\nMIC-TEST", "PARENT ISSUE\nMIC-OTHER")

    spoofed = "PARENT ISSUE\nMIC-TEST\nWHY SPLIT\n" <> foreign
    retain(issue, "SPLIT", spoofed)

    {peer, graphql} = publication_peer()
    assert :ok = Discovery.run(issue, self(), publication_graphql: graphql)

    # Parent identity is read from the validated proposal region, so the spoof is inert
    # and nothing is published for the foreign proposal.
    assert Agent.get(peer, & &1.calls) == []
    assert Agent.get(peer, &map_size(&1.comments)) == 0
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
