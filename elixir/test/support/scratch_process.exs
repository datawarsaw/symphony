defmodule SymphonyElixir.TestSupport.ScratchProcess do
  @moduledoc """
  MIC-223 helper-test support: builds the scratch process-tree child and drives
  it through the production `jobrun` wrapper with real Job containment.

  Evidence model (from the PoC): every scratch process writes
  `<scratch>/<id>.started` and heartbeats every 250 ms; a graceful exit via
  stop-file produces `<id>.exited` with `reason=graceful_stop_file`. An
  `.exited` file with that reason therefore proves the process was alive and
  responsive up to the moment it was asked to stop — no PID bookkeeping.
  """

  @scratch_source "test/support/windows/scratch_proc.cs"
  @bin_dir "test/support/windows/bin"
  @scratch_exe "scratch_proc.exe"

  # ---------------------------------------------------------------------------
  # Build
  # ---------------------------------------------------------------------------

  def scratch_exe, do: Path.expand(Path.join([@bin_dir, @scratch_exe]))

  def ensure_built! do
    exe = scratch_exe()
    src = Path.expand(@scratch_source)

    rebuild? =
      not File.exists?(exe) or
        File.stat!(src).mtime > File.stat!(exe).mtime

    if rebuild? do
      File.mkdir_p!(Path.expand(@bin_dir))
      csc = csc_path!()

      args = [
        "/nologo",
        "/optimize+",
        "/target:exe",
        "/out:" <> String.replace(exe, "/", "\\"),
        String.replace(src, "/", "\\")
      ]

      case System.cmd(csc, args, stderr_to_stdout: true) do
        {_, 0} ->
          :ok

        {output, status} ->
          raise "scratch_proc build failed (#{status}): #{output}"
      end
    end

    :ok
  end

  defp csc_path! do
    windir = System.get_env("WINDIR") || "C:\\Windows"

    candidates = [
      Path.join([windir, "Microsoft.NET", "Framework64", "v4.0.30319", "csc.exe"]),
      Path.join([windir, "Microsoft.NET", "Framework", "v4.0.30319", "csc.exe"])
    ]

    found = Enum.find(candidates, &File.exists?/1)
    found || raise "csc.exe not found; cannot build scratch_proc"
  end

  def jobrun_exe! do
    case SymphonyElixir.WorkerContainment.helper_path() do
      {:ok, exe} -> exe
      {:error, reason} -> raise "jobrun helper unavailable: #{inspect(reason)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Spawning
  # ---------------------------------------------------------------------------

  @doc """
  Spawns jobrun wrapping scratch_proc with the given scratch args.

  Options:
    - `:scratch` — evidence directory (required)
    - `:id` — scratch id (required)
    - `:grace_ms` — jobrun `--grace-ms` override (e.g. 800 for fast hard-kill tests)
    - `:drain_wait_ms` — jobrun `--drain-wait-ms` override
    - `:scratch_args` — argv for scratch_proc (e.g. ~w(--id a --scratch ...))

  Returns `%{port: port, receipt: receipt_path, os_pid: wrapper_pid}`.
  """
  def spawn_jobrun(opts, scratch_args) do
    scratch = Keyword.fetch!(opts, :scratch)
    id = Keyword.fetch!(opts, :id)
    receipt = Path.join(scratch, id <> ".receipt.json")
    File.mkdir_p!(scratch)

    args =
      [
        opts[:grace_ms] && ["--grace-ms", Integer.to_string(opts[:grace_ms])],
        opts[:drain_wait_ms] && ["--drain-wait-ms", Integer.to_string(opts[:drain_wait_ms])],
        ["--receipt", receipt],
        ["--launch-id", id],
        ["--", scratch_exe()],
        Enum.map(scratch_args, &to_string/1)
      ]
      |> Enum.reject(&is_nil/1)
      |> List.flatten()
      |> Enum.map(&String.to_charlist/1)

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(jobrun_exe!())},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: args,
          cd: String.to_charlist(scratch)
        ]
      )

    os_pid =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, pid} when is_integer(pid) -> pid
        {:os_pid, pid} when is_list(pid) -> List.to_integer(pid)
        _ -> nil
      end

    %{port: port, receipt: receipt, os_pid: os_pid, scratch: scratch, id: id}
  end

  @doc """
  Closes the port (stdin EOF to jobrun) and waits for the wrapper process to
  finish. A closed port never delivers `exit_status` (proven on OTP 28), so
  completion is observed by polling the wrapper OS pid, exactly like the
  production stop path. Returns {:ok, receipt_child_exit_code_or_nil}.
  """
  def close_and_await(%{port: port, os_pid: os_pid, receipt: receipt}, timeout_ms \\ 30_000) do
    Port.close(port)
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_wrapper_gone(os_pid, deadline)

    child_code =
      case File.read(receipt) do
        {:ok, raw} ->
          raw |> Jason.decode!() |> Map.get("child_exit_code")

        {:error, _} ->
          nil
      end

    {:ok, child_code}
  end

  defp await_wrapper_gone(os_pid, deadline) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      raise "wrapper #{os_pid} did not exit within the bounded wait"
    end

    if pid_alive?(os_pid) do
      Process.sleep(150)
      await_wrapper_gone(os_pid, deadline)
    else
      :ok
    end
  end

  @doc "Hard-kills the jobrun wrapper process (wrapper-crash scenario)."
  def kill_wrapper!(os_pid) when is_integer(os_pid) do
    case System.cmd("taskkill", ["/F", "/PID", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> raise "taskkill wrapper failed: #{output}"
    end
  end

  # ---------------------------------------------------------------------------
  # Evidence helpers
  # ---------------------------------------------------------------------------

  def started_path(%{scratch: scratch, id: id}), do: Path.join(scratch, id <> ".started")

  def await_started(tree, timeout_ms \\ 10_000), do: await_file(started_path(tree), timeout_ms)

  @doc "Waits for `<id>.exited` and returns the reason= field, or nil on timeout."
  def await_exit_reason(%{scratch: scratch, id: id}, timeout_ms) do
    path = Path.join(scratch, id <> ".exited")
    await_file(path, timeout_ms)

    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("|")
        |> Enum.find_value(fn kv ->
          case String.split(kv, "=", parts: 2) do
            ["reason", reason] -> reason
            _ -> nil
          end
        end)

      {:error, _} ->
        nil
    end
  end

  @doc "Signals a scratch process (or tree sharing a stop file) to exit gracefully."
  def stop_via_file(%{scratch: scratch, id: id}, stop_name \\ nil) do
    name = stop_name || id <> ".stop"
    File.write!(Path.join(scratch, name), "stop\n")
  end

  def read_receipt(receipt_path) when is_binary(receipt_path) do
    case File.read(receipt_path) do
      {:ok, raw} -> Jason.decode!(raw)
      {:error, reason} -> raise "receipt unreadable #{receipt_path}: #{inspect(reason)}"
    end
  end

  @doc "Parses the OS pid from a scratch process's .started evidence file."
  def started_pid!(%{scratch: scratch, id: id}) do
    content = File.read!(Path.join(scratch, id <> ".started"))

    case Regex.run(~r/pid=(\d+)/, content) do
      [_, pid] -> String.to_integer(pid)
      _ -> raise "no pid in started file for #{id}"
    end
  end

  @doc "tasklist-based liveness probe for a scratch OS pid."
  def pid_alive?(pid) when is_integer(pid) do
    {output, 0} =
      System.cmd("tasklist", ["/FI", "PID eq #{pid}", "/NH", "/FO", "CSV"], stderr_to_stdout: true)

    Regex.match?(~r/"#{pid}"/, output)
  end

  @doc "Waits until the pid disappears from the process list (or times out)."
  def await_pid_gone(pid, timeout_ms) when is_integer(pid) do
    if pid_alive?(pid) do
      if timeout_ms <= 0 do
        false
      else
        Process.sleep(100)
        await_pid_gone(pid, timeout_ms - 100)
      end
    else
      true
    end
  end

  defp await_file(_path, timeout_ms) when timeout_ms <= 0, do: false

  defp await_file(path, timeout_ms) do
    if File.exists?(path) do
      true
    else
      Process.sleep(50)
      await_file(path, timeout_ms - 50)
    end
  end
end
