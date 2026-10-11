defmodule SymphonyElixir.WorkerContainmentFaultInjectionTest do
  use SymphonyElixir.TestSupport

  @moduledoc """
  MIC-223 M1-JOB-F: fault-injection coverage for atomic Job Object assignment in
  the production `jobrun` helper. Every scenario uses a disposable scratch child.
  Cleanup is registered before any assertion that could fail, so no scratch
  process survives a red run.

  Windows API requirement: atomic assignment uses PROC_THREAD_ATTRIBUTE_JOB_LIST,
  available on Windows 10 / Server 2016 and later.
  """

  alias SymphonyElixir.TestSupport.ScratchProcess
  alias SymphonyElixir.WorkerContainment

  setup_all do
    case :os.type() do
      {:win32, _} -> :ok
      _ -> {:skip, "MIC-223 jobrun fault-injection tests are Windows-only"}
    end
  end

  setup do
    scratch_root =
      Path.join(System.tmp_dir!(), "mic223-m1jobf-tests-#{System.unique_integer([:positive])}")

    File.mkdir_p!(scratch_root)
    {:ok, scratch_root: scratch_root}
  end

  defp id(scratch_root, name), do: Path.join(scratch_root, name)

  @tag :mic223_helper
  test "16. CreateProcess failure creates no child and reports WRAPPER_FAILURE", %{scratch_root: scratch_root} do
    scratch = id(scratch_root, "spawnfail")
    File.mkdir_p!(scratch)
    fake_exe = Path.join(scratch, "not-a-program.exe")
    File.write!(fake_exe, "not a PE image\n")
    receipt = Path.join(scratch, "spawnfail.receipt.json")

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(ScratchProcess.jobrun_exe!())},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: Enum.map(["--receipt", receipt, "--launch-id", "spawnfail", "--", fake_exe], &String.to_charlist/1),
          cd: String.to_charlist(scratch)
        ]
      )

    assert {:ok, 254} = drain_until_exit(port, 15_000)

    report = ScratchProcess.read_receipt(receipt)
    assert report["terminal_reason"] == "WRAPPER_FAILURE"
    assert report["termination_mode"] == "spawn_failed"
    assert report["tree_drained"] == false
    refute Map.has_key?(report, "root_pid")
    assert WorkerContainment.classify_receipt(report) == :TERMINATION_UNCONFIRMED
  end

  @tag :mic223_helper
  test "17. failed membership verification terminates the suspended child (repeated)", %{scratch_root: scratch_root} do
    for n <- 1..5 do
      name = "notinjob#{n}"

      tree =
        ScratchProcess.spawn_jobrun(
          [scratch: id(scratch_root, name), id: name, jobrun_args: ["--test-fault", "not-in-job"]],
          ["--id", name, "--scratch", id(scratch_root, name), "--lifetime", "30"]
        )

      assert {:ok, 254} = drain_until_exit(tree.port, 15_000)

      report = ScratchProcess.read_receipt(tree.receipt)
      assert report["terminal_reason"] == "WRAPPER_FAILURE"
      assert report["tree_drained"] == false
      child_pid = report["root_pid"]
      assert is_integer(child_pid), "receipt must name the suspended child for OS-level evidence"
      on_exit(fn -> kill_if_alive(child_pid) end)

      assert ScratchProcess.await_pid_gone(child_pid, 5_000), "suspended child survived membership failure"
      refute File.exists?(ScratchProcess.started_path(tree))
    end
  end

  @tag :mic223_helper
  test "18. wrapper crash between contained creation and resume leaves no surviving child (repeated)", %{scratch_root: scratch_root} do
    for n <- 1..3 do
      name = "crashwin#{n}"

      tree =
        ScratchProcess.spawn_jobrun(
          [scratch: id(scratch_root, name), id: name, jobrun_args: ["--test-fault", "hold-suspended"]],
          ["--id", name, "--scratch", id(scratch_root, name), "--lifetime", "30"]
        )

      child_pid = await_hold_child_pid(tree.port, 15_000)
      on_exit(fn -> kill_if_alive(child_pid) end)
      assert ScratchProcess.pid_alive?(child_pid), "held child must exist and be contained before the crash"

      ScratchProcess.kill_wrapper!(tree.os_pid)
      assert ScratchProcess.await_pid_gone(child_pid, 10_000), "suspended child survived wrapper crash"
      refute File.exists?(ScratchProcess.started_path(tree)), "child ran before the crash window closed"
      refute File.exists?(tree.receipt)
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

  defp await_hold_child_pid(port, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_hold_child_pid(port, "", deadline)
  end

  defp do_await_hold_child_pid(port, acc, deadline) do
    case Regex.run(~r/test hold child_pid=(\d+)/, acc) do
      [_, pid] ->
        String.to_integer(pid)

      _ ->
        remaining = deadline - System.monotonic_time(:millisecond)
        if remaining <= 0, do: flunk("wrapper never reported the held child pid")

        receive do
          {^port, {:data, data}} -> do_await_hold_child_pid(port, acc <> data, deadline)
        after
          remaining -> flunk("wrapper never reported the held child pid")
        end
    end
  end

  defp kill_if_alive(pid) when is_integer(pid) do
    if ScratchProcess.pid_alive?(pid) do
      System.cmd("taskkill", ["/F", "/PID", Integer.to_string(pid)], stderr_to_stdout: true)
    end

    :ok
  end
end
