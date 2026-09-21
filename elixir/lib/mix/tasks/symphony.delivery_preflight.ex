defmodule Mix.Tasks.Symphony.DeliveryPreflight do
  @shortdoc "Deterministic delivery artifact proof: freeze, preflight, drift, remote-truth"

  @moduledoc """
  Freeze manifests and run deterministic delivery-integrity preflights.

  This task is an evidence generator and a deterministic stop gate. It is
  NOT a semantic reviewer, NOT Human Acceptance, and NOT merge authority:
  a `PROCEED` verdict proves mechanical artifact equivalence only, and every
  report repeats that boundary.

  Subcommands (run from `elixir/`; point `--repo` at the git repository the
  artifact lives in):

      # Freeze what was accepted (one sha = single artifact; ordered shas = cumulative):
      mix symphony.delivery_preflight freeze <sha> [<sha> ...] \
        --repo <repo> [--out manifest.json]

      # Preflight against an externally supplied fresh main:
      mix symphony.delivery_preflight preflight --manifest manifest.json \
        --repo <repo> [--fresh-main <sha>] [--replay] [--json]

      # Report main movement between two observations (never updates a baseline):
      mix symphony.delivery_preflight drift --from <old-main> --to <new-main> --repo <repo>

      # Prove post-merge remote truth without touching the remote:
      mix symphony.delivery_preflight remote-truth --manifest manifest.json \
        --final-main <sha> --repo <repo> [--scan-base <sha>] [--scan-limit N] [--json]

  Exit codes: 0 = mechanical PROCEED, 1 = STOP or error. STOP is always a
  safe direction: the tool refuses rather than guesses.
  """

  use Mix.Task

  alias SymphonyElixir.Delivery.{ArtifactManifest, Proof}

  @switches [
    repo: :string,
    out: :string,
    manifest: :string,
    fresh_main: :string,
    replay: :boolean,
    scratch_dir: :string,
    scan_base: :string,
    scan_limit: :integer,
    from: :string,
    to: :string,
    final_main: :string,
    json: :boolean
  ]

  @subcommands ~w(freeze preflight drift remote-truth)

  @impl Mix.Task
  def run([]) do
    Mix.raise("symphony.delivery_preflight: missing subcommand. Expected one of: #{Enum.join(@subcommands, ", ")}")
  end

  def run([subcommand | rest]) when subcommand in @subcommands do
    {opts, argv, invalid} = OptionParser.parse(rest, strict: @switches)

    unless invalid == [] do
      Mix.raise("symphony.delivery_preflight #{subcommand}: unrecognized arguments: #{inspect(invalid)}")
    end

    case subcommand do
      "freeze" -> freeze(argv, opts)
      "preflight" -> preflight(opts)
      "drift" -> drift(opts)
      "remote-truth" -> remote_truth(opts)
    end
  end

  def run([unknown | _]) do
    Mix.raise("symphony.delivery_preflight: unknown subcommand #{inspect(unknown)}. Expected one of: #{Enum.join(@subcommands, ", ")}")
  end

  # ------------------------------------------------------------------
  # freeze
  # ------------------------------------------------------------------

  defp freeze(argv, opts) do
    repo = repo_opt(opts)

    if argv == [] do
      Mix.raise("symphony.delivery_preflight freeze: pass at least one accepted commit sha (ordered, feature first)")
    end

    case ArtifactManifest.build(repo, argv, repository: repository_annotation(repo)) do
      {:ok, manifest} ->
        case Keyword.get(opts, :out) do
          nil -> Mix.shell().info(ArtifactManifest.encode(manifest))
          path -> save_manifest(manifest, path)
        end

      {:error, reason} ->
        Mix.raise("symphony.delivery_preflight freeze: #{inspect(reason)}")
    end
  end

  defp save_manifest(manifest, path) do
    case ArtifactManifest.save(manifest, path) do
      :ok ->
        Mix.shell().info("froze #{length(manifest.commits)} commit(s) into #{path} (#{manifest.artifact_kind} artifact)")

      {:error, reason} ->
        Mix.raise("symphony.delivery_preflight freeze: cannot write #{path}: #{inspect(reason)}")
    end
  end

  # ------------------------------------------------------------------
  # preflight
  # ------------------------------------------------------------------

  defp preflight(opts) do
    manifest = load_manifest(opts)

    report =
      Proof.run_preflight(repo_opt(opts), manifest,
        fresh_main: opts[:fresh_main],
        replay: opts[:replay] || false,
        scratch_dir: opts[:scratch_dir]
      )

    finish(report, opts[:json] || false)
  end

  # ------------------------------------------------------------------
  # drift
  # ------------------------------------------------------------------

  defp drift(opts) do
    with {:ok, from} <- require_opt(opts, :from, "drift"),
         {:ok, to} <- require_opt(opts, :to, "drift") do
      Proof.drift(repo_opt(opts), from, to) |> finish(opts[:json] || false)
    else
      {:error, message} -> Mix.raise(message)
    end
  end

  # ------------------------------------------------------------------
  # remote truth
  # ------------------------------------------------------------------

  defp remote_truth(opts) do
    manifest = load_manifest(opts)

    case require_opt(opts, :final_main, "remote-truth") do
      {:ok, final_main} ->
        report =
          Proof.remote_truth(repo_opt(opts), manifest, final_main,
            scan_base: opts[:scan_base],
            scan_limit: opts[:scan_limit]
          )

        finish(report, opts[:json] || false)

      {:error, message} ->
        Mix.raise(message)
    end
  end

  # ------------------------------------------------------------------
  # shared plumbing
  # ------------------------------------------------------------------

  defp load_manifest(opts) do
    with {:ok, path} <- require_opt(opts, :manifest, "preflight/remote-truth"),
         {:ok, manifest} <- ArtifactManifest.load(path) do
      manifest
    else
      {:error, message} when is_binary(message) -> Mix.raise(message)
      {:error, reason} -> Mix.raise("symphony.delivery_preflight: cannot load manifest: #{inspect(reason)}")
    end
  end

  defp require_opt(opts, key, context) do
    case opts[key] do
      nil -> {:error, "symphony.delivery_preflight #{context}: missing --#{key}"}
      value -> {:ok, value}
    end
  end

  defp repo_opt(opts), do: Keyword.get(opts, :repo, ".") |> Path.absname()

  defp repository_annotation(repo) do
    case System.cmd("git", ["-c", "safe.directory=#{repo}", "-C", repo, "remote", "get-url", "origin"],
           cd: repo,
           stderr_to_stdout: true
         ) do
      {url, 0} -> String.trim(url)
      _ -> repo
    end
  end

  defp finish(report, true), do: Mix.shell().info(Jason.encode!(report, pretty: true))

  defp finish(report, false) do
    Enum.each(report.evidence, &Mix.shell().info(&1))
    Mix.shell().info("VERDICT: #{String.upcase(Atom.to_string(report.verdict))}")
    print_boundary()

    if report.verdict == :stop do
      stop_exit(report)
    end

    :ok
  end

  defp print_boundary do
    Mix.shell().info("NOTE: mechanical evidence only — this tool is not a semantic reviewer, not Human Acceptance, and not merge authority.")
  end

  defp stop_exit(report) do
    reasons = Enum.map_join(report.stop_reasons, ", ", &stop_reason_text/1)
    Mix.shell().error("symphony.delivery_preflight: STOP (#{reasons})")
    exit({:shutdown, 1})
  end

  defp stop_reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp stop_reason_text(reason), do: inspect(reason)
end
