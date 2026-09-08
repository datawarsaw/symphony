defmodule SymphonyElixir.TestSupport.FakeSSH do
  @moduledoc """
  Installs a platform-portable fake `ssh` executable for remote-lifecycle tests.

  The production code resolves `ssh` with `System.find_executable/1` and spawns it
  either through `System.cmd/3` or `Port.open({:spawn_executable, ...}, ...)`, so the
  fixture only has to place a plausible `ssh` earlier on `PATH`.

  POSIX hosts get an extensionless `#!/bin/sh` script exactly like the historical
  fixtures (shebang plus `File.chmod!/2`). Windows hosts get a compiled `ssh.exe`
  built on demand with the .NET Framework compiler that ships with Windows: command
  lines with embedded newlines (the multi-line remote prepare/remove scripts) do not
  survive a `.bat` re-parse, so the fake must observe its own command line directly.

  Both implementations expose the same observable behavior selected with `mode`:

    * `:trace` - append `ARGV:<args>` to the trace file, optionally print one stdout
      line, exit 0
    * `:jsonrpc` - JSON-RPC responder used by the remote AppServer test: trace argv
      and every stdin line, answer the first four requests, exit after the
      `turn/completed` notification closes the pipe
    * `:marker` - trace argv and, when the arguments contain the workspace marker,
      print the configured tab-separated marker line; optionally fail with a stderr
      message and a specific exit status when another match appears first

  `install!/3` writes the fixture into `bin_dir` and prepends `bin_dir` to `PATH`
  with the platform path separator. Traces are written to the `:trace_file` opt
  (mirrored into `SYMP_TEST_SSH_TRACE`, the variable the tests already save and
  restore). Failure to find a usable Windows compiler raises loudly instead of
  silently degrading the fixture.
  """

  @marker_match "__SYMPHONY_WORKSPACE__"

  @csharp_source ~S"""
  using System;
  using System.IO;
  using System.Text;

  // Minimal fake ssh used by Symphony remote-lifecycle tests on Windows.
  // Mode and parameters come from the environment; see test/support/fake_ssh.exs.
  static class FakeSsh
  {
      static int Main()
      {
          string joined = JoinArgs(Environment.GetCommandLineArgs());
          Trace("ARGV:" + joined);

          string mode = Environment.GetEnvironmentVariable("SYMP_FAKE_SSH_MODE") ?? "trace";
          switch (mode)
          {
              case "jsonrpc":
                  return JsonRpc();
              case "marker":
                  return Marker(joined);
              default:
                  return TraceMode();
          }
      }

      static int TraceMode()
      {
          string stdout = Environment.GetEnvironmentVariable("SYMP_FAKE_SSH_STDOUT");
          if (stdout != null)
          {
              WriteRaw(Console.OpenStandardOutput(), stdout + "\n");
          }
          return 0;
      }

      static int JsonRpc()
      {
          int count = 0;
          bool done = false;
          Stream stdin = Console.OpenStandardInput();
          Stream stdout = Console.OpenStandardOutput();
          var pending = new StringBuilder();
          int b;

          while (!done && (b = stdin.ReadByte()) >= 0)
          {
              if (b == '\n')
              {
                  string line = pending.ToString();
                  pending.Length = 0;
                  if (line.EndsWith("\r"))
                  {
                      line = line.Substring(0, line.Length - 1);
                  }

                  count++;
                  Trace("JSON:" + line);

                  string response = null;
                  switch (count)
                  {
                      case 1:
                          response = "{\"id\":1,\"result\":{}}";
                          break;
                      case 2:
                          response = "{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-remote\"}}}";
                          break;
                      case 3:
                          response = "{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-remote\"}}}";
                          break;
                      case 4:
                          response = "{\"method\":\"turn/completed\"}";
                          done = true;
                          break;
                  }

                  if (response != null)
                  {
                      WriteRaw(stdout, response + "\n");
                  }
              }
              else
              {
                  pending.Append((char)b);
              }
          }

          return 0;
      }

      static int Marker(string joined)
      {
          string failMatch = Environment.GetEnvironmentVariable("SYMP_FAKE_SSH_FAIL_MATCH");
          string markerMatch = Environment.GetEnvironmentVariable("SYMP_FAKE_SSH_MARKER_MATCH") ?? "__SYMPHONY_WORKSPACE__";

          if (failMatch != null && joined.Contains(failMatch) && joined.Contains(markerMatch))
          {
              Console.Error.WriteLine(Environment.GetEnvironmentVariable("SYMP_FAKE_SSH_FAIL_STDERR") ?? "prepare failed");
              return int.Parse(Environment.GetEnvironmentVariable("SYMP_FAKE_SSH_FAIL_EXIT") ?? "75");
          }

          if (joined.Contains(markerMatch))
          {
              string output = Environment.GetEnvironmentVariable("SYMP_FAKE_SSH_MARKER_OUTPUT") ?? "";
              WriteRaw(Console.OpenStandardOutput(), output + "\n");
          }

          return 0;
      }

      static string JoinArgs(string[] argv)
      {
          var sb = new StringBuilder();
          for (int i = 1; i < argv.Length; i++)
          {
              if (i > 1)
              {
                  sb.Append(' ');
              }
              sb.Append(argv[i]);
          }
          return sb.ToString();
      }

      static void Trace(string line)
      {
          string traceFile = Environment.GetEnvironmentVariable("SYMP_TEST_SSH_TRACE");
          if (traceFile != null && traceFile != "")
          {
              File.AppendAllText(traceFile, line + "\n", new UTF8Encoding(false));
          }
      }

      static void WriteRaw(Stream stream, string text)
      {
          byte[] bytes = new UTF8Encoding(false).GetBytes(text);
          stream.Write(bytes, 0, bytes.Length);
          stream.Flush();
      }
  }
  """

  @doc """
  Installs the fake ssh fixture into `bin_dir` and prepends it to `PATH`.

  ## Options

    * `:trace_file` - path of the trace file the fake appends `ARGV:`/`JSON:` lines to
    * `:stdout` - (`:trace` mode only) single line printed to stdout before exit
    * `:output_line` - (`:marker` mode only) tab-separated line printed when the
      arguments contain the workspace marker
    * `:failure` - (`:marker` mode only) map with `:match`, `:stderr` and `:exit_code`
      describing the host startup failure
  """
  @spec install!(String.t(), :trace | :jsonrpc | :marker, keyword()) :: :ok
  def install!(bin_dir, mode, opts \\ []) when mode in [:trace, :jsonrpc, :marker] do
    File.mkdir_p!(bin_dir)

    if windows?() do
      install_windows!(bin_dir, mode, opts)
    else
      install_posix!(bin_dir, mode, opts)
    end

    prepend_path!(bin_dir)
  end

  defp windows?, do: match?({:win32, _}, :os.type())

  # -- POSIX: the historical extensionless sh fixture --------------------------

  defp install_posix!(bin_dir, mode, opts) do
    fake_ssh = Path.join(bin_dir, "ssh")
    File.write!(fake_ssh, sh_body(mode, opts))
    File.chmod!(fake_ssh, 0o755)
    :ok
  end

  defp sh_body(:trace, opts) do
    [
      "#!/bin/sh",
      argv_trace_line(opts),
      stdout_line(opts[:stdout]),
      "exit 0"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp sh_body(:jsonrpc, opts) do
    """
    #!/bin/sh
    count=0
    #{argv_trace_line(opts)}

    while IFS= read -r line; do
      count=$((count + 1))
      printf 'JSON:%s\\n' "$line" >> "#{opts[:trace_file]}"

      case "$count" in
        1) printf '%s\\n' '{"id":1,"result":{}}' ;;
        2) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-remote"}}}' ;;
        3) printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-remote"}}}' ;;
        4)
          printf '%s\\n' '{"method":"turn/completed"}'
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
    done
    """
  end

  defp sh_body(:marker, opts) do
    failure = opts[:failure]
    marker_output = marker_printf(Keyword.fetch!(opts, :output_line))

    failure_case =
      if failure do
        """

        case "$*" in
          *#{failure.match}*"#{@marker_match}"*)
            printf '%s\\n' '#{failure.stderr}' >&2
            exit #{failure.exit_code}
            ;;
        esac
        """
      else
        ""
      end

    """
    #!/bin/sh
    #{argv_trace_line(opts)}
    #{failure_case}
    case "$*" in
      *"#{@marker_match}"*)
        #{marker_output}
        ;;
    esac

    exit 0
    """
  end

  defp argv_trace_line(opts), do: ~s(printf 'ARGV:%s\\n' "$*" >> "#{opts[:trace_file]}")
  defp stdout_line(nil), do: nil
  defp stdout_line(line), do: ~s(printf '#{line}\\n')

  defp marker_printf(output_line) do
    parts = output_line |> String.split("\t") |> Enum.map(&sh_escape/1)

    format =
      parts
      |> Enum.map_join("\\t", fn _ -> "%s" end)
      |> Kernel.<>("\\n")

    args = Enum.map_join(parts, " ", fn part -> "'" <> part <> "'" end)

    "printf '#{format}' #{args}"
  end

  defp sh_escape(value), do: String.replace(value, "'", "'\\''")

  # -- Windows: compiled ssh.exe ------------------------------------------------

  defp install_windows!(bin_dir, mode, opts) do
    exe = ensure_windows_exe!()
    File.cp!(exe, Path.join(bin_dir, "ssh.exe"))

    if trace_file = opts[:trace_file] do
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
    end

    System.put_env("SYMP_FAKE_SSH_MODE", Atom.to_string(mode))
    put_or_delete_env("SYMP_FAKE_SSH_STDOUT", opts[:stdout])

    case opts[:output_line] do
      nil -> System.delete_env("SYMP_FAKE_SSH_MARKER_OUTPUT")
      line -> System.put_env("SYMP_FAKE_SSH_MARKER_OUTPUT", line)
    end

    case opts[:failure] do
      nil ->
        System.delete_env("SYMP_FAKE_SSH_FAIL_MATCH")

      failure ->
        System.put_env("SYMP_FAKE_SSH_FAIL_MATCH", failure.match)
        System.put_env("SYMP_FAKE_SSH_FAIL_STDERR", failure.stderr)
        System.put_env("SYMP_FAKE_SSH_FAIL_EXIT", to_string(failure.exit_code))
    end

    :ok
  end

  defp put_or_delete_env(key, nil), do: System.delete_env(key)

  defp put_or_delete_env(key, value), do: System.put_env(key, value)

  defp ensure_windows_exe! do
    cache_dir =
      Path.join(System.tmp_dir!(), "symphony-fake-ssh-exe-#{:erlang.phash2(@csharp_source)}")

    exe = Path.join(cache_dir, "ssh.exe")

    unless File.exists?(exe) do
      File.mkdir_p!(cache_dir)
      source = Path.join(cache_dir, "fake_ssh.cs")
      File.write!(source, @csharp_source)
      # csc parses "/" segments in source paths as compiler options, so every
      # path handed to the compiler must use backslashes.
      compile!(find_csc!(), windows_path(source), windows_path(exe))
    end

    exe
  end

  defp windows_path(path), do: String.replace(path, "/", "\\")

  defp compile!(csc, source, exe) do
    tmp_exe = "#{exe}.#{System.unique_integer([:positive])}.tmp"

    case System.cmd(csc, ["/nologo", "/out:" <> tmp_exe, source], stderr_to_stdout: true) do
      {_, 0} ->
        case File.rename(tmp_exe, exe) do
          :ok -> :ok
          {:error, _} -> File.rm(tmp_exe)
        end

      {output, status} ->
        File.rm(tmp_exe)
        raise "compiling fake ssh fixture failed (#{status}): #{output}"
    end

    :ok
  end

  defp find_csc! do
    windir = System.get_env("windir") || "C:\\Windows"

    found =
      Enum.find_value(["Framework64", "Framework"], fn framework ->
        framework_dir = Path.join([windir, "Microsoft.NET", framework])

        case File.ls(framework_dir) do
          {:ok, versions} ->
            versions
            |> Enum.filter(&String.match?(&1, ~r/^v4/))
            |> Enum.sort(:desc)
            |> Enum.find_value(fn version ->
              candidate = Path.join([framework_dir, version, "csc.exe"])
              if File.exists?(candidate), do: candidate
            end)

          _ ->
            nil
        end
      end)

    found || raise("fake ssh fixture requires csc.exe under %windir%\\Microsoft.NET to build ssh.exe on Windows")
  end

  # -- shared -------------------------------------------------------------------

  defp prepend_path!(bin_dir) do
    separator = if windows?(), do: ";", else: ":"
    System.put_env("PATH", bin_dir <> separator <> (System.get_env("PATH") || ""))
    :ok
  end
end
