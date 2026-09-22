defmodule SymphonyElixir.Delivery.Proof do
  @moduledoc """
  Deterministic delivery-integrity proof engine.

  Answers five questions mechanically, and nothing else:

    1. What exact artifact was accepted? (frozen `ArtifactManifest`)
    2. Has fresh main drifted? (`classify_fresh_main/3`, `drift/3`)
    3. Can the accepted artifact be replayed mechanically? (`Replay`)
    4. Is the replay artifact-equivalent? (patch-id / paths / blobs / tree)
    5. Did remote main after merge contain the same artifact? (`remote_truth/4`)

  Boundary the engine enforces on itself: it never classifies semantic drift
  as safe. Overlap and context evidence is reported, but a decision that
  main changes are `IRRELEVANT` versus `SEMANTIC` belongs to human review
  and the delivery process, not to this module. `:exact_parent` and exact
  replay equivalence are the only mechanically-proven outcomes; every other
  classification is evidence for a reviewer.
  """

  alias SymphonyElixir.Delivery.{ArtifactManifest, Git, Replay}

  @default_scan_limit 2000

  @type repo :: Git.repo()
  @type sha :: Git.sha()
  @type manifest :: ArtifactManifest.t()

  @type classification ::
          :exact_parent
          | :no_overlap
          | :changed_path_overlap
          | :already_merged
          | :superseded
          | :partially_superseded
          | :main_not_descendant

  @type report :: %{
          required(:verdict) => :proceed | :stop,
          required(:stage) => :preflight | :drift | :remote_truth,
          required(:classification) => classification() | nil,
          required(:stop_reasons) => [atom()],
          required(:evidence) => [String.t()],
          required(:data) => map()
        }

  # Replay is meaningful when the artifact can sit on top of fresh main. It
  # runs under :changed_path_overlap too — as evidence only: the overlap stop
  # is never overturned by a clean scratch merge, because "merged cleanly"
  # is not "semantically safe".
  @replay_classifications [:exact_parent, :no_overlap, :changed_path_overlap]

  @doc """
  Verifies a manifest against the repository it claims to describe.

  Recomputes every recorded fact — existence, parent lineage, subject, tree,
  changed paths, stable patch ids, per-path blobs, and the cumulative chain
  — directly from git. Any divergence between manifest and repository is a
  stop: the frozen artifact can no longer be proven to be what was accepted.
  """
  @spec self_check(repo(), manifest()) :: {:ok, report()} | {:stop, report()}
  def self_check(repo, %ArtifactManifest{} = manifest) do
    entries_result =
      manifest.commits
      |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
        case check_entry(repo, entry) do
          :ok -> {:cont, {:ok, [entry.candidate_sha | acc]}}
          {:stop, _} = stop -> {:halt, stop}
        end
      end)

    with {:ok, reversed} <- entries_result,
         :ok <- check_chain(manifest) do
      {:ok,
       report(:preflight,
         evidence:
           reversed
           |> Enum.reverse()
           |> Enum.map(&"self-check #{short(&1)}: lineage, subject, tree, paths, patch-id, blobs all recomputed and matching"),
         data: %{artifact_kind: manifest.artifact_kind, commits: commit_shas(manifest)}
       )}
    end
  end

  @doc """
  Runs the full preflight pipeline: self-check, fresh-main classification,
  and — when `opts` contains `replay: true` — a scratch cherry-pick replay
  compared against the manifest.

  `opts`:

    * `:fresh_main` — externally supplied fresh main sha (required for
      classification and replay)
    * `:replay` — opt in to the mutating scratch replay
    * `:scratch_dir` — where the scratch worktree is created (default:
      unique directory under the system temp dir)
    * `:scan_limit` — bound for patch-id containment scans

  The returned report carries `verdict: :stop` whenever mechanical
  equivalence cannot be proven. The engine never updates any baseline.
  """
  @spec run_preflight(repo(), manifest(), keyword()) :: report()
  def run_preflight(repo, %ArtifactManifest{} = manifest, opts \\ []) do
    case self_check(repo, manifest) do
      {:stop, report} ->
        report

      {:ok, report} ->
        preflight_stage(repo, manifest, opts, report)
    end
  end

  defp preflight_stage(repo, manifest, opts, report) do
    case Keyword.get(opts, :fresh_main) do
      nil ->
        add_evidence(report, ["no --fresh-main supplied: manifest self-check only"])

      fresh_main ->
        report = merge_report(report, classify_stage(repo, manifest, fresh_main))
        maybe_replay(repo, manifest, fresh_main, opts, report)
    end
  end

  defp maybe_replay(repo, manifest, fresh_main, opts, report) do
    replay_requested? = Keyword.get(opts, :replay, false)

    cond do
      replay_requested? and report.classification in @replay_classifications ->
        replay_stage(repo, manifest, fresh_main, opts, report)

      replay_requested? ->
        add_evidence(report, [
          "replay not run: classification #{report.classification} gives replay nothing valid to sit on"
        ])

      true ->
        report
    end
  end

  @doc """
  Classifies a fresh main sha against the frozen artifact.

  Mechanical classifications only:

    * `:exact_parent` — fresh main is exactly the accepted parent
    * `:no_overlap` — main advanced, none of the artifact's paths moved
    * `:changed_path_overlap` — main advanced into the artifact's paths (stop)
    * `:already_merged` — the accepted shas are already ancestors of main
    * `:superseded` — equivalent patches (same stable patch ids) are already
      in main while the accepted shas are not (stop: review, do not replay)
    * `:partially_superseded` — some but not all artifact patch ids are in
      main (stop)
    * `:main_not_descendant` — main is behind the accepted parent or its
      history was rewritten (stop)

  Whether overlapped main changes are semantically `IRRELEVANT` or
  `SEMANTIC` is deliberately not decided here.
  """
  @spec classify_fresh_main(repo(), manifest(), sha()) :: {:ok, report()} | {:stop, report()}
  def classify_fresh_main(repo, manifest, fresh_main) do
    case Git.resolve_commit(repo, fresh_main) do
      {:ok, resolved} ->
        classify_descendant(repo, manifest, resolved)

      {:error, :not_a_commit} ->
        {:stop, stop_report({:fresh_main_missing, fresh_main}, :preflight)}

      error ->
        {:stop, git_stop(:preflight, error)}
    end
  end

  @doc """
  Compares a replayed (or remotely contained) commit against a frozen
  manifest entry.

  Returns `:equivalent` or `{:mismatch, details}`. Tree identity is only
  required when the compared commit has the identical parent; otherwise tree
  proof is reported as not applicable (a transformed replay's parent always
  differs). This comparator backs both replay equivalence and remote truth.
  """
  @spec compare_entry(repo(), sha(), ArtifactManifest.entry()) :: :equivalent | {:mismatch, [map()]}
  def compare_entry(repo, commit_sha, %ArtifactManifest.Entry{} = entry) do
    details =
      Enum.concat([
        patch_id_details(repo, commit_sha, entry),
        path_details(repo, commit_sha, entry),
        blob_details(repo, commit_sha, entry),
        tree_details(repo, commit_sha, entry)
      ])

    if details == [], do: :equivalent, else: {:mismatch, details}
  end

  @doc """
  Reports main movement between two observed mains, explicitly.

  `from` and `to` must both be supplied by the caller every time — the
  helper never remembers a baseline and never updates one. `:advanced`
  reports how many commits main moved; `:rewound` and `:diverged` stop the
  delivery: main did not merely grow.
  """
  @spec drift(repo(), sha(), sha()) :: report()
  def drift(repo, from, to) do
    with {:ok, from} <- resolve_sha(repo, from, :drift),
         {:ok, to} <- resolve_sha(repo, to, :drift) do
      relation =
        cond do
          from == to -> :unchanged
          match?({:ok, true}, Git.ancestor?(repo, from, to)) -> :advanced
          match?({:ok, true}, Git.ancestor?(repo, to, from)) -> :rewound
          true -> :diverged
        end

      drift_report(repo, relation, from, to)
    else
      {:stop, report} -> report
    end
  end

  @doc """
  Deterministic post-merge verification against a final main sha.

  Proves, without touching the remote:

    * every manifest commit is contained in final main — exactly by sha
      ancestry, or by stable patch-id when delivery landed as a transformed
      cherry-pick (accepted sha ≠ merged sha);
    * each container commit is artifact-equivalent (patch-id, paths, blobs);
    * for cumulative artifacts, the feature container is an ancestor of the
      remediation container (ordered lineage preserved);
    * where every artifact path stands on final main now, and whether it
      evolved after delivery (evidence only — post-delivery evolution is
      legitimate and is not a stop).
  """
  @spec remote_truth(repo(), manifest(), sha(), keyword()) :: report()
  def remote_truth(repo, %ArtifactManifest{} = manifest, final_main, opts \\ []) do
    case Git.resolve_commit(repo, final_main) do
      {:ok, resolved} ->
        containment_stage(repo, manifest, resolved, opts)

      {:error, :not_a_commit} ->
        stop_report({:final_main_missing, final_main}, :remote_truth)

      error ->
        git_stop(:remote_truth, error)
    end
  end

  # ------------------------------------------------------------------
  # self-check internals
  # ------------------------------------------------------------------

  defp check_entry(repo, entry) do
    with {:ok, _resolved} <- resolve_candidate(repo, entry),
         {:ok, info} <- Git.commit_info(repo, entry.candidate_sha),
         :ok <- check_topology(info, entry) do
      check_recomputed(repo, entry)
    else
      {:stop, _} = stop -> stop
      {:error, reason} -> {:stop, stop_report({:entry_unreadable, {entry.candidate_sha, reason}}, :preflight)}
    end
  end

  defp resolve_candidate(repo, entry) do
    case Git.resolve_commit(repo, entry.candidate_sha) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, :not_a_commit} -> {:stop, stop_report({:candidate_missing, entry.candidate_sha}, :preflight)}
      error -> error
    end
  end

  defp check_topology(info, entry) do
    cond do
      length(info.parent_shas) > 1 ->
        {:stop, stop_report({:merge_commit, entry.candidate_sha}, :preflight)}

      List.first(info.parent_shas) != entry.parent_sha ->
        {:stop, stop_report({:lineage_broken, entry.candidate_sha}, :preflight)}

      info.subject != entry.commit_subject ->
        {:stop, stop_report({:manifest_tampered, {entry.candidate_sha, :commit_subject}}, :preflight)}

      info.tree_sha != entry.tree_sha ->
        {:stop, stop_report({:manifest_tampered, {entry.candidate_sha, :tree_sha}}, :preflight)}

      true ->
        :ok
    end
  end

  defp check_recomputed(repo, entry) do
    with {:ok, paths} <- Git.changed_paths(repo, entry.candidate_sha),
         :ok <- check_paths(entry, paths),
         {:ok, patch_id} <- Git.stable_patch_id(repo, entry.candidate_sha),
         :ok <- check_patch_id(entry, patch_id) do
      check_blobs(repo, entry)
    else
      {:stop, _} = stop -> stop
      {:error, reason} -> {:stop, stop_report({:entry_unreadable, {entry.candidate_sha, reason}}, :preflight)}
    end
  end

  defp check_paths(entry, paths) do
    if paths == entry.changed_paths,
      do: :ok,
      else: {:stop, stop_report({:manifest_tampered, {entry.candidate_sha, :changed_paths}}, :preflight)}
  end

  defp check_patch_id(entry, patch_id) do
    if patch_id == entry.stable_patch_id,
      do: :ok,
      else: {:stop, stop_report({:manifest_tampered, {entry.candidate_sha, :stable_patch_id}}, :preflight)}
  end

  defp check_blobs(repo, entry) do
    entry.path_blobs
    |> Enum.reduce_while(:ok, fn {path, expected}, :ok ->
      case Git.path_blob(repo, entry.candidate_sha, path) do
        {:ok, ^expected} ->
          {:cont, :ok}

        {:ok, _actual} ->
          reason = {:manifest_tampered, {entry.candidate_sha, {:path_blob, path}}}
          {:halt, {:stop, stop_report(reason, :preflight)}}
      end
    end)
  end

  defp check_chain(%ArtifactManifest{artifact_kind: :single}), do: :ok

  defp check_chain(%ArtifactManifest{commits: commits, cumulative: cumulative}) do
    broken_pair =
      commits
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.find(fn [parent, child] -> child.parent_sha != parent.candidate_sha end)

    case broken_pair do
      nil ->
        if is_nil(cumulative) or cumulative.ordered_patch_ids != ordered_patch_ids(commits) do
          {:stop, stop_report({:manifest_tampered, {:cumulative, :ordered_patch_ids}}, :preflight)}
        else
          :ok
        end

      # A hand-tampered manifest (reversed, duplicated, or reordered chain)
      # can leave every entry individually consistent with git while the
      # consecutive pairs disagree; the child is the entry claiming a parent
      # that is not the previously accepted commit.
      [_parent, child] ->
        {:stop, stop_report({:lineage_broken, child.candidate_sha}, :preflight)}

      other ->
        {:stop, stop_report({:manifest_tampered, {:cumulative, :malformed_pair}}, :preflight, [inspect(other)])}
    end
  end

  defp ordered_patch_ids(commits), do: Enum.map(commits, & &1.stable_patch_id)

  # ------------------------------------------------------------------
  # classification internals
  # ------------------------------------------------------------------

  defp classify_stage(repo, manifest, fresh_main) do
    case classify_fresh_main(repo, manifest, fresh_main) do
      {:ok, fresh_report} -> fresh_report
      {:stop, stop_report} -> stop_report
    end
  end

  defp classify_descendant(repo, manifest, fresh_main) do
    base = ArtifactManifest.first_entry(manifest).parent_sha

    cond do
      is_nil(base) ->
        {:stop, stop_report(:unsupported_root_artifact, :preflight)}

      fresh_main == base ->
        {:ok,
         report(:preflight,
           classification: :exact_parent,
           evidence: ["fresh main #{short(fresh_main)} == accepted parent #{short(base)}: exact parent"],
           data: %{fresh_main: fresh_main, base: base, relation: :exact_parent}
         )}

      match?({:ok, true}, Git.ancestor?(repo, base, fresh_main)) ->
        classify_advanced(repo, manifest, base, fresh_main)

      true ->
        classify_non_descendant(repo, base, fresh_main)
    end
  end

  defp classify_advanced(repo, manifest, base, fresh_main) do
    case Git.count_commits(repo, base, fresh_main) do
      {:ok, advanced} ->
        last_sha = ArtifactManifest.last_entry(manifest).candidate_sha

        if match?({:ok, true}, Git.ancestor?(repo, last_sha, fresh_main)) do
          {:ok, already_merged_report(base, fresh_main, advanced)}
        else
          classify_by_patch_ids(repo, manifest, base, fresh_main, advanced)
        end

      {:error, reason} ->
        {:stop, git_stop(:preflight, {:error, reason})}
    end
  end

  defp already_merged_report(base, fresh_main, advanced) do
    report(:preflight,
      classification: :already_merged,
      evidence: [
        "accepted artifact is already contained in main (ancestor): nothing left to deliver",
        "main advanced #{advanced} commit(s) past the accepted parent"
      ],
      data: %{fresh_main: fresh_main, base: base, advanced_by: advanced, relation: :descendant}
    )
  end

  defp classify_by_patch_ids(repo, manifest, base, fresh_main, advanced) do
    case Git.patch_id_scan(repo, "#{base}..#{fresh_main}", @default_scan_limit) do
      {:ok, scan} ->
        case Git.range_changed_paths(repo, base, fresh_main) do
          {:ok, overlap} ->
            classify_scan(manifest, base, fresh_main, advanced, scan, overlap)

          {:error, reason} ->
            {:stop, git_stop(:preflight, {:error, reason})}
        end

      {:error, reason} ->
        {:stop, git_stop(:preflight, {:error, reason})}
    end
  end

  defp classify_scan(manifest, base, fresh_main, advanced, scan, overlap) do
    ids = ArtifactManifest.ordered_patch_ids(manifest)
    present = Enum.filter(ids, fn id -> Enum.any?(scan, fn {scanned_id, _} -> scanned_id == id end) end)
    artifact_paths = manifest |> ArtifactManifest.changed_paths() |> Enum.uniq()
    overlap_paths = Enum.sort(Enum.filter(artifact_paths, &(&1 in overlap)))

    cond do
      present == ids ->
        superseded_report(base, fresh_main, advanced, scan, ids, present)

      present != [] ->
        partially_superseded_report(base, fresh_main, advanced, ids, present)

      overlap_paths == [] ->
        {:ok,
         report(:preflight,
           classification: :no_overlap,
           evidence: [
             "main advanced #{advanced} commit(s) past the accepted parent",
             "changed paths on base..fresh-main do not intersect artifact paths: mechanically replayable",
             "scan window #{length(scan)} commit(s); no equivalent patch id present"
           ],
           data: %{
             fresh_main: fresh_main,
             base: base,
             advanced_by: advanced,
             overlap_paths: [],
             relation: :descendant
           }
         )}

      true ->
        changed_path_overlap_report(base, fresh_main, advanced, overlap_paths)
    end
  end

  defp superseded_report(base, fresh_main, advanced, scan, ids, present) do
    {:ok,
     report(:preflight,
       classification: :superseded,
       stop_reasons: [:superseded],
       evidence: [
         "STOP: equivalent patches (all #{length(ids)} stable patch id(s)) are already contained in main",
         "main advanced #{advanced} commit(s) past the accepted parent; supersession found within a " <>
           "#{length(scan)} commit scan window"
       ],
       data: %{fresh_main: fresh_main, base: base, advanced_by: advanced, superseded_patch_ids: present}
     )
     |> Map.put(:verdict, :stop)}
  end

  defp partially_superseded_report(base, fresh_main, advanced, ids, present) do
    {:ok,
     report(:preflight,
       classification: :partially_superseded,
       stop_reasons: [:partially_superseded],
       evidence: [
         "STOP: #{length(present)} of #{length(ids)} artifact patch id(s) already in main; partial supersession",
         "missing patch ids: #{inspect(ids -- present)}"
       ],
       data: %{fresh_main: fresh_main, base: base, advanced_by: advanced, superseded_patch_ids: present}
     )
     |> Map.put(:verdict, :stop)}
  end

  defp changed_path_overlap_report(base, fresh_main, advanced, overlap_paths) do
    {:ok,
     report(:preflight,
       classification: :changed_path_overlap,
       stop_reasons: [:changed_path_overlap],
       evidence: [
         "STOP: main moved into the artifact's changed surface",
         "overlapping paths: #{Enum.join(overlap_paths, ", ")}",
         "whether those changes are semantically IRRELEVANT or SEMANTIC is a review decision, not a tool verdict"
       ],
       data: %{
         fresh_main: fresh_main,
         base: base,
         advanced_by: advanced,
         overlap_paths: overlap_paths,
         relation: :descendant
       }
     )
     |> Map.put(:verdict, :stop)}
  end

  defp classify_non_descendant(repo, base, fresh_main) do
    behind? = match?({:ok, true}, Git.ancestor?(repo, fresh_main, base))

    evidence =
      if behind? do
        ["STOP: main #{short(fresh_main)} is BEHIND the accepted parent #{short(base)} (rewound main)"]
      else
        [
          "STOP: main #{short(fresh_main)} is not a descendant of the accepted parent #{short(base)} " <>
            "(history rewritten or unrelated branch)"
        ]
      end

    {:ok,
     report(:preflight,
       classification: :main_not_descendant,
       stop_reasons: [:main_not_descendant],
       evidence: evidence,
       data: %{fresh_main: fresh_main, base: base, relation: if(behind?, do: :rewound, else: :diverged)}
     )
     |> Map.put(:verdict, :stop)}
  end

  # ------------------------------------------------------------------
  # replay internals
  # ------------------------------------------------------------------

  defp replay_stage(repo, manifest, fresh_main, opts, report) do
    shas = commit_shas(manifest)

    evidence_header = [
      "replaying #{length(shas)} accepted commit(s) onto fresh main #{short(fresh_main)} in a scratch worktree"
    ]

    case Replay.cherry_pick(repo, shas, fresh_main, Keyword.take(opts, [:scratch_dir])) do
      {:ok, %{replayed_shas: replayed}} ->
        finish_replay(repo, manifest, replayed, report, evidence_header)

      {:error, {:cherry_pick_conflict, %{failing_sha: failed, conflicting_paths: paths}}} ->
        report
        |> add_evidence(evidence_header)
        |> add_evidence([
          "STOP: cherry-pick of #{short(failed)} conflicted",
          "conflicting paths: #{Enum.join(paths, ", ")}"
        ])
        |> Map.update!(:data, &Map.put(&1, :replay_conflict, %{failing_sha: failed, conflicting_paths: paths}))
        |> stop_with(:replay_conflict)

      error ->
        report
        |> add_evidence(evidence_header)
        |> add_evidence(["STOP: replay infrastructure failure: #{inspect(error)}"])
        |> stop_with(:replay_infrastructure_failure)
    end
  end

  defp finish_replay(repo, manifest, replayed, report, evidence_header) do
    outcomes = Enum.map(Enum.zip(manifest.commits, replayed), &compare_replayed(repo, &1))
    lines = Enum.map(outcomes, &elem(&1, 0))
    mismatches = outcomes |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1)

    if mismatches == [] do
      report
      |> add_evidence(evidence_header ++ lines)
      |> Map.update!(:data, &Map.put(&1, :replayed_shas, replayed))
    else
      report
      |> add_evidence(evidence_header ++ lines)
      |> add_evidence(["STOP: replay is not artifact-equivalent to the accepted artifact"])
      |> Map.update!(:data, &Map.put(&1, :replay_mismatches, mismatches))
      |> stop_with(stop_reason_for_mismatches(mismatches))
    end
  end

  defp compare_replayed(repo, {entry, replayed_sha}) do
    case compare_entry(repo, replayed_sha, entry) do
      :equivalent ->
        {replay_equivalent_line(repo, entry, replayed_sha), nil}

      {:mismatch, details} ->
        detail_lines = Enum.map(details, fn detail -> "    #{detail.detail}" end)
        header = "  MISMATCH replay #{short(replayed_sha)} for accepted #{short(entry.candidate_sha)}"
        {Enum.join([header | detail_lines], "\n"), details}
    end
  end

  defp replay_equivalent_line(repo, entry, replayed_sha) do
    tree_part =
      case Git.commit_info(repo, replayed_sha) do
        {:ok, %{parent_shas: [parent]}} when parent == entry.parent_sha and parent != nil ->
          "tree ✓ (identical parent, tree proof required and passed)"

        _ ->
          "tree n/a (replay parent differs: transformed replay)"
      end

    "  replay #{short(replayed_sha)} ≡ accepted #{short(entry.candidate_sha)}: patch-id ✓ paths ✓ blobs ✓ #{tree_part}"
  end

  defp stop_reason_for_mismatches(mismatches) do
    kinds =
      mismatches
      |> List.flatten()
      |> Enum.map(& &1.kind)
      |> Enum.uniq()

    cond do
      :patch_id in kinds -> :replay_patch_id_mismatch
      :paths in kinds -> :replay_path_mismatch
      :blob in kinds -> :replay_blob_mismatch
      :tree in kinds -> :replay_tree_mismatch
      true -> :replay_mismatch
    end
  end

  # ------------------------------------------------------------------
  # comparator internals (shared by replay and remote truth)
  # ------------------------------------------------------------------

  defp patch_id_details(repo, commit_sha, entry) do
    case Git.stable_patch_id(repo, commit_sha) do
      {:ok, actual} when actual == entry.stable_patch_id ->
        []

      {:ok, actual} ->
        [%{kind: :patch_id, detail: "patch-id differs: accepted #{entry.stable_patch_id} vs found #{actual}"}]

      error ->
        [%{kind: :patch_id, detail: "patch-id unreadable: #{inspect(error)}"}]
    end
  end

  defp path_details(repo, commit_sha, entry) do
    case Git.changed_paths(repo, commit_sha) do
      {:ok, paths} when paths == entry.changed_paths ->
        []

      {:ok, paths} ->
        [%{kind: :paths, detail: "changed-path set differs: accepted #{inspect(entry.changed_paths)} vs found #{inspect(paths)}"}]

      error ->
        [%{kind: :paths, detail: "changed paths unreadable: #{inspect(error)}"}]
    end
  end

  defp blob_details(repo, commit_sha, entry) do
    entry.path_blobs
    |> Enum.flat_map(fn {path, expected} ->
      case Git.path_blob(repo, commit_sha, path) do
        {:ok, ^expected} ->
          []

        {:ok, actual} ->
          [%{kind: :blob, detail: "blob identity differs at #{path}: accepted #{expected || "absent"} vs found #{actual || "absent"}"}]
      end
    end)
  end

  defp tree_details(repo, commit_sha, entry) do
    case Git.commit_info(repo, commit_sha) do
      {:ok, %{parent_shas: parents, tree_sha: tree}} ->
        identical_parent? = parents == [entry.parent_sha] and entry.parent_sha != nil

        if identical_parent? and tree != entry.tree_sha do
          [%{kind: :tree, detail: "tree differs despite identical parent: accepted #{entry.tree_sha} vs found #{tree}"}]
        else
          []
        end

      error ->
        [%{kind: :tree, detail: "commit unreadable: #{inspect(error)}"}]
    end
  end

  # ------------------------------------------------------------------
  # drift internals
  # ------------------------------------------------------------------

  defp resolve_sha(repo, sha, stage) do
    case Git.resolve_commit(repo, sha) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, :not_a_commit} -> {:stop, stop_report({:unknown_sha, sha}, stage)}
      error -> {:stop, git_stop(stage, error)}
    end
  end

  defp drift_report(_repo, :unchanged, from, to) do
    report(:drift,
      evidence: ["main unchanged: #{short(from)} == #{short(to)}"],
      data: %{from: from, to: to, relation: :unchanged, moved_by: 0}
    )
  end

  defp drift_report(repo, :advanced, from, to) do
    {:ok, moved} = Git.count_commits(repo, from, to)

    report(:drift,
      evidence: ["BASELINE MOVED: main advanced #{short(from)} -> #{short(to)} (+#{moved} commit(s))"],
      data: %{from: from, to: to, relation: :advanced, moved_by: moved}
    )
  end

  defp drift_report(repo, :rewound, from, to) do
    {:ok, moved} = Git.count_commits(repo, to, from)

    report(:drift,
      stop_reasons: [:main_rewound],
      evidence: ["STOP: main REWOUND #{short(from)} -> #{short(to)} (-#{moved} commit(s)); main did not merely grow"],
      data: %{from: from, to: to, relation: :rewound, moved_by: -moved}
    )
    |> Map.put(:verdict, :stop)
  end

  defp drift_report(_repo, :diverged, from, to) do
    report(:drift,
      stop_reasons: [:main_diverged],
      evidence: ["STOP: main DIVERGED #{short(from)} -> #{short(to)} (neither is an ancestor of the other; history rewritten?)"],
      data: %{from: from, to: to, relation: :diverged}
    )
    |> Map.put(:verdict, :stop)
  end

  # ------------------------------------------------------------------
  # remote truth internals
  # ------------------------------------------------------------------

  defp containment_stage(repo, manifest, final_main, opts) do
    # explicit nils from a CLI that omits the flags must fall back to defaults
    scan_limit = opts[:scan_limit] || @default_scan_limit
    scan_base = opts[:scan_base]

    range = if scan_base, do: "#{scan_base}..#{final_main}", else: final_main

    case Git.patch_id_scan(repo, range, scan_limit) do
      {:ok, scan} ->
        contain_all(repo, manifest, final_main, scan)

      error ->
        git_stop(:remote_truth, error)
    end
  end

  defp contain_all(repo, manifest, final_main, scan) do
    result =
      manifest.commits
      |> Enum.reduce_while({:ok, [], []}, fn entry, {:ok, containers, evidence} ->
        case contain_one(repo, entry, final_main, scan) do
          {:ok, container} ->
            {:cont, {:ok, [container | containers], [container_evidence(repo, entry, container) | evidence]}}

          {:stop, _} = stop ->
            {:halt, stop}
        end
      end)

    case result do
      {:ok, containers, evidence} ->
        case check_order(repo, manifest, Enum.reverse(containers)) do
          :ok ->
            report(:remote_truth,
              evidence: Enum.reverse(evidence),
              data: %{final_main: final_main, containers: Enum.reverse(containers)}
            )
            |> current_state_evidence(repo, manifest, final_main)

          {:stop, stop_report} ->
            stop_report
        end

      {:stop, stop_report} ->
        stop_report
    end
  end

  defp contain_one(repo, entry, final_main, scan) do
    exact? = match?({:ok, true}, Git.ancestor?(repo, entry.candidate_sha, final_main))

    if exact? do
      verify_container(repo, entry, entry.candidate_sha, :exact)
    else
      find_equivalent_container(repo, entry, scan)
    end
  end

  defp find_equivalent_container(repo, entry, scan) do
    match = Enum.find(scan, fn {scanned_id, _} -> scanned_id == entry.stable_patch_id end)

    case match do
      {_id, sha} -> verify_container(repo, entry, sha, :equivalent)
      nil -> not_contained_stop(entry)
    end
  end

  defp verify_container(repo, entry, container_sha, mode) do
    case compare_entry(repo, container_sha, entry) do
      :equivalent ->
        {:ok, %{sha: container_sha, mode: mode, patch_id: entry.stable_patch_id}}

      {:mismatch, details} ->
        lines = Enum.map(details, fn detail -> "    #{detail.detail}" end)

        {:stop,
         stop_report(
           {:remote_truth_mismatch, {entry.candidate_sha, container_sha}},
           :remote_truth,
           [
             "STOP: container #{short(container_sha)} is not artifact-equivalent to accepted #{short(entry.candidate_sha)}"
           ] ++ lines
         )}
    end
  end

  defp not_contained_stop(entry) do
    {:stop,
     stop_report(
       {:remote_truth_not_contained, {entry.candidate_sha, entry.stable_patch_id}},
       :remote_truth,
       [
         "STOP: accepted commit #{short(entry.candidate_sha)} is not an ancestor of final main and no equivalent " <>
           "patch id was found in the scan window"
       ]
     )}
  end

  defp container_evidence(_repo, entry, container) do
    mode_line =
      case container.mode do
        :exact -> "exact containment (sha is an ancestor of final main)"
        :equivalent -> "transformed containment (cherry-picked as #{short(container.sha)}, stable patch id equal)"
      end

    "accepted #{short(entry.candidate_sha)}: #{mode_line}; patch-id ✓ paths ✓ blobs ✓"
  end

  defp check_order(_repo, %ArtifactManifest{artifact_kind: :single}, _containers), do: :ok

  defp check_order(repo, _manifest, containers) do
    feature = List.first(containers)
    remediation = List.last(containers)

    if match?({:ok, true}, Git.ancestor?(repo, feature.sha, remediation.sha)) do
      :ok
    else
      # stop_report takes the evidence lines positionally; a keyword here would
      # leak a tuple into the report and crash the CLI printing the stop.
      {:stop,
       stop_report(
         :remote_truth_order_violated,
         :remote_truth,
         [
           "STOP: cumulative order violated on final main: feature container #{short(feature.sha)} is not an " <>
             "ancestor of remediation container #{short(remediation.sha)}"
         ]
       )}
    end
  end

  defp current_state_evidence(report, repo, manifest, final_main) do
    lines =
      manifest.commits
      |> Enum.reduce(%{}, fn entry, acc -> Map.merge(acc, entry.path_blobs) end)
      |> Enum.sort()
      |> Enum.map(fn {path, expected} ->
        case Git.path_blob(repo, final_main, path) do
          {:ok, ^expected} -> "  #{path}: blob unchanged since delivery (#{expected || "absent"})"
          {:ok, actual} -> "  #{path}: blob EVOLVED after delivery (delivered #{expected || "absent"}, now #{actual || "absent"})"
        end
      end)

    report
    |> add_evidence(["current state of artifact paths on final main:" | lines])
  end

  # ------------------------------------------------------------------
  # report plumbing
  # ------------------------------------------------------------------

  defp report(stage, fields) do
    Keyword.merge(
      [verdict: :proceed, stage: stage, classification: nil, stop_reasons: [], evidence: [], data: %{}],
      fields
    )
    |> Map.new()
  end

  defp stop_report(reason, stage, evidence \\ []) do
    report(stage, stop_reasons: [reason], evidence: evidence) |> Map.put(:verdict, :stop)
  end

  defp add_evidence(report, lines), do: Map.update!(report, :evidence, &(&1 ++ lines))

  defp merge_report(report, inner) do
    combined =
      report
      |> Map.put(:classification, inner.classification || report.classification)
      |> add_evidence(inner.evidence)
      |> Map.update!(:data, &Map.merge(&1, inner.data))

    if inner.verdict == :stop do
      combined
      |> Map.put(:verdict, :stop)
      |> Map.update!(:stop_reasons, &(&1 ++ inner.stop_reasons))
    else
      combined
    end
  end

  defp stop_with(report, reason) do
    report
    |> Map.put(:verdict, :stop)
    |> Map.update!(:stop_reasons, &(&1 ++ [reason]))
  end

  defp git_stop(stage, {:error, {:git_failed, code, out}}) do
    stop_report({:git_failed, code, String.slice(out, 0, 400)}, stage, ["STOP: git command failed (#{code})"])
  end

  defp commit_shas(manifest), do: Enum.map(manifest.commits, & &1.candidate_sha)

  # Evidence lines carry full shas: they are records meant to be pasted into
  # a delivery report, where an 8-character prefix is ambiguous.
  defp short(sha) when is_binary(sha), do: sha
  defp short(other), do: inspect(other)
end
