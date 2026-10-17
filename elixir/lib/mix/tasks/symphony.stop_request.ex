defmodule Mix.Tasks.Symphony.StopRequest do
  @shortdoc "Request a guarded graceful stop of a running Symphony runtime"

  @moduledoc """
  Writes an attributable runtime stop request for a running Symphony runtime.

      mix symphony.stop_request --state-root <path> --reason <text> --requested-by <who>

  The request names the runtime instance that currently holds the authority
  lease for `--state-root`. A runtime started through a foreground entry point
  (`mix symphony.pilot_bootstrap`, the `symphony` CLI) polls the request file
  and honors an exact-instance request by stopping through supervision and
  releasing the lease — only when it provably still owns the lease and no
  worker is running. The task itself stops nothing and never touches a stale
  or foreign lease; explicit operator recovery
  (`SymphonyElixir.RuntimeLease.force_release/2`) remains the only path for
  those.

  Refuses with a non-zero exit code and writes nothing when: `--state-root` or
  attribution is missing or blank, no lease exists at the state root, the
  lease cannot be read, or a request for a DIFFERENT instance is already
  pending (remove that file explicitly when it is stale residue).
  """

  use Mix.Task

  alias SymphonyElixir.RuntimeShutdown

  @switches [state_root: :string, reason: :string, requested_by: :string, help: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    cond do
      opts[:help] ->
        Mix.shell().info(usage())

      invalid != [] or argv != [] ->
        refuse("unrecognized arguments: " <> inspect(invalid ++ argv))

      is_binary(opts[:state_root]) and is_binary(opts[:reason]) and is_binary(opts[:requested_by]) ->
        request(opts)

      true ->
        refuse("state_root, reason, and requested_by are required. " <> usage())
    end
  end

  defp request(opts) do
    case RuntimeShutdown.request(opts[:state_root], opts[:reason], requested_by: opts[:requested_by]) do
      {:ok, body} ->
        Mix.shell().info(
          "runtime stop request written instance_id=#{body.instance_id} " <>
            "path=#{RuntimeShutdown.stop_request_path(opts[:state_root])}"
        )

      {:error, reason} ->
        refuse(inspect(reason))
    end
  end

  defp refuse(detail) do
    Mix.shell().error("symphony.stop_request: REFUSED (fail-closed): " <> detail)
    Mix.raise("symphony.stop_request: refusing to write the stop request")
  end

  defp usage do
    "Usage: mix symphony.stop_request --state-root <path> --reason <text> --requested-by <who>"
  end
end
