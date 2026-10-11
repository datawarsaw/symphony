defmodule Mix.Tasks.Symphony.PilotBootstrap do
  @shortdoc "Fail-closed preflight and start gate for the isolated OpenCode pilot"

  @moduledoc """
  Runs the pilot bootstrap gate before any runtime start.

      mix symphony.pilot_bootstrap --manifest <path> [--preflight-only]

  Without `--preflight-only` the task starts the orchestrator only after the
  `:armed` gate passes, then blocks until the application supervisor exits. With
  `--preflight-only` it reports readiness and exits without starting anything.

  Both modes refuse with a non-zero exit code when the manifest is missing, the
  source identity does not match, the workflow is the tracked production file,
  the workspace or log root is outside the pilot, the routing contract is not
  exactly one approved target, or an authorized issue would not select the
  OpenCode harness.

  The gate never contacts a tracker or a provider. It reads the manifest, the
  workflow file and local `git` state only.
  """

  use Mix.Task

  alias SymphonyElixir.PilotBootstrap

  @switches [manifest: :string, preflight_only: :boolean, protected_root: :keep, help: :boolean]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")

    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    cond do
      opts[:help] ->
        Mix.shell().info(usage())

      invalid != [] ->
        Mix.raise("symphony.pilot_bootstrap: unrecognized arguments: " <> inspect(invalid ++ argv))

      is_nil(opts[:manifest]) ->
        Mix.raise("symphony.pilot_bootstrap: --manifest <path> is required. " <> usage())

      true ->
        run_gate(opts)
    end
  end

  defp run_gate(opts) do
    gate_opts = [protected_roots: Keyword.get_values(opts, :protected_root)]

    if opts[:preflight_only] do
      case PilotBootstrap.preflight(opts[:manifest], gate_opts) do
        {:ok, report} ->
          print_report(report)
          Mix.shell().info("symphony.pilot_bootstrap: PREFLIGHT ONLY - runtime not started")

        {:error, reason} ->
          refuse(reason)
      end
    else
      case PilotBootstrap.start(opts[:manifest], gate_opts) do
        {:ok, report} ->
          print_report(report)
          Mix.shell().info("symphony.pilot_bootstrap: gate passed; runtime started")
          wait_for_shutdown()

        {:error, reason} ->
          refuse(reason)
      end
    end
  end

  defp refuse(reason) do
    Mix.shell().error("symphony.pilot_bootstrap: REFUSED (fail-closed)")
    Mix.shell().error(inspect(reason, pretty: true, limit: :infinity))
    Mix.raise("symphony.pilot_bootstrap: refusing to start the pilot")
  end

  defp print_report(report) do
    Mix.shell().info("symphony.pilot_bootstrap: mode=#{report.mode}")
    Mix.shell().info("  pilot_root      = #{report.pilot_root}")
    Mix.shell().info("  source_root     = #{report.source_root}")
    Mix.shell().info("  source_sha      = #{report.source_sha}")
    Mix.shell().info("  workflow_path   = #{report.workflow_path}")
    Mix.shell().info("  workspace_root  = #{report.workspace_root}")
    Mix.shell().info("  logs_root       = #{report.logs_root}")
    Mix.shell().info("  log_file        = #{report.log_file}")
    Mix.shell().info("  routing_targets = #{inspect(report.routing_targets)}")
    Mix.shell().info("  approved_target = #{inspect(report.approved_repo_target)}")
    Mix.shell().info("  armed_ready     = #{inspect(report.armed_ready?)}")

    Enum.each(report.arming_blockers, fn {check, reason} ->
      Mix.shell().info("  arming_blocker  = #{check}: #{inspect(reason)}")
    end)
  end

  defp wait_for_shutdown do
    case Process.whereis(SymphonyElixir.Supervisor) do
      nil ->
        Mix.raise("symphony.pilot_bootstrap: runtime supervisor is not running")

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        end
    end
  end

  defp usage do
    "Usage: mix symphony.pilot_bootstrap --manifest <path> [--preflight-only] [--protected-root <path>]"
  end
end
