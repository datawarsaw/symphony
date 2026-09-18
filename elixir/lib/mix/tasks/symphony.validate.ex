defmodule Mix.Tasks.Symphony.Validate do
  use Mix.Task

  @moduledoc """
  Canonical validation entry point for the Symphony Elixir implementation.

  Runs a bounded gate set and propagates every failure to a non-zero `mix`
  exit code. Each gate's exit status is captured before its output is
  printed, so piping or filtering the output afterwards can never mask a
  failing gate.

  Standard gates:

    1. `mix compile --warnings-as-errors`
    2. `mix format --check-formatted`
    3. `git diff --check`
    4. `mix test`

  `--full` additionally runs `mix lint` (`specs.check` + `credo --strict`).

  Line endings are governed by the repository `.gitattributes` (LF for all
  text); do not rely on `core.autocrlf`, and never use `command | tail` as a
  pass/fail gate. Run from this directory (`elixir/`).
  """

  @shortdoc "Run the standard (or --full) validation gates with strict exit codes"

  @switches [full: :boolean]
  @failure_tail_lines 40

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    unless invalid == [] do
      Mix.raise("symphony.validate: unrecognized arguments: #{inspect(invalid)}")
    end

    gates = standard_gates() ++ full_gates(opts)
    results = Enum.map(gates, &run_gate/1)

    Enum.each(results, &print_result/1)

    case Enum.filter(results, &(&1.status != 0)) do
      [] ->
        Mix.shell().info("symphony.validate: all #{length(results)} gates passed")

      failures ->
        names = Enum.map_join(failures, ", ", & &1.name)
        Mix.raise("symphony.validate: #{length(failures)} failing gate(s): #{names}")
    end
  end

  defp standard_gates do
    [
      gate("compile --warnings-as-errors", mix_command(["compile", "--warnings-as-errors"])),
      gate("format --check-formatted", mix_command(["format", "--check-formatted"])),
      gate("git diff --check", {"git", ["diff", "--check"]}),
      gate("test suite", mix_command(["test"]))
    ]
  end

  defp full_gates(opts) do
    if opts[:full] do
      [gate("lint (specs.check + credo --strict)", mix_command(["lint"]))]
    else
      []
    end
  end

  defp gate(name, command), do: %{name: name, command: command}

  # On Windows the `mix` launcher is a batch file, which spawn_executable
  # cannot run directly; route through cmd.exe. On other platforms use mix.
  defp mix_command(args) do
    case :os.type() do
      {:win32, _} -> {"cmd", ["/c", "mix" | args]}
      _ -> {"mix", args}
    end
  end

  defp run_gate(%{name: name, command: {exec, args}}) do
    Mix.shell().info("[symphony.validate] running: #{name}")
    {output_lines, status} = System.cmd(exec, args, into: [], stderr_to_stdout: true)
    %{name: name, status: status, output: output_lines}
  end

  defp print_result(%{name: name, status: 0}) do
    Mix.shell().info("[symphony.validate] PASS: #{name}")
  end

  defp print_result(%{name: name, status: status, output: output}) do
    Mix.shell().error("[symphony.validate] FAIL (exit #{status}): #{name}")

    output
    |> Enum.take(-@failure_tail_lines)
    |> Enum.each(fn line -> Mix.shell().error(line) end)
  end
end
