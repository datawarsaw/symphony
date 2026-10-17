defmodule SymphonyElixir.BeamDeathRecoveryTest do
  use SymphonyElixir.TestSupport

  @moduledoc """
  M1-BEAM-T: real parent-BEAM death and recovery evidence.

  The existing containment suites prove the launch-marker / termination-receipt
  fence against simulated interruption and helper crash, but they stop short of
  actually halting the BEAM that owns a worker. `worker_containment_helper_test.exs`
  calls that out explicitly: "the BEAM-owner-crash case lives in the Windows host
  proof, not here, because it requires halting a separate BEAM".

  This suite closes that gap. It boots a *separate* OS BEAM (plain `elixir`, no
  `mix`) under a bounded controller, has it record a durable launch marker and
  start a contained mock worker through the production `jobrun` wrapper, then
  terminates only that isolated test VM and boots a second independent BEAM that
  recomputes the fence over the same authority root.

  Two scenarios are pinned:

  1. Confirmed death - only the launch BEAM is killed. The `jobrun` wrapper
     survives its parent, drains the job, and writes the termination receipt
     post-mortem, so the recovery BEAM sees `DEAD` and the reuse/cleanup gates
     are `ALLOWED`; an authorized continuation launch then runs and drains.
  2. Uncertain termination - the launch BEAM tree is destroyed, taking the
     wrapper with it before it can record any proof. OS evidence shows the job
     really died (`KILL_ON_JOB_CLOSE`), yet the recovery BEAM stays `UNKNOWN` and
     both gates stay `BLOCKED:worker_termination_unproven`.

  Windows-only and gated by `SYMPHONY_RUN_BEAM_DEATH_E2E=1` (it boots real BEAM
  processes and the `jobrun` helper; mirrors the `SYMPHONY_RUN_RUNTIME_LEASE_E2E`
  convention). It never touches the development runtime: every child is spawned
  from an isolated temp root and terminated by its own recorded OS pid.
  """

  @windows? match?({:win32, _}, :os.type())

  @skip_reason (cond do
                  not @windows? ->
                    "M1-BEAM-T requires Windows jobrun containment"

                  System.get_env("SYMPHONY_RUN_BEAM_DEATH_E2E") != "1" ->
                    "set SYMPHONY_RUN_BEAM_DEATH_E2E=1 to run the real two-BEAM death/recovery test"

                  true ->
                    nil
                end)

  if @skip_reason do
    @moduletag skip: @skip_reason
  end

  @moduletag :beam_death
  @moduletag timeout: 300_000

  # A bare BEAM boots in a couple of seconds; the bound only has to cover a slow
  # host, never a hang (the child self-halts on its own deadline).
  @boot_timeout_ms 60_000
  @receipt_timeout_ms 30_000
  @pid_timeout_ms 15_000
  @child_deadline_ms 150_000

  setup do
    root = create_temp_fixture_root!("m1-beam-t")
    {:ok, guard} = Agent.start(fn -> MapSet.new() end)

    on_exit(fn ->
      guarded_pids(guard) |> Enum.each(&force_kill_tree/1)
      stop_guard(guard)
      remove_temp_fixture_root!(root)
    end)

    %{root: root, guard: guard}
  end

  test "confirmed death after the launch BEAM is killed: post-mortem receipt proves the tree drained",
       %{root: root, guard: guard} do
    ctx = prepare_root(root)
    issue_id = "m1-beam-t-" <> run_token()
    launch_signal = Path.join(root, "launch.signal.json")

    child = start_child(root, "launch", launch_env(root, ctx, issue_id, launch_signal))
    ref = child.ref
    guard_pid_file(guard, launch_pid_file(root))

    launch = await_signal!(launch_signal, @boot_timeout_ms)
    assert launch["phase"] == "launch"
    assert launch["marker_exists"] == true

    identity = launch["identity"]
    assert identity["issue_id"] == issue_id
    assert identity["attempt_id"] == "1"
    assert identity["authority_root"] == root
    assert identity["workspace"] == launch["workspace"]
    assert String.starts_with?(identity["receipt_path"], launch["receipt_dir"])
    assert String.ends_with?(identity["receipt_path"], identity["launch_id"] <> ".json")

    # The marker is durable on disk before the worker exists, and names the
    # same authority root the launch was fenced under.
    marker = read_json!(launch["marker_path"])
    assert marker["issue_id"] == issue_id
    assert marker["launch_id"] == identity["launch_id"]
    assert marker["worker_identity"]["launch_id"] == identity["launch_id"]
    assert marker["worker_identity"]["authority_root"] == root

    # The contained mock worker tree is really running: OS evidence before death.
    wrapper_pid = launch["wrapper_pid"]
    assert is_integer(wrapper_pid)
    assert pid_alive?(wrapper_pid), "jobrun wrapper #{wrapper_pid} is not alive"
    worker_pids = await_worker_pids(ctx.scratch, @pid_timeout_ms)
    assert Enum.all?(worker_pids, &pid_alive?/1), "mock worker tree is not alive: #{inspect(worker_pids)}"
    guard_pids(guard, [launch["beam_os_pid"], wrapper_pid | worker_pids])

    # Terminate ONLY this isolated test BEAM (no /T). The wrapper survives its
    # parent, sees stdin EOF, drains the job, and writes the receipt post-mortem.
    kill_pid(launch["beam_os_pid"])
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 30_000
    _ = child_output(child)

    receipt_path = identity["receipt_path"]

    assert await_file(receipt_path, @receipt_timeout_ms),
           "jobrun wrapper never wrote a post-mortem receipt after the BEAM died"

    receipt = read_json!(receipt_path)
    assert receipt["launch_id"] == identity["launch_id"]
    assert receipt["tree_drained"] == true
    assert receipt["terminal_reason"] == "HARD_JOB_TERMINATION"

    assert SymphonyElixir.WorkerContainment.classify_receipt(receipt) == :TERMINATED_CONFIRMED

    # Actual process-tree cleanup, demonstrated by OS evidence rather than inferred.
    tree_gone = Enum.all?(worker_pids, &await_pid_gone(&1, @pid_timeout_ms))
    assert tree_gone, "worker tree survived the post-mortem wrapper drain: #{inspect(worker_pids)}"
    assert await_pid_gone(wrapper_pid, @pid_timeout_ms), "jobrun wrapper #{wrapper_pid} survived"

    recover = run_recover(root, ctx, issue_id, guard)

    # Same authority root, matching receipt identity, positive liveness verdict.
    assert recover["authority_root"] == root
    assert recover["marker_root"] == launch["marker_root"]
    assert recover["receipt_dir"] == launch["receipt_dir"]
    assert String.starts_with?(recover["marker_root"], root)
    assert String.starts_with?(recover["receipt_dir"], root)
    assert recover["marker_status"] == "VALID"
    assert recover["marker_launch_id"] == identity["launch_id"]
    assert recover["marker_identity_authority_root"] == root
    assert recover["receipt_launch_id_matches"] == true
    assert recover["verdict"] == "DEAD"
    assert recover["identity_receipt_verdict"] == "DEAD"
    assert recover["reuse_gate"] == "ALLOWED"
    assert recover["cleanup_gate"] == "ALLOWED"

    # Confirmed death permits authorized continuation: a replacement launch runs
    # and drains to TERMINATED_CONFIRMED, and the marker is cleared on proof.
    continuation = recover["continuation"]
    assert continuation["performed"] == true
    assert continuation["status"] == "TERMINATED_CONFIRMED"
    assert continuation["receipt_launch_id"] == continuation["launch_id"]
    assert continuation["receipt_tree_drained"] == true
    assert continuation["wrapper_after_stop"] == "GONE"
    assert continuation["marker_after_stop"] == "NOT_FOUND"
    refute continuation["launch_id"] == identity["launch_id"]

    record_evidence(root, "confirmed", %{
      "issue_id" => issue_id,
      "launch_id" => identity["launch_id"],
      "beam_os_pid" => launch["beam_os_pid"],
      "wrapper_pid" => wrapper_pid,
      "worker_pids" => worker_pids,
      "receipt_terminal_reason" => receipt["terminal_reason"],
      "receipt_tree_drained" => receipt["tree_drained"],
      "recover_verdict" => recover["verdict"],
      "recover_reuse_gate" => recover["reuse_gate"],
      "recover_cleanup_gate" => recover["cleanup_gate"],
      "continuation_status" => continuation["status"],
      "tree_cleanup" => %{
        "evidence_source" => "OS_TASKLIST",
        "observed_pids" => worker_pids,
        "all_absent_after" => true,
        "inferred" => false
      }
    })
  end

  test "uncertain termination after the BEAM tree is destroyed: OS cleanup observed, fence stays blocked",
       %{root: root, guard: guard} do
    ctx = prepare_root(root)
    issue_id = "m1-beam-t-" <> run_token()
    launch_signal = Path.join(root, "launch.signal.json")

    child = start_child(root, "launch", launch_env(root, ctx, issue_id, launch_signal))
    ref = child.ref
    guard_pid_file(guard, launch_pid_file(root))

    launch = await_signal!(launch_signal, @boot_timeout_ms)
    assert launch["marker_exists"] == true
    identity = launch["identity"]

    wrapper_pid = launch["wrapper_pid"]
    worker_pids = await_worker_pids(ctx.scratch, @pid_timeout_ms)
    assert Enum.all?(worker_pids, &pid_alive?/1)
    guard_pids(guard, [launch["beam_os_pid"], wrapper_pid | worker_pids])

    # Destroy the whole isolated tree: the wrapper dies with the BEAM before it
    # can record any proof, so no receipt is ever written.
    kill_tree(launch["beam_os_pid"])
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 30_000
    _ = child_output(child)

    receipt_path = identity["receipt_path"]
    Process.sleep(1_000)
    refute File.exists?(receipt_path), "unexpected receipt written by a destroyed wrapper: #{receipt_path}"

    # OS evidence still shows the job died (KILL_ON_JOB_CLOSE): the workspace is
    # really empty of processes, yet that is not positive termination proof.
    tree_gone = Enum.all?(worker_pids, &await_pid_gone(&1, @pid_timeout_ms))
    assert tree_gone, "job did not die with the destroyed wrapper: #{inspect(worker_pids)}"

    recover = run_recover(root, ctx, issue_id, guard)

    assert recover["authority_root"] == root
    assert recover["marker_status"] == "VALID"
    assert recover["marker_launch_id"] == identity["launch_id"]
    assert recover["receipt"] == nil
    assert recover["receipt_launch_id_matches"] == false
    assert recover["verdict"] == "UNKNOWN"
    assert recover["identity_receipt_verdict"] == "UNKNOWN"
    assert recover["reuse_gate"] == "BLOCKED:worker_termination_unproven"
    assert recover["cleanup_gate"] == "BLOCKED:worker_termination_unproven"
    assert recover["continuation"]["performed"] == false

    record_evidence(root, "uncertain", %{
      "issue_id" => issue_id,
      "launch_id" => identity["launch_id"],
      "beam_os_pid" => launch["beam_os_pid"],
      "worker_pids" => worker_pids,
      "receipt_present" => false,
      "recover_verdict" => recover["verdict"],
      "recover_reuse_gate" => recover["reuse_gate"],
      "recover_cleanup_gate" => recover["cleanup_gate"],
      "tree_cleanup" => %{
        "evidence_source" => "OS_TASKLIST",
        "observed_pids" => worker_pids,
        "all_absent_after" => true,
        "inferred" => false,
        "blocks_reuse" => true
      }
    })
  end

  # -- controller: child BEAM boot ------------------------------------------

  defp run_recover(root, ctx, issue_id, guard) do
    signal = Path.join(root, "recover.signal.json")
    child = start_child(root, "recover", recover_env(root, ctx, issue_id, signal))
    ref = child.ref
    guard_pid_file(guard, recover_pid_file(root))

    recover = await_signal!(signal, @boot_timeout_ms)
    assert recover["phase"] == "recover"

    # The recovery BEAM has done its work; terminate its whole tree (it owns no
    # production work) and release the guard.
    kill_tree(recover["beam_os_pid"])
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 30_000
    _ = child_output(child)

    recover
  end

  defp start_child(root, name, env) do
    batch = write_boot_batch(root, name, env)

    task =
      Task.async(fn ->
        System.cmd("cmd.exe", ["/c", batch], cd: File.cwd!(), stderr_to_stdout: true)
      end)

    ref = Process.monitor(task.pid)
    %{task: task, ref: ref}
  end

  defp child_output(%{task: task}) do
    case Task.yield(task, 5_000) do
      {:ok, {output, code}} ->
        "exit=#{code}\n" <> output

      {:exit, reason} ->
        "task exited: #{inspect(reason)}"

      nil ->
        _ = Task.shutdown(task, :brutal_kill)
        "task still running (shut down)"
    end
  end

  defp write_boot_batch(root, name, env) do
    batch = Path.join(root, "beam_boot_#{name}.cmd")

    lines =
      ["@echo off", "set \"ERL_LIBS=#{erl_libs()}\""] ++
        Enum.map(env, fn {key, value} -> "set \"#{key}=#{value}\"" end) ++
        ["\"#{elixir_bat()}\" \"#{child_script()}\""]

    File.write!(batch, Enum.join(lines, "\r\n") <> "\r\n")
    batch
  end

  defp erl_libs do
    Application.app_dir(:symphony_elixir) |> Path.dirname() |> String.replace("/", "\\")
  end

  defp elixir_bat do
    System.find_executable("elixir.bat") || raise "elixir.bat not found on PATH"
  end

  defp child_script do
    Path.expand("../support/beam_death/beam_child.exs", __DIR__)
  end

  defp scratch_exe do
    exe = Path.expand("../support/windows/bin/scratch_proc.exe", __DIR__)
    assert File.exists?(exe), "scratch_proc.exe fixture is missing: #{exe}"
    exe
  end

  # -- controller: fixture + env --------------------------------------------

  defp prepare_root(root) do
    workflow = Path.join(root, "WORKFLOW.md")
    File.write!(workflow, workflow_content(root))

    scratch = Path.join(root, "scratch")
    File.mkdir_p!(scratch)

    %{workflow: workflow, scratch: scratch}
  end

  defp workflow_content(root) do
    """
    ---
    tracker:
      kind: memory
    workspace:
      root: '#{root}'
    codex:
      command: codex app-server
      worker_termination_grace_ms: 500
    ---

    M1-BEAM-T isolated workflow (test-only).
    """
  end

  defp launch_env(root, ctx, issue_id, signal) do
    base_env(root, ctx, issue_id, signal)
    |> Map.put("SYMPHONY_BEAM_PHASE", "launch")
    |> Map.put("SYMPHONY_BEAM_PID_FILE", launch_pid_file(root))
  end

  defp recover_env(root, ctx, issue_id, signal) do
    base_env(root, ctx, issue_id, signal)
    |> Map.put("SYMPHONY_BEAM_PHASE", "recover")
    |> Map.put("SYMPHONY_BEAM_PID_FILE", recover_pid_file(root))
  end

  defp base_env(root, ctx, issue_id, signal) do
    %{
      "SYMPHONY_BEAM_ROOT" => root,
      "SYMPHONY_BEAM_WORKFLOW" => ctx.workflow,
      "SYMPHONY_BEAM_ISSUE_ID" => issue_id,
      "SYMPHONY_BEAM_ATTEMPT_ID" => "1",
      "SYMPHONY_BEAM_SIGNAL" => signal,
      "SYMPHONY_BEAM_DEADLINE_MS" => Integer.to_string(@child_deadline_ms),
      "SYMPHONY_BEAM_SCRATCH_DIR" => ctx.scratch,
      "SYMPHONY_BEAM_SCRATCH_EXE" => scratch_exe(),
      "SYMPHONY_BEAM_LIFETIME_SEC" => "120"
    }
  end

  defp launch_pid_file(root), do: Path.join(root, "launch.beam.pid")
  defp recover_pid_file(root), do: Path.join(root, "recover.beam.pid")

  defp run_token do
    Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
  end

  # -- controller: bounded waits --------------------------------------------

  defp await_signal!(path, timeout_ms) do
    case await_signal(path, timeout_ms) do
      {:ok, signal} -> signal
      {:error, :timeout} -> flunk("child BEAM never wrote its signal file: #{path}")
    end
  end

  defp await_signal(path, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_signal(path, deadline)
  end

  defp do_await_signal(path, deadline) do
    cond do
      File.exists?(path) -> {:ok, read_json!(path)}
      System.monotonic_time(:millisecond) >= deadline -> {:error, :timeout}
      true -> Process.sleep(100) && do_await_signal(path, deadline)
    end
  end

  defp await_file(path, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_file(path, deadline)
  end

  defp do_await_file(path, deadline) do
    cond do
      File.exists?(path) -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> Process.sleep(100) && do_await_file(path, deadline)
    end
  end

  defp await_pid_gone(pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_pid_gone(pid, deadline)
  end

  defp do_await_pid_gone(pid, deadline) do
    cond do
      not pid_alive?(pid) -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> Process.sleep(100) && do_await_pid_gone(pid, deadline)
    end
  end

  defp await_worker_pids(scratch, timeout_ms) do
    base = Path.join(scratch, "beamworker")
    root_file = Path.join(base, "beamworker.started")
    child_file = Path.join(base, "beamchild.started")

    assert await_file(root_file, timeout_ms), "mock worker never started: #{root_file}"
    assert await_file(child_file, timeout_ms), "mock worker descendant never started: #{child_file}"

    [started_pid!(root_file), started_pid!(child_file)]
  end

  # -- controller: OS process helpers ---------------------------------------

  defp pid_alive?(pid) when is_integer(pid) do
    case System.cmd("tasklist", ["/FI", "PID eq #{pid}", "/NH", "/FO", "CSV"], stderr_to_stdout: true) do
      {output, 0} -> Regex.match?(~r/"#{pid}"/, output)
      _other -> false
    end
  end

  defp started_pid!(path) do
    content = File.read!(path)

    case Regex.run(~r/pid=(\d+)/, content) do
      [_, pid] -> String.to_integer(pid)
      _other -> raise "no pid in #{path}"
    end
  end

  defp kill_pid(pid) do
    assert {_, 0} = System.cmd("taskkill", ["/F", "/PID", to_string(pid)], stderr_to_stdout: true)
    :ok
  end

  defp kill_tree(pid) do
    assert {_, 0} = System.cmd("taskkill", ["/F", "/T", "/PID", to_string(pid)], stderr_to_stdout: true)
    :ok
  end

  defp force_kill_tree(pid) when is_integer(pid) do
    _ = System.cmd("taskkill", ["/F", "/T", "/PID", to_string(pid)], stderr_to_stdout: true)
    :ok
  end

  defp force_kill_tree(_pid), do: :ok

  # -- controller: cleanup guard --------------------------------------------

  defp guard_pids(guard, pids) do
    pids
    |> Enum.filter(&is_integer/1)
    |> Enum.each(fn pid -> Agent.update(guard, &MapSet.put(&1, pid)) end)
  end

  # A child that fails before publishing its signal is still cleaned up: the
  # child writes its own OS pid to a known file as its very first action.
  defp guard_pid_file(guard, pid_file) do
    case File.read(pid_file) do
      {:ok, raw} ->
        case Integer.parse(String.trim(raw)) do
          {pid, _rest} when pid > 0 -> guard_pids(guard, [pid])
          _other -> :ok
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp guarded_pids(guard) do
    Agent.get(guard, &MapSet.to_list/1)
  catch
    _, _ -> []
  end

  defp stop_guard(guard) do
    Agent.stop(guard)
  catch
    _, _ -> :ok
  end

  # -- controller: evidence -------------------------------------------------

  defp read_json!(path) do
    path |> File.read!() |> Jason.decode!()
  end

  defp record_evidence(root, scenario, evidence) do
    path = Path.join(root, "evidence-#{scenario}.json")
    File.write!(path, Jason.encode!(evidence, pretty: true))
    IO.puts("[M1-BEAM-T] #{scenario} evidence: " <> Jason.encode!(evidence))
  end
end
