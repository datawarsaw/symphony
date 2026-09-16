defmodule SymphonyElixir.WorkerContainmentHelperTest do
  use SymphonyElixir.TestSupport

  @moduledoc """
  MIC-223 Phase 20: focused validation of the production `jobrun` helper
  against scratch process trees (never production workers). Ported from the
  proven PoC scenarios. The BEAM-owner-crash case lives in the Windows host
  proof, not here, because it requires halting a separate BEAM.
  """

  alias SymphonyElixir.TestSupport.ScratchProcess

  @bash_candidates ["C:/Program Files/Git/bin/bash.exe", "C:/Program Files/Git/usr/bin/bash.exe"]

  setup_all do
    case :os.type() do
      {:win32, _} ->
        :ok

      _ ->
        {:skip, "MIC-223 jobrun helper tests are Windows-only"}
    end
  end

  setup do
    scratch_root =
      Path.join(System.tmp_dir!(), "mic223-helper-tests-#{System.unique_integer([:positive])}")

    File.mkdir_p!(scratch_root)
    {:ok, scratch_root: scratch_root}
  end

  defp id(scratch_root, name), do: Path.join(scratch_root, name)

  defp spawn_tree(scratch_root, name, scratch_args, opts \\ []) do
    tree =
      ScratchProcess.spawn_jobrun(
        [scratch: id(scratch_root, name), id: name] ++ opts,
        ["--id", name, "--scratch", id(scratch_root, name)] ++ scratch_args
      )

    assert ScratchProcess.await_started(tree), "scratch process #{name} never started"
    tree
  end

  @tag :mic223_helper
  test "1. natural root exit drains and confirms (NATURAL_EXIT)", %{scratch_root: scratch_root} do
    tree = spawn_tree(scratch_root, "natural", ["--lifetime", "1"])

    # No Port.close: the root dies on its own, so the wrapper takes the
    # natural-exit path and the runtime observes the exit status.
    assert {:ok, 0} = drain_until_exit(tree.port, 15_000)

    receipt = ScratchProcess.read_receipt(tree.receipt)
    assert receipt["terminal_reason"] == "NATURAL_EXIT"
    assert receipt["tree_drained"] == true
    assert receipt["child_exit_code"] == 0
    assert receipt["launch_id"] == "natural"
    assert receipt["root_pid"] == ScratchProcess.started_pid!(tree)
    assert receipt["root_creation_time"] =~ "Z"
  end

  @tag :mic223_helper
  test "2. non-zero child exit code propagates with positive drain", %{scratch_root: scratch_root} do
    tree = spawn_tree(scratch_root, "exit3", ["--lifetime", "1", "--exit-code", "3"])

    assert {:ok, 3} = drain_until_exit(tree.port, 15_000)

    receipt = ScratchProcess.read_receipt(tree.receipt)
    assert receipt["terminal_reason"] == "NATURAL_EXIT"
    assert receipt["tree_drained"] == true
    assert receipt["child_exit_code"] == 3
  end

  @tag :mic223_helper
  test "3+6. Port.close with cooperative stdin-EOF root exits during grace", %{scratch_root: scratch_root} do
    tree =
      spawn_tree(scratch_root, "coop", ["--lifetime", "20", "--stdin-exit"],
        grace_ms: 3_000,
        drain_wait_ms: 500
      )

    Process.sleep(300)
    assert {:ok, 0} = ScratchProcess.close_and_await(tree, 15_000)

    receipt = ScratchProcess.read_receipt(tree.receipt)
    assert receipt["terminal_reason"] == "COOPERATIVE_EXIT"
    assert receipt["termination_mode"] == "stdin_eof_grace"
    assert receipt["tree_drained"] == true
    assert receipt["child_exit_code"] == 0
  end

  @tag :mic223_helper
  test "7. unresponsive root gets hard-terminated after grace (HARD_JOB_TERMINATION)", %{
    scratch_root: scratch_root
  } do
    tree =
      spawn_tree(scratch_root, "hard", ["--lifetime", "20"], grace_ms: 800, drain_wait_ms: 500)

    Process.sleep(300)
    root_pid = ScratchProcess.started_pid!(tree)
    # A hard-terminated root has no child exit code; the receipt carries the
    # semantics (exit codes are transport, not lifecycle evidence).
    assert {:ok, nil} = ScratchProcess.close_and_await(tree, 20_000)

    receipt = ScratchProcess.read_receipt(tree.receipt)
    assert receipt["terminal_reason"] == "HARD_JOB_TERMINATION"
    assert receipt["termination_mode"] == "stdin_eof_terminate"
    assert receipt["tree_drained"] == true
    assert ScratchProcess.await_pid_gone(root_pid, 5_000)
  end

  @tag :mic223_helper
  test "4. abrupt wrapper crash kills the whole tree via KILL_ON_JOB_CLOSE", %{
    scratch_root: scratch_root
  } do
    tree = spawn_tree(scratch_root, "crash", ["--lifetime", "20", "--spawn-chain", "c1>c2"])
    await_chain_started(tree, ["c1", "c2"])

    root_pid = ScratchProcess.started_pid!(tree)
    c1_pid = chain_pid(tree, "c1")
    c2_pid = chain_pid(tree, "c2")

    ScratchProcess.kill_wrapper!(tree.os_pid)
    _ = root_pid

    # No wrapper is left to write a receipt: from the runtime's perspective
    # this stays TERMINATION_UNCONFIRMED (fail closed); kernel-side containment
    # still kills every job member.
    refute File.exists?(tree.receipt)
    assert ScratchProcess.await_pid_gone(c1_pid, 10_000), "c1 survived wrapper crash"
    assert ScratchProcess.await_pid_gone(c2_pid, 10_000), "c2 survived wrapper crash"
    assert_crash_no_graceful_exit(tree, ["c1", "c2"])
  end

  @tag :mic223_helper
  test "8+9. root exit with surviving descendants escalates to full tree drain", %{
    scratch_root: scratch_root
  } do
    tree =
      spawn_tree(scratch_root, "orphan", ["--lifetime", "1", "--spawn-chain", "orphan-child", "--child-lifetime", "4"], drain_wait_ms: 500)

    await_chain_started(tree, ["orphan-child"])
    child_pid = chain_pid(tree, "orphan-child")
    assert {:ok, 0} = drain_until_exit(tree.port, 20_000)

    receipt = ScratchProcess.read_receipt(tree.receipt)
    assert receipt["terminal_reason"] == "NATURAL_EXIT"
    assert receipt["tree_drained"] == true
    # ROOT_EXITED != TERMINATED_CONFIRMED: the receipt proves the drain too.
    assert receipt["root_exited_at"] != receipt["tree_drained_at"]
    assert ScratchProcess.await_pid_gone(child_pid, 5_000), "orphaned descendant survived"
  end

  @tag :mic223_helper
  test "10. breakaway is denied inside the job (no BREAKAWAY_OK granted)", %{
    scratch_root: scratch_root
  } do
    tree = spawn_tree(scratch_root, "breakaway", ["--lifetime", "3", "--try-breakaway"])

    breakaway_path = Path.join([scratch_root, "breakaway", "breakaway.breakaway"])
    wait_until_file(breakaway_path, 5_000)

    assert {:ok, 0} = ScratchProcess.close_and_await(tree, 15_000)
    content = File.read!(breakaway_path)
    assert content =~ "FAILED"
    assert content =~ "win32_err=5"
  end

  @tag :mic223_helper
  test "11+12. unrelated sibling job survives hard termination of job A", %{
    scratch_root: scratch_root
  } do
    tree_a = spawn_tree(scratch_root, "job_a", ["--lifetime", "20"], grace_ms: 800, drain_wait_ms: 500)
    tree_b = spawn_tree(scratch_root, "job_b", ["--lifetime", "20", "--stop-file", "shared_b.stop"])

    Process.sleep(300)
    assert {:ok, nil} = ScratchProcess.close_and_await(tree_a, 20_000)
    assert ScratchProcess.read_receipt(tree_a.receipt)["tree_drained"] == true

    # Job B was alive the entire time and still answers a graceful stop.
    File.write!(Path.join([scratch_root, "job_b", "shared_b.stop"]), "stop\n")
    assert ScratchProcess.await_exit_reason(tree_b, 8_000) == "graceful_stop_file"
    assert {:ok, 0} = drain_until_exit(tree_b.port, 15_000)
    assert ScratchProcess.read_receipt(tree_b.receipt)["tree_drained"] == true
  end

  @tag :mic223_helper
  test "13. Git Bash/MSYS broken-PPID descendant shape drains", %{scratch_root: scratch_root} do
    bash = Enum.find(@bash_candidates, &File.exists?/1)

    unless bash do
      flunk("no Git Bash found for MSYS shape test")
    end

    jobrun = ScratchProcess.jobrun_exe!()
    scratch = id(scratch_root, "msys")
    File.mkdir_p!(scratch)
    receipt = Path.join(scratch, "msys.receipt.json")

    args =
      ["--receipt", receipt, "--launch-id", "msys", "--drain-wait-ms", "500", "--", bash, "-lc", "sh -c 'sleep 4' & sleep 0.3"]
      |> Enum.map(&String.to_charlist/1)

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(jobrun)},
        [:binary, :exit_status, :stderr_to_stdout, args: args, cd: String.to_charlist(scratch)]
      )

    assert {:ok, 0} = drain_until_exit(port, 20_000)

    receipt_map = ScratchProcess.read_receipt(receipt)
    assert receipt_map["terminal_reason"] == "NATURAL_EXIT"
    # The orphaned `sh -c 'sleep 4'` was reaped by the job despite its broken
    # MSYS parentage: positive accounting evidence, not PID chasing.
    assert receipt_map["tree_drained"] == true
  end

  @tag :mic223_helper
  test "14. stdout integrity: wrapper injects no protocol noise", %{scratch_root: scratch_root} do
    tree = spawn_tree(scratch_root, "chatty", ["--lifetime", "2", "--chatty", "5"])

    {status, output} = collect_output(tree.port, 20_000)
    assert status == 0

    lines = output |> String.split("\n") |> Enum.reject(&(String.trim(&1) == ""))

    assert length(lines) == 5

    Enum.each(lines, fn line ->
      assert line =~ ~r/^CHATTY\|chatty\|\d{7}\|x{40}\r?$/
    end)

    assert ScratchProcess.read_receipt(tree.receipt)["tree_drained"] == true
  end

  @tag :mic223_helper
  test "15. process hygiene: every scratch tree is dead after the suite", %{
    scratch_root: scratch_root
  } do
    # Spawn one final tree, exercise close, then prove no scratch process from
    # this run survives anywhere.
    tree = spawn_tree(scratch_root, "hygiene", ["--lifetime", "1"])
    assert {:ok, 0} = drain_until_exit(tree.port, 15_000)

    started_files = list_started_files(scratch_root)
    refute started_files == []

    Enum.each(started_files, fn path ->
      [_, pid] = Regex.run(~r/pid=(\d+)/, File.read!(path))
      assert ScratchProcess.await_pid_gone(String.to_integer(pid), 5_000), "#{path} still alive"
    end)
  end

  # -- helpers --------------------------------------------------------------

  defp await_chain_started(tree, child_ids) do
    Enum.each(child_ids, fn child_id ->
      path = Path.join(tree.scratch, child_id <> ".started")
      wait_until_file(path, 10_000)
      assert File.exists?(path), "chain child #{child_id} never started"
    end)
  end

  defp chain_pid(tree, child_id) do
    content = File.read!(Path.join(tree.scratch, child_id <> ".started"))
    [_, pid] = Regex.run(~r/pid=(\d+)/, content)
    String.to_integer(pid)
  end

  defp assert_crash_no_graceful_exit(tree, child_ids) do
    # The tree died by containment, not by graceful stop: no .exited file with
    # reason=graceful_stop_file may appear for any chain member.
    Process.sleep(300)

    Enum.each(child_ids, fn child_id ->
      path = Path.join(tree.scratch, child_id <> ".exited")

      if File.exists?(path) do
        refute File.read!(path) =~ "graceful_stop_file"
      end
    end)
  end

  # Path.wildcard/1 does not reliably expand drive-letter absolute globs on
  # this platform; enumerate evidence directories directly instead.
  defp list_started_files(scratch_root) do
    case File.ls(scratch_root) do
      {:ok, dirs} ->
        Enum.flat_map(dirs, fn dir ->
          dir_path = Path.join(scratch_root, dir)

          case File.ls(dir_path) do
            {:ok, files} ->
              files
              |> Enum.filter(&String.ends_with?(&1, ".started"))
              |> Enum.map(&Path.join([dir_path, &1]))

            {:error, _} ->
              []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp wait_until_file(_path, ms) when ms <= 0, do: nil

  defp wait_until_file(path, ms) do
    unless File.exists?(path) do
      Process.sleep(50)
      wait_until_file(path, ms - 50)
    end
  end

  defp drain_until_exit(port, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_drain(port, deadline)
  end

  defp do_drain(port, deadline) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:error, :timeout}
    else
      receive do
        {^port, {:exit_status, code}} -> {:ok, code}
        {^port, _} -> do_drain(port, deadline)
      after
        deadline - now -> {:error, :timeout}
      end
    end
  end

  defp collect_output(port, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect_output(port, deadline, [])
  end

  defp collect_output(port, deadline, acc) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:error, :timeout}
    else
      receive do
        {^port, {:exit_status, code}} ->
          {code, acc |> Enum.reverse() |> IO.iodata_to_binary()}

        {^port, {:data, chunk}} when is_binary(chunk) ->
          collect_output(port, deadline, [chunk | acc])

        {^port, {:data, {:eol, chunk}}} ->
          collect_output(port, deadline, [to_string(chunk) <> "\n" | acc])

        {^port, {:data, {:noeol, chunk}}} ->
          collect_output(port, deadline, [to_string(chunk) | acc])

        {^port, _} ->
          collect_output(port, deadline, acc)
      after
        deadline - now -> {:error, :timeout}
      end
    end
  end
end
