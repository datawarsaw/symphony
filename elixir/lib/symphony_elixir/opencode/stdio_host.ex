defmodule SymphonyElixir.OpenCode.StdioHost do
  @moduledoc """
  Small Windows host that gives the OpenCode child stdin EOF immediately and
  keeps the child's stderr out of the JSONL stdout pipe.

  The host process itself keeps the port stdin open. Under Job containment that
  pipe is the wrapper's stop signal, so it must not be closed merely to unblock
  OpenCode.
  """

  @source_name "opencode_stdio.cs"
  @exe_name "opencode_stdio.exe"

  @spec ensure_built() :: {:ok, String.t()} | {:error, term()}
  def ensure_built do
    dir = Application.app_dir(:symphony_elixir, "priv/windows/opencode_stdio")
    src = Path.join(dir, @source_name)
    exe = Path.join(dir, @exe_name)

    cond do
      not File.regular?(src) ->
        {:error, {:stdio_host_source_missing, src}}

      needs_rebuild?(src, exe) ->
        compile(src, exe)

      true ->
        {:ok, exe}
    end
  end

  defp needs_rebuild?(src, exe) do
    not File.regular?(exe) or File.stat!(src).mtime > File.stat!(exe).mtime
  end

  defp compile(src, exe) do
    with {:ok, csc} <- find_csc() do
      args = [
        "/nologo",
        "/optimize+",
        "/target:exe",
        "/out:" <> backslash(exe),
        backslash(src)
      ]

      case System.cmd(csc, args, stderr_to_stdout: true) do
        {_, 0} -> {:ok, exe}
        {output, status} -> {:error, {:stdio_host_compile_failed, status, output}}
      end
    end
  end

  defp find_csc do
    windir = System.get_env("WINDIR") || "C:\\Windows"

    candidates = [
      Path.join([windir, "Microsoft.NET", "Framework64", "v4.0.30319", "csc.exe"]),
      Path.join([windir, "Microsoft.NET", "Framework", "v4.0.30319", "csc.exe"])
    ]

    Enum.find_value(candidates, fn candidate ->
      if File.exists?(candidate), do: {:ok, candidate}, else: nil
    end) || {:error, :csc_not_found}
  end

  defp backslash(path), do: String.replace(path, "/", "\\")
end
