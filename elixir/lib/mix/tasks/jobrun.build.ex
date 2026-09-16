defmodule Mix.Tasks.Jobrun.Build do
  @shortdoc "Build the MIC-223 jobrun Windows containment helper and record its hash"

  @moduledoc """
  Deterministically builds `priv/windows/jobrun/jobrun.exe` from the checked-in
  `jobrun.cs` using the in-box .NET Framework compiler (`csc.exe`), then writes
  the SHA-256 of the resulting binary to `priv/windows/jobrun/jobrun.sha256`.

  Requirements: no package restore, no network, no elevation. Fails visibly when
  `csc.exe` is unavailable. Run this once per checkout on Windows before
  starting workers; `SymphonyElixir.Codex.AppServer` refuses to launch a local
  Windows worker through an unverified or missing helper.
  """

  use Mix.Task

  alias SymphonyElixir.WorkerContainment

  @impl Mix.Task
  def run(_args) do
    case WorkerContainment.build_helper() do
      {:ok, %{exe: exe, sha256: sha256}} ->
        Mix.shell().info("jobrun helper built: #{exe}")
        Mix.shell().info("sha256: #{sha256}")

      {:error, reason} ->
        raise Mix.Error, message: "jobrun helper build failed: #{format(reason)}"
    end
  end

  defp format(reason) when is_binary(reason), do: reason
  defp format(reason), do: inspect(reason)
end
