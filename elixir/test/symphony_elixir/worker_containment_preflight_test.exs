defmodule SymphonyElixir.WorkerContainmentPreflightTest do
  use SymphonyElixir.TestSupport

  @moduletag :jobrun_preflight

  setup_all do
    case :os.type() do
      {:win32, _} ->
        # The checked-in helper is reused while its recorded hash still matches.
        # Rebuild the test copy so this file follows the edited jobrun.cs.
        dir = SymphonyElixir.WorkerContainment.helper_source_dir()
        _ = File.rm(Path.join(dir, "jobrun.exe"))
        _ = File.rm(Path.join(dir, "jobrun.exe.sha256"))
        assert {:ok, %{exe: exe}} = SymphonyElixir.WorkerContainment.build_helper()
        # Processes whose image lives under the Mix build tree cannot create
        # files here. Run the same bytes from a private temp directory.
        staged = Path.join(System.tmp_dir!(), "jobrun-preflight-helper")
        File.mkdir_p!(staged)
        staged_exe = Path.join(staged, "jobrun.exe")
        File.cp!(exe, staged_exe)
        File.cp!(exe <> ".sha256", staged_exe <> ".sha256")
        Application.put_env(:symphony_elixir, :jobrun_helper_path, staged_exe)
        :ok

      _ ->
        {:skip, "jobrun receipt preflight tests are Windows-only"}
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "jobrun-preflight-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> release_root!(root) end)
    {:ok, root: root}
  end

  test "writable receipt directory: child starts and the final receipt follows termination", %{root: root} do
    dir = Path.join(root, "receipts")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "kept.json"), "KEPT")
    id = "launch-ok"
    receipt = Path.join(dir, id <> ".json")

    port =
      open_port([
        "--grace-ms",
        "1000",
        "--drain-wait-ms",
        "500",
        "--receipt",
        receipt,
        "--launch-id",
        id,
        "--",
        cmd_exe(),
        "/c",
        "ping",
        "-n",
        "4",
        "127.0.0.1"
      ])

    Process.sleep(400)
    refute File.exists?(receipt)
    assert probe_names(dir) == []

    assert {:ok, 0, output} = drain_port(port, 15_000)
    refute output =~ "preflight failed"

    parsed = assert_final_receipt!(receipt, id)
    _ = parsed
    assert File.read!(Path.join(dir, "kept.json")) == "KEPT"
    assert probe_names(dir) == []
  end

  test "missing but creatable receipt directory: preflight succeeds", %{root: root} do
    id = "launch-create"
    dir = Path.join(root, "missing/receipts")
    receipt = Path.join(dir, id <> ".json")
    refute File.exists?(dir)

    result = run_scratch(root, id, receipt, [])

    assert result.status == 0, result.output
    assert File.dir?(dir)
    assert_final_receipt!(receipt, id)
    assert probe_names(dir) == []
    refute result.output =~ "preflight failed"
  end

  test "access denied: child never starts", %{root: root} do
    parent = Path.join(root, "parent")
    File.mkdir_p!(parent)
    icacls!([parent, "/deny", current_user() <> ":(AD)"])
    id = "launch-denied"
    receipt = Path.join(parent, "blocked/" <> id <> ".json")

    result = run_scratch(root, id, receipt, [])

    assert result.status == 254
    refute File.exists?(Path.join(parent, "blocked"))
    assert result.output =~ "phase=directory_create"
    assert result.output =~ "error=UnauthorizedAccessException"
    assert result.output =~ "win32=5"
    refute result.output =~ "injected preflight fault"
  end

  test "file-create failure: child never starts and an existing receipt is untouched", %{root: root} do
    dir = Path.join(root, "receipts")
    File.mkdir_p!(dir)
    id = "launch-create-fail"
    receipt = Path.join(dir, id <> ".json")
    sentinel = "EXISTING-RECEIPT\n"
    File.write!(receipt, sentinel)
    File.write!(Path.join(dir, "kept.json"), "KEPT")
    icacls!([dir, "/deny", current_user() <> ":(OI)(CI)(WD)"])

    result = run_scratch(root, id, receipt, [])

    assert result.status == 254
    assert result.output =~ "phase=file_create"
    assert result.output =~ "error=UnauthorizedAccessException"
    assert File.read!(receipt) == sentinel
    assert File.read!(Path.join(dir, "kept.json")) == "KEPT"
    assert probe_names(dir) == []
  end

  test "rename failure: child never starts and probe files are removed", %{root: root} do
    dir = Path.join(root, "receipts")
    File.mkdir_p!(dir)
    id = "launch-rename"
    receipt = Path.join(dir, id <> ".json")
    sentinel = "EXISTING-RECEIPT\n"
    File.write!(receipt, sentinel)

    result = run_scratch(root, id, receipt, ["--preflight-fault", "rename"])

    assert result.status == 254
    assert result.output =~ "phase=rename"
    assert result.output =~ "error=IOException"
    assert result.output =~ "injected preflight fault phase=rename"
    refute result.output =~ "phase=cleanup"
    assert File.read!(receipt) == sentinel
    assert probe_names(dir) == []
  end

  test "probe cleanup failure: not ready, and the probe is not a receipt", %{root: root} do
    dir = Path.join(root, "receipts")
    File.mkdir_p!(dir)
    id = "launch-cleanup"
    receipt = Path.join(dir, id <> ".json")
    sentinel = "EXISTING-RECEIPT\n"
    File.write!(receipt, sentinel)

    result = run_scratch(root, id, receipt, ["--preflight-fault", "cleanup"])

    assert result.status == 254
    assert result.output =~ "phase=cleanup"
    assert result.output =~ "error=IOException"
    assert File.read!(receipt) == sentinel

    probes = probe_names(dir)
    assert probes == [hd(probes)]
    assert String.ends_with?(hd(probes), ".probe")
    payload = File.read!(Path.join(dir, hd(probes)))
    assert payload == "jobrun-preflight-probe"
    refute String.contains?(payload, "schema_version")
    refute String.ends_with?(hd(probes), ".json")
  end

  defp run_scratch(_root, id, receipt, extra) do
    args =
      extra ++
        [
          "--receipt",
          receipt,
          "--launch-id",
          id,
          "--",
          cmd_exe(),
          "/c",
          "exit",
          "0"
        ]

    {output, status} = System.cmd(jobrun!(), args, stderr_to_stdout: true)
    %{status: status, output: output}
  end

  defp cmd_exe do
    [System.fetch_env!("SystemRoot"), "System32", "cmd.exe"]
    |> Path.join()
    |> String.replace("/", "\\")
  end

  defp open_port(args) do
    Port.open({:spawn_executable, String.to_charlist(jobrun!())}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: Enum.map(args, &String.to_charlist/1)
    ])
  end

  defp jobrun! do
    case SymphonyElixir.WorkerContainment.helper_path() do
      {:ok, exe} -> exe
      {:error, reason} -> flunk("jobrun helper unavailable: #{inspect(reason)}")
    end
  end

  defp assert_final_receipt!(path, launch_id) do
    parsed = Jason.decode!(File.read!(path))
    assert parsed["schema_version"] == 1
    assert parsed["launch_id"] == launch_id
    assert parsed["tree_drained"] == true
    assert parsed["terminal_reason"] == "NATURAL_EXIT"
    assert parsed["termination_mode"] == "natural_exit"
    assert parsed["child_exit_code"] == 0
    assert parsed["wrapper_status"] == "ok"
    assert is_integer(parsed["root_pid"]) and parsed["root_pid"] > 0
    parsed
  end

  defp probe_names(dir) do
    case File.ls(dir) do
      {:ok, names} -> Enum.filter(names, &String.starts_with?(&1, "jobrun-preflight-"))
      {:error, _} -> []
    end
  end

  defp current_user, do: System.fetch_env!("USERDOMAIN") <> "\\" <> System.fetch_env!("USERNAME")

  defp icacls!(args) do
    {out, status} = System.cmd("icacls", args, stderr_to_stdout: true)
    assert status == 0, out
  end

  defp release_root!(root) do
    if File.exists?(root) do
      user = current_user()
      System.cmd("icacls", [root, "/grant:r", user <> ":(OI)(CI)F", "/T", "/C"], stderr_to_stdout: true)
      System.cmd("icacls", [root, "/reset", "/T", "/C"], stderr_to_stdout: true)
      File.rm_rf(root)
    end
  end

  defp drain_port(port, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    drain_port(port, deadline, [])
  end

  defp drain_port(port, deadline, acc) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:error, :timeout}
    else
      receive do
        {^port, {:exit_status, code}} ->
          {:ok, code, acc |> Enum.reverse() |> IO.iodata_to_binary()}

        {^port, {:data, chunk}} when is_binary(chunk) ->
          drain_port(port, deadline, [chunk | acc])

        {^port, {:data, {:eol, chunk}}} ->
          drain_port(port, deadline, [to_string(chunk) <> "\n" | acc])

        {^port, {:data, {:noeol, chunk}}} ->
          drain_port(port, deadline, [to_string(chunk) | acc])

        {^port, _} ->
          drain_port(port, deadline, acc)
      after
        deadline - now -> {:error, :timeout}
      end
    end
  end
end
