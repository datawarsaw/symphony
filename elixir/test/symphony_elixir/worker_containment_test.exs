defmodule SymphonyElixir.WorkerContainmentTest do
  use SymphonyElixir.TestSupport

  @moduledoc """
  MIC-223 Phase 21: worker identity contract, termination receipt parsing and
  classification, positive-death gating, AppServer integration, WorkerFence
  receipt verification, RetryStore identity persistence, and MIC-224 restart
  reconciliation compatibility. Non-process tests run on every platform; the
  containment integration tests are Windows-only by design.
  """

  alias SymphonyElixir.RetryStore
  alias SymphonyElixir.WorkerContainment
  alias SymphonyElixir.WorkerFence

  @windows? match?({:win32, _}, :os.type())

  # ---------------------------------------------------------------------------
  # Identity contract
  # ---------------------------------------------------------------------------

  test "worker identity carries the bounded fields and a managed receipt path" do
    receipts = tmp_receipt_root()
    Application.put_env(:symphony_elixir, :worker_termination_receipt_root, receipts)

    try do
      identity =
        WorkerContainment.new_identity(
          issue_id: "issue-1",
          attempt_id: "attempt-1",
          workspace: "C:/tmp/ws",
          worker_host: nil
        )

      assert identity["schema_version"] == 1
      assert identity["issue_id"] == "issue-1"
      assert identity["attempt_id"] == "attempt-1"
      assert identity["workspace"] == "C:/tmp/ws"
      assert identity["worker_host"] == nil
      assert identity["root_pid"] == nil
      assert is_binary(identity["launch_id"])
      assert identity["receipt_path"] |> Path.dirname() |> canonical() == canonical(receipts)

      # Identities are unique per launch.
      second = WorkerContainment.new_identity(issue_id: "issue-1", workspace: "C:/tmp/ws")
      refute second["launch_id"] == identity["launch_id"]
    after
      Application.delete_env(:symphony_elixir, :worker_termination_receipt_root)
      File.rm_rf(receipts)
    end
  end

  test "launch_args pass wrapper options before the absolute child command" do
    receipts = tmp_receipt_root()
    Application.put_env(:symphony_elixir, :worker_termination_receipt_root, receipts)

    try do
      identity = WorkerContainment.new_identity(issue_id: "i", workspace: "C:/tmp/ws", worker_host: nil)

      args =
        WorkerContainment.launch_args(identity, "C:/Program Files/Git/bin/bash.exe", [
          "-lc",
          "exec codex app-server"
        ])

      args = Enum.map(args, &to_string/1)
      separator_index = Enum.find_index(args, &(&1 == "--"))

      # `--` separates wrapper options from the child command vector.
      assert Enum.count(args, &(&1 == "--")) == 1

      assert Enum.take(args, separator_index + 1) ==
               ["--grace-ms", Integer.to_string(WorkerContainment.grace_ms()), "--receipt", identity["receipt_path"], "--launch-id", identity["launch_id"], "--"]

      assert Enum.drop(args, separator_index + 1) == [
               "C:/Program Files/Git/bin/bash.exe",
               "-lc",
               "exec codex app-server"
             ]
    after
      Application.delete_env(:symphony_elixir, :worker_termination_receipt_root)
      File.rm_rf(receipts)
    end
  end

  # ---------------------------------------------------------------------------
  # Receipt parsing + classification
  # ---------------------------------------------------------------------------

  defp write_receipt(dir, launch_id, overrides \\ %{}) do
    File.mkdir_p!(dir)
    path = Path.join(dir, launch_id <> ".json")

    receipt =
      Map.merge(
        %{
          "schema_version" => 1,
          "launch_id" => launch_id,
          "wrapper_pid" => 111,
          "root_pid" => 222,
          "root_creation_time" => "2026-09-15T10:00:00.000Z",
          "started_at" => "2026-09-15T10:00:00.000Z",
          "termination_requested_at" => "2026-09-15T10:00:01.000Z",
          "root_exited_at" => "2026-09-15T10:00:02.000Z",
          "tree_drained_at" => "2026-09-15T10:00:02.100Z",
          "termination_mode" => "stdin_eof_terminate",
          "tree_drained" => true,
          "child_exit_code" => 253,
          "wrapper_status" => "ok",
          "terminal_reason" => "HARD_JOB_TERMINATION"
        },
        overrides
      )

    File.write!(path, Jason.encode!(receipt))
    path
  end

  test "valid receipt parses and classifies as TERMINATED_CONFIRMED" do
    dir = tmp_receipt_root()

    try do
      path = write_receipt(dir, "ok")
      assert {:ok, receipt} = WorkerContainment.parse_receipt(path)
      assert WorkerContainment.classify_receipt(receipt) == :TERMINATED_CONFIRMED
    after
      File.rm_rf(dir)
    end
  end

  test "missing, unreadable, and malformed receipts fail closed" do
    dir = tmp_receipt_root()

    try do
      assert {:error, {:receipt_unreadable, :enoent}} =
               WorkerContainment.parse_receipt(Path.join(dir, "nope.json"))

      File.mkdir_p!(dir)
      bad_json = Path.join(dir, "bad.json")
      File.write!(bad_json, "{not json")
      assert {:error, {:malformed_receipt, _}} = WorkerContainment.parse_receipt(bad_json)

      wrong_schema = write_receipt(dir, "wrong_schema", %{"schema_version" => 2})
      assert {:error, {:malformed_receipt, :invalid_receipt_shape}} = WorkerContainment.parse_receipt(wrong_schema)

      no_drain_flag = write_receipt(dir, "no_flag", %{"tree_drained" => "yes"})
      assert {:error, {:malformed_receipt, :invalid_receipt_shape}} = WorkerContainment.parse_receipt(no_drain_flag)
    after
      File.rm_rf(dir)
    end
  end

  test "tree_drained false is TERMINATION_UNCONFIRMED even for natural exit" do
    # ROOT_EXITED != TERMINATED_CONFIRMED.
    assert WorkerContainment.classify_receipt(%{"tree_drained" => false, "terminal_reason" => "NATURAL_EXIT"}) ==
             :TERMINATION_UNCONFIRMED

    assert WorkerContainment.classify_receipt(%{"tree_drained" => true, "terminal_reason" => "WRAPPER_FAILURE"}) ==
             :TERMINATION_UNCONFIRMED

    assert WorkerContainment.classify_receipt(%{
             "tree_drained" => true,
             "terminal_reason" => "TERMINATION_UNCONFIRMED"
           }) == :TERMINATION_UNCONFIRMED

    assert WorkerContainment.classify_receipt(%{"tree_drained" => true, "terminal_reason" => "NATURAL_EXIT"}) ==
             :TERMINATED_CONFIRMED

    assert WorkerContainment.classify_receipt(%{"tree_drained" => true, "terminal_reason" => "COOPERATIVE_EXIT"}) ==
             :TERMINATED_CONFIRMED
  end

  # ---------------------------------------------------------------------------
  # Receipt-backed identity verification (WorkerFence evidence path)
  # ---------------------------------------------------------------------------

  defp identity_for(path, launch_id) do
    %{
      "schema_version" => 1,
      "launch_id" => launch_id,
      "issue_id" => "issue-1",
      "attempt_id" => nil,
      "workspace" => "C:/tmp/ws",
      "worker_host" => nil,
      "root_pid" => nil,
      "root_creation_time" => nil,
      "receipt_path" => path
    }
  end

  test "verify_identity_receipt proves death only for managed, matching, proven receipts" do
    receipts = tmp_receipt_root()
    Application.put_env(:symphony_elixir, :worker_termination_receipt_root, receipts)

    try do
      path = write_receipt(receipts, "launch-ok")

      assert WorkerContainment.verify_identity_receipt(identity_for(path, "launch-ok")) == {:ok, :dead}
      assert WorkerFence.confirm_termination_receipt(identity_for(path, "launch-ok")) == {:ok, :dead}

      # launch id binding: a receipt for another launch never proves this death
      assert WorkerContainment.verify_identity_receipt(identity_for(path, "launch-other")) == {:error, :unknown}

      # a receipt that did not prove the drain is UNKNOWN
      unproven = write_receipt(receipts, "launch-unproven", %{"tree_drained" => false})
      assert WorkerContainment.verify_identity_receipt(identity_for(unproven, "launch-unproven")) == {:error, :unknown}

      # receipt paths outside the managed directory never verify
      outside_dir = Path.join(System.tmp_dir!(), "mic223-outside-#{System.unique_integer([:positive])}")
      outside = write_receipt(outside_dir, "outside")
      assert WorkerContainment.verify_identity_receipt(identity_for(outside, "outside")) == {:error, :unknown}
      File.rm_rf(outside_dir)

      # missing/malformed receipts are UNKNOWN
      assert WorkerContainment.verify_identity_receipt(identity_for(Path.join(receipts, "gone.json"), "gone")) ==
               {:error, :unknown}

      # pid-only identities keep the legacy fence behavior
      assert WorkerContainment.verify_identity_receipt("pid-string") == {:error, :unknown}
      assert WorkerContainment.verify_identity_receipt(nil) == {:error, :unknown}
    after
      Application.delete_env(:symphony_elixir, :worker_termination_receipt_root)
      File.rm_rf(receipts)
    end
  end

  # ---------------------------------------------------------------------------
  # Reuse gate
  # ---------------------------------------------------------------------------

  test "reuse gate without a managed identity keeps legacy semantics" do
    assert WorkerContainment.reuse_gate(nil, nil) == :allowed
    assert WorkerContainment.reuse_gate(%{status: :NOT_APPLICABLE}, nil) == :allowed
    assert WorkerContainment.reuse_gate(%{status: :TERMINATED_CONFIRMED}, nil) == :allowed

    assert WorkerContainment.reuse_gate(%{status: :TERMINATION_UNCONFIRMED, receipt: nil}, nil) ==
             {:blocked, :worker_termination_unconfirmed}
  end

  test "reuse gate with a managed identity allows only positive confirmation" do
    identity = %{"launch_id" => "l-1", "receipt_path" => Path.join(tmp_receipt_root(), "l-1.json")}

    assert WorkerContainment.reuse_gate(%{status: :TERMINATED_CONFIRMED, receipt: %{}, exit_code: 0}, identity) ==
             :allowed

    # Missing, unconfirmed, not-applicable, and malformed evidence all fail
    # closed while a managed worker termination is expected.
    assert WorkerContainment.reuse_gate(nil, identity) == {:blocked, :worker_termination_unconfirmed}

    assert WorkerContainment.reuse_gate(%{status: :TERMINATION_UNCONFIRMED, receipt: nil}, identity) ==
             {:blocked, :worker_termination_unconfirmed}

    assert WorkerContainment.reuse_gate(%{status: :NOT_APPLICABLE}, identity) ==
             {:blocked, :worker_termination_unconfirmed}

    assert WorkerContainment.reuse_gate(%{}, identity) == {:blocked, :worker_termination_unconfirmed}
    assert WorkerContainment.reuse_gate(%{status: :SOMETHING_ELSE}, identity) == {:blocked, :worker_termination_unconfirmed}
    assert WorkerContainment.reuse_gate("garbage", identity) == {:blocked, :worker_termination_unconfirmed}
  end

  test "reuse gate fails closed on malformed evidence without a managed identity" do
    assert WorkerContainment.reuse_gate(%{}, nil) == {:blocked, :worker_termination_unconfirmed}
    assert WorkerContainment.reuse_gate(%{status: :NOT_A_REAL_STATUS}, nil) == {:blocked, :worker_termination_unconfirmed}
    assert WorkerContainment.reuse_gate("garbage", nil) == {:blocked, :worker_termination_unconfirmed}
    assert WorkerContainment.reuse_gate(42, nil) == {:blocked, :worker_termination_unconfirmed}
  end

  # ---------------------------------------------------------------------------
  # Wrapper liveness probe (fail-closed tri-state)
  # ---------------------------------------------------------------------------

  defp with_tasklist_probe(fun, test_fun) do
    Application.put_env(:symphony_elixir, :worker_containment_tasklist_probe, fun)

    try do
      test_fun.()
    after
      Application.delete_env(:symphony_elixir, :worker_containment_tasklist_probe)
    end
  end

  @os_pid 424_242

  test "tasklist non-zero exit is unknown, never gone" do
    with_tasklist_probe(fn _args -> {"ERROR: The RPC server is unavailable.", 1726} end, fn ->
      assert WorkerContainment.wrapper_liveness(@os_pid) == :unknown
    end)
  end

  test "tasklist command exception is unknown, never gone" do
    with_tasklist_probe(
      fn _args -> raise ErlangError, message: "enoent" end,
      fn ->
        assert WorkerContainment.wrapper_liveness(@os_pid) == :unknown
      end
    )
  end

  test "malformed tasklist output is unknown, never gone" do
    # Exit 0 with no output at all is anomalous: tasklist always writes rows
    # or a no-match message.
    with_tasklist_probe(fn _args -> {"", 0} end, fn ->
      assert WorkerContainment.wrapper_liveness(@os_pid) == :unknown
    end)

    # CSV rows that do not carry the probed PID mean the filter was mangled.
    with_tasklist_probe(fn _args -> {"\"unrelated.exe\",\"99\",\"Console\",1", 0} end, fn ->
      assert WorkerContainment.wrapper_liveness(@os_pid) == :unknown
    end)
  end

  test "tasklist exit 0 classifies presence and absence positively" do
    with_tasklist_probe(fn _args -> {"\"worker.exe\",\"#{@os_pid}\",\"Console\",1", 0} end, fn ->
      assert WorkerContainment.wrapper_liveness(@os_pid) == :alive
    end)

    with_tasklist_probe(fn _args -> {"INFO: No tasks are running which match the specified criteria.", 0} end, fn ->
      assert WorkerContainment.wrapper_liveness(@os_pid) == :gone
    end)

    assert WorkerContainment.wrapper_liveness(nil) == :unknown
    assert WorkerContainment.wrapper_liveness("not-a-pid") == :unknown
  end

  test "unprovable wrapper liveness reaches the bounded deadline and stays unconfirmed" do
    # A missing receipt and a probe that cannot classify liveness must never
    # infer death: the wait runs to its bounded deadline and the stop stays
    # TERMINATION_UNCONFIRMED.
    port = Port.open({:spawn, "cmd /c exit 0"}, [:binary])

    identity = %{
      "launch_id" => "l-probe-timeout",
      "receipt_path" => Path.join(tmp_receipt_root(), "never-written.json"),
      "wrapper_pid" => "999999999"
    }

    original_budget = Application.get_env(:symphony_elixir, :worker_termination_hard_budget_ms)
    original_probe = Application.get_env(:symphony_elixir, :worker_containment_tasklist_probe)

    Application.put_env(:symphony_elixir, :worker_termination_hard_budget_ms, 50)
    Application.put_env(:symphony_elixir, :worker_containment_tasklist_probe, fn _args -> {"", 1} end)

    try do
      confirmation = WorkerContainment.stop_and_confirm(port, identity, 1)

      assert %{status: :TERMINATION_UNCONFIRMED, receipt: nil, exit_code: nil} = confirmation
      assert confirmation.reason == :termination_wait_timeout
    after
      restore_app_env(:worker_termination_hard_budget_ms, original_budget)
      restore_app_env(:worker_containment_tasklist_probe, original_probe)
      File.rm_rf(identity["receipt_path"] |> Path.dirname())
    end
  end

  defp restore_app_env(key, value) do
    if value == nil do
      Application.delete_env(:symphony_elixir, key)
    else
      Application.put_env(:symphony_elixir, key, value)
    end
  end

  # ---------------------------------------------------------------------------
  # Helper resolution (deterministic build contract)
  # ---------------------------------------------------------------------------

  if @windows? do
    test "helper resolves after the deterministic build" do
      assert {:ok, exe} = WorkerContainment.helper_path()
      assert String.ends_with?(exe, "jobrun.exe")
      assert File.exists?(exe <> ".sha256")
    end

    test "missing or unverified helper fails visibly" do
      missing_dir = tmp_receipt_root()
      File.mkdir_p!(missing_dir)

      try do
        Application.put_env(:symphony_elixir, :jobrun_helper_path, Path.join(missing_dir, "nope.exe"))
        assert {:error, {:jobrun_helper_missing, _}} = WorkerContainment.helper_path()

        unverified = Path.join(missing_dir, "nohash.exe")
        File.write!(unverified, "not a real helper")
        Application.put_env(:symphony_elixir, :jobrun_helper_path, unverified)

        assert {:error, {:jobrun_helper_unverified, _}} = WorkerContainment.helper_path()
      after
        Application.delete_env(:symphony_elixir, :jobrun_helper_path)
        File.rm_rf(missing_dir)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # AppServer integration (contained local launch, Windows only)
  # ---------------------------------------------------------------------------

  @fake_codex """
  #!/bin/sh
  count=0
  while IFS= read -r line; do
    count=$((count + 1))
    case "$count" in
      1) printf '%s\\n' '{"id":1,"result":{}}' ;;
      2) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-mic223"}}}' ;;
      *) exit 0 ;;
    esac
  done
  """

  if @windows? do
    test "contained launch carries worker identity and stop yields TERMINATED_CONFIRMED" do
      test_root = Path.join(System.tmp_dir!(), "mic223-appserver-#{System.unique_integer([:positive])}")

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "MIC223-WS")
        codex_binary = Path.join(test_root, "fake-codex")
        File.mkdir_p!(workspace)
        File.write!(codex_binary, @fake_codex)
        File.chmod!(codex_binary, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          codex_command: "#{String.replace(codex_binary, "\\", "/")} app-server"
        )

        issue = %Issue{id: "issue-mic223", identifier: "MIC-223", title: "Containment", state: "In Progress"}

        {:ok, session} = AppServer.start_session(workspace, issue: issue)
        identity = session.worker_identity
        assert is_map(identity)
        assert identity["issue_id"] == "issue-mic223"
        assert String.to_integer(identity["wrapper_pid"]) > 0

        confirmation = AppServer.stop_session(session)
        assert %{status: :TERMINATED_CONFIRMED} = confirmation
        assert confirmation.receipt["tree_drained"] == true
        assert confirmation.receipt["launch_id"] == identity["launch_id"]
        assert File.exists?(identity["receipt_path"])
      after
        File.rm_rf(test_root)
      end
    end

    test "missing helper fails the AppServer launch visibly instead of falling back" do
      test_root = Path.join(System.tmp_dir!(), "mic223-appserver-#{System.unique_integer([:positive])}")

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "MIC223-NOHELPER")
        File.mkdir_p!(workspace)

        write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

        Application.put_env(:symphony_elixir, :jobrun_helper_path, Path.join(test_root, "missing-jobrun.exe"))

        issue = %Issue{id: "issue-mic223b", identifier: "MIC-223B", title: "No helper", state: "In Progress"}

        assert {:error, {:jobrun_helper_missing, _}} = AppServer.start_session(workspace, issue: issue)
      after
        Application.delete_env(:symphony_elixir, :jobrun_helper_path)
        File.rm_rf(test_root)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # RetryStore identity round-trip
  # ---------------------------------------------------------------------------

  test "RetryStore persists the worker identity through a write/read round-trip" do
    root = Path.join(System.tmp_dir!(), "mic223-retrystore-#{System.unique_integer([:positive])}")

    try do
      identity = identity_for(Path.join([root, ".symphony-state", "worker-terminations", "l1.json"]), "l1")

      record =
        RetryStore.build_record(%{
          issue_id: "issue-rt",
          status: "retrying",
          failure_class: "TRANSIENT_WORKER_FAILURE",
          worker_identity: identity
        })

      RetryStore.write_record(root, record)

      assert {:ok, read_back} = RetryStore.read_record(root, "issue-rt")
      assert read_back["worker_identity"] == identity
      assert read_back["worker_identity"]["receipt_path"] == identity["receipt_path"]
    after
      File.rm_rf(root)
    end
  end

  # ---------------------------------------------------------------------------
  # Orchestrator: evidence handling, retry gate, restart reconciliation
  # ---------------------------------------------------------------------------

  defp base_running_entry(issue, workspace_root, worker_termination, worker_identity) do
    %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      worker_host: nil,
      workspace_path: Path.join(workspace_root, issue.identifier),
      workspace_root: workspace_root,
      session_id: nil,
      resumed: false,
      started_at: DateTime.utc_now(),
      worker_termination: worker_termination,
      worker_identity: worker_identity
    }
  end

  defp workflow_issue(identifier) do
    %Issue{id: "issue-#{identifier}", identifier: identifier, title: identifier, state: "In Progress"}
  end

  test "worker_termination evidence lands on the running entry" do
    root = workflow_test_root()

    try do
      write_test_workflow!(root)
      issue = workflow_issue("MT-TERM")
      state = %Orchestrator.State{task_supervisor: SymphonyElixir.TaskSupervisor}
      state = %{state | running: Map.put(state.running, issue.id, base_running_entry(issue, root, nil, nil))}

      {:noreply, state} =
        Orchestrator.handle_info(
          {:worker_termination, issue.id,
           %{
             worker_identity: %{"launch_id" => "l-1"},
             worker_termination: %{status: :TERMINATION_UNCONFIRMED, receipt: nil, exit_code: 253}
           }},
          state
        )

      entry = state.running[issue.id]
      assert %{status: :TERMINATION_UNCONFIRMED, exit_code: 253} = entry.worker_termination
      assert entry.worker_identity == %{"launch_id" => "l-1"}
    after
      File.rm_rf(root)
    end
  end

  test "retry with unconfirmed termination parks fail-closed with claim and no timer" do
    root = workflow_test_root()

    try do
      write_test_workflow!(root)
      pin_retry_store_root!(root)
      issue = workflow_issue("MT-UNCONF")
      state = %Orchestrator.State{task_supervisor: SymphonyElixir.TaskSupervisor}

      identity = identity_for(Path.join(root, "l-unconf.json"), "l-unconf")

      entry =
        base_running_entry(issue, root, %{status: :TERMINATION_UNCONFIRMED, receipt: nil, exit_code: nil}, identity)

      reason = failure_reason()

      state = Orchestrator.handle_failure_for_test(state, issue.id, entry, "sess-1", reason)

      assert MapSet.member?(state.claimed, issue.id)
      assert %{stop_reason: :worker_termination_unconfirmed} = state.parked[issue.id]
      assert state.retry_attempts == %{}

      # The parked record preserves the worker identity for reconciliation.
      assert {:ok, record} = RetryStore.read_record(root, issue.id)
      assert record["status"] == "parked"
      assert record["worker_identity"]["launch_id"] == "l-unconf"
    after
      File.rm_rf(root)
    end
  end

  test "missing termination evidence with a known managed identity parks fail-closed" do
    root = workflow_test_root()

    try do
      write_test_workflow!(root)
      pin_retry_store_root!(root)
      issue = workflow_issue("MT-NOEVID")
      state = %Orchestrator.State{task_supervisor: SymphonyElixir.TaskSupervisor}

      identity = identity_for(Path.join(root, "l-noevid.json"), "l-noevid")

      # Evidence never arrived (for example a stop-path crash); the managed
      # identity on the running entry must force the closed verdict.
      entry = base_running_entry(issue, root, nil, identity)

      state = Orchestrator.handle_failure_for_test(state, issue.id, entry, "sess-1", failure_reason())

      assert MapSet.member?(state.claimed, issue.id)
      assert %{stop_reason: :worker_termination_unconfirmed} = state.parked[issue.id]
      assert state.retry_attempts == %{}

      assert {:ok, record} = RetryStore.read_record(root, issue.id)
      assert record["status"] == "parked"
      assert record["worker_identity"]["launch_id"] == "l-noevid"
    after
      File.rm_rf(root)
    end
  end

  test "failure without a managed identity or evidence keeps the retry path" do
    root = workflow_test_root()

    try do
      write_test_workflow!(root)
      pin_retry_store_root!(root)
      issue = workflow_issue("MT-NOIDENT")
      state = %Orchestrator.State{task_supervisor: SymphonyElixir.TaskSupervisor}

      # Neither evidence nor a managed identity: the launch never carried
      # containment (for example a pre-session failure), so the MIC-195 retry
      # semantics are unchanged.
      entry = base_running_entry(issue, root, nil, nil)

      state = Orchestrator.handle_failure_for_test(state, issue.id, entry, "sess-1", failure_reason())

      assert Map.fetch!(state.retry_attempts, issue.id)
      refute MapSet.member?(state.claimed, issue.id)
      assert state.parked == %{}
    after
      File.rm_rf(root)
    end
  end

  test "restart reconciliation: proven receipt schedules retry, missing receipt parks" do
    root = workflow_test_root()

    try do
      write_test_workflow!(root)
      pin_retry_store_root!(root)

      receipts_dir = WorkerContainment.receipt_dir()
      File.mkdir_p!(receipts_dir)
      proven_path = write_receipt(receipts_dir, "restart-ok")

      proven_record =
        RetryStore.build_record(%{
          issue_id: "issue-restart-ok",
          status: "retrying",
          failure_class: "TRANSIENT_WORKER_FAILURE",
          attempt_count: 1,
          first_failure_at: DateTime.utc_now() |> DateTime.add(-1_000, :millisecond) |> DateTime.to_iso8601(),
          worker_identity: identity_for(proven_path, "restart-ok")
        })

      RetryStore.write_record(root, proven_record)

      unproven_record =
        RetryStore.build_record(%{
          issue_id: "issue-restart-lost",
          status: "retrying",
          failure_class: "TRANSIENT_WORKER_FAILURE",
          attempt_count: 1,
          first_failure_at: DateTime.utc_now() |> DateTime.add(-1_000, :millisecond) |> DateTime.to_iso8601(),
          worker_identity: identity_for(Path.join(receipts_dir, "lost.json"), "restart-lost")
        })

      RetryStore.write_record(root, unproven_record)

      state = %Orchestrator.State{task_supervisor: SymphonyElixir.TaskSupervisor}
      state = Orchestrator.recover_retry_records_for_test(state)

      # Proven death: the issue is scheduled for retry (timer armed).
      assert state.retry_attempts["issue-restart-ok"]

      # Receipt lost: no fabricated death; fail closed to parked with claim.
      assert %{stop_reason: :fence_unknown} = state.parked["issue-restart-lost"]
      assert MapSet.member?(state.claimed, "issue-restart-lost")
    after
      File.rm_rf(root)
    end
  end

  # -- helpers --------------------------------------------------------------

  defp failure_reason do
    try do
      raise "boom"
    rescue
      e -> {e, __STACKTRACE__}
    end
  end

  # Windows drive-letter case is insignificant when comparing canonical paths.
  defp canonical(path) when is_binary(path) do
    path |> Path.expand() |> String.downcase()
  end

  defp tmp_receipt_root do
    Path.join(System.tmp_dir!(), "mic223-receipts-#{System.unique_integer([:positive])}")
  end

  defp workflow_test_root do
    Path.join(System.tmp_dir!(), "mic223-orchestrator-#{System.unique_integer([:positive])}")
  end

  defp write_test_workflow!(root) do
    File.mkdir_p!(root)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: root,
      tracker_kind: "memory",
      tracker_active_states: ["In Progress"],
      tracker_terminal_states: ["Closed"]
    )
  end

  # Recovery and record writes must target this test's own workspace root, not
  # the run-wide retry store root configured for the test environment.
  defp pin_retry_store_root!(root) do
    original = Application.get_env(:symphony_elixir, :retry_store_root)
    Application.put_env(:symphony_elixir, :retry_store_root, root)
    on_exit(fn -> Application.put_env(:symphony_elixir, :retry_store_root, original) end)
  end
end
