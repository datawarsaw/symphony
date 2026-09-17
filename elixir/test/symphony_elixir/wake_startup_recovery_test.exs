defmodule SymphonyElixir.WakeStartupRecoveryTest do
  @moduledoc """
  MIC-10 review-repair regressions: real startup/recovery ordering and
  wake-persistence failure semantics.

  The reviewed candidate attached the wake ledger after the two wake-producing
  startup paths (reconciliation mismatch, retry-record fence verdicts), so
  those observations silently no-opped against a nil ledger, and its bang wake
  Store could raise into the Orchestrator GenServer. These tests drive the real
  `Orchestrator.start_link` init path — not the `*_for_test` seams — so the
  ordering cannot regress silently, and they reproduce persistence failures
  deterministically by occupying the wake-store directory path with a regular
  file (no disk filling, no timers).
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.RepositoryRouter.Route
  alias SymphonyElixir.RetryStore
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Wake.Ledger
  alias SymphonyElixir.Wake.Store
  alias SymphonyElixir.Workflow
  alias SymphonyElixir.Workspace

  @failed_opts [evidence: "class:TRANSIENT_WORKER_FAILURE:attempt:1", attempt_id: "1"]

  describe "real startup ordering: the wake ledger exists before wake producers run" do
    test "retry-record fence_unknown recovery surfaces worker_termination_unconfirmed through real init" do
      root = Application.fetch_env!(:symphony_elixir, :retry_store_root)
      issue_id = "ISS-WAKE-FENCE"

      # A retrying record with no provable worker identity: MIC-223 fails
      # closed to fence_unknown (absence of death evidence is never death),
      # which is exactly the startup path that must observe a wake.
      seed_fence_unknown_retry_record!(root, issue_id, "MT-WAKE-FENCE")

      workspace_root = tmp_root("wake-fence-workspaces")
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: workspace_root)
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      %{orchestrator: orch_name} = start_orchestrator!()
      state = :sys.get_state(Process.whereis(orch_name))

      # The wake survives startup: pending, actionable, and durably recorded.
      assert [%{kind: :worker_termination_unconfirmed, issue_id: ^issue_id, actionable: true}] =
               Ledger.snapshot(state.wake_ledger).pending_actionable

      assert File.exists?(Store.issue_path(root, issue_id))

      {:ok, %{pending: [persisted]}} = Store.read_issue(root, issue_id)
      assert persisted.identity =~ "fence_unknown"

      # Lifecycle authority is unchanged: MIC-223 still parks fail-closed.
      assert MapSet.member?(state.claimed, issue_id)
      assert Map.has_key?(state.parked, issue_id)
      assert state.parked[issue_id].stop_reason == :fence_unknown
    end

    test "startup reconciliation mismatch surfaces eligibility_action_required through real init" do
      test_root = tmp_root("wake-mismatch")

      issue = %Issue{
        id: "issue-wake-mismatch",
        identifier: "MT-WAKE-MISMATCH",
        title: "Wake ordering mismatch issue",
        state: "In Progress",
        labels: ["repo:symphony-runtime"],
        dispatchable: true
      }

      fixture_a = setup_source_fixture!(Path.join(test_root, "repo_a"))
      fixture_b = setup_source_fixture!(Path.join(test_root, "repo_b"))

      shared_workspace_root = Path.join(test_root, "shared_workspaces")
      File.mkdir_p!(shared_workspace_root)

      mismatched_ws = Path.join(shared_workspace_root, Workspace.workspace_key(issue))
      git!(["-C", fixture_b.source_repo, "worktree", "add", mismatched_ws, "-b", "symphony/#{issue.identifier}"])

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: shared_workspace_root,
        routing: %{
          target_label_prefix: "repo:",
          default_branch: "main",
          targets: %{
            "symphony-runtime" => %{source_path: fixture_a.source_repo, remote: fixture_a.remote_repo}
          }
        }
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      root = Application.fetch_env!(:symphony_elixir, :retry_store_root)
      issue_id = issue.id
      %{orchestrator: orch_name} = start_orchestrator!()
      state = :sys.get_state(Process.whereis(orch_name))

      # The reconciliation mismatch wake survives startup and is durable.
      assert [%{kind: :eligibility_action_required, issue_id: ^issue_id, actionable: true}] =
               Ledger.snapshot(state.wake_ledger).pending_actionable

      assert File.exists?(Store.issue_path(root, issue_id))

      # Lifecycle authority is unchanged: mismatch still fails closed to blocked.
      assert Map.has_key?(state.blocked, issue.id)
      assert MapSet.member?(state.claimed, issue.id)
      assert File.dir?(mismatched_ws)
    end
  end

  describe "wake persistence failures are best-effort and never raise" do
    test "wake store write failure returns an error instead of raising" do
      root = wake_store_sabotage!(tmp_root("wake-store-sabotage"))

      assert {:error, _reason} = Store.write_issue(root, "ISS-1", %{pending: [], handled: %{}})
    end

    test "observe survives a degraded store: verdict and in-memory dedup intact, degradation logged, no durable success fabricated" do
      root = wake_store_sabotage!(tmp_root("wake-observe-sabotage"))
      parent = self()

      log =
        capture_log(fn ->
          send(parent, Ledger.observe(Ledger.new(root), :worker_failed, "ISS-1", @failed_opts))
        end)

      assert_received {ledger, {:wake, receipt}}
      assert receipt.actionable
      assert log =~ "Wake persistence degraded"

      assert [%{event_id: event_id}] = Ledger.snapshot(ledger).pending_actionable
      assert event_id == receipt.event_id

      # In-memory dedup stays authoritative; nothing durable is claimed.
      assert {:suppress, _, :duplicate} = Ledger.observe(ledger, :worker_failed, "ISS-1", @failed_opts) |> elem(1)
      refute File.exists?(Store.issue_path(root, "ISS-1"))
    end

    test "orchestrator survives a degraded wake store at startup: lifecycle stays fail-closed, wake stays observable, nothing durable is claimed" do
      root = Application.fetch_env!(:symphony_elixir, :retry_store_root)
      issue_id = "ISS-WAKE-DEGRADED"

      seed_fence_unknown_retry_record!(root, issue_id, "MT-WAKE-DEGRADED")
      wake_store_sabotage!(root)

      workspace_root = tmp_root("wake-degraded-workspaces")
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: workspace_root)
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      parent = self()

      log =
        capture_log(fn ->
          send(parent, start_orchestrator!())
        end)

      assert_received started
      state = :sys.get_state(started.orchestrator_pid)

      # Lifecycle authority is unchanged: fence_unknown still parks fail-closed.
      assert MapSet.member?(state.claimed, issue_id)
      assert Map.has_key?(state.parked, issue_id)
      assert state.parked[issue_id].stop_reason == :fence_unknown

      # The wake is observable in memory but no durable success is fabricated,
      # and the persistence degradation is logged.
      assert [%{kind: :worker_termination_unconfirmed, issue_id: ^issue_id}] =
               Ledger.snapshot(state.wake_ledger).pending_actionable

      refute File.exists?(Store.issue_path(root, issue_id))
      assert log =~ "Wake persistence degraded"

      # The GenServer still processes lifecycle calls.
      assert is_map(Orchestrator.snapshot(started.orchestrator, 5_000))
    end

    test "a wake-store write failure during poll reconciliation does not crash the orchestrator" do
      workspace_root = tmp_root("wake-poll-workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        poll_interval_ms: 120
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      started = start_orchestrator!()
      orch_pid = started.orchestrator_pid

      # One handled and one pending receipt for the same issue, persisted
      # against a healthy store. Retargeted to a degraded store, the next poll
      # reconciles the issue's receipts stale and must attempt the durable
      # stale-write without taking the GenServer down (the reviewed Store
      # raised File.Error right here, killing the callback).
      good_root = tmp_root("wake-poll-good")

      {ledger, {:wake, first}} = Ledger.observe(Ledger.new(good_root), :worker_failed, "ISS-WAKE-POLL", @failed_opts)
      {ledger, :ok} = Ledger.mark_handled(ledger, first.event_id)

      {ledger, {:wake, _second}} =
        Ledger.observe(ledger, :worker_failed, "ISS-WAKE-POLL",
          evidence: "class:TRANSIENT_WORKER_FAILURE:attempt:2",
          attempt_id: "2"
        )

      sabotaged_root = wake_store_sabotage!(tmp_root("wake-poll-sabotaged"))

      :sys.replace_state(orch_pid, fn state -> %{state | wake_ledger: %{ledger | root: sabotaged_root}} end)
      assert :sys.get_state(orch_pid).wake_ledger.root == sabotaged_root

      log = capture_log(fn -> Process.sleep(1_200) end)

      # The Orchestrator survived and lifecycle processing still responds.
      assert Process.alive?(orch_pid)
      assert is_map(Orchestrator.snapshot(started.orchestrator, 5_000))

      # The failure is observable, and no durable success was fabricated.
      assert log =~ "Wake persistence degraded"
      refute File.exists?(Store.issue_path(sabotaged_root, "ISS-WAKE-POLL"))
    end
  end

  describe "startup fail-open for unreadable wake state" do
    test "corrupt wake records fail open at startup: orchestrator starts, ledger empty, nothing fabricated" do
      root = Application.fetch_env!(:symphony_elixir, :retry_store_root)
      wakes_dir = Path.join([root, ".symphony-state", "wakes"])
      File.mkdir_p!(wakes_dir)
      File.write!(Path.join(wakes_dir, "broken.json"), "{not json at all")
      File.write!(Path.join(wakes_dir, "wrong-schema.json"), Jason.encode!(%{"schema_version" => 99, "pending" => []}))

      workspace_root = tmp_root("wake-corrupt-workspaces")
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: workspace_root)
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      %{orchestrator: orch_name} = start_orchestrator!()
      state = :sys.get_state(Process.whereis(orch_name))

      # Fail-open observability: startup proceeds with an empty ledger and no
      # fabricated handled state; the corrupt records were skipped, not minted.
      assert %Ledger{} = state.wake_ledger
      snapshot = Ledger.snapshot(state.wake_ledger)
      assert snapshot.pending_actionable == []
      assert snapshot.pending_decisions == []
      assert snapshot.handled_count == 0

      # Lifecycle processing still responds.
      assert is_map(Orchestrator.snapshot(orch_name, 5_000))
    end
  end

  defp build_fence_unknown_record(root, issue_id, identifier) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    RetryStore.build_record(%{
      issue_id: issue_id,
      identifier: identifier,
      status: "retrying",
      failure_class: "TRANSIENT_WORKER_FAILURE",
      attempt_count: 1,
      identical_failure_count: 1,
      first_failure_at: now,
      last_failure_at: now,
      last_error: "restart fence check",
      workspace_root: root
      # worker_identity defaults to nil: WorkerFence.confirm_dead(nil) is
      # {:error, :unknown}, the fail-closed fence_unknown park path.
    })
  end

  defp seed_fence_unknown_retry_record!(root, issue_id, identifier) do
    record = build_fence_unknown_record(root, issue_id, identifier)
    :ok = RetryStore.write_record(root, record)
    root
  end

  # Occupies the wake-store directory path with a regular file: reads fail
  # open, and (repaired) writes degrade to `{:error, reason}` instead of
  # raising. Deterministic on every host; nothing fills a disk.
  defp wake_store_sabotage!(root) do
    File.mkdir_p!(Path.join([root, ".symphony-state"]))
    File.write!(Path.join([root, ".symphony-state", "wakes"]), "occupied by a regular file")
    root
  end

  defp tmp_root(name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "wake-startup-recovery-#{name}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp start_orchestrator! do
    orchestrator_name = Module.concat(__MODULE__, "WakeOrch#{System.unique_integer([:positive])}")
    task_sup_name = Module.concat(__MODULE__, "WakeTaskSup#{System.unique_integer([:positive])}")

    {:ok, task_sup} = Task.Supervisor.start_link(name: task_sup_name)
    {:ok, orch_pid} = Orchestrator.start_link(name: orchestrator_name, task_supervisor: task_sup_name)

    on_exit(fn ->
      try do
        if pid = Process.whereis(orchestrator_name) do
          if Process.alive?(pid), do: GenServer.stop(pid)
        end
      catch
        :exit, _ -> :ok
      end

      try do
        if Process.alive?(task_sup), do: GenServer.stop(task_sup)
      catch
        :exit, _ -> :ok
      end
    end)

    %{orchestrator: orchestrator_name, orchestrator_pid: orch_pid, task_supervisor: task_sup}
  end

  defp setup_source_fixture!(test_root) do
    remote_repo = Path.join(test_root, "remote.git") |> String.replace("\\", "/")
    source_repo = Path.join(test_root, "source") |> String.replace("\\", "/")
    workspace_root = Path.join(test_root, "workspaces")

    git!(["init", "--bare", remote_repo])
    git!(["init", "-b", "main", source_repo])
    git!(["-C", source_repo, "config", "user.name", "Test User"])
    git!(["-C", source_repo, "config", "user.email", "test@example.com"])
    File.write!(Path.join(source_repo, "README.md"), "initial content\n")
    git!(["-C", source_repo, "add", "README.md"])
    git!(["-C", source_repo, "commit", "-m", "initial commit"])
    git!(["-C", source_repo, "remote", "add", "origin", remote_repo])
    git!(["-C", source_repo, "push", "-u", "origin", "main"])

    initial_commit = get_head_sha(source_repo)
    git!(["-C", remote_repo, "symbolic-ref", "HEAD", "refs/heads/main"])

    route = %Route{
      target: "symphony-runtime",
      source_path: source_repo,
      remote: remote_repo,
      default_branch: "main"
    }

    %{
      initial_commit: initial_commit,
      remote_repo: remote_repo,
      route: route,
      source_repo: source_repo,
      workspace_root: workspace_root
    }
  end

  defp git!(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, code} -> flunk("git #{Enum.join(args, " ")} failed (#{code}): #{output}")
    end
  end

  defp get_head_sha(repo_path) do
    {sha, 0} = System.cmd("git", ["-c", "safe.directory=#{repo_path}", "-C", repo_path, "rev-parse", "HEAD"])
    String.trim(sha)
  end
end
