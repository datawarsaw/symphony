defmodule Mix.Tasks.HumanAcceptance do
  use Mix.Task

  alias SymphonyElixir.HumanAcceptance
  alias SymphonyElixir.HumanAcceptance.EvidencePack
  alias SymphonyElixir.Workflow

  @shortdoc "Preview or publish a post-review Human Acceptance evidence snapshot"
  @moduledoc """
  Render a trusted version 1 JSON evidence snapshot without starting the scheduler.

      mix human_acceptance --input evidence.json
      mix human_acceptance --input evidence.json --publish MIC-185 --workflow WORKFLOW.md

  Preview is the default. Publication upserts one Linear comment; neither mode
  changes issue state or starts a reviewer. The post-review caller must supply
  the current target and independent reviewer receipt under its per-issue lock.
  See docs/human-acceptance.md for the evidence contract and revision discipline.
  """

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [input: :string, publish: :string, workflow: :string])

    if rest != [] or invalid != [] or is_nil(opts[:input]) do
      Mix.raise("Expected --input evidence.json [--publish ISSUE_ID] [--workflow WORKFLOW.md]")
    end

    Mix.Task.run("compile")
    evidence = read_evidence!(opts[:input])

    case opts[:publish] do
      nil -> Mix.shell().info(EvidencePack.render(evidence).body)
      issue_id -> publish!(issue_id, evidence, opts)
    end
  end

  defp read_evidence!(path) do
    with {:ok, %{size: size}} when size <= 262_144 <- File.stat(path),
         {:ok, content} <- File.read(path),
         {:ok, evidence} when is_map(evidence) <- Jason.decode(content) do
      evidence
    else
      _ -> Mix.raise("Evidence input must be a readable JSON object no larger than 256 KiB")
    end
  end

  defp publish!(issue_id, evidence, opts) do
    if opts[:workflow], do: Workflow.set_workflow_file_path(Path.expand(opts[:workflow]))
    {:ok, _apps} = Application.ensure_all_started(:req)

    case HumanAcceptance.publish(issue_id, evidence) do
      {:ok, %{comment_id: id, ready: ready}} -> Mix.shell().info("Human Acceptance comment #{id}; ready=#{ready}; issue state unchanged")
      {:error, reason} -> Mix.raise("Human Acceptance publication failed: #{inspect(reason)}")
    end
  end
end
