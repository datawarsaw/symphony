defmodule SymphonyElixir.RuntimeAuthorityV3Test do
  use SymphonyElixir.TestSupport

  @moduletag timeout: 240_000

  @moduledoc """
  v3 recomposition coverage: the mutation-root pinning contracts on top of the
  full current-main lifecycle (Launch Marker, Workspace Viability, PARKED
  recovery).

  The known bug this suite closes: R1 acquires authority A and writes a launch
  marker under A; configuration reloads `workspace.root` A→B. A store resolved
  from live configuration would strand the fence's memory under B — every gate
  would then read "no marker" and fail OPEN. All marker operations here must
  stay on A, and B must never be touched.
  """

  alias SymphonyElixir.{Control, Discovery, LaunchMarker, Orchestrator, RetryPolicy, RetryStore, RuntimeLease, WorkerContainment, WorkerFence, Workspace}

  @discovery_ready File.read!(Path.expand("../fixtures/discovery-ready.txt", __DIR__))
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Wake.Store, as: WakeStore

  @hard_budget_ms 300

  setup do
    root_a = unique_root("v3-a") |> Path.expand()
    root_b = unique_root("v3-b") |> Path.expand()
    File.mkdir_p!(root_a)
    File.mkdir_p!(root_b)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      poll_interval_ms: 3_600_000,
      workspace_root: root_a,
      # the detached drain watcher must be able to survive a workflow reload
      # between spawn and the arrival of the death proof
      codex_worker_termination_grace_ms: 10_000
    )

    # Shrink the detached drain watcher's budget for these tests only; the
    # proof is written promptly, so the budget only bounds failure paths.
    previous_budget = Application.get_env(:symphony_elixir, :worker_termination_hard_budget_ms)
    Application.put_env(:symphony_elixir, :worker_termination_hard_budget_ms, @hard_budget_ms)

    on_exit(fn ->
      if is_nil(previous_budget) do
        Application.delete_env(:symphony_elixir, :worker_termination_hard_budget_ms)
      else
        Application.put_env(:symphony_elixir, :worker_termination_hard_budget_ms, previous_budget)
      end

      File.rm_rf(root_a)
      File.rm_rf(root_b)
    end)

    {:ok, root_a: root_a, root_b: root_b, canonical_a: root_a, canonical_b: root_b}
  end

  # -- the known bug, closed: the marker store stays at A across A→B ----------

  test "launch marker store remains at A after an A→B config reload; B is untouched", %{
    root_a: root_a,
    root_b: root_b,
    canonical_a: canonical_a,
    canonical_b: canonical_b
  } do
    issue = test_issue("v3-marker", "V3M-1")
    workspace = workspace_under(root_a, issue)
    identity = new_identity(issue, workspace, canonical_a)

    assert :ok = LaunchMarker.record(identity, identifier: issue.identifier, attempt_id: 1, root: canonical_a)
    assert {:ok, _marker} = LaunchMarker.read(issue.id, root: canonical_a)

    # configuration reloads A → B while the marker is unproven
    reload_root_to_b!(root_b)

    # the pinned store answers every gate from A
    assert {:ok, _marker} = LaunchMarker.read(issue.id, root: canonical_a)
    assert {:blocked, :worker_termination_unproven} = LaunchMarker.reuse_gate(issue.id, root: canonical_a)
    assert {:blocked, :worker_termination_unproven} = LaunchMarker.cleanup_gate(issue.id, root: canonical_a)

    # live configuration now points at B, where no marker exists: the
    # un-pinned resolution documents exactly the fail-open trap the pinning
    # closes (this assertion is the regression tripwire for the known bug)
    assert {:error, :not_found} = LaunchMarker.read(issue.id)
    assert :allowed = LaunchMarker.reuse_gate(issue.id)

    # the drain proof arrives under A; the pinned fence admits and clears A
    write_receipt!(identity)
    assert :allowed = LaunchMarker.reuse_gate(issue.id, root: canonical_a)
    assert :ok = LaunchMarker.clear(issue.id, root: canonical_a)
    assert {:error, :not_found} = LaunchMarker.read(issue.id, root: canonical_a)

    # B was never written to by this lifecycle (issue-scoped marker path; the
    # launches directory itself may be created concurrently by an unrelated
    # unpinned test sharing the VM's global workflow config)
    refute File.exists?(marker_path_under(canonical_b, issue.id))
  end

  # -- receipt directory pinning ------------------------------------------------

  test "termination receipts are written under the pinned authority root", %{
    root_a: root_a,
    root_b: root_b,
    canonical_a: canonical_a
  } do
    issue = test_issue("v3-receipt", "V3R-1")
    identity = new_identity(issue, workspace_under(root_a, issue), canonical_a)

    assert identity["authority_root"] == canonical_a

    assert identity["receipt_path"] ==
             Path.join([canonical_a, ".symphony-state", "worker-terminations", identity["launch_id"] <> ".json"])

    # while configuration still desires A, pinned and live resolutions agree
    assert WorkerContainment.receipt_dir(canonical_a) == Path.join([canonical_a, ".symphony-state", "worker-terminations"])

    reload_root_to_b!(root_b)

    # a reload must not move the pinned receipt directory, while live
    # configuration now resolves a different (B) directory
    assert WorkerContainment.receipt_dir(canonical_a) == Path.join([canonical_a, ".symphony-state", "worker-terminations"])

    assert identity["receipt_path"] ==
             Path.join([canonical_a, ".symphony-state", "worker-terminations", identity["launch_id"] <> ".json"])

    refute WorkerContainment.receipt_dir(canonical_a) == WorkerContainment.receipt_dir(nil)

    # the explicit app-env override still wins over both
    override = Path.join(root_a, "receipt-override")
    Application.put_env(:symphony_elixir, :worker_termination_receipt_root, override)
    assert WorkerContainment.receipt_dir(canonical_a) == override
    Application.delete_env(:symphony_elixir, :worker_termination_receipt_root)
  end

  # -- wake-ledger pinning --------------------------------------------------------

  test "wake ledger recovery reads the pinned authority root, not live config", %{
    root_b: root_b,
    canonical_a: canonical_a
  } do
    WakeStore.write_issue(canonical_a, "issue-v3-wake", %{pending: [], handled: []})
    reload_root_to_b!(root_b)

    without_retry_store_root_env(fn ->
      {:ok, sup} = Task.Supervisor.start_link(name: unique_name("V3WakeTasks"))
      {:ok, pid} = Orchestrator.start_link(name: unique_name("V3WakeOrch"), authority_root: canonical_a, task_supervisor: sup)

      on_exit(fn ->
        if Process.alive?(pid), do: Process.exit(pid, :normal)
        if Process.alive?(sup), do: Process.exit(sup, :normal)
      end)

      ledger = :sys.get_state(pid).wake_ledger

      # the ledger is bound to A and recovered the record seeded there
      assert ledger.root == canonical_a
      assert Map.has_key?(ledger.issues, "issue-v3-wake")
    end)
  end

  # -- discovery-root pinning -----------------------------------------------------

  test "discovery evidence stays pinned to the authority root across drift", %{
    root_a: root_a,
    root_b: root_b,
    canonical_a: canonical_a,
    canonical_b: canonical_b
  } do
    source = Path.join(root_a, "source-symphony")
    File.mkdir_p!(source)

    skill = Path.join([root_a, "skill", "SKILL.md"])
    File.mkdir_p!(Path.join([root_a, "skill", "references"]))
    File.write!(skill, "Read-only Discovery. SUBAGENTS: DISABLED")
    File.write!(Path.join([root_a, "skill", "references", "discovery-contract.md"]), "DISCOVERY BRIEF and TODO HANDOFF")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      poll_interval_ms: 3_600_000,
      workspace_root: root_a,
      routing: %{"targets" => %{"symphony" => %{"source_path" => source}}}
    )

    body = File.read!(Workflow.workflow_file_path())
    body = String.replace(body, "---", "---\ndiscovery:\n  enabled: true\n  skill_path: #{Jason.encode!(skill)}", global: false)
    File.write!(Workflow.workflow_file_path(), body)
    WorkflowStore.force_reload()

    # identifier/title must match the checked-in READY fixture's ISSUE lines
    # (bind_issue verifies the handoff identity against the current issue)
    issue = %Issue{
      id: "issue-v3-discovery",
      identifier: "MIC-TEST",
      title: "Dedicated Discovery worker",
      description: "evidence stays at the pinned root",
      state: "Discovery",
      labels: ["repo:symphony"],
      dispatchable: true,
      parent: nil,
      project: nil
    }

    # seed READY evidence under A using the exact snapshot input digest
    {:ok, input} = Discovery.snapshot(issue)
    evidence = Path.join([canonical_a, ".discovery-results", digest(issue.id), digest(input) <> ".json"])
    File.mkdir_p!(Path.dirname(evidence))
    ready_output = String.replace(@discovery_ready, "C:/repo/symphony", source)

    File.write!(
      evidence,
      Jason.encode!(%{
        input_sha256: digest(input),
        status: "READY",
        output: ready_output,
        provider: "p",
        model: "m"
      })
    )

    # configuration drifts to B (routing and Discovery stay enabled on B's
    # workflow); the pinned evidence read stays on A
    reload_root_to_b!(root_b, routing: %{"targets" => %{"symphony" => %{"source_path" => source}}})
    inject_discovery!(skill)

    assert {:ok, implementation} = Discovery.implementation_issue(issue, authority_root: canonical_a)
    assert implementation.description != issue.description
    assert implementation.description =~ "TODO HANDOFF"

    # the same issue resolved against B (which holds no evidence) is unchanged
    assert {:ok, ^issue} = Discovery.implementation_issue(issue, authority_root: canonical_b)
    refute File.dir?(Path.join(canonical_b, ".discovery-results"))
  end

  # -- workspace viability under the pinned root ---------------------------------

  test "workspace viability composes with the pinned root (broken tree fails closed at A)", %{
    root_a: root_a,
    root_b: root_b,
    canonical_a: canonical_a,
    canonical_b: canonical_b
  } do
    source = init_source_repo!(root_a)
    issue = test_issue("v3-viability", "V3V-1")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      poll_interval_ms: 3_600_000,
      workspace_root: root_a,
      routing: %{"targets" => %{"symphony" => %{"source_path" => source}}}
    )

    viable = git_worktree!(source, Path.join(canonical_a, Workspace.workspace_key(issue)), "symphony/#{issue.identifier}", [])

    # a second issue whose workspace is the provably broken --no-checkout tree
    broken_issue = test_issue("v3-viability-broken", "V3V-2")
    broken = git_worktree!(source, Path.join(canonical_a, Workspace.workspace_key(broken_issue)), "symphony/#{broken_issue.identifier}", ["--no-checkout"])

    opts = [workspace_root: canonical_a, configured_workspace_root: root_a]

    # pinned classification: viable → resume, broken → fail closed — all under A
    assert {:ok, :resume, ^viable, _route} = Workspace.classify_candidate(issue, nil, opts)
    assert {:error, {:workspace_not_viable, ^broken, :never_checked_out}} = Workspace.classify_candidate(broken_issue, nil, opts)

    # after the drift, live-config classification resolves under B (fresh),
    # never re-targeting A's workspaces
    reload_root_to_b!(root_b)

    assert {:ok, :fresh, fresh_path, _route} = Workspace.classify_candidate(issue, nil)
    assert String.starts_with?(Path.expand(fresh_path), Path.expand(canonical_b))
    assert File.exists?(viable)
  end

  # -- detached cleanup watcher: drift + authority loss --------------------------

  test "detached cleanup watcher stays rooted at A across an A→B reload", %{
    root_a: root_a,
    root_b: root_b,
    canonical_a: canonical_a
  } do
    {issue, workspace, identity, root_opts} = watcher_fixture(root_a, canonical_a)
    holder = acquire_holder!(root_a)

    Orchestrator.spawn_fenced_cleanup_wait_for_test(
      issue,
      %{workspace_path: workspace, worker_host: nil, workspace_root: canonical_a},
      issue.id,
      root_opts
    )

    reload_root_to_b!(root_b)

    # the drain proof arrives under A after the reload
    write_receipt!(identity)

    wait_until(5_000, fn ->
      match?({:error, :not_found}, LaunchMarker.read(issue.id, root: canonical_a)) and not File.exists?(workspace)
    end)

    # B was never touched BY THIS LIFECYCLE: this issue's marker file and
    # workspace never resolve under B. (The launches directory itself may be
    # created concurrently by an unrelated unpinned test sharing the VM's
    # global workflow config — fixture isolation, not this runtime's doing.)
    refute File.exists?(marker_path_under(Path.expand(root_b), issue.id))
    refute File.exists?(Path.join(Path.expand(root_b), Workspace.workspace_key(issue)))
    assert :ok = RuntimeLease.release_held(holder)
  end

  test "detached cleanup watcher fails closed after authority loss (lease removed)", %{
    root_a: root_a,
    canonical_a: canonical_a
  } do
    {issue, workspace, identity, root_opts} = watcher_fixture(root_a, canonical_a)
    _holder = acquire_holder!(root_a)

    # the drain watcher is IN FLIGHT — waiting for the death proof — when
    # authority is lost, so its wake-up below exercises the real guard
    :ok = Orchestrator.spawn_fenced_cleanup_wait_for_test(issue, %{workspace_path: workspace, worker_host: nil, workspace_root: canonical_a}, issue.id, root_opts)

    # operator recovery removes the lease while the watcher waits
    assert {:ok, _record} =
             RuntimeLease.force_release(root_a, confirm: true, reason: "v3 authority-loss drill", forced_by: "test", force_active: true)

    assert {:error, :not_found} = RuntimeLease.observe(root_a)

    # the drain proof arrives only AFTER authority was lost
    write_receipt!(identity)

    wait_until(5_000, fn ->
      match?({:ok, :dead}, WorkerFence.confirm_termination_receipt(identity))
    end)

    # give any (forbidden) watcher action ample time to show up
    Process.sleep(500)

    # fail closed: the watcher must not clear the marker or delete the
    # state of a root it can no longer prove authority over
    assert {:ok, _marker} = LaunchMarker.read(issue.id, root: canonical_a)
    assert File.exists?(workspace)

    # control: with authority re-established (same instance identity), the
    # same watcher on the same state succeeds — the guard was the only blocker
    holder2 = acquire_holder!(root_a)

    Orchestrator.spawn_fenced_cleanup_wait_for_test(
      issue,
      %{workspace_path: workspace, worker_host: nil, workspace_root: canonical_a},
      issue.id,
      root_opts
    )

    wait_until(5_000, fn ->
      match?({:error, :not_found}, LaunchMarker.read(issue.id, root: canonical_a)) and not File.exists?(workspace)
    end)

    assert :ok = RuntimeLease.release_held(holder2)
  end

  test "detached cleanup watcher fails closed against a foreign successor lease", %{
    root_a: root_a,
    canonical_a: canonical_a
  } do
    {issue, workspace, identity, root_opts} = watcher_fixture(root_a, canonical_a)
    holder = acquire_holder!(root_a)

    # the drain watcher is IN FLIGHT when the authority transfer happens
    :ok = Orchestrator.spawn_fenced_cleanup_wait_for_test(issue, %{workspace_path: workspace, worker_host: nil, workspace_root: canonical_a}, issue.id, root_opts)

    # the lease is released and a successor runtime (different BEAM identity)
    # acquires the root while the old watcher still waits for the death proof
    assert :ok = RuntimeLease.release_held(holder)
    write_foreign_lease!(root_a)

    write_receipt!(identity)

    wait_until(5_000, fn ->
      match?({:ok, :dead}, WorkerFence.confirm_termination_receipt(identity))
    end)

    # give the woken old watcher ample time to (wrongly) act if the guard leaked
    Process.sleep(500)

    # the old watcher must not act on the successor's root
    assert {:ok, _marker} = LaunchMarker.read(issue.id, root: canonical_a)
    assert File.exists?(workspace)
  end

  # -- PARKED recovery re-enters the pinned launch-marker gate ------------------

  test "a recovery-scheduled retry dispatches through the pinned launch-marker gate", %{
    root_a: root_a,
    root_b: root_b,
    canonical_a: canonical_a
  } do
    issue = test_issue("v3-parked", "V3P-1")
    workspace = workspace_under(root_a, issue)
    identity = new_identity(issue, workspace, canonical_a)

    # the launch marker AppServer would have written, pinned to A: unproven
    assert :ok = LaunchMarker.record(identity, identifier: issue.identifier, attempt_id: 1, root: canonical_a)
    assert {:ok, _marker} = LaunchMarker.read(issue.id, root: canonical_a)

    {:ok, sup} = Task.Supervisor.start_link(name: unique_name("V3ParkedTasks"))

    {:ok, pid} =
      Orchestrator.start_link(
        name: unique_name("V3ParkedOrch"),
        authority_root: canonical_a,
        configured_workspace_root: root_a,
        task_supervisor: sup
      )

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      if Process.alive?(sup), do: Process.exit(sup, :normal)
    end)

    set_tracker_issues([issue])

    # the issue is parked fail-closed on the unproven launch at A, with the
    # durable record at the runtime's record root (the per-test env root)
    inject_parked(pid, issue.id, worker_identity: identity, workspace_path: workspace)
    park_record(issue.id, worker_identity: identity, workspace_path: workspace)

    # configuration drifts to B; recovery must still judge A's evidence
    reload_root_to_b!(root_b)

    # no receipt yet → recovery refused (fence UNKNOWN against A's receipt dir)
    assert {:ok, %{outcome: :rejected_fence_unknown}} =
             Control.request(:recover_parked, %{issue_id: issue.id}, server: pid)

    # the wrapper receipt appears under A → recovery releases the park and
    # schedules the replacement attempt on the existing envelope
    write_receipt!(identity)

    assert {:ok, %{outcome: :recovery_scheduled}} =
             Control.request(:recover_parked, %{issue_id: issue.id}, server: pid)

    state_after = :sys.get_state(pid)
    refute Map.has_key?(state_after.parked, issue.id)
    assert map_size(state_after.retry_attempts) == 1

    # the receipt is removed again BEFORE the retry timer fires: the retry
    # must dispatch through the PINNED gate — reading A's marker with its
    # now-unproven identity — and fail closed there. A gate that had drifted
    # to B would find no marker and admit a second worker.
    assert :ok = File.rm(identity["receipt_path"])
    refute File.exists?(identity["receipt_path"])

    # probe: with the receipt gone, the pinned gate must refuse a dispatch now
    assert {:blocked, :worker_termination_unproven} = LaunchMarker.reuse_gate(issue.id, root: canonical_a)

    delay_ms = RetryPolicy.backoff_delay(2, 300_000, nil)
    deadline = System.monotonic_time(:millisecond) + delay_ms + 15_000

    retried = wait_for_repark(pid, issue.id, deadline)

    # the pinned gate re-parked the issue; the workspace at A is preserved
    assert retried.parked[issue.id].stop_reason == :worker_launch_unproven
    assert {:ok, _marker} = LaunchMarker.read(issue.id, root: canonical_a)
    assert File.exists?(workspace)

    # The re-park above is the pinning proof: a gate that had drifted to B
    # would find no marker there and ADMIT the dispatch instead of re-parking
    # with :worker_launch_unproven, and every A-side assertion above shows the
    # store, record, and workspace stayed at A. (No B-path assertions here:
    # this test seeds the shared memory tracker, so concurrent unpinned test
    # orchestrators may observe this issue and write its workspace/marker
    # under the global config's root — fixture isolation, not this runtime's
    # doing. The tests that do not seed the tracker assert B-untouched
    # directly.)
  end

  # -- status truth: pinned authority root vs desired configured root -----------

  test "snapshot reports authority root A and desired root B truthfully after drift", %{
    root_a: root_a,
    root_b: root_b,
    canonical_a: canonical_a
  } do
    {:ok, sup} = Task.Supervisor.start_link(name: unique_name("V3StatusTasks"))

    orch = unique_name("V3StatusOrch")

    {:ok, pid} =
      Orchestrator.start_link(name: orch, authority_root: canonical_a, configured_workspace_root: root_a, task_supervisor: sup)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      if Process.alive?(sup), do: Process.exit(sup, :normal)
    end)

    assert %{runtime_root: %{drift_detected?: false, restart_required: false}} = Orchestrator.snapshot(orch, 5_000)
    assert %{runtime_root: %{authority_root: pinned, configured_root: configured}} = Orchestrator.snapshot(orch, 5_000)
    assert RuntimeLease.roots_match?(pinned, canonical_a)
    assert RuntimeLease.roots_match?(configured, root_a)

    reload_root_to_b!(root_b)
    assert %{queued: true} = Orchestrator.request_refresh(orch)

    wait_until(5_000, fn ->
      match?(
        %{runtime_root: %{drift_detected?: true, restart_required: true}},
        Orchestrator.snapshot(orch, 5_000)
      )
    end)

    snapshot = Orchestrator.snapshot(orch, 5_000)

    # the mutation root itself never moved
    assert RuntimeLease.roots_match?(snapshot.runtime_root.authority_root, canonical_a)
    assert RuntimeLease.roots_match?(snapshot.runtime_root.configured_root, root_b)
  end

  # -- fixtures and helpers -------------------------------------------------------

  # Records the same durable marker AppServer writes for a contained launch —
  # pinned to A — and returns the parts a watcher scenario needs.
  defp watcher_fixture(root_a, canonical_a) do
    issue = test_issue("v3-watcher", "V3W-1")
    workspace = workspace_under(root_a, issue)
    identity = new_identity(issue, workspace, canonical_a)
    assert :ok = LaunchMarker.record(identity, identifier: issue.identifier, attempt_id: 1, root: canonical_a)

    root_opts = [
      workspace_root: canonical_a,
      configured_workspace_root: root_a,
      fallback_workspace_root: canonical_a,
      fallback_configured_workspace_root: root_a,
      root: canonical_a
    ]

    {issue, workspace, identity, root_opts}
  end

  defp acquire_holder!(root_a) do
    holder = unique_name("V3Holder")

    assert {:ok, _pid} =
             RuntimeLease.acquire_and_hold(name: holder, root: root_a, runtime_supervisor: nil, heartbeat_ms: 3_600_000)

    holder
  end

  defp new_identity(issue, workspace, canonical_a) do
    WorkerContainment.new_identity(
      issue_id: issue.id,
      attempt_id: 1,
      workspace: workspace,
      worker_host: nil,
      authority_root: canonical_a
    )
  end

  defp write_receipt!(identity) do
    File.mkdir_p!(Path.dirname(identity["receipt_path"]))

    receipt = %{
      "schema_version" => 1,
      "launch_id" => identity["launch_id"],
      "tree_drained" => true,
      "terminal_reason" => "HARD_JOB_TERMINATION",
      "termination_mode" => "hard",
      "child_exit_code" => 1
    }

    File.write!(identity["receipt_path"], Jason.encode!(receipt))
    identity["receipt_path"]
  end

  defp write_foreign_lease!(root) do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    lease = %{
      "schema_version" => 1,
      "kind" => "runtime-authority",
      "state_root" => root,
      "instance_id" => String.duplicate("f", 32),
      "owner_token" => String.duplicate("d", 32),
      "os_pid" => "999999",
      "node" => "successor@host",
      "hostname" => "successor-host",
      "started_at" => now,
      "heartbeat_at" => now
    }

    File.mkdir_p!(RuntimeLease.authority_dir(root))
    File.write!(RuntimeLease.authority_path(root), Jason.encode!(lease, pretty: true))
    lease
  end

  defp inject_parked(pid, issue_id, overrides) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    entry =
      Map.merge(
        %{
          issue_id: issue_id,
          identifier: issue_id,
          issue_url: nil,
          failure_class: "PROVIDER_OUTAGE",
          stop_reason: :worker_termination_unconfirmed,
          attempt_count: 1,
          identical_failure_count: 1,
          first_failure_at: now,
          last_failure_at: now,
          error: "worker death could not be proven",
          worker_host: nil,
          workspace_path: nil,
          workspace_root: nil,
          route: :primary,
          primary_failure_count: 0,
          worker_identity: nil,
          termination_expectation: :MANAGED_CONFIRMATION_REQUIRED,
          parked_at: now
        },
        Map.new(overrides)
      )

    :sys.replace_state(pid, fn state ->
      %{state | parked: Map.put(state.parked, issue_id, entry), claimed: MapSet.put(state.claimed, issue_id)}
    end)

    entry
  end

  defp park_record(issue_id, overrides) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    record =
      RetryStore.build_record(%{
        issue_id: issue_id,
        identifier: issue_id,
        status: "parked",
        failure_class: "PROVIDER_OUTAGE",
        attempt_count: 1,
        identical_failure_count: 1,
        first_failure_at: now,
        last_failure_at: now,
        last_error: "worker death could not be proven",
        worker_host: "",
        workspace_path: overrides[:workspace_path] || "",
        workspace_root: overrides[:workspace_root] || "",
        worker_identity: overrides[:worker_identity]
      })

    record = Map.put(record, "stop_reason", "worker_termination_unconfirmed")
    record = Map.put(record, "termination_expectation", "MANAGED_CONFIRMATION_REQUIRED")
    :ok = RetryStore.write_record(retry_store_root_env(), record)
    record
  end

  defp retry_store_root_env, do: Application.fetch_env!(:symphony_elixir, :retry_store_root)

  defp workspace_under(root, issue) do
    path = Path.join(root, Workspace.workspace_key(issue))
    File.mkdir_p!(path)
    File.write!(Path.join(path, "workpad.md"), "v3 pinned workpad\n")
    path
  end

  defp init_source_repo!(root) do
    source = Path.join(root, "v3-source")
    File.mkdir_p!(source)
    git!(["-C", source, "init"])
    git!(["-C", source, "config", "user.email", "test@example.org"])
    git!(["-C", source, "config", "user.name", "Symphony Test"])
    File.write!(Path.join(source, "README.md"), "v3 source\n")
    git!(["-C", source, "add", "."])
    git!(["-C", source, "commit", "-m", "init"])
    source
  end

  defp git_worktree!(source, workspace, branch, extra_args) do
    git!(["-C", source, "worktree", "add" | extra_args] ++ [workspace, "-b", branch])
    workspace
  end

  defp git!(args) do
    {output, 0} = System.cmd("git", args, stderr_to_stdout: true)
    String.trim(output)
  end

  defp inject_discovery!(skill_path) do
    path = Workflow.workflow_file_path()
    body = File.read!(path)

    body =
      if String.contains?(body, "discovery:") do
        body
      else
        String.replace(body, "---", "---" <> chr_nl() <> "discovery:" <> chr_nl() <> "  enabled: true" <> chr_nl() <> "  skill_path: " <> Jason.encode!(skill_path), global: false)
      end

    File.write!(path, body)
    WorkflowStore.force_reload()
    :ok
  end

  defp chr_nl, do: <<10>>

  # This issue's durable marker file as it would resolve under an un-pinned
  # store rooted at `root` — the precise artifact whose absence proves this
  # lifecycle never drifted its marker store to another root.
  defp marker_path_under(root, issue_id) do
    Path.join([root, ".symphony-state", "launches", RetryStore.safe_issue_id(issue_id) <> ".json"])
  end

  defp reload_root_to_b!(root_b, overrides \\ []) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      [tracker_kind: "memory", poll_interval_ms: 3_600_000, workspace_root: root_b, codex_worker_termination_grace_ms: 10_000] ++ overrides
    )
  end

  defp test_issue(id, identifier) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Runtime authority v3 #{identifier}",
      description: "v3 pinning",
      state: "In Progress",
      url: "https://example.org/issues/#{identifier}",
      labels: ["repo:symphony"],
      dispatchable: true
    }
  end

  defp set_tracker_issues(issues) do
    previous = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      else
        Application.put_env(:symphony_elixir, :memory_tracker_issues, previous)
      end
    end)

    :ok
  end

  defp without_retry_store_root_env(fun) do
    previous = Application.get_env(:symphony_elixir, :retry_store_root)
    Application.delete_env(:symphony_elixir, :retry_store_root)

    try do
      fun.()
    after
      if is_nil(previous) do
        Application.delete_env(:symphony_elixir, :retry_store_root)
      else
        Application.put_env(:symphony_elixir, :retry_store_root, previous)
      end
    end
  end

  defp unique_root(label), do: Path.join(System.tmp_dir!(), "#{label}-#{:erlang.unique_integer([:positive])}")

  defp unique_name(label), do: Module.concat(__MODULE__, "#{label}#{System.unique_integer([:positive])}")

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp wait_for_repark(pid, issue_id, deadline) do
    state = :sys.get_state(pid, 60_000)

    if map_size(state.parked) == 1 and state.parked[issue_id][:stop_reason] == :worker_launch_unproven do
      state
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk(
          "retry never re-entered the pinned gate; state: " <>
            inspect(%{parked: state.parked, retry_attempts: Map.new(state.retry_attempts, fn {k, v} -> {k, Map.delete(v, :timer_ref)} end), claimed: MapSet.to_list(state.claimed)})
        )
      end

      Process.sleep(100)
      wait_for_repark(pid, issue_id, deadline)
    end
  end

  defp wait_until(timeout, _fun) when timeout <= 0, do: flunk("condition not met in time")

  defp wait_until(timeout, fun) do
    if fun.() do
      :ok
    else
      Process.sleep(50)
      wait_until(timeout - 50, fun)
    end
  end
end
