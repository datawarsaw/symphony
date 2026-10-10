defmodule SymphonyElixir.TestSupport.MockOpenCode do
  @moduledoc """
  Deterministic mock OpenCode worker compiler and executable resolver.
  Compiles test/support/windows/mock_opencode.cs via Microsoft csc.exe.
  """

  @source "test/support/windows/mock_opencode.cs"
  @bin_dir "test/support/windows/bin"
  @exe_name "mock_opencode.exe"

  def exe_path do
    Path.expand(Path.join([@bin_dir, @exe_name]))
  end

  def ensure_built! do
    exe = exe_path()
    src = Path.expand(@source)

    rebuild? =
      not File.exists?(exe) or
        File.stat!(src).mtime > File.stat!(exe).mtime

    if rebuild? do
      File.mkdir_p!(Path.expand(@bin_dir))
      csc = find_csc!()

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
          raise "mock_opencode build failed (#{status}): #{output}"
      end
    end

    exe
  end

  defp find_csc! do
    windir = System.get_env("WINDIR") || "C:\\Windows"

    candidates = [
      Path.join([windir, "Microsoft.NET", "Framework64", "v4.0.30319", "csc.exe"]),
      Path.join([windir, "Microsoft.NET", "Framework", "v4.0.30319", "csc.exe"])
    ]

    Enum.find(candidates, &File.exists?/1) || raise "csc.exe not found on host"
  end
end

