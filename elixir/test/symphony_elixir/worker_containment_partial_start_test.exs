defmodule SymphonyElixir.WorkerContainmentPartialStartTest do
  use SymphonyElixir.TestSupport

  @moduletag :jobrun_partial_start

  setup_all do
    case :os.type() do
      {:win32, _} ->
        {helper_root, helper} = build_private_helper!()
        on_exit(fn -> File.rm_rf(helper_root) end)
        {:ok, helper: helper}

      _ ->
        {:skip, "jobrun partial-start tests are Windows-only"}
    end
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "jobrun-partial-start-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  test "assignment failure directly terminates the suspended child before a conservative receipt",
       %{
         helper: helper,
         root: root
       } do
    result = run_fault(helper, root, "assign")

    assert result.status == 254, result.output
    refute File.exists?(result.child_started)
    receipt = assert_conservative_receipt(result.receipt, "assign_failed")
    assert_pid_gone(receipt["root_pid"])
  end

  test "resume failure directly terminates the assigned suspended child before a conservative receipt",
       %{
         helper: helper,
         root: root
       } do
    result = run_fault(helper, root, "resume")

    assert result.status == 254, result.output
    refute File.exists?(result.child_started)
    receipt = assert_conservative_receipt(result.receipt, "resume_failed")
    assert_pid_gone(receipt["root_pid"])
  end

  test "production helper rejects the compile-time-only fault injection option", %{root: root} do
    {:ok, production_helper} = SymphonyElixir.WorkerContainment.helper_path()
    marker = Path.join(root, "must-not-start")

    {output, status} =
      System.cmd(
        production_helper,
        ["--test-partial-start-fault", "assign", "--", cmd_exe(), "/c", "echo unsafe>\"#{marker}\""],
        stderr_to_stdout: true
      )

    assert status == 254
    assert output =~ "unknown option"
    refute File.exists?(marker)
  end

  defp run_fault(helper, root, phase) do
    receipt = Path.join(root, phase <> ".receipt.json")
    child_started = Path.join(root, phase <> ".child-started")

    args = [
      "--test-partial-start-fault",
      phase,
      "--receipt",
      receipt,
      "--launch-id",
      "partial-" <> phase,
      "--",
      cmd_exe(),
      "/c",
      "echo started>\"#{child_started}\""
    ]

    {output, status} = System.cmd(helper, args, stderr_to_stdout: true)
    %{status: status, output: output, receipt: receipt, child_started: child_started}
  end

  defp assert_conservative_receipt(path, mode) do
    receipt = path |> File.read!() |> Jason.decode!()
    assert receipt["terminal_reason"] == "WRAPPER_FAILURE"
    assert receipt["termination_mode"] == mode
    assert receipt["tree_drained"] == false
    refute Map.has_key?(receipt, "child_exit_code")
    assert is_integer(receipt["root_pid"]) and receipt["root_pid"] > 0
    receipt
  end

  defp assert_pid_gone(pid) do
    {output, 0} =
      System.cmd("tasklist", ["/FI", "PID eq #{pid}", "/NH", "/FO", "CSV"], stderr_to_stdout: true)

    refute output =~ ~s("#{pid}")
  end

  defp build_private_helper! do
    root =
      Path.join(
        System.tmp_dir!(),
        "jobrun-partial-start-helper-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    exe = Path.join(root, "jobrun-test.exe")
    source = Path.expand("priv/windows/jobrun/jobrun.cs")

    {output, status} =
      System.cmd(
        csc!(),
        [
          "/nologo",
          "/optimize+",
          "/define:JOBRUN_TEST",
          "/out:" <> String.replace(exe, "/", "\\"),
          String.replace(source, "/", "\\")
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    {root, exe}
  end

  defp csc! do
    windir = System.get_env("WINDIR") || "C:\\Windows"

    [
      Path.join([windir, "Microsoft.NET", "Framework64", "v4.0.30319", "csc.exe"]),
      Path.join([windir, "Microsoft.NET", "Framework", "v4.0.30319", "csc.exe"])
    ]
    |> Enum.find(&File.exists?/1)
    |> case do
      nil -> flunk("csc.exe not found")
      csc -> csc
    end
  end

  defp cmd_exe do
    [System.fetch_env!("SystemRoot"), "System32", "cmd.exe"]
    |> Path.join()
    |> String.replace("/", "\\")
  end
end
